#!/bin/bash
set -o xtrace
set -xeuo pipefail

echo "testing!"

if [ "$(uname -m)" = "arm64" ] || [ "$(uname -m)" = "aarch64" ]; then
  ARCH=arm64
else
  ARCH=amd64
fi

# Fix issues with no networking from pods
sed -i "s/^MACAddressPolicy=.*/MACAddressPolicy=none/" /usr/lib/systemd/network/99-default.link
systemctl restart systemd-resolved

mkdir -p /etc/kubernetes/
cat << EOF > /etc/kubernetes/kubeadm-join.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: {{KUBEADM_CONTROL_PLANE_IP}}:6443
    token: {{KUBEADM_TOKEN}}
    unsafeSkipCAVerification: true
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  name: {{HOSTNAME_OVERRIDE}}
  kubeletExtraArgs:
    cloud-provider: {{EXTERNAL_CLOUD_PROVIDER}}
    provider-id: {{PROVIDER_ID}}
    node-ip: {{NODE_IP}}
    hostname-override: {{HOSTNAME_OVERRIDE}}
    image-credential-provider-bin-dir: /etc/eks/image-credential-provider/
    image-credential-provider-config: /etc/eks/image-credential-provider/config.json
    resolv-conf: /etc/resolv.conf
EOF

TOKEN=$(curl --request PUT "http://169.254.169.254/latest/api/token" --header "X-aws-ec2-metadata-token-ttl-seconds: 3600" -s)
META_URL=http://169.254.169.254/latest/meta-data
AVAILABILITY_ZONE=$(curl -s $META_URL/placement/availability-zone --header "X-aws-ec2-metadata-token: $TOKEN")
INSTANCE_ID=$(curl -s $META_URL/instance-id --header "X-aws-ec2-metadata-token: $TOKEN")
PROVIDER_ID="aws:///$AVAILABILITY_ZONE/$INSTANCE_ID"
PRIVATE_DNS_NAME=$(curl -s $META_URL/hostname --header "X-aws-ec2-metadata-token: $TOKEN")
NODE_IP=$(curl -s $META_URL/local-ipv4 --header "X-aws-ec2-metadata-token: $TOKEN")

sed -i "s|{{PROVIDER_ID}}|$PROVIDER_ID|g" /etc/kubernetes/kubeadm-join.yaml
sed -i "s|{{HOSTNAME_OVERRIDE}}|$PRIVATE_DNS_NAME|g" /etc/kubernetes/kubeadm-join.yaml
sed -i "s|{{NODE_IP}}|$NODE_IP|g" /etc/kubernetes/kubeadm-join.yaml

# Ensure references to the instance id are resolved properly
echo "$(curl -s -f -m 1 --header "X-aws-ec2-metadata-token: $TOKEN" $META_URL/local-ipv4) $(curl -s -f -m 1 --header "X-aws-ec2-metadata-token: $TOKEN" $META_URL/instance-id/)" | sudo tee -a /etc/hosts

VERSION="v1.28.0"
curl -sSL --fail --retry 5 https://storage.googleapis.com/k8s-artifacts-cri-tools/release/$VERSION/crictl-$VERSION-linux-$ARCH.tar.gz | sudo tar -xvzf - -C /usr/local/bin

RELEASE_VERSION="v0.16.4"
curl -sSL "https://raw.githubusercontent.com/kubernetes/release/${RELEASE_VERSION}/cmd/krel/templates/latest/kubelet/kubelet.service" | sed "s:/usr/bin:/bin:g" | sudo tee /etc/systemd/system/kubelet.service
sudo mkdir -p /etc/systemd/system/kubelet.service.d
curl -sSL "https://raw.githubusercontent.com/kubernetes/release/${RELEASE_VERSION}/cmd/krel/templates/latest/kubeadm/10-kubeadm.conf" | sed "s:/usr/bin:/bin:g" | sudo tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
systemctl enable --now kubelet

# shellcheck disable=SC2050
if [[ "{{STAGING_BUCKET}}" =~ ^s3.*  ]]; then
  aws s3 cp "{{STAGING_BUCKET}}/{{STAGING_VERSION}}/kubernetes-server-linux-$ARCH.tar.gz" "kubernetes-server-linux-$ARCH.tar.gz"
elif [[ "{{STAGING_BUCKET}}" =~ ^https.*  ]]; then
  curl -sSLo kubernetes-server-linux-$ARCH.tar.gz --fail --retry 5 "{{STAGING_BUCKET}}/{{STAGING_VERSION}}/kubernetes-server-linux-$ARCH.tar.gz"
else
  aws s3 cp "s3://{{STAGING_BUCKET}}/{{STAGING_VERSION}}/kubernetes-server-linux-$ARCH.tar.gz" "kubernetes-server-linux-$ARCH.tar.gz"
fi

tar -xvzf kubernetes-server-linux-$ARCH.tar.gz
cp ./kubernetes/server/bin/* /usr/local/bin/

cp /etc/eks/containerd/containerd-config.toml /etc/containerd/config.toml
# rewrite the pause image url
sed -i'' 's#SANDBOX_IMAGE#registry.k8s.io/pause:3.8#' /etc/containerd/config.toml
systemctl start containerd

# shellcheck disable=SC2038
find . -name "*.tar" -print | xargs -L 1 ctr -n k8s.io images import
# shellcheck disable=SC2016
ctr -n k8s.io images ls -q | grep -e $ARCH | xargs -L 1 -I '{}' /bin/bash -c 'ctr -n k8s.io images tag "{}" "$(echo "{}" | sed s/-'$ARCH':/:/)"'

# shellcheck disable=SC2155
export PATH=$PATH:/usr/local/bin

kubeadm join \
   --v 10 \
   --config /etc/kubernetes/kubeadm-join.yaml