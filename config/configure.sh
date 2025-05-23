#!/bin/bash

#   Copyright The containerd Authors.

#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at

#       http://www.apache.org/licenses/LICENSE-2.0

#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

set -o xtrace
set -o errexit
set -o nounset
set -o pipefail

if [[ "$(python -V 2>&1)" =~ "Python 2" ]]; then
  # found python2, just use that
  PYTHON="python"
elif [[ -f "/usr/bin/python2.7" ]]; then
  # System python not defaulted to python 2 but using 2.7 during migration
  PYTHON="/usr/bin/python2.7"
else
  # No python2 either by default, let's see if we can find python3
  PYTHON="python3"
  if ! command -v ${PYTHON} >/dev/null 2>&1; then
    echo "ERROR Python not found. Aborting."
    exit 2
  fi
fi
echo "Version : " $(${PYTHON} -V 2>&1)

## sysctl settings (required by Prow to avoid inotify issues)
sysctl -w fs.inotify.max_user_watches=1048576
sysctl -w fs.inotify.max_user_instances=8192

# CONTAINERD_HOME is the directory for containerd.
CONTAINERD_HOME="/home/containerd"
cd "${CONTAINERD_HOME}"
# KUBE_HOME is the directory for kubernetes.
KUBE_HOME="/home/kubernetes"

case $(uname -m) in
	aarch64)	ARCH="arm64";;
	x86_64)		ARCH="amd64";;
	*)		ARCH="$(uname -m)";;
esac

# Install yq to parse some yaml
curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.31.1/yq_linux_${ARCH}.tar.gz |\
  tar xz && mv yq_linux_${ARCH} /usr/local/bin/yq

# fetch_env fetches environment variables from GCE metadata server
# and generate a env file under ${CONTAINERD_HOME}. It assumes that
# the environment variables in metadata are in yaml format.
fetch_env() {
  local -r env_file_name=$1
  (
    umask 077;
    local -r tmp_env_file="/tmp/${env_file_name}.yaml"
    tmp_env_content=$(curl -sSL "$(cat /tmp/bootstrap/extra-fetches.yaml | yq "."${env_file_name}" // \"\"")")
    if [ -z "${tmp_env_content}" ]; then
      echo "No environment variable is specified in ${env_file_name}"
      return
    fi
    echo "${tmp_env_content}" > "${tmp_env_file}"
    # Convert the yaml format file into a shell-style file.
    eval $(${PYTHON} -c '''
import pipes,sys,yaml
# check version of python and call methods appropriate for that version
if sys.version_info[0] < 3:
    items = yaml.load(sys.stdin).iteritems()
else:
    items = yaml.load(sys.stdin, Loader=yaml.BaseLoader).items()
for k,v in items:
  print("readonly {var}={value}".format(var = k, value = pipes.quote(str(v))))
''' < "${tmp_env_file}" > "${CONTAINERD_HOME}/${env_file_name}")
    rm -f "${tmp_env_file}"
  )
}

# is_preloaded checks whether a package has been preloaded in the image.
is_preloaded() {
  local -r tar=$1
  local -r sha1=$2
  grep -qs "${tar},${sha1}" "${KUBE_HOME}/preload_info"
}

# CONTAINERD_ENV_METADATA is the metadata key for containerd envs.
CONTAINERD_ENV_METADATA="containerd-env"
fetch_env ${CONTAINERD_ENV_METADATA}
if [ -f "${CONTAINERD_HOME}/${CONTAINERD_ENV_METADATA}" ]; then
  source "${CONTAINERD_HOME}/${CONTAINERD_ENV_METADATA}"
fi


# CONTAINERD_PKG_PREFIX is the prefix of the cri-containerd tarball name.
# By default use the release tarball with cni built in.
pkg_prefix=${CONTAINERD_PKG_PREFIX:-"cri-containerd-cni"}
# Behave differently for test and production.
if [ "${CONTAINERD_TEST:-"false"}"  != "true" ]; then
    # CONTAINERD_DEPLOY_PATH is the gcs path where cri-containerd tarball is stored.
  deploy_path=${CONTAINERD_DEPLOY_PATH:-"cri-containerd-release"}
  # CONTAINERD_VERSION is the cri-containerd version to use.
  version=${CONTAINERD_VERSION:-""}
else
  deploy_path=${CONTAINERD_DEPLOY_PATH:-"cri-containerd-staging"}
  version=$(set +x; curl -X GET "${HEADERS[@]}" -f --ipv4 --retry 6 --retry-delay 3 --silent --show-error \
    https://storage.googleapis.com/${deploy_path}/latest)
fi

TARBALL_GCS_NAME="${pkg_prefix}-${version}.linux-${ARCH}.tar.gz"
ALT_TARBALL_GCS_NAME="${pkg_prefix}-${version}-linux-${ARCH}.tar.gz"
# TARBALL_GCS_PATH is the path to download cri-containerd tarball for node e2e.
TARBALL_GCS_PATH="https://storage.googleapis.com/${deploy_path}/${TARBALL_GCS_NAME}"
ALT_TARBALL_GCS_PATH="https://storage.googleapis.com/${deploy_path}/${ALT_TARBALL_GCS_NAME}"
# TARBALL is the name of the tarball after being downloaded.
TARBALL="containerd.tar.gz"
# CONTAINERD_TAR_SHA1 is the sha1sum of containerd tarball.
tar_sha1="${CONTAINERD_TAR_SHA1:-""}"

if [ -z "${version}" ]; then
  # Try using preloaded containerd if version is not specified.
  tarball_gcs_pattern="${pkg_prefix}-.*.linux-${ARCH}.tar.gz"
  if is_preloaded "${tarball_gcs_pattern}" "${tar_sha1}"; then
    echo "CONTAINERD_VERSION is not set, use preloaded containerd"
  else
    echo "CONTAINERD_VERSION is not set, and containerd is not preloaded"
    exit 1
  fi
else
  # Download and untar the release tar ball, there are two alternate names for the
  # tar.gz files unfortunately, so this is a temporary respite until the fixes
  # are in place
  $(set +x; curl -X GET "${HEADERS[@]}" -f --ipv4 -Lo "${TARBALL}" --connect-timeout 20 --max-time 300 --retry 6 \
    --retry-delay 10 "${ALT_TARBALL_GCS_PATH}") || \
  $(set +x; curl -X GET "${HEADERS[@]}" -f --ipv4 -Lo "${TARBALL}" --connect-timeout 20 --max-time 300 --retry 6 \
    --retry-delay 10 "${TARBALL_GCS_PATH}")
  tar xvf "${TARBALL}"
  rm -f "${TARBALL}"
  # copy `runc` in ${CONTAINERD_HOME} to a directory in PATH as well
  cp usr/local/sbin/runc /bin/runc || true
fi

# Remove crictl shipped with containerd, use crictl installed
# by kube-up.sh.
rm -f "${CONTAINERD_HOME}/usr/local/bin/crictl"
rm -f "${CONTAINERD_HOME}/etc/crictl.yaml"

# Generate containerd config
config_path="${CONTAINERD_CONFIG_PATH:-"/etc/containerd/config.toml"}"
mkdir -p $(dirname ${config_path})

# Download and configure CNI
cni_template_path="${CONTAINERD_HOME}/opt/containerd/cluster/gce/cni.template"
cni_bin_dir="/opt/cni/bin"

CNI_VERSION=v1.2.0 &&\
mkdir -p ${cni_bin_dir} &&\
curl -fsSL https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz \
    | tar xfz - -C ${cni_bin_dir}

# Use systemd cgroup if specified in env
systemdCgroup="${CONTAINERD_SYSTEMD_CGROUP:-"true"}"

log_level="${CONTAINERD_LOG_LEVEL:-"info"}"
max_container_log_line="${CONTAINERD_MAX_CONTAINER_LOG_LINE:-16384}"
cat > ${config_path} <<EOF
version = 2
# Kubernetes requires the cri plugin.
required_plugins = ["io.containerd.grpc.v1.cri"]
# Kubernetes doesn't use containerd restart manager.
disabled_plugins = ["io.containerd.internal.v1.restart"]

[debug]
  level = "${log_level}"

[plugins."io.containerd.grpc.v1.cri"]
  stream_server_address = "127.0.0.1"
  stream_server_port = "0"
  max_container_log_line_size = ${max_container_log_line}
[plugins."io.containerd.grpc.v1.cri".cni]
  bin_dir = "${cni_bin_dir}"
  conf_dir = "/etc/cni/net.d"
  conf_template = "${cni_template_path}"
[plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
  endpoint = ["https://mirror.gcr.io","https://registry-1.docker.io"]
[plugins."io.containerd.grpc.v1.cri".containerd]
  default_runtime_name = "${CONTAINERD_DEFAULT_RUNTIME:-"runc"}"
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  BinaryName = "${CONTAINERD_HOME}/usr/local/sbin/runc"
  SystemdCgroup = ${systemdCgroup}
EOF
chmod 644 "${config_path}"

# containerd_extra_runtime_handler is the extra runtime handler to install.
containerd_extra_runtime_handler=${CONTAINERD_EXTRA_RUNTIME_HANDLER:-""}
if [[ -n "${containerd_extra_runtime_handler}" ]]; then
  cat >> ${config_path} <<EOF
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.${containerd_extra_runtime_handler}]
  runtime_type = "${CONTAINERD_EXTRA_RUNTIME_TYPE:-io.containerd.runc.v2}"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.${containerd_extra_runtime_handler}.options]
${CONTAINERD_EXTRA_RUNTIME_OPTIONS:-}
EOF
fi

echo "export PATH=${CONTAINERD_HOME}/usr/local/bin/:${CONTAINERD_HOME}/usr/local/sbin/:\$PATH" > \
  /etc/profile.d/containerd_env.sh

# Run extra init script for test.
if [ "${CONTAINERD_TEST:-"false"}"  == "true" ]; then
  # EXTRA_INIT_SCRIPT is the name of the extra init script after being downloaded.
  EXTRA_INIT_SCRIPT="containerd-extra-init.sh"
  extra_init="$(cat /tmp/bootstrap/extra-fetches.yaml | yq '.extra_init // ""')"
  # Return if containerd-extra-init-sh is not set.
  if [ -z "${extra_init}" ]; then
    exit 0
  fi
  extra_init=$(curl -sSL "$(cat /tmp/bootstrap/extra-fetches.yaml | yq .extra_init)")
  echo "${extra_init}" > "${EXTRA_INIT_SCRIPT}"
  chmod 544 "${EXTRA_INIT_SCRIPT}"
  ./${EXTRA_INIT_SCRIPT}
fi
