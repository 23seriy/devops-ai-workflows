
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

For each problem pod found in Step 4:

```bash
kubectl logs -n <ns> <pod> --all-containers --tail=$LOG_TAIL --timestamps
kubectl logs -n <ns> <pod> --all-containers --previous --tail=$LOG_TAIL --timestamps 2>/dev/null
```

Search the captured logs for: `error`, `fatal`, `panic`, `exception`, `traceback`, `failed`, `timeout`, `refused`, `denied`, `unauthorized`, `OOM`, `evicted`, `connection reset`, `no such host`, `dial tcp`. Group identical messages and report counts plus first/last timestamp.

---

## Step 6 — Workload controllers


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

## Step 7 — Events (cluster-wide warnings)


```bash
SCOPE="-A"; [ "$NAMESPACE" != "all" ] && SCOPE="-n $NAMESPACE"
kubectl get events $SCOPE --sort-by=.lastTimestamp | tail -100
kubectl get events $SCOPE --field-selector type=Warning --sort-by=.lastTimestamp | tail -200
```

Aggregate Warning events by `reason` and `involvedObject.kind`. Highlight: `FailedScheduling`, `FailedMount`, `FailedAttachVolume`, `BackOff`, `Unhealthy`, `NodeNotReady`, `Evicted`, `FailedCreatePodSandBox`, `NetworkPluginNotReady`, `KubeletHasInsufficientMemory`, `OOMKilling`, `Preempting`, `FailedKillPod`.

---

## Step 8 — Networking


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

- **Pending pod** → check events (`FailedScheduling`), node taints/affinity, resource requests vs node capacity, PVC binding.
- **CrashLoopBackOff** → previous logs, exit code (137=OOM, 1=app error, 139=segfault), liveness probe misconfig, missing config/secret.
- **ImagePullBackOff** → registry auth (`imagePullSecrets`), image name/tag typo, network egress to registry, private registry cert.
- **CreateContainerConfigError** → missing ConfigMap/Secret keys referenced in env/volumeMounts.
- **Service has no endpoints** → selector ↔ pod label mismatch, target pods not Ready, named port mismatch.
- **DNS failures inside pods** → CoreDNS pods unhealthy, NetworkPolicy blocking egress to kube-dns, node `resolv.conf` issue.
- **PVC Pending** → no default StorageClass, provisioner pod down, capacity quota exhausted, AZ mismatch.
- **Webhook errors on apply** → mutating/validating webhook service has no endpoints, expired CA bundle, namespace not in `namespaceSelector`.
- **Evicted pods** → node DiskPressure/MemoryPressure; check `kubectl describe node` and ephemeral-storage limits.

---

## Safety rules

- Every command in this workflow is **read-only** except the optional Step 15 probes, which create short-lived diagnostic pods that auto-delete (`--rm`).
- Never print secret values; only names, types, and key lists.
- Never modify resources, scale workloads, restart pods, or delete anything as part of debugging.
- If a command fails due to RBAC, record the failure in the report and continue — do not attempt privilege escalation.
