---
description: Read-only RDS/Aurora diagnostics — instance health, events, parameter groups, replication lag, storage, backups, and security posture. Generates a markdown report.
argument-hint: "DB_IDENTIFIER=... [PROFILE=...] [REGION=...] [REPORT_DIR=...]"
---

# /aws-rds-health — RDS/Aurora Health Diagnostics

Read-only deep-dive into an RDS or Aurora database instance or cluster. Covers instance status, recent events, parameter group drift, replication lag, storage pressure, backup configuration, security posture, and CloudWatch metrics. Produces a severity-ranked Markdown report.

## Prerequisites

- `aws` CLI v2 configured (`aws sts get-caller-identity` succeeds).
- IAM permissions: `AmazonRDSReadOnlyAccess` or equivalent (`rds:Describe*`, `cloudwatch:GetMetricStatistics`, `cloudwatch:GetMetricData`).
- Optional: `jq` (richer output — degrades gracefully without it).

## Inputs

- **DB_IDENTIFIER** *(required)* — RDS instance identifier or Aurora cluster identifier.
- **PROFILE** — AWS CLI profile. Default: current default profile.
- **REGION** — AWS region. Default: current default region.
- **REPORT_DIR** — report output directory. Default: `./aws-rds-health-reports`.

Confirm all inputs and caller identity with the user **before running any command**.

---

## Step 1 — Verify identity and locate the database

```bash
aws sts get-caller-identity 2>/dev/null

# Try instance first, then cluster
aws rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" --region "$REGION" \
  --query 'DBInstances[0].{Id:DBInstanceIdentifier,Engine:Engine,EngineVersion:EngineVersion,Class:DBInstanceClass,Status:DBInstanceStatus,MultiAZ:MultiAZ,AZ:AvailabilityZone}' \
  --output table 2>/dev/null \
|| aws rds describe-db-clusters --db-cluster-identifier "$DB_IDENTIFIER" --region "$REGION" \
  --query 'DBClusters[0].{Id:DBClusterIdentifier,Engine:Engine,EngineVersion:EngineVersion,Status:Status,MultiAZ:MultiAZ,Members:DBClusterMembers[].{Id:DBInstanceIdentifier,Role:IsClusterWriter}}' \
  --output json 2>/dev/null \
|| echo "ERROR: DB_IDENTIFIER '$DB_IDENTIFIER' not found as instance or cluster in $REGION"
```

Stop and report if the database is not found. Never try alternative regions or profiles.

Detect type (instance vs Aurora cluster) and set `DB_TYPE=instance|aurora` for subsequent steps.

---

## Step 2 — Instance / cluster detail

```bash
echo "=== RDS instance detail ==="
aws rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" --region "$REGION" \
  --output json 2>/dev/null | jq '.DBInstances[0] | {
    id: .DBInstanceIdentifier,
    engine: .Engine,
    engineVersion: .EngineVersion,
    class: .DBInstanceClass,
    status: .DBInstanceStatus,
    multiAZ: .MultiAZ,
    az: .AvailabilityZone,
    publiclyAccessible: .PubliclyAccessible,
    storageType: .StorageType,
    allocatedStorage: .AllocatedStorageGB,
    maxAllocatedStorage: .MaxAllocatedStorage,
    iops: .Iops,
    encrypted: .StorageEncrypted,
    kmsKeyId: .KmsKeyId,
    endpoint: .Endpoint.Address,
    port: .Endpoint.Port,
    vpcId: .DBSubnetGroup.VpcId,
    subnetGroup: .DBSubnetGroup.DBSubnetGroupName,
    securityGroups: [.VpcSecurityGroups[].VpcSecurityGroupId],
    parameterGroup: .DBParameterGroups[0].DBParameterGroupName,
    optionGroup: .OptionGroupMemberships[0].OptionGroupName,
    backupRetention: .BackupRetentionPeriod,
    backupWindow: .PreferredBackupWindow,
    maintenanceWindow: .PreferredMaintenanceWindow,
    autoMinorVersionUpgrade: .AutoMinorVersionUpgrade,
    deletionProtection: .DeletionProtection,
    performanceInsights: .PerformanceInsightsEnabled,
    caCertificate: .CACertificateIdentifier,
    latestRestorableTime: .LatestRestorableTime
  }' 2>/dev/null \
|| aws rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" --region "$REGION" --output table 2>/dev/null

echo "=== Aurora cluster detail (if applicable) ==="
aws rds describe-db-clusters --db-cluster-identifier "$DB_IDENTIFIER" --region "$REGION" \
  --output json 2>/dev/null | jq '.DBClusters[0] | {
    id: .DBClusterIdentifier,
    engine: .Engine,
    engineVersion: .EngineVersion,
    status: .Status,
    multiAZ: .MultiAZ,
    readerEndpoint: .ReaderEndpoint,
    writerEndpoint: .Endpoint,
    port: .Port,
    backupRetention: .BackupRetentionPeriod,
    deletionProtection: .DeletionProtection,
    encrypted: .StorageEncrypted,
    members: [.DBClusterMembers[] | {id: .DBInstanceIdentifier, writer: .IsClusterWriter}]
  }' 2>/dev/null || true
```

Flag:

- `PubliclyAccessible: true` — database reachable from the internet.
- `DeletionProtection: false` — database can be deleted without additional safeguard.
- `StorageEncrypted: false` — data at rest not encrypted.
- `AutoMinorVersionUpgrade: false` — security patches not applied automatically.
- `BackupRetentionPeriod < 7` — insufficient backup history.

---

## Step 3 — Recent events

```bash
echo "=== RDS events (last 24h) ==="
aws rds describe-events --source-identifier "$DB_IDENTIFIER" \
  --source-type db-instance \
  --duration 1440 \
  --region "$REGION" \
  --query 'Events[].{Time:Date,Category:EventCategories[0],Message:Message}' \
  --output table 2>/dev/null \
|| aws rds describe-events --source-identifier "$DB_IDENTIFIER" \
  --source-type db-cluster \
  --duration 1440 \
  --region "$REGION" \
  --query 'Events[].{Time:Date,Category:EventCategories[0],Message:Message}' \
  --output table 2>/dev/null

echo "=== RDS events (last 7 days) ==="
aws rds describe-events --source-identifier "$DB_IDENTIFIER" \
  --source-type db-instance \
  --duration 10080 \
  --region "$REGION" \
  --query 'Events[?contains(EventCategories, `failure`) || contains(EventCategories, `failover`) || contains(EventCategories, `maintenance`)].{Time:Date,Category:EventCategories[0],Message:Message}' \
  --output table 2>/dev/null || true
```

Flag:

- Any `failure` or `failover` events in the last 24h.
- Recent `maintenance` events indicating an unplanned or unexpected maintenance window.
- Repeated identical events (loop pattern — indicative of a persistent issue).

---

## Step 4 — Storage and I/O metrics (CloudWatch)

Fetch key metrics for the past 1 hour (5-minute periods).

```bash
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START=$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)

for metric in FreeStorageSpace ReadIOPS WriteIOPS ReadLatency WriteLatency DiskQueueDepth FreeableMemory DatabaseConnections CPUUtilization; do
  echo "=== $metric (last 1h, 5-min avg) ==="
  aws cloudwatch get-metric-statistics \
    --namespace AWS/RDS \
    --metric-name "$metric" \
    --dimensions "Name=DBInstanceIdentifier,Value=$DB_IDENTIFIER" \
    --start-time "$START" --end-time "$END" \
    --period 300 --statistics Average Maximum \
    --region "$REGION" \
    --query 'sort_by(Datapoints, &Timestamp)[-3:].{Time:Timestamp,Avg:Average,Max:Maximum}' \
    --output table 2>/dev/null || echo "  No data (may be Aurora cluster-level metric)"
done
```

Flag:

- `FreeStorageSpace` below 20% of `AllocatedStorage` (storage pressure).
- `CPUUtilization` sustained above 80%.
- `DatabaseConnections` near `max_connections` parameter value (check in Step 5).
- `ReadLatency` or `WriteLatency` above 20ms sustained.
- `DiskQueueDepth` consistently above 1 (I/O bottleneck).
- `FreeableMemory` below 256 MB (memory pressure).

---

## Step 5 — Parameter group

```bash
PG=$(aws rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" --region "$REGION" \
  --query 'DBInstances[0].DBParameterGroups[0].DBParameterGroupName' --output text 2>/dev/null)

echo "=== Parameter group: $PG ==="
aws rds describe-db-parameter-groups --db-parameter-group-name "$PG" --region "$REGION" \
  --query 'DBParameterGroups[0].{Name:DBParameterGroupName,Family:DBParameterGroupFamily,Description:Description}' \
  --output table 2>/dev/null

echo "=== Key parameters ==="
aws rds describe-db-parameters --db-parameter-group-name "$PG" --region "$REGION" \
  --query "Parameters[?ParameterName=='max_connections' || ParameterName=='innodb_buffer_pool_size' || ParameterName=='work_mem' || ParameterName=='shared_buffers' || ParameterName=='log_min_duration_statement' || ParameterName=='slow_query_log' || ParameterName=='long_query_time' || ParameterName=='log_connections' || ParameterName=='log_disconnections' || ParameterName=='rds.force_ssl' || ParameterName=='ssl' || ParameterName=='require_secure_transport'].{Name:ParameterName,Value:ParameterValue,Source:Source,ApplyType:ApplyType}" \
  --output table 2>/dev/null

echo "=== Parameters pending reboot ==="
aws rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" --region "$REGION" \
  --query 'DBInstances[0].DBParameterGroups[?ParameterApplyStatus==`pending-reboot`].{Name:DBParameterGroupName,Status:ParameterApplyStatus}' \
  --output table 2>/dev/null
```

Flag:

- Parameter group in `pending-reboot` state (configuration change not applied).
- `rds.force_ssl` or `require_secure_transport` not enabled (unencrypted connections allowed).
- `log_min_duration_statement` not set (no slow query logging — hard to diagnose performance issues).
- Using default parameter group (no custom tuning applied).

---

## Step 6 — Replication and Aurora cluster members

```bash
echo "=== Read replicas ==="
aws rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" --region "$REGION" \
  --query 'DBInstances[0].ReadReplicaDBInstanceIdentifiers[]' --output text 2>/dev/null

echo "=== Replica replication lag (CloudWatch) ==="
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START=$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name ReplicaLag \
  --dimensions "Name=DBInstanceIdentifier,Value=$DB_IDENTIFIER" \
  --start-time "$START" --end-time "$END" \
  --period 60 --statistics Average Maximum \
  --region "$REGION" \
  --query 'sort_by(Datapoints, &Timestamp)[-5:].{Time:Timestamp,AvgSeconds:Average,MaxSeconds:Maximum}' \
  --output table 2>/dev/null || echo "No ReplicaLag data (may be primary or no replicas)"

echo "=== Aurora cluster members and roles ==="
aws rds describe-db-clusters --db-cluster-identifier "$DB_IDENTIFIER" --region "$REGION" \
  --query 'DBClusters[0].DBClusterMembers[].{Instance:DBInstanceIdentifier,Writer:IsClusterWriter,PromotionTier:PromotionTier}' \
  --output table 2>/dev/null || echo "Not an Aurora cluster or no permission"

echo "=== Aurora global cluster (if applicable) ==="
aws rds describe-global-clusters --region "$REGION" \
  --query "GlobalClusters[?contains(GlobalClusterMembers[].DBClusterArn, '$DB_IDENTIFIER')].{Id:GlobalClusterIdentifier,Engine:Engine,Status:Status,Members:GlobalClusterMembers[].{Arn:DBClusterArn,Writer:IsWriter}}" \
  --output json 2>/dev/null || echo "Not part of a global cluster or no permission"
```

Flag:

- Replica lag above 30 seconds (replication falling behind).
- No read replicas for a production read-heavy workload (single point of failure for reads).
- Aurora cluster with all members at `PromotionTier=1` (failover order not tuned).

---

## Step 7 — Backups and snapshots

```bash
echo "=== Automated backup configuration ==="
aws rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" --region "$REGION" \
  --query 'DBInstances[0].{BackupRetention:BackupRetentionPeriod,BackupWindow:PreferredBackupWindow,LatestRestorableTime:LatestRestorableTime}' \
  --output table 2>/dev/null

echo "=== Recent manual snapshots (last 10) ==="
aws rds describe-db-snapshots --db-instance-identifier "$DB_IDENTIFIER" --region "$REGION" \
  --snapshot-type manual \
  --query 'reverse(sort_by(DBSnapshots, &SnapshotCreateTime))[:10].{Id:DBSnapshotIdentifier,Status:Status,Created:SnapshotCreateTime,SizeGB:AllocatedStorage,Encrypted:Encrypted}' \
  --output table 2>/dev/null

echo "=== Automated snapshots (most recent 3) ==="
aws rds describe-db-snapshots --db-instance-identifier "$DB_IDENTIFIER" --region "$REGION" \
  --snapshot-type automated \
  --query 'reverse(sort_by(DBSnapshots, &SnapshotCreateTime))[:3].{Id:DBSnapshotIdentifier,Status:Status,Created:SnapshotCreateTime,SizeGB:AllocatedStorage}' \
  --output table 2>/dev/null

echo "=== AWS Backup plans covering this RDS instance ==="
aws backup list-protected-resources --region "$REGION" \
  --query "Results[?ResourceType=='RDS'].{Arn:ResourceArn,LastBackup:LastBackupTime}" \
  --output table 2>/dev/null || echo "AWS Backup not accessible or not configured"
```

Flag:

- `BackupRetentionPeriod < 7` (less than a week of point-in-time recovery).
- `BackupRetentionPeriod = 0` (automated backups disabled — cannot do PITR).
- No manual snapshots (no out-of-cycle recovery point before risky operations).
- Latest automated snapshot older than 25 hours (backup window may be failing).
- Snapshots not encrypted.

---

## Step 8 — Security posture

```bash
echo "=== Security groups attached to RDS ==="
SG_IDS=$(aws rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" --region "$REGION" \
  --query 'DBInstances[0].VpcSecurityGroups[].VpcSecurityGroupId' --output text 2>/dev/null | tr '\t' ' ')
[ -n "$SG_IDS" ] && aws ec2 describe-security-groups --group-ids $SG_IDS --region "$REGION" \
  --query 'SecurityGroups[].{GroupId:GroupId,GroupName:GroupName,Inbound:IpPermissions[].{Proto:IpProtocol,From:FromPort,To:ToPort,CIDRs:IpRanges[].CidrIp}}' \
  --output json 2>/dev/null

echo "=== RDS subnet group ==="
SNG=$(aws rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" --region "$REGION" \
  --query 'DBInstances[0].DBSubnetGroup.DBSubnetGroupName' --output text 2>/dev/null)
aws rds describe-db-subnet-groups --db-subnet-group-name "$SNG" --region "$REGION" \
  --query 'DBSubnetGroups[0].{Name:DBSubnetGroupName,VpcId:VpcId,Subnets:Subnets[].{Id:SubnetIdentifier,AZ:SubnetAvailabilityZone.Name}}' \
  --output json 2>/dev/null

echo "=== CA certificate ==="
aws rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" --region "$REGION" \
  --query 'DBInstances[0].CACertificateIdentifier' --output text 2>/dev/null
```

Flag:

- Security group inbound rule allows `0.0.0.0/0` on DB port (public access).
- Security group allows DB port from entire VPC CIDR (overly broad).
- CA certificate is `rds-ca-2019` (deprecated — should migrate to `rds-ca-rsa2048-g1` or newer).
- Subnet group subnets not spread across at least 2 AZs.

---

## Step 9 — Engine version and upgrade path

```bash
echo "=== Current engine version ==="
aws rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" --region "$REGION" \
  --query 'DBInstances[0].{Engine:Engine,Version:EngineVersion,AutoMinorUpgrade:AutoMinorVersionUpgrade}' \
  --output table 2>/dev/null

echo "=== Available upgrade targets ==="
ENGINE=$(aws rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" --region "$REGION" \
  --query 'DBInstances[0].Engine' --output text 2>/dev/null)
VERSION=$(aws rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" --region "$REGION" \
  --query 'DBInstances[0].EngineVersion' --output text 2>/dev/null)
aws rds describe-db-engine-versions --engine "$ENGINE" --engine-version "$VERSION" --region "$REGION" \
  --query 'DBEngineVersions[0].ValidUpgradeTarget[].{Version:EngineVersion,AutoUpgrade:AutoUpgrade,IsMajor:IsMajorVersionUpgrade}' \
  --output table 2>/dev/null
```

Flag:

- Engine version with known CVEs or past end-of-life (check AWS RDS deprecation schedule).
- Major version upgrade available and `AutoMinorVersionUpgrade: false` (manually managed).
- No upgrade targets available (may already be on latest, or engine version lookup failed).

---

## Step 10 — Generate report

Compile all findings into a timestamped Markdown report:

```text
$REPORT_DIR/aws-rds-health-<db-identifier>-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# RDS Health Report

| Field | Value |
|---|---|
| Generated | <timestamp> |
| DB Identifier | <id> |
| Engine | <engine> <version> |
| Class | <instance-class> |
| Region | <region> |
| Account | <account-id> |
| Status | <status> |

## Executive summary
<verdict: 🟢 healthy / 🟡 needs attention / 🔴 critical findings>
<top 3–5 findings ranked by severity>

## Findings by category
### Instance / cluster health
### Recent events
### Storage and I/O
### Parameter group
### Replication
### Backups and snapshots
### Security posture
### Engine version

## Recommended actions
<prioritized list with specific AWS CLI remediation commands>
```

Present the user with:

1. Path to the saved report.
2. Verdict (🟢 / 🟡 / 🔴).
3. Top 3–5 recommended actions.

---

## Safety rules

- Every command in this workflow is **read-only**. No RDS resources are created, modified, or deleted.
- Never print secret values, passwords, or connection strings. Report only names, ARNs, endpoints, and configuration metadata.
- If a command fails due to IAM permissions, record the failure in the report and continue — never attempt privilege escalation.
- Confirm `DB_IDENTIFIER`, region, and AWS profile with the user before running any command.
