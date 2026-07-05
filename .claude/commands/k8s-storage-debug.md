---
description: Diagnose Kubernetes storage issues top-down: pod → PVC → PV → StorageClass → CSI driver → node disk pressure. Read-only, generates a markdown report.
argument-hint: "NAMESPACE=... [CONTEXT=...] [POD=...] [PVC=...] [REPORT_DIR=...]"
---

# /k8s-storage-debug — Kubernetes Storage Stack Debugger

Read-only, top-down storage diagnostic. Traces the full stack — pod → PVC → PV → StorageClass → CSI driver → node disk pressure — and produces a severity-ranked markdown report.

## Prerequisites

- `kubectl` configured for the target cluster.
- RBAC to `get`/`list` pods, PVCs, PVs, StorageClasses, nodes, and events in `NAMESPACE` plus `kube-system`.
- Optional: `jq` (degrades gracefully without it).

## Inputs

- **NAMESPACE** *(required)* — namespace to inspect.
- **CONTEXT** — kubectl context name. Default: current context.
- **POD** — narrow to a specific pod; if omitted, scans all pods with storage-related events.
- **PVC** — inspect a specific PVC directly without starting from a pod.
- **REPORT_DIR** — where to write the report. Default: `./k8s-storage-debug-reports`.

Confirm all inputs and current `kubectl config current-context` with the user **before running any command**.

---

## Step 1 — Context and identity check

```bash
kubectl config current-context
kubectl cluster-info --request-timeout=10s 2>&1 | head -5
```

Stop and report if connectivity fails. Never try alternative contexts or credentials. Confirm the displayed context matches the user's intent before proceeding.

---

## Step 2 — Pod surface scan

Find pods with storage-related problems in `NAMESPACE`. If `POD` is set, scope to that pod only.

```bash
kubectl get pods -n $NAMESPACE -o wide

# Storage-related events (FailedMount, FailedAttach, VolumeNotFound, unable to mount)
kubectl get events -n $NAMESPACE --sort-by=.lastTimestamp \
  | grep -iE "mount|attach|volume|pvc|pv|failedschedule" \
  | tail -40

# Per-pod detail for pods in non-Running/Completed phases
kubectl get pods -n $NAMESPACE -o json \
  | grep -E '"phase":|"reason":|"message":' \
  | head -60
```

If `POD` is set:

```bash
kubectl describe pod -n $NAMESPACE $POD
kubectl get events -n $NAMESPACE \
  --field-selector involvedObject.name=$POD \
  --sort-by=.lastTimestamp
```

Flag: `ContainerCreating` > 2 min, `Pending` > 2 min, `FailedMount`, `FailedAttachVolume`, `VolumeNotFound`, init containers stuck on volume wait.

---

## Step 3 — PVC audit

For each PVC referenced by an affected pod (or `PVC` if set directly):

```bash
kubectl get pvc -n $NAMESPACE -o wide

# Detailed view per PVC
kubectl describe pvc -n $NAMESPACE $PVC_NAME
```

Inspect:

- Phase: `Pending` / `Bound` / `Lost`
- Access mode vs what the pod requests (ReadWriteOnce on multi-replica Deployment = scheduling conflict)
- Storage class name
- Requested vs actual capacity (expansion in progress?)
- Age — long-pending PVC usually means provisioner failure
- Finalizers — if stuck terminating, check for `kubernetes.io/pvc-protection`

Flag: `Pending` > 5 min with no provisioner events; `Lost`; ReadWriteOnce PVC on a multi-node multi-replica Deployment; PVC stuck terminating with finalizers.

---

## Step 4 — PV inspection

For each bound PV (resolved from PVC `spec.volumeName`):

```bash
kubectl get pv -o wide

kubectl describe pv $PV_NAME
```

Inspect:

- Phase: `Available` / `Bound` / `Released` / `Failed`
- Reclaim policy: `Retain` / `Delete` / `Recycle`
- Backend type from `spec` (`awsElasticBlockStore`, `nfs`, `hostPath`, `csi`, etc.)
- Node affinity constraints — if the node is gone, the PV is unschedulable

Flag: `Released` or `Failed` PVs; `Retain` policy with `Released` status (manual cleanup needed); node affinity pointing to a removed node.

---

## Step 5 — StorageClass check

For each StorageClass referenced by the affected PVCs:

```bash
kubectl get storageclass

kubectl describe storageclass $SC_NAME
```

Inspect:

- Provisioner (e.g. `ebs.csi.aws.com`, `kubernetes.io/no-provisioner`)
- `volumeBindingMode`: `WaitForFirstConsumer` (zone-aware) vs `Immediate` (common zone mismatch source)
- `allowVolumeExpansion` — flag if expansion needed but disabled
- Whether the StorageClass is marked default (`storageclass.kubernetes.io/is-default-class: "true"`)

```bash
# Check for multiple default StorageClasses (causes silent provisioner confusion)
kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}'
```

Flag: provisioner not running (check Step 6); `WaitForFirstConsumer` + pod with no assigned node; `allowVolumeExpansion: false` when PVC needs resize; multiple default StorageClasses.

---

## Step 6 — CSI driver health

Locate CSI driver pods (controller Deployment and node DaemonSet):

```bash
# Standard label selectors
kubectl get pods -A -l app.kubernetes.io/component=csi-driver -o wide 2>/dev/null || true
kubectl get pods -A -l app.kubernetes.io/component=csi-controller -o wide 2>/dev/null || true
kubectl get pods -A -l app.kubernetes.io/component=csi-node -o wide 2>/dev/null || true

# Fallback: name-based search in kube-system
kubectl get pods -n kube-system -o wide | grep -iE "csi|ebs|efs|fsx|nfs" || true
```

For each CSI pod:

```bash
kubectl logs -n $CSI_NAMESPACE $CSI_POD --tail=50 2>/dev/null \
  | grep -iE "error|failed|timeout|rpc|unavailable" || true
```

Inspect: phase, readiness, restart count, recent log errors.

If no CSI pods found, note that the cluster may use in-tree volume plugins or a non-standard label scheme — record it in the report and continue.

Flag: CSI controller not Running; high restart count (> 5 in the last hour); log errors containing `rpc error`, `timeout`, `attachment limit`; node DaemonSet pod not Running on the affected pod's node.

---

## Step 7 — Node disk pressure

For each node that hosts (or could host) the affected pods:

```bash
kubectl get nodes -o wide

# DiskPressure condition and taint
kubectl describe nodes | grep -A5 "Conditions:"
kubectl describe nodes | grep -iE "diskpressure|disk-pressure"

# Allocatable vs capacity for ephemeral-storage (no metrics-server needed)
kubectl get nodes -o json \
  | grep -A2 -B2 '"ephemeral-storage"' \
  | head -60
```

Identify nodes where:

- `DiskPressure` condition is `True`
- The taint `node.kubernetes.io/disk-pressure` is present
- `allocatable.ephemeral-storage` is significantly less than `capacity.ephemeral-storage`
  (gap > 15% of capacity indicates kubelet has reserved headroom against eviction)

Note: live per-pod ephemeral usage requires `metrics-server`. If unavailable, record the gap in the report.

Flag: `DiskPressure=True`; disk-pressure taint present; allocatable/capacity ratio < 85%.

---

## Step 8 — Generate report

Create `$REPORT_DIR` if it does not exist, then write the report:

```text
$REPORT_DIR/k8s-storage-debug-YYYYMMDD-HHMMSS.md
```

Report structure:

```markdown
# Kubernetes Storage Debug Report

| Field | Value |
| --- | --- |
| Cluster | <current-context> |
| Namespace | <NAMESPACE> |
| Pod filter | <POD or "(all)"> |
| PVC filter | <PVC or "(all)"> |
| Generated | <timestamp> |

## Critical findings

<!-- PVC Pending > 5 min; pod stuck ContainerCreating > 5 min;
     PV Failed/Released; CSI controller not Running;
     node DiskPressure=True -->

## Warning findings

<!-- StorageClass with no provisioner pod; WaitForFirstConsumer + unscheduled pod;
     allowVolumeExpansion:false; CSI pod high restarts -->

## Info / observations

<!-- Retain policy Released PVs needing manual cleanup;
     multiple default StorageClasses; in-tree volume plugin detected -->

## Raw evidence

<!-- Step-by-step command output -->
```

After writing, print the report path and the top three critical findings with suggested next-step `kubectl` commands for each.

---

## Triage cheat-sheet

- **PVC Pending** → describe PVC for events; check provisioner pod is Running (Step 6); check `WaitForFirstConsumer` + pod node assignment.
- **FailedMount** → PVC phase, PV phase, and node DaemonSet pod on the target node (Step 6).
- **FailedAttachVolume** → CSI controller logs, PV node affinity vs pod's actual node (Steps 4 & 6).
- **DiskPressure** → `kubectl describe node <node>`, check kubelet ephemeral-storage threshold.
- **ReadWriteOnce multi-node conflict** → PVC access mode vs Deployment replica count and node spread.
- **PV Released** → reclaim policy is `Retain`; after verifying data is safe, a cluster admin must run `kubectl delete pv <name>` outside this workflow to release the volume.

---

## Safety rules

- All commands above are **read-only**. Do not apply, patch, delete, or exec anything.
- Do not print secret values (e.g. from storage credentials Secrets) — names and key lists only.
- If RBAC blocks a command, record it in the report and continue — never attempt privilege escalation.
- Confirm context with the user before running any command (Step 1).
