#!/usr/bin/env bash
# Run the validator test suite, installing bats locally if it is missing.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v bats >/dev/null 2>&1; then
  echo "bats not found — installing locally via npm"
  npx --yes bats scripts/tests/
else
  bats scripts/tests/
fi
