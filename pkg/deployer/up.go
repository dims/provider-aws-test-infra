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

package deployer

import (
	"fmt"
	"os"
	osexec "os/exec"
	"path/filepath"

	"k8s.io/klog/v2"
	"sigs.k8s.io/kubetest2/pkg/exec"
)

func (d *deployer) IsUp() (up bool, err error) {
	args := []string{
		d.kubectlPath,
		"get",
		"nodes",
		"-o=name",
	}
	cmd := exec.Command(args[0], args[1:]...)
	cmd.SetStderr(os.Stderr)
	lines, err := exec.OutputLines(cmd)
	if err != nil {
		return false, fmt.Errorf("is up failed to get nodes: %s", err)
	}

	return len(lines) > 0, nil
}

func (d *deployer) Up() error {
	klog.V(1).Info("EC2 deployer starting Up()")

	path, err := d.verifyKubectl()
	if err != nil {
		return err
	}
	d.kubectlPath = path

	return nil
}

// verifyKubectl checks if kubectl exists in kubetest2 artifacts or PATH
// returns the path to the binary, error if it doesn't exist
// kubectl detection using legacy verify-get-kube-binaries is unreliable
// https://github.com/kubernetes/kubernetes/blob/b10d82b93bad7a4e39b9d3f5c5e81defa3af68f0/cluster/kubectl.sh#L25-L26
func (d *deployer) verifyKubectl() (string, error) {
	klog.V(2).Infof("checking locally built kubectl ...")
	localKubectl := filepath.Join(d.commonOptions.RunDir(), "kubectl")
	if _, err := os.Stat(localKubectl); err == nil {
		return localKubectl, nil
	}
	klog.V(2).Infof("could not find locally built kubectl, checking existence of kubectl in $PATH ...")
	kubectlPath, err := osexec.LookPath("kubectl")
	if err != nil {
		return "", fmt.Errorf("could not find kubectl in $PATH, please ensure your environment has the kubectl binary")
	}
	return kubectlPath, nil
}
