#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── 1. bookinfo-nomesh ────────────────────────────────────────────────────────
echo "==> Deploying bookinfo-nomesh (no mesh)..."
kubectl apply -f "${REPO_ROOT}/apps/nomesh-bookinfo.yaml"

# ── 2. bookinfo-sidecar ───────────────────────────────────────────────────────
echo "==> Deploying bookinfo-sidecar (Envoy sidecars)..."
kubectl apply -f "${REPO_ROOT}/apps/sidecar-bookinfo.yaml"

# ── Wait for rollouts ─────────────────────────────────────────────────────────
for ns in bookinfo-nomesh bookinfo-sidecar; do
  echo "==> Waiting for rollout in ${ns}..."
  kubectl rollout status deployment -n "${ns}" --timeout=120s
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "==> nomesh + sidecar namespaces are ready."
echo ""
for ns in bookinfo-nomesh bookinfo-sidecar; do
  echo "  [${ns}]"
  kubectl get pods -n "${ns}" -o wide --no-headers | sed 's/^/    /'
  echo ""
done

echo "LoadBalancer IPs (productpage):"
for ns in bookinfo-nomesh bookinfo-sidecar; do
  IP=$(kubectl get svc productpage -n "${ns}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "<pending>")
  echo "  ${ns}: http://${IP}:9080/productpage"
done

# ── HTTPRoutes for nomesh + sidecar ─────────────────────────────────────────
echo "==> Applying HTTPRoutes for nomesh and sidecar..."
kubectl apply -f "${REPO_ROOT}/infra/ingress-routes.yaml"

echo ""
echo "================================================================="
echo "  DEMO PAUSE — Show Kiali"
echo "  Traffic flows but there are no mTLS lock icons."
echo "  Run:  kubectl port-forward -n istio-system svc/kiali 20001:20001"
echo "  Open: http://localhost:20001"
echo "  Gateway (port-forward on :8080):"
echo "    http://localhost:8080/nomesh/productpage"
echo "    http://localhost:8080/sidecar/productpage"
echo "================================================================="
