## What changed

<!-- One or two sentences. Link the workflow/prompt/rule file this touches. -->

## PR checklist

See [CONTRIBUTING.md](../CONTRIBUTING.md) for the full rules. The essentials:

- [ ] `.claude/commands/<name>.md` added/updated with `description` + `argument-hint` frontmatter
- [ ] New workflow is listed in the *Available workflows* table in [README.md](../README.md)
- [ ] All commands are read-only, or any mutation is gated behind an explicit opt-in flag (`DEEP=yes`, `APPLY=yes`, …) and labelled in the step heading
- [ ] No secret values are printed (names, types, key lists, counts only)
- [ ] Optional tools (`jq`, `metrics-server`, `helm`, …) degrade gracefully when missing
- [ ] Workflow ends by writing a timestamped report to `./<name>-reports/`
- [ ] `./scripts/validate-repo.sh` passes
- [ ] `shellcheck scripts/*.sh` passes (if a script changed)
- [ ] `CHANGELOG.md` updated under `[Unreleased]`

## Testing

<!-- Which environment(s) did you run the workflow against? Note anything that needed a real cluster/account. -->
