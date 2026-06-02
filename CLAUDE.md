# CLAUDE.md

DevOps AI workflows — read-only diagnostic and review workflows for Kubernetes, AWS, IaC, CI/CD, containers, security, and incidents. Designed to be invoked as slash commands by Claude Code (and other AI agents).

## Repo layout

- `.claude/commands/<domain>/<name>.md` — workflow definitions, auto-discovered by Claude Code as `/<name>` slash commands. Source of truth.
- `prompts/` — reusable system prompts for any LLM (incident-commander, postmortem-writer, etc.).
- `rules/` — agent-agnostic safety rule sets (`devops-agent.md`, `kubernetes.md`, `terraform.md`). When working on the relevant tech in a downstream repo, load the matching rule via `@rules/<name>.md`. The safety posture they describe (no prod changes without confirmation, prefer read-only, never hardcode secrets, GitOps awareness) applies to anything done in this repo too.
- `scripts/` — standalone bash helpers (`k8s-snapshot.sh`, `aws-whoami.sh`, `stale-branches.sh`, `validate-repo.sh`).

## Adding or editing a workflow

See [CONTRIBUTING.md](./CONTRIBUTING.md). Non-negotiables when working in this repo:

- File lives at `.claude/commands/<domain>/<name>.md` with YAML frontmatter containing a `description:` line — that's what slash-command pickers display.
- **Read-only by default.** Anything that creates / mutates / deletes resources must be gated behind an opt-in flag (`DEEP=yes`, `APPLY=yes`, etc.) AND clearly labelled in the step heading.
- **No secret values in output.** Names, types, key lists, and counts only — never the actual value.
- **Idempotent.** Running a workflow twice must not change cluster / account state.
- **Degrade gracefully** when optional tools (`jq`, `metrics-server`, `helm`, etc.) are missing — state the prerequisite, don't crash.
- End by writing a timestamped report at `./<name>-reports/<name>-<YYYYMMDD-HHMMSS>.md` so users have an artefact to share.
- Update the *Available workflows* table in [README.md](./README.md).

## Validation

Before committing:

```bash
./scripts/validate-repo.sh
```

Checks YAML frontmatter on every `.claude/commands/**/*.md`, README local links, and script executability. CI (`.github/workflows/ci.yml`) runs the same checks plus markdownlint and the markdown-link-check action.

## Safety posture for the agent itself

This repo's whole point is to be safe in production environments. When **executing** a workflow against a real cluster / account:

- Confirm context (kubectl context, AWS profile/region, target namespace) with the user **before** running anything.
- Stop and report if a connectivity / identity check fails — don't try alternative credentials or contexts.
- If a command fails due to RBAC or IAM permissions, record it and move on — never attempt privilege escalation.
- Treat the `Inputs` section of each workflow as required: ask for unspecified values, use documented defaults when reasonable, but never invent values for sensitive scoping inputs like `CONTEXT`, `PROFILE`, or `NAMESPACE`.
