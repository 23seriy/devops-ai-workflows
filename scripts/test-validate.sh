#!/usr/bin/env bash
# Run the validator test suite, installing bats locally if it is missing.
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v bats >/dev/null 2>&1; then
  bats scripts/tests/
else
  if [ ! -x .bats/bin/bats ]; then
    echo "bats not found — installing locally into ./.bats"
    git clone --depth 1 https://github.com/bats-core/bats-core.git "$PWD/.bats-src"
    "$PWD/.bats-src/install.sh" "$PWD/.bats"
    rm -rf "$PWD/.bats-src"
  fi
  ./.bats/bin/bats scripts/tests/
fi
