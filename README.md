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

| Workflow | Slash command | Description | Prerequisites |
|---|---|---|---|
| [k8s-debug](./.windsurf/workflows/k8s-debug.md) | `/k8s-debug` | General-purpose, read-only Kubernetes cluster diagnostics across nodes, pods, workloads, networking, storage, RBAC, events, and resource pressure. Produces a timestamped Markdown report. | `kubectl` configured for the target cluster. Optional: `jq`, `metrics-server`. |

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

- [ ] `/aws-audit` — read-only AWS account hygiene check (IAM, S3, EC2, security groups, costs)
- [ ] `/terraform-review` — review a `terraform plan` output for risky changes
- [ ] `/helm-diff` — explain a Helm release upgrade diff
- [ ] `/incident-triage` — guided first 15 minutes of an incident
- [ ] `/postmortem` — generate a blameless post-mortem from chat/incident transcript
- [ ] `/ci-debug` — diagnose a failing GitHub Actions / Jenkins / GitLab pipeline
- [ ] `/dockerfile-review` — security and size review of a Dockerfile
- [ ] `/image-cve-scan` — walk through a container CVE report and prioritise fixes

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). The short version:

1. Add the Windsurf version to `.windsurf/workflows/<name>.md` (with frontmatter and `// turbo` where safe).
2. Add the tool-agnostic copy to `runbooks/<name>.md`.
3. Update the **Available workflows** table in this README.
4. Keep workflows **read-only by default**. Anything mutating must be opt-in (e.g. a `DEEP=yes` flag) and clearly flagged.

## License

[MIT](./LICENSE) — use freely, attribution appreciated but not required.
