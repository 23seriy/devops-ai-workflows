---
description: Diagnose a failing CI/CD pipeline build. Parses build logs from Jenkins, GitHub Actions, GitLab CI, or Bitbucket Pipelines to identify root cause, suggest fixes, and flag patterns. Read-only analysis.
---

# /ci-debug — CI/CD Pipeline Failure Diagnosis

Diagnose why a CI/CD build is failing. Feed in build logs (pasted, file, or URL) and get root-cause analysis, fix suggestions, and pattern detection. Works with **Jenkins, GitHub Actions, GitLab CI, Bitbucket Pipelines**, and other CI systems. **Read-only** — no builds are triggered or modified.

## Prerequisites

- Build log output from a failed pipeline. Any of:
  - Pasted text.
  - Log file on disk.
  - URL to a build console (if accessible).
- Optional: access to the repository source code for deeper analysis.
- Optional: access to the CI configuration file (Jenkinsfile, `.github/workflows/*.yml`, `.gitlab-ci.yml`, `bitbucket-pipelines.yml`).

## Inputs

- **LOG_SOURCE** *(required)* — one of:
  - `text` — user will paste log output.
  - `file:<path>` — path to a log file.
  - `url:<url>` — URL to build console output.
- **CI_SYSTEM** — `jenkins` / `github-actions` / `gitlab-ci` / `bitbucket` / `auto`. Default: `auto` (detect from log content).
- **REPO_PATH** — optional local path to the repository for source-level analysis.
- **REPORT_DIR** — Default: `./ci-debug-reports`.

---

## Step 1 — Ingest and identify CI system

Parse the log and detect the CI system from markers:

| CI System | Detection markers |
|---|---|
| Jenkins | `[Pipeline]`, `Started by`, `Running on`, `[INFO]`, `BUILD FAILURE`, `Finished: FAILURE` |
| GitHub Actions | `::error::`, `##[error]`, `Run `, `with:`, `GITHUB_`, `workflow` |
| GitLab CI | `$ `, `Running with gitlab-runner`, `Job succeeded`, `ERROR: Job failed` |
| Bitbucket | `+ `, `Pipelines`, `bitbucket-pipelines.yml`, `Build teardown` |

---

## Step 2 — Identify the failure point

Scan the log for:

### Error signatures (ordered by priority)

1. **Exit codes**: non-zero exit codes, `exit status`, `Process exited with code`.
2. **Explicit error markers**: `ERROR`, `FATAL`, `FAILURE`, `failed`, `error:`, `::error::`.
3. **Exception traces**: stack traces, `Traceback`, `Exception`, `panic:`, `at Object.`.
4. **Timeout markers**: `timeout`, `Timed out`, `deadline exceeded`, `ETIMEDOUT`.
5. **OOM markers**: `Killed`, `oom-kill`, `Out of memory`, `heap out of memory`, `ENOMEM`, `JavaScript heap`.
6. **Permission markers**: `Permission denied`, `403`, `401`, `EACCES`, `not authorized`.
7. **Network markers**: `ECONNREFUSED`, `ENOTFOUND`, `Connection refused`, `no such host`, `SSL`, `certificate`.
8. **Dependency markers**: `Could not resolve`, `404 Not Found`, `npm ERR!`, `pip install failed`, `go: module not found`.

### Stage identification

Determine which build stage failed:

| Stage | Common patterns |
|---|---|
| Checkout / clone | `git`, `clone`, `fetch`, `checkout`, `LFS` |
| Dependency install | `npm install`, `pip install`, `go mod`, `maven`, `gradle`, `bundle install`, `yarn` |
| Compile / build | `tsc`, `go build`, `javac`, `gcc`, `webpack`, `docker build` |
| Lint / format | `eslint`, `prettier`, `golint`, `flake8`, `rubocop` |
| Unit test | `jest`, `pytest`, `go test`, `mvn test`, `rspec`, `mocha` |
| Integration test | `cypress`, `playwright`, `selenium`, `testcontainers` |
| Static analysis | `sonarqube`, `sonar-scanner`, `snyk`, `npm audit`, `trivy` |
| Docker build | `docker build`, `Dockerfile`, `COPY`, `RUN`, `buildx` |
| Push / publish | `docker push`, `npm publish`, `aws ecr`, `twine upload` |
| Deploy | `terraform`, `kubectl`, `helm`, `aws deploy`, `cdk` |
| Post-build | `artifacts`, `coverage`, `notification` |

---

## Step 3 — Root cause classification

Classify the failure into one of these categories:

### Code errors
- **Compilation error** — syntax errors, type errors, missing imports.
- **Test failure** — assertion failures, test timeouts, flaky tests.
- **Lint failure** — style violations, formatting issues.

### Dependency errors
- **Missing dependency** — package not found, version conflict.
- **Registry unavailable** — npm registry, PyPI, Maven Central down or unreachable.
- **Version conflict** — incompatible dependency versions, lockfile mismatch.
- **Vulnerability gate** — Snyk, npm audit, or similar blocking on CVEs.

### Infrastructure errors
- **Docker build failure** — Dockerfile errors, base image issues, layer cache problems.
- **Resource exhaustion** — OOM, disk full, too many open files.
- **Timeout** — build exceeded time limit.
- **Network** — cannot reach external service, DNS failure, proxy issues.
- **Permissions** — missing credentials, expired tokens, insufficient IAM.

### Configuration errors
- **CI config syntax** — invalid YAML, missing required fields.
- **Environment variable** — missing or incorrect env vars.
- **Secret** — missing secret, expired credential.
- **Agent/runner** — no matching runner, label mismatch, offline agent.
- **Branch/trigger** — wrong branch filter, missing trigger condition.

### Flaky / intermittent
- **Flaky test** — test passes sometimes, fails sometimes.
- **Race condition** — timing-dependent failures.
- **External service** — third-party API intermittently unavailable.

---

## Step 4 — Jenkins-specific analysis (if CI_SYSTEM=jenkins)

If the CI system is Jenkins, perform additional checks:

```
Check for:
- Shared library errors (@Library load failures, method not found)
- Agent/node issues (offline, label mismatch, workspace conflicts)
- Credential binding failures (credentials ID not found, expired)
- Pipeline syntax errors (Groovy compilation, CPS transformation)
- Multibranch indexing issues
- Jenkinsfile path resolution
- Plugin compatibility (version conflicts, deprecated features)
- Workspace cleanup issues
- Stash/unstash failures across nodes
- Parallel stage failures and error propagation
```

For Jenkins pipelines using `itc-jenkins-shared-libraries` patterns:

```
Check for:
- BRANCH_CONFIG.BUILD_SEED branch resolution
- repoData lookup failures (projectName not found in repositories_v2.json)
- Build stage failures (Dockerfile not found, build script errors)
- ECR push failures (authentication, repository not found)
- Deployment flag issues (INFRA, APP deployment toggles)
- Diagnostics container build failures
- Static scan failures (SonarQube, Snyk, npm audit) vs snooze dates
```

---

## Step 5 — GitHub Actions-specific analysis (if CI_SYSTEM=github-actions)

```
Check for:
- Workflow syntax errors
- Action version pinning issues (using @main vs @v4)
- Secret/environment access (environment protection rules)
- Runner issues (self-hosted offline, label mismatch)
- Concurrency conflicts (job cancelled by newer run)
- Matrix strategy failures (partial matrix failure)
- Artifact upload/download issues
- GITHUB_TOKEN permission scope
- Reusable workflow input/output mismatches
```

---

## Step 6 — Pattern detection

Look for recurring patterns across the log:

- **Same error repeated** — indicates a loop or retry exhaustion.
- **Cascading failures** — one failure causing downstream failures.
- **Warning escalation** — warnings that eventually became the error.
- **Timing patterns** — failures always at the same duration (timeout).
- **Resource patterns** — memory/CPU climbing before crash.

---

## Step 7 — Suggest fixes

For each identified issue, provide:

1. **Root cause** — one sentence.
2. **Fix** — specific actionable steps.
3. **Prevention** — how to avoid this in the future.

Common fix patterns:

| Issue | Fix |
|---|---|
| npm install fails | Clear cache, delete `node_modules` + `package-lock.json`, re-install |
| Docker build OOM | Increase builder memory, reduce parallel builds, use multi-stage |
| Test timeout | Increase timeout, check for deadlocks, add test isolation |
| Flaky test | Add retry, fix race condition, mock external dependency |
| Credential expired | Rotate credential, check expiry, add monitoring |
| SonarQube gate fail | Check quality gate thresholds, review new issues, check snooze dates |
| Snyk vulnerability | Check `snoozeSnykUntil` date, evaluate CVE severity, update dependency |
| Git clone fail | Check SSH keys, check repo permissions, check network/proxy |

---

## Step 8 — Generate report

Compile findings into a timestamped Markdown report:

```
$REPORT_DIR/ci-debug-<ci-system>-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# CI/CD Pipeline Debug Report

| Field | Value |
|---|---|
| Generated | <timestamp> |
| CI system | <detected system> |
| Build | <build number/URL if available> |
| Failed stage | <stage name> |
| Root cause | <category> |

## Summary
<1-2 sentence description of what went wrong>

## Failure details
<exact error message and context>

## Root cause analysis
<detailed explanation>

## Fix
<specific steps to resolve>

## Prevention
<how to avoid this in the future>

## Full error context
<relevant log excerpt around the failure point>
```

---

## Safety rules

- This workflow is **entirely read-only**. It analyses log output only — it never triggers, retries, or modifies builds.
- Never print secrets, tokens, or credentials found in logs. Flag their presence but redact values.
- If the log contains sensitive information (API keys, passwords), note this as a security finding.
- The workflow does not access CI systems directly — it only analyses provided log content.
