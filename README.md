# devops-ai-workflows

A growing collection of **AI-agent workflows, prompts, and rules** for day-to-day DevOps / SRE / platform work.

> Note: "workflows" here means **AI coding-agent workflows** (Windsurf, Cursor, Claude Code, etc.) — *not* GitHub Actions.

## What's inside

| Folder | Purpose | Audience |
|---|---|---|
| [`workflows/`](./workflows) | Workflow definitions, grouped by domain | Everyone |
| [`prompts/`](./prompts) | Reusable system / task prompts (incident triage, code review, post-mortem, etc.) | Any LLM |
| [`rules/`](./rules) | Editor / agent rule files (`.windsurfrules`, `.cursorrules`, Copilot instructions) | Per-tool |
| [`scripts/`](./scripts) | Standalone shell scripts referenced by workflows | Anyone with a shell |

## Available workflows

### Kubernetes

| Workflow | Slash command | Description | Prerequisites |
|---|---|---|---|
| [k8s-debug](./workflows/kubernetes/k8s-debug.md) | `/k8s-debug` | General-purpose, read-only cluster diagnostics across nodes, pods, workloads, networking, storage, RBAC, events, and resource pressure. | `kubectl`. Optional: `jq`, metrics-server. |
| [k8s-workload-debug](./workflows/kubernetes/k8s-workload-debug.md) | `/k8s-workload-debug` | Deep-dive on a single Deployment / StatefulSet / DaemonSet / Job / Pod: rollout, spec, probes, resources, logs, networking, storage, config. | `kubectl`. Optional: `jq`, metrics-server. |
| [k8s-rbac-audit](./workflows/kubernetes/k8s-rbac-audit.md) | `/k8s-rbac-audit` | RBAC risk audit — wildcards, cluster-admin bindings, risky verb/resource combos, over-privileged ServiceAccounts, anonymous access. | `kubectl`, `jq`. Optional: `kubectl-who-can`. |
| [k8s-cost-hotspots](./workflows/kubernetes/k8s-cost-hotspots.md) | `/k8s-cost-hotspots` | Find waste: over-provisioned workloads, missing requests/limits, idle workloads, orphan PVCs/PVs, idle LoadBalancers. | `kubectl`, `jq`, metrics-server. |
| [k8s-upgrade-readiness](./workflows/kubernetes/k8s-upgrade-readiness.md) | `/k8s-upgrade-readiness` | Pre-flight before a control-plane / node upgrade: deprecated APIs, version skew, PDB gaps, expiring certs, broken webhooks. | `kubectl`. Optional: `kubent` or `pluto`, `helm`. |
| [helm-release-debug](./workflows/kubernetes/helm-release-debug.md) | `/helm-release-debug` | Diagnose a stuck or failed Helm release: history, values diff, hook failures, rendered manifest vs cluster, workload health. | `helm` v3, `kubectl`. Optional: `jq`, `yq`. |

### AWS / Cloud

| Workflow | Slash command | Description | Prerequisites |
|---|---|---|---|
| [aws-account-audit](./workflows/aws/aws-account-audit.md) | `/aws-account-audit` | Read-only AWS account security & hygiene audit: IAM, S3, EC2, RDS, CloudTrail, encryption, GuardDuty, SecurityHub. | `aws` CLI. Optional: `jq`. |
| [aws-cost-quickscan](./workflows/aws/aws-cost-quickscan.md) | `/aws-cost-quickscan` | Find AWS cost waste: idle EC2/RDS, unattached EBS, old snapshots, expensive log groups, NAT data processing, missing Savings Plans. | `aws` CLI, Cost Explorer enabled. Optional: `jq`. |
| [aws-vpc-debug](./workflows/aws/aws-vpc-debug.md) | `/aws-vpc-debug` | Diagnose VPC connectivity: trace path across SGs, NACLs, route tables, NAT/IGW/TGW, VPC endpoints, DNS, and flow logs. | `aws` CLI. Optional: `jq`, `dig`. |
| [aws-iam-policy-review](./workflows/aws/aws-iam-policy-review.md) | `/aws-iam-policy-review` | Explain an IAM policy and flag risks: admin-equivalent access, privilege escalation paths, wildcard actions, missing conditions. | `aws` CLI. Optional: `jq`. |

### IaC

| Workflow | Slash command | Description | Prerequisites |
|---|---|---|---|
| [terraform-plan-review](./workflows/iac/terraform-plan-review.md) | `/terraform-plan-review` | Explain a Terraform plan and flag risky changes: destroys, replacements, security group mutations, IAM changes, blast radius. | `terraform plan` output. Optional: `terraform` CLI, `jq`. |

### Containers & CI/CD

| Workflow | Slash command | Description | Prerequisites |
|---|---|---|---|
| [ci-debug](./workflows/cicd/ci-debug.md) | `/ci-debug` | Diagnose a failing CI/CD pipeline: parse build logs from Jenkins, GitHub Actions, GitLab CI, or Bitbucket Pipelines. Root cause analysis and fix suggestions. | Build log output. Optional: repo source, CI config file. |
| [jenkins-pipeline-review](./workflows/cicd/jenkins-pipeline-review.md) | `/jenkins-pipeline-review` | Review Jenkinsfile / shared-library Groovy for security risks, anti-patterns, missing error handling, credential leaks, CPS issues, and build config cross-references. | Jenkinsfile(s) or `vars/*.groovy`. Optional: `repositories_v2.json`. |
| [dockerfile-review](./workflows/containers/dockerfile-review.md) | `/dockerfile-review` | Review Dockerfiles for security, size, caching, and best practices. Flags CVE-prone bases, leaked secrets, missing health checks. | Dockerfile(s). Optional: `docker`, `trivy`. |

More on the way — see [Roadmap](#roadmap).

## Using a workflow

### In AI agents

Open the matching file in [`workflows/`](./workflows) and either:

- invoke it as a slash command if your agent supports workflow discovery from this repo,
- paste the relevant section into the agent's chat, or
- include the file as context and ask the agent to follow it.

### As a plain human workflow

Every workflow is just Markdown with shell commands. You can run the steps yourself in a terminal — no AI required.

## Repo layout

```
devops-ai-workflows/
├── workflows/
│   ├── kubernetes/          # Kubernetes workflow definitions
│   ├── aws/                 # AWS / cloud workflow definitions
│   ├── iac/                 # Infrastructure as Code workflows
│   ├── cicd/                # CI/CD pipeline workflows
│   └── containers/          # Container & image workflows
├── prompts/                 # Reusable LLM prompts
├── rules/                   # Editor/agent rule files
├── scripts/                 # Standalone shell helpers
├── CONTRIBUTING.md
├── LICENSE
└── README.md
```

## Roadmap

Ideas I plan to add (PRs welcome):

**AWS / cloud**
- [ ] `/aws-eks-debug` — bridge EKS + Kubernetes: node groups, OIDC, add-ons, IAM roles for service accounts
- [ ] `/aws-rds-health` — RDS/Aurora diagnostics: events, metrics, parameter groups, replication lag
- [ ] `/aws-lambda-debug` — Lambda diagnostics: errors, throttles, DLQ, VPC/ENI, CloudWatch logs
- [ ] `/aws-ecs-service-debug` — ECS/Fargate service rollout failures: task events, target group health, IAM roles

**IaC**
- [ ] `/terraform-state-debug` — diagnose locks, drift, orphans
- [ ] `/iac-secrets-scan` — repo-wide hardcoded-secret sweep

**Containers & CI/CD**
- [ ] `/image-cve-triage` — prioritise CVE scanner output by exploitability + fix availability
- [ ] `/github-actions-review` — security review of GitHub Actions workflow files
- [ ] `/release-checklist` — pre-release gate
- [ ] `/helm-chart-review` — review Helm chart for missing resources/limits, PDB, anti-affinity, template issues

**Observability & incident**
- [ ] `/prometheus-query-helper` — intent → PromQL with rationale
- [ ] `/log-pattern-extract` — cluster repeated errors out of a log dump
- [ ] `/incident-triage` — guided first 15 minutes of an incident
- [ ] `/postmortem` — blameless post-mortem from a transcript
- [ ] `/runbook-from-incident` — turn a resolved incident into a reusable runbook

**Networking / database**
- [ ] `/dns-debug` — multi-resolver dig, propagation, DNSSEC
- [ ] `/tls-cert-audit` — chain inspection, expiry, weak ciphers across a list of hosts
- [ ] `/postgres-health` — bloat, long queries, replication lag, missing indexes
- [ ] `/redis-health` — memory pressure, slow log, persistence config, eviction patterns
- [ ] `/db-migration-review` — flag risky migration patterns

**Security & repo hygiene**
- [ ] `/secrets-leak-scan` — gitleaks/trufflehog over full git history
- [ ] `/cve-impact-assessment` — given a CVE, check whether your stack is affected
- [ ] `/repo-health` — README, license, CI, branch protection, stale branches
- [ ] `/dependency-upgrade-plan` — group outdated deps by risk and suggest batching

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). The short version:

1. Add the canonical workflow to `workflows/<domain>/<name>.md`.
2. Update the **Available workflows** table in this README.
3. Keep workflows **read-only by default**. Anything mutating must be opt-in (e.g. a `DEEP=yes` flag) and clearly flagged.

## License

[MIT](./LICENSE) — use freely, attribution appreciated but not required.
