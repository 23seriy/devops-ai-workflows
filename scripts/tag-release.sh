#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────
# tag-release.sh — cut a release tag from CHANGELOG.md
# ────────────────────────────────────────────────────────────────
# Usage: ./scripts/tag-release.sh <version> [--push]
#   version   e.g. 1.2.0 (the 'v' prefix is added if missing)
#   --push    push the tag to origin (triggers the Release workflow)
#
# Pre-flight:
#   - CHANGELOG.md has a "## [<version>]" section
#   - the working tree is clean and HEAD is on main
# Then creates an annotated tag. With --push, pushes it.
# ────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

if [ $# -lt 1 ]; then
  echo "Usage: $0 <version> [--push]" >&2
  exit 2
fi

version=${1#v}
tag="v${version}"
push=no
[ "${2:-}" = "--push" ] && push=yes

if ! grep -q "^## \[${version}\]" CHANGELOG.md; then
  echo "ERROR: CHANGELOG.md has no '## [${version}]' section" >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: working tree is not clean — commit or stash first" >&2
  exit 1
fi

if [ "$(git branch --show-current)" != "main" ]; then
  echo "ERROR: not on main (on '$(git branch --show-current)')" >&2
  exit 1
fi

if git rev-parse "$tag" >/dev/null 2>&1; then
  echo "ERROR: tag $tag already exists" >&2
  exit 1
fi

git tag -a "$tag" -m "Release $tag"
echo "Tagged $tag"

if [ "$push" = "yes" ]; then
  git push origin "$tag"
  echo "Pushed $tag — the Release workflow will publish notes from CHANGELOG.md"
else
  echo "Not pushed. Run: git push origin $tag"
fi
