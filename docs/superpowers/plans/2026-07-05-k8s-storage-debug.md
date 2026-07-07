# /k8s-storage-debug Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new `/k8s-storage-debug` slash command that traces the Kubernetes storage stack top-down (pod → PVC → PV → StorageClass → CSI driver → node disk pressure) and produces a severity-ranked markdown report.

**Architecture:** Single new workflow file at `.claude/commands/k8s-storage-debug.md` following the existing command conventions. Two supporting prose edits (README table + CHANGELOG). No new dependencies, no new scripts, no schema changes.

**Tech Stack:** Markdown, YAML frontmatter, bash (`kubectl`, `grep`, `awk`), `./scripts/validate-repo.sh`, `npx markdownlint-cli2`.

## Global Constraints

- Workflow must be **read-only** — zero mutations under any flag (no `kubectl apply/delete/patch/exec`).
- YAML frontmatter keys: `description` (one sentence) and `argument-hint` exactly as specified in the spec.
- All bash code blocks must have a language tag (`bash`) — MD040 rule.
- No bold section headings in place of `###` headings — MD036 rule.
- Table style must be compact (no aligned padding) — MD060 rule.
- Secret values must never be printed; names/types/counts only.
- Degrade gracefully when optional tools (`jq`, `metrics-server`, `helm`) are absent.
- End with a timestamped report written to `REPORT_DIR`.
- `./scripts/validate-repo.sh` must pass with zero errors after each commit.
- `npx markdownlint-cli2 .claude/commands/k8s-storage-debug.md` must pass with zero errors.
- Omit `Co-Authored-By: Claude ...` from every commit.
- Branch off `main`; PR targets `main`.

---

### Task 1: Create `.claude/commands/k8s-storage-debug.md`

**Files:**

- Create: `.claude/commands/k8s-storage-debug.md`

**Interfaces:**

- Consumes: spec at `docs/superpowers/specs/2026-07-05-k8s-storage-debug-design.md`
- Produces: a working slash command file that `validate-repo.sh` and `markdownlint-cli2` accept without errors

- [ ] **Step 1: Create the branch**

```bash
git checkout main && git pull && git checkout -b feat/k8s-storage-debug
```

Expected: `Switched to a new branch 'feat/k8s-storage-debug'`

- [ ] **Step 2: Verify validate-repo fails before the file exists**

```bash
./scripts/validate-repo.sh 2>&1 | grep -c "k8s-storage-debug" || true
```

Expected: `0` (the file simply doesn't exist yet — not a failure, just confirming start state).

- [ ] **Step 3: Write the workflow file**

Create `.claude/commands/k8s-storage-debug.md` with the exact content below. Copy verbatim — every fence needs a language tag, every heading must be `#`/`##`/`###`, no bold text standing in for headings, tables must be compact (no aligned padding):

````markdown
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

```
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
- **PV Released** → reclaim policy is `Retain`; requires manual `kubectl delete pv` after verifying data is safe.

---

## Safety rules

- All commands above are **read-only**. Do not apply, patch, delete, or exec anything.
- Do not print secret values (e.g. from storage credentials Secrets) — names and key lists only.
- If RBAC blocks a command, record it in the report and continue — never attempt privilege escalation.
- Confirm context with the user before running any command (Step 1).
````

- [ ] **Step 4: Run validate-repo.sh and confirm it passes**

```bash
./scripts/validate-repo.sh
```

Expected: zero errors. If it fails on the new file, the error message will name the failing check — fix it before proceeding.

- [ ] **Step 5: Run markdownlint on the new file**

```bash
npx markdownlint-cli2 .claude/commands/k8s-storage-debug.md 2>&1
```

Expected: no output (zero violations). If violations appear, fix them inline (most common: bare fence → add `bash`, bold heading → convert to `###`, aligned table → remove padding).

- [ ] **Step 6: Commit**

```bash
git add .claude/commands/k8s-storage-debug.md
git commit -m "feat: add /k8s-storage-debug workflow"
```

---

### Task 2: Update README Available Workflows table

**Files:**

- Modify: `README.md`

**Interfaces:**

- Consumes: the workflow name and description from Task 1's frontmatter
- Produces: a new row in the Available Workflows table that is visually consistent with existing rows

- [ ] **Step 1: Locate the Kubernetes section in the Available Workflows table**

```bash
grep -n "k8s\|kubernetes\|Kubernetes" README.md | head -20
```

Expected: lines showing the table header and existing `k8s-*` rows.

- [ ] **Step 2: Add the new row**

In `README.md`, find the Kubernetes workflow block in the Available Workflows table. Add the following row **after** the last `k8s-*` row and **before** the next section separator:

```markdown
| `/k8s-storage-debug` | Diagnose Kubernetes storage issues top-down: pod → PVC → PV → StorageClass → CSI driver → node disk pressure. Read-only, generates a markdown report. |
```

Match the exact column ordering and compact table style (no aligned padding) of surrounding rows.

- [ ] **Step 3: Verify the table still renders correctly**

```bash
grep -A2 -B2 "k8s-storage-debug" README.md
```

Expected: the new row surrounded by the adjacent existing rows, same pipe-separated format.

- [ ] **Step 4: Run markdownlint on README**

```bash
npx markdownlint-cli2 README.md 2>&1
```

Expected: no output.

- [ ] **Step 5: Run validate-repo.sh**

```bash
./scripts/validate-repo.sh
```

Expected: zero errors.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs: add /k8s-storage-debug to Available Workflows table"
```

---

### Task 3: Update CHANGELOG [Unreleased]

**Files:**

- Modify: `CHANGELOG.md`

**Interfaces:**

- Consumes: nothing from previous tasks (prose edit only)
- Produces: a CHANGELOG entry that records the new workflow under `[Unreleased] → Added`

- [ ] **Step 1: Locate the [Unreleased] section**

```bash
grep -n "^## \[" CHANGELOG.md | head -5
```

Expected: first line is `## [Unreleased]`, followed by the most recent release.

- [ ] **Step 2: Add the entry**

In `CHANGELOG.md`, under `## [Unreleased]`, add (or append to) an `### Added` subsection:

```markdown
## [Unreleased]

### Added
- `/k8s-storage-debug` — read-only Kubernetes storage stack debugger: pod → PVC → PV → StorageClass → CSI driver → node disk pressure, with severity-ranked markdown report
```

If an `### Added` subsection already exists under `[Unreleased]`, append the bullet to it rather than creating a duplicate subsection.

- [ ] **Step 3: Verify CHANGELOG structure is intact**

```bash
grep -n "^## \[" CHANGELOG.md | head -5
```

Expected: `## [Unreleased]` is still first, followed by the previous release line — order must not change.

- [ ] **Step 4: Run markdownlint on CHANGELOG**

```bash
npx markdownlint-cli2 CHANGELOG.md 2>&1
```

Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md
git commit -m "chore: changelog entry for /k8s-storage-debug"
```

---

### Task 4: Validate, agent review, and open PR

**Files:**

- No file edits — this task runs checks and opens the PR.

**Interfaces:**

- Consumes: all commits from Tasks 1–3 on branch `feat/k8s-storage-debug`
- Produces: a passing PR ready for merge

- [ ] **Step 1: Full validate-repo.sh pass**

```bash
./scripts/validate-repo.sh
```

Expected: zero errors. The script checks frontmatter (`description` + `argument-hint` on every workflow), README local links, and script executability.

- [ ] **Step 2: Full markdownlint pass on all touched files**

```bash
npx markdownlint-cli2 .claude/commands/k8s-storage-debug.md README.md CHANGELOG.md 2>&1
```

Expected: no output.

- [ ] **Step 3: Dispatch the workflow-author agent for review**

Use the `workflow-author` agent (available in the Agent tool) to review `.claude/commands/k8s-storage-debug.md` against the repo contribution rules. Its punch list is the gate — fix every required item before opening the PR.

- [ ] **Step 4: Fix any required items from the punch list**

Address each item flagged as required by the workflow-author agent. For each fix:

```bash
# After editing the file:
npx markdownlint-cli2 .claude/commands/k8s-storage-debug.md 2>&1
./scripts/validate-repo.sh
git add .claude/commands/k8s-storage-debug.md
git commit -m "fix: workflow-author review: <short description>"
```

- [ ] **Step 5: Push branch**

```bash
git push -u origin feat/k8s-storage-debug
```

- [ ] **Step 6: Open PR**

```bash
gh pr create \
  --title "feat: add /k8s-storage-debug workflow" \
  --body "$(cat <<'EOF'
## Summary

- Adds `/k8s-storage-debug` — a read-only, top-down Kubernetes storage stack debugger covering pod → PVC → PV → StorageClass → CSI driver → node disk pressure.
- Updates README Available Workflows table with the new entry.
- Adds CHANGELOG `[Unreleased]` entry.

## Test plan

- [ ] `./scripts/validate-repo.sh` passes
- [ ] `npx markdownlint-cli2 .claude/commands/k8s-storage-debug.md README.md CHANGELOG.md` passes with zero violations
- [ ] workflow-author agent review punch list: all required items resolved
- [ ] CI (validate + markdown + shellcheck jobs) passes
- [ ] Frontmatter `description` and `argument-hint` are present and match spec
- [ ] All bash code blocks have language tag (`bash`)
- [ ] No secret values printed in any step (names/types only)
- [ ] Report written to `REPORT_DIR/k8s-storage-debug-YYYYMMDD-HHMMSS.md`
EOF
)"
```

Expected: PR URL printed.
