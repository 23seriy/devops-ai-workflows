---
description: Guided first 15 minutes of a production incident. Establishes timeline, assesses blast radius, gathers evidence, and coordinates response. Read-only investigation commands.
---

# /incident-triage — First 15 Minutes of an Incident

Structured triage workflow for the critical first 15 minutes of a production incident. Guides you through timeline establishment, blast radius assessment, evidence gathering, and initial mitigation — with concrete commands for Kubernetes, AWS, and general infrastructure.

## Prerequisites

- Access to the affected environment (kubectl, AWS CLI, monitoring dashboards).
- This workflow uses **read-only** commands only. Mitigation actions are suggested but not executed automatically.

## Inputs

- **INCIDENT** *(required)* — brief description of the symptoms (e.g., "scores-api returning 500s", "high latency on checkout", "pods crashing in prod").
- **ENVIRONMENT** — `prod` / `staging` / `dev`. Default: `prod`.
- **AFFECTED_SERVICE** — service name if known.
- **REPORT_DIR** — Default: `./incident-triage-reports`.

---

## Minute 0–2: Declare and orient

### Establish the basics

Ask the user (or determine from context):

1. **What are the symptoms?** (errors, latency, downtime, data issue)
2. **When did it start?** (first alert, first customer report, when you noticed)
3. **Who reported it?** (alert, customer, internal)
4. **What environment?** (prod, staging, which region/cluster)
5. **What changed recently?** (deploys, config changes, infra changes, maintenance windows)

### Check recent deployments

```bash
# Kubernetes: recent rollouts
kubectl rollout history deploy -A 2>/dev/null | head -30

# Helm: recent releases
helm ls -A --sort-by updated 2>/dev/null | tail -20

# Git: recent deploys (if deploy tags exist)
git log --oneline --since="6 hours ago" --all 2>/dev/null | head -20

# AWS: recent CloudFormation events
aws cloudformation describe-stack-events --stack-name <stack> --query 'StackEvents[:10].[Timestamp,ResourceStatus,LogicalResourceId,ResourceStatusReason]' --output table 2>/dev/null
```

### Draft initial status

```
🔴 Incident declared: <title>
Time: <HH:MM UTC>
Severity: <SEV1/SEV2/SEV3>
Impact: <who/what is affected>
Status: Investigating
IC: <your name>
Next update in 15 minutes.
```

---

## Minute 2–5: Assess blast radius

### What's broken?

```bash
# Kubernetes: cluster health snapshot
kubectl get nodes -o wide
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded -o wide
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -30

# If service is known:
kubectl get pods -n <ns> -l app=<service> -o wide
kubectl describe deploy -n <ns> <service> | tail -30

# AWS: service health
aws health describe-events --filter eventStatusCodes=open --query 'events[].{Service:service,Status:statusCode,Description:eventTypeCode}' --output table 2>/dev/null || true
```

### Who's affected?

```bash
# Check error rates (if Prometheus/metrics available)
# Substitute your actual metric names
curl -s "http://prometheus:9090/api/v1/query?query=sum(rate(http_requests_total{status=~\"5..\"}[5m]))" 2>/dev/null | jq '.data.result'

# Check ALB/NLB metrics (AWS)
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB --metric-name HTTPCode_Target_5XX_Count \
  --dimensions Name=LoadBalancer,Value=<lb-name> \
  --start-time $(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 --statistics Sum 2>/dev/null
```

### Quantify impact

| Question | How to determine |
|---|---|
| Error rate | Prometheus, CloudWatch, APM |
| Affected users (%) | Compare error rate to total request rate |
| Which regions/AZs | Check per-region metrics, node distribution |
| Data loss risk | Check database health, replication status |
| Revenue impact | Error rate × average revenue per request |

---

## Minute 5–10: Gather evidence

### Logs from affected service

```bash
# Kubernetes: recent logs
kubectl logs -n <ns> -l app=<service> --all-containers --tail=200 --timestamps --since=30m 2>/dev/null | grep -iE 'error|fatal|panic|exception|timeout|refused' | tail -50

# Previous container logs (if restarting)
for pod in $(kubectl get pods -n <ns> -l app=<service> -o name); do
  echo "=== $pod previous ==="
  kubectl logs -n <ns> $pod --previous --tail=100 --timestamps 2>/dev/null | tail -20
done

# AWS Lambda (if applicable)
aws logs filter-log-events \
  --log-group-name "/aws/lambda/<function-name>" \
  --start-time $(($(date +%s) - 1800))000 \
  --filter-pattern "ERROR" \
  --limit 30 2>/dev/null
```

### Infrastructure state

```bash
# Kubernetes: resource pressure
kubectl top nodes 2>/dev/null
kubectl top pods -n <ns> --sort-by=memory 2>/dev/null | head -20

# Kubernetes: HPA status
kubectl get hpa -n <ns> -o wide 2>/dev/null

# AWS: EC2/RDS health
aws ec2 describe-instance-status --filters Name=instance-status.status,Values=impaired --query 'InstanceStatuses[].{Id:InstanceId,Status:InstanceStatus.Status}' --output table 2>/dev/null
aws rds describe-events --duration 30 --query 'Events[].{Source:SourceIdentifier,Type:EventCategories,Message:Message,Date:Date}' --output table 2>/dev/null
```

### Network and dependencies

```bash
# DNS resolution (from inside the cluster)
kubectl run dns-test --rm -it --restart=Never --image=busybox:1.36 --command -- nslookup <service>.<ns>.svc.cluster.local 2>/dev/null

# Endpoint health
kubectl get endpoints -n <ns> <service> -o wide

# External dependency check
curl -sSm 5 -o /dev/null -w "status=%{http_code} time=%{time_total}s\n" https://<dependency-endpoint>/health 2>/dev/null || echo "UNREACHABLE"
```

---

## Minute 10–12: Identify and mitigate

### Common root causes and quick mitigations

| Symptom | Likely cause | Quick mitigation |
|---|---|---|
| Pods in CrashLoopBackOff after deploy | Bad code / config in new version | `kubectl rollout undo deploy/<name> -n <ns>` |
| All pods OOMKilled | Memory leak or insufficient limits | Scale up or increase memory limits |
| 503s from LB | No healthy targets | Check pod readiness, fix probes |
| Connection refused to dependency | Dependency is down | Check dependency status, failover |
| Slow queries / high DB CPU | Bad query or missing index | Identify and kill long-running queries |
| Certificate expired | TLS cert not renewed | Emergency cert renewal |
| DNS resolution failing | CoreDNS unhealthy | Restart CoreDNS pods |

### Suggest (don't execute) mitigations

The agent should present mitigation options but **never execute them automatically**:

```
Suggested mitigations (choose one — confirm before running):

Option A: Rollback to previous version
  kubectl rollout undo deploy/<service> -n <ns>

Option B: Scale up to handle load
  kubectl scale deploy/<service> -n <ns> --replicas=<N>

Option C: Restart pods (if stuck state)
  kubectl rollout restart deploy/<service> -n <ns>

Option D: Disable traffic to the service
  kubectl scale deploy/<service> -n <ns> --replicas=0
```

---

## Minute 12–15: Communicate and plan

### Status update

```
🟡 Update: <title>
Time: <HH:MM UTC>
Status: Identified / Mitigating
What we know:
  - Root cause: <description>
  - Impact: <X% of requests affected / Y users impacted>
  - Started: <HH:MM UTC>
Current action: <what's being done>
Next update in 15 minutes.
```

### Evidence log

Record everything gathered so far:

```markdown
## Evidence collected at <timestamp>

### Timeline
- HH:MM — First symptom / alert
- HH:MM — Investigation started
- HH:MM — Root cause identified: <description>
- HH:MM — Mitigation applied: <action>

### Key findings
- <finding 1>
- <finding 2>

### Commands run
- <command 1> → <result summary>
- <command 2> → <result summary>
```

---

## Step — Generate triage report

Compile all findings into a timestamped report:

```
$REPORT_DIR/incident-triage-<service>-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# Incident Triage Report

| Field | Value |
|---|---|
| Generated | <timestamp> |
| Incident | <description> |
| Environment | <env> |
| Service | <service> |
| Severity | SEV1/SEV2/SEV3 |
| Duration (so far) | <minutes> |

## Blast radius
<who/what is affected, error rates, user impact>

## Timeline
<chronological events>

## Root cause (if identified)
<description>

## Evidence
<logs, metrics, command outputs>

## Mitigation applied / recommended
<what was done or what should be done>

## Next steps
<follow-up investigation, post-mortem scheduling>
```

---

## Safety rules

- All investigation commands are **read-only**.
- **Mitigation commands are suggested but never executed automatically.** The user must explicitly confirm any write/mutation operation.
- Never print secret values from logs or configs.
- The DNS test pod (`dns-test`) uses `--rm` and auto-deletes.
- If kubectl/AWS commands fail due to permissions, record the failure and continue.
- Always confirm the target environment before suggesting any mitigation.
