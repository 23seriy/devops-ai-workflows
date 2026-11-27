#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────
# changelog-release-notes.sh — extract a version's release notes
# ────────────────────────────────────────────────────────────────
# Usage: ./scripts/changelog-release-notes.sh <version> [CHANGELOG]
#   version   e.g. 1.2.0 or v1.2.0
#   CHANGELOG default: CHANGELOG.md
#
# Prints the body under the matching "## [<version>]" heading to stdout,
# excluding the heading itself and surrounding blank lines.
# Exits 1 if the version is not found.
# ────────────────────────────────────────────────────────────────
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <version> [CHANGELOG]" >&2
  exit 2
fi

version=${1#v}
changelog=${2:-CHANGELOG.md}

if [ ! -f "$changelog" ]; then
  echo "ERROR: $changelog not found" >&2
  exit 1
fi

notes=$(
  awk -v ver="$version" '
    !capture && index($0, "## [" ver "]") == 1 { capture = 1; next }
    capture && index($0, "## [") == 1 { exit }
    capture { lines[++n] = $0 }
    END {
      first = 1; last = n
      while (first <= last && lines[first] ~ /^[[:space:]]*$/) first++
      while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
      for (i = first; i <= last; i++) print lines[i]
    }
  ' "$changelog"
)

if [ -z "$notes" ]; then
  echo "ERROR: no section found for version $version in $changelog" >&2
  exit 1
fi

printf '%s\n' "$notes"
