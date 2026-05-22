---
description: Audit repository hygiene and maintainability. Checks README, license, CI, branch protection indicators, stale branches, secrets hygiene, dependency files, and release readiness.
---

# /repo-health — Repository Hygiene Audit

Read-only repository audit for maintainability, security hygiene, and operational readiness. Useful before open-sourcing a repo, onboarding a team, or preparing a production service for long-term ownership.

## Prerequisites

- Local git repository.
- Optional: `gh` CLI for GitHub metadata.
- Optional: `jq`.

## Inputs

- **REPO_PATH** *(required)* — path to the git repository root.
- **STALE_DAYS** — branch staleness threshold. Default: `90`.
- **REPORT_DIR** — Default: `./repo-health-reports`.

---

## Step 1 — Basic repository inventory

// turbo

```bash
cd $REPO_PATH

echo "=== Git basics ==="
git remote -v
git branch --show-current
git log --oneline -5
git status --short

echo "=== Top-level files ==="
find . -maxdepth 2 -type f | sed 's#^./##' | sort | head -100
```

Flag:
- No remote configured.
- Dirty working tree when preparing release/PR.
- Missing standard files: README, LICENSE, CHANGELOG, CONTRIBUTING, CODEOWNERS.

---

## Step 2 — Documentation and ownership

// turbo

```bash
cd $REPO_PATH

for f in README.md LICENSE CHANGELOG.md CONTRIBUTING.md CODEOWNERS .github/CODEOWNERS; do
  [ -f "$f" ] && echo "FOUND: $f" || echo "MISSING: $f"
done

echo "=== README sections ==="
grep -nE '^##? (Overview|Quick start|Usage|Development|Testing|Deployment|Configuration|Troubleshooting|Contributing|License)' README.md 2>/dev/null || true
```

Flag:
- README without quick start, usage, testing, or deployment instructions.
- No ownership file for review routing.
- CHANGELOG absent for reusable tools/libraries.

---

## Step 3 — CI/CD and automation

// turbo

```bash
cd $REPO_PATH

echo "=== CI configs ==="
find .github/workflows .gitlab-ci.yml bitbucket-pipelines.yml Jenkinsfile -maxdepth 2 -type f 2>/dev/null | sort

echo "=== Common quality configs ==="
find . -maxdepth 3 -type f \( -name '.pre-commit-config.yaml' -o -name '.editorconfig' -o -name '.markdownlint*' -o -name 'renovate.json' -o -name 'dependabot.yml' \) | sort
```

Flag:
- No CI workflow/pipeline.
- No dependency update automation (`renovate`/`dependabot`).
- No formatting/lint configuration for active languages.
- CI exists but no security or dependency scanning.

---

## Step 4 — Secrets and ignore hygiene

// turbo

```bash
cd $REPO_PATH

echo "=== .gitignore present ==="
[ -f .gitignore ] && cat .gitignore || echo "NO .gitignore"

echo "=== Sensitive files tracked ==="
for pattern in '.env' '.env.*' '*.pem' '*.key' '*.p12' '*.pfx' '*.tfstate' '*.tfvars' 'kubeconfig' 'credentials' 'secrets.yaml' 'secrets.yml'; do
  git ls-files "$pattern" 2>/dev/null | sed "s/^/TRACKED: /"
done

echo "=== High-confidence secret-looking strings in current tree ==="
git grep -nE 'AKIA[0-9A-Z]{16}|ghp_[0-9A-Za-z]{36}|glpat-[0-9A-Za-z\-]{20}|BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY' 2>/dev/null | head -20 || true
```

If suspicious findings appear, recommend `/secrets-leak-scan` for full history scanning.

---

## Step 5 — Branch and release hygiene

// turbo

```bash
cd $REPO_PATH

echo "=== Recent branches ==="
git for-each-ref --sort=-committerdate --format='%(refname:short) %(committerdate:short) %(authorname)' refs/heads/ refs/remotes/origin/ | head -30

echo "=== Tags/releases ==="
git tag --sort=-creatordate | head -20
```

Flag:
- Many stale branches older than `STALE_DAYS`.
- No tags/releases for production software.
- No clear branching strategy documented.

---

## Step 6 — Generate report

Write:

```
$REPORT_DIR/repo-health-<repo-name>-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# Repository Health Report

| Field | Value |
|---|---|
| Repo | <name> |
| Branch | <branch> |
| Generated | <timestamp> |
| Verdict | Healthy / Needs attention / High risk |

## Summary
<top findings>

## Documentation and ownership
<findings>

## CI/CD and automation
<findings>

## Security hygiene
<findings>

## Branch and release hygiene
<findings>

## Recommended actions
<prioritized list>
```

---

## Safety rules

- This workflow is **read-only**.
- Do not print full secret values. Redact if reporting.
- Do not delete branches or modify repository settings.
- If `gh` or remote API access is unavailable, record that limitation and continue with local checks.
