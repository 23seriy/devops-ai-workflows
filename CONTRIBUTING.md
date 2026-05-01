# Contributing

Thanks for helping grow this collection! The goal is a curated set of **safe, reusable, AI-agent-friendly DevOps workflows**.

## Adding a new workflow

1. **Create the workflow** at `workflows/<domain>/<name>.md` with this skeleton:

   ```markdown
   ---
   description: One-sentence summary shown in the slash-command picker.
   ---

   # /<name> — Short title

   What this workflow does, in 2-3 sentences.

   ## Prerequisites
   - Tool X installed
   - Access Y configured

   ## Inputs
   - **VAR_NAME** — meaning. Default: ...

   ## Step 1 — ...
   // turbo
   ```bash
   safe read-only command
   ```

   ## Step N — Generate report
   Write `./<name>-reports/<name>-<timestamp>.md` summarising findings.
   ```

2. **Register it** in the *Available workflows* table in [`README.md`](./README.md).

## Workflow design rules

- **Read-only by default.** Discovery, listing, describing, logging — fine. Anything that creates, mutates, scales, or deletes resources must be:
  - gated behind an explicit input flag (e.g. `DEEP=yes`, `APPLY=yes`), and
  - clearly labelled in the step heading.
- **No secrets in output.** Never print secret values, tokens, private keys, or passwords. Names and metadata only.
- **Idempotent and safe to re-run.** Running the workflow twice should not change cluster state.
- **No assumptions about the environment.** State the prerequisites; degrade gracefully when optional tools (`jq`, `metrics-server`, etc.) are missing.
- **Use `// turbo` only on truly safe commands.** When in doubt, omit it so the user approves.
- **Produce a report.** Workflows should end by writing a timestamped Markdown report so users have an artefact to share.

## PR checklist

- [ ] `workflows/<domain>/<name>.md` added
- [ ] README *Available workflows* table updated
- [ ] All commands are read-only or gated behind an opt-in flag
- [ ] No secret values printed
- [ ] Tested against at least one real environment (note which one in the PR description)
