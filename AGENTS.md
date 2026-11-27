# AGENTS.md

Cross-tool entry point for AI coding agents (Codex, Cursor, Windsurf, Gemini CLI, Claude Code, …). Claude Code reads `CLAUDE.md`; this file carries the same instructions so other agents that look for `AGENTS.md` inherit them.

## What this repo is

A collection of **read-only** AI-agent workflows, prompts, and safety rules for DevOps/SRE/platform work. "Workflows" means slash commands for AI agents (`.claude/commands/*.md`), not GitHub Actions.

## Inherited safety rules

These rule files apply to any work done in this repo. Load them before acting:

- [`rules/devops-agent.md`](./rules/devops-agent.md) — general DevOps guardrails
- [`rules/aws.md`](./rules/aws.md) — AWS account, IAM, and cost safety
- [`rules/kubernetes.md`](./rules/kubernetes.md) — Kubernetes / Helm / GitOps safety
- [`rules/terraform.md`](./rules/terraform.md) — Terraform state and change safety

## Non-negotiables when editing this repo

- A workflow lives at `.claude/commands/<name>.md` with `description` + `argument-hint` frontmatter.
- **Read-only by default.** Anything that creates/mutates/deletes must be gated behind an opt-in flag (`DEEP=yes`, `APPLY=yes`) and labelled in the step heading.
- **No secret values in output** — names, types, key lists, counts only.
- **Idempotent** — running twice must not change cluster/account state.
- **Degrade gracefully** when optional tools are missing.
- **Write a timestamped report** at `./<name>-reports/<name>-<YYYYMMDD-HHMMSS>.md`.
- **Register the workflow** in the *Available workflows* table in [`README.md`](./README.md).

## Validation

```bash
./scripts/validate-repo.sh      # frontmatter, README registration, report paths, read-only policy, fence balance
bats scripts/tests/             # validator unit tests (or ./scripts/test-validate.sh)
```

`pre-commit install` runs the same checks (markdownlint, shellcheck, actionlint, validate-repo) before each commit.

## Layout

- `.claude/commands/` — workflow definitions (source of truth)
- `.claude/agents/` — repo-maintenance subagents
- `prompts/` — reusable system prompts for any LLM
- `rules/` — agent-agnostic safety rule sets (imported above)
- `scripts/` — standalone bash helpers + tests
