# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added — Workflows
- **`/helm-chart-review`** — review Helm charts for security, reliability, and best practices (kubernetes/)
- **`/secrets-leak-scan`** — scan git repos for leaked secrets using gitleaks, trufflehog, or regex (security/)
- **`/incident-triage`** — guided first 15 minutes of a production incident (observability/)

### Added — Prompts
- **`pr-description.md`** — generate PR descriptions from diffs
- **`explain-like-a-senior.md`** — explain infrastructure code to junior engineers

### Added — Scripts
- **`aws-whoami.sh`** — quick AWS identity and account context check
- **`stale-branches.sh`** — list git branches older than N days

### Added — CI
- GitHub Actions CI: markdown lint, link check, frontmatter validation, README link verification

### Improved
- **`/aws-account-audit`** — added `FAST=yes` input to skip slow per-policy IAM loops on large accounts
- **`/aws-cost-quickscan`** — added `DEEP=yes` input for per-instance CPU utilization analysis
- **`/terraform-plan-review`** — added Step 0 with plan generation commands (including Terragrunt)
- **`/k8s-debug`** — enhanced log analysis (Step 5) with init container logs, structured error extraction, severity classification, and "noisiest pods" scan; added restart timeline analysis (Step 6a) and HPA health check (Step 6b); expanded triage cheat-sheet with startup-order, Redis, autoscaling, and webhook patterns

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
- **`devops-agent.windsurfrules`** — AI safety guardrails for DevOps repos

### Added — Scripts
- **`k8s-snapshot.sh`** — cluster state snapshot to Markdown

### Added — Repo
- Repository structure: workflows/, prompts/, rules/, scripts/
- README.md with full documentation
- CONTRIBUTING.md with workflow design rules
- MIT License
