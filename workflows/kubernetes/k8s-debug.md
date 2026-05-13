---
description: General-purpose Kubernetes cluster debugger. Performs deep, read-only health and diagnostics checks against any cluster reachable via the current kubectl context. Generates a markdown report.
---

# /k8s-debug — General Kubernetes Cluster Debugger

Diagnose any Kubernetes cluster using only `kubectl` (and optional `jq`). All commands are **read-only**. The workflow walks through cluster, node, workload, networking, storage, RBAC, events, and resource-usage checks, then writes a timestamped markdown report.

## Prerequisites

- `kubectl` installed and configured (the current context points at the target cluster).
- Optional: `jq` (richer JSON parsing), `yq`, `stern` (better log streaming), `kubectl top` (requires metrics-server).
- Read access (RBAC) to the namespaces being inspected. Most steps need `get`/`list` on core resources and logs.

## Inputs

Ask the user for the following before starting (use sensible defaults if not provided):

- **NAMESPACE** — target namespace, or `all` for cluster-wide. Default: `all`.
- **CONTEXT** — kubectl context name. Default: current context (`kubectl config current-context`).
- **FOCUS_LABEL** — optional label selector to scope workload checks (e.g. `app=myapi`). Default: none.
- **LOG_TAIL** — log lines per container/pod. Default: `300`.
- **SINCE** — log/event time window. Default: `1h`.
- **REPORT_DIR** — where to write the report. Default: `./k8s-debug-reports`.
- **DEEP** — `yes`/`no`. If `yes`, also run optional/expensive checks (network policy reachability, image pull tests, exec-into-pod probes). Default: `no`.

Confirm the inputs and current context with the user before proceeding.

---

## Step 1 — Verify connectivity and context

// turbo

```bash
kubectl config current-context
kubectl cluster-info
kubectl version --output=yaml
kubectl auth can-i --list | head -50
kubectl get --raw='/healthz?verbose' | tail -40
kubectl get --raw='/livez?verbose' 2>/dev/null | tail -20
kubectl get --raw='/readyz?verbose' 2>/dev/null | tail -20
```

Stop the workflow if `cluster-info` fails — kubectl is not configured. Report exact error.

---

## Step 2 — Cluster inventory

// turbo

```bash
kubectl get nodes -o wide
kubectl get ns
kubectl api-resources --verbs=list --namespaced -o name | wc -l
kubectl get componentstatuses 2>/dev/null || true
kubectl get apiservices | awk '$2 != "Local" && $3 != "True"' | head -40   # unhealthy aggregated APIs
```

Capture: kubernetes version, node count, kubelet versions, container runtimes, OS images, total namespace count, any non-`True` APIService.

---

## Step 3 — Node health

// turbo

```bash
kubectl get nodes -o json | jq -r '
  .items[] | {
    name: .metadata.name,
    ready: ([.status.conditions[] | select(.type=="Ready") | .status][0]),
    pressure: [.status.conditions[] | select(.type|test("Pressure|Unavailable")) | select(.status=="True") | .type],
    taints: [.spec.taints[]?.key],
    cpu_alloc: .status.allocatable.cpu,
    mem_alloc: .status.allocatable.memory,
    pods_alloc: .status.allocatable.pods,
    kubelet: .status.nodeInfo.kubeletVersion,
    runtime: .status.nodeInfo.containerRuntimeVersion
  }'
kubectl describe nodes | grep -E "Name:|Taints:|Conditions:|MemoryPressure|DiskPressure|PIDPressure|Ready " | head -200
kubectl top nodes 2>/dev/null || echo "metrics-server not available"
```

Flag: `Ready != True`, any `*Pressure=True`, unschedulable nodes, kubelet version skew vs control plane > 1 minor.

---

## Step 4 — Pod health (cluster-wide or scoped)

Use `-A` if NAMESPACE=all, otherwise `-n $NAMESPACE`.

// turbo

```bash
SCOPE="-A"; [ "$NAMESPACE" != "all" ] && SCOPE="-n $NAMESPACE"
kubectl get pods $SCOPE -o wide
kubectl get pods $SCOPE --field-selector=status.phase!=Running,status.phase!=Succeeded -o wide
kubectl get pods $SCOPE -o json | jq -r '
  .items[] |
  select(
    (.status.phase != "Running" and .status.phase != "Succeeded") or
    ([.status.containerStatuses[]?.ready] | any(. == false)) or
    ([.status.containerStatuses[]?.restartCount] | max // 0) > 0 or
    ([.status.initContainerStatuses[]?.ready] | any(. == false))
  ) |
  {
    ns: .metadata.namespace,
    pod: .metadata.name,
    phase: .status.phase,
    reason: (.status.reason // ""),
    node: .spec.nodeName,
    restarts: ([.status.containerStatuses[]?.restartCount] | max // 0),
    notReady: [.status.containerStatuses[]? | select(.ready==false) | .name],
    waiting: [.status.containerStatuses[]? | .state.waiting? | select(.!=null) | .reason],
    terminated: [.status.containerStatuses[]? | .lastState.terminated? | select(.!=null) | {c: .reason, exit: .exitCode}]
  }'
```

For each problem pod, also collect:

```bash
kubectl describe pod -n <ns> <pod> | sed -n '/Events:/,$p'
kubectl get events -n <ns> --field-selector involvedObject.name=<pod> --sort-by=.lastTimestamp
```

Common patterns to flag:

- `CrashLoopBackOff`, `Error`, `OOMKilled` (exit 137), `ImagePullBackOff`/`ErrImagePull`, `CreateContainerConfigError`, `RunContainerError`.
- `Pending` with no node — schedulability or PVC binding issue.
- `ContainerCreating` > 2 min — CNI / volume mount / image pull.
- `Init:*` stuck — init container or dependency wait.
- `Terminating` > 2 min — finalizers, stuck volumes, node NotReady.
- High `restartCount` with low age — flapping.

---

## Step 5 — Logs from problem pods

For each problem pod found in Step 4, collect logs systematically:

### 5a — Current and previous container logs

```bash
# Current logs for all containers
kubectl logs -n <ns> <pod> --all-containers --tail=$LOG_TAIL --timestamps

# Previous container logs (captures crash output before restart)
kubectl logs -n <ns> <pod> --all-containers --previous --tail=$LOG_TAIL --timestamps 2>/dev/null
```

### 5b — Init container logs (commonly missed)

Init containers are a frequent source of stuck pods. Check them explicitly:

```bash
# List init container names
kubectl get pod -n <ns> <pod> -o jsonpath='{.spec.initContainers[*].name}'

# Logs for each init container
for ic in $(kubectl get pod -n <ns> <pod> -o jsonpath='{.spec.initContainers[*].name}'); do
  echo "=== init-container: $ic ==="
  kubectl logs -n <ns> <pod> -c $ic --tail=$LOG_TAIL --timestamps 2>/dev/null
done
```

### 5c — Structured error extraction

Scan all collected logs for error patterns and build an aggregated error table:

```bash
# Extract error lines with severity classification
kubectl logs -n <ns> <pod> --all-containers --tail=$LOG_TAIL --timestamps 2>/dev/null | \
  grep -iE 'error|fatal|panic|exception|traceback|failed|timeout|refused|denied|unauthorized|OOM|evicted|connection reset|no such host|dial tcp|SIGTERM|SIGKILL|killed|backoff|certificate|x509|tls' | \
  sort | uniq -c | sort -rn | head -30
```

### 5d — Log analysis guidance

Classify found errors by severity:

| Severity | Patterns | Likely cause |
|---|---|---|
| 🔴 Fatal | `panic`, `fatal`, `SIGKILL`, `OOMKilled`, exit 137 | App crash, OOM, kernel kill |
| 🔴 Auth/TLS | `x509`, `certificate`, `tls handshake`, `unauthorized`, `forbidden` | Expired cert, wrong CA, RBAC |
| 🟡 Connectivity | `connection refused`, `no such host`, `dial tcp`, `i/o timeout`, `ECONNREFUSED` | Service down, DNS, network policy |
| 🟡 Dependency | `timeout`, `deadline exceeded`, `context canceled`, `backoff` | Upstream slow or down |
| 🔵 App error | `error`, `failed`, `exception`, `traceback` | Application bug, bad config |

For **high-restart pods**, compare previous logs vs current logs — if the error is the same, it's a persistent issue; if different, it may be a startup-order dependency.

### 5e — Broad log scan (optional, when FOCUS_LABEL is not set)

If no specific problem pods are found but the user suspects issues, scan all running pods for recent errors:

```bash
SCOPE="-A"; [ "$NAMESPACE" != "all" ] && SCOPE="-n $NAMESPACE"
for pod in $(kubectl get pods $SCOPE -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' | head -50); do
  ns=${pod%%/*}; name=${pod##*/}
  errors=$(kubectl logs -n $ns $name --all-containers --since=$SINCE --timestamps 2>/dev/null | grep -ciE 'error|fatal|panic|exception' || true)
  [ "$errors" -gt 0 ] 2>/dev/null && echo "$errors errors: $ns/$name"
done | sort -rn | head -20
```

This gives a "noisiest pods" ranking even when no pods are in a failed state.

---

## Step 6 — Workload controllers

// turbo

```bash
SCOPE="-A"; [ "$NAMESPACE" != "all" ] && SCOPE="-n $NAMESPACE"
kubectl get deploy,sts,ds,rs,job,cronjob $SCOPE
kubectl get deploy $SCOPE -o json | jq -r '.items[] | select(
    (.status.replicas // 0) != (.status.availableReplicas // 0) or
    (.status.unavailableReplicas // 0) > 0
  ) | "\(.metadata.namespace)/\(.metadata.name) desired=\(.spec.replicas) avail=\(.status.availableReplicas // 0) unavail=\(.status.unavailableReplicas // 0)"'
kubectl get sts $SCOPE -o json | jq -r '.items[] | select(.status.readyReplicas != .status.replicas) | "\(.metadata.namespace)/\(.metadata.name) ready=\(.status.readyReplicas // 0)/\(.status.replicas)"'
kubectl get ds $SCOPE -o json | jq -r '.items[] | select(.status.numberReady != .status.desiredNumberScheduled) | "\(.metadata.namespace)/\(.metadata.name) ready=\(.status.numberReady)/\(.status.desiredNumberScheduled) misscheduled=\(.status.numberMisscheduled)"'
kubectl get jobs $SCOPE -o json | jq -r '.items[] | select((.status.failed // 0) > 0) | "\(.metadata.namespace)/\(.metadata.name) failed=\(.status.failed) succeeded=\(.status.succeeded // 0)"'
```

For each unhealthy controller, run `kubectl describe <kind> -n <ns> <name>` and check rollout status: `kubectl rollout status <kind>/<name> -n <ns> --timeout=10s`.

---

## Step 6a — Restart timeline and failure chain analysis

Build a timeline of container restarts to distinguish **startup-order noise** (restarts clustered at boot, now stable) from **active instability** (restarts continuing).

```bash
SCOPE="-A"; [ "$NAMESPACE" != "all" ] && SCOPE="-n $NAMESPACE"

# Restart timeline: when did each container last terminate?
kubectl get pods $SCOPE -o json | jq -r '
  .items[] | select(.status.phase=="Running") |
  .metadata as $m |
  .status.containerStatuses[]? |
  select(.restartCount > 0) |
  "\(.lastState.terminated.finishedAt // "-") \($m.namespace)/\($m.name) container=\(.name) restarts=\(.restartCount) reason=\(.lastState.terminated.reason // "-") exit=\(.lastState.terminated.exitCode // "-")"
' | sort
```

**Interpretation guide:**

- **All restarts clustered at cluster boot time (e.g., within the first 10 minutes)** — likely startup-order dependencies. A pod starts before its dependency is ready, crashes, then succeeds on retry. Low priority.
- **Restarts continuing in the last 30 minutes** — active instability. High priority.
- **Restart chains** — if pod A restarts, then pod B restarts shortly after, B likely depends on A. Map the dependency chain:
  - Database → app → worker is a common pattern (e.g., Redis → cluster-manager → dataplane workers).
  - Identify the **root pod** (the one that restarted first) and focus debugging there.

```bash
# Check if any restarts happened recently (last 30 min)
kubectl get pods $SCOPE -o json | jq -r --arg cutoff "$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" '
  .items[] | .metadata as $m |
  .status.containerStatuses[]? |
  select(.restartCount > 0 and (.lastState.terminated.finishedAt // "1970") > $cutoff) |
  "RECENT-RESTART: \($m.namespace)/\($m.name) container=\(.name) at=\(.lastState.terminated.finishedAt) reason=\(.lastState.terminated.reason)"
'
```

---

## Step 6b — HPA and autoscaling health

// turbo

```bash
SCOPE="-A"; [ "$NAMESPACE" != "all" ] && SCOPE="-n $NAMESPACE"

# HPA status
kubectl get hpa $SCOPE -o wide 2>/dev/null

# HPAs unable to scale (metrics issues)
kubectl get hpa $SCOPE -o json 2>/dev/null | jq -r '
  .items[] | .metadata.name as $n | .metadata.namespace as $ns |
  .status.conditions[]? |
  select(.type=="ScalingActive" and .status!="True") |
  "\($ns)/\($n): \(.reason) — \(.message)"'

# HPAs at max replicas (may need attention)
kubectl get hpa $SCOPE -o json 2>/dev/null | jq -r '
  .items[] |
  select(.status.currentReplicas >= .spec.maxReplicas) |
  "\(.metadata.namespace)/\(.metadata.name) at-max=\(.status.currentReplicas)/\(.spec.maxReplicas)"'

# Custom metrics API health (common failure point)
kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1 2>&1 | head -5
kubectl get --raw /apis/metrics.k8s.io/v1beta1 2>&1 | head -5
```

Flag:
- HPAs with `ScalingActive=False` — metrics API broken or metric not found.
- HPAs at max replicas — workload may be under-provisioned.
- Custom metrics API `ServiceUnavailable` — prometheus-adapter or similar is broken.
- HPAs with `FailedGetObjectMetric` or `FailedGetResourceMetric` events.

---

## Step 7 — Events (cluster-wide warnings)

// turbo

```bash
SCOPE="-A"; [ "$NAMESPACE" != "all" ] && SCOPE="-n $NAMESPACE"
kubectl get events $SCOPE --sort-by=.lastTimestamp | tail -100
kubectl get events $SCOPE --field-selector type=Warning --sort-by=.lastTimestamp | tail -200
```

Aggregate Warning events by `reason` and `involvedObject.kind`. Highlight: `FailedScheduling`, `FailedMount`, `FailedAttachVolume`, `BackOff`, `Unhealthy`, `NodeNotReady`, `Evicted`, `FailedCreatePodSandBox`, `NetworkPluginNotReady`, `KubeletHasInsufficientMemory`, `OOMKilling`, `Preempting`, `FailedKillPod`.

---

## Step 8 — Networking

// turbo

```bash
SCOPE="-A"; [ "$NAMESPACE" != "all" ] && SCOPE="-n $NAMESPACE"
kubectl get svc $SCOPE -o wide
kubectl get endpoints $SCOPE | awk 'NR==1 || $3=="<none>"'                # services with no endpoints
kubectl get endpointslices $SCOPE 2>/dev/null | head -50
kubectl get ingress $SCOPE 2>/dev/null
kubectl get networkpolicy $SCOPE 2>/dev/null
kubectl get gateway,httproute,grpcroute,tlsroute $SCOPE 2>/dev/null
# DNS health
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide 2>/dev/null
kubectl -n kube-system get pods -l k8s-app=coredns -o wide 2>/dev/null
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50 2>/dev/null
kubectl -n kube-system logs -l k8s-app=coredns --tail=50 2>/dev/null
# CNI
kubectl -n kube-system get ds 2>/dev/null
```

Flag: services with empty endpoints (selector mismatch or no ready pods), Ingress without IP/hostname, CoreDNS errors (`SERVFAIL`, `i/o timeout`, `loop`), CNI DaemonSet not Ready on every node.

If `DEEP=yes`, run a connectivity probe:

```bash
kubectl run k8s-debug-net --rm -it --restart=Never --image=nicolaka/netshoot --command -- sh -c '
  echo "--- DNS ---"; for d in kubernetes.default.svc.cluster.local kube-dns.kube-system.svc.cluster.local; do nslookup $d || true; done
  echo "--- API ---"; curl -ksS https://kubernetes.default.svc/healthz; echo
  echo "--- EGRESS ---"; curl -ksSm 5 https://www.google.com -o /dev/null -w "google=%{http_code}\n" || true
'
```

---

## Step 9 — Storage

// turbo

```bash
SCOPE="-A"; [ "$NAMESPACE" != "all" ] && SCOPE="-n $NAMESPACE"
kubectl get sc
kubectl get pv
kubectl get pvc $SCOPE
kubectl get pvc $SCOPE -o json | jq -r '.items[] | select(.status.phase!="Bound") | "\(.metadata.namespace)/\(.metadata.name) phase=\(.status.phase) sc=\(.spec.storageClassName // "-")"'
kubectl get pv -o json | jq -r '.items[] | select(.status.phase!="Bound" and .status.phase!="Available") | "\(.metadata.name) phase=\(.status.phase) reclaim=\(.spec.persistentVolumeReclaimPolicy)"'
# CSI drivers / nodes
kubectl get csidrivers 2>/dev/null
kubectl get csinodes 2>/dev/null
```

Flag: `Pending` PVCs (no SC, no provisioner, capacity), `Released` PVs not reclaimed, mismatched access modes, CSI driver pods not Ready.

---

## Step 10 — Configuration & secrets sanity

// turbo

```bash
SCOPE="-A"; [ "$NAMESPACE" != "all" ] && SCOPE="-n $NAMESPACE"
kubectl get cm $SCOPE | wc -l
kubectl get secret $SCOPE | wc -l
# Secrets close to empty (often broken):
kubectl get secret $SCOPE -o json | jq -r '.items[] | select((.data // {}) | length == 0) | "EMPTY \(.metadata.namespace)/\(.metadata.name) type=\(.type)"' | head -40
# ServiceAccount tokens missing
kubectl get sa $SCOPE -o json | jq -r '.items[] | select((.secrets // []) | length == 0 and .metadata.name=="default") | "\(.metadata.namespace)/\(.metadata.name)"' | head -20
```

Do **not** print secret values. Only metadata and counts.

---

## Step 11 — RBAC sanity (current identity)

// turbo

```bash
kubectl auth whoami 2>/dev/null || kubectl config view --minify -o jsonpath='{.users[0].name}'
kubectl auth can-i get pods -A
kubectl auth can-i create pods -A
kubectl auth can-i get secrets -A
kubectl auth can-i '*' '*' -A
```

Note any restrictions; some later steps may legitimately fail because of RBAC, not cluster issues.

---

## Step 12 — Resource pressure & quotas

// turbo

```bash
SCOPE="-A"; [ "$NAMESPACE" != "all" ] && SCOPE="-n $NAMESPACE"
kubectl get resourcequota $SCOPE
kubectl get limitrange $SCOPE
kubectl top pods $SCOPE --sort-by=memory 2>/dev/null | head -25
kubectl top pods $SCOPE --sort-by=cpu 2>/dev/null | head -25
kubectl top nodes 2>/dev/null
# Pods without requests/limits
kubectl get pods $SCOPE -o json | jq -r '.items[] | select(any(.spec.containers[]; (.resources.requests // {}) == {} or (.resources.limits // {}) == {})) | "\(.metadata.namespace)/\(.metadata.name)"' | head -30
# Recently OOMKilled containers
kubectl get pods $SCOPE -o json | jq -r '.items[] | .metadata as $m | .status.containerStatuses[]? | select(.lastState.terminated.reason=="OOMKilled") | "\($m.namespace)/\($m.name) container=\(.name) exit=\(.lastState.terminated.exitCode)"'
```

---

## Step 13 — Control-plane add-ons (best-effort)

// turbo

```bash
kubectl -n kube-system get pods -o wide
kubectl -n kube-system get pods --field-selector=status.phase!=Running,status.phase!=Succeeded
# Common add-ons; ignore if absent
for ns in kube-system ingress-nginx istio-system linkerd cert-manager metallb-system kube-flannel calico-system tigera-operator longhorn-system rook-ceph openebs metrics-server; do
  kubectl get pods -n $ns 2>/dev/null | tail -n +1
done
```

---

## Step 14 — Certificates & webhooks

// turbo

```bash
kubectl get validatingwebhookconfigurations
kubectl get mutatingwebhookconfigurations
kubectl get crds | wc -l
# cert-manager (if installed)
kubectl get certificates -A 2>/dev/null
kubectl get certificaterequests -A 2>/dev/null | tail -20
kubectl get clusterissuers,issuers -A 2>/dev/null
```

Flag webhooks pointing at services with no endpoints (a classic cause of `failed calling webhook` errors blocking creates).

---

## Step 15 — Optional deep checks (only when DEEP=yes)

- **Image pullability**: for each unique image in problem pods, run a one-shot `kubectl run img-test-<n> --image=<img> --restart=Never --rm -it --command -- true` and report failures.
- **Exec probe** into a healthy app pod to test in-cluster DNS and target service reachability (`getent hosts`, `nc -zv`).
- **NetworkPolicy simulation**: list policies in the namespace and summarise ingress/egress restrictions affecting the focus pod.
- **API server latency**: `kubectl get --raw='/metrics' | grep apiserver_request_duration_seconds_bucket | head` (only if metrics endpoint is accessible).

Skip any deep check that requires permissions the user lacks.

---

## Step 16 — Generate the report

Write a single markdown file: `$REPORT_DIR/k8s-debug-<context>-<YYYYMMDD-HHMMSS>.md` containing:

1. **Header** — context, cluster version, scope (namespace / label), inputs, run timestamp, identity.
2. **Executive summary** — one paragraph + Healthy/Degraded/Critical verdict.
3. **Top findings** — ranked list (🔴 Critical / 🟡 Warning / 🔵 Info) with: what was found, where, why it matters, suggested next action.
4. **Section-by-section results** — one subsection per step above, including the raw highlights (truncated as needed).
5. **Aggregated log error table** — message → count → first/last seen → pod(s).
6. **Aggregated event table** — reason → kind → count → namespaces.
7. **Recommended actions** — prioritized P1/P2/P3 with concrete `kubectl` commands the user can run to fix or investigate further.
8. **Appendix** — full command list executed (for reproducibility).

After writing the file, print: report path, verdict, and the top 3 P1 actions.

---

## Triage cheat-sheet (apply while interpreting results)

### Pod-level issues

- **Pending pod** → check events (`FailedScheduling`), node taints/affinity, resource requests vs node capacity, PVC binding.
- **CrashLoopBackOff** → previous logs, exit code (137=OOM, 1=app error, 139=segfault), liveness probe misconfig, missing config/secret.
- **ImagePullBackOff** → registry auth (`imagePullSecrets`), image name/tag typo, network egress to registry, private registry cert.
- **CreateContainerConfigError** → missing ConfigMap/Secret keys referenced in env/volumeMounts.
- **Init:Error / Init:CrashLoopBackOff** → check init container logs explicitly (Step 5b). Common causes: dependency not ready, DB migration failed, config validation failed.
- **Terminating > 2 min** → finalizers, stuck volumes, node NotReady, `preStop` hook hanging.
- **Evicted pods** → node DiskPressure/MemoryPressure; check `kubectl describe node` and ephemeral-storage limits.

### Startup-order and dependency chains

- **Multiple pods restart at boot, then stabilize** → startup-order dependency (e.g., app starts before DB is ready). Low priority if restarts stopped.
- **Cascading CrashLoopBackOff** → identify the root pod (first to crash). Common chains: database → app → workers, DNS → everything, cert-manager → webhooks → all creates.
- **nginx "host not found in upstream"** → nginx resolved DNS at startup before the backend service existed. Expected to self-heal after a few restarts.
- **Redis "LOADING" during startup** → Redis loading dataset from disk; scripts that `SET` immediately after `PING` will fail. Wait for `loading:0` in `INFO persistence`.

### Networking and services

- **Service has no endpoints** → selector ↔ pod label mismatch, target pods not Ready, named port mismatch.
- **DNS failures inside pods** → CoreDNS pods unhealthy, NetworkPolicy blocking egress to kube-dns, node `resolv.conf` issue.
- **Connection refused to a service** → target pods not ready, wrong port in Service spec, readiness probe failing.

### Storage

- **PVC Pending** → no default StorageClass, provisioner pod down, capacity quota exhausted, AZ mismatch.
- **PDB disruptionsAllowed=0 blocking drain** → single-replica stateful workloads or storage engine pods (e.g., Longhorn instance-manager).

### Autoscaling

- **HPA `FailedGetObjectMetric`** → custom metrics API broken, prometheus-adapter not serving metrics, metric name mismatch.
- **HPA at max replicas** → workload may be under-provisioned, or max is set too low.
- **HPA `TooFewReplicas`** → minReplicas is higher than what the HPA would scale to; expected when load is low.

### Webhooks and API

- **Webhook errors on apply** → mutating/validating webhook service has no endpoints, expired CA bundle, namespace not in `namespaceSelector`.
- **API server slow / timeouts** → check aggregated API services; a broken `custom.metrics.k8s.io` can degrade API server responsiveness.
- **"the server is currently unable to handle the request"** → aggregated API service is registered but its backing pods are unhealthy.

---

## Safety rules

- Every command in this workflow is **read-only** except the optional Step 15 probes, which create short-lived diagnostic pods that auto-delete (`--rm`).
- Never print secret values; only names, types, and key lists.
- Never modify resources, scale workloads, restart pods, or delete anything as part of debugging.
- If a command fails due to RBAC, record the failure in the report and continue — do not attempt privilege escalation.
