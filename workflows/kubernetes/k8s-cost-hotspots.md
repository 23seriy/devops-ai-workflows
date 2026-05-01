---
description: Find Kubernetes cost and waste hotspots - over-provisioned workloads, idle resources, missing requests/limits, orphaned PVCs and load balancers. Read-only, produces a Markdown report.
---

# /k8s-cost-hotspots — Kubernetes Cost & Waste Audit

Identify the workloads, namespaces, and resources most likely to be wasting money. Designed to work with just `kubectl` + `metrics-server`; if you have OpenCost / Kubecost / cloud cost APIs, use those for $$ figures and feed the workload list from this report into them.

## Prerequisites

- `kubectl` configured.
- `metrics-server` installed (`kubectl top nodes/pods` works). Without it, usage-based checks are skipped.
- Optional: `jq`.

## Inputs

- **NAMESPACE** — `all` or specific. Default: `all`.
- **TOP_N** — how many rows in each ranking. Default: `20`.
- **REPORT_DIR** — Default: `./k8s-cost-reports`.

---

## Step 1 — Cluster capacity baseline

// turbo

```bash
kubectl top nodes 2>/dev/null
kubectl get nodes -o json | jq -r '
  .items[] | {
    name: .metadata.name,
    cpu_alloc: .status.allocatable.cpu,
    mem_alloc: .status.allocatable.memory,
    pods_alloc: .status.allocatable.pods,
    instance: .metadata.labels."node.kubernetes.io/instance-type",
    zone: .metadata.labels."topology.kubernetes.io/zone"
  }'
```

Capture totals: total allocatable CPU/memory, instance-type mix, zones (cross-AZ data transfer is a hidden cost).

---

## Step 2 — Sum of requests vs cluster allocatable (over/under commit)

// turbo

```bash
kubectl get pods -A -o json | jq '
  [.items[] | .spec.containers[]?.resources.requests // {} |
    {cpu: (.cpu // "0"), memory: (.memory // "0")}]
  | {
    cpu_requests: ([.[] | .cpu | tostring] | length),
    samples: .[0:3]
  }'
# Easier path: kubectl describe node summary
kubectl describe nodes | grep -A5 "Allocated resources" | head -200
```

Flag: total requests << allocatable → cluster is over-sized; total requests >> allocatable → scheduling pressure / evictions likely.

---

## Step 3 — Pods with usage << requests (over-provisioned)

```bash
[ "$NAMESPACE" = "all" ] && S="-A" || S="-n $NAMESPACE"
kubectl top pods $S --containers --no-headers 2>/dev/null \
  | awk '{print $1"/"$2"/"$3, $4, $5}' > /tmp/usage.txt
kubectl get pods $S -o json | jq -r '
  .items[] | .metadata.namespace as $ns | .metadata.name as $p |
  .spec.containers[] | "\($ns)/\($p)/\(.name) \(.resources.requests.cpu // "0") \(.resources.requests.memory // "0")"' > /tmp/req.txt
join /tmp/usage.txt /tmp/req.txt | head -$TOP_N
```

Compute % usage = used/requested. Flag containers consistently <30% CPU **and** <50% memory of requests as candidates to right-size down.

---

## Step 4 — Pods with usage approaching limits (under-provisioned / OOM risk)

```bash
# Pull both top output and limits, compute used/limit
kubectl get pods $S -o json | jq -r '
  .items[] | .metadata.namespace as $ns | .metadata.name as $p |
  .spec.containers[] | "\($ns)/\($p)/\(.name) limit_cpu=\(.resources.limits.cpu // "-") limit_mem=\(.resources.limits.memory // "-")"' > /tmp/lim.txt
join /tmp/usage.txt /tmp/lim.txt | head -$TOP_N
```

Flag: memory usage > 80% of limit (OOM risk), CPU usage at limit (throttling — latency cost).

---

## Step 5 — Workloads with no requests/limits (unbillable & noisy-neighbour)

// turbo

```bash
kubectl get pods $S -o json | jq -r '
  .items[] | .metadata.namespace as $ns | .metadata.name as $p |
  .spec.containers[] |
  select((.resources.requests // {}) == {} or (.resources.limits // {}) == {}) |
  "\($ns)/\($p)/\(.name) requests=\(.resources.requests // {}) limits=\(.resources.limits // {})"' | head -$TOP_N
```

Flag: BestEffort QoS pods (no requests anywhere) — first to be evicted, hardest to chargeback.

---

## Step 6 — Idle / zero-replica workloads still consuming infra

// turbo

```bash
kubectl get deploy -A -o json | jq -r '.items[] | select((.spec.replicas // 0) == 0) | "\(.metadata.namespace)/\(.metadata.name) replicas=0"'
kubectl get sts -A -o json | jq -r '.items[] | select((.spec.replicas // 0) == 0) | "\(.metadata.namespace)/\(.metadata.name) replicas=0"'
# Replicas > 0 but 0 active endpoints (potentially never receives traffic)
kubectl get svc -A -o json | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace)/\(.metadata.name)"' | while read s; do
  ns=${s%%/*}; name=${s##*/}
  ep=$(kubectl -n $ns get endpoints $name -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
  echo "$s LB endpoints=${ep:-<none>}"
done
```

Flag: `LoadBalancer` services with no endpoints (paying for cloud LB doing nothing); HPAs sitting at minReplicas for weeks.

---

## Step 7 — Orphaned and over-sized PVCs

// turbo

```bash
# PVCs not mounted by any pod
kubectl get pvc -A -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name) size=\(.spec.resources.requests.storage) sc=\(.spec.storageClassName // "-")"' > /tmp/all_pvc.txt
kubectl get pods -A -o json | jq -r '.items[] | .metadata.namespace as $ns | .spec.volumes[]? | select(.persistentVolumeClaim) | "\($ns)/\(.persistentVolumeClaim.claimName)"' | sort -u > /tmp/used_pvc.txt
echo "=== Orphaned PVCs ==="
comm -23 <(awk '{print $1}' /tmp/all_pvc.txt | sort) <(sort -u /tmp/used_pvc.txt) | head -$TOP_N

# Released PVs (storage still allocated but no PVC)
kubectl get pv -o json | jq -r '.items[] | select(.status.phase=="Released") | "\(.metadata.name) size=\(.spec.capacity.storage) reclaim=\(.spec.persistentVolumeReclaimPolicy)"' | head -$TOP_N

# PVCs much larger than typical (>500Gi) — eyeball candidates
kubectl get pvc -A --sort-by=.spec.resources.requests.storage 2>/dev/null | tail -$TOP_N
```

Flag: orphaned PVCs (still being billed by cloud provider), `Released` PVs with `Retain` policy (cloud disks linger).

---

## Step 8 — LoadBalancer & cloud-resource sprawl

// turbo

```bash
# Each LB svc = a cloud LB ($$ per month even if idle)
kubectl get svc -A --field-selector spec.type=LoadBalancer
# NodePort services that probably should be ClusterIP
kubectl get svc -A --field-selector spec.type=NodePort | head -$TOP_N
# Ingress count (each ingress controller may map to its own LB)
kubectl get ingress -A | wc -l
# StorageClasses with retain policy
kubectl get sc -o json | jq -r '.items[] | "\(.metadata.name) reclaim=\(.reclaimPolicy) provisioner=\(.provisioner)"'
```

Flag: many `LoadBalancer` services where one Ingress + many backends would suffice; `Retain` reclaim policy across the board (causes orphan PVs).

---

## Step 9 — Replicas vs actual concurrency (over-replicated)

// turbo

```bash
kubectl get hpa -A 2>/dev/null
kubectl get deploy -A -o json | jq -r '.items[] | select((.spec.replicas // 1) > 3) |
  "\(.metadata.namespace)/\(.metadata.name) replicas=\(.spec.replicas)"' | head -$TOP_N
```

Flag: high replica counts without an HPA, identical replica counts across very different workloads (cargo-culted defaults).

---

## Step 10 — Namespace-level top consumers

```bash
kubectl top pods -A --sum=true 2>/dev/null | head -50
# Approx: sum of requests per namespace
kubectl get pods -A -o json | jq -r '
  [.items[] | {ns: .metadata.namespace, c: .spec.containers[]?.resources.requests}]
  | group_by(.ns) | map({ns: .[0].ns, n: length}) | sort_by(-.n)' | head -50
```

---

## Step 11 — Generate report

Write `$REPORT_DIR/k8s-cost-<context>-<timestamp>.md`:

1. Header + cluster size summary (nodes, instance types, zones).
2. Executive summary with estimated waste categories (over-provisioned / idle / orphan / sprawl).
3. **Top right-sizing candidates** (Step 3) — table: workload, current request, p95 usage, suggested request.
4. **OOM / throttle risks** (Step 4).
5. **No-requests/limits offenders** (Step 5).
6. **Idle workloads & idle LBs** (Step 6).
7. **Orphan PVCs / Released PVs** (Step 7) — explicit list with sizes.
8. **Sprawl** (Step 8): LB count, NodePort count, Ingress count.
9. **Recommendations** ranked by likely savings impact, each with the exact `kubectl` / Helm / Terraform action to take.
10. Appendix: command transcript.

Print path + top 3 highest-impact actions.

---

## Heuristics for "is this waste?"

- **Right-size down**: p95 CPU < 30% *and* p95 mem < 50% of request, sustained for ≥7 days.
- **Right-size up**: p95 CPU at limit (throttled) or memory > 80% of limit.
- **Idle workload**: replicas=0 for >30 days, or replicas>0 but 0 traffic events / 0 ingress hits / 0 service endpoints.
- **Orphan PVC**: not mounted by any current pod **and** no StatefulSet template referencing its name.
- **Idle LB**: `LoadBalancer` service with empty endpoints for >24h.

---

## Safety rules

- Read-only. The report **suggests** reductions; it does **not** apply them.
- Always cross-check usage windows against the application's natural cycle (batch jobs, weekly peaks) before recommending downsizing.
- Don't include cost figures unless a real cost source is wired in; use ratios and counts instead.
