# Repo Health Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the four actionable findings from the 2026-07-04 repo-health audit and open a PR.

**Architecture:** Four independent file edits + a CHANGELOG bump, all on one branch. No new dependencies, no new files (except gitignoring `settings.local.json`).

**Tech Stack:** GitHub Actions YAML, Markdown, JSON, git.

## Global Constraints

- All edits are in the existing repo at `/Users/solshanetski/src/devops-ai-workflows`.
- Branch off `main`. PR targets `main`.
- Do not delete stale branches in this PR — that's a local cleanup operation done separately.
- CI must pass: `./scripts/validate-repo.sh`, shellcheck, markdownlint (which will now fail the build).
- Omit `Co-Authored-By: Claude ...` from commits (project convention).

---

### Task 1: Fix CI — markdownlint must fail the build

**Files:**

- Modify: `.github/workflows/ci.yml:40`

**Context:** The `Lint markdown` step at line 40 has `continue-on-error: true`, so markdown lint violations never block a PR. The link-checker step (line 33) intentionally keeps `continue-on-error: true` — external URLs can be unavailable. Only the linter step needs to change.

- [ ] **Step 1: Create branch**

```bash
git checkout -b fix/repo-health-cleanup
```

Expected: `Switched to a new branch 'fix/repo-health-cleanup'`

- [ ] **Step 2: Remove `continue-on-error` from the markdownlint step**

Edit `.github/workflows/ci.yml`. Remove **only** line 40 (`continue-on-error: true` under `Lint markdown`). Leave the identical line under `Check markdown links` (line 33) intact.

Before (lines 35-40):

```yaml
      - name: Lint markdown
        uses: DavidAnson/markdownlint-cli2-action@v23
        with:
          globs: '**/*.md'
          config: '.github/.markdownlint.json'
        continue-on-error: true
```

After (lines 35-39):

```yaml
      - name: Lint markdown
        uses: DavidAnson/markdownlint-cli2-action@v23
        with:
          globs: '**/*.md'
          config: '.github/.markdownlint.json'
```

- [ ] **Step 3: Verify YAML is valid**

```bash
python3 -c "import yaml, sys; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo "OK"
```

Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: markdownlint now fails the build (remove continue-on-error)"
```

---

### Task 2: Remove completed `/repo-health` item from README Roadmap

**Files:**

- Modify: `README.md:189`

**Context:** Line 189 lists `- [ ] /repo-health — README, license, CI, branch protection, stale branches` as a future TODO. The workflow was shipped in v1.1.0 and is listed in the Available Workflows table at line 61. The roadmap item is stale and confusing.

- [ ] **Step 1: Delete the stale roadmap line**

In `README.md`, find the **Security & repo hygiene** block in the Roadmap section and delete the `/repo-health` line:

```
- [ ] `/repo-health` — README, license, CI, branch protection, stale branches
```

Leave all other roadmap items untouched.

- [ ] **Step 2: Verify the Available Workflows table still has `/repo-health`**

```bash
grep -n "repo-health" README.md
```

Expected: one or more lines showing the table entry (line ~61) but NOT the roadmap TODO.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: remove /repo-health from roadmap (shipped in v1.1.0)"
```

---

### Task 3: Gitignore `settings.local.json`

**Files:**

- Modify: `.gitignore`

**Context:** `.claude/settings.local.json` contains git write permissions (`git checkout *`, `git add *`, `git commit -m '*'`) that are appropriate for the repo maintainer's local dev workflow but should not be pre-approved for all users. The `*.local.*` naming convention signals machine-local overrides. It should not be tracked. The file's content stays on disk — only tracking is removed.

- [ ] **Step 1: Add the pattern to `.gitignore`**

Append to `.gitignore` under the `# OS / editor` or `# Local secrets` block:

```
# Claude Code local settings (machine-specific permissions)
.claude/settings.local.json
```

- [ ] **Step 2: Untrack the file without deleting it**

```bash
git rm --cached .claude/settings.local.json
```

Expected: `rm '.claude/settings.local.json'`

- [ ] **Step 3: Verify the file still exists on disk**

```bash
ls -la .claude/settings.local.json
```

Expected: file present.

- [ ] **Step 4: Commit**

```bash
git add .gitignore
git commit -m "chore: gitignore settings.local.json (machine-local claude permissions)"
```

---

### Task 4: Bump CHANGELOG to v1.2.0

**Files:**

- Modify: `CHANGELOG.md:5-21`

**Context:** The `[Unreleased]` section has accumulated content for the Claude Code integration work. Promote it to `[1.2.0]` dated today, add the hygiene fixes from this PR, and add a new empty `[Unreleased]` header for future work.

- [ ] **Step 1: Promote [Unreleased] to [1.2.0] and add hygiene entries**

Replace the current `## [Unreleased]` block (lines 5–21) with:

```markdown
## [Unreleased]

## [1.2.0] — 2026-07-04

### Added — Claude Code
- **`argument-hint`** frontmatter on every workflow — shows expected args inline in the slash-command picker
- **`.claude/settings.json`** — shared project permissions: read-only bash allowlist + cluster/cloud-mutation denylist that enforces the repo's read-only contract at the tool layer
- **`.claude/agents/workflow-author.md`** — repo subagent for reviewing new workflow files against the contribution rules
- **CLAUDE.md `@`-imports** of `rules/devops-agent.md`, `rules/kubernetes.md`, `rules/terraform.md` so safety guardrails auto-load when Claude Code runs in this repo

### Fixed
- Removed bogus `auto_execution_mode: 2` frontmatter from `/k8s-upgrade-readiness` (left over from another editor)
- `scripts/stale-branches.sh` no longer silently fails to skip the `main`/`master` branches (precedence bug in `||` + `&&` chain)
- `scripts/*.sh` are now shellcheck-clean (argument flags converted to bash arrays, `read -r` used everywhere)
- Markdownlint CI step now fails the build (removed `continue-on-error: true`)
- Removed stale `/repo-health` roadmap TODO from README (shipped in v1.1.0)
- `settings.local.json` removed from git tracking (machine-local permissions should not be shared)

### Improved
- **`scripts/validate-repo.sh`** — checks for `description` + `argument-hint` in every workflow, validates `.claude/settings.json` parses, validates subagent frontmatter
- **CI** — split into 3 jobs (validate, markdown, shellcheck); shellcheck now actually installs and fails the build on findings; least-privilege `permissions:` block added
```

- [ ] **Step 2: Verify CHANGELOG structure**

```bash
grep -n "^## \[" CHANGELOG.md
```

Expected output (order matters — newest first):

```
5:## [Unreleased]
7:## [1.2.0] — 2026-07-04
29:## [1.1.0] — 2026-06-02
```

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "chore: release v1.2.0 changelog"
```

---

### Task 5: Validate and open PR

- [ ] **Step 1: Run local validation**

```bash
./scripts/validate-repo.sh
```

Expected: all checks pass (no errors).

- [ ] **Step 2: Push branch**

```bash
git push -u origin fix/repo-health-cleanup
```

- [ ] **Step 3: Open PR**

```bash
gh pr create \
  --title "chore: repo health cleanup (CI enforcement, README, gitignore, changelog)" \
  --body "$(cat <<'EOF'
## Summary

Fixes from the 2026-07-04 repo-health audit:

- **CI**: `markdownlint` step now fails the build — `continue-on-error: true` removed. Link-checker step intentionally left lenient (external URLs can be down).
- **README**: Removed stale `/repo-health` roadmap TODO — shipped in v1.1.0.
- **settings.local.json**: Removed from git tracking (`.gitignore` updated). File contains machine-local git write permissions that should not be pre-approved for all users. File stays on disk.
- **CHANGELOG**: Promoted `[Unreleased]` block to `[1.2.0]` dated 2026-07-04.

## Test plan

- [ ] CI passes on this PR (validate + shellcheck jobs; markdown lint job is now enforced)
- [ ] `./scripts/validate-repo.sh` passes locally
- [ ] `settings.local.json` no longer appears in `git status` after clone (verify: `git ls-files .claude/settings.local.json` returns empty)
- [ ] README Roadmap no longer contains `/repo-health` entry
- [ ] CHANGELOG `[Unreleased]` is empty, `[1.2.0]` entry is present
EOF
)"
```

Expected: PR URL printed.
