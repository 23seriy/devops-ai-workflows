#!/usr/bin/env bats
# Tests for scripts/changelog-release-notes.sh

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  CHANGELOG=$(mktemp)
  cat > "$CHANGELOG" <<'MD'
# Changelog

## [Unreleased]

### Added

- pending thing

## [1.2.0] — 2026-01-02

### Added

- shipped thing

### Fixed

- a bug

## [1.1.0] — 2026-01-01

### Added

- older thing
MD
}

teardown() {
  rm -f "$CHANGELOG"
}

@test "extracts the requested version body only" {
  run "$REPO_ROOT/scripts/changelog-release-notes.sh" 1.2.0 "$CHANGELOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"shipped thing"* ]]
  [[ "$output" == *"a bug"* ]]
  [[ "$output" != *"older thing"* ]]
  [[ "$output" != *"pending thing"* ]]
  [[ "$output" != *"## [1.2.0]"* ]]
}

@test "accepts a leading v prefix" {
  run "$REPO_ROOT/scripts/changelog-release-notes.sh" v1.1.0 "$CHANGELOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"older thing"* ]]
}

@test "trims leading and trailing blank lines" {
  run "$REPO_ROOT/scripts/changelog-release-notes.sh" 1.2.0 "$CHANGELOG"
  [ "${lines[0]}" = "### Added" ]
}

@test "fails for an unknown version" {
  run "$REPO_ROOT/scripts/changelog-release-notes.sh" 9.9.9 "$CHANGELOG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no section found"* ]]
}

@test "fails when the changelog is missing" {
  run "$REPO_ROOT/scripts/changelog-release-notes.sh" 1.2.0 /nonexistent/CHANGELOG.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}
