#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── 1. Create Kind cluster ────────────────────────────────────────────────────
echo "==> Creating Kind cluster..."
kind create cluster --config "${REPO_ROOT}/infra/kind-config.yaml"

# ── 2. Gateway API CRDs (must be installed before Istio) ─────────────────────
echo "==> Installing Gateway API CRDs (v1.2.1)..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

# ── 3. Istio (ambient profile) ────────────────────────────────────────────────
echo "==> Installing Istio (ambient profile)..."
istioctl install -f "${REPO_ROOT}/istio/ambient-profile.yaml" -y

# ── 4. Kiali + Prometheus (observability) ────────────────────────────────────
# Prometheus must be installed before Kiali (Kiali uses it as a metrics source).
echo "==> Installing Prometheus addon..."
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/addons/prometheus.yaml

echo "==> Installing Kiali addon..."
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/addons/kiali.yaml

echo "==> Waiting for Kiali to be ready..."
kubectl rollout status -n istio-system deployment/kiali --timeout=120s

# ── 5. MetalLB ────────────────────────────────────────────────────────────────
echo "==> Installing MetalLB (v0.14.9)..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml

echo "==> Waiting for MetalLB controller to be ready..."
kubectl rollout status -n metallb-system deployment/controller --timeout=90s

# Auto-detect the Docker 'kind' bridge IPv4 subnet (skip IPv6 entries)
KIND_SUBNET=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' | grep -v ":" | head -1)
# Extract the first two octets of the subnet to build the LB pool range
PREFIX=$(echo "${KIND_SUBNET}" | cut -d. -f1,2)
LB_RANGE="${PREFIX}.255.200-${PREFIX}.255.250"
echo "==> Configuring MetalLB IP pool: ${LB_RANGE}"

kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
    - ${LB_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - kind-pool
EOF

# ── 6. Central Gateway (ingress entry point) ──────────────────────────────────
echo "==> Applying central Gateway (bookinfo-gateway)..."
kubectl apply -f "${REPO_ROOT}/infra/central-gateway.yaml"
kubectl wait gateway/bookinfo-gateway -n istio-system \
  --for=condition=Programmed --timeout=60s

echo ""
echo "==> Cluster setup complete."
echo "    Nodes:"
kubectl get nodes -o wide
