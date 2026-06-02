---
description: Review a Helm chart for security, reliability, and best practices before deployment. Checks templates, values, resource specs, and RBAC. Read-only static analysis.
---

# /helm-chart-review — Helm Chart Best Practices Review

Static analysis of a Helm chart **before deployment**. Checks templates, `values.yaml`, resource specifications, security context, RBAC, and packaging. Flags missing best practices that cause production incidents.

> This reviews chart **source code**. For diagnosing a **live broken Helm release**, use `/helm-release-debug` instead.

## Prerequisites

- Helm chart source directory or `.tgz` archive.
- Optional: `helm` CLI (for `helm template`, `helm lint`).
- Optional: `kubectl` (for dry-run validation against a cluster).
- No cluster access required for basic review.

## Inputs

- **CHART_PATH** *(required)* — path to the chart directory or `.tgz` file.
- **VALUES_FILE** — optional custom values file to review alongside defaults.
- **REPORT_DIR** — Default: `./helm-chart-review-reports`.

---

## Step 1 — Chart structure and metadata

// turbo

```bash
# Validate chart structure
ls -la $CHART_PATH/
cat $CHART_PATH/Chart.yaml
cat $CHART_PATH/values.yaml | head -100

# Helm lint
helm lint $CHART_PATH 2>&1
helm lint $CHART_PATH --strict 2>&1

# Template render (catch errors before deploy)
helm template test-release $CHART_PATH 2>&1 | head -200
```

Check:

- `Chart.yaml` has `version`, `appVersion`, `description`, `maintainers`.
- `apiVersion: v2` (Helm 3). Flag `v1` charts (Helm 2 legacy).
- Dependencies declared in `Chart.yaml` or `requirements.yaml` (legacy).
- `helm lint --strict` passes with no warnings.
- `helm template` renders without errors.

---

## Step 2 — Resource specifications

For every Deployment, StatefulSet, DaemonSet, Job in the templates, check:

### Resource requests and limits

```yaml
# ✅ Good
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

# ❌ Bad — no resources at all
# ❌ Bad — limits without requests
# ⚠️ Caution — requests == limits (Guaranteed QoS, may be wasteful)
```

Flag:
- Containers with no `resources.requests` → scheduling problems, noisy neighbors.
- Containers with no `resources.limits` → can consume unbounded resources.
- Memory limits much larger than requests → overcommitment risk.

### Probes

```yaml
# ✅ Should have all three
readinessProbe: ...   # When to send traffic
livenessProbe: ...    # When to restart
startupProbe: ...     # Grace period for slow-starting apps
```

Flag:
- No `readinessProbe` → traffic sent before app is ready.
- No `livenessProbe` → stuck pods never restart.
- `livenessProbe` same as `readinessProbe` → may cause restart loops under load.
- `initialDelaySeconds` too low → premature restarts during startup.
- No `startupProbe` on apps known to have slow startup.

---

## Step 3 — Security

### Pod security context

```yaml
# ✅ Good
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  fsGroup: 1000
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
```

Flag:
- No `securityContext` at all → runs as root.
- `privileged: true` → full host access.
- `allowPrivilegeEscalation: true` or missing → container can escalate.
- `capabilities` not dropped → unnecessary kernel capabilities.
- `hostNetwork: true`, `hostPID: true`, `hostIPC: true` → breaks isolation.
- `readOnlyRootFilesystem: false` or missing → writable root fs.

### RBAC

If the chart creates `ClusterRole`, `ClusterRoleBinding`, `Role`, `RoleBinding`:

- Flag `ClusterRole` with `*` verbs or `*` resources.
- Flag `ClusterRoleBinding` to `default` ServiceAccount.
- Flag any binding to `cluster-admin`.
- Prefer `Role`+`RoleBinding` (namespace-scoped) over `ClusterRole`+`ClusterRoleBinding`.

### Secrets

- Flag `Secret` resources with hardcoded values in templates.
- Prefer `existingSecret` pattern (reference external secrets).
- Flag secrets in `ConfigMap` (should be `Secret`).
- Check if `values.yaml` has password/token fields with default values.

---

## Step 4 — High availability and resilience

### Replicas and PDB

Flag:
- `replicas: 1` for production workloads → single point of failure.
- No `PodDisruptionBudget` for multi-replica Deployments/StatefulSets.
- PDB with `maxUnavailable: 0` → blocks all voluntary disruptions (node drain).
- PDB with `minAvailable` equal to `replicas` → same problem.

### Anti-affinity

```yaml
# ✅ Good — spread across nodes
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
              - key: app
                operator: In
                values: ["myapp"]
          topologyKey: kubernetes.io/hostname
```

Flag:
- Multi-replica workloads with no anti-affinity → all pods on one node.
- `requiredDuringScheduling` anti-affinity on small clusters → pods may not schedule.

### Update strategy

- Deployments: `RollingUpdate` with `maxSurge` and `maxUnavailable` configured.
- StatefulSets: `RollingUpdate` with `partition` for staged rollouts.
- DaemonSets: `RollingUpdate` with `maxUnavailable`.
- Flag `Recreate` strategy on production Deployments (causes downtime).

---

## Step 5 — Networking

- **Service type** — flag `LoadBalancer` without annotation for internal LB (may create public LB).
- **Ingress** — check for TLS configuration, valid hosts, path types.
- **NetworkPolicy** — flag charts with no NetworkPolicy (all traffic allowed).
- **Service ports** — named ports match container ports.
- **Service selectors** — match pod labels.

---

## Step 6 — Storage

- **PVC templates** in StatefulSets — check `storageClassName`, access modes, size.
- **EmptyDir** with no `sizeLimit` → can fill node disk.
- **HostPath** volumes → breaks portability, security risk.
- **Volume mounts** — check for unnecessary write access.

---

## Step 7 — Values and configurability

Review `values.yaml`:

- **Image tag** — flag `latest` or missing tag. Should default to `appVersion` from `Chart.yaml` or a pinned tag.
- **Image pull policy** — should be `IfNotPresent` for tagged images, `Always` only for `latest`.
- **Configurable resource limits** — requests/limits should be in values, not hardcoded in templates.
- **Environment-specific values** — check if the chart supports different envs via values overlays.
- **Sensitive defaults** — flag default passwords, tokens, or keys in `values.yaml`.

---

## Step 8 — Generate report

Compile findings into a timestamped Markdown report:

```
$REPORT_DIR/helm-chart-review-<chart-name>-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# Helm Chart Review Report

| Field | Value |
|---|---|
| Generated | <timestamp> |
| Chart | <name> v<version> |
| App version | <appVersion> |
| Templates | <count> |
| Risk level | 🔴 / 🟡 / 🟢 |

## Summary
<overall assessment>

## Findings
### 🔴 Critical
### 🟡 Warning
### 🔵 Info

## Template-by-template breakdown
<per-template analysis>

## Recommended changes
<prioritized with YAML examples>
```

---

## Safety rules

- This workflow is **entirely read-only**. No charts are installed, upgraded, or deleted.
- `helm template` renders locally — it does not contact a cluster.
- `helm lint` is a local static check.
- Never print secret values from `values.yaml`. Flag their presence but redact.
