---
description: Read-only Lambda function diagnostics — errors, throttles, duration, DLQ, VPC/ENI, concurrency, layers, and CloudWatch logs. Generates a markdown report.
argument-hint: "FUNCTION=... [PROFILE=...] [REGION=...] [LOG_MINUTES=60] [REPORT_DIR=...]"
---

# /aws-lambda-debug — Lambda Function Diagnostics

Read-only diagnostics for an AWS Lambda function. Covers function configuration, recent errors and throttles, duration percentiles, dead-letter queue state, VPC/ENI cold-start impact, concurrency limits, layer versions, event source mappings, and CloudWatch log tail. Produces a severity-ranked Markdown report.

## Prerequisites

- `aws` CLI v2 configured (`aws sts get-caller-identity` succeeds).
- IAM permissions: `AWSLambdaReadOnlyAccess` + `cloudwatch:GetMetricStatistics` + `logs:FilterLogEvents` + `logs:DescribeLogGroups`.
- Optional: `jq` (richer output — degrades gracefully without it).

## Inputs

- **FUNCTION** *(required)* — Lambda function name or ARN.
- **PROFILE** — AWS CLI profile. Default: current default profile.
- **REGION** — AWS region. Default: current default region.
- **LOG_MINUTES** — how far back to search logs and metrics. Default: `60`.
- **REPORT_DIR** — report output directory. Default: `./aws-lambda-debug-reports`.

Confirm all inputs and caller identity with the user **before running any command**.

---

## Step 1 — Verify identity and locate the function

```bash
aws sts get-caller-identity 2>/dev/null

aws lambda get-function --function-name "$FUNCTION" --region "$REGION" \
  --query 'Configuration.{Name:FunctionName,Arn:FunctionArn,Runtime:Runtime,State:State,LastStatus:LastUpdateStatus,Handler:Handler,Timeout:Timeout,MemorySize:MemorySize,CodeSize:CodeSize,Modified:LastModified}' \
  --output table 2>/dev/null \
|| echo "ERROR: Function '$FUNCTION' not found in $REGION or insufficient permissions"
```

Stop and report if the function is not found. Never try alternative regions or profiles.

---

## Step 2 — Function configuration

```bash
echo "=== Full function configuration ==="
aws lambda get-function-configuration --function-name "$FUNCTION" --region "$REGION" \
  --output json 2>/dev/null | jq '{
    name: .FunctionName,
    runtime: .Runtime,
    handler: .Handler,
    state: .State,
    lastUpdateStatus: .LastUpdateStatus,
    lastUpdateStatusReason: .LastUpdateStatusReason,
    timeout: .Timeout,
    memoryMB: .MemorySize,
    ephemeralStorageMB: .EphemeralStorage.Size,
    architecture: .Architectures,
    role: .Role,
    description: .Description,
    environment: (.Environment.Variables // {} | keys),
    vpcConfig: .VpcConfig,
    deadLetterConfig: .DeadLetterConfig,
    layers: [.Layers[]? | {arn: .Arn, size: .CodeSize}],
    reservedConcurrency: "see Step 6",
    packageType: .PackageType,
    imageUri: .Code.ImageUri,
    codeSha256: .CodeSha256,
    modified: .LastModified
  }' 2>/dev/null \
|| aws lambda get-function-configuration --function-name "$FUNCTION" --region "$REGION" --output table

echo "=== Function URL (if configured) ==="
aws lambda get-function-url-config --function-name "$FUNCTION" --region "$REGION" \
  --query '{Url:FunctionUrl,AuthType:AuthType,Cors:Cors}' --output json 2>/dev/null \
|| echo "No function URL configured"

echo "=== Function tags ==="
FUNC_ARN=$(aws lambda get-function --function-name "$FUNCTION" --region "$REGION" \
  --query 'Configuration.FunctionArn' --output text 2>/dev/null)
[ -n "$FUNC_ARN" ] && aws lambda list-tags --resource "$FUNC_ARN" --region "$REGION" --output json 2>/dev/null
```

Flag:
- `State` not `Active` (e.g., `Pending`, `Failed`, `Inactive`).
- `LastUpdateStatus` is `Failed` (recent deployment failed).
- `Timeout` at 15 minutes (maximum — likely misconfigured or function hangs).
- `MemorySize` at 128 MB minimum (may hit OOM for non-trivial workloads).
- Environment variable keys containing `SECRET`, `KEY`, `TOKEN`, `PASS`, `PASSWORD` (secrets should be in Secrets Manager or SSM Parameter Store, not env vars — report key names only, never values).
- No `DeadLetterConfig` on async-invoked functions.
- Function URL with `AuthType: NONE` (publicly accessible without auth).

---

## Step 3 — CloudWatch metrics (errors, throttles, duration, invocations)

```bash
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START=$(date -u -v-${LOG_MINUTES}M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d "${LOG_MINUTES} minutes ago" +%Y-%m-%dT%H:%M:%SZ)
PERIOD=300

echo "=== Invocations (last ${LOG_MINUTES}m) ==="
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda --metric-name Invocations \
  --dimensions "Name=FunctionName,Value=$FUNCTION" \
  --start-time "$START" --end-time "$END" \
  --period $PERIOD --statistics Sum \
  --region "$REGION" \
  --query 'sort_by(Datapoints,&Timestamp)[-6:].{Time:Timestamp,Count:Sum}' --output table 2>/dev/null

echo "=== Errors (last ${LOG_MINUTES}m) ==="
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda --metric-name Errors \
  --dimensions "Name=FunctionName,Value=$FUNCTION" \
  --start-time "$START" --end-time "$END" \
  --period $PERIOD --statistics Sum \
  --region "$REGION" \
  --query 'sort_by(Datapoints,&Timestamp)[-6:].{Time:Timestamp,Errors:Sum}' --output table 2>/dev/null

echo "=== Throttles (last ${LOG_MINUTES}m) ==="
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda --metric-name Throttles \
  --dimensions "Name=FunctionName,Value=$FUNCTION" \
  --start-time "$START" --end-time "$END" \
  --period $PERIOD --statistics Sum \
  --region "$REGION" \
  --query 'sort_by(Datapoints,&Timestamp)[-6:].{Time:Timestamp,Throttles:Sum}' --output table 2>/dev/null

echo "=== Duration p50/p95/p99 and max (last ${LOG_MINUTES}m) ==="
for stat in p50 p95 p99 Maximum; do
  aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda --metric-name Duration \
    --dimensions "Name=FunctionName,Value=$FUNCTION" \
    --start-time "$START" --end-time "$END" \
    --period $PERIOD --statistics "$stat" \
    --region "$REGION" \
    --query "sort_by(Datapoints,&Timestamp)[-3:].{Time:Timestamp,${stat}Ms:${stat}}" --output table 2>/dev/null
done

echo "=== ConcurrentExecutions (last ${LOG_MINUTES}m) ==="
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda --metric-name ConcurrentExecutions \
  --dimensions "Name=FunctionName,Value=$FUNCTION" \
  --start-time "$START" --end-time "$END" \
  --period $PERIOD --statistics Maximum \
  --region "$REGION" \
  --query 'sort_by(Datapoints,&Timestamp)[-6:].{Time:Timestamp,MaxConcurrent:Maximum}' --output table 2>/dev/null

echo "=== InitDuration (cold starts, last ${LOG_MINUTES}m) ==="
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda --metric-name InitDuration \
  --dimensions "Name=FunctionName,Value=$FUNCTION" \
  --start-time "$START" --end-time "$END" \
  --period $PERIOD --statistics Average Maximum SampleCount \
  --region "$REGION" \
  --query 'sort_by(Datapoints,&Timestamp)[-6:].{Time:Timestamp,AvgMs:Average,MaxMs:Maximum,ColdStarts:SampleCount}' --output table 2>/dev/null
```

Flag:
- Error rate above 1% of invocations (calculate: errors / invocations × 100).
- Any throttles present (reserved or account-level concurrency limit hit).
- p99 duration approaching the configured timeout (within 20%).
- High `InitDuration` (cold starts > 3s, especially with VPC config).
- `ConcurrentExecutions` approaching reserved or account limit.

---

## Step 4 — CloudWatch logs (recent errors)

```bash
LOG_GROUP="/aws/lambda/$FUNCTION"

echo "=== Log group info ==="
aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --region "$REGION" \
  --query 'logGroups[].{Name:logGroupName,RetentionDays:retentionInDays,StoredBytes:storedBytes,LastEvent:lastEventTime}' \
  --output table 2>/dev/null

echo "=== Recent ERROR / WARN / Exception / Timeout log lines ==="
START_MS=$(( $(date -u +%s) - ${LOG_MINUTES} * 60 ))000
aws logs filter-log-events \
  --log-group-name "$LOG_GROUP" \
  --start-time "${START_MS}" \
  --filter-pattern '?ERROR ?WARN ?Exception ?Timeout ?Task timed out ?OutOfMemory ?Runtime.ExitError' \
  --region "$REGION" \
  --query 'events[].{Time:timestamp,Message:message}' \
  --output json 2>/dev/null | jq '.[:30] | .[] | "\(.Time) \(.Message)"' -r 2>/dev/null \
|| echo "No matching log events or no log group access"

echo "=== Most recent log stream ==="
STREAM=$(aws logs describe-log-streams \
  --log-group-name "$LOG_GROUP" \
  --order-by LastEventTime --descending \
  --region "$REGION" \
  --query 'logStreams[0].logStreamName' --output text 2>/dev/null)
[ -n "$STREAM" ] && [ "$STREAM" != "None" ] && \
  aws logs get-log-events \
    --log-group-name "$LOG_GROUP" \
    --log-stream-name "$STREAM" \
    --region "$REGION" \
    --limit 30 \
    --query 'events[-30:].message' --output text 2>/dev/null \
  || echo "No log streams found"
```

Flag:
- Log group missing (Lambda never invoked, or logging disabled via resource policy).
- Log group retention not set (unbounded cost growth).
- `Task timed out` — function consistently hitting timeout.
- `Runtime.ExitError` — runtime crash (segfault, OOM, unhandled exception in runtime wrapper).
- `OutOfMemoryError` — needs larger `MemorySize`.

---

## Step 5 — Dead-letter queue (DLQ) and destinations

```bash
echo "=== Dead-letter queue config ==="
aws lambda get-function-configuration --function-name "$FUNCTION" --region "$REGION" \
  --query 'DeadLetterConfig' --output json 2>/dev/null

DLQ_ARN=$(aws lambda get-function-configuration --function-name "$FUNCTION" --region "$REGION" \
  --query 'DeadLetterConfig.TargetArn' --output text 2>/dev/null)

if [ -n "$DLQ_ARN" ] && [ "$DLQ_ARN" != "None" ]; then
  echo "=== DLQ approximate message count ==="
  # SQS DLQ
  echo "$DLQ_ARN" | grep -q "sqs" && \
    DLQ_URL=$(aws sqs get-queue-url \
      --queue-name "$(echo "$DLQ_ARN" | awk -F: '{print $NF}')" \
      --region "$REGION" --query 'QueueUrl' --output text 2>/dev/null) && \
    aws sqs get-queue-attributes --queue-url "$DLQ_URL" \
      --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
      --region "$REGION" --output table 2>/dev/null \
  || echo "DLQ is SNS or inaccessible — check manually"
fi

echo "=== Event destinations (async invocation) ==="
aws lambda get-function-event-invoke-config --function-name "$FUNCTION" --region "$REGION" \
  --query '{MaxRetryAttempts:MaximumRetryAttempts,MaxAgeSeconds:MaximumEventAgeInSeconds,OnSuccess:DestinationConfig.OnSuccess.Destination,OnFailure:DestinationConfig.OnFailure.Destination}' \
  --output json 2>/dev/null \
|| echo "No async invocation config (function may only be invoked synchronously)"
```

Flag:
- Async function with no DLQ and no `OnFailure` destination (failed events silently dropped).
- DLQ has messages (failures are accumulating — requires investigation).
- `MaximumRetryAttempts: 0` with no DLQ (zero retry tolerance but no failure capture).
- `MaximumEventAgeInSeconds` very high (events queued for a long time before giving up).

---

## Step 6 — Concurrency and throttle configuration

```bash
echo "=== Reserved concurrency ==="
aws lambda get-function-concurrency --function-name "$FUNCTION" --region "$REGION" \
  --query 'ReservedConcurrentExecutions' --output text 2>/dev/null \
|| echo "No reserved concurrency set (uses account pool)"

echo "=== Provisioned concurrency configs ==="
aws lambda list-provisioned-concurrency-configs --function-name "$FUNCTION" --region "$REGION" \
  --query 'ProvisionedConcurrencyConfigs[].{Qualifier:FunctionArn,Requested:RequestedProvisionedConcurrentExecutions,Allocated:AllocatedProvisionedConcurrentExecutions,Status:Status}' \
  --output table 2>/dev/null || echo "No provisioned concurrency configured"

echo "=== Account-level concurrency limit (region) ==="
aws lambda get-account-settings --region "$REGION" \
  --query '{TotalConcurrency:AccountLimit.ConcurrentExecutions,UnreservedConcurrency:AccountLimit.UnreservedConcurrentExecutions}' \
  --output table 2>/dev/null
```

Flag:
- `ReservedConcurrentExecutions: 0` — function throttled to zero (intentional or misconfiguration).
- No provisioned concurrency on a latency-sensitive function in a VPC (cold starts will be high).
- Account unreserved concurrency pool exhausted (other functions being throttled).

---

## Step 7 — VPC and networking

```bash
echo "=== VPC configuration ==="
aws lambda get-function-configuration --function-name "$FUNCTION" --region "$REGION" \
  --query 'VpcConfig.{VpcId:VpcId,Subnets:SubnetIds,SecurityGroups:SecurityGroupIds}' \
  --output json 2>/dev/null

VPC_ID=$(aws lambda get-function-configuration --function-name "$FUNCTION" --region "$REGION" \
  --query 'VpcConfig.VpcId' --output text 2>/dev/null)

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ] && [ "$VPC_ID" != "null" ]; then
  echo "=== Subnets available IPs (cold start pool) ==="
  SUBNET_IDS=$(aws lambda get-function-configuration --function-name "$FUNCTION" --region "$REGION" \
    --query 'VpcConfig.SubnetIds[]' --output text 2>/dev/null | tr '\t' ' ')
  [ -n "$SUBNET_IDS" ] && aws ec2 describe-subnets --subnet-ids $SUBNET_IDS --region "$REGION" \
    --query 'Subnets[].{Id:SubnetId,AZ:AvailabilityZone,CidrBlock:CidrBlock,AvailableIPs:AvailableIpAddressCount}' \
    --output table 2>/dev/null

  echo "=== Security groups ==="
  SG_IDS=$(aws lambda get-function-configuration --function-name "$FUNCTION" --region "$REGION" \
    --query 'VpcConfig.SecurityGroupIds[]' --output text 2>/dev/null | tr '\t' ' ')
  [ -n "$SG_IDS" ] && aws ec2 describe-security-groups --group-ids $SG_IDS --region "$REGION" \
    --query 'SecurityGroups[].{Id:GroupId,Name:GroupName,Outbound:IpPermissionsEgress[].{Proto:IpProtocol,From:FromPort,To:ToPort,CIDRs:IpRanges[].CidrIp}}' \
    --output json 2>/dev/null
else
  echo "Function not in a VPC"
fi
```

Flag:
- Function in VPC — cold starts will be higher; check provisioned concurrency if latency-sensitive.
- Subnets with few available IPs (ENI allocation will fail, causing throttle-like errors).
- Security group with no outbound rules (function cannot reach external services).
- Single subnet / single AZ (no AZ failover for ENIs).

---

## Step 8 — Event source mappings

```bash
echo "=== Event source mappings (triggers) ==="
aws lambda list-event-source-mappings --function-name "$FUNCTION" --region "$REGION" \
  --output json 2>/dev/null | jq '[.EventSourceMappings[] | {
    uuid: .UUID,
    source: .EventSourceArn,
    state: .State,
    stateReason: .StateTransitionReason,
    batchSize: .BatchSize,
    bisectOnError: .BisectBatchOnFunctionError,
    maxRetry: .MaximumRetryAttempts,
    maxAge: .MaximumRecordAgeInSeconds,
    destinationOnFailure: .DestinationConfig.OnFailure.Destination,
    startingPosition: .StartingPosition,
    filterCriteria: .FilterCriteria
  }]' 2>/dev/null \
|| aws lambda list-event-source-mappings --function-name "$FUNCTION" --region "$REGION" \
   --query 'EventSourceMappings[].{UUID:UUID,Source:EventSourceArn,State:State,BatchSize:BatchSize}' \
   --output table 2>/dev/null
```

Flag:
- Event source mapping in `Disabled` or `Failed` state.
- No `BisectBatchOnFunctionError` for Kinesis/DynamoDB sources (a single poison-pill message blocks the shard forever).
- No `DestinationConfig.OnFailure` for stream-based triggers (failed records silently dropped after retries exhausted).
- Very large `BatchSize` without corresponding timeout increase.

---

## Step 9 — Layers and runtime

```bash
echo "=== Layers ==="
aws lambda get-function-configuration --function-name "$FUNCTION" --region "$REGION" \
  --query 'Layers[].{Arn:Arn,Size:CodeSize}' --output table 2>/dev/null \
|| echo "No layers attached"

echo "=== Runtime deprecation status ==="
RUNTIME=$(aws lambda get-function-configuration --function-name "$FUNCTION" --region "$REGION" \
  --query 'Runtime' --output text 2>/dev/null)
echo "Runtime: $RUNTIME"
# Deprecated runtimes (as of mid-2025 — verify against https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html)
echo "$RUNTIME" | grep -qE "^(nodejs12|nodejs14|nodejs16|python2|python3\.6|python3\.7|python3\.8|ruby2|java8$|java11|go1\.x|dotnet5|dotnet6)" \
  && echo "WARNING: Runtime '$RUNTIME' is deprecated or approaching end of support — upgrade recommended" \
  || echo "Runtime appears current (verify against AWS Lambda runtime deprecation schedule)"

echo "=== Aliases ==="
aws lambda list-aliases --function-name "$FUNCTION" --region "$REGION" \
  --query 'Aliases[].{Name:Name,Version:FunctionVersion,Description:Description,RoutingConfig:RoutingConfig}' \
  --output table 2>/dev/null

echo "=== Published versions (last 5) ==="
aws lambda list-versions-by-function --function-name "$FUNCTION" --region "$REGION" \
  --query 'reverse(sort_by(Versions[?Version!=`$LATEST`], &LastModified))[:5].{Version:Version,Runtime:Runtime,Modified:LastModified,CodeSize:CodeSize}' \
  --output table 2>/dev/null
```

Flag:
- Deprecated runtime (security patches no longer applied by AWS).
- No aliases in use (deployments directly targeting `$LATEST` — no canary/traffic-shifting capability).
- Layer ARN pointing to an external account (supply chain risk — third-party layers can be updated without notice).

---

## Step 10 — IAM execution role

```bash
echo "=== Execution role ==="
ROLE_ARN=$(aws lambda get-function-configuration --function-name "$FUNCTION" --region "$REGION" \
  --query 'Role' --output text 2>/dev/null)
ROLE_NAME=$(echo "$ROLE_ARN" | awk -F/ '{print $NF}')
echo "Role ARN: $ROLE_ARN"

echo "=== Attached policies ==="
aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
  --query 'AttachedPolicies[].{Name:PolicyName,Arn:PolicyArn}' --output table 2>/dev/null

echo "=== Inline policies ==="
aws iam list-role-policies --role-name "$ROLE_NAME" \
  --query 'PolicyNames[]' --output text 2>/dev/null

echo "=== Check for overly broad permissions ==="
aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
  --query 'AttachedPolicies[?PolicyName==`AdministratorAccess` || PolicyName==`PowerUserAccess` || PolicyName==`AmazonDynamoDBFullAccess` || PolicyName==`AmazonS3FullAccess`].PolicyName' \
  --output text 2>/dev/null
```

Flag:
- Role has `AdministratorAccess` or `PowerUserAccess` (massively over-privileged for a Lambda).
- Role has full-access managed policies for individual services (S3, DynamoDB, etc.) rather than scoped resource-level permissions.
- Role name shared across multiple functions (cannot scope permissions per function).

---

## Step 11 — Generate report

Compile all findings into a timestamped Markdown report:

```text
$REPORT_DIR/aws-lambda-debug-<function>-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# Lambda Debug Report

| Field | Value |
|---|---|
| Generated | <timestamp> |
| Function | <name> |
| Runtime | <runtime> |
| Region | <region> |
| Account | <account-id> |
| State | <state> |
| Memory | <MB> |
| Timeout | <seconds> |

## Executive summary
<verdict: 🟢 healthy / 🟡 needs attention / 🔴 critical findings>
<top 3–5 findings ranked by severity>

## Findings by category
### Function state and configuration
### Errors and throttles
### Duration and cold starts
### CloudWatch logs
### Dead-letter queue
### Concurrency
### VPC and networking
### Event source mappings
### Layers and runtime
### IAM execution role

## Recommended actions
<prioritized list with specific AWS CLI or console remediation steps>
```

Present the user with:

1. Path to the saved report.
2. Verdict (🟢 / 🟡 / 🔴).
3. Top 3–5 recommended actions.

---

## Safety rules

- Every command in this workflow is **read-only**. No Lambda resources are created, modified, or deleted.
- Never print environment variable values — report only key names. Values may contain secrets.
- Never print log lines containing obvious secret patterns (e.g., lines matching `password=`, `token=`, `key=` followed by a value).
- If a command fails due to IAM permissions, record the failure in the report and continue — never attempt privilege escalation.
- Confirm function name, region, and AWS profile with the user before running any command.
