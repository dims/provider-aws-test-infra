/*
Copyright 2021 The Kubernetes Authors.

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

// Package deployer implements the kubetest2 ec2 deployer
package deployer

import (
	"flag"
	"os"
	"path/filepath"

	"github.com/octago/sflags/gen/gpflag"
	"github.com/spf13/pflag"

	"k8s.io/klog/v2"

	"sigs.k8s.io/kubetest2/pkg/build"
	"sigs.k8s.io/kubetest2/pkg/types"
	"sigs.k8s.io/provider-aws-test-infra/pkg/deployer/options"
)

// Name is the name of the deployer
const Name = "ec2"

var GitTag string

// New implements deployer.New for ec2
func New(opts types.Options) (types.Deployer, *pflag.FlagSet) {
	// create a deployer object and set fields that are not flag controlled
	d := &deployer{
		commonOptions: opts,
		BuildOptions: &options.BuildOptions{
			CommonBuildOptions: &build.Options{
				Builder:  &build.MakeBuilder{},
				Stager:   &build.NoopStager{},
				Strategy: "make",
			},
		},
		Ec2InstanceConnect: true,
		InstanceType:       "t3a.medium",
	}
	// register flags and return
	return d, bindFlags(d)
}

// assert that New implements types.NewDeployer
var _ types.NewDeployer = New

type deployer struct {
	// generic parts
	commonOptions types.Options

	BuildOptions *options.BuildOptions

	kubectlPath string

	KubeconfigPath string `flag:"kubeconfig" desc:"Absolute path to existing kubeconfig for cluster"`
	RepoRoot       string `desc:"The path to the root of the local kubernetes/kubernetes repo."`

	Region             string `desc:"AWS region that the hosts live in (aws)"`
	UserDataFile       string `desc:"Path to user data to pass to created instances (aws)"`
	InstanceProfile    string `desc:"The name of the instance profile to assign to the node (aws)"`
	Ec2InstanceConnect bool   `desc:"Use EC2 instance connect to generate a one time use key (aws)"`
	InstanceType       string `desc:"EC2 Instance type to use for test"`
}

func (d *deployer) Down() error {
	return nil
}

func (d *deployer) DumpClusterLogs() error {
	return nil
}

func (d *deployer) Kubeconfig() (string, error) {
	// noop deployer is specifically used with an existing cluster and KUBECONFIG
	if d.KubeconfigPath != "" {
		return d.KubeconfigPath, nil
	}
	if kconfig, ok := os.LookupEnv("KUBECONFIG"); ok {
		return kconfig, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".kube", "config"), nil
}

func (d *deployer) Version() string {
	return GitTag
}

// helper used to create & bind a flagset to the deployer
func bindFlags(d *deployer) *pflag.FlagSet {
	flags, err := gpflag.Parse(d)
	if err != nil {
		klog.Fatalf("unable to generate flags from deployer")
		return nil
	}

	klog.InitFlags(nil)
	flags.AddGoFlagSet(flag.CommandLine)

	return flags
}

// assert that deployer implements types.DeployerWithKubeconfig
var _ types.DeployerWithKubeconfig = &deployer{}