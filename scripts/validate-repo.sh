#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────
# validate-repo.sh — Local validation for devops-ai-workflows
# ────────────────────────────────────────────────────────────────
# Usage: ./scripts/validate-repo.sh
#
# Checks:
#   - workflow markdown files have YAML frontmatter
#   - README links point to existing local files
#   - shell scripts are executable
#   - optional markdownlint/shellcheck if installed
# ────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT_DIR"

errors=0

echo "🔎 Validating devops-ai-workflows repo"
echo "Root: $ROOT_DIR"
echo ""

echo "== Workflow frontmatter =="
while IFS= read -r file; do
  if ! head -1 "$file" | grep -q '^---$'; then
    echo "❌ Missing frontmatter: $file"
    errors=$((errors + 1))
  fi
done < <(find workflows -name '*.md' | sort)
[ "$errors" -eq 0 ] && echo "✅ Workflow frontmatter OK"
echo ""

echo "== README local links =="
while IFS= read -r link; do
  path=${link#./}
  if [ ! -e "$path" ]; then
    echo "❌ Broken README link: $link"
    errors=$((errors + 1))
  fi
done < <(grep -oE '\]\(\./[^)]+\)' README.md | sed -E 's/^.*\((.*)\)$/\1/' | sort -u)
[ "$errors" -eq 0 ] && echo "✅ README local links OK"
echo ""

echo "== Script executability =="
while IFS= read -r file; do
  if [ ! -x "$file" ]; then
    echo "❌ Script not executable: $file"
    errors=$((errors + 1))
  fi
done < <(find scripts -name '*.sh' | sort)
[ "$errors" -eq 0 ] && echo "✅ Scripts executable"
echo ""

if command -v markdownlint >/dev/null 2>&1; then
  echo "== markdownlint =="
  markdownlint '**/*.md' || errors=$((errors + 1))
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
