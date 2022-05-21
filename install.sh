#!/usr/bin/env bash

############
# by xwjh.
############

set -e

type curl >/dev/null 2>&1 || (
    echo 'no curl command.'
    exit 1
)

install_jq() {
    jq_tag=$(curl https://api.github.com/repos/stedolan/jq/releases/latest | grep '  "tag_name": ' | awk -F'"' '{print $4}') &&
        curl -sSL "https://github.com/stedolan/jq/releases/download/${jq_tag}/jq-linux64" -o /usr/local/bin/jq &&
        chmod +x /usr/local/bin/jq
}

install_containerd() {
    containerd_tag=$(curl -sSL https://api.github.com/repos/containerd/containerd/releases/latest | jq -r '.tag_name')
    containerd_file=cri-containerd-cni-${containerd_tag:1}-linux-amd64.tar.gz
    test -e ${containerd_file} || curl -sSL https://github.com/containerd/containerd/releases/download/${containerd_tag}/${containerd_file} -o ${containerd_file}
    test -e ${containerd_file} && tar -xzf ${containerd_file} -C /
}

install_runc() {
    runc_tag=$(curl -sSL https://api.github.com/repos/opencontainers/runc/releases/latest | jq -r '.tag_name')
    curl -sSL https://github.com/opencontainers/runc/releases/download/${runc_tag}/runc.amd64 -o /usr/local/sbin/runc
    chmod +x /usr/local/sbin/runc
}

init_system() {
    # 启用cgoup v2
    cat /sys/fs/cgroup/cgroup.controllers || grubby --update-kernel=ALL --args="systemd.unified_cgroup_hierarchy=1"

    # 使用 containerd 作为 CRI 运行时的必要步骤
    cat <<EOF | tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

    modprobe overlay
    modprobe br_netfilter

    # 设置必需的 sysctl 参数，这些参数在重新启动后仍然存在。
    cat <<EOF | tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

    mkdir -p /etc/containerd
    containerd config default | tee /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    # 应用 sysctl 参数而无需重新启动
    sysctl --system
    systemctl enable --now containerd.service
}

install_k8s() {
    CNI_VERSION=$(curl -sSL https://api.github.com/repos/containernetworking/plugins/releases/latest | jq -r '.tag_name')
    CRICTL_VERSION=$(curl -sSL https://api.github.com/repos/kubernetes-sigs/cri-tools/releases/latest | jq -r '.tag_name')
    RELEASE_VERSION=$(curl -sSL https://api.github.com/repos/kubernetes/release/releases/latest | jq -r '.tag_name')
    mkdir -p /opt/cni/bin
    curl -L "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz" | tar -C /opt/cni/bin -xz

    # 安装 crictl（kubeadm/kubelet 容器运行时接口（CRI）所需）
    DOWNLOAD_DIR=/usr/local/bin
    mkdir -p $DOWNLOAD_DIR
    curl -L "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" | tar -C $DOWNLOAD_DIR -xz

    # 安装 kubeadm、kubelet、kubectl 并添加 kubelet 系统服务
    RELEASE="$(curl -sSL https://dl.k8s.io/release/stable.txt)"
    cd $DOWNLOAD_DIR
    curl -L --remote-name-all https://storage.googleapis.com/kubernetes-release/release/${RELEASE}/bin/linux/amd64/{kubeadm,kubelet,kubectl}
    chmod +x {kubeadm,kubelet,kubectl}

    curl -sSL "https://raw.githubusercontent.com/kubernetes/release/${RELEASE_VERSION}/cmd/kubepkg/templates/latest/deb/kubelet/lib/systemd/system/kubelet.service" | sed "s:/usr/bin:${DOWNLOAD_DIR}:g" | tee /etc/systemd/system/kubelet.service
    mkdir -p /etc/systemd/system/kubelet.service.d
    curl -sSL "https://raw.githubusercontent.com/kubernetes/release/${RELEASE_VERSION}/cmd/kubepkg/templates/latest/deb/kubeadm/10-kubeadm.conf" | sed "s:/usr/bin:${DOWNLOAD_DIR}:g" | tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
    systemctl enable kubelet.service
    kubectl completion bash >/etc/bash_completion.d/kubectl
    source /etc/bash_completion.d/kubectl
    cat >kubeadm.yaml <<EOF
---
apiServer:
  timeoutForControlPlane: 4m0s
apiVersion: kubeadm.k8s.io/v1beta3
certificatesDir: /etc/kubernetes/pki
clusterName: kubernetes
imageRepository: k8s.gcr.io
kind: ClusterConfiguration
networking:
  dnsDomain: cluster.local
  podSubnet: 100.64.0.0/10
  serviceSubnet: 10.96.0.0/12
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: "ipvs"
EOF
    kubeadm init --config kubeadm.yaml --upload-certs
}

type jq || install_jq
type containerd || install_containerd
# install_runc
runc -v >/dev/null 2>&1 || install_runc

init_system
install_k8s
