#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NS="bookinfo-ambient-l7"
CURL_MANIFEST="${REPO_ROOT}/apps/curl-details-l7.yaml"
POLICY_MANIFEST="${REPO_ROOT}/policies/l7-deny-details.yaml"

# ── --remove flag ─────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--remove" ]]; then
  echo "==> Removing L7 policy and curl-details pod..."
  kubectl delete -f "${POLICY_MANIFEST}" --ignore-not-found
  kubectl delete -f "${CURL_MANIFEST}" --ignore-not-found
  echo "  Done."
  exit 0
fi

# ── 1. Deploy curl-review pod ────────────────────────────────────────────────
echo "==> Deploying curl-details pod in ${NS}..."
kubectl delete -f "${CURL_MANIFEST}" --ignore-not-found >/dev/null 2>&1 || true
kubectl apply -f "${CURL_MANIFEST}"
kubectl wait pod/curl-details -n "${NS}" --for=condition=Ready --timeout=30s
echo "  curl-details pod is running."
echo ""

# ── 2. Show pre-policy baseline (expect 200s) ────────────────────────────────
echo "==> Pre-policy baseline (should see Status: 200)..."
sleep 3
kubectl logs curl-details -n "${NS}" --tail=5
echo ""

# ── 3. Apply L7 deny policy ──────────────────────────────────────────────────
echo "==> Applying L7 deny authorization policy for details..."
kubectl apply -f "${POLICY_MANIFEST}"
echo ""
echo "  Policy details:"
kubectl get authorizationpolicy -n "${NS}" deny-details-l7 \
  -o custom-columns='NAME:.metadata.name,ACTION:.spec.action,NAMESPACE:.metadata.namespace'
echo ""

# ── 4. Wait for the waypoint to reload the policy ────────────────────────────
echo "==> Waiting 5s for reviews-waypoint to reload the L7 policy..."
sleep 5
echo ""

# ── 5. Check curl-details logs for L7 denial ──────────────────────────────────
# The policy denies all traffic to the details Service via the waypoint,
# so every request to details should return 403.
echo "==> Post-policy curl-details logs (expect Status: 403)..."
sleep 5
LOGS=$(kubectl logs curl-details -n "${NS}" --tail=10 2>/dev/null)
echo "${LOGS}"
echo ""

# ── 6. Assert denial ─────────────────────────────────────────────────────────
if echo "${LOGS}" | grep -q 'Status: 403'; then
  echo "================================================================="
  echo "  [PASS] L7 policy enforced — details denied with 403"
  echo "  Policy : deny-details-l7  (namespace: ${NS})"
  echo "  Layer  : reviews-waypoint — HTTP-layer DENY enforcement"
  echo "  Rule   : all traffic to details is denied (HTTP 403)"
  echo "================================================================="
else
  echo "================================================================="
  echo "  [FAIL] Expected Status: 403 but did not find it in logs"
  echo "  Policy : deny-details-l7  (namespace: ${NS})"
  echo "  Hint   : check that the reviews-waypoint is active."
  echo "================================================================="
  exit 1
fi
