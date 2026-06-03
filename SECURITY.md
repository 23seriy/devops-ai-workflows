# Security Policy

## Supported versions

Only the latest tagged release receives security updates. See [CHANGELOG.md](./CHANGELOG.md) for the current version.

## Reporting a vulnerability

**Please do not open a public GitHub issue for security problems.**

Use GitHub's private vulnerability reporting:

1. Go to the [Security tab](https://github.com/23seriy/devops-ai-workflows/security) of this repository.
2. Click **Report a vulnerability**.
3. Fill in the advisory form with a description, reproduction steps, and impact assessment.

You should receive an acknowledgement within 5 business days. We will work with you on a fix and coordinate disclosure timing.

## Scope

This repository contains AI-agent workflows, prompts, and rule sets — there is no deployed service. The kinds of issues we consider security-relevant:

- **Workflows that mutate or destroy resources** without the documented opt-in flag (`DEEP=yes`, `APPLY=yes`, etc.) — workflows here are read-only by contract.
- **Prompts or workflows that exfiltrate or print secret values** (credentials, tokens, private keys) when they should redact.
- **Prompts that could be turned against the user** via injection — e.g. a workflow that feeds untrusted input back into the agent without escaping.
- **Scripts in `scripts/`** with command injection, unsafe `eval`, or path traversal.
- **Rules / safety guardrails** that fail open in dangerous ways.

Out of scope:

- Bugs in third-party tools (`kubectl`, `aws`, `terraform`, `helm`, `gitleaks`, etc.) invoked by these workflows — report those upstream.
- Findings from running a workflow against your own systems — those are operational results, not vulnerabilities in this repo.
- Stylistic issues, typos, or non-security CI failures — open a regular issue or PR.

## Disclosure

We prefer **coordinated disclosure**. Once a fix is merged and a release is cut, the advisory will be published with credit to the reporter (unless you ask to remain anonymous).
