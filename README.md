
## Devoxx 2026 Demo - Istio Service Mesh 

### Prerequisites

- `kind`, `kubectl`, `istioctl`, `docker` installed and in `$PATH`
- Docker Desktop running

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

### Step 5 — Demo L4 & L7 AuthorizationPolicy

Deploying `curl-review` that directly targets bookinfo reviews
```bash
kubectl run curl-review -n bookinfo-ambient-l7 --image=curlimages/curl -- /bin/sh -c \
"while true; do curl -s -o /dev/null --connect-timeout 1 --max-time 2 -w \"Status: %{http_code} | Timestamp: \$(date +%H:%M:%S)\n\" http://reviews.bookinfo-ambient-l7.svc.cluster.local:9080/reviews/1; sleep 0.5; done"

kubectl logs -f curl-review -n bookinfo-ambient-l7
```

First ap deployes : deny at l4 reviews-v2 (black stars)

```bash
kubectl apply -f policies/l7-deny-reviewsv2.yaml
```

---

#### Step 6 — L7: Whitelist only productpage SA at the Waypoint

```bash
kubectl apply -f policies/l4-whitelist-reviews.yaml
```


#### Cleanup

```bash
kubectl delete -f policies/l4-whitelist-reviews.yaml
kubectl delete -f policies/l7-deny-reviewsv2.yaml

# Graceful cleanup with checks
bash scripts/05-demo-l7-policy.sh --remove
bash scripts/04-demo-l4-policy.sh --remove 

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