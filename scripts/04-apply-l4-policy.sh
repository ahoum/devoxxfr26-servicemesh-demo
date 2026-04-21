#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NS="bookinfo-ambient-l7"
PASS_COUNT=0
FAIL_COUNT=0
# Unique suffix to avoid pod name collisions on re-runs
RUN_ID="$$"

pass() { echo "  [PASS] $*"; (( PASS_COUNT++ )) || true; }
fail() { echo "  [FAIL] $*"; (( FAIL_COUNT++ )) || true; }

# ── Cleanup trap ──────────────────────────────────────────────────────────────
cleanup() {
  kubectl delete pod "test-l4-allow-${RUN_ID}" "test-l4-deny-${RUN_ID}" \
    -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ── Helper: run a one-shot curl pod and return the HTTP status code ───────────
# Usage: run_curl_test <pod-name> <service-account> <url>
run_curl_test() {
  local pod_name="$1"
  local sa="$2"
  local url="$3"

  kubectl run "${pod_name}" \
    --image=curlimages/curl:8.11.0 \
    --restart=Never \
    -n "${NS}" \
    --serviceaccount="${sa}" \
    -- curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${url}" \
    >/dev/null 2>&1

  # Poll until the pod completes (max 30s)
  for _ in $(seq 1 30); do
    local phase
    phase=$(kubectl get pod "${pod_name}" -n "${NS}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    [[ "${phase}" == "Succeeded" || "${phase}" == "Failed" ]] && break
    sleep 1
  done

  local code
  code=$(kubectl logs "${pod_name}" -n "${NS}" 2>/dev/null | tr -d '[:space:]')
  echo "${code:-000}"
}

# ── 1. Apply L4 authorization policy ─────────────────────────────────────────
echo "==> Applying L4 whitelist authorization policy..."
kubectl apply -f "${REPO_ROOT}/policies/l4-whitelist-reviews.yaml"
echo ""
echo "  Policy details:"
kubectl get authorizationpolicy -n "${NS}" whitelist-reviews-l4 \
  -o custom-columns='NAME:.metadata.name,ACTION:.spec.action,NAMESPACE:.metadata.namespace'
echo ""

# ── 2. Wait for ztunnel to propagate the policy ───────────────────────────────
echo "==> Waiting 5s for policy to propagate to ztunnel / waypoint..."
sleep 5
echo ""

# ── 3. Test ALLOW — bookinfo-productpage SA → reviews ────────────────────────
echo "--- Test 1: ALLOW — pod with bookinfo-productpage SA → reviews ---"
echo "  Launching test pod (SA: bookinfo-productpage)..."
HTTP_CODE=$(run_curl_test \
  "test-l4-allow-${RUN_ID}" \
  "bookinfo-productpage" \
  "http://reviews:9080/reviews/0")

echo "  HTTP response: ${HTTP_CODE}"
if [[ "${HTTP_CODE}" =~ ^2 ]]; then
  pass "bookinfo-productpage SA → reviews: HTTP ${HTTP_CODE} (allowed as expected)"
else
  fail "bookinfo-productpage SA → reviews: HTTP ${HTTP_CODE} (expected 2xx — SA is in the whitelist)"
fi
echo ""

# ── 4. Test DENY — default SA (not whitelisted) → reviews ────────────────────
echo "--- Test 2: DENY — pod with default SA (not in whitelist) → reviews ---"
echo "  Launching test pod (SA: default)..."
HTTP_CODE=$(run_curl_test \
  "test-l4-deny-${RUN_ID}" \
  "default" \
  "http://reviews:9080/reviews/0")

echo "  HTTP response: ${HTTP_CODE}"
# ztunnel rejects at L4 (TCP reset → curl returns 000) or
# waypoint returns HTTP 403/503 depending on enforcement point
if [[ "${HTTP_CODE}" == "000" || "${HTTP_CODE}" == "403" || "${HTTP_CODE}" == "503" ]]; then
  pass "default SA → reviews: blocked (HTTP ${HTTP_CODE}) (denied as expected)"
else
  fail "default SA → reviews: HTTP ${HTTP_CODE} (expected 403/503 or TCP reset — SA not in whitelist)"
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "================================================================="
echo "  L4 Authorization Policy Test Summary"
echo "  Policy : whitelist-reviews-l4  (namespace: ${NS})"
echo "  Layer  : ztunnel — SPIFFE / mTLS principal enforcement"
echo "  Rule   : only bookinfo-productpage SA may reach reviews"
echo "-----------------------------------------------------------------"
echo "  Passed : ${PASS_COUNT} / $((PASS_COUNT + FAIL_COUNT))"
if [[ "${FAIL_COUNT}" -eq 0 ]]; then
  echo "  Result : ALL TESTS PASSED"
else
  echo "  Result : ${FAIL_COUNT} TEST(S) FAILED"
  exit 1
fi
echo "================================================================="
