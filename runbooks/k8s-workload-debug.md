
# /k8s-workload-debug — Single-Workload Deep Dive

Use when one specific workload is misbehaving and `/k8s-debug` would be too broad. Walks the entire surface of *one* Deployment/StatefulSet/DaemonSet/Job/Pod and emits a focused report.

## Prerequisites

- `kubectl` configured for the target cluster.
- Optional: `jq`, `kubectl top` (metrics-server).
- RBAC to `get`/`list` the workload, its pods, events, and logs.

## Inputs

- **NAMESPACE** *(required)* — the workload's namespace.
- **KIND** *(required)* — `deployment` | `statefulset` | `daemonset` | `job` | `cronjob` | `pod`.
- **NAME** *(required)* — the workload name.
- **LOG_TAIL** — log lines per container. Default: `500`.
- **SINCE** — log/event window. Default: `2h`.
- **REPORT_DIR** — Default: `./k8s-workload-reports`.

Confirm inputs and current `kubectl config current-context` before proceeding.

---

## Step 1 — Identify the workload and owned pods


```bash
kubectl -n $NAMESPACE get $KIND $NAME -o wide
kubectl -n $NAMESPACE describe $KIND $NAME
# Resolve label selector → owned pods (works for deploy/sts/ds/job)
SEL=$(kubectl -n $NAMESPACE get $KIND $NAME -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null \
      | jq -r 'to_entries|map("\(.key)=\(.value)")|join(",")' 2>/dev/null)
echo "Selector: ${SEL:-<pod direct>}"
[ -n "$SEL" ] && kubectl -n $NAMESPACE get pods -l "$SEL" -o wide || kubectl -n $NAMESPACE get pod $NAME -o wide
```

---

## Step 2 — Rollout / revision history (deploy & sts only)


```bash
case "$KIND" in
  deployment|deploy|statefulset|sts|daemonset|ds)
    kubectl -n $NAMESPACE rollout status $KIND/$NAME --timeout=10s || true
    kubectl -n $NAMESPACE rollout history $KIND/$NAME
    # Recent ReplicaSets (deploy) with creation times and replica counts
    [ "$KIND" = "deployment" ] || [ "$KIND" = "deploy" ] && \
      kubectl -n $NAMESPACE get rs -l "$SEL" -o custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas,AGE:.metadata.creationTimestamp --sort-by=.metadata.creationTimestamp
    ;;
esac
```

Flag: stuck rollout, multiple active ReplicaSets, frequent revisions (deploy thrash).

---

## Step 3 — Spec sanity check


```bash
kubectl -n $NAMESPACE get $KIND $NAME -o json | jq '{
  replicas: .spec.replicas,
  strategy: (.spec.strategy // .spec.updateStrategy),
  selector: .spec.selector,
  serviceAccount: .spec.template.spec.serviceAccountName,
  imagePullSecrets: .spec.template.spec.imagePullSecrets,
  nodeSelector: .spec.template.spec.nodeSelector,
  tolerations: .spec.template.spec.tolerations,
  affinity: .spec.template.spec.affinity,
  topologySpread: .spec.template.spec.topologySpreadConstraints,
  containers: [.spec.template.spec.containers[] | {
    name, image,
    resources,
    livenessProbe, readinessProbe, startupProbe,
    env: ([.env[]?.name] // []),
    envFrom: ([.envFrom[]? | (.configMapRef.name // .secretRef.name)] // []),
    volumeMounts: ([.volumeMounts[]?.name] // []),
    securityContext
  }],
  volumes: [.spec.template.spec.volumes[]? | {name, type: (keys - ["name"])[0]}]
}'
```

Flag: missing requests/limits, no probes, no readinessProbe (rolling updates lie about readiness), `latest` tag, runs as root, missing `imagePullSecrets` for private registry, oversized resources vs cluster.

---

## Step 4 — Pod-level health for owned pods


```bash
kubectl -n $NAMESPACE get pods -l "$SEL" -o json | jq -r '
  .items[] | {
    pod: .metadata.name,
    phase: .status.phase,
    node: .spec.nodeName,
    age: .metadata.creationTimestamp,
    restarts: ([.status.containerStatuses[]?.restartCount] | max // 0),
    ready: ([.status.containerStatuses[]?.ready] | all),
    waiting: [.status.containerStatuses[]? | .state.waiting? | select(.!=null) | .reason],
    terminated: [.status.containerStatuses[]? | .lastState.terminated? | select(.!=null) | {reason, exitCode, finishedAt}],
    qos: .status.qosClass
  }'
```

For each Not Ready / restarting pod also run:

```bash
kubectl -n $NAMESPACE describe pod <pod> | sed -n '/Events:/,$p'
kubectl -n $NAMESPACE get events --field-selector involvedObject.name=<pod> --sort-by=.lastTimestamp
```

---

## Step 5 — Logs and error mining

```bash
for p in $(kubectl -n $NAMESPACE get pods -l "$SEL" -o name); do
  echo "===== $p ====="
  kubectl -n $NAMESPACE logs $p --all-containers --tail=$LOG_TAIL --timestamps
  kubectl -n $NAMESPACE logs $p --all-containers --previous --tail=$LOG_TAIL --timestamps 2>/dev/null
done
```

Search for: `error`, `fatal`, `panic`, `exception`, `traceback`, `failed`, `timeout`, `refused`, `denied`, `unauthorized`, `OOM`, `evicted`, `connection reset`, `dial tcp`, `no such host`, `permission denied`, `bind: address already in use`. Group identical messages; report count + first/last timestamp + sample line.

---

## Step 6 — Probe failure analysis


```bash
kubectl -n $NAMESPACE get events --field-selector reason=Unhealthy --sort-by=.lastTimestamp | tail -50
kubectl -n $NAMESPACE get events --field-selector reason=ProbeWarning --sort-by=.lastTimestamp | tail -50
```

Cross-reference probe configs from Step 3 against failures. Flag: too-aggressive `initialDelaySeconds`, identical liveness+readiness probes, probes hitting wrong port/path, exec probes that fork heavy processes.

---

## Step 7 — Resource usage vs requests/limits


```bash
kubectl -n $NAMESPACE top pods -l "$SEL" --containers 2>/dev/null || echo "metrics-server not available"
# OOMKills in last window
kubectl -n $NAMESPACE get pods -l "$SEL" -o json | jq -r '
  .items[] | .metadata.name as $p | .status.containerStatuses[]? |
  select(.lastState.terminated.reason=="OOMKilled") |
  "\($p) container=\(.name) exit=\(.lastState.terminated.exitCode) at=\(.lastState.terminated.finishedAt)"'
```

Flag: usage > 80% of limit (throttling/OOM risk), usage << request (over-provisioned), missing requests (BestEffort QoS), CPU limit on latency-sensitive workload (throttling).

---

## Step 8 — Networking exposure


```bash
# Services that select these pods
kubectl -n $NAMESPACE get svc -o json | jq -r --arg sel "$SEL" '
  .items[] | select(.spec.selector != null) |
  (.spec.selector | to_entries | map("\(.key)=\(.value)") | join(",")) as $s |
  select($sel | contains($s)) |
  "\(.metadata.name) type=\(.spec.type) clusterIP=\(.spec.clusterIP) ports=\([.spec.ports[]|"\(.port)->\(.targetPort)/\(.protocol)"]|join(","))"'
# Endpoints health for those services
for svc in $(kubectl -n $NAMESPACE get svc -o name); do
  ep=$(kubectl -n $NAMESPACE get endpoints ${svc#service/} -o jsonpath='{.subsets[*].addresses[*].ip}')
  echo "$svc endpoints: ${ep:-<none>}"
done
# Ingresses / NetworkPolicies referencing this workload's labels
kubectl -n $NAMESPACE get ingress 2>/dev/null
kubectl -n $NAMESPACE get networkpolicy 2>/dev/null
```

Flag: service with no endpoints, named-port mismatch, NetworkPolicy denying expected traffic, Ingress without IP/host.

---

## Step 9 — Storage (PVCs and mounts)


```bash
kubectl -n $NAMESPACE get $KIND $NAME -o json | jq -r '
  .spec.template.spec.volumes[]? | select(.persistentVolumeClaim) |
  .persistentVolumeClaim.claimName' | while read pvc; do
    [ -z "$pvc" ] && continue
    kubectl -n $NAMESPACE get pvc "$pvc" -o wide
    pv=$(kubectl -n $NAMESPACE get pvc "$pvc" -o jsonpath='{.spec.volumeName}')
    [ -n "$pv" ] && kubectl get pv "$pv" -o wide
done
kubectl -n $NAMESPACE get events --field-selector reason=FailedMount --sort-by=.lastTimestamp | tail -20
kubectl -n $NAMESPACE get events --field-selector reason=FailedAttachVolume --sort-by=.lastTimestamp | tail -20
```

Flag: PVC not Bound, FailedMount events, ReadWriteOnce PVC referenced by multi-replica Deployment across nodes.

---

## Step 10 — Config & secrets referenced


```bash
kubectl -n $NAMESPACE get $KIND $NAME -o json | jq -r '
  .spec.template.spec |
  (.containers[].envFrom[]? | (.configMapRef.name, .secretRef.name)),
  (.containers[].env[]?.valueFrom? | (.configMapKeyRef.name, .secretKeyRef.name)),
  (.volumes[]? | (.configMap.name, .secret.secretName))
' | grep -v null | sort -u | while read ref; do
    kubectl -n $NAMESPACE get cm "$ref" 2>/dev/null && continue
    kubectl -n $NAMESPACE get secret "$ref" 2>/dev/null
done
```

Flag: referenced ConfigMap/Secret missing → `CreateContainerConfigError`. Do **not** print secret values.

---

## Step 11 — Image and pull diagnostics


```bash
kubectl -n $NAMESPACE get $KIND $NAME -o jsonpath='{.spec.template.spec.containers[*].image}{"\n"}'
kubectl -n $NAMESPACE get events --field-selector reason=Failed,reason=BackOff --sort-by=.lastTimestamp | grep -iE "pull|image" | tail -20
```

Flag: `:latest` tag, image not pinned by digest, repeated `ImagePullBackOff`, missing `imagePullSecrets`.

---

## Step 12 — Generate report

Write `$REPORT_DIR/k8s-workload-<ns>-<kind>-<name>-<timestamp>.md` containing:

1. Header (context, namespace, kind, name, scope of selector, timestamp).
2. Executive summary + verdict (Healthy / Degraded / Failing).
3. Top findings ranked 🔴/🟡/🔵 with concrete next-step `kubectl` commands.
4. Per-step results (rollout, spec, pods, logs, probes, resources, network, storage, config, images).
5. Aggregated log error table.
6. Recommended actions (P1/P2/P3).
7. Appendix: full command transcript.

After writing, print the path and the top 3 P1 actions.

---

## Triage cheat-sheet

- **Rollout stuck** → `kubectl rollout history`, check progressDeadlineSeconds, look for failing readinessProbe.
- **CrashLoopBackOff** → previous logs (`--previous`), exit code 137=OOM, 1=app, 139=segfault.
- **ImagePullBackOff** → registry auth, image typo, network egress, private registry CA.
- **CreateContainerConfigError** → missing CM/Secret keys (Step 10).
- **Pending forever** → events show FailedScheduling reason; check requests vs node capacity, taints, PVC binding.
- **Random 500s in service** → endpoints empty briefly during rollout (no readiness probe), or readiness probe lies.
- **Pod evicted** → node DiskPressure/MemoryPressure or ephemeral-storage limit exceeded.

---

## Safety rules

- All commands above are **read-only**. Do not exec, restart, scale, patch, or delete anything.
- Do not print secret values; names + key lists only.
- If RBAC blocks a command, record it in the report and continue.
