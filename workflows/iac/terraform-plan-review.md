---
description: Explain a Terraform plan and flag risky changes. Detects resource destroys, replacements, security group mutations, IAM changes, and blast radius. Read-only analysis of plan output.
---

# /terraform-plan-review — Terraform Plan Risk Analysis

Feed in a `terraform plan` (text, JSON, or saved plan file) and get a plain-English explanation of every change, grouped by risk level. Flags destroys, replacements, security-sensitive mutations, and blast-radius concerns. **No cloud access needed** — works purely on plan output.

## Prerequisites

- A `terraform plan` output. Any of:
  - Text output (pasted or piped from `terraform plan`).
  - JSON output (`terraform show -json <planfile>`).
  - A saved plan file on disk.
- Optional: `terraform` CLI (only needed if a binary plan file is provided and needs to be converted to JSON).
- Optional: `jq`.

## Inputs

- **PLAN_SOURCE** *(required)* — one of:
  - `text` — user will paste plan output.
  - `file:<path>` — path to a saved plan file or JSON.
  - `stdin` — plan will be piped.
- **REPORT_DIR** — Default: `./terraform-plan-reports`.

---

## Step 1 — Ingest and parse the plan

If the input is a binary plan file, convert it:

```bash
terraform show -json $PLAN_FILE > /tmp/tf-plan.json
```

If the input is text output, the agent should parse it directly.

If the input is already JSON, load it directly.

Identify:
- Total resources changing.
- Actions: `create`, `update`, `delete`, `replace` (delete+create), `read`.
- Provider and resource types.

---

## Step 2 — Classify changes by risk

### 🔴 Critical — immediate attention

Flag any of these:

- **Destroys** (`delete` or `replace`) of:
  - Databases: `aws_db_instance`, `aws_rds_cluster`, `google_sql_database_instance`, `azurerm_mssql_server`, etc.
  - Storage: `aws_s3_bucket`, `aws_efs_file_system`, `google_storage_bucket`, etc.
  - Encryption keys: `aws_kms_key`, `google_kms_crypto_key`, etc.
  - IAM identity providers, OIDC providers.
  - VPCs, subnets (cascading deletes).
  - Kubernetes clusters: `aws_eks_cluster`, `google_container_cluster`, `azurerm_kubernetes_cluster`.
  - Load balancers with active traffic.
  - DNS zones / records for production domains.

- **Replacements** (`delete` then `create`) of any stateful resource — data loss risk.

- **Security group / firewall rule changes** that:
  - Add `0.0.0.0/0` or `::/0` ingress.
  - Open sensitive ports (22, 3389, 3306, 5432, 6379).
  - Remove egress restrictions.

- **IAM changes** that:
  - Add `*:*` (admin) permissions.
  - Add `iam:PassRole` with `Resource: *`.
  - Modify trust policies to allow cross-account or `Principal: *`.
  - Create new IAM users with console access.

### 🟡 Warning — review carefully

- **Replacements** of any resource (even stateless — may cause downtime).
- **Updates** to:
  - Instance types / sizes (potential downtime).
  - AMI / image changes (rollout risk).
  - Listener / target group changes on load balancers.
  - Auto-scaling min/max changes.
  - Kubernetes node pool changes.
  - Network ACL / route table changes.
  - Certificate / TLS configuration changes.
  - Environment variables (may contain config changes).
- **Removing** resources that other resources depend on.
- **Changing** `prevent_destroy` lifecycle settings.
- **Large blast radius** — more than 20 resources changing in one plan.

### 🟢 Safe — low risk

- **Creates** of new resources (no existing infra affected).
- **Tag-only updates**.
- **Output changes**.
- **Data source refreshes** (`read`).
- **No-op** (0 changes).

---

## Step 3 — Blast radius analysis

Count and categorize:

```markdown
| Action | Count |
|---|---:|
| Create | X |
| Update | X |
| Delete | X |
| Replace | X |
| Read | X |
| **Total** | **X** |
```

Flag:
- More than 20 resources changing → **large blast radius**.
- More than 5 deletes → **high risk**.
- Any deletes of stateful resources → **data loss risk**.
- Resources across multiple environments/accounts in one plan → **scope concern**.

---

## Step 4 — Dependency and ordering analysis

For JSON plans, examine `resource_changes` and identify:

- Resources being replaced that have dependents — cascading impact.
- Resources being deleted that are referenced by other resources still in the state.
- Potential race conditions in parallel applies.
- Module-level changes that affect many child resources.

---

## Step 5 — Drift and import detection

Check for:

- Resources marked as `import` — new to state management, verify config matches reality.
- Resources with `before` values that differ from expected — possible manual drift.
- `moved` blocks — renamed resources, verify no unintended side effects.

---

## Step 6 — Provider-specific checks

### AWS
- `aws_security_group_rule` / `aws_vpc_security_group_ingress_rule` opening to `0.0.0.0/0`.
- `aws_iam_policy` / `aws_iam_role_policy` with `*` actions or resources.
- `aws_s3_bucket` public access changes.
- `aws_rds_instance` `publicly_accessible` changes.
- `aws_instance` `user_data` changes (forces replacement on some providers).
- `aws_launch_template` changes (may trigger rolling updates).

### Kubernetes / Helm
- `kubernetes_namespace` deletion (cascades all resources).
- `helm_release` chart version changes.
- `kubernetes_config_map` / `kubernetes_secret` changes (may trigger pod restarts).

### General
- `null_resource` / `local_exec` provisioners (arbitrary code execution).
- `random_*` resource recreation (may cascade to dependent resources).

---

## Step 7 — Generate report

Compile findings into a timestamped Markdown report:

```
$REPORT_DIR/terraform-plan-review-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# Terraform Plan Review

| Field | Value |
|---|---|
| Generated | <timestamp> |
| Plan source | <source> |
| Total changes | <count> |
| Risk level | 🔴 / 🟡 / 🟢 |

## Summary
<1-2 sentence plain-English summary of what this plan does>

## Change overview
| Action | Count |
|---|---:|
| Create | X |
| Update | X |
| Delete | X |
| Replace | X |

## 🔴 Critical findings
<destroys, security changes, IAM changes>

## 🟡 Warnings
<replacements, risky updates, blast radius>

## 🟢 Safe changes
<creates, tag updates, data refreshes>

## Resource-by-resource breakdown
<table of every resource with action, risk, and explanation>

## Recommendations
- Apply / Don't apply / Apply with caution
- Suggested mitigations (backups, staged rollout, etc.)
```

Present the user with:
1. Path to the saved report.
2. Risk verdict (🔴 / 🟡 / 🟢).
3. Whether it's safe to apply.
4. Top concerns if any.

---

## Safety rules

- This workflow is **entirely read-only**. It analyses plan output only — it never runs `terraform apply`.
- Never print secret values from plan output. If `sensitive` values appear in the plan JSON, redact them.
- If the plan contains credentials, tokens, or keys in plaintext, flag this as a finding.
- The workflow does not modify any infrastructure or state files.
