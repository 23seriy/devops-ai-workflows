---
description: Security and reliability review of GitHub Actions workflow files — untrusted input injection, excessive permissions, unpinned actions, pull_request_target risks, secret handling, and cache poisoning. Read-only static analysis.
argument-hint: "WORKFLOW_PATH=<file|glob|dir> [REPO_ROOT=...] [DEEP=yes|no] [REPORT_DIR=...]"
---

# /github-actions-review — GitHub Actions Security & Reliability Review

Static analysis of GitHub Actions workflow files (`.github/workflows/*.yml`) for security and reliability problems before they happen. Focuses on the classes of issue that cause real supply-chain incidents: expression injection, over-broad tokens, mutable action refs, `pull_request_target` footguns, secret exposure, and cache poisoning. **Read-only** — no workflows are modified or run.

## Prerequisites

- One or more workflow files (or a directory containing them) to review.
- Optional: `actionlint` for structural validation.
- Optional: `gh` CLI for resolving action SHAs to tags.
- Optional: `yq` for structured YAML queries.

## Inputs

- **WORKFLOW_PATH** *(required)* — path to a workflow file, glob, or directory. A directory is searched recursively for `*.yml` / `*.yaml`.
- **REPO_ROOT** — repository root for resolving referenced local actions (`./.github/actions/...`). Default: nearest `.git` ancestor.
- **DEEP** — `yes` also reviews referenced composite/local actions and reusable workflows. Default: `no`.
- **REPORT_DIR** — report output directory. Default: `./github-actions-review-reports`.

---

## Step 1 — Discover workflow files

```bash
if [ -d "$WORKFLOW_PATH" ]; then
  find "$WORKFLOW_PATH" -type f \( -name '*.yml' -o -name '*.yaml' \) \
    -not -path '*/.git/*' -not -path '*/node_modules/*' | sort
elif [ -n "${WORKFLOW_PATH##*[*?]}" ]; then
  echo "$WORKFLOW_PATH"
else
  ls $WORKFLOW_PATH 2>/dev/null
fi
```

Report the list of files reviewed up front. If none are found, stop and report.

---

## Step 2 — Structural validation

```bash
if command -v actionlint >/dev/null 2>&1; then
  actionlint -oneline $FILES || true
else
  echo "actionlint not installed — skipping structural checks (install: https://github.com/rhysd/actionlint)"
fi
```

If `actionlint` is missing, still do the static checks below — they cover the security-relevant classes.

---

## Step 3 — Permission scope

```bash
grep -nE '^(permissions|  permissions):' -A6 $FILES 2>/dev/null
grep -nE 'permissions: *write-all' $FILES 2>/dev/null
grep -nE '^[^#]*\bpermissions:' -A0 $FILES 2>/dev/null | head -40
```

Flag:

- No `permissions:` block at all (workflow inherits the repo/org default, often `write-all`).
- `permissions: write-all` — should be scoped per job.
- `contents: write` / `packages: write` / `id-token: write` on jobs that only read.
- `pull_request_target` with `id-token: write` or write `contents` (combines untrusted trigger with privileged token — see Step 5).

---

## Step 4 — Action pinning and trust

```bash
grep -nE 'uses: *[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@' $FILES 2>/dev/null
grep -nE 'uses: *[^#]*@(main|master|latest|v[0-9]+)\b' $FILES 2>/dev/null
grep -nE 'uses: *[^#]*@v[0-9]+\b' $FILES 2>/dev/null | grep -v '@[0-9a-f]\{40\}' | head -40
```

Flag:

- `uses:` referencing a tag or major version (`@v4`, `@main`) instead of a full 40-character commit SHA — mutable refs are a classic supply-chain risk.
- `uses: actions/...@master` / `@main` — unpinned branch.
- `uses: ./.github/...` local actions — verify the action's own `action.yml` doesn't run untrusted code (DEEP).
- Docker `uses: docker://...` images without a sha256 digest.
- Third-party actions not owned by a verified publisher org (`actions/*`, `github/*`, `docker/*`, or a known vendor) — flag for review.

---

## Step 5 — Event trigger and injection risks

```bash
grep -nE '^on:' -A12 $FILES 2>/dev/null
grep -nE 'pull_request_target' $FILES 2>/dev/null
grep -nE 'workflow_run' $FILES 2>/dev/null
```

Flag:

- **`pull_request_target`** combined with `actions/checkout` of the PR's head ref (`ref: ${{ github.event.pull_request.head.sha }}` or `head.ref`) — gives untrusted PR code access to write tokens and secrets. This is the #1 GitHub Actions RCE pattern.
- `workflow_run` without verifying `github.event.workflow_run.head_repository.full_name == github.repository`.
- `issue_comment` / `discussion_comment` triggers running untrusted comment text.
- Missing `if: github.event.pull_request.head.repo.full_name == github.repository` guard on fork-prone workflows.

---

## Step 6 — Expression injection (script injection)

```bash
grep -nE '\$\{\{[^}]*github\.event\.(issue|pull_request|comment|review|head_commit)\.' $FILES 2>/dev/null
grep -nE '\$\{\{[^}]*github\.(head_ref|ref_name)' $FILES 2>/dev/null
grep -nE '^\s*(run|script):' -A3 $FILES 2>/dev/null | grep -E '\$\{\{'
```

Flag:

- Untrusted GitHub context values (`github.event.*.title`, `body`, `head_ref`, `comment.body`, branch names) interpolated directly into `run:` / `script:` blocks — attacker-controlled strings execute as shell (or JS in `actions/github-script`).
- Recommend passing through an `env:` var (`env: { TITLE: ${{ github.event.issue.title }} }` then `"$TITLE"`) instead of inline interpolation.
- `github.event.pull_request.head.ref` used in a checkout `ref:` without a commit SHA — branch names can contain shell-special characters.

---

## Step 7 — Secret handling

```bash
grep -nE 'secrets\.[A-Za-z0-9_]+' $FILES 2>/dev/null
grep -nE 'secrets\.(GITHUB_TOKEN|ACTIONS_TOKEN)' $FILES 2>/dev/null
grep -nE 'echo .*secrets\.|>>? *\$GITHUB_(OUTPUT|ENV)' $FILES 2>/dev/null
grep -nE '^\s*env:' -A20 $FILES 2>/dev/null | grep -iE 'secret|token|key|pass'
```

Flag:

- `secrets.*` passed into `run:` via `env:` without `set +x` where echo/`set -x` could leak them.
- Secrets written to `$GITHUB_ENV` / `$GITHUB_OUTPUT` (persisted into subsequent steps and visible in logs if logged).
- Secrets referenced from `pull_request_target` workflows (available to untrusted code).
- `GITHUB_TOKEN` used where a scoped app token is required (e.g. `pull_request` from forks with write needed).
- Secret names that suggest static cloud credentials instead of OIDC federation (`AWS_ACCESS_KEY_ID` vs `id-token: write` + `role-to-assume`).
- Never print secret values — report only the expression/name.

---

## Step 8 — Cache and artifact risks

```bash
grep -nE 'actions/cache' -A6 $FILES 2>/dev/null
grep -nE 'actions/upload-artifact|actions/download-artifact' -A4 $FILES 2>/dev/null
grep -nE 'actions/checkout' -A6 $FILES 2>/dev/null | grep -iE 'persist-credentials|submodules|token'
```

Flag:

- `actions/cache` keyed on a value derived from untrusted input (PR title, issue body) without isolation — cache poisoning between trusted/untrusted runs.
- `actions/checkout` on `pull_request_target` with `persist-credentials: true` (default) — token retained in the workspace for PR code.
- `actions/download-artifact` from a `workflow_run` that consumes artifacts from a fork without verifying provenance.
- Artifacts uploaded from untrusted runs and later executed by a privileged workflow.

---

## Step 9 — DEEP: referenced local/composite actions

Only when `DEEP=yes`:

```bash
grep -nE 'uses: *\./' $FILES 2>/dev/null
for a in $(grep -hoE 'uses: *\./[^ ]+' $FILES 2>/dev/null | awk '{print $2}' | sort -u); do
  f="$(git rev-parse --show-toplevel 2>/dev/null)/${a#./}/action.yml"
  [ -f "$f" ] && echo "--- $f" && cat "$f"
done
```

Apply Steps 5–8 to the composite action's `run:` steps too — a composite action can reintroduce injection that the workflow file itself avoids.

---

## Step 10 — Generate report

Compile all findings into a timestamped Markdown report:

```text
$REPORT_DIR/github-actions-review-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# GitHub Actions Review Report

| Field | Value |
|---|---|
| Generated | <timestamp> |
| Files reviewed | <n> |
| Highest severity | 🔴 / 🟡 / 🟢 |

## Summary
<1-2 sentence overall assessment>

## Findings

### 🔴 Critical
<`pull_request_target` + checkout head, expression injection in run, secrets in untrusted contexts>

### 🟡 Warning
<unpinned actions, broad permissions, missing permissions block, cache poisoning>

### 🔵 Info
<actionlint suggestions, minor hardening>

## File-by-file breakdown
<per-workflow analysis with line references>

## Hardening checklist
<ordered list of concrete edits to apply>
```

---

## Safety rules

- This workflow is **entirely read-only**. No workflow file is modified, no action is run, no cache/artifact is touched.
- Never print secret values or environment values — report only expression text and secret names.
- Never suggest auto-editing files; provide a hardening checklist for the maintainer to apply.
- Do not attempt to resolve network-hosted action SHAs unless `gh` is available and the user asked for it.
- If a file cannot be parsed, report it and continue with the remaining files.
