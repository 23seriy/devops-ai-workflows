#!/usr/bin/env bats
# Tests for scripts/validate-repo.sh
# Run: bats scripts/tests/validate-repo.bats   (or: ./scripts/test-validate.sh)

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  FIXTURE=$(mktemp -d)
  mkdir -p "$FIXTURE/.claude/commands" "$FIXTURE/.claude/agents" "$FIXTURE/scripts"
  # Minimal files the validator expects.
  printf '{}' > "$FIXTURE/.claude/settings.json"
  printf '# readme\n\n[cmd](./.claude/commands/%s.md)\n' "good" > "$FIXTURE/README.md"
}

teardown() {
  rm -rf "$FIXTURE"
}

write_workflow() {
  local name=$1 body=$2
  cat > "$FIXTURE/.claude/commands/$name.md" <<EOF
---
description: test workflow
argument-hint: "X=..."
---

# /$name

$body
EOF
}

run_validator() {
  cd "$FIXTURE" || exit 1
  run "$REPO_ROOT/scripts/validate-repo.sh"
}

@test "passes for a well-formed workflow with a report and no mutations" {
  write_workflow good '## Step 1

```bash
kubectl get pods -n bar
```

## Step 2 — report

Write `./good-reports/x.md`.'
  run_validator
  [ "$status" -eq 0 ]
}

@test "fails when a workflow is not registered in the README" {
  write_workflow good 'Write `./good-reports/x.md`.'
  write_workflow orphan 'Write `./orphan-reports/x.md`.'
  run_validator
  [ "$status" -ne 0 ]
  [[ "$output" == *"not listed in README table: /orphan"* ]]
}

@test "fails when a workflow has no report/artifact path" {
  write_workflow good '## Step 1

```bash
kubectl get pods
```'
  run_validator
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not describe a report"* ]]
}

@test "fails on an ungated mutating command in a code fence" {
  write_workflow good '## Step 1

```bash
kubectl delete pod foo -n bar
```

Write `./good-reports/x.md`.'
  run_validator
  [ "$status" -ne 0 ]
  [[ "$output" == *"Ungated mutating command"* ]]
}

@test "passes when the mutating command is gated by DEEP=yes" {
  write_workflow good '## Step 1 — apply (DEEP=yes)

```bash
APPLY=yes
kubectl apply -f manifest.yaml
```

Write `./good-reports/x.md`.'
  run_validator
  [ "$status" -eq 0 ]
}

@test "ignores mutating commands mentioned only in prose" {
  write_workflow good '## Safety

Never run `helm upgrade` or `kubectl delete` from this workflow.

Write `./good-reports/x.md`.'
  run_validator
  [ "$status" -eq 0 ]
}

@test "fails on an odd number of code fences" {
  write_workflow good '## Step 1

```bash
echo hi
```

Write `./good-reports/x.md`.'
  printf '\n```bash\nunclosed\n' >> "$FIXTURE/.claude/commands/good.md"
  run_validator
  [ "$status" -ne 0 ]
  [[ "$output" == *"Odd number of code fences"* ]]
}

@test "fails when frontmatter is missing argument-hint" {
  cat > "$FIXTURE/.claude/commands/good.md" <<'EOF'
---
description: no hint
---

Write `./good-reports/x.md`.
EOF
  run_validator
  [ "$status" -ne 0 ]
  [[ "$output" == *"Missing 'argument-hint:'"* ]]
}
