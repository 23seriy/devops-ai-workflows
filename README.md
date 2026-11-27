# devops-ai-workflows

A growing collection of **AI-agent workflows, prompts, and rules** for day-to-day DevOps / SRE / platform work.

> Note: "workflows" here means **Claude Code slash commands / AI-agent workflows** — *not* GitHub Actions.

## What's inside

| Folder | Purpose | Audience |
| --- | --- | --- |
| [`.claude/commands/`](./.claude/commands) | Workflow definitions, auto-discovered as slash commands by Claude Code. | Everyone |
| [`.claude/agents/`](./.claude/agents) | Repo-maintenance subagents (e.g. `workflow-author`) invoked via the `Agent` tool. | Maintainers |
| [`.claude/settings.json`](./.claude/settings.json) | Shared project settings: pre-approved read-only `Bash(...)` patterns + a deny list that blocks cluster/cloud mutations even if a workflow tries. | Claude Code users |
| [`prompts/`](./prompts) | Reusable system / task prompts (incident triage, code review, post-mortem, etc.) | Any LLM |
| [`rules/`](./rules) | Reusable safety rule sets to load into Claude Code (via `CLAUDE.md` `@`-reference) or any other agent | Any agent |
| [`scripts/`](./scripts) | Standalone shell scripts referenced by workflows | Anyone with a shell |

## Available workflows

### Kubernetes

| Workflow | Slash command | Description | Prerequisites |
| --- | --- | --- | --- |
| [k8s-debug](./.claude/commands/k8s-debug.md) | `/k8s-debug` | General-purpose, read-only cluster diagnostics across nodes, pods, workloads, networking, storage, RBAC, events, and resource pressure. | `kubectl`. Optional: `jq`, metrics-server. |
| [k8s-workload-debug](./.claude/commands/k8s-workload-debug.md) | `/k8s-workload-debug` | Deep-dive on a single Deployment / StatefulSet / DaemonSet / Job / Pod: rollout, spec, probes, resources, logs, networking, storage, config. | `kubectl`. Optional: `jq`, metrics-server. |
| [k8s-rbac-audit](./.claude/commands/k8s-rbac-audit.md) | `/k8s-rbac-audit` | RBAC risk audit — wildcards, cluster-admin bindings, risky verb/resource combos, over-privileged ServiceAccounts, anonymous access. | `kubectl`, `jq`. Optional: `kubectl-who-can`. |
| [k8s-cost-hotspots](./.claude/commands/k8s-cost-hotspots.md) | `/k8s-cost-hotspots` | Find waste: over-provisioned workloads, missing requests/limits, idle workloads, orphan PVCs/PVs, idle LoadBalancers. | `kubectl`, `jq`, metrics-server. |
| [k8s-upgrade-readiness](./.claude/commands/k8s-upgrade-readiness.md) | `/k8s-upgrade-readiness` | Pre-flight before a control-plane / node upgrade: deprecated APIs, version skew, PDB gaps, expiring certs, broken webhooks. | `kubectl`. Optional: `kubent` or `pluto`, `helm`. |
| [k8s-storage-debug](./.claude/commands/k8s-storage-debug.md) | `/k8s-storage-debug` | Diagnose Kubernetes storage issues top-down: pod → PVC → PV → StorageClass → CSI driver → node disk pressure. Read-only, generates a markdown report. | `kubectl`. Optional: `jq`. |
| [helm-release-debug](./.claude/commands/helm-release-debug.md) | `/helm-release-debug` | Diagnose a stuck or failed Helm release: history, values diff, hook failures, rendered manifest vs cluster, workload health. | `helm` v3, `kubectl`. Optional: `jq`, `yq`. |
| [helm-chart-review](./.claude/commands/helm-chart-review.md) | `/helm-chart-review` | Review a Helm chart for security, reliability, and best practices: resource specs, probes, security context, PDBs, anti-affinity, RBAC. | Helm chart source. Optional: `helm` CLI. |

### AWS / Cloud

| Workflow | Slash command | Description | Prerequisites |
| --- | --- | --- | --- |
| [aws-account-audit](./.claude/commands/aws-account-audit.md) | `/aws-account-audit` | Read-only AWS account security & hygiene audit: IAM, S3, EC2, RDS, CloudTrail, encryption, GuardDuty, SecurityHub. | `aws` CLI. Optional: `jq`. |
| [aws-cost-quickscan](./.claude/commands/aws-cost-quickscan.md) | `/aws-cost-quickscan` | Find AWS cost waste: idle EC2/RDS, unattached EBS, old snapshots, expensive log groups, NAT data processing, missing Savings Plans. | `aws` CLI, Cost Explorer enabled. Optional: `jq`. |
| [aws-vpc-debug](./.claude/commands/aws-vpc-debug.md) | `/aws-vpc-debug` | Diagnose VPC connectivity: trace path across SGs, NACLs, route tables, NAT/IGW/TGW, VPC endpoints, DNS, and flow logs. | `aws` CLI. Optional: `jq`, `dig`. |
| [aws-iam-policy-review](./.claude/commands/aws-iam-policy-review.md) | `/aws-iam-policy-review` | Explain an IAM policy and flag risks: admin-equivalent access, privilege escalation paths, wildcard actions, missing conditions. | `aws` CLI. Optional: `jq`. |
| [aws-eks-debug](./.claude/commands/aws-eks-debug.md) | `/aws-eks-debug` | Read-only EKS diagnostics: cluster health, node groups, OIDC/IRSA, add-ons, VPC CNI networking, control-plane logging, version skew, and IAM access. | `aws` CLI. Optional: `kubectl`, `jq`. |
| [aws-rds-health](./.claude/commands/aws-rds-health.md) | `/aws-rds-health` | Read-only RDS/Aurora diagnostics: instance health, events, storage/I/O metrics, parameter groups, replication lag, backups, and security posture. | `aws` CLI. Optional: `jq`. |
| [aws-lambda-debug](./.claude/commands/aws-lambda-debug.md) | `/aws-lambda-debug` | Read-only Lambda diagnostics: errors, throttles, duration percentiles, cold starts, DLQ, VPC/ENI, concurrency, event source mappings, layers, and IAM role. | `aws` CLI. Optional: `jq`. |
| [aws-ecs-service-debug](./.claude/commands/aws-ecs-service-debug.md) | `/aws-ecs-service-debug` | Read-only ECS/Fargate service diagnostics: task rollout failures, stopped-task reasons, deployment circuit breaker, target group health, task IAM roles, and logs. | `aws` CLI. Optional: `jq`. |
| [aws-s3-audit](./.claude/commands/aws-s3-audit.md) | `/aws-s3-audit` | Read-only S3 security & hygiene audit: public access, bucket policies, ACLs, encryption, versioning, lifecycle, logging, and replication. | `aws` CLI. Optional: `jq`. |

### IaC

| Workflow | Slash command | Description | Prerequisites |
| --- | --- | --- | --- |
| [terraform-plan-review](./.claude/commands/terraform-plan-review.md) | `/terraform-plan-review` | Explain a Terraform plan and flag risky changes: destroys, replacements, security group mutations, IAM changes, blast radius. | `terraform plan` output. Optional: `terraform` CLI, `jq`. |
| [terraform-state-debug](./.claude/commands/terraform-state-debug.md) | `/terraform-state-debug` | Read-only Terraform state diagnostics: locks, drift, orphans, workspace mapping, and backend health. | `terraform` CLI. Optional: `jq`. |

### Containers & CI/CD

| Workflow | Slash command | Description | Prerequisites |
| --- | --- | --- | --- |
| [ci-debug](./.claude/commands/ci-debug.md) | `/ci-debug` | Diagnose a failing CI/CD pipeline: parse build logs from Jenkins, GitHub Actions, GitLab CI, or Bitbucket Pipelines. Root cause analysis and fix suggestions. | Build log output. Optional: repo source, CI config file. |
| [jenkins-pipeline-review](./.claude/commands/jenkins-pipeline-review.md) | `/jenkins-pipeline-review` | Review Jenkinsfile / shared-library Groovy for security risks, anti-patterns, missing error handling, credential leaks, CPS issues, and build config cross-references. | Jenkinsfile(s) or `vars/*.groovy`. Optional: `repositories_v2.json`. |
| [release-checklist](./.claude/commands/release-checklist.md) | `/release-checklist` | Pre-release safety gate: scope, deploy order, rollback, tests, monitoring, and communication before production release. | PR/diff summary. Optional: test results, plans, diffs. |
| [dockerfile-review](./.claude/commands/dockerfile-review.md) | `/dockerfile-review` | Review Dockerfiles for security, size, caching, and best practices. Flags CVE-prone bases, leaked secrets, missing health checks. | Dockerfile(s). Optional: `docker`, `trivy`. |
| [github-actions-review](./.claude/commands/github-actions-review.md) | `/github-actions-review` | Security & reliability review of GitHub Actions workflows: expression injection, excessive permissions, unpinned actions, `pull_request_target` risks, secret handling, cache poisoning. | Workflow file(s). Optional: `actionlint`, `gh`, `yq`. |

### Networking / Database

| Workflow | Slash command | Description | Prerequisites |
| --- | --- | --- | --- |
| [postgres-health](./.claude/commands/postgres-health.md) | `/postgres-health` | Read-only PostgreSQL health check: bloat, long-running and idle-in-transaction queries, lock waits, replication lag, connection saturation, missing indexes, and autovacuum. | `psql` + a `pg_monitor` role. Optional: `pg_stat_statements`. |
| [redis-health](./.claude/commands/redis-health.md) | `/redis-health` | Read-only Redis health check: memory pressure and eviction, slow log, persistence, replication lag, connection saturation, keyspace, and dangerous config. | `redis-cli` + read access. |
| [db-migration-review](./.claude/commands/db-migration-review.md) | `/db-migration-review` | Static review of DB migration scripts: locking DDL, long transactions, destructive/irreversible changes, unbatched backfills. Read-only. | Migration file(s). Optional: `sqlfluff`. |
| [tls-cert-audit](./.claude/commands/tls-cert-audit.md) | `/tls-cert-audit` | Audit TLS across hosts: chain validity, expiry, weak protocols/ciphers, hostname match, HSTS. Read-only. | `openssl`. Optional: `nmap`, `curl`. |
| [dns-debug](./.claude/commands/dns-debug.md) | `/dns-debug` | Diagnose DNS across resolvers: authoritative answers, propagation, CNAME chains, negative answers, DNSSEC. Read-only. | `dig`. Optional: `delv`. |

### Security

| Workflow | Slash command | Description | Prerequisites |
| --- | --- | --- | --- |
| [secrets-leak-scan](./.claude/commands/secrets-leak-scan.md) | `/secrets-leak-scan` | Scan git repo history for leaked secrets: API keys, passwords, tokens, private keys. Uses gitleaks, trufflehog, or regex fallback. | Git repo. Optional: `gitleaks`, `trufflehog`. |
| [repo-health](./.claude/commands/repo-health.md) | `/repo-health` | Audit repository hygiene: README, license, CI, branch/release hygiene, tracked secrets, ownership, and automation gaps. | Local git repo. Optional: `gh`, `jq`. |

### Observability & Incident

| Workflow | Slash command | Description | Prerequisites |
| --- | --- | --- | --- |
| [incident-triage](./.claude/commands/incident-triage.md) | `/incident-triage` | Guided first 15 minutes of a production incident: timeline, blast radius, evidence gathering, mitigation suggestions. | Access to affected environment. |
| [prometheus-query-helper](./.claude/commands/prometheus-query-helper.md) | `/prometheus-query-helper` | Turn a plain-English monitoring intent into a validated PromQL query with rationale, cardinality notes, and an example alert. Read-only. | None. Optional: `curl`, `jq`, a Prometheus URL. |

### Productivity

| Workflow | Slash command | Description | Prerequisites |
| --- | --- | --- | --- |
| [jira-my-tasks](./.claude/commands/jira-my-tasks.md) | `/jira-my-tasks` | Fetch your open Jira issues (not Done) and save a timestamped markdown snapshot to `~/src/my_tasks/YYYY-MM-DD-HHMM.md`. Grouped by In Progress / Ready for Testing / Backlog. | `curl`, `python3`. `~/.jira-credentials` with API token. |

More on the way — see [Roadmap](#roadmap).

## Prompts

Reusable system prompts you can paste into any AI agent for common DevOps tasks:

| Prompt | What it does |
| --- | --- |
| [incident-commander](./prompts/incident-commander.md) | Puts the AI in incident-commander mode: timeline, blast radius, action tracking, status updates. |
| [postmortem-writer](./prompts/postmortem-writer.md) | Generates a blameless post-mortem from incident notes: timeline, root cause, impact, action items. |
| [code-review-devops](./prompts/code-review-devops.md) | Reviews IaC / pipeline / Docker / K8s code with a security-first DevOps lens. |
| [pr-description](./prompts/pr-description.md) | Generates a PR description from a diff: what, why, how, testing, risk, rollback plan. |
| [explain-like-a-senior](./prompts/explain-like-a-senior.md) | Explains infrastructure code to junior engineers: what it does, why, gotchas, and how it fits together. |
| [runbook-from-incident](./prompts/runbook-from-incident.md) | Converts incident notes or post-mortems into reusable runbooks with diagnosis, mitigation, escalation, and follow-up steps. |

## Rules

Reusable, agent-agnostic safety rule sets. Reference them from a project's `CLAUDE.md` (e.g. `@rules/kubernetes.md`), paste into a system prompt, or include as context:

| Rule file | What it does |
| --- | --- |
| [devops-agent.md](./rules/devops-agent.md) | Safety guardrails for AI in DevOps repos: never modify prod without confirmation, prefer read-only, never hardcode secrets, always check context, GitOps awareness, multi-repo coordination. |
| [aws.md](./rules/aws.md) | AWS-specific: identity/account verification, IAM change caution, secret redaction, destructive-op confirmation, cost awareness, least-privilege read roles. |
| [terraform.md](./rules/terraform.md) | Terraform-specific: state safety, ForceNew attribute warnings, provider/module pinning, workspace safety, import workflow, `prevent_destroy` reminders. |
| [kubernetes.md](./rules/kubernetes.md) | Kubernetes-specific: context verification, dry-run first, Helm safety, ArgoCD/GitOps awareness, secret handling, debugging approach, RBAC best practices. |

## Scripts

Standalone shell utilities referenced by workflows or useful on their own:

| Script | Usage |
| --- | --- |
| [k8s-snapshot.sh](./scripts/k8s-snapshot.sh) | `./k8s-snapshot.sh [namespace\|all] [output-dir]` — dump cluster state (nodes, pods, events, services, top) to a timestamped Markdown file. |
| [aws-whoami.sh](./scripts/aws-whoami.sh) | `./aws-whoami.sh [profile]` — quick AWS identity check: caller, region, account alias, org, SSO role. |
| [stale-branches.sh](./scripts/stale-branches.sh) | `./stale-branches.sh [days] [--remote]` — list git branches older than N days with last commit info. |
| [validate-repo.sh](./scripts/validate-repo.sh) | `./scripts/validate-repo.sh` — validate workflow frontmatter, README links, script executability, and optional lint checks. |

## Using a workflow

### In Claude Code

Clone the repo and run Claude Code from the repo root. Every workflow under [`.claude/commands/`](./.claude/commands) is auto-discovered as a slash command — `.claude/commands/k8s-debug.md` is invoked as `/k8s-debug`, etc. The `argument-hint` in each file's frontmatter is shown inline as you type.

[`CLAUDE.md`](./CLAUDE.md) `@`-imports the rule files under [`rules/`](./rules), so the safety guardrails for Kubernetes, Terraform, and general DevOps work load automatically whenever you run Claude Code in this directory.

[`.claude/settings.json`](./.claude/settings.json) pre-approves read-only bash patterns commonly used while developing here (validate-repo, find, grep, git status/diff/log) and denies cluster/cloud mutations (`kubectl apply|delete|scale`, `helm install|upgrade`, `terraform apply|destroy`, `aws iam create|delete|put`, etc.) — keeping the repo's read-only contract enforced at the tool level.

### In other AI agents

Open the matching file in [`.claude/commands/`](./.claude/commands) and either:

- paste the relevant section into the agent's chat, or
- include the file as context and ask the agent to follow it.

### As a plain human workflow

Every workflow is just Markdown with shell commands. You can run the steps yourself in a terminal — no AI required.

## Slash command frontmatter

Every workflow declares two YAML keys:

```yaml
---
description: One-sentence summary shown in the slash-command picker.
argument-hint: "REQUIRED=<value> [OPTIONAL=default]"
---
```

`description` shows up in the `/`-picker. `argument-hint` mirrors the Inputs section so users see expected args inline. See [CONTRIBUTING.md](./CONTRIBUTING.md) for examples.

## Repo layout

```text
devops-ai-workflows/
├── .claude/
│   ├── commands/            # Workflow definitions (Claude Code slash commands)
│   ├── agents/              # Repo-maintenance subagents (workflow-author, ...)
│   └── settings.json        # Shared allow/deny permissions
├── .github/
│   ├── workflows/ci.yml     # Validate + markdownlint + shellcheck
│   ├── .markdownlint.json   # Lint config
│   ├── dependabot.yml       # Weekly GitHub Actions updates
│   ├── CODEOWNERS
│   └── PULL_REQUEST_TEMPLATE.md
├── prompts/                 # Reusable LLM prompts
├── rules/                   # Editor/agent rule files (auto-loaded via CLAUDE.md)
├── scripts/                 # Standalone shell helpers + tests/
├── AGENTS.md                # Cross-tool agent instructions (Codex/Cursor/…)
├── CHANGELOG.md
├── CLAUDE.md                # Claude Code project instructions
├── CONTRIBUTING.md
├── LICENSE
├── SECURITY.md
├── README.md
└── .pre-commit-config.yaml
```

## Roadmap

Ideas I plan to add (PRs welcome):

### AWS / cloud

- [ ] `/aws-open-cost-allocation` — compare tag coverage across cost allocation reports and accounts

### IaC

- [ ] `/iac-secrets-scan` — repo-wide hardcoded-secret sweep

### Containers & CI/CD

- [ ] `/image-cve-triage` — prioritise CVE scanner output by exploitability + fix availability

### Observability & incident

- [ ] `/log-pattern-extract` — cluster repeated errors out of a log dump
- [ ] `/postmortem` — blameless post-mortem from a transcript
- [ ] `/runbook-from-incident` — turn a resolved incident into a reusable runbook

### Networking / database

### Security & repo hygiene

- [ ] `/cve-impact-assessment` — given a CVE, check whether your stack is affected
- [ ] `/dependency-upgrade-plan` — group outdated deps by risk and suggest batching

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). The short version:

1. Add the canonical workflow to `.claude/commands/<name>.md`.
2. Update the **Available workflows** table in this README.
3. Keep workflows **read-only by default**. Anything mutating must be opt-in (e.g. a `DEEP=yes` flag) and clearly flagged.

## License

[MIT](./LICENSE) — use freely, attribution appreciated but not required.
