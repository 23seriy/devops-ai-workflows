# Contributing

Thanks for helping grow this collection! The goal is a curated set of **safe, reusable, AI-agent-friendly DevOps workflows**.

## Adding a new workflow

1. **Create the workflow** at `.claude/commands/<name>.md` with this skeleton (the file doubles as a Claude Code slash command — `/<name>`):

   ```markdown
   ---
   description: One-sentence summary shown in the slash-command picker.
   argument-hint: "REQUIRED=<value> [OPTIONAL=default]"
   ---

   # /<name> — Short title

   What this workflow does, in 2-3 sentences.

   ## Prerequisites
   - Tool X installed
   - Access Y configured

   ## Inputs
   - **VAR_NAME** — meaning. Default: ...

   ## Step 1 — ...

   ```bash
   safe read-only command
   ```

   ## Step N — Generate report

   Write `./<name>-reports/<name>-<timestamp>.md` summarising findings.

   ```text

   Both `description` and `argument-hint` are required. `argument-hint` should mirror the Inputs section: required args first, optional in `[brackets]`, separated by spaces. Examples:

   - `"NAMESPACE=<ns> RELEASE=<name>"`
   - `"[PROFILE=...] [REGION=...] [DEEP=yes|no]"`
   - `"POLICY_ARN=... | PRINCIPAL_ARN=... | POLICY_FILE=path"`

   Do not add editor-specific keys (`auto_execution_mode`, `model_provider`, etc.) — `validate-repo.sh` rejects them.

2. **Register it** in the *Available workflows* table in [`README.md`](./README.md).

3. **(Optional)** Run the in-repo `workflow-author` subagent for a pre-merge review:

   ```text
   Use the workflow-author agent to review .claude/commands/<name>.md
   ```

## Adding a subagent

Repo-maintenance subagents live in `.claude/agents/<name>.md` with this frontmatter:

```markdown
---
name: <name>
description: When this agent should be used. Include enough trigger context that Claude picks it without prompting.
tools: Read, Grep, Glob, Bash
model: sonnet
---

System prompt for the subagent.
```

Keep subagents focused on jobs that live in **this** repo (writing/reviewing workflow files, summarising reports). Diagnostic specialists should be slash commands, not subagents.

## Workflow design rules

- **Read-only by default.** Discovery, listing, describing, logging — fine. Anything that creates, mutates, scales, or deletes resources must be:
  - gated behind an explicit input flag (e.g. `DEEP=yes`, `APPLY=yes`), and
  - clearly labelled in the step heading.
- **No secrets in output.** Never print secret values, tokens, private keys, or passwords. Names and metadata only.
- **Idempotent and safe to re-run.** Running the workflow twice should not change cluster state.
- **No assumptions about the environment.** State the prerequisites; degrade gracefully when optional tools (`jq`, `metrics-server`, etc.) are missing.
- **Produce a report.** Workflows should end by writing a timestamped Markdown report so users have an artefact to share.

## Project-level safety

The shared `.claude/settings.json` defines:

- An **allow list** of read-only bash patterns commonly needed when developing in this repo (`./scripts/validate-repo.sh`, `find`, `grep`, `git status|diff|log`, linters).
- A **deny list** of cluster/cloud mutations (`kubectl apply|delete|scale`, `helm install|upgrade`, `terraform apply|destroy`, `aws iam create|delete|put`, `aws s3 rm`, `aws ec2 terminate-instances`, `aws rds delete`). These are blocked even if a workflow tries to run them.

If you add a new workflow that legitimately needs a denied command (e.g. a future `/apply-...` workflow gated behind `APPLY=yes`), discuss in the PR before relaxing the deny list — the read-only contract is the repo's whole value proposition.

## PR checklist

- [ ] `.claude/commands/<name>.md` added with `description` + `argument-hint` frontmatter
- [ ] README *Available workflows* table updated
- [ ] All commands are read-only or gated behind an opt-in flag
- [ ] No secret values printed
- [ ] `./scripts/validate-repo.sh` passes
- [ ] `shellcheck scripts/*.sh` passes (if you touched a script)
- [ ] Tested against at least one real environment (note which one in the PR description)
