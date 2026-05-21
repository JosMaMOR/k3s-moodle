#!/bin/bash
set -e
K3S_VERSION="v1.29.4+k3s1"
NODE_IP=$(hostname -I | awk '{print $1}')
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION sh -s - server --write-kubeconfig-mode 644 --tls-san $NODE_IP --tls-san mcc.tesoem.edu.mx --node-name k3s-moodle-master --disable servicelb --disable traefik
mkdir -p ~/.kube && cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && chmod 600 ~/.kube/config
export KUBECONFIG=~/.kube/config
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc
kubectl wait --for=condition=ready node --all --timeout=300s
echo "Instalando HELM con script oficial"
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh

helm repo add traefik https://traefik.github.io/charts && helm repo update
helm install traefik traefik/traefik --namespace kube-system --set ports.web.port=8000 --set ports.websecure.port=8443 --set service.type=NodePort --set "service.nodePorts.web=30080" --set "service.nodePorts.websecure=30443" --wait
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'
kubectl label node k3s-moodle-master storage-type=raid-local --overwrite
echo "K3s instalado."
