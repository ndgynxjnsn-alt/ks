#!/usr/bin/env bash
# Downloads kubectl + helm into .bin/ and fetches a kubeconfig that talks to the API through the VIP.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
KUBECTL_VERSION=v1.37.1
HELM_VERSION=v4.3.0

mkdir -p .bin
[ -x .bin/kubectl ] || curl -sfL -o .bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
[ -x .bin/helm ] || curl -sfL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" |
  tar xz -C .bin --strip-components=1 linux-amd64/helm
chmod +x .bin/kubectl .bin/helm

vagrant ssh lgtm1 -c "sudo cat /etc/rancher/rke2/rke2.yaml" 2>/dev/null |
  sed "s#https://127.0.0.1:6443#https://${VIP}:6443#" >kubeconfig
chmod 600 kubeconfig
kubectl get nodes -o wide
