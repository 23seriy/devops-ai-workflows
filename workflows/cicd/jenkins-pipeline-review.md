---
description: Review a Jenkinsfile or Groovy shared-library pipeline for anti-patterns, security risks, reliability gaps, and best practices. Read-only static analysis of pipeline code.
---

# /jenkins-pipeline-review — Jenkinsfile & Pipeline Code Review

Static analysis of Jenkins pipeline code — Jenkinsfiles (declarative or scripted), shared-library `vars/*.groovy` files, and pipeline-adjacent configs (`repositories_v2.json`, build scripts). Flags security risks, reliability issues, anti-patterns, and missed best practices **before** they cause build failures.

> This is a **code review** workflow. For diagnosing a **failing build from logs**, use `/ci-debug` instead.

## Prerequisites

- One or more Jenkinsfile(s) or Groovy pipeline files.
- Optional: shared-library source (`vars/`, `src/`, `resources/`).
- Optional: `repositories_v2.json` or similar build config for cross-referencing.
- No Jenkins access required — works purely on source files.

## Inputs

- **PIPELINE_PATH** *(required)* — path to the Jenkinsfile(s) or shared-library root. Examples:
  - `./Jenkinsfile`
  - `./vars/servicePipeline.groovy`
  - `./` (scans for all `*.groovy`, `Jenkinsfile*` files)
- **PIPELINE_TYPE** — `declarative` / `scripted` / `shared-library` / `auto`. Default: `auto`.
- **BUILD_CONFIG_PATH** — optional path to `repositories_v2.json` or similar config.
- **REPORT_DIR** — Default: `./jenkins-pipeline-review-reports`.

---

## Step 1 — Discover and read pipeline files

// turbo

```bash
find ${PIPELINE_PATH:-.} \( -name 'Jenkinsfile*' -o -name '*.groovy' \) \
  -not -path '*/node_modules/*' -not -path '*/.git/*' | head -30

# Check for shared library structure
ls -la ${PIPELINE_PATH:-.}/vars/ 2>/dev/null || echo "No vars/ directory"
ls -la ${PIPELINE_PATH:-.}/src/ 2>/dev/null || echo "No src/ directory"
ls -la ${PIPELINE_PATH:-.}/resources/ 2>/dev/null || echo "No resources/ directory"
```

Identify:
- Pipeline type (declarative vs scripted vs shared library).
- File count and structure.
- Entry points vs helper classes.

---

## Step 2 — Security analysis

### Credential handling

Flag these patterns:

| Pattern | Severity | Issue |
|---|---|---|
| Hardcoded passwords/tokens in source | 🔴 | `password = "..."`, `token = "..."`, `SECRET_KEY = "..."` |
| `echo` / `println` of credential variables | 🔴 | Leaks secrets to console log |
| Credentials used outside `withCredentials` block | 🔴 | Secret may persist in env or workspace |
| `sh "curl -u ${user}:${pass}"` (string interpolation) | 🔴 | Groovy interpolates before masking; secret appears in `set -x` output |
| `sh "... $PASSWORD ..."` (double-quoted shell) | 🔴 | Use single quotes or `sh(script: '...', returnStdout: true)` |
| `credentials()` helper in `environment` block without masking check | 🟡 | Ensure `SECRET` type, not `STRING` |
| Credential IDs that look like secrets themselves | 🟡 | ID should be descriptive, not the actual value |

**Best practice:** Always use `withCredentials([...])` blocks. For shell steps, use single-quoted strings or heredocs to prevent Groovy interpolation of secret variables.

### Script approval and sandbox escape

| Pattern | Severity | Issue |
|---|---|---|
| `@NonCPS` methods accessing Jenkins internals | 🟡 | May bypass sandbox; review what it accesses |
| `@Grab` annotations | 🔴 | Downloads arbitrary JARs at runtime |
| `evaluate()` / `Eval.me()` | 🔴 | Arbitrary code execution |
| `new File(...)` / `new URL(...)` in sandbox context | 🟡 | May fail in sandbox or require script approval |
| `Jenkins.instance` / `hudson.*` API access | 🟡 | Direct Jenkins API — needs admin approval, fragile |
| `load` step loading external Groovy scripts | 🟡 | Verify the loaded script is trusted |

### Agent and workspace security

| Pattern | Severity | Issue |
|---|---|---|
| `agent any` without node restriction | 🟡 | Build runs on any node — may expose secrets to untrusted agents |
| No workspace cleanup (`cleanWs()` or `deleteDir()`) | 🟡 | Secrets/artifacts may persist between builds |
| `stash`/`unstash` of sensitive files across nodes | 🟡 | Stashed content stored on controller |

---

## Step 3 — Reliability and error handling

### Missing error handling

| Pattern | Severity | Issue |
|---|---|---|
| No `post { failure { ... } }` block | 🟡 | No notification or cleanup on failure |
| No `post { always { ... } }` block | 🟡 | Resources not cleaned up (containers, temp files) |
| `try/catch` that swallows exceptions silently | 🔴 | `catch (e) { }` — hides failures |
| `catchError(buildResult: 'SUCCESS')` | 🟡 | Stage failure silently ignored; build still green |
| `sh` step without error checking | 🟡 | Use `set -e` or check `returnStatus` |
| No `timeout` on stages or the entire pipeline | 🟡 | Builds can hang forever |
| No `retry` on flaky operations (git clone, docker push, artifact download) | 🔵 | Network operations should have retry logic |

### Pipeline durability

| Pattern | Severity | Issue |
|---|---|---|
| Very long pipeline (>500 lines in one file) | 🟡 | Hard to maintain; extract into shared library |
| Nested `parallel` blocks | 🟡 | Can cause serialization issues in CPS |
| Heavy computation in CPS-transformed code | 🟡 | Move to `@NonCPS` methods or external scripts |
| `sleep` in pipeline body (not in `sh`) | 🟡 | Blocks an executor; use `waitUntil` or external polling |
| No `durability` hint for critical pipelines | 🔵 | Consider `properties([durabilityHint('MAX_SURVIVABILITY')])` |

---

## Step 4 — Pipeline structure and best practices

### Declarative pipeline

| Check | Expected |
|---|---|
| `agent` block present | ✅ at top level or per-stage |
| `stages` block with named stages | ✅ meaningful names, not "Stage 1" |
| `environment` block for shared env vars | ✅ not scattered `withEnv` blocks |
| `parameters` block for user inputs | ✅ if pipeline accepts inputs |
| `options` block | ✅ should include `timeout`, `timestamps`, `buildDiscarder` |
| `post` block with `always`, `failure`, `success` | ✅ for cleanup and notification |
| `tools` block for JDK/Maven/Node version | ✅ or explicit version management |
| `when` conditions on stages | ✅ for branch-specific logic |

### Shared library patterns

| Check | Expected |
|---|---|
| `call()` method in `vars/*.groovy` | ✅ entry point for each pipeline |
| `@Library('name') _` import with version | ✅ pin to a tag/branch, not `@Library('name')` |
| Clean separation: vars/ (entry) → src/ (logic) | ✅ vars should be thin wrappers |
| `BRANCH_CONFIG` or equivalent for branch mapping | ✅ configurable, not hardcoded |
| Error propagation from shared lib to calling pipeline | ✅ exceptions should bubble up |

### Resource management

| Pattern | Severity | Issue |
|---|---|---|
| Docker containers started but not cleaned up | 🟡 | Use `docker.image().inside { }` or explicit cleanup |
| `withDockerContainer` without resource limits | 🔵 | Consider `--memory`, `--cpus` |
| Workspace accumulation (no `cleanWs()`) | 🟡 | Disk fills up over time |
| Large artifacts stashed/archived unnecessarily | 🔵 | Only archive what's needed |
| `checkout scm` in multiple stages | 🟡 | Checkout once, stash if needed across nodes |

---

## Step 5 — Build configuration analysis

If `BUILD_CONFIG_PATH` is provided (e.g., `repositories_v2.json`), cross-reference:

### `repositories_v2.json` checks

| Check | What to flag |
|---|---|
| `kind` matches pipeline type | `nodejs-service` → `servicePipeline.groovy`, `nodejs-lambda` → `lambdaPipeline.groovy`, etc. |
| `runtime_version` is current | Flag EOL versions: Node 14, 16, 18; Python 3.7, 3.8; Go <1.21 |
| `staticscans.sonarqube` / `snyk` enabled | Flag repos with scans disabled without a snooze date |
| Snooze dates in the past | `snoozeSonarqubeUntil`, `snoozeSnykUntil`, `snoozeNpmAuditUntil` — if expired, scan should be enforced |
| `exec_diagnostics` consistency | If `true`, verify `Dockerfile_diagnostics` and diagnostics scripts exist |
| `edge` lambda config | If `true`, verify `Dockerfile_edge_lambda` exists and `extensions` is not set (mutually exclusive) |
| `testsToRun` non-empty for services | Services should have integration tests configured |
| `dependsOn` for services | Should list actual dependencies, not empty array for services that clearly depend on others |

### BRANCH_CONFIG checks

| Check | What to flag |
|---|---|
| `BUILD_SEED` points to a real branch | `master` for production, feature branch for testing |
| `BUILD_TOOLS` points to a real branch | Same |
| Mismatch between pipeline and build-seed | Pipeline expects files that don't exist in the referenced build-seed branch |

---

## Step 6 — Performance and optimization

| Pattern | Severity | Suggestion |
|---|---|---|
| Sequential stages that could run in parallel | 🔵 | Lint + unit test + security scan can often parallelize |
| `git clone` of entire repo history | 🔵 | Use `checkout([$class: 'GitSCM', extensions: [[$class: 'CloneOption', depth: 1, shallow: true]]])` |
| Docker build without layer caching | 🔵 | Use `--cache-from` or BuildKit cache mounts |
| `npm install` instead of `npm ci` | 🟡 | `ci` is faster and deterministic |
| Full test suite on PR builds | 🔵 | Consider running only affected tests on PRs |
| Archiving large artifacts on every build | 🔵 | Archive only on master/release branches |
| No build discarder | 🟡 | `buildDiscarder(logRotator(numToKeepStr: '20'))` to prevent controller disk bloat |

---

## Step 7 — Jenkins-specific gotchas

### CPS (Continuation Passing Style) issues

Jenkins pipelines are CPS-transformed, which introduces subtle bugs:

| Issue | Example | Fix |
|---|---|---|
| Non-serializable variables in pipeline body | `def matcher = (text =~ /pattern/)` | Move to `@NonCPS` method or use `==~` |
| Closure serialization | `list.collect { ... }` in pipeline context | Use `@NonCPS` or `for` loop |
| `java.io.NotSerializableException` | Any non-serializable object crossing a CPS boundary | Extract to `@NonCPS` or convert to String/Map |
| `RejectedAccessException` | Calling methods not whitelisted in sandbox | Use approved alternatives or request script approval |

### Multibranch and organization folder

| Check | What to flag |
|---|---|
| Jenkinsfile path hardcoded vs convention | Should match Jenkins job config (usually `Jenkinsfile` at root) |
| Branch indexing triggers too broad | Builds triggered on irrelevant branches |
| No Jenkinsfile in default branch | Multibranch won't discover the project |
| `properties([])` overriding org-level settings | Can break inherited build discarders, triggers |

### Plugin compatibility

| Check | What to flag |
|---|---|
| Use of deprecated pipeline steps | `dockerFingerprintFrom`, old `build` syntax |
| Pipeline Utility Steps assumed available | `readJSON`, `readYaml`, `writeJSON` need Pipeline Utility Steps plugin |
| Git plugin version requirements | `checkout scm` behavior changes across versions |
| Blue Ocean vs classic pipeline visualization | Some constructs render differently |

---

## Step 8 — Generate report

Compile findings into a timestamped Markdown report:

```
$REPORT_DIR/jenkins-pipeline-review-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# Jenkins Pipeline Review Report

| Field | Value |
|---|---|
| Generated | <timestamp> |
| Files reviewed | <list> |
| Pipeline type | <declarative / scripted / shared-library> |
| Risk level | 🔴 / 🟡 / 🟢 |

## Summary
<1-2 sentence overall assessment>

## Findings

### 🔴 Critical
<credential leaks, code injection, sandbox escapes>

### 🟡 Warning
<missing error handling, no timeout, stale snooze dates, reliability gaps>

### 🔵 Info
<optimization suggestions, style improvements>

## File-by-file breakdown
<per-file analysis>

## Build config findings
<repositories_v2.json cross-reference if provided>

## Recommended changes
<prioritized list with code examples>
```

---

## Safety rules

- This workflow is **entirely read-only**. It analyses pipeline source code — it never triggers, modifies, or executes any Jenkins build.
- Never print secret values found in pipeline code. Flag their presence but redact values.
- If hardcoded credentials are found, this is a 🔴 critical finding — recommend immediate rotation.
- The workflow does not access Jenkins APIs, controllers, or agents.
