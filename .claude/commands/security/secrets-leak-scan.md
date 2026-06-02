---
description: Scan a git repository for leaked secrets across full history. Uses gitleaks, trufflehog, or manual regex patterns. Read-only, generates a markdown report.
---

# /secrets-leak-scan — Git Repository Secrets Scanner

Scan a git repository's **full commit history** for accidentally committed secrets: API keys, passwords, tokens, private keys, connection strings, and credentials. Uses `gitleaks`, `trufflehog`, or falls back to manual regex patterns. **Read-only** — nothing is modified.

## Prerequisites

- A git repository (local clone).
- Recommended: `gitleaks` or `trufflehog` installed (the workflow will detect which is available).
- Fallback: `grep` and `git log` (always available, less accurate).

## Inputs

- **REPO_PATH** *(required)* — path to the git repository root.
- **SCAN_SCOPE** — `full` (entire git history) or `recent` (last 30 days / last 100 commits). Default: `full`.
- **REPORT_DIR** — Default: `./secrets-leak-scan-reports`.

---

## Step 1 — Detect available tools

// turbo

```bash
echo "=== Available scanners ==="
command -v gitleaks >/dev/null && echo "gitleaks: $(gitleaks version 2>&1)" || echo "gitleaks: not installed"
command -v trufflehog >/dev/null && echo "trufflehog: $(trufflehog --version 2>&1)" || echo "trufflehog: not installed"
echo "git: $(git --version)"
echo "grep: available"

echo ""
echo "=== Repository info ==="
cd $REPO_PATH
echo "Repo: $(basename $(git rev-parse --show-toplevel))"
echo "Branch: $(git branch --show-current)"
echo "Commits: $(git rev-list --count HEAD)"
echo "Remotes: $(git remote -v | head -2)"
```

---

## Step 2 — Run primary scanner

### Option A: gitleaks (preferred)

```bash
cd $REPO_PATH

# Full history scan
gitleaks detect --source . --report-format json --report-path /tmp/gitleaks-report.json --verbose 2>&1

# Or recent only
gitleaks detect --source . --log-opts="--since='30 days ago'" --report-format json --report-path /tmp/gitleaks-report.json --verbose 2>&1

# Parse results
cat /tmp/gitleaks-report.json | jq -r '.[] | "\(.RuleID)\t\(.File)\tcommit=\(.Commit[:8])\tauthor=\(.Author)\tdate=\(.Date)"' | head -50
```

### Option B: trufflehog

```bash
cd $REPO_PATH

# Full history scan
trufflehog git file://. --json 2>/dev/null | jq -r '.SourceMetadata.Data.Git | "\(.file) commit=\(.commit[:8]) email=\(.email)"' | head -50

# Recent only
trufflehog git file://. --since-commit=$(git rev-list -1 --before="30 days ago" HEAD) --json 2>/dev/null | head -50
```

### Option C: Manual regex fallback

If neither tool is installed, fall back to git log + grep:

```bash
cd $REPO_PATH

echo "=== Scanning for common secret patterns ==="

# High-confidence patterns
git log -p --all --diff-filter=A 2>/dev/null | grep -nE \
  'AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z\-_]{35}|ghp_[0-9a-zA-Z]{36}|gho_[0-9a-zA-Z]{36}|glpat-[0-9a-zA-Z\-]{20}|sk-[0-9a-zA-Z]{48}|xox[bporas]-[0-9a-zA-Z\-]+' \
  | head -30

# AWS keys
git log -p --all 2>/dev/null | grep -nE 'AKIA[0-9A-Z]{16}' | head -10
echo ""

# Private keys
git log -p --all 2>/dev/null | grep -nE 'BEGIN (RSA |DSA |EC |OPENSSH )?PRIVATE KEY' | head -10
echo ""

# Connection strings
git log -p --all 2>/dev/null | grep -nE '(mysql|postgres|mongodb|redis)://[^/\s]+:[^@\s]+@' | head -10
echo ""

# Generic password/secret assignments
git log -p --all 2>/dev/null | grep -nE '(password|passwd|secret|token|api_key|apikey|access_key|private_key)\s*[:=]\s*["\x27][^\s"'\'']{8,}' | head -20
echo ""

# .env files committed
git log --all --name-only --diff-filter=A 2>/dev/null | grep -E '^\.env$|\.env\.' | sort -u
echo ""

# Key/cert files committed
git log --all --name-only --diff-filter=A 2>/dev/null | grep -iE '\.(pem|key|p12|pfx|jks|keystore|cert)$' | sort -u
```

---

## Step 3 — Triage findings

For each finding, classify:

| Severity | Pattern | Action |
|---|---|---|
| 🔴 Critical | AWS access key (`AKIA*`), private key, GCP service account JSON, GitHub PAT (`ghp_*`), Slack token (`xox*`) | Rotate immediately. Check if key is still active. |
| 🔴 Critical | Database connection string with credentials | Rotate password. Check if DB is exposed. |
| 🟡 Warning | Generic `password=`, `secret=`, `token=` in config files | May be placeholder/test value — verify if real. |
| 🟡 Warning | `.env` file committed | Remove from tracking, add to `.gitignore`. |
| 🔵 Info | Test/mock credentials, example configs, documentation examples | Verify these are not real credentials. |

### Check if secrets are still active

For AWS keys:

```bash
# Check if a found AWS key is still active (requires aws CLI)
aws sts get-caller-identity --access-key-id AKIA... 2>&1
# "InvalidClientTokenId" = deactivated/deleted (safe)
# Success = STILL ACTIVE (rotate immediately!)
```

### Check if secrets are in current HEAD

```bash
# Is the secret still in the current codebase? (not just history)
git grep -l 'AKIA...' HEAD 2>/dev/null
```

If the secret is only in history (not current HEAD), it's still a risk — the git history is accessible to anyone who clones the repo.

---

## Step 4 — Check .gitignore coverage

// turbo

```bash
cd $REPO_PATH

echo "=== .gitignore check ==="
cat .gitignore 2>/dev/null || echo "NO .gitignore FILE"

echo ""
echo "=== Files that should typically be gitignored ==="
for pattern in ".env" ".env.*" "*.pem" "*.key" "*.p12" "*.pfx" "*.jks" "*.keystore" "credentials" "*.tfvars" "*.tfstate" "terraform.tfstate*" ".terraform/" "secrets.yaml" "secrets.yml"; do
  found=$(git ls-files "$pattern" 2>/dev/null)
  [ -n "$found" ] && echo "TRACKED: $found (should be in .gitignore)"
done
```

---

## Step 5 — Generate report

Compile findings into a timestamped Markdown report:

```
$REPORT_DIR/secrets-leak-scan-<repo-name>-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# Secrets Leak Scan Report

| Field | Value |
|---|---|
| Generated | <timestamp> |
| Repository | <repo name> |
| Scanner | gitleaks / trufflehog / manual |
| Scan scope | full history / recent |
| Commits scanned | <count> |
| Findings | <count> |
| Risk level | 🔴 / 🟡 / 🟢 |

## Summary
<count of findings by severity>

## 🔴 Critical findings
<secret type, file, commit, still active?>

## 🟡 Warnings
<potential secrets, .env files, suspicious patterns>

## 🔵 Info
<test credentials, documentation examples>

## .gitignore gaps
<files that should be excluded>

## Recommended actions
1. Rotate all 🔴 critical secrets immediately
2. Add missing .gitignore patterns
3. Consider using git-filter-repo to remove secrets from history
4. Set up pre-commit hooks to prevent future leaks
```

---

## Safety rules

- This workflow is **entirely read-only**. No files are modified, no secrets are rotated, no git history is rewritten.
- **Never print full secret values** in the report. Redact to first/last 4 characters: `AKIA****WXYZ`.
- The `sts get-caller-identity` check for AWS keys is read-only — it does not perform any actions with the key.
- If a secret is found to be active, recommend rotation but do not rotate it.
- Suggested remediation commands (git-filter-repo, pre-commit hooks) are provided in the report for the user to evaluate and run manually.
