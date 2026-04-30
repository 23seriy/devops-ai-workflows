
# /helm-release-debug — Helm Release Diagnostics

For when `helm upgrade` is stuck `pending-upgrade`, a release is `failed`, hooks won't finish, or the workload looks healthy in `helm` but broken in Kubernetes (or vice versa).

## Prerequisites

- `helm` v3 CLI configured against the same cluster.
- `kubectl` configured for the same cluster.
- Optional: `jq`, `yq`, `dyff` (better YAML diff).
- RBAC: `get`/`list` on the release's namespace + the resources the chart creates.

## Inputs

- **NAMESPACE** *(required)* — release namespace.
- **RELEASE** *(required)* — Helm release name.
- **REPORT_DIR** — Default: `./helm-release-reports`.

---

## Step 1 — Release status & history


```bash
helm -n $NAMESPACE status $RELEASE
helm -n $NAMESPACE history $RELEASE --max=20
helm -n $NAMESPACE get metadata $RELEASE 2>/dev/null
```

Flag:

- Status `pending-install` / `pending-upgrade` / `pending-rollback` → previous operation crashed; release is locked.
- Status `failed` → check last hooks and resources.
- Many revisions in a short window → upgrade thrash; likely values churn or readiness issues.

---

## Step 2 — Stuck-pending release recovery hint (no action, just suggest)

If status is `pending-*` and no `helm upgrade/rollback` is currently running:

```text
Likely a previous operation was killed (timeout, Ctrl-C, controller restart).
Safe recovery options (run manually after confirming nothing is in-flight):
  - helm -n $NAMESPACE rollback $RELEASE <last-good-revision>
  - or, as a last resort: kubectl -n $NAMESPACE patch secret \
      sh.helm.release.v1.$RELEASE.v<revision> --type=merge \
      -p '{"metadata":{"labels":{"status":"deployed"}}}'
```

The workflow itself does **not** run these — it only includes them in the report.

---

## Step 3 — Values diff vs previous revision

```bash
helm -n $NAMESPACE get values $RELEASE --revision=$(helm -n $NAMESPACE history $RELEASE -o json | jq -r '.[-1].revision') -a > /tmp/cur.yaml
prev=$(helm -n $NAMESPACE history $RELEASE -o json | jq -r '.[-2].revision // empty')
if [ -n "$prev" ]; then
  helm -n $NAMESPACE get values $RELEASE --revision=$prev -a > /tmp/prev.yaml
  diff -u /tmp/prev.yaml /tmp/cur.yaml | head -200
fi
```

Flag: changes in image tags, replica counts, resources, securityContext, ingress hosts. These are the most common rollout-breakers.

---

## Step 4 — Rendered manifest sanity


```bash
helm -n $NAMESPACE get manifest $RELEASE > /tmp/manifest.yaml
grep -E '^(apiVersion|kind|metadata|  name|  namespace):' /tmp/manifest.yaml | head -200
# Object inventory
grep -cE '^kind: ' /tmp/manifest.yaml
grep -E '^kind: ' /tmp/manifest.yaml | sort | uniq -c | sort -rn
```

Flag: deprecated apiVersions (compare against current cluster version — see `/k8s-upgrade-readiness`); kinds the cluster doesn't support (CRD missing).

---

## Step 5 — Hooks (pre/post-install/upgrade/delete)

```bash
helm -n $NAMESPACE get hooks $RELEASE > /tmp/hooks.yaml
grep -E 'helm.sh/hook' /tmp/hooks.yaml | sort -u
# Find hook pods/jobs and inspect them
kubectl -n $NAMESPACE get pods,jobs -l "helm.sh/chart" 2>/dev/null
kubectl -n $NAMESPACE get pods,jobs -l "app.kubernetes.io/managed-by=Helm,app.kubernetes.io/instance=$RELEASE" -o wide
# Most recent hook job logs
for j in $(kubectl -n $NAMESPACE get jobs -l app.kubernetes.io/instance=$RELEASE -o name 2>/dev/null); do
  echo "===== $j ====="
  kubectl -n $NAMESPACE describe $j | sed -n '/Events:/,$p'
  pod=$(kubectl -n $NAMESPACE get pods --selector=job-name=${j#job.batch/} -o name | head -1)
  [ -n "$pod" ] && kubectl -n $NAMESPACE logs $pod --tail=200
done
```

Flag: `pre-upgrade` / `pre-install` jobs failing (these block the whole release); `post-delete` hooks left running on a previous uninstall.

---

## Step 6 — Resources actually created

```bash
helm -n $NAMESPACE get manifest $RELEASE | yq '. | select(.kind != null) | [.kind, .metadata.name] | @tsv' 2>/dev/null \
  || awk '/^kind:/{k=$2} /^  name:/{print k, $2; k=""}' /tmp/manifest.yaml
```

For each resource, confirm presence and readiness in cluster:

```bash
helm -n $NAMESPACE get manifest $RELEASE | grep -E '^kind:|^  name:' | paste - - | while read k _ kind _ name; do
  kubectl -n $NAMESPACE get $kind $name 2>/dev/null || echo "MISSING $kind/$name"
done | head -200
```

Flag: resources in the manifest but missing in the cluster (uninstall race, hook failure mid-upgrade), or extra resources owned by the release that should have been pruned.

---

## Step 7 — Workload health for release-owned objects

```bash
kubectl -n $NAMESPACE get all -l app.kubernetes.io/instance=$RELEASE -o wide
kubectl -n $NAMESPACE get pods -l app.kubernetes.io/instance=$RELEASE -o json | jq -r '
  .items[] | select(
    (.status.phase != "Running" and .status.phase != "Succeeded") or
    ([.status.containerStatuses[]?.ready] | any(. == false)) or
    ([.status.containerStatuses[]?.restartCount] | max // 0) > 0
  ) | "\(.metadata.name) phase=\(.status.phase) restarts=\([.status.containerStatuses[]?.restartCount] | max // 0)"'
```

For any unhealthy pod, drop into `/k8s-workload-debug` for that workload.

---

## Step 8 — Events scoped to release

```bash
kubectl -n $NAMESPACE get events --sort-by=.lastTimestamp | grep -E "$RELEASE|Helm" | tail -50
kubectl -n $NAMESPACE get events --field-selector type=Warning --sort-by=.lastTimestamp | tail -100
```

Flag: `FailedCreate` from hook jobs, `BackOff`/`Failed` on release pods, webhook rejections during apply (`admission webhook ... denied the request`).

---

## Step 9 — Chart vs cluster compatibility


```bash
chart=$(helm -n $NAMESPACE get metadata $RELEASE -o json 2>/dev/null | jq -r '.chart')
appver=$(helm -n $NAMESPACE get metadata $RELEASE -o json 2>/dev/null | jq -r '.appVersion')
echo "Chart: $chart  appVersion: $appver"
kubectl version -o yaml | grep -E 'gitVersion|major|minor'
```

Look up the chart's `Chart.yaml` `kubeVersion` constraint if you have the chart locally; flag mismatches with the cluster's actual version.

---

## Step 10 — Release secret integrity


```bash
kubectl -n $NAMESPACE get secrets -l owner=helm,name=$RELEASE -o custom-columns=NAME:.metadata.name,STATUS:.metadata.labels.status,REVISION:.metadata.labels.version,AGE:.metadata.creationTimestamp
```

Flag: missing latest-revision secret (corrupted history → `helm history` lies); duplicate `deployed` labels across revisions (manual edits gone wrong).

---

## Step 11 — Generate report

Write `$REPORT_DIR/helm-$RELEASE-$NAMESPACE-<timestamp>.md`:

1. Header: cluster context, namespace, release, current revision/status, chart/appVersion.
2. Executive summary + verdict (Healthy / Stuck / Failed / Drifted).
3. **Top findings** ranked 🔴/🟡/🔵 with concrete next steps (rollback target, hook to retry, value to revert, resource to recreate).
4. Status & history table.
5. Values diff highlights from Step 3.
6. Hook failure analysis with logs (Step 5).
7. Resource inventory: rendered vs in-cluster, missing/extra.
8. Workload health summary (Step 7).
9. Events digest (Step 8).
10. Suggested commands — *for the user to run manually*: rollback, retry upgrade with `--atomic --wait --timeout`, force rerun of a hook, etc.
11. Appendix: command transcript.

Print path + verdict + top 3 actions.

---

## Triage cheat-sheet

- **`pending-upgrade` for hours** → previous operation died; safest fix is `helm rollback $RELEASE <last-deployed>`.
- **Hook job failed** → look at the *job's* pod logs; fix the hook image/script, then `helm upgrade --force` or delete the failed Job and retry.
- **`UPGRADE FAILED: ... has no deployed releases`** → all revisions failed; reinstall with `helm upgrade --install --atomic`.
- **Resource owned by another release / no owner labels** → drift from manual `kubectl apply`; reconcile values to match cluster, then `helm upgrade`.
- **Webhook denied admission** → the chart depends on a CRD or webhook that isn't ready yet; check installation order and `helm dependency`.
- **Pods Ready but service still down** → values changed selector/port; readiness lies because probes hit old version cached behind a Service. Check Step 6 + Step 7 together.

---

## Safety rules

- Read-only. Never run `helm upgrade`, `helm rollback`, `helm uninstall`, `kubectl delete`, or `kubectl patch` from this workflow.
- Suggested recovery commands are emitted into the report for the user to evaluate and run.
- Do not print Secret values; chart values are fine to print, but redact obvious secret-looking keys (`*password*`, `*token*`, `*key*`, `*cert*` data) when emitting the report.
