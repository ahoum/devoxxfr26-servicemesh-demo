#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NS="bookinfo-ambient-l7"
PASS_COUNT=0
FAIL_COUNT=0
RUN_ID="$$"

pass() { echo "  [PASS] $*"; (( PASS_COUNT++ )) || true; }
fail() { echo "  [FAIL] $*"; (( FAIL_COUNT++ )) || true; }

# ── Cleanup trap ──────────────────────────────────────────────────────────────
cleanup() {
  kubectl delete pod "test-l7-client-${RUN_ID}" \
    -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ── 1. Apply L7 deny policy ───────────────────────────────────────────────────
echo "==> Applying L7 deny authorization policy for reviews-v2..."
kubectl apply -f "${REPO_ROOT}/policies/l7-deny-reviewsv2.yaml"
echo ""
echo "  Policy details:"
kubectl get authorizationpolicy -n "${NS}" deny-reviews-v2-l7 \
  -o custom-columns='NAME:.metadata.name,ACTION:.spec.action,NAMESPACE:.metadata.namespace'
echo ""

# ── 2. Wait for the waypoint to reload the policy ────────────────────────────
echo "==> Waiting 5s for reviews-waypoint to reload the L7 policy..."
sleep 5
echo ""

# ── 3. Verify reviews pods exist (v1, v2, v3) ────────────────────────────────
echo "==> Checking reviews pods in namespace ${NS}..."
kubectl get pods -n "${NS}" -l app=reviews \
  -o custom-columns='NAME:.metadata.name,VERSION:.metadata.labels.version,STATUS:.status.phase'
echo ""

# ── 4. Spawn a persistent curl client pod for all requests ───────────────────
# Use bookinfo-productpage SA so L4 whitelist (if applied) does not interfere.
echo "==> Launching curl client pod (SA: bookinfo-productpage)..."
kubectl run "test-l7-client-${RUN_ID}" \
  --image=curlimages/curl:8.11.0 \
  --restart=Never \
  -n "${NS}" \
  --serviceaccount=bookinfo-productpage \
  -- sleep 60 \
  >/dev/null 2>&1

# Wait for the client pod to be Running
kubectl wait pod/"test-l7-client-${RUN_ID}" -n "${NS}" \
  --for=condition=Ready --timeout=30s >/dev/null 2>&1
echo "  Client pod ready."
echo ""

# ── 5. Helper: single curl via the client pod ────────────────────────────────
curl_reviews() {
  kubectl exec "test-l7-client-${RUN_ID}" -n "${NS}" \
    -- curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    http://reviews:9080/reviews/0 2>/dev/null || echo "000"
}

# ── 6. Test DENY — reviews-v2 must return 403 from the waypoint ──────────────
# With 3 versions (v1, v2, v3) and 12 requests, the probability of never
# hitting v2 is (2/3)^12 ≈ 0.8 %. Looping 12 times is statistically safe.
echo "--- Test 1: DENY — reviews-v2 traffic must be blocked (HTTP 403) ---"
echo "  Sending 12 requests to the reviews service (covers all 3 versions)..."
GOT_403=false
GOT_200=false
RESULTS=()

for i in $(seq 1 12); do
  CODE=$(curl_reviews)
  RESULTS+=("${CODE}")
  echo "    Request ${i}: HTTP ${CODE}"
  [[ "${CODE}" == "403" ]] && GOT_403=true
  [[ "${CODE}" =~ ^2    ]] && GOT_200=true
done
echo ""

if [[ "${GOT_403}" == "true" ]]; then
  pass "reviews-v2: received HTTP 403 — DENY policy enforced by reviews-waypoint (L7)"
else
  fail "reviews-v2: never received 403 in 12 requests — waypoint policy may not be active"
fi

# ── 7. Test ALLOW — reviews-v1 and v3 still reachable ────────────────────────
echo "--- Test 2: ALLOW — reviews-v1 / reviews-v3 still return HTTP 200 ---"
if [[ "${GOT_200}" == "true" ]]; then
  pass "reviews-v1/v3: received HTTP 200 — non-v2 versions still reachable"
else
  fail "reviews-v1/v3: never received 200 — policy may be blocking more than intended"
fi
echo ""

# ── 8. Distribution summary ───────────────────────────────────────────────────
COUNT_200=0; COUNT_403=0; COUNT_OTHER=0
for c in "${RESULTS[@]}"; do
  case "${c}" in
    2*) (( COUNT_200++  )) || true ;;
    403) (( COUNT_403++ )) || true ;;
    *) (( COUNT_OTHER++ )) || true ;;
  esac
done
echo "  Response distribution over 12 requests:"
echo "    HTTP 2xx (v1 / v3 — ALLOWED) : ${COUNT_200}"
echo "    HTTP 403 (v2  — DENIED)      : ${COUNT_403}"
[[ "${COUNT_OTHER}" -gt 0 ]] && echo "    Other                        : ${COUNT_OTHER}"
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "================================================================="
echo "  L7 Authorization Policy Test Summary"
echo "  Policy : deny-reviews-v2-l7  (namespace: ${NS})"
echo "  Layer  : reviews-waypoint — HTTP-layer DENY enforcement"
echo "  Rule   : all traffic to reviews-v2 pods is denied (HTTP 403)"
echo "-----------------------------------------------------------------"
echo "  Passed : ${PASS_COUNT} / $((PASS_COUNT + FAIL_COUNT))"
if [[ "${FAIL_COUNT}" -eq 0 ]]; then
  echo "  Result : ALL TESTS PASSED"
else
  echo "  Result : ${FAIL_COUNT} TEST(S) FAILED"
  exit 1
fi
echo "================================================================="
