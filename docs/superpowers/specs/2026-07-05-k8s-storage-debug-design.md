# /k8s-storage-debug Workflow Design

## Goal

A read-only, top-down Kubernetes storage debugger that traces the full storage
stack — pod → PVC → PV → StorageClass → CSI driver → node disk pressure —
and produces a severity-ranked markdown report. Fills the gap in the existing
k8s workflow suite, which covers networking, RBAC, workloads, and cost but not
storage volumes.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `NAMESPACE` | yes | — | Namespace to inspect |
| `CONTEXT` | no | current context | kubectl context name |
| `POD` | no | — | Narrow to a specific pod; if omitted, scans all pods with volume issues |
| `PVC` | no | — | Inspect a specific PVC directly without starting from a pod |
| `REPORT_DIR` | no | `./k8s-storage-debug-reports` | Where to write the report |

## Steps

All steps are read-only. No mutations, no `kubectl apply/delete/patch`.

### Step 1 — Context and identity check

Run `kubectl config current-context` and `kubectl cluster-info`. Confirm the
cluster identity with the user before proceeding. Stop and report if
connectivity fails — never try alternative contexts.

### Step 2 — Pod surface scan

Find pods with storage-related problems in `NAMESPACE`. If `POD` is set, scope
to that pod only.

Signals to look for:
- Phase: `Pending` or `ContainerCreating` for more than 2 minutes
- Events: `FailedMount`, `FailedAttach`, `VolumeNotFound`, `unable to mount`
- Init containers stuck waiting for volumes

Commands:
- `kubectl get pods -n NAMESPACE -o wide`
- `kubectl describe pod -n NAMESPACE POD` (or all pods if POD unset)
- `kubectl get events -n NAMESPACE --sort-by=.lastTimestamp | grep -iE "mount|attach|volume|pvc|pv"`

### Step 3 — PVC audit

For each PVC referenced by an affected pod (or for `PVC` if specified directly):

- Phase: `Pending` / `Bound` / `Lost`
- Access mode vs what the pod requests
- Storage class name
- Requested capacity vs actual (check for expansion in progress)
- Age (long-pending PVCs usually mean provisioner failure)
- Finalizers blocking deletion if PVC is stuck terminating

Commands:
- `kubectl get pvc -n NAMESPACE -o wide`
- `kubectl describe pvc -n NAMESPACE PVC_NAME`

### Step 4 — PV inspection

For each bound PV:

- Reclaim policy (`Retain` / `Delete` / `Recycle`)
- Backend type from `spec` (e.g. `awsElasticBlockStore`, `nfs`, `hostPath`, `csi`)
- Node affinity constraints (can cause unschedulable volumes if node is gone)
- Phase: `Available` / `Bound` / `Released` / `Failed`

Commands:
- `kubectl get pv`
- `kubectl describe pv PV_NAME`

### Step 5 — StorageClass check

For each StorageClass referenced:

- Provisioner (e.g. `ebs.csi.aws.com`, `kubernetes.io/no-provisioner`)
- Binding mode: `WaitForFirstConsumer` (zone-aware) vs `Immediate` (common source of zone mismatch bugs)
- `allowVolumeExpansion` — flag if expansion is needed but disabled
- Whether the provisioner is marked as default and whether multiple defaults exist (causes silent failures)
- Confirm the provisioner's controller pod is Running (checked in Step 6)

Commands:
- `kubectl get storageclass`
- `kubectl describe storageclass SC_NAME`

### Step 6 — CSI driver health

Find CSI driver pods (both node DaemonSet pods and controller Deployment pods).
Detection strategy: label selector `app.kubernetes.io/component in (csi-driver,csi-node,csi-controller)`
plus checking namespaces `kube-system` and any namespace containing `csi`.

For each CSI pod:
- Phase and readiness
- Recent log tail (last 50 lines) for errors: `error`, `failed`, `timeout`, `rpc`
- Restart count (high restarts = unstable driver)

Commands:
- `kubectl get pods -A -l app.kubernetes.io/component=csi-driver -o wide`
- `kubectl get pods -n kube-system | grep csi`
- `kubectl logs -n kube-system POD --tail=50`

Degrade gracefully: if no CSI pods found, note that the cluster may use
in-tree volume plugins or a non-standard label scheme.

### Step 7 — Node disk pressure

For each node that hosts (or could host) the affected pods:

- `DiskPressure` condition in `kubectl describe node`
- Allocatable vs capacity for `ephemeral-storage`
- Identify nodes with < 15% ephemeral storage free as eviction risk
  (derived from `capacity.ephemeral-storage` vs `allocatable.ephemeral-storage`
  in the node spec — no metrics-server required)
- Taints added by the kubelet under pressure (`node.kubernetes.io/disk-pressure`)

Note: live per-pod disk usage requires metrics-server. If unavailable, the
capacity/allocatable delta still gives a cluster-level picture — note the gap
in the report.

Commands:
- `kubectl get nodes -o wide`
- `kubectl describe nodes | grep -A5 "Conditions:"`
- `kubectl describe nodes | grep -A3 "Allocatable"`

### Step 8 — Generate report

Write to `REPORT_DIR/k8s-storage-debug-YYYYMMDD-HHMMSS.md`.

Structure:
```
# Kubernetes Storage Debug Report
| Field | Value |
| --- | --- |
| Cluster | ... |
| Namespace | ... |
| Generated | ... |

## Critical findings
## Warning findings
## Info / observations
## Raw evidence
```

Severity rules:
- **Critical**: PVC in `Pending` > 5 min with no provisioner activity; pod stuck
  `ContainerCreating` > 5 min; PV in `Failed`/`Released`; CSI controller not Running;
  node with `DiskPressure=True`
- **Warning**: StorageClass with no provisioner pod; `WaitForFirstConsumer` + pod
  with no node assigned; `allowVolumeExpansion: false` on a PVC that needs resizing;
  CSI pod restarting frequently
- **Info**: PVs with `Retain` reclaim policy that are `Released` (manual cleanup needed);
  multiple default StorageClasses; in-tree volume plugin detected

## Constraints

- Read-only. No mutations under any flag.
- No `kubectl exec` into pods.
- Works without `jq`, `metrics-server`, or any optional tooling — degrade gracefully.
- Confirm context before running any command.
- Never print secret values (e.g. from storage credentials Secrets) — names and types only.
- End with a timestamped report file for sharing.

## Frontmatter

```yaml
description: Diagnose Kubernetes storage issues top-down: pod → PVC → PV → StorageClass → CSI driver → node disk pressure. Read-only, generates a markdown report.
argument-hint: "NAMESPACE=... [CONTEXT=...] [POD=...] [PVC=...] [REPORT_DIR=...]"
```
