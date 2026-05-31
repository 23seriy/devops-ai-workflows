---
description: Find AWS cost waste and top spend areas. Scans for idle resources, unattached storage, over-provisioned instances, and expensive log groups. Read-only, generates a markdown report.
---

# /aws-cost-quickscan — AWS Cost & Waste Analysis

Quick, **read-only** scan of an AWS account to surface the biggest cost drivers and likely waste. Identifies idle/stopped resources, unattached storage, over-provisioned instances, and expensive CloudWatch log groups.

## Prerequisites

- `aws` CLI v2 installed and configured.
- IAM permissions: `ReadOnlyAccess` or at minimum `ce:GetCostAndUsage`, `ec2:Describe*`, `rds:Describe*`, `s3:List*`, `elasticloadbalancing:Describe*`, `logs:DescribeLogGroups`, `cloudwatch:GetMetricStatistics`.
- `jq` installed (required for JSON parsing in several steps).
- Cost Explorer must be enabled in the account (it is enabled by default on accounts created after 2017).

## Inputs

- **PROFILE** — AWS CLI profile. Default: current default.
- **REGION** — primary region. Default: current default.
- **ALL_REGIONS** — `yes`/`no`. Default: `no`.
- **LOOKBACK_DAYS** — Cost Explorer lookback period. Default: `30`.
- **DEEP** — `yes`/`no`. If `yes`, also check per-instance CPU/memory utilization (requires CloudWatch `GetMetricStatistics`, slower on large fleets). Default: `no`.
- **REPORT_DIR** — Default: `./aws-cost-quickscan-reports`.

---

## Step 1 — Verify identity and region

// turbo

```bash
PROFILE_FLAG="${PROFILE:+--profile $PROFILE}"
aws sts get-caller-identity $PROFILE_FLAG
aws configure get region $PROFILE_FLAG
mkdir -p "${REPORT_DIR:-./aws-cost-quickscan-reports}"
```

---

## Step 2 — Cost Explorer: top spend by service

// turbo

```bash
START_DATE=$(date -u -v-${LOOKBACK_DAYS}d +%Y-%m-%d 2>/dev/null || date -u -d "${LOOKBACK_DAYS} days ago" +%Y-%m-%d)
END_DATE=$(date -u +%Y-%m-%d)

echo "=== Top spend by service (last ${LOOKBACK_DAYS} days) ==="
aws ce get-cost-and-usage $PROFILE_FLAG \
  --time-period Start=$START_DATE,End=$END_DATE \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[].Groups[].{Service:Keys[0],Cost:Metrics.BlendedCost.Amount}' \
  --output json 2>/dev/null | jq -r 'sort_by(-.Cost | tonumber) | .[:20] | .[] | "\(.Cost)\t\(.Service)"' || echo "Cost Explorer not available"

echo "=== Total spend (last ${LOOKBACK_DAYS} days) ==="
aws ce get-cost-and-usage $PROFILE_FLAG \
  --time-period Start=$START_DATE,End=$END_DATE \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --query 'ResultsByTime[].Total.BlendedCost.{Amount:Amount,Unit:Unit}' \
  --output table 2>/dev/null || true

echo "=== Daily spend trend (last 14 days) ==="
TREND_START=$(date -u -v-14d +%Y-%m-%d 2>/dev/null || date -u -d "14 days ago" +%Y-%m-%d)
aws ce get-cost-and-usage $PROFILE_FLAG \
  --time-period Start=$TREND_START,End=$END_DATE \
  --granularity DAILY \
  --metrics BlendedCost \
  --query 'ResultsByTime[].{Date:TimePeriod.Start,Cost:Total.BlendedCost.Amount}' \
  --output table 2>/dev/null || true
```

Flag:

- Services with spend spikes compared to daily average.
- Top 5 services by absolute spend.

---

## Step 3 — EC2 waste: stopped, idle, over-provisioned

// turbo

```bash
REGIONS="${ALL_REGIONS_LIST:-$REGION}"

for r in $REGIONS; do
  echo "=== Stopped EC2 instances region=$r ==="
  aws ec2 describe-instances $PROFILE_FLAG --region "$r" \
    --filters Name=instance-state-name,Values=stopped \
    --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,StoppedSince:StateTransitionReason,LaunchTime:LaunchTime,Name:Tags[?Key==`Name`]|[0].Value}' \
    --output table 2>/dev/null

  echo "=== Running instances by type region=$r ==="
  aws ec2 describe-instances $PROFILE_FLAG --region "$r" \
    --filters Name=instance-state-name,Values=running \
    --query 'Reservations[].Instances[].InstanceType' --output text 2>/dev/null | tr '\t' '\n' | sort | uniq -c | sort -rn

  echo "=== Long-running instances (>90 days) region=$r ==="
  aws ec2 describe-instances $PROFILE_FLAG --region "$r" \
    --filters Name=instance-state-name,Values=running \
    --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,LaunchTime:LaunchTime,Name:Tags[?Key==`Name`]|[0].Value}' \
    --output json 2>/dev/null | jq -r --arg cutoff "$(date -u -v-90d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '90 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
    '[.[] | select(.LaunchTime <= $cutoff)] | sort_by(.LaunchTime) | .[] | "\(.Id)\t\(.Type)\t\(.LaunchTime)\t\(.Name)"' || true
done
```

Flag:

- Stopped instances (still incur EBS charges).
- Long-running instances (>90 days) — candidates for Reserved Instance / Savings Plan.
- Large instance types with minimal utilization (see Step 9 DEEP mode for CPU analysis).

---

## Step 4 — EBS waste: unattached volumes and old snapshots

// turbo

```bash
REGIONS="${ALL_REGIONS_LIST:-$REGION}"

for r in $REGIONS; do
  echo "=== Unattached EBS volumes region=$r ==="
  aws ec2 describe-volumes $PROFILE_FLAG --region "$r" \
    --filters Name=status,Values=available \
    --query 'Volumes[].{Id:VolumeId,Size:Size,Type:VolumeType,Created:CreateTime}' \
    --output table 2>/dev/null

  echo "=== Total unattached EBS cost estimate region=$r ==="
  aws ec2 describe-volumes $PROFILE_FLAG --region "$r" \
    --filters Name=status,Values=available \
    --query 'Volumes[].Size' --output text 2>/dev/null | tr '\t' '\n' | awk '{s+=$1} END {print "Total unattached GB:", s+0}'

  echo "=== Snapshots older than 180 days region=$r ==="
  CUTOFF=$(date -u -v-180d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '180 days ago' +%Y-%m-%dT%H:%M:%SZ)
  aws ec2 describe-snapshots $PROFILE_FLAG --region "$r" --owner-ids self \
    --query "Snapshots[?StartTime<='$CUTOFF'].{Id:SnapshotId,Size:VolumeSize,Started:StartTime,Description:Description}" \
    --output table 2>/dev/null | head -80

  echo "=== Snapshot count and total size region=$r ==="
  aws ec2 describe-snapshots $PROFILE_FLAG --region "$r" --owner-ids self \
    --query 'Snapshots[].VolumeSize' --output text 2>/dev/null | tr '\t' '\n' | awk '{s+=$1; n++} END {print "Snapshots:", n+0, "Total GB:", s+0}'
done
```

Flag:

- Unattached volumes (pure waste).
- Old snapshots that may no longer be needed.
- Total unattached storage size for cost estimation.

---

## Step 5 — Elastic IPs and load balancers

// turbo

```bash
REGIONS="${ALL_REGIONS_LIST:-$REGION}"

for r in $REGIONS; do
  echo "=== Unassociated Elastic IPs region=$r ==="
  aws ec2 describe-addresses $PROFILE_FLAG --region "$r" \
    --query 'Addresses[?AssociationId==null].{AllocationId:AllocationId,PublicIp:PublicIp}' \
    --output table 2>/dev/null

  echo "=== ALBs/NLBs with no targets region=$r ==="
  for lb_arn in $(aws elbv2 describe-load-balancers $PROFILE_FLAG --region "$r" --query 'LoadBalancers[].LoadBalancerArn' --output text 2>/dev/null); do
    lb_name=$(aws elbv2 describe-load-balancers $PROFILE_FLAG --region "$r" --load-balancer-arns "$lb_arn" --query 'LoadBalancers[0].LoadBalancerName' --output text 2>/dev/null)
    tg_count=0
    for tg in $(aws elbv2 describe-target-groups $PROFILE_FLAG --region "$r" --load-balancer-arn "$lb_arn" --query 'TargetGroups[].TargetGroupArn' --output text 2>/dev/null); do
      health=$(aws elbv2 describe-target-health $PROFILE_FLAG --region "$r" --target-group-arn "$tg" --query 'TargetHealthDescriptions' --output text 2>/dev/null)
      [ -n "$health" ] && tg_count=$((tg_count + 1))
    done
    [ "$tg_count" -eq 0 ] && echo "NO-TARGETS: $lb_name ($lb_arn)"
  done

  echo "=== Classic ELBs region=$r ==="
  aws elb describe-load-balancers $PROFILE_FLAG --region "$r" --query 'LoadBalancerDescriptions[].{Name:LoadBalancerName,Instances:Instances|length(@),Created:CreatedTime}' --output table 2>/dev/null || true
done
```

Flag:

- Unassociated Elastic IPs ($3.65/mo each after Feb 2024 pricing change).
- Load balancers with no healthy targets.
- Classic ELBs (candidates for migration to ALB/NLB).

---

## Step 6 — NAT Gateways

// turbo

```bash
REGIONS="${ALL_REGIONS_LIST:-$REGION}"

for r in $REGIONS; do
  echo "=== NAT Gateways region=$r ==="
  aws ec2 describe-nat-gateways $PROFILE_FLAG --region "$r" \
    --filter Name=state,Values=available \
    --query 'NatGateways[].{Id:NatGatewayId,SubnetId:SubnetId,State:State,Created:CreateTime,PublicIp:NatGatewayAddresses[0].PublicIp}' \
    --output table 2>/dev/null

  echo "=== NAT Gateway data processing (last 7 days) region=$r ==="
  for natgw in $(aws ec2 describe-nat-gateways $PROFILE_FLAG --region "$r" --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null); do
    bytes=$(aws cloudwatch get-metric-statistics $PROFILE_FLAG --region "$r" \
      --namespace AWS/NATGateway --metric-name BytesOutToDestination \
      --dimensions Name=NatGatewayId,Value=$natgw \
      --start-time $(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ) \
      --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
      --period 604800 --statistics Sum \
      --query 'Datapoints[0].Sum' --output text 2>/dev/null)
    [ -n "$bytes" ] && [ "$bytes" != "None" ] && echo "  $natgw bytes_out_7d=$bytes ($(echo "$bytes / 1073741824" | bc 2>/dev/null || echo '?') GB)"
  done
done
```

Flag:

- NAT Gateway data processing costs (can be a major hidden cost).
- Multiple NAT Gateways per AZ (potentially redundant).

---

## Step 7 — RDS waste

// turbo

```bash
REGIONS="${ALL_REGIONS_LIST:-$REGION}"

for r in $REGIONS; do
  echo "=== Stopped RDS instances region=$r ==="
  aws rds describe-db-instances $PROFILE_FLAG --region "$r" \
    --query 'DBInstances[?DBInstanceStatus==`stopped`].{Id:DBInstanceIdentifier,Class:DBInstanceClass,Engine:Engine,Storage:AllocatedStorage}' \
    --output table 2>/dev/null

  echo "=== Running RDS instances region=$r ==="
  aws rds describe-db-instances $PROFILE_FLAG --region "$r" \
    --query 'DBInstances[?DBInstanceStatus==`available`].{Id:DBInstanceIdentifier,Class:DBInstanceClass,Engine:Engine,MultiAZ:MultiAZ,Storage:AllocatedStorage}' \
    --output table 2>/dev/null
done
```

Flag:

- Stopped RDS instances (still incur storage charges; auto-start after 7 days).
- Non-prod Multi-AZ instances (potential 50% savings by disabling Multi-AZ).
- Under-utilized running RDS instances (see Step 9 DEEP mode for CPU analysis).

---

## Step 8 — S3 and CloudWatch Logs

// turbo

```bash
echo "=== Largest S3 buckets (by size, sampled) ==="
for bucket in $(aws s3api list-buckets $PROFILE_FLAG --query 'Buckets[].Name' --output text 2>/dev/null | tr '\t' '\n' | head -50); do
  metrics=$(aws cloudwatch get-metric-statistics $PROFILE_FLAG --region us-east-1 \
    --namespace AWS/S3 --metric-name BucketSizeBytes \
    --dimensions Name=BucketName,Value=$bucket Name=StorageType,Value=StandardStorage \
    --start-time $(date -u -v-3d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
    --period 86400 --statistics Average \
    --query 'Datapoints[-1].Average' --output text 2>/dev/null)
  [ -n "$metrics" ] && [ "$metrics" != "None" ] && echo "$bucket size_bytes=$metrics ($(echo "$metrics / 1073741824" | bc 2>/dev/null || echo '?') GB)"
done | sort -t= -k2 -rn | head -20

echo "=== S3 incomplete multipart uploads ==="
for bucket in $(aws s3api list-buckets $PROFILE_FLAG --query 'Buckets[].Name' --output text 2>/dev/null | tr '\t' '\n' | head -30); do
  count=$(aws s3api list-multipart-uploads $PROFILE_FLAG --bucket "$bucket" --query 'length(Uploads || `[]`)' --output text 2>/dev/null)
  [ "$count" != "0" ] && [ "$count" != "None" ] 2>/dev/null && echo "INCOMPLETE-MULTIPART: $bucket count=$count"
done

echo "=== CloudWatch log groups by stored bytes ==="
aws logs describe-log-groups $PROFILE_FLAG \
  --query 'logGroups[].{Name:logGroupName,StoredBytes:storedBytes,Retention:retentionInDays}' \
  --output json 2>/dev/null | jq -r '[.[] | select(.StoredBytes != null)] | sort_by(-.StoredBytes) | .[:20] | .[] | "\(.StoredBytes / 1073741824 | . * 100 | round / 100) GB\tretention=\(.Retention // "never")\t\(.Name)"' || true

echo "=== Log groups with no retention (never expire) ==="
aws logs describe-log-groups $PROFILE_FLAG \
  --query 'logGroups[?!retentionInDays].{Name:logGroupName,StoredGB:storedBytes}' \
  --output json 2>/dev/null | jq -r '[.[] | select(.StoredGB != null and .StoredGB > 0)] | sort_by(-.StoredGB) | .[:20] | .[] | "\(.StoredGB / 1073741824 | . * 100 | round / 100) GB\t\(.Name)"' || true
```

Flag:

- Largest S3 buckets — review lifecycle policies.
- Incomplete multipart uploads (hidden cost).
- CloudWatch log groups with no retention policy (accumulate forever).
- Log groups storing many GB.

---

## Step 9 — Lambda audit

// turbo

```bash
REGIONS="${ALL_REGIONS_LIST:-$REGION}"

for r in $REGIONS; do
  echo "=== Lambda functions region=$r ==="
  aws lambda list-functions $PROFILE_FLAG --region "$r" \
    --query 'Functions[].{Name:FunctionName,Runtime:Runtime,Memory:MemorySize,Timeout:Timeout,LastModified:LastModified}' \
    --output json 2>/dev/null | jq -r 'sort_by(-.Memory) | .[] | "\(.Memory)MB\t\(.Timeout)s\t\(.Runtime // "n/a")\t\(.LastModified[:10])\t\(.Name)"' || true

  echo "=== Over-provisioned Lambdas (>512 MB memory) region=$r ==="
  aws lambda list-functions $PROFILE_FLAG --region "$r" \
    --query 'Functions[?MemorySize>`512`].{Name:FunctionName,Memory:MemorySize,Runtime:Runtime}' \
    --output table 2>/dev/null || true

  echo "=== Stale Lambdas (not modified in 90+ days) region=$r ==="
  LAMBDA_CUTOFF=$(date -u -v-90d +%Y-%m-%d 2>/dev/null || date -u -d '90 days ago' +%Y-%m-%d)
  aws lambda list-functions $PROFILE_FLAG --region "$r" \
    --query 'Functions[].{Name:FunctionName,LastModified:LastModified,Memory:MemorySize}' \
    --output json 2>/dev/null | jq -r --arg cutoff "$LAMBDA_CUTOFF" \
    '[.[] | select(.LastModified[:10] <= $cutoff)] | sort_by(.LastModified) | .[] | "\(.LastModified[:10])\t\(.Memory)MB\t\(.Name)"' | head -30 || true
done
```

Flag:
- Functions with >512 MB memory — likely over-provisioned.
- Functions not modified in 90+ days — candidates for cleanup.
- Deprecated runtimes (Python 3.8, Node.js 16, etc.).

---

## Step 10 — EC2 and RDS utilization analysis (only when DEEP=yes)

> **Skip this step if `DEEP!=yes`.** This makes one CloudWatch API call per instance and can be slow on large fleets (50+ instances). The workflow caps at 50 instances.

```bash
REGIONS="${ALL_REGIONS_LIST:-$REGION}"

for r in $REGIONS; do
  echo "=== Low-CPU EC2 instances (avg < 5% over 7d) region=$r ==="
  for iid in $(aws ec2 describe-instances $PROFILE_FLAG --region "$r" --filters Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | head -50); do
    avg=$(aws cloudwatch get-metric-statistics $PROFILE_FLAG --region "$r" \
      --namespace AWS/EC2 --metric-name CPUUtilization \
      --dimensions Name=InstanceId,Value=$iid \
      --start-time $(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ) \
      --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
      --period 86400 --statistics Average \
      --query 'Datapoints[].Average' --output text 2>/dev/null | awk '{s+=$1; n++} END {if(n>0) printf "%.1f", s/n; else print "N/A"}')
    [ "$avg" != "N/A" ] && [ "$(echo "$avg < 5" | bc 2>/dev/null)" = "1" ] && echo "LOW-CPU: $iid avg=${avg}%"
  done

  echo "=== Low-CPU RDS instances (avg < 10% over 7d) region=$r ==="
  for dbid in $(aws rds describe-db-instances $PROFILE_FLAG --region "$r" --query 'DBInstances[?DBInstanceStatus==`available`].DBInstanceIdentifier' --output text 2>/dev/null | head -30); do
    avg=$(aws cloudwatch get-metric-statistics $PROFILE_FLAG --region "$r" \
      --namespace AWS/RDS --metric-name CPUUtilization \
      --dimensions Name=DBInstanceIdentifier,Value=$dbid \
      --start-time $(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ) \
      --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
      --period 86400 --statistics Average \
      --query 'Datapoints[].Average' --output text 2>/dev/null | awk '{s+=$1; n++} END {if(n>0) printf "%.1f", s/n; else print "N/A"}')
    [ "$avg" != "N/A" ] && [ "$(echo "$avg < 10" | bc 2>/dev/null)" = "1" ] && echo "LOW-CPU-RDS: $dbid avg=${avg}%"
  done
done
```

Flag:
- EC2 instances with avg CPU < 5% — candidates for downsizing or termination.
- RDS instances with avg CPU < 10% — candidates for smaller instance class.
- Cross-reference with instance type to estimate savings from right-sizing.

---

## Step 11 — Savings Plans and Reserved Instances coverage

// turbo

```bash
echo "=== Active Savings Plans ==="
aws savingsplans describe-savings-plans $PROFILE_FLAG \
  --query 'savingsPlans[?state==`active`].{Id:savingsPlanId,Type:savingsPlanType,Commitment:commitment,Start:start,End:end,Utilization:utilizationPercentage}' \
  --output table 2>/dev/null || echo "No Savings Plans or no permission"

echo "=== Reserved Instances ==="
aws ec2 describe-reserved-instances $PROFILE_FLAG \
  --filters Name=state,Values=active \
  --query 'ReservedInstances[].{Id:ReservedInstancesId,Type:InstanceType,Count:InstanceCount,Duration:Duration,End:End}' \
  --output table 2>/dev/null || true

echo "=== RDS Reserved Instances ==="
aws rds describe-reserved-db-instances $PROFILE_FLAG \
  --query 'ReservedDBInstances[?State==`active`].{Id:ReservedDBInstanceId,Class:DBInstanceClass,Count:DBInstanceCount,Duration:Duration}' \
  --output table 2>/dev/null || true
```

Flag:

- No Savings Plans or Reserved Instances on heavy-use accounts.
- Low utilization of existing commitments.

---

## Step 12 — Generate report

Compile all findings into a timestamped Markdown report:

```
$REPORT_DIR/aws-cost-quickscan-<account-id>-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# AWS Cost Quick Scan Report

| Field | Value |
|---|---|
| Generated | <timestamp> |
| Account | <account-id> |
| Region(s) | <audited-regions> |
| Lookback | <LOOKBACK_DAYS> days |

## Executive summary
<estimated monthly waste>
<top 3–5 waste areas>

## Findings by category
### Cost Explorer — Top Spend
### EC2 Waste
### EBS Waste
### Elastic IPs & Load Balancers
### NAT Gateways
### RDS Waste
### S3 & CloudWatch Logs
### Savings Plans & Reserved Instances

## Recommended actions
<prioritized list with estimated monthly savings where possible>
```

Present the user with:
1. Path to the saved report.
2. Estimated total monthly waste.
3. Top 5 recommended cost-saving actions.

---

## Safety rules

- Every command in this workflow is **read-only**. No resources are created, modified, or deleted.
- Never print secret values or credentials. Only resource metadata, sizes, and utilization metrics.
- If a command fails due to IAM permissions, record the failure in the report and continue.
- Cost estimates are approximate and based on public pricing; actual costs depend on pricing agreements.
