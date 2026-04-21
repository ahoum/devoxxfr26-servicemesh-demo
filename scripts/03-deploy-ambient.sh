#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── 0. Enable ztunnel (deferred from initial install) ─────────────────────────
echo "==> Enabling ztunnel DaemonSet..."
istioctl install -f "${REPO_ROOT}/istio/ambient-profile.yaml" \
  --set components.ztunnel.enabled=true -y
kubectl rollout status -n istio-system daemonset/ztunnel --timeout=60s
echo "    ztunnel is ready."
echo ""

# ── Enroll traffic-generator into ambient (now that ztunnel exists) ─────────────
echo "==> Enrolling traffic-generator namespace into ambient..."
kubectl label namespace traffic-generator istio.io/dataplane-mode=ambient --overwrite
echo "    curl-product will now have a SPIFFE identity in Kiali."
echo ""

# ── 1. bookinfo-ambient-l4 ────────────────────────────────────────────────────
echo "==> Deploying bookinfo-ambient-l4 (ztunnel L4 only)..."
kubectl apply -f "${REPO_ROOT}/apps/l4-ambient.yaml"

# ── 2. bookinfo-ambient-l7 ────────────────────────────────────────────────────
echo "==> Deploying bookinfo-ambient-l7 (ztunnel + Waypoint)..."
# waypoint.yaml first: Namespace, Gateway, and Services must exist before Deployments
kubectl apply -f "${REPO_ROOT}/istio/waypoint.yaml"
kubectl apply -f "${REPO_ROOT}/apps/l7-ambient.yaml"

# ── Wait for rollouts ─────────────────────────────────────────────────────────
for ns in bookinfo-ambient-l4 bookinfo-ambient-l7; do
  echo "==> Waiting for rollout in ${ns}..."
  kubectl rollout status deployment -n "${ns}" --timeout=120s
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "==> Ambient namespaces are ready."
echo ""
for ns in bookinfo-ambient-l4 bookinfo-ambient-l7; do
  echo "  [${ns}]"
  kubectl get pods -n "${ns}" -o wide --no-headers | sed 's/^/    /'
  echo ""
done

echo "LoadBalancer IPs (productpage):"
for ns in bookinfo-ambient-l4 bookinfo-ambient-l7; do
  IP=$(kubectl get svc productpage -n "${ns}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "<pending>")
  echo "  ${ns}: http://${IP}:9080/productpage"
done

# ── HTTPRoutes (ambient routes already applied in 02, this is idempotent) ────
echo "==> Refreshing HTTPRoutes (adds ambient routes)..."
kubectl apply -f "${REPO_ROOT}/infra/ingress-routes.yaml"

echo ""
echo "================================================================="
echo "  DEMO PAUSE — Refresh Kiali"
echo "  Ambient mTLS lock icons now visible on L4 + L7 (Waypoint) traffic."
echo "  Run:  kubectl port-forward -n istio-system svc/kiali 20001:20001"
echo "  Open: http://localhost:20001"
echo "  Gateway (port-forward on :8080):"
echo "    http://localhost:8080/nomesh/productpage"
echo "    http://localhost:8080/sidecar/productpage"
echo "    http://localhost:8080/l4/productpage"
echo "    http://localhost:8080/l7/productpage"
echo "================================================================="
