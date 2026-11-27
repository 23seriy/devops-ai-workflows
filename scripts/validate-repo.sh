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
#   - every workflow is registered in the README *Available workflows* table
#   - examples in docs use a balanced number of code fences
#   - shell scripts are executable
#   - .claude/settings.json parses as JSON
#   - optional markdownlint/shellcheck if installed
# ────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT_DIR"

check_repo() {

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
  # Workflows are registered in the README table
  # ────────────────────────────────────────────────────────────────
  echo "== Workflow registration in README =="
  unregistered=0
  while IFS= read -r file; do
    name=$(basename "$file" .md)
    if ! grep -q "\.claude/commands/${name}\.md" README.md; then
      echo "❌ Workflow not listed in README table: /$name ($file)"
      unregistered=$((unregistered + 1))
      errors=$((errors + 1))
    fi
  done < <(find .claude/commands -name '*.md' | sort)
  [ "$unregistered" -eq 0 ] && echo "✅ All workflows registered in README"
  echo ""

  # ────────────────────────────────────────────────────────────────
  # Balanced code fences in docs (catches examples that swallow the page)
  # ────────────────────────────────────────────────────────────────
  echo "== Code fence balance =="
  unbalanced=0
  while IFS= read -r file; do
    fences=$(grep -cE '^```' "$file" || true)
    if [ $((fences % 2)) -ne 0 ]; then
      echo "❌ Odd number of code fences ($fences) in: $file"
      unbalanced=$((unbalanced + 1))
      errors=$((errors + 1))
    fi
  done < <(find . -path ./.git -prune -o -name '*.md' -print | sort)
  [ "$unbalanced" -eq 0 ] && echo "✅ Code fences balanced"
  echo ""

  # ────────────────────────────────────────────────────────────────
  # Workflows write a timestamped report
  # ────────────────────────────────────────────────────────────────
  echo "== Workflow report/artifact step =="
  no_report=0
  while IFS= read -r file; do
    # A workflow must persist findings: either a -reports/ dir or an explicit written file.
    if ! grep -qiE 'reports?/|-reports|OUTPUT_FILE|open\([^)]*[, ]*["'"'"']w' "$file"; then
      echo "❌ Workflow does not describe a report/artifact path: $file"
      no_report=$((no_report + 1))
      errors=$((errors + 1))
    fi
  done < <(find .claude/commands -name '*.md' | sort)
  [ "$no_report" -eq 0 ] && echo "✅ All workflows write a report"
  echo ""

  # ────────────────────────────────────────────────────────────────
  # No ungated mutating commands (read-only-by-default contract)
  # ────────────────────────────────────────────────────────────────
  echo "== Read-only policy =="
  mutation_re='(kubectl[[:space:]]+(apply|delete|scale|drain|cordon|taint|patch|replace)|terraform[[:space:]]+(apply|destroy|import|state[[:space:]]+(rm|mv|push))|helm[[:space:]]+(install|upgrade|uninstall|rollback)|aws[[:space:]]+[a-z0-9-]+[[:space:]]+(create|delete|put|update|modify|terminate|run|start|stop|reboot)[a-z-]*|aws[[:space:]]+s3[[:space:]]+(rm|mv|cp))'
  policy_violations=0
  while IFS= read -r file; do
    # bash 3.2-safe: slurp into a newline-split array without mapfile.
    IFS=$'\n' read -r -d '' -a lines < "$file" || true
    # Inside fenced code blocks only — prose mentions ("never run helm upgrade") are documentation.
    in_fence=0
    for idx in "${!lines[@]}"; do
      line=${lines[$idx]}
      if [[ "$line" =~ ^[[:space:]]*\`\`\` ]]; then
        if [ "$in_fence" -eq 1 ]; then in_fence=0; else in_fence=1; fi
        continue
      fi
      [ "$in_fence" -eq 1 ] || continue
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      grep -qE "$mutation_re" <<<"$line" || continue
      # Allowed only inside a step/section gated by an opt-in flag (e.g. DEEP=yes, APPLY=yes).
      lineno=$((idx + 1))
      start=$((idx - 19)); [ "$start" -lt 0 ] && start=0
      context=$(printf '%s\n' "${lines[@]:start:lineno-start}")
      if ! grep -qiE 'DEEP[[:space:]]*=[[:space:]]*yes|APPLY[[:space:]]*=[[:space:]]*yes|--dry-run|opt-in|gated|[Oo]ptional|suggest|don.t execute|confirm' <<<"$context"; then
        echo "❌ Ungated mutating command in $file:$lineno — $line"
        policy_violations=$((policy_violations + 1))
        errors=$((errors + 1))
      fi
    done
  done < <(find .claude/commands -name '*.md' | sort)
  [ "$policy_violations" -eq 0 ] && echo "✅ No ungated mutating commands"
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
    # CHANGELOG is excluded to match .markdownlintignore in CI.
    markdownlint-cli2 '**/*.md' '#CHANGELOG.md' --config .github/.markdownlint.json || errors=$((errors + 1))
    echo ""
  elif command -v markdownlint >/dev/null 2>&1; then
    echo "== markdownlint =="
    markdownlint '**/*.md' --ignore CHANGELOG.md --config .github/.markdownlint.json || errors=$((errors + 1))
    echo ""
  else
    echo "ℹ️ markdownlint not installed; skipping"
    echo ""
  fi

  if command -v shellcheck >/dev/null 2>&1 && compgen -G "scripts/*.sh" >/dev/null; then
    echo "== shellcheck =="
    shellcheck scripts/*.sh || errors=$((errors + 1))
    echo ""
  else
    echo "ℹ️ shellcheck not installed; skipping"
    echo ""
  fi

  if [ "$errors" -eq 0 ]; then
    echo "✅ Validation passed"
    return 0
  fi
  echo "❌ Validation failed with $errors issue(s)"
  return 1
}


# Run only when executed directly, so tests can source the functions.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  check_repo
fi
