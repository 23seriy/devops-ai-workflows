# Kubernetes Debug Report

> Example output from `/k8s-debug`. Cluster, namespaces, and pod names are fictional.

| Field | Value |
|---|---|
| Generated | 2026-03-14 02:11:04 UTC |
| Context | `staging-eu-1` |
| Cluster version | v1.29.4 |
| Namespace | `payments` |
| Nodes | 6 (2 control-plane, 4 workers) |

## Executive summary

🟡 **Needs attention.** One deployment is running below desired replicas due to memory pressure; a PVC is stuck `Pending` because its StorageClass uses `WaitForFirstConsumer` and no scheduled pod is consuming it yet. No control-plane or node-level emergencies.

Top findings:

1. `payments-api` — 2/4 replicas Ready; two pods `OOMKilled` in the last hour.
2. `payments-cache` — pod `Pending`; PVC `payments-cache-data` unbound.
3. Node `worker-3` — disk usage at 91% (`DiskPressure` condition `True` briefly).

## Findings by category

### Workloads

- **`payments-api`**: `Deployment` 2/4 Ready. Events show `OOMKilled` for `payments-api-7d9f…`. Container limit is 256Mi; peak working set ~430Mi.
  - Suggested: raise memory limit to 512Mi and add a `HorizontalPodAutoscaler` on CPU.
- **`payments-cache`**: `Pod` Pending. `PersistentVolumeClaim payments-cache-data` is `Pending` (`WaitForFirstConsumer`). Scheduling is blocked because the node selector `disktype=ssd` matches no available node.

### Storage

- `payments-cache-data` (PVC) → no bound PV. StorageClass `fast-ssd` has `volumeBindingMode: WaitForFirstConsumer`.
- Suggested: confirm a node with label `disktype=ssd` exists, or relax the selector.

### Nodes

- `worker-3`: `DiskPressure=True` transiently. `/var/lib/kubelet` 91% full — image garbage collection threshold is 85/80%.
  - Suggested: prune unused images, or set `imageGCHighThresholdPercent: 80`.

### Events (last 60m, most frequent)

| Count | Reason | Involved object |
|---|---|---|
| 14 | `OOMKilling` | pod/payments-api-7d9f… |
| 6 | `FailedScheduling` | pod/payments-cache-0 |
| 2 | `EvictionThresholdMet` | node/worker-3 |

## Recommended actions

1. Raise `payments-api` memory limit to 512Mi and re-apply via GitOps.
2. Fix `payments-cache` scheduling (node label or PVC class).
3. Investigate disk growth on `worker-3`; consider a larger volume or image GC tuning.
