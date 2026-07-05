---
description: Pre-release safety checklist for application, infrastructure, or platform changes. Reviews deploy order, rollback, tests, monitoring, and communication before release.
argument-hint: "RELEASE_NAME=... [ENVIRONMENT=staging] [CHANGE_TYPE=app|infra|helm|terraform|pipeline|mixed]"
---

# /release-checklist — Pre-Release Safety Gate

Use before releasing application code, infrastructure changes, Helm charts, Terraform modules, or CI/CD updates. The workflow produces a release readiness report and highlights blockers before production deployment.

## Prerequisites

- PR/diff summary or release notes.
- Target environment and deployment method.
- Optional: test results, Terraform plan, Helm diff, ArgoCD app status, CI build URL.

## Inputs

- **RELEASE_NAME** *(required)* — short name of the change/release.
- **ENVIRONMENT** — target environment. Default: `staging`.
- **CHANGE_TYPE** — `app` | `infra` | `helm` | `terraform` | `pipeline` | `mixed`.
- **REPORT_DIR** — Default: `./release-checklist-reports`.

---

## Step 1 — Identify release scope

Gather:

- What is changing?
- Which repos/services/environments are affected?
- Is this a single-repo or multi-repo release?
- Is there a database, schema, IAM, networking, or config change?
- Is there a feature flag or staged rollout mechanism?

Classify risk:

| Risk | Criteria |
| --- | --- |
| Low | Backward-compatible, tested, easy rollback, small blast radius |
| Medium | Config/IaC changes, multiple services, partial rollback complexity |
| High | Data migration, IAM/networking, irreversible changes, production-wide impact |

---

## Step 2 — Validate test and build evidence

Check:

- CI build passed for the exact commit being deployed.
- Unit/integration/e2e tests relevant to the change passed.
- Security scans completed or exceptions are documented.
- Artifact/image tag is immutable and traceable to commit SHA.
- No local-only changes are required for deploy.

For infrastructure:

```bash
terraform validate
terraform plan -out=plan.bin
terraform show -json plan.bin > plan.json
```

For Helm/Kubernetes:

```bash
helm lint <chart>
helm template <release> <chart> --values <values.yaml> >/tmp/rendered.yaml
kubectl diff -f /tmp/rendered.yaml --server-side 2>/dev/null || true
```

---

## Step 3 — Deploy order and dependency check

Document:

| Item | Value |
| --- | --- |
| Must deploy before | <repos/services/infra> |
| Must deploy after | <repos/services/infra> |
| Can deploy independently | yes/no |
| Requires feature flag | yes/no |
| Requires maintenance window | yes/no |

Common ordering rules:

- Database/schema backward-compatible change before app rollout.
- IAM/networking prerequisites before service deployment.
- CRDs before custom resources.
- Shared libraries/build seed changes before dependent service builds.
- Producer/consumer API compatibility verified before either side is deployed.

---

## Step 4 — Rollback and recovery plan

Every release needs a rollback plan:

| Area | Rollback approach | Time estimate | Risk |
| --- | --- | --- | --- |
| App | redeploy previous image/tag | <time> | <risk> |
| Helm | `helm rollback` or GitOps revert | <time> | <risk> |
| Terraform | revert code + apply plan | <time> | <risk> |
| DB | forward-fix / restore / migration rollback | <time> | <risk> |

Flag blockers:

- No rollback path for data migration.
- Terraform plan destroys/replaces stateful resources.
- Previous app version cannot run against new schema.
- Rollback requires manual console steps.

---

## Step 5 — Monitoring and communication

Before release:

- Identify dashboards to watch.
- Identify alerts expected to fire (if any).
- Confirm on-call owner and escalation channel.
- Define success metrics and abort thresholds.

Example release watchlist:

| Signal | Healthy | Abort threshold |
| --- | --- | --- |
| Error rate | <1% | >5% for 5 min |
| p95 latency | <baseline + 20% | >baseline + 50% |
| Pod restarts | 0–1 expected | repeated CrashLoopBackOff |
| Queue lag | stable/decreasing | sustained growth |

---

## Step 6 — Generate report

Write:

```text
$REPORT_DIR/release-checklist-<release-name>-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# Release Checklist Report

| Field | Value |
|---|---|
| Release | <name> |
| Environment | <env> |
| Change type | <type> |
| Risk | Low / Medium / High |
| Verdict | Ready / Ready with cautions / Blocked |

## Scope
<what changes>

## Evidence
<tests, CI, plans, diffs>

## Deploy order
<dependencies and sequencing>

## Rollback plan
<commands/process and risk>

## Monitoring plan
<dashboards, alerts, abort thresholds>

## Blockers / cautions
<items to resolve before release>
```

---

## Safety rules

- This workflow is a **review gate**. It should not deploy anything.
- Commands are validation/diff/plan commands only.
- Never recommend production deploy if rollback is unknown for high-risk changes.
- Never ignore failed tests or scans; document explicit risk acceptance if release proceeds.
