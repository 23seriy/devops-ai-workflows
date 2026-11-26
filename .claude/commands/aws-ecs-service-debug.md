---
description: Read-only ECS/Fargate service diagnostics — task rollout failures, stopped-task reasons, deployment circuit breaker, target group health, task IAM roles, and logs. Generates a markdown report.
argument-hint: "CLUSTER=... SERVICE=... [PROFILE=...] [REGION=...] [LOG_MINUTES=60] [REPORT_DIR=...]"
---

# /aws-ecs-service-debug — ECS / Fargate Service Diagnostics

Read-only diagnostics for a single ECS service on EC2 or Fargate. Traces why tasks fail to start or stay healthy: service events, deployment state and circuit breaker, recent stopped tasks and their reasons, load-balancer target health, task definition essentials, execution/task IAM roles, and container logs. Produces a severity-ranked Markdown report.

Uses `get` / `list` / `describe` / `logs` calls only.

## Prerequisites

- `aws` CLI v2 configured (`aws sts get-caller-identity` succeeds).
- IAM permissions: `ecs:Describe*`, `ecs:List*`, `elasticloadbalancing:DescribeTargetHealth`, `elasticloadbalancing:DescribeTargetGroups`, `logs:FilterLogEvents`, `logs:DescribeLogGroups`, `iam:GetRole` (task definition drill-down), `ec2:DescribeInstances` (EC2 launch type only).
- Optional: `jq` (richer output — degrades gracefully without it).

## Inputs

- **CLUSTER** *(required)* — ECS cluster name or ARN.
- **SERVICE** *(required)* — service name or ARN.
- **PROFILE** — AWS CLI profile. Default: current default profile.
- **REGION** — AWS region. Default: current default region.
- **LOG_MINUTES** — how far back to search logs and metrics. Default: `60`.
- **REPORT_DIR** — report output directory. Default: `./aws-ecs-service-debug-reports`.

Confirm all inputs and caller identity with the user **before running any command**.

---

## Step 1 — Verify identity and locate the service

```bash
aws sts get-caller-identity 2>/dev/null

aws ecs describe-services \
  --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION" \
  --query 'services[0].{Name:serviceName,Arn:serviceArn,Status:status,LaunchType:launchType,CapacityProviders:capacityProviderStrategy[].capacityProvider,Desired:desiredCount,Running:runningCount,Pending:pendingCount,TaskDef:taskDefinition,HealthCheckGracePeriod:healthCheckGracePeriodSeconds}' \
  --output table 2>/dev/null \
|| echo "ERROR: Service '$SERVICE' not found in cluster '$CLUSTER' or insufficient permissions"
```

Stop and report if the service is not found. Never try alternative clusters or regions.

---

## Step 2 — Service events and deployment state

```bash
echo "=== Service events ==="
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION" \
  --query 'services[0].events[].[createdAt,message]' --output text 2>/dev/null | head -30

echo "=== Deployments ==="
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION" \
  --query 'services[0].deployments[].[id,status,desiredCount,runningCount,pendingCount,rolloutState]' \
  --output text 2>/dev/null

echo "=== Deployment circuit breaker and rollback ==="
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION" \
  --query 'services[0].deploymentConfiguration.deploymentCircuitBreaker' --output json 2>/dev/null
```

Flag:

- `runningCount` below `desiredCount` (shortfall — tasks failing or unable to place).
- A deployment `rolloutState` of `FAILED` or two deployments present (stuck rollout).
- Circuit breaker disabled (`circuitBreaker.enable: false`), so a bad deploy never auto-rolls back.
- Repeated `(service ...) was unable to place a task because no container instance met all of its requirements` events (EC2 capacity/placement problem).

---

## Step 3 — Recent stopped tasks and exit reasons

```bash
echo "=== Recently stopped tasks (last $LOG_MINUTES min) ==="
TASK_ARNS=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --desired-status STOPPED \
  --region "$REGION" --query 'taskArns[]' --output text 2>/dev/null)

if [ -n "$TASK_ARNS" ]; then
  # shellcheck disable=SC2086
  aws ecs describe-tasks --cluster "$CLUSTER" --tasks $TASK_ARNS --region "$REGION" \
    --query 'tasks[].{Task:taskArn,StoppedReason:stoppedReason,StopCode:stopCode,Health:healthStatus,Containers:containers[].{Name:name,ExitCode:exitCode,Reason:reason}}' \
    --output json 2>/dev/null
else
  echo "No recently stopped tasks listed"
fi
```

Flag:

- `stopCode: TaskFailedToStart` — most often bad image tag, missing ECR permission, or unreadable secrets.
- `StoppedReason` containing `OutOfMemory` or an exit code of `137` (OOM-killed).
- `stopCode: EssentialContainerExited` with a non-zero container `reason`/`exitCode`.
- Tasks exiting with `0` while desired count stays below target (app starts then quits — entrypoint or readiness issue).
- ELB health check failures (`Task failed ELB health checks`) — app healthy locally but failing `/health`.

---

## Step 4 — Task definition essentials

```bash
TASKDEF=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION" \
  --query 'services[0].taskDefinition' --output text 2>/dev/null)

aws ecs describe-task-definition --task-definition "$TASKDEF" --region "$REGION" \
  --query 'taskDefinition.{Family:family,Revision:revision,NetworkMode:networkMode,Cpu:cpu,Memory:memory,ExecutionRole:executionRoleArn,TaskRole:taskRoleArn,Compatibility:compatibilities,Containers:containerDefinitions[].{Name:name,Image:image,Essential:essential,Cpu:cpu,Memory:memory,MemoryReservation:memoryReservation,PortMappings:portMappings,LogDriver:logConfiguration.logDriver,LogOptions:logConfiguration.options,HealthCheck:healthCheck,Secrets:[secrets[].name],Env:[environment[].name]}}' \
  --output json 2>/dev/null
```

Flag:

- No `executionRoleArn` (can't pull private images, read secrets, or send logs).
- Image referenced by the mutable `:latest` tag (rollouts are non-deterministic).
- `secrets` referencing SSM/Secrets Manager ARNs whose IAM access is missing from the execution role.
- Environment variable keys containing `SECRET`, `KEY`, `TOKEN`, `PASS` (secrets should be in Secrets Manager / SSM — report key names only, never values).
- Hard `memory` at container level with no `memoryReservation` on EC2 (can make placement impossible).

---

## Step 5 — Load-balancer target health

```bash
TG_ARNS=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION" \
  --query 'services[0].loadBalancers[].targetGroupArn' --output text 2>/dev/null)

if [ -n "$TG_ARNS" ] && [ "$TG_ARNS" != "None" ]; then
  for tg in $TG_ARNS; do
    echo "=== Target group: $tg ==="
    aws elbv2 describe-target-health --target-group-arn "$tg" --region "$REGION" \
      --query 'TargetHealthDescriptions[].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason,Description:TargetHealth.Description}' \
      --output table 2>/dev/null
  done
else
  echo "Service is not attached to a load balancer"
fi
```

Flag:

- Targets in `unhealthy` state with reason `Target.FailedHealthChecks` — check the configured health-check path/port against the container.
- Targets `unused` after a deploy (draining old tasks that never terminate — long-lived connections or missing `stopTimeout`).
- Zero healthy targets with the service attached to a target group (traffic fully down).

---

## Step 6 — Execution and task IAM roles

```bash
for ROLE_ARN in \
  "$(aws ecs describe-task-definition --task-definition "$TASKDEF" --region "$REGION" --query 'taskDefinition.executionRoleArn' --output text 2>/dev/null)" \
  "$(aws ecs describe-task-definition --task-definition "$TASKDEF" --region "$REGION" --query 'taskDefinition.taskRoleArn' --output text 2>/dev/null)"; do
  [ -z "$ROLE_ARN" ] || [ "$ROLE_ARN" = "None" ] && continue
  ROLE_NAME=${ROLE_ARN##*/}
  echo "=== Role: $ROLE_NAME ==="
  aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
    --query 'AttachedPolicies[].{Name:PolicyName,Arn:PolicyArn}' --output table 2>/dev/null
  aws iam list-role-policies --role-name "$ROLE_NAME" --query 'PolicyNames[]' --output text 2>/dev/null
done
```

Flag:

- Execution role with `AdministratorAccess` / `PowerUserAccess`, or full-access managed policies — ECS roles should be narrowly scoped.
- Task role missing the permissions the app needs (surfaced as `AccessDenied` in logs).
- A single role shared by execution and task roles across many services.

---

## Step 7 — Container logs

```bash
echo "=== Log configuration ==="
aws ecs describe-task-definition --task-definition "$TASKDEF" --region "$REGION" \
  --query 'taskDefinition.containerDefinitions[].{Name:name,Driver:logConfiguration.logDriver,Group:logConfiguration.options."awslogs-group",StreamPrefix:logConfiguration.options."awslogs-stream-prefix"}' \
  --output table 2>/dev/null

echo "=== Recent ERROR lines (last $LOG_MINUTES min; names only) ==="
LOG_GROUP=$(aws ecs describe-task-definition --task-definition "$TASKDEF" --region "$REGION" \
  --query 'taskDefinition.containerDefinitions[0].logConfiguration.options."awslogs-group"' --output text 2>/dev/null)
if [ -n "$LOG_GROUP" ] && [ "$LOG_GROUP" != "None" ]; then
  START_MS=$(( ($(date +%s) - LOG_MINUTES * 60) * 1000 ))
  aws logs filter-log-events --log-group-name "$LOG_GROUP" --region "$REGION" \
    --start-time "$START_MS" --filter-pattern '?"ERROR" ?"Exception" ?"FATAL"' \
    --query 'events[].message' --output text 2>/dev/null | tail -50
else
  echo "No awslogs configuration found — inspect the container runtime log driver"
fi
```

Flag:

- Log pattern shows startup crashes, missing env vars, or connection-refused to dependencies.
- Logs stopping abruptly with no shutdown message (OOM at container or task level).
- Never echo full log bodies containing obvious secret patterns (`password=`, `token=`, `key=` followed by a value).

---

## Step 8 — Generate report

Compile all findings into a timestamped Markdown report:

```text
$REPORT_DIR/aws-ecs-service-debug-<service>-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# ECS Service Debug Report

| Field | Value |
|---|---|
| Generated | <timestamp> |
| Cluster | <name> |
| Service | <name> |
| Launch type | <EC2 / Fargate / capacity provider> |
| Region | <region> |
| Account | <account-id> |
| Desired / Running / Pending | <n> / <n> / <n> |
| Task definition | <family:revision> |

## Executive summary
<verdict: 🟢 healthy / 🟡 needs attention / 🔴 critical findings>
<top 3–5 findings ranked by severity>

## Findings by category
### Service state and deployment
### Stopped tasks and exit reasons
### Task definition and image
### Load-balancer target health
### IAM roles
### Logs

## Recommended actions
<prioritized list with specific AWS CLI or console remediation steps>
```

Present the user with:

1. Path to the saved report.
2. Verdict (🟢 / 🟡 / 🔴).
3. Top 3–5 recommended actions.

---

## Safety rules

- Every command in this workflow is **read-only**. No ECS resources are created, updated, scaled, or deleted.
- Never print secret or environment variable values — report only key names. Values may contain credentials.
- Never print log lines containing obvious secret patterns (e.g., `password=`, `token=`, `key=` followed by a value).
- Never suggest `aws ecs update-service --force-new-deployment` or task-definition changes as an automatic fix — list them as recommended actions for the user to approve.
- If a command fails due to IAM permissions, record the failure in the report and continue — never attempt privilege escalation.
- Confirm cluster, service, region, and AWS profile with the user before running any command.
