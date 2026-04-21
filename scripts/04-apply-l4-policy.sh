#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NS="bookinfo-ambient-l4"
CURL_MANIFEST="${REPO_ROOT}/apps/curl-review-l4.yaml"
POLICY_MANIFEST="${REPO_ROOT}/policies/l4-whitelist-reviews.yaml"

# ── --remove flag ─────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--remove" ]]; then
  echo "==> Removing L4 policy and curl-review pod..."
  kubectl delete -f "${POLICY_MANIFEST}" --ignore-not-found
  kubectl delete -f "${CURL_MANIFEST}" --ignore-not-found
  echo "  Done."
  exit 0
fi

# ── 1. Deploy curl-review pod ────────────────────────────────────────────────
echo "==> Deploying curl-review pod in ${NS}..."
kubectl delete -f "${CURL_MANIFEST}" --ignore-not-found >/dev/null 2>&1 || true
kubectl apply -f "${CURL_MANIFEST}"
kubectl wait pod/curl-review -n "${NS}" --for=condition=Ready --timeout=30s
echo "  curl-review pod is running."
echo ""

# ── 2. Show pre-policy baseline (expect 200s) ────────────────────────────────
echo "==> Pre-policy baseline (should see Status: 200)..."
sleep 3
kubectl logs curl-review -n "${NS}" --tail=5
echo ""

# ── 3. Apply L4 authorization policy ─────────────────────────────────────────
echo "==> Applying L4 whitelist authorization policy..."
kubectl apply -f "${POLICY_MANIFEST}"
echo ""
echo "  Policy details:"
kubectl get authorizationpolicy -n "${NS}" whitelist-reviews-l4 \
  -o custom-columns='NAME:.metadata.name,ACTION:.spec.action,NAMESPACE:.metadata.namespace'
echo ""

# ── 4. Wait for ztunnel to propagate the policy ──────────────────────────────
echo "==> Waiting 5s for ztunnel to propagate the policy..."
sleep 5
echo ""

# ── 5. Check curl-review logs for L4 denial ──────────────────────────────────
echo "==> Post-policy curl-review logs (expect Status: 503 or Status: 000)..."
LOGS=$(kubectl logs curl-review -n "${NS}" --tail=10 2>/dev/null)
echo "${LOGS}"
echo ""

# ── 6. Assert denial ─────────────────────────────────────────────────────────
# ztunnel L4 denial produces 503 or 000 (TCP reset) depending on Istio version
if echo "${LOGS}" | grep -qE 'Status: (503|000)'; then
  echo "================================================================="
  echo "  [PASS] L4 policy enforced — curl-review (default SA) blocked"
  echo "  Policy : whitelist-reviews-l4  (namespace: ${NS})"
  echo "  Layer  : ztunnel — SPIFFE / mTLS principal enforcement"
  echo "  Rule   : only bookinfo-productpage SA may reach reviews"
  echo "================================================================="
else
  echo "================================================================="
  echo "  [FAIL] Expected Status: 503 or 000 but did not find it in logs"
  echo "  Policy : whitelist-reviews-l4  (namespace: ${NS})"
  echo "================================================================="
  exit 1
fi
