# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.0] — 2026-11-27

### Added — Prompts

- `cost-optimization.md` — prioritized cloud/cluster savings plan from billing or inventory data
- `dora-metrics.md` — compute/interpret the four DORA metrics with explicit definitions and confidence
- `change-advisory.md` — RFC-style change advisory with blast radius, rollback, and approve/reject

### Added — Rules

- `rules/database.md` — PostgreSQL/MySQL/Redis guardrails (read-only investigation, expand/contract, lock timeouts)
- `rules/mcp-safety.md` — agent tool/MCP safety (least privilege, confirmation, no exfiltration, untrusted output)

### Added — Release automation

- **`.github/workflows/release.yml`** — on a `v*` tag push, extracts the version's `CHANGELOG.md` section and creates a GitHub Release
- **`scripts/changelog-release-notes.sh`** — print a version's release notes from `CHANGELOG.md`
- **`scripts/tag-release.sh`** — cut an annotated release tag after checking the changelog section, clean tree, and `main`
- `validate-repo.sh` now fails if any `v*` tag has no matching `## [x.y.z]` changelog section

### Added — Docs

- Scenario-based workflow index ("Something is down → …") at the top of the README
- `docs/examples/` with anonymised sample reports from `/k8s-debug` and `/terraform-plan-review`
- CI, release, and license badges in the README

### Added — Workflows

- `/aws-s3-audit` — read-only S3 security & hygiene audit: public access, bucket policies, ACLs, encryption, versioning, lifecycle, logging, and replication
- `/github-actions-review` — security & reliability static analysis of GitHub Actions workflows: expression injection, permissions, unpinned actions, `pull_request_target` risks, secrets, cache poisoning
- `/postgres-health` — read-only PostgreSQL health check: bloat, long/idle transactions, lock waits, replication lag, connections, index candidates, autovacuum
- `/terraform-state-debug` — read-only Terraform state diagnostics: locks, drift, orphans, workspace mapping, backend health
- `/tls-cert-audit` — TLS audit across hosts: chain validity, expiry, weak protocols/ciphers, hostname match, HSTS
- `/dns-debug` — DNS resolution diagnostics across resolvers: delegation, propagation, CNAME chains, DNSSEC
- `/redis-health` — read-only Redis health: memory/eviction, slow log, persistence, replication, clients, config
- `/db-migration-review` — static review of DB migrations: locking DDL, destructive/irreversible changes, unbatched backfills
- `/prometheus-query-helper` — turns a plain-English intent into a validated PromQL query with rationale and cardinality notes

### Added — Repo

- **`AGENTS.md`** — cross-tool entry point (Codex, Cursor, Windsurf, Gemini CLI) that imports the safety rules and repo conventions
- **`rules/aws.md`** — AWS-specific agent guardrails: identity/account verification, IAM change caution, secret redaction, destructive-op confirmation, cost awareness
- **`scripts/tests/validate-repo.bats`** + `scripts/test-validate.sh` — unit tests for the validator (8 cases)
- **`.pre-commit-config.yaml`** — markdownlint, shellcheck, actionlint, and validate-repo hooks mirroring CI
- Workflow request issue template and pull request checklist
- `SECURITY.md`, `CODEOWNERS`, and `dependabot.yml` now listed in the README repo layout
- New *Networking / Database* section in the README workflow tables

### Improved

- **`scripts/validate-repo.sh`** — content-as-code checks on top of the structural ones:
  - every workflow must describe a report/artifact path
  - **read-only policy**: fails on ungated mutating commands (`kubectl delete/apply/scale`, `terraform apply/destroy`, `helm install/upgrade`, `aws … create/put/delete/terminate`, …) inside code fences unless the surrounding step opts in (`DEEP=yes`, `APPLY=yes`, `--dry-run`, or a "suggest/optional/confirm" gate); prose mentions are ignored
  - still fails when a workflow is missing from the README table or a markdown file has unbalanced fences
  - body extracted into a sourceable `check_repo()` function so it can be unit-tested
- **CI** — plus an `actionlint` job and a bats test step; all Actions are now pinned to full commit SHAs (resolved with `gh api`)
- README roadmap pruned of already-shipped workflows

### Removed

- Stale `prompts/.gitkeep`, `rules/.gitkeep`, `scripts/.gitkeep` (directories are populated)

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

## [1.0.0] — 2026-05-15

### Added

- Initial tagged release: the Kubernetes, AWS, Helm, and IaC workflows, reusable prompts, and the `k8s-snapshot.sh` helper described under 0.1.0 (this entry back-fills the tag that was cut without a changelog section).

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
