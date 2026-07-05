# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- `/k8s-storage-debug` — read-only Kubernetes storage stack debugger: pod → PVC → PV → StorageClass → CSI driver → node disk pressure, with severity-ranked markdown report

## [1.2.0] — 2026-07-04

### Added — Claude Code

- **`argument-hint`** frontmatter on every workflow — shows expected args inline in the slash-command picker
- **`.claude/settings.json`** — shared project permissions: read-only bash allowlist + cluster/cloud-mutation denylist that enforces the repo's read-only contract at the tool layer
- **`.claude/agents/workflow-author.md`** — repo subagent for reviewing new workflow files against the contribution rules
- **CLAUDE.md `@`-imports** of `rules/devops-agent.md`, `rules/kubernetes.md`, `rules/terraform.md` so safety guardrails auto-load when Claude Code runs in this repo

### Fixed

- Removed bogus `auto_execution_mode: 2` frontmatter from `/k8s-upgrade-readiness` (left over from another editor)
- `scripts/stale-branches.sh` no longer silently fails to skip the `main`/`master` branches (precedence bug in `||` + `&&` chain)
- `scripts/*.sh` are now shellcheck-clean (argument flags converted to bash arrays, `read -r` used everywhere)
- Markdownlint CI step now fails the build (removed `continue-on-error: true`)
- Removed stale `/repo-health` roadmap TODO from README (shipped in v1.1.0)
- `settings.local.json` removed from git tracking (machine-local permissions should not be shared)

### Improved

- **`scripts/validate-repo.sh`** — checks for `description` + `argument-hint` in every workflow, validates `.claude/settings.json` parses, validates subagent frontmatter
- **CI** — split into 3 jobs (validate, markdown, shellcheck); shellcheck now actually installs and fails the build on findings; least-privilege `permissions:` block added

## [1.1.0] — 2026-06-02

### Added — Repo

- **`SECURITY.md`** — vulnerability disclosure policy using GitHub Security Advisories
- **`.github/CODEOWNERS`** — review routing for PRs
- **`.github/dependabot.yml`** — weekly GitHub Actions dependency updates

### Added — Workflows

- **`/helm-chart-review`** — review Helm charts for security, reliability, and best practices (kubernetes/)
- **`/secrets-leak-scan`** — scan git repos for leaked secrets using gitleaks, trufflehog, or regex (security/)
- **`/incident-triage`** — guided first 15 minutes of a production incident (observability/)
- **`/release-checklist`** — pre-release safety gate covering scope, deploy order, rollback, tests, monitoring, and communication (cicd/)
- **`/repo-health`** — repository hygiene audit for docs, CI, ownership, branch/release hygiene, and secrets risk (security/)

### Added — Prompts

- **`pr-description.md`** — generate PR descriptions from diffs
- **`explain-like-a-senior.md`** — explain infrastructure code to junior engineers
- **`runbook-from-incident.md`** — turn incident notes or post-mortems into reusable runbooks

### Added — Scripts

- **`aws-whoami.sh`** — quick AWS identity and account context check
- **`stale-branches.sh`** — list git branches older than N days
- **`validate-repo.sh`** — local validation for workflow frontmatter, README links, executable scripts, and optional lint checks

### Added — CI

- GitHub Actions CI: markdown lint, link check, frontmatter validation, README link verification

### Improved

- **`/aws-account-audit`** — added `FAST=yes` input to skip slow per-policy IAM loops on large accounts
- **`/aws-cost-quickscan`** — added `DEEP=yes` input for per-instance CPU utilization analysis
- **`/terraform-plan-review`** — added Step 0 with plan generation commands (including Terragrunt)
- **`/k8s-debug`** — enhanced log analysis (Step 5) with init container logs, structured error extraction, severity classification, and "noisiest pods" scan; added restart timeline analysis (Step 6a) and HPA health check (Step 6b); expanded triage cheat-sheet with startup-order, Redis, autoscaling, and webhook patterns
- **`/k8s-workload-debug`** — added init/sidecar analysis and GitOps/controller ownership checks
- **`/k8s-rbac-audit`** — added ServiceAccount token exposure checks
- **`/helm-release-debug`** — added ArgoCD/Flux ownership checks before suggesting manual Helm recovery
- **`/aws-vpc-debug`** — clarified source/destination variable resolution for VPC, subnet, security groups, and destination IP
- **`postmortem-writer.md`** — added SLO/data impact, recurrence risk, and action item type classification
- **`explain-like-a-senior.md`** — added prerequisite knowledge, safe validation, and team-question sections

---

## [0.1.0] — 2026-05-04

### Added — Workflows

- **`/k8s-debug`** — general-purpose Kubernetes cluster debugger (kubernetes/)
- **`/k8s-workload-debug`** — deep-dive on a single workload (kubernetes/)
- **`/k8s-rbac-audit`** — RBAC security audit (kubernetes/)
- **`/k8s-cost-hotspots`** — cost and waste analysis (kubernetes/)
- **`/k8s-upgrade-readiness`** — pre-flight checks for K8s upgrades (kubernetes/)
- **`/helm-release-debug`** — diagnose stuck or failed Helm releases (kubernetes/)
- **`/aws-account-audit`** — AWS account security audit (aws/)
- **`/aws-cost-quickscan`** — AWS cost waste analysis (aws/)
- **`/aws-vpc-debug`** — VPC connectivity triage (aws/)
- **`/aws-iam-policy-review`** — IAM policy risk analysis (aws/)
- **`/terraform-plan-review`** — Terraform plan risk analysis (iac/)
- **`/ci-debug`** — CI/CD pipeline failure diagnosis (cicd/)
- **`/jenkins-pipeline-review`** — Jenkinsfile code review (cicd/)
- **`/dockerfile-review`** — Dockerfile security and optimization review (containers/)

### Added — Prompts

- **`incident-commander.md`** — incident commander system prompt
- **`postmortem-writer.md`** — blameless post-mortem generator
- **`code-review-devops.md`** — DevOps code review prompt

### Added — Rules

- **`devops-agent.md`** rule set — AI safety guardrails for DevOps repos

### Added — Scripts

- **`k8s-snapshot.sh`** — cluster state snapshot to Markdown

### Added — Repo

- Repository structure: workflows/, prompts/, rules/, scripts/
- README.md with full documentation
- CONTRIBUTING.md with workflow design rules
- MIT License
