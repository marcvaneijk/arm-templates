#!/bin/bash

# Arguments
UNIQUE_STRING=$1
CONTROLPLANE_IP="$2:6443"
ADMIN_USERNAME=$3
POD_SUBNET="10.244.0.0/16"
# Original overlay YAML has an issue with 1.16 (needs cniVersion 0.2.0). Once source repo is updated remove temp overlay path
# OVERLAY_CONF="https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml"
OVERLAY_CONF="https://raw.githubusercontent.com/marcvaneijk/flannel/master/Documentation/kube-flannel.yml"
KUBEADM_CONF="kubeadm_config.yaml"
# Generate a 32 byte key from the unique string
CERTIFICATE_KEY=$(echo $UNIQUE_STRING | xxd -p -c 32 -l 32)
# Generate the bootstrap token from the unique string
# [a-z0-9]{6}\.[a-z0-9]{16}
BOOTSTRAP_TOKEN="${UNIQUE_STRING:0:6}"."${UNIQUE_STRING:6:16}"

# Installation
echo "===== update package database ====="
sudo apt-get update \
  && echo "## Pass: updated package database" \
  || { echo "## Fail: failed to update package database" ; exit 1 ; }

echo "===== install prereq packages ====="
sudo apt-get install -y apt-transport-https curl \
  && echo "## Pass: prereq packages installed" \
  || { echo "## Fail: failed to install prereq packages" ; exit 1 ; }

echo "===== install Docker ====="
sudo apt-get install -y docker.io \
  && echo "## Pass: installed docker" \
  || { echo "## Fail: failed to install docker" ; exit 1 ; }

echo "===== add gpg key for Google ====="
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add - \
  && echo "## Pass: added GPG key for Google repository" \
  || { echo "## Fail: failed to add GPG key for Google repository" ; exit 1 ; }

echo "===== add Kubernetes repository ====="
cat << EOF | sudo tee -a /etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF

echo "===== update package database ====="
sudo apt-get update \
  && echo "## Pass: updated package database" \
  || { echo "## Fail: failed to update package database" ; exit 1 ; }

## Needed for flannel?
echo "net.bridge.bridge-nf-call-iptables = 1" >> /etc/sysctl.conf
echo "net.bridge.bridge-nf-call-ip6tables = 1" >> /etc/sysctl.conf
/sbin/sysctl -p /etc/sysctl.conf

echo "===== install Kubernetes components ====="
sudo apt-get install -y kubelet kubeadm kubectl \
  && echo "## Pass: Install Kubernetes components" \
  || { echo "## Fail: failed to install Kubernetes components" ; exit 1 ; }

# Fix warning 1
sudo systemctl enable docker.service \
  && echo "## Pass: Apply fix for kubeadm init warning" \
  || { echo "## Fail: failed to apply fix for kubeadm init warning" ; exit 1 ; }

# Fix warning 2
cat << EOF | sudo tee -a /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

sudo mkdir -p /etc/systemd/system/docker.service.d \
  && echo "## Pass: Apply fix for kubeadm init warning" \
  || { echo "## Fail: failed to apply fix for kubeadm init warning" ; exit 1 ; }

sudo systemctl daemon-reload \
  && echo "## Pass: reload daemon" \
  || { echo "## Fail: failed to reload daemon" ; exit 1 ; }

sudo systemctl restart docker \
  && echo "## Pass: restart docker" \
  || { echo "## Fail: failed to restart docker" ; exit 1 ; }

echo "===== Creating the cluster ====="

cat <<EOF >${KUBEADM_CONF}
apiVersion: kubeadm.k8s.io/v1beta2
kind: InitConfiguration
bootstrapTokens:
- groups:
  - system:bootstrappers:kubeadm:default-node-token
  token: "${BOOTSTRAP_TOKEN}"
  ttl: 24h0m0s
  usages:
  - signing
  - authentication
certificateKey: "${CERTIFICATE_KEY}"
---
apiVersion: kubeadm.k8s.io/v1beta2
kind: ClusterConfiguration
networking:
  podSubnet: "${POD_SUBNET}"
kubernetesVersion: "stable"
controlPlaneEndpoint: "${CONTROLPLANE_IP}"
EOF

sudo kubeadm init --config ${KUBEADM_CONF} --upload-certs \
  && echo "## Pass: Initiale Kubenetes cluster" \
  || { echo "## Fail: failed to initialize Kubernetes cluster" ; exit 1 ; }

# Apply network overlay
sudo kubectl apply -f ${OVERLAY_CONF} --kubeconfig /etc/kubernetes/admin.conf \
  && echo "## Pass: Applied network overlay" \
  || { echo "## Fail: failed to apply network overlay" ; exit 1 ; }

echo "===== Copy conf files to user context ====="

mkdir -p /home/$ADMIN_USERNAME/.kube \
  && echo "## Pass: Create .kube folder in home dir" \
  || { echo "## Fail: failed to create .kube folder in home dir" ; exit 1 ; }

sudo cp -T -v /etc/kubernetes/admin.conf /home/$ADMIN_USERNAME/.kube/config \
  && echo "## Pass: Copy admin.conf to .kube" \
  || { echo "## Fail: failed to copy admin.conf to .kube" ; exit 1 ; }

sudo chown $(id -u $ADMIN_USERNAME):$(id -g $ADMIN_USERNAME) /home/$ADMIN_USERNAME/.kube/config \
  && echo "## Pass: Set permissions on .kube/config folder" \
  || { echo "## Fail: failed to set permissions on .kube/config folder" ; exit 1 ; }