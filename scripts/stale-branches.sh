#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────
# stale-branches.sh — List git branches older than N days
# ────────────────────────────────────────────────────────────────
# Usage: ./stale-branches.sh [days] [--remote]
#
# Defaults: 90 days, local branches only.
# Add --remote to include remote tracking branches.
# ────────────────────────────────────────────────────────────────
set -euo pipefail

DAYS="${1:-90}"
INCLUDE_REMOTE=false
[ "${2:-}" = "--remote" ] && INCLUDE_REMOTE=true

CUTOFF=$(date -u -v-${DAYS}d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "${DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)

echo "🌿 Stale Branch Report"
echo "======================"
echo "Repo: $(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo '?')")"
echo "Threshold: ${DAYS} days (before $(echo "$CUTOFF" | cut -dT -f1))"
echo "Scope: $([ "$INCLUDE_REMOTE" = true ] && echo 'local + remote' || echo 'local only')"
echo ""

# Current branch (don't flag this one)
CURRENT=$(git branch --show-current 2>/dev/null || echo "")

echo "--- Stale local branches ---"
stale_local=0
for branch in $(git for-each-ref --sort=committerdate --format='%(refname:short) %(committerdate:iso8601)' refs/heads/ | while read name date; do
  # Compare dates
  branch_epoch=$(date -jf "%Y-%m-%d %H:%M:%S %z" "$date" +%s 2>/dev/null || date -d "$date" +%s 2>/dev/null || echo 0)
  cutoff_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$CUTOFF" +%s 2>/dev/null || date -d "$CUTOFF" +%s 2>/dev/null || echo 0)
  [ "$branch_epoch" -lt "$cutoff_epoch" ] 2>/dev/null && echo "$name"
done); do
  [ "$branch" = "$CURRENT" ] && continue
  [ "$branch" = "main" ] || [ "$branch" = "master" ] && continue
  last_commit=$(git log -1 --format='%ci (%cr)' "$branch" 2>/dev/null || echo "unknown")
  author=$(git log -1 --format='%an' "$branch" 2>/dev/null || echo "unknown")
  echo "  $branch"
  echo "    Last commit: $last_commit"
  echo "    Author: $author"
  stale_local=$((stale_local + 1))
done
[ "$stale_local" -eq 0 ] && echo "  (none)"
echo ""
echo "Stale local branches: $stale_local"

if [ "$INCLUDE_REMOTE" = true ]; then
  echo ""
  echo "--- Stale remote branches ---"
  git fetch --prune 2>/dev/null || true
  stale_remote=0
  git for-each-ref --sort=committerdate --format='%(refname:short) %(committerdate:iso8601)' refs/remotes/origin/ | while read name date; do
    # Skip HEAD and main/master
    echo "$name" | grep -qE 'HEAD|/main$|/master$' && continue
    branch_epoch=$(date -jf "%Y-%m-%d %H:%M:%S %z" "$date" +%s 2>/dev/null || date -d "$date" +%s 2>/dev/null || echo 0)
    cutoff_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$CUTOFF" +%s 2>/dev/null || date -d "$CUTOFF" +%s 2>/dev/null || echo 0)
    if [ "$branch_epoch" -lt "$cutoff_epoch" ] 2>/dev/null; then
      last_commit=$(git log -1 --format='%ci (%cr)' "$name" 2>/dev/null || echo "unknown")
      echo "  $name — $last_commit"
      stale_remote=$((stale_remote + 1))
    fi
  done
  echo ""
  echo "Stale remote branches: $stale_remote"
fi

echo ""
echo "💡 To delete a stale local branch:  git branch -d <branch>"
echo "💡 To delete a stale remote branch: git push origin --delete <branch>"
