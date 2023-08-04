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

	"k8s.io/klog/v2"

	"sigs.k8s.io/provider-aws-test-infra/pkg/deployer/build"
)

func (d *deployer) Build() error {
	klog.V(1).Info("EC2 deployer starting Build()")

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
	build.StoreCommonBinaries(d.RepoRoot, d.commonOptions.RunDir())
	return nil
}
