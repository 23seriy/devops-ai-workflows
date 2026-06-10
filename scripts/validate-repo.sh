#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────
# validate-repo.sh — Local validation for devops-ai-workflows
# ────────────────────────────────────────────────────────────────
# Usage: ./scripts/validate-repo.sh
#
# Checks:
#   - workflow markdown files have YAML frontmatter with
#     required keys (description, argument-hint)
#   - no obsolete editor keys (auto_execution_mode, etc.)
#   - subagent files (if any) have name + description in frontmatter
#   - README links point to existing local files
#   - shell scripts are executable
#   - .claude/settings.json parses as JSON
#   - optional markdownlint/shellcheck if installed
# ────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT_DIR"

errors=0

echo "🔎 Validating devops-ai-workflows repo"
echo "Root: $ROOT_DIR"
echo ""

# ────────────────────────────────────────────────────────────────
# Workflow frontmatter (description + argument-hint, no obsolete keys)
# ────────────────────────────────────────────────────────────────
echo "== Workflow frontmatter =="
workflow_count=0
while IFS= read -r file; do
  workflow_count=$((workflow_count + 1))
  # Extract frontmatter block (between first two --- lines)
  frontmatter=$(awk '/^---$/{c++; if (c==2) exit; next} c==1' "$file")

  if [ -z "$frontmatter" ]; then
    echo "❌ Missing or empty frontmatter: $file"
    errors=$((errors + 1))
    continue
  fi

  if ! grep -q '^description:' <<<"$frontmatter"; then
    echo "❌ Missing 'description:' in frontmatter: $file"
    errors=$((errors + 1))
  fi

  if ! grep -q '^argument-hint:' <<<"$frontmatter"; then
    echo "❌ Missing 'argument-hint:' in frontmatter: $file"
    errors=$((errors + 1))
  fi

  # Obsolete keys from other editors / older tooling
  for bad_key in auto_execution_mode model_provider; do
    if grep -q "^${bad_key}:" <<<"$frontmatter"; then
      echo "❌ Obsolete frontmatter key '${bad_key}' in: $file"
      errors=$((errors + 1))
    fi
  done
done < <(find .claude/commands -name '*.md' | sort)
echo "Checked $workflow_count workflow file(s)"
[ "$errors" -eq 0 ] && echo "✅ Workflow frontmatter OK"
echo ""

# ────────────────────────────────────────────────────────────────
# Subagent frontmatter (if any)
# ────────────────────────────────────────────────────────────────
if [ -d .claude/agents ]; then
  echo "== Subagent frontmatter =="
  agent_count=0
  while IFS= read -r file; do
    agent_count=$((agent_count + 1))
    frontmatter=$(awk '/^---$/{c++; if (c==2) exit; next} c==1' "$file")

    if [ -z "$frontmatter" ]; then
      echo "❌ Missing frontmatter: $file"
      errors=$((errors + 1))
      continue
    fi

    for required in name description; do
      if ! grep -q "^${required}:" <<<"$frontmatter"; then
        echo "❌ Missing '${required}:' in subagent: $file"
        errors=$((errors + 1))
      fi
    done
  done < <(find .claude/agents -name '*.md' 2>/dev/null | sort)
  echo "Checked $agent_count subagent file(s)"
  [ "$errors" -eq 0 ] && echo "✅ Subagent frontmatter OK"
  echo ""
fi

# ────────────────────────────────────────────────────────────────
# README local links
# ────────────────────────────────────────────────────────────────
echo "== README local links =="
broken=0
while IFS= read -r link; do
  path=${link#./}
  if [ ! -e "$path" ]; then
    echo "❌ Broken README link: $link"
    broken=$((broken + 1))
    errors=$((errors + 1))
  fi
done < <(grep -oE '\]\(\./[^)]+\)' README.md | sed -E 's/^.*\((.*)\)$/\1/' | sort -u)
[ "$broken" -eq 0 ] && echo "✅ README local links OK"
echo ""

# ────────────────────────────────────────────────────────────────
# Scripts are executable
# ────────────────────────────────────────────────────────────────
echo "== Script executability =="
nonexec=0
while IFS= read -r file; do
  if [ ! -x "$file" ]; then
    echo "❌ Script not executable: $file"
    nonexec=$((nonexec + 1))
    errors=$((errors + 1))
  fi
done < <(find scripts -name '*.sh' | sort)
[ "$nonexec" -eq 0 ] && echo "✅ Scripts executable"
echo ""

# ────────────────────────────────────────────────────────────────
# .claude/settings.json parses
# ────────────────────────────────────────────────────────────────
if [ -f .claude/settings.json ]; then
  echo "== .claude/settings.json =="
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import json,sys; json.load(open(".claude/settings.json"))' 2>/dev/null; then
      echo "✅ .claude/settings.json is valid JSON"
    else
      echo "❌ .claude/settings.json is not valid JSON"
      errors=$((errors + 1))
    fi
  elif command -v jq >/dev/null 2>&1; then
    if jq empty .claude/settings.json >/dev/null 2>&1; then
      echo "✅ .claude/settings.json is valid JSON"
    else
      echo "❌ .claude/settings.json is not valid JSON"
      errors=$((errors + 1))
    fi
  else
    echo "ℹ️ python3 / jq not installed; skipping JSON parse check"
  fi
  echo ""
fi

# ────────────────────────────────────────────────────────────────
# Optional linters
# ────────────────────────────────────────────────────────────────
if command -v markdownlint-cli2 >/dev/null 2>&1; then
  echo "== markdownlint-cli2 =="
  markdownlint-cli2 '**/*.md' --config .github/.markdownlint.json || errors=$((errors + 1))
  echo ""
elif command -v markdownlint >/dev/null 2>&1; then
  echo "== markdownlint =="
  markdownlint '**/*.md' --config .github/.markdownlint.json || errors=$((errors + 1))
  echo ""
else
  echo "ℹ️ markdownlint not installed; skipping"
  echo ""
fi

if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck =="
  shellcheck scripts/*.sh || errors=$((errors + 1))
  echo ""
else
  echo "ℹ️ shellcheck not installed; skipping"
  echo ""
fi

if [ "$errors" -eq 0 ]; then
  echo "✅ Validation passed"
else
  echo "❌ Validation failed with $errors issue(s)"
  exit 1
fi
