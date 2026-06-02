---
description: Pre-flight check before a Kubernetes control-plane / node upgrade. Scans for deprecated APIs, version skew, PDB gaps, expiring certs, and risky workload patterns. Read-only, produces a Markdown report.
auto_execution_mode: 2
---

# /k8s-upgrade-readiness — Cluster Upgrade Pre-Flight

Run this *before* upgrading the control plane or rolling node pools. Surfaces deprecated APIs, version skew, missing PodDisruptionBudgets, soon-to-expire certs, and other things that turn a routine upgrade into a 2 a.m. incident.

## Prerequisites

- `kubectl` configured.
- Optional: `kubent` (or `kube-no-trouble`) for deprecated API detection — workflow falls back to manual checks if missing.
- Optional: `pluto` (FairwindsOps) — same purpose as kubent.

## Inputs

- **TARGET_VERSION** — version you plan to upgrade *to* (e.g. `1.30`). Required for skew checks.
- **REPORT_DIR** — Default: `./k8s-upgrade-reports`.

---

## Step 1 — Current versions and skew

// turbo

```bash
kubectl version --output=yaml
kubectl get nodes -o json | jq -r '
  .items[] | "\(.metadata.name)\tkubelet=\(.status.nodeInfo.kubeletVersion)\truntime=\(.status.nodeInfo.containerRuntimeVersion)\tos=\(.status.nodeInfo.osImage)\tkernel=\(.status.nodeInfo.kernelVersion)"'
```

Skew rules to flag:

- **Control-plane → kubelet**: kubelet may be up to 3 minor versions older than apiserver (1.28+); never *newer*.
- **Control-plane minor jumps**: only one minor at a time (1.28 → 1.29 → 1.30, **not** 1.28 → 1.30).
- **Container runtime**: containerd ≥ 1.7 / CRI-O matching the kubelet line.

---

## Step 2 — Deprecated / removed APIs in cluster objects

// turbo

```bash
if command -v kubent >/dev/null 2>&1; then
  kubent --target-version=$TARGET_VERSION
elif command -v pluto >/dev/null 2>&1; then
  pluto detect-all-in-cluster --target-versions k8s=v$TARGET_VERSION
else
  echo "Install kubent (https://github.com/doitintl/kube-no-trouble) or pluto for full coverage."
  echo "Falling back to manual sweep..."
  # Common removals to spot-check
  kubectl get poddisruptionbudgets.policy/v1beta1 -A 2>&1 | head
  kubectl get cronjobs.batch/v1beta1 -A 2>&1 | head
  kubectl get horizontalpodautoscalers.autoscaling/v2beta2 -A 2>&1 | head
  kubectl get ingresses.networking.k8s.io/v1beta1 -A 2>&1 | head
  kubectl get flowschemas.flowcontrol.apiserver.k8s.io/v1beta2 -A 2>&1 | head
fi
```

Also scan Helm release manifests:

```bash
if command -v helm >/dev/null 2>&1; then
  for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
    helm -n $ns ls -q 2>/dev/null | while read r; do
      [ -n "$r" ] && helm -n $ns get manifest "$r" 2>/dev/null | grep -E '^apiVersion:' | sort -u | sed "s|^|$ns/$r: |"
    done
  done | grep -E 'v1beta1|v1alpha|v2beta' | head -100
fi
```

---

## Step 3 — Aggregated APIServices health

// turbo

```bash
kubectl get apiservices -o json | jq -r '
  .items[] | select(.spec.service != null) |
  .metadata.name as $n |
  ([.status.conditions[] | select(.type=="Available")][0]) as $c |
  "\($n)\tavailable=\($c.status)\treason=\($c.reason)\tservice=\(.spec.service.namespace)/\(.spec.service.name)"' | grep -v 'available=True'
```

Any non-Available aggregated API will block / break upgrades. Common offenders: `metrics.k8s.io`, custom `external.metrics.k8s.io`, admission webhooks tied to a service with no endpoints.

---

## Step 4 — Admission webhooks pointing at fragile services

// turbo

```bash
echo "=== Validating webhooks ==="
kubectl get validatingwebhookconfigurations -o json | jq -r '
  .items[] | .metadata.name as $n |
  .webhooks[]? | "\($n)\twebhook=\(.name)\tsvc=\(.clientConfig.service.namespace // "-")/\(.clientConfig.service.name // "-")\tfailurePolicy=\(.failurePolicy)"'
echo "=== Mutating webhooks ==="
kubectl get mutatingwebhookconfigurations -o json | jq -r '
  .items[] | .metadata.name as $n |
  .webhooks[]? | "\($n)\twebhook=\(.name)\tsvc=\(.clientConfig.service.namespace // "-")/\(.clientConfig.service.name // "-")\tfailurePolicy=\(.failurePolicy)"'
```

For each webhook: confirm the target Service has Endpoints (Step 8 of `/k8s-debug` covers this). `failurePolicy: Fail` + dead service = the upgraded API server will refuse to admit objects.

---

## Step 5 — PodDisruptionBudget coverage

// turbo

```bash
# Workloads with replicas > 1 but no PDB selecting them
kubectl get pdb -A -o json | jq -r '.items[] | "\(.metadata.namespace)\t\(.metadata.name)\tselector=\(.spec.selector.matchLabels)"' > /tmp/pdbs.txt
kubectl get deploy,sts -A -o json | jq -r '
  .items[] | select((.spec.replicas // 1) > 1) |
  "\(.metadata.namespace)/\(.kind)/\(.metadata.name) replicas=\(.spec.replicas) labels=\(.spec.template.metadata.labels)"' | head -100
```

Flag: multi-replica workloads with **no** PDB → a node drain during upgrade can take all replicas down at once. Also flag: PDBs with `minAvailable: 100%` or `maxUnavailable: 0` → drains will hang forever.

```bash
# PDBs that block all disruption
kubectl get pdb -A -o json | jq -r '.items[] |
  select(.spec.minAvailable == "100%" or .spec.maxUnavailable == 0 or .spec.minAvailable == .status.currentHealthy) |
  "\(.metadata.namespace)/\(.metadata.name) minAvail=\(.spec.minAvailable) maxUnavail=\(.spec.maxUnavailable)"'
```

---

## Step 6 — Single-replica workloads that will cause downtime

// turbo

```bash
kubectl get deploy,sts -A -o json | jq -r '
  .items[] | select((.spec.replicas // 1) == 1 and (.metadata.namespace | test("^kube-|^calico|^ingress|^cert-manager")|not)) |
  "\(.metadata.namespace)/\(.kind)/\(.metadata.name)"' | head -50
```

Inform the owners — these will have a downtime window during node drain.

---

## Step 7 — Certificate expiry

// turbo

```bash
# Control-plane certs (only on managed access; for self-managed run on master): kubeadm certs check-expiration
# Service account / TLS secrets approaching expiry:
kubectl get secrets -A -o json | jq -r '
  .items[] | select(.type=="kubernetes.io/tls") |
  "\(.metadata.namespace)/\(.metadata.name)"' | while read s; do
    ns=${s%%/*}; name=${s##*/}
    crt=$(kubectl -n $ns get secret $name -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null)
    [ -z "$crt" ] && continue
    end=$(echo "$crt" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    [ -n "$end" ] && echo "$s expires=$end"
done | head -50
# cert-manager Certificates close to renewal failure
kubectl get certificates -A 2>/dev/null | tail -50
kubectl get certificaterequests -A 2>/dev/null | grep -vE 'True|Approved' | head
```

Flag: any cert expiring within 30 days of upgrade window.

---

## Step 8 — Workloads relying on PodSecurityPolicy / removed beta features

// turbo

```bash
# PSP was removed in 1.25 — should be 0
kubectl get psp 2>&1 | head
# In-tree CSI volume migrations (vSphere, AWS EBS, GCE PD): check for in-tree volumes
kubectl get pv -o json | jq -r '
  .items[] | "\(.metadata.name)\ttype=\([.spec | keys[]] | map(select(. != "accessModes" and . != "capacity" and . != "claimRef" and . != "mountOptions" and . != "nodeAffinity" and . != "persistentVolumeReclaimPolicy" and . != "storageClassName" and . != "volumeMode")) | join(","))"' | grep -vE 'csi$' | head -30
```

Flag: clusters still pinned to deprecated in-tree volume plugins on versions where the corresponding migration is forced.

---

## Step 9 — Node pool readiness

// turbo

```bash
# Cordoned / unschedulable nodes already
kubectl get nodes -o json | jq -r '.items[] | select(.spec.unschedulable==true) | .metadata.name'
# Nodes near full (drain target nodes will need somewhere to go)
kubectl describe nodes | awk '/^Name:/{n=$2} /Allocated resources/,/Events/' | head -200
# DaemonSets that block drain
kubectl get pods -A -o json | jq -r '
  .items[] | select(.metadata.ownerReferences[]?.kind == "DaemonSet") |
  "\(.metadata.namespace)/\(.metadata.name) (DS)"' | sort -u | head -30
```

Flag: cluster running near node capacity → during a rolling upgrade there's no headroom to reschedule pods.

---

## Step 10 — CRDs and operators

// turbo

```bash
kubectl get crds -o json | jq -r '
  .items[] | .metadata.name as $n |
  .spec.versions[] | select(.served==true) |
  "\($n)\tversion=\(.name)\tstorage=\(.storage)"' | head -100
```

Flag: CRDs serving only `v1beta1` storage versions — operator must be upgraded before cluster upgrade. List operators (Deployments in obvious namespaces) and check their support matrix manually for `$TARGET_VERSION`.

---

## Step 11 — Generate report

Write `$REPORT_DIR/k8s-upgrade-<context>-<from>-to-$TARGET_VERSION-<timestamp>.md`:

1. Header: current control-plane version, kubelet versions, target version, cluster context.
2. Verdict: 🟢 Ready / 🟡 Ready with caveats / 🔴 Block upgrade.
3. **Blockers** (must fix before upgrade): deprecated APIs in use, dead webhooks with `failurePolicy: Fail`, version skew violations, full node pool, certs expiring during window.
4. **Warnings**: missing PDBs, single-replica prod workloads, soon-to-expire certs, CRD storage version migrations needed.
5. **Informational**: cluster capacity headroom, DaemonSets, operator inventory.
6. Per-step details from above, including raw findings.
7. Recommended sequence: fixes → control-plane upgrade → node pool roll → post-upgrade verification (suggest re-running `/k8s-debug`).
8. Appendix: full command transcript.

Print path + verdict + the blockers list.

---

## Recommended remediation order

1. Replace deprecated APIs in source repos / Helm charts (Step 2) — re-deploy.
2. Repair or remove broken admission webhooks (Step 4).
3. Add PDBs to multi-replica prod workloads (Step 5); fix unsplittable PDBs.
4. Renew or replace certificates expiring in the upgrade window (Step 7).
5. Upgrade operators / CRDs to versions that support `$TARGET_VERSION`.
6. Add node pool headroom (autoscaler max + buffer node).
7. Run `kubeadm upgrade plan` (or cloud provider equivalent) and proceed.

---

## Safety rules

- Read-only. Do not execute upgrades from this workflow.
- Don't print secret data; only metadata and expiry dates derived from public cert fields.
- Some checks (e.g. control-plane cert expiry on managed clusters) are cloud-provider specific — note "N/A managed" rather than guessing.
