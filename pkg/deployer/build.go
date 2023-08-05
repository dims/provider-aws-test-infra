/*
Copyright 2020 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package deployer

import (
	"fmt"
	"strings"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/s3"
	"github.com/aws/aws-sdk-go/service/s3/s3manager"

	"k8s.io/klog/v2"

	"sigs.k8s.io/provider-aws-test-infra/pkg/deployer/build"
)

func (d *deployer) Build() error {
	klog.V(1).Info("EC2 deployer starting Build()")

	sess, err := session.NewSession(&aws.Config{Region: aws.String(d.Region)})
	if err != nil {
		klog.Fatalf("Unable to create AWS session, %s", err)
	}
	s3Uploader := s3manager.NewUploaderWithClient(s3.New(sess), func(u *s3manager.Uploader) {
		u.PartSize = 10 * 1024 * 1024 // 50 mb
		u.Concurrency = 10
	})
	d.BuildOptions.CommonBuildOptions.S3Uploader = s3Uploader

	d.BuildOptions.Validate()

	// this supports the kubernetes/kubernetes build
	klog.V(2).Info("starting to build kubernetes")
	version, err := d.BuildOptions.Build()
	if err != nil {
		return err
	}

	// append the kubetest2 run id
	// avoid double + in the version
	// so they are valid docker tags
	if strings.Contains(version, "+") {
		version += "-" + d.commonOptions.RunID()
	} else {
		version += "+" + d.commonOptions.RunID()
	}

	// stage build if requested
	if d.BuildOptions.CommonBuildOptions.StageLocation != "" {
		if err := d.BuildOptions.Stage(version); err != nil {
			return fmt.Errorf("error staging build: %v", err)
		}
	}
	build.StoreCommonBinaries(d.RepoRoot, d.commonOptions.RunDir(),
		d.BuildOptions.CommonBuildOptions.TargetBuildArch)
	return nil
}
