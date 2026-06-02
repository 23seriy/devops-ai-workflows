---
description: Review a Dockerfile for security, size, caching, and best practices. Flags CVE-prone base images, leaked secrets, missing health checks, and optimization opportunities. Read-only analysis.
---

# /dockerfile-review — Dockerfile Security & Optimization Review

Analyse a Dockerfile (or set of Dockerfiles) for security vulnerabilities, image size optimization, layer caching, and best practices. **Read-only** — no images are built or pushed.

## Prerequisites

- One or more Dockerfiles to review.
- Optional: access to the repository for context (`.dockerignore`, `package.json`, `go.mod`, etc.).
- Optional: `docker` CLI for `docker history` / `docker inspect` on existing images.
- Optional: `trivy`, `grype`, or `snyk` for CVE scanning of base images.

## Inputs

- **DOCKERFILE_PATH** *(required)* — path to the Dockerfile(s). Can be:
  - A single file: `./Dockerfile`
  - A glob: `./Dockerfiles/Dockerfile_*`
  - A directory: `.` (will find all `Dockerfile*` files).
- **CONTEXT_DIR** — build context directory for `.dockerignore` analysis. Default: parent of Dockerfile.
- **REPORT_DIR** — Default: `./dockerfile-review-reports`.

---

## Step 1 — Discover and read Dockerfiles

// turbo

```bash
# Find all Dockerfiles
find ${CONTEXT_DIR:-.} -name 'Dockerfile*' -not -path '*/node_modules/*' -not -path '*/.git/*' | head -20

# Read .dockerignore if present
cat ${CONTEXT_DIR:-.}/.dockerignore 2>/dev/null || echo "No .dockerignore found"
```

---

## Step 2 — Base image analysis

For each `FROM` instruction, check:

### Base image security

- **`FROM latest`** — ❌ never use `latest` in production. Pin to a specific tag or digest.
- **`FROM <image>` without registry** — ⚠️ implicit Docker Hub, consider using explicit registry.
- **`FROM <image>:<tag>` without digest** — ⚠️ tags are mutable, consider pinning `@sha256:...` for reproducibility.
- **Distro-based images** (`ubuntu`, `debian`, `centos`, `amazonlinux`) — ⚠️ larger attack surface. Consider `alpine`, `distroless`, or `scratch`.
- **Deprecated / EOL base images** — ❌ flag `centos:7`, `centos:8`, `node:14`, `python:3.7`, `ubuntu:18.04`, etc.
- **Multi-stage builds** — ✅ check if final stage uses a minimal image. Flag if build tools leak into runtime image.

### Size optimization

- **Use slim/alpine variants** where possible (`node:22-slim`, `python:3.12-slim`, `golang:1.23-alpine`).
- **Distroless** for Go/Java — smallest possible runtime image.
- **Scratch** for statically compiled binaries.

---

## Step 3 — Layer and caching analysis

Check instruction ordering for optimal caching:

### Optimal order (most stable → least stable)

```dockerfile
FROM base
# 1. System dependencies (rarely change)
RUN apt-get update && apt-get install -y ...
# 2. Language dependencies (change with lockfile)
COPY package.json package-lock.json ./
RUN npm ci
# 3. Application code (changes frequently)
COPY . .
# 4. Build
RUN npm run build
```

### Anti-patterns to flag

- **`COPY . .` before dependency install** — ❌ busts cache on every code change.
- **Separate `RUN apt-get update` and `RUN apt-get install`** — ❌ cache can serve stale package index.
- **Too many `RUN` layers** — ⚠️ chain with `&&` to reduce layers.
- **`RUN apt-get update && apt-get install` without `rm -rf /var/lib/apt/lists/*`** — ⚠️ bloats image.
- **`npm install` instead of `npm ci`** — ⚠️ `ci` is faster and deterministic in CI.
- **Not copying lockfile separately** — ❌ should copy `package-lock.json` / `go.sum` / `requirements.txt` before full `COPY`.

---

## Step 4 — Security checks

### Secrets and credentials

- **`ARG`/`ENV` with secrets** — ❌ flag any `ARG PASSWORD`, `ENV API_KEY`, `ENV AWS_SECRET_ACCESS_KEY`, etc.
- **`COPY` of secret files** — ❌ flag `.env`, `*.pem`, `*.key`, `credentials`, `.aws/`, `.ssh/`.
- **Secrets in `RUN` commands** — ❌ flag `curl -H "Authorization: Bearer ..."`, `echo $PASSWORD`.
- **Multi-stage secret leakage** — check that build-stage secrets don't persist in runtime stage.
- **BuildKit secrets** — ✅ suggest `--mount=type=secret` for build-time secrets.

### User and permissions

- **Running as root** — ⚠️ flag if no `USER` instruction (defaults to root).
- **`USER root` in final stage** — ❌ should use non-root user.
- **Suggest**: `RUN addgroup -S app && adduser -S app -G app` then `USER app`.
- **`chmod 777`** — ❌ overly permissive.
- **`COPY --chown`** — ✅ good practice.

### Package management

- **`apt-get install` without version pinning** — ⚠️ non-reproducible builds.
- **`pip install` without `--no-cache-dir`** — ⚠️ wastes space.
- **`npm install --unsafe-perm`** — ⚠️ security risk.
- **Missing `apt-get clean`** — ⚠️ leaves package cache in layer.

### Network and ports

- **`EXPOSE` on unexpected ports** — ⚠️ review if all exposed ports are intended.
- **`curl` / `wget` piped to `sh`** — ❌ risky installation method.

---

## Step 5 — Best practices check

### Health and metadata

- **Missing `HEALTHCHECK`** — ⚠️ recommended for production images.
- **Missing `LABEL`** — ⚠️ add `maintainer`, `version`, `description` labels.
- **`ENTRYPOINT` vs `CMD`** — verify correct usage. `ENTRYPOINT` for the executable, `CMD` for default args.
- **Shell form vs exec form** — prefer exec form `["cmd", "arg"]` over shell form `cmd arg` (proper signal handling).

### .dockerignore

- **Missing `.dockerignore`** — ❌ build context will include everything.
- **Should exclude**: `.git/`, `node_modules/`, `*.md`, `.env`, `*.log`, `tests/`, `__pycache__/`, `.terraform/`, `*.tfstate`.
- **Should NOT exclude** (if needed in build): `package-lock.json`, `go.sum`, `requirements.txt`, test files if running tests in Docker.

### Multi-stage specific

- **Build tools in runtime stage** — ❌ check for `gcc`, `make`, `python-dev`, `build-essential` in final stage.
- **`COPY --from=builder`** — ✅ verify only necessary artifacts are copied.
- **Named stages** — ✅ use `FROM base AS builder` for clarity.

---

## Step 6 — Language-specific checks

### Node.js

- `npm ci` preferred over `npm install`.
- `NODE_ENV=production` should be set for production builds.
- `node_modules` should not be copied from host (should be in `.dockerignore`).
- Use `dumb-init` or `tini` for proper signal handling if PID 1.
- Copy `package.json` + `package-lock.json` before `COPY . .`.

### Go

- Use multi-stage build: build in `golang:X`, run in `distroless` or `scratch`.
- Set `CGO_ENABLED=0` for static binaries if using `scratch`.
- Copy `go.mod` + `go.sum` first, then `go mod download`, then `COPY . .`.
- Run `go test` in build stage before final binary copy.

### Python

- Use `--no-cache-dir` with `pip install`.
- Use `pip install --no-deps` with locked requirements for reproducibility.
- Consider `poetry export` or `pip-compile` for deterministic installs.
- Virtual envs in Docker are optional but can simplify multi-stage copies.

### Java

- Use multi-stage: build with `maven`/`gradle`, run with `eclipse-temurin:X-jre`.
- Copy `pom.xml` / `build.gradle` first for dependency caching.
- Use `jlink` for custom minimal JRE.

---

## Step 7 — Generate report

Compile findings into a timestamped Markdown report:

```
$REPORT_DIR/dockerfile-review-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# Dockerfile Review Report

| Field | Value |
|---|---|
| Generated | <timestamp> |
| Files reviewed | <list> |
| Base images | <list> |
| Risk level | 🔴 / 🟡 / 🟢 |

## Summary
<1-2 sentence overall assessment>

## Findings

### 🔴 Critical
<secrets, root user, CVE-prone bases, leaked credentials>

### 🟡 Warning
<cache ordering, missing .dockerignore, no healthcheck, size>

### 🔵 Info
<suggestions, minor optimizations>

## File-by-file breakdown
<per-Dockerfile analysis>

## Optimized Dockerfile (suggested)
<rewritten Dockerfile with all fixes applied>

## Estimated size impact
<before/after estimates if possible>
```

---

## Safety rules

- This workflow is **entirely read-only**. No images are built, pushed, or modified.
- Never print secret values found in Dockerfiles. Flag their presence but redact values.
- If the Dockerfile contains hardcoded credentials, tokens, or keys, flag this as a 🔴 critical finding.
- The workflow does not execute any `RUN` commands from the Dockerfile.
- Suggested fixes are provided in the report for the user to evaluate and apply manually.
