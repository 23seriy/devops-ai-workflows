# CLAUDE.md

DevOps AI workflows — read-only diagnostic and review workflows for Kubernetes, AWS, IaC, CI/CD, containers, security, and incidents. Designed to be invoked as slash commands by Claude Code (and other AI agents).

## Inherited safety rules

The repo's own safety posture applies to anything done in this repo too — these rule files load automatically:

- @rules/devops-agent.md
- @rules/kubernetes.md
- @rules/terraform.md

## Repo layout

- `.claude/commands/<name>.md` — workflow definitions, auto-discovered by Claude Code as `/<name>` slash commands. Source of truth.
- `.claude/settings.json` — shared project settings: pre-approved read-only `Bash(...)` permissions for working inside this repo, plus a `deny` list that blocks cluster/cloud mutations even if a workflow tries.
- `.claude/agents/<name>.md` — repo-specific subagents (e.g. `workflow-author`) for repo-maintenance tasks. Invoked via the `Agent` tool.
- `prompts/` — reusable system prompts for any LLM (incident-commander, postmortem-writer, etc.).
- `rules/` — agent-agnostic safety rule sets imported above. Downstream repos can load these the same way (e.g. `@rules/kubernetes.md`).
- `scripts/` — standalone bash helpers (`k8s-snapshot.sh`, `aws-whoami.sh`, `stale-branches.sh`, `validate-repo.sh`).

## Slash command frontmatter

Every workflow in `.claude/commands/` must have YAML frontmatter:

```yaml
---
description: One-sentence summary shown in the slash-command picker.
argument-hint: "REQUIRED=... [OPTIONAL=...]"
---
```

- `description` — required. Shown in the `/`-picker.
- `argument-hint` — required. Mirrors the Inputs section so users see expected args inline.

Optional fields (`allowed-tools`, `model`) are deliberately left unset so users can pick what fits their environment.

## Adding or editing a workflow

See [CONTRIBUTING.md](./CONTRIBUTING.md). Non-negotiables when working in this repo:

- File lives at `.claude/commands/<name>.md` with the frontmatter above.
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

Checks YAML frontmatter on every `.claude/commands/**/*.md` (presence of `description` and `argument-hint`), README local links, and script executability. CI (`.github/workflows/ci.yml`) runs the same checks plus markdownlint, shellcheck, and the markdown-link-check action.

## Safety posture for the agent itself

This repo's whole point is to be safe in production environments. When **executing** a workflow against a real cluster / account:

- Confirm context (kubectl context, AWS profile/region, target namespace) with the user **before** running anything.
- Stop and report if a connectivity / identity check fails — don't try alternative credentials or contexts.
- If a command fails due to RBAC or IAM permissions, record it and move on — never attempt privilege escalation.
- Treat the `Inputs` section of each workflow as required: ask for unspecified values, use documented defaults when reasonable, but never invent values for sensitive scoping inputs like `CONTEXT`, `PROFILE`, or `NAMESPACE`.

The shared `.claude/settings.json` enforces this at the tool level by denying common cluster/cloud mutations (`kubectl apply|delete|scale`, `helm install|upgrade|uninstall`, `terraform apply|destroy`, etc.). If you legitimately need to run one of those while iterating, override per-call rather than relaxing the project setting.
