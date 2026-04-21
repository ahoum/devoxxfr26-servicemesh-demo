
## Devoxx 2026 Demo - Istio Service Mesh 

### Prerequisites

- `kind`, `kubectl`, `istioctl`, `docker` installed and in `$PATH`
- Docker Desktop running with kind cluster 3 nodes

---

### Step 1 — Bootstrap the cluster

```bash
bash scripts/01-setup.sh
```

~3–4 minutes. Creates the Kind cluster, installs Gateway API CRDs, Istio (ambient), Prometheus, Kiali, and MetalLB.

---

### Step 2 — Deploy nomesh + sidecar (Phase 1)

```bash
bash scripts/02-deploy-sidecar.sh
```

Deploys `bookinfo-nomesh` and `bookinfo-sidecar`, waits for rollouts, and prints LoadBalancer IPs.


```bash
kubectl port-forward -n istio-system svc/kiali 20001:20001
```

Open **http://localhost:20001** to access kiali UI

```bash
kubectl port-forward -n istio-system svc/bookinfo-gateway-istio 8080:80
```

Open **http://localhost:8080/nomesh/productpage** to access product page. (replace nomesh with : sidecar , l4 , l7 to access productpage of the desired deployment)

---

### Step 3 — Start the traffic generator

```bash
kubectl apply -f apps/traffic-generator.yaml
```

The curl pod hits all 4 `productpage` services continuously. Pacing is provided by `--connect-timeout 1 --max-time 2` per request. Namespaces not yet deployed produce `status:0` lines and are skipped.

---

### Step 4 — Deploy ambient (Phase 2)

```bash
bash scripts/03-deploy-ambient.sh
```

Deploys `bookinfo-ambient-l4` (ztunnel only) and `bookinfo-ambient-l7` (ztunnel + Waypoint), waits for rollouts.

---

### Step 5 — L4: Whitelist only productpage SA (ztunnel enforcement)

Deploy a `curl-review` pod in `bookinfo-ambient-l4` (uses the `default` SA, which is **not** in the whitelist):

```bash
kubectl apply -f apps/curl-review-l4.yaml
kubectl logs -f curl-review -n bookinfo-ambient-l4
```

You should see `Status: 200` lines. Now apply the L4 whitelist policy:

```bash
kubectl apply -f policies/l4-whitelist-reviews.yaml
```

Only the `bookinfo-productpage` SA is allowed to reach reviews. Since `curl-review` runs as `default`, ztunnel blocks it at L4 — logs switch to `Status: 503`.

> **Automated test:** `bash scripts/04-apply-l4-policy.sh` deploys curl-review, applies the policy, and asserts 503 in logs.

---

### Step 6 — L7: Deny all traffic to the details Service (waypoint enforcement)

Deploy a `curl-details` pod in `bookinfo-ambient-l7` (targets the `details` Service):

```bash
kubectl apply -f apps/curl-details-l7.yaml
kubectl logs -f curl-details -n bookinfo-ambient-l7
```

You should see `Status: 200` lines. Now apply the L7 deny policy:

```bash
kubectl apply -f policies/l7-deny-details.yaml
```

The policy uses `targetRefs` to bind to the `details` Service. Traffic to `details` is routed through the `reviews-waypoint` and denied at L7. Logs switch to `Status: 403`.

> **Automated test:** `bash scripts/05-apply-l7-policy.sh` deploys curl-details, applies the policy, and asserts 403 in logs.

---

#### Cleanup

```bash
# Remove L4 policy + curl-review
bash scripts/04-apply-l4-policy.sh --remove

# Remove L7 policy + curl-review
bash scripts/05-apply-l7-policy.sh --remove
```

---

### Verify traffic is flowing (optional)

```bash
kubectl logs -f -l app=curl-product -n traffic-generator
```

Each line is a JSON record: `{"ns":"bookinfo-ambient-l7","status":200,"ms":4.3}`

---

### Gateway Access (via port-forward)

The central `bookinfo-gateway` is applied during Step 1. Once the target namespaces are deployed you can reach each Bookinfo app through a single port-forward:

```bash
kubectl port-forward -n istio-system svc/bookinfo-gateway-istio 8080:80
```

| App | URL | Available after |
|-----|-----|-----------------|
| bookinfo-nomesh | http://localhost:8080/nomesh/productpage | Step 2 |
| bookinfo-ambient-l7 | http://localhost:8080/l7/productpage | Step 4 |

> HTTPRoutes are applied automatically by scripts 02 and 03. No manual step needed.

---

### Teardown

```bash
kind delete cluster --name devoxx26fr
```