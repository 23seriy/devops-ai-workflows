---
description: Read-only Terraform state diagnostics — state locks, drift, orphans, workspace mapping, and backend health. Generates a markdown report.
argument-hint: "WORKDIR=<path> [WORKSPACE=default] [ENV_FILE=...] [DEEP=yes|no] [REPORT_DIR=...]"
---

# /terraform-state-debug — Terraform State Diagnostics

Diagnose Terraform state problems: stale locks, drift between state and real infrastructure, orphaned resources, workspace/backend misconfiguration, and resource-count anomalies. **Read-only** — no state is modified. Break-glass operations (`force-unlock`, `state rm`) are listed as recommended actions only.

## Prerequisites

- `terraform` CLI v1.x installed (`terraform version`).
- Initialized working directory (`.terraform/` present) with a reachable backend.
- Read access to the backend (S3 + DynamoDB, GCS, AzureRM, Terraform Cloud) and the cloud provider.
- Optional: `jq` (parser for `show -json` output).

## Inputs

- **WORKDIR** *(required)* — path to the Terraform working directory containing `.terraform/`.
- **WORKSPACE** — Terraform workspace to inspect. Default: `default`.
- **ENV_FILE** — optional file of environment variables (exports) needed for the backend/provider, sourced before commands. Default: none.
- **DEEP** — `yes` runs a `terraform plan -refresh-only` drift check and parses `show -json` for a full resource inventory. Default: `no`.
- **REPORT_DIR** — report output directory. Default: `./terraform-state-debug-reports`.

Confirm the working directory, workspace, and target account/project with the user **before running any command**. Never pass `-auto-approve` or any apply flag.

---

## Step 1 — Verify CLI, working directory, and backend

```bash
cd "$WORKDIR"
terraform version

echo "=== Backend configuration ==="
terraform init -input=false -lock=false 2>&1 | tail -20

echo "=== Workspace ==="
terraform workspace show
terraform workspace list
```

Flag:

- `terraform init` failing (backend unreachable, missing backend creds, version constraints).
- Active workspace not equal to `WORKSPACE` — different workspaces can point at different accounts.
- Local state (`terraform.tfstate` in the workdir) for what should be a remote backend — flag as a collaboration/backup risk.
- No state locking backend (`dynamodb` for S3, or TFC) — concurrent runs can corrupt state.

---

## Step 2 — State lock status

```bash
echo "=== Lock info (if backend supports it) ==="
terraform force-unlock -help >/dev/null 2>&1 && echo "force-unlock available"

# S3+DynamoDB backends: inspect the lock item directly
if command -v aws >/dev/null 2>&1; then
  aws dynamodb scan --table-name "${TF_LOCK_TABLE:-}" \
    --filter-expression "attribute_exists(LockID)" --max-items 5 2>/dev/null \
    || echo "TF_LOCK_TABLE not set or no lock table (check backend config)"
fi
```

Flag:

- A lock present with an old `Info.Created` timestamp — a run crashed or was killed.
- Recommend `terraform force-unlock <LOCK_ID>` **only after** confirming no run is in progress and recording the lock ID — list it as an action, never execute.
- For Terraform Cloud, check the workspace run queue in the UI/API rather than the DynamoDB path.

---

## Step 3 — State inventory and resource count

```bash
terraform state list 2>/dev/null | sort > /tmp/tf-state-list.txt
echo "Resources in state: $(wc -l < /tmp/tf-state-list.txt)"

echo "=== Resources per module ==="
awk -F. '{print $1"."$2}' /tmp/tf-state-list.txt | sort | uniq -c | sort -rn | head -20

echo "=== State metadata ==="
terraform state pull 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print("serial:", d.get("serial")); print("lineage:", d.get("lineage")); print("terraform_version:", d.get("terraform_version")); print("resources:", len(d.get("resources",[])))' 2>/dev/null
```

Flag:

- `terraform_version` in state newer than the installed CLI (may fail to plan).
- Unexpected resource count (compared with what the config declares) — orphan or missing resources.
- Very old `serial` / `lineage` mismatch between environments — flag for review.

---

## Step 4 — Drift detection (DEEP)

```bash
if [ "${DEEP:-no}" = "yes" ]; then
  echo "=== Drift check (no changes applied) ==="
  terraform plan -refresh-only -lock=false -input=false -detailed-exitcode 2>&1 | tail -40
  echo "plan exit: $? (0=no drift, 2=drift, 1=error)"
fi
```

Drift exit codes are meaningful: `0` = no drift, `2` = drift detected, `1` = error. Report the code explicitly rather than "skipping".

---

## Step 5 — Orphans and missing resources

```bash
# In state but possibly gone from the provider
if [ "${DEEP:-no}" = "yes" ]; then
  for addr in $(head -100 /tmp/tf-state-list.txt); do
    terraform state show -no-color "$addr" >/dev/null 2>&1 || echo "INACCESSIBLE: $addr"
  done
fi
```

Flag:

- Addresses that fail `state show` with a refresh error — resource deleted out-of-band (orphan) or provider auth problem.
- No counterpart in config for a state address (removed from code, left in state) — candidate for `terraform state rm` (list as action only).
- Config resources absent from state (never imported) — candidate for import.

---

## Step 6 — Generate report

Compile all findings into a timestamped Markdown report:

```text
$REPORT_DIR/terraform-state-debug-<workspace>-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# Terraform State Debug Report

| Field | Value |
|---|---|
| Generated | <timestamp> |
| Working dir | <path> |
| Workspace | <name> |
| Backend | <type> |
| State version | <serial / lineage> |
| Resources | <n> |
| Drift | <none / detected / not checked> |

## Executive summary
<verdict: 🟢 healthy / 🟡 needs attention / 🔴 critical findings>
<top 3–5 findings ranked by severity>

## Findings by category
### Backend and workspace
### Locking
### State integrity
### Drift
### Orphans and missing resources

## Recommended actions
<prioritized, with confirm-then-run commands — never executed by this workflow>
```

---

## Safety rules

- Every command is **read-only** against state. Never run `terraform apply`, `destroy`, `import`, `state rm`, `state mv`, `state push`, or `force-unlock`.
- `terraform init` runs with `-lock=false` and never upgrades state; `-upgrade` is not used.
- Never print state file contents or provider credentials. Report only addresses, counts, versions, and lineage/serial.
- Recommend break-glass operations with explicit "confirm no active run" guidance — do not execute them.
- Confirm working directory and workspace with the user before running anything.
