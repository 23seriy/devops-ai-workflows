# devops-ai-workflows

A growing collection of **AI-agent workflows, runbooks, prompts, and rules** for day-to-day DevOps / SRE / platform work.

> Note: "workflows" here means **AI coding-agent workflows** (Windsurf, Cursor, Claude Code, etc.) — *not* GitHub Actions.

## What's inside

| Folder | Purpose | Audience |
|---|---|---|
| [`.windsurf/workflows/`](./.windsurf/workflows) | Windsurf slash-command workflows (with frontmatter and `// turbo` auto-run hints) | Windsurf / Cascade users |
| [`runbooks/`](./runbooks) | The same workflows as plain Markdown — readable by humans and any other AI agent | Everyone |
| [`prompts/`](./prompts) | Reusable system / task prompts (incident triage, code review, post-mortem, etc.) | Any LLM |
| [`rules/`](./rules) | Editor / agent rule files (`.windsurfrules`, `.cursorrules`, Copilot instructions) | Per-tool |
| [`scripts/`](./scripts) | Standalone shell scripts referenced by workflows | Anyone with a shell |

## Available workflows

### Kubernetes

| Workflow | Slash command | Description | Prerequisites |
|---|---|---|---|
| [k8s-debug](./.windsurf/workflows/k8s-debug.md) | `/k8s-debug` | General-purpose, read-only cluster diagnostics across nodes, pods, workloads, networking, storage, RBAC, events, and resource pressure. | `kubectl`. Optional: `jq`, metrics-server. |
| [k8s-workload-debug](./.windsurf/workflows/k8s-workload-debug.md) | `/k8s-workload-debug` | Deep-dive on a single Deployment / StatefulSet / DaemonSet / Job / Pod: rollout, spec, probes, resources, logs, networking, storage, config. | `kubectl`. Optional: `jq`, metrics-server. |
| [k8s-rbac-audit](./.windsurf/workflows/k8s-rbac-audit.md) | `/k8s-rbac-audit` | RBAC risk audit — wildcards, cluster-admin bindings, risky verb/resource combos, over-privileged ServiceAccounts, anonymous access. | `kubectl`, `jq`. Optional: `kubectl-who-can`. |
| [k8s-cost-hotspots](./.windsurf/workflows/k8s-cost-hotspots.md) | `/k8s-cost-hotspots` | Find waste: over-provisioned workloads, missing requests/limits, idle workloads, orphan PVCs/PVs, idle LoadBalancers. | `kubectl`, `jq`, metrics-server. |
| [k8s-upgrade-readiness](./.windsurf/workflows/k8s-upgrade-readiness.md) | `/k8s-upgrade-readiness` | Pre-flight before a control-plane / node upgrade: deprecated APIs, version skew, PDB gaps, expiring certs, broken webhooks. | `kubectl`. Optional: `kubent` or `pluto`, `helm`. |
| [helm-release-debug](./.windsurf/workflows/helm-release-debug.md) | `/helm-release-debug` | Diagnose a stuck or failed Helm release: history, values diff, hook failures, rendered manifest vs cluster, workload health. | `helm` v3, `kubectl`. Optional: `jq`, `yq`. |

More on the way — see [Roadmap](#roadmap).

## Using a workflow

### In Windsurf / Cascade

Two options:

1. **Per-project**: copy the file into your project's `.windsurf/workflows/` folder, then trigger it with its slash command (e.g. `/k8s-debug`).
2. **Global** (available in every workspace): copy it into `~/.codeium/windsurf/windsurf/workflows/`.

```bash
# Global install of every workflow in this repo
cp .windsurf/workflows/*.md ~/.codeium/windsurf/windsurf/workflows/
```

### In other AI agents (Cursor, Claude Code, Aider, Copilot Chat, ...)

Open the matching file in [`runbooks/`](./runbooks) and either:

- paste the relevant section into the agent's chat, or
- include the file as context and ask the agent to "follow this runbook".

The runbook variants have the Windsurf-specific frontmatter and `// turbo` hints stripped out.

### As a plain human runbook

Every workflow is just Markdown with shell commands. You can run the steps yourself in a terminal — no AI required.

## Repo layout

```
devops-ai-workflows/
├── .windsurf/workflows/     # Windsurf slash-command workflows
├── runbooks/                # Tool-agnostic Markdown copies
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
- [ ] `/aws-account-audit` — read-only AWS account hygiene (IAM, S3, EC2, SGs, CloudTrail, encryption)
- [ ] `/aws-cost-quickscan` — top spenders, idle resources, anomalies
- [ ] `/aws-iam-policy-review` — explain a policy and flag risky permissions
- [ ] `/aws-vpc-debug` — connectivity triage across SGs / NACLs / routes / endpoints

**IaC**
- [ ] `/terraform-plan-review` — explain a `terraform plan` and highlight risky changes
- [ ] `/terraform-state-debug` — diagnose locks, drift, orphans
- [ ] `/iac-secrets-scan` — repo-wide hardcoded-secret sweep

**Containers & CI/CD**
- [ ] `/dockerfile-review` — security, size, cache, and CVE-prone bases
- [ ] `/image-cve-triage` — prioritise CVE scanner output by exploitability + fix availability
- [ ] `/ci-debug` — diagnose a failing GitHub Actions / GitLab / Jenkins pipeline
- [ ] `/github-actions-review` — security review of workflow files
- [ ] `/release-checklist` — pre-release gate

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

1. Add the Windsurf version to `.windsurf/workflows/<name>.md` (with frontmatter and `// turbo` where safe).
2. Add the tool-agnostic copy to `runbooks/<name>.md`.
3. Update the **Available workflows** table in this README.
4. Keep workflows **read-only by default**. Anything mutating must be opt-in (e.g. a `DEEP=yes` flag) and clearly flagged.

## License

[MIT](./LICENSE) — use freely, attribution appreciated but not required.
