---
description: Read-only AWS account hygiene and security audit. Scans IAM, S3, EC2, RDS, CloudTrail, encryption, and more. Generates a markdown report with findings ranked by severity.
---

# /aws-account-audit — AWS Account Security & Hygiene Audit

Perform a comprehensive, **read-only** sweep of an AWS account to surface security misconfigurations, hygiene gaps, and compliance risks. Requires only the AWS CLI and read-only IAM permissions.

## Prerequisites

- `aws` CLI v2 installed and configured (`aws sts get-caller-identity` succeeds).
- IAM permissions: `ReadOnlyAccess` managed policy or equivalent. The workflow degrades gracefully if specific API calls are denied.
- Optional: `jq` (richer JSON parsing).

## Inputs

Ask the user for the following before starting (use sensible defaults if not provided):

- **PROFILE** — AWS CLI profile name. Default: current default profile.
- **REGION** — primary region to audit. Default: current default region (`aws configure get region`).
- **ALL_REGIONS** — `yes`/`no`. If `yes`, repeat region-scoped checks across all enabled regions. Default: `no` (primary region only).
- **REPORT_DIR** — where to write the report. Default: `./aws-account-audit-reports`.

Confirm the inputs and caller identity with the user before proceeding.

---

## Step 1 — Verify identity and account context

// turbo

```bash
aws sts get-caller-identity
aws configure get region
aws organizations describe-organization 2>/dev/null || echo "Not part of an AWS Organization (or no org:Describe* permission)"
```

Stop the workflow if `get-caller-identity` fails — AWS CLI is not configured. Report exact error.

---

## Step 2 — IAM users, access keys, and MFA

// turbo

```bash
echo "=== IAM credential report ==="
aws iam generate-credential-report >/dev/null 2>&1
sleep 3
aws iam get-credential-report --query 'Content' --output text 2>/dev/null | base64 -d 2>/dev/null || echo "credential report not available"

echo "=== IAM users ==="
aws iam list-users --query 'Users[].{Name:UserName,Created:CreateDate,PasswordLastUsed:PasswordLastUsed,Arn:Arn}' --output table

echo "=== Users without MFA ==="
for user in $(aws iam list-users --query 'Users[].UserName' --output text); do
  mfa=$(aws iam list-mfa-devices --user-name "$user" --query 'MFADevices' --output text)
  [ -z "$mfa" ] && echo "NO-MFA: $user"
done

echo "=== Access keys older than 90 days ==="
for user in $(aws iam list-users --query 'Users[].UserName' --output text); do
  aws iam list-access-keys --user-name "$user" --query "AccessKeyMetadata[?CreateDate<='$(date -u -v-90d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '90 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)'].{User:UserName,KeyId:AccessKeyId,Created:CreateDate,Status:Status}" --output table 2>/dev/null
done

echo "=== Access keys never used ==="
for user in $(aws iam list-users --query 'Users[].UserName' --output text); do
  for key in $(aws iam list-access-keys --user-name "$user" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
    last=$(aws iam get-access-key-last-used --access-key-id "$key" --query 'AccessKeyLastUsed.LastUsedDate' --output text 2>/dev/null)
    [ "$last" = "None" ] || [ -z "$last" ] && echo "NEVER-USED: user=$user key=$key"
  done
done
```

Flag:

- Console users without MFA.
- Access keys older than 90 days.
- Access keys that have never been used.
- Root account access key existence (visible in credential report).

---

## Step 3 — IAM policies and privilege escalation risks

// turbo

```bash
echo "=== Policies with admin access ==="
for arn in $(aws iam list-policies --scope Local --query 'Policies[].Arn' --output text); do
  ver=$(aws iam get-policy --policy-arn "$arn" --query 'Policy.DefaultVersionId' --output text)
  doc=$(aws iam get-policy-version --policy-arn "$arn" --version-id "$ver" --query 'PolicyVersion.Document' --output json 2>/dev/null)
  echo "$doc" | jq -e '.Statement[] | select(.Effect=="Allow" and .Action=="*" and .Resource=="*")' >/dev/null 2>&1 && echo "ADMIN-POLICY: $arn"
done

echo "=== Users/roles with AdministratorAccess ==="
for arn in "arn:aws:iam::policy/AdministratorAccess" "arn:aws:iam::policy/IAMFullAccess"; do
  full_arn="arn:aws:iam::policy/${arn##*/}"
  managed_arn="arn:aws:iam::aws:policy/${arn##*/}"
  aws iam list-entities-for-policy --policy-arn "$managed_arn" --query '{Users:PolicyUsers[].UserName,Roles:PolicyRoles[].RoleName,Groups:PolicyGroups[].GroupName}' --output json 2>/dev/null || true
done

echo "=== Inline policies with wildcards ==="
for user in $(aws iam list-users --query 'Users[].UserName' --output text); do
  for pol in $(aws iam list-user-policies --user-name "$user" --query 'PolicyNames[]' --output text); do
    doc=$(aws iam get-user-policy --user-name "$user" --policy-name "$pol" --query 'PolicyDocument' --output json 2>/dev/null)
    echo "$doc" | jq -e '.Statement[] | select(.Effect=="Allow" and (.Action=="*" or .Action[]?=="*"))' >/dev/null 2>&1 && echo "WILDCARD-INLINE: user=$user policy=$pol"
  done
done
```

Flag:

- Customer-managed policies granting `*:*`.
- Principals with `AdministratorAccess` or `IAMFullAccess`.
- Inline policies with wildcard actions.
- Roles allowing `iam:PassRole` with `*` resource.

---

## Step 4 — S3 bucket security

// turbo

```bash
echo "=== S3 buckets ==="
aws s3api list-buckets --query 'Buckets[].Name' --output text | tr '\t' '\n' | while read bucket; do
  region=$(aws s3api get-bucket-location --bucket "$bucket" --query 'LocationConstraint' --output text 2>/dev/null)
  [ "$region" = "None" ] && region="us-east-1"

  # Public access block
  pab=$(aws s3api get-public-access-block --bucket "$bucket" 2>/dev/null | jq -r '.PublicAccessBlockConfiguration | to_entries | map(select(.value==false)) | .[].key' 2>/dev/null)
  [ -n "$pab" ] && echo "PUBLIC-ACCESS-OPEN: $bucket missing=$pab"

  # Encryption
  enc=$(aws s3api get-bucket-encryption --bucket "$bucket" 2>/dev/null | jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' 2>/dev/null)
  [ -z "$enc" ] || [ "$enc" = "null" ] && echo "NO-ENCRYPTION: $bucket"

  # Versioning
  ver=$(aws s3api get-bucket-versioning --bucket "$bucket" --query 'Status' --output text 2>/dev/null)
  [ "$ver" != "Enabled" ] && echo "NO-VERSIONING: $bucket status=${ver:-Disabled}"

  # Bucket policy public check
  pol=$(aws s3api get-bucket-policy --bucket "$bucket" --query 'Policy' --output text 2>/dev/null)
  [ -n "$pol" ] && echo "$pol" | jq -e '.Statement[] | select(.Effect=="Allow" and (.Principal=="*" or .Principal.AWS=="*"))' >/dev/null 2>&1 && echo "PUBLIC-POLICY: $bucket"

  echo "  $bucket region=$region enc=${enc:-none} ver=${ver:-Disabled}"
done
```

Flag:

- Buckets with public access block disabled or incomplete.
- Buckets without server-side encryption.
- Buckets without versioning (especially if they hold backups or logs).
- Bucket policies allowing `Principal: "*"`.

---

## Step 5 — EC2 and security groups

// turbo

```bash
REGIONS="${ALL_REGIONS_LIST:-$REGION}"

for r in $REGIONS; do
  echo "=== EC2 instances region=$r ==="
  aws ec2 describe-instances --region "$r" --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,State:State.Name,PublicIp:PublicIpAddress,Platform:Platform,LaunchTime:LaunchTime}' --output table 2>/dev/null

  echo "=== Open security groups region=$r ==="
  aws ec2 describe-security-groups --region "$r" --query 'SecurityGroups[]' --output json 2>/dev/null | jq -r '
    .[] | .GroupId as $gid | .GroupName as $gn |
    .IpPermissions[]? |
    select(.IpRanges[]?.CidrIp == "0.0.0.0/0" or .Ipv6Ranges[]?.CidrIpv6 == "::/0") |
    "\($gid) \($gn) port=\(.FromPort // "all")-\(.ToPort // "all") proto=\(.IpProtocol) OPEN-TO-WORLD"
  '

  echo "=== Unencrypted EBS volumes region=$r ==="
  aws ec2 describe-volumes --region "$r" --query 'Volumes[?Encrypted==`false`].{Id:VolumeId,Size:Size,State:State,Attached:Attachments[0].InstanceId}' --output table 2>/dev/null

  echo "=== Unattached EBS volumes region=$r ==="
  aws ec2 describe-volumes --region "$r" --filters Name=status,Values=available --query 'Volumes[].{Id:VolumeId,Size:Size,Type:VolumeType,Created:CreateTime}' --output table 2>/dev/null
done
```

Flag:

- Security groups open to `0.0.0.0/0` on sensitive ports (22, 3389, 3306, 5432, 6379, 27017).
- EC2 instances with public IP addresses.
- Unencrypted EBS volumes.
- Unattached EBS volumes (waste + potential data exposure).

---

## Step 6 — RDS security

// turbo

```bash
REGIONS="${ALL_REGIONS_LIST:-$REGION}"

for r in $REGIONS; do
  echo "=== RDS instances region=$r ==="
  aws rds describe-db-instances --region "$r" --query 'DBInstances[].{Id:DBInstanceIdentifier,Engine:Engine,Status:DBInstanceStatus,Public:PubliclyAccessible,Encrypted:StorageEncrypted,MultiAZ:MultiAZ,BackupRetention:BackupRetentionPeriod,Class:DBInstanceClass}' --output table 2>/dev/null

  echo "=== Public RDS instances region=$r ==="
  aws rds describe-db-instances --region "$r" --query 'DBInstances[?PubliclyAccessible==`true`].{Id:DBInstanceIdentifier,Engine:Engine,Endpoint:Endpoint.Address}' --output table 2>/dev/null

  echo "=== Unencrypted RDS instances region=$r ==="
  aws rds describe-db-instances --region "$r" --query 'DBInstances[?StorageEncrypted==`false`].{Id:DBInstanceIdentifier,Engine:Engine}' --output table 2>/dev/null

  echo "=== RDS instances with no/short backup retention region=$r ==="
  aws rds describe-db-instances --region "$r" --query 'DBInstances[?BackupRetentionPeriod<`7`].{Id:DBInstanceIdentifier,Retention:BackupRetentionPeriod}' --output table 2>/dev/null
done
```

Flag:

- Publicly accessible RDS instances.
- Unencrypted RDS instances.
- Backup retention < 7 days.
- Single-AZ production databases.

---

## Step 7 — CloudTrail, Config, GuardDuty, SecurityHub

// turbo

```bash
echo "=== CloudTrail trails ==="
aws cloudtrail describe-trails --query 'trailList[].{Name:Name,IsMultiRegion:IsMultiRegionTrail,LogValidation:LogFileValidationEnabled,S3Bucket:S3BucketName,IsOrg:IsOrganizationTrail}' --output table

echo "=== CloudTrail status ==="
for trail in $(aws cloudtrail describe-trails --query 'trailList[].Name' --output text); do
  status=$(aws cloudtrail get-trail-status --name "$trail" --query '{Logging:IsLogging,LatestDelivery:LatestDeliveryTime,LatestDigest:LatestDigestDeliveryTime}' --output json 2>/dev/null)
  echo "$trail: $status"
done

echo "=== AWS Config recorders ==="
aws configservice describe-configuration-recorders --query 'ConfigurationRecorders[].{Name:name,RoleArn:roleARN,AllSupported:recordingGroup.allSupported}' --output table 2>/dev/null || echo "Config not enabled or no permission"

echo "=== AWS Config recorder status ==="
aws configservice describe-configuration-recorder-status --query 'ConfigurationRecordersStatus[].{Name:name,Recording:recording,LastStatus:lastStatus}' --output table 2>/dev/null || true

echo "=== GuardDuty detectors ==="
for did in $(aws guardduty list-detectors --query 'DetectorIds[]' --output text 2>/dev/null); do
  aws guardduty get-detector --detector-id "$did" --query '{Id:DetectorId,Status:Status,FindingPublishing:FindingPublishingFrequency}' --output json 2>/dev/null
done
[ -z "$(aws guardduty list-detectors --query 'DetectorIds[]' --output text 2>/dev/null)" ] && echo "GuardDuty: NOT ENABLED"

echo "=== Security Hub status ==="
aws securityhub describe-hub 2>/dev/null || echo "SecurityHub: NOT ENABLED or no permission"
```

Flag:

- CloudTrail not enabled, not multi-region, or log validation disabled.
- AWS Config not recording.
- GuardDuty not enabled.
- SecurityHub not enabled.

---

## Step 8 — KMS key rotation and ECR

// turbo

```bash
echo "=== KMS keys without rotation ==="
for key in $(aws kms list-keys --query 'Keys[].KeyId' --output text 2>/dev/null); do
  mgr=$(aws kms describe-key --key-id "$key" --query 'KeyMetadata.KeyManager' --output text 2>/dev/null)
  [ "$mgr" != "CUSTOMER" ] && continue
  state=$(aws kms describe-key --key-id "$key" --query 'KeyMetadata.KeyState' --output text 2>/dev/null)
  [ "$state" != "Enabled" ] && continue
  rot=$(aws kms get-key-rotation-status --key-id "$key" --query 'KeyRotationEnabled' --output text 2>/dev/null)
  [ "$rot" != "True" ] && echo "NO-ROTATION: key=$key"
done

echo "=== ECR repositories ==="
aws ecr describe-repositories --query 'repositories[].{Name:repositoryName,ScanOnPush:imageScanningConfiguration.scanOnPush,TagImmutability:imageTagMutability,Uri:repositoryUri}' --output table 2>/dev/null || echo "No ECR repos or no permission"

echo "=== ECR repos without scan-on-push ==="
aws ecr describe-repositories --query 'repositories[?imageScanningConfiguration.scanOnPush==`false`].{Name:repositoryName}' --output table 2>/dev/null || true
```

Flag:

- Customer-managed KMS keys without automatic rotation.
- ECR repositories without scan-on-push enabled.

---

## Step 9 — Password policy and account-level settings

// turbo

```bash
echo "=== Account password policy ==="
aws iam get-account-password-policy 2>/dev/null || echo "No custom password policy set (AWS defaults apply)"

echo "=== Account summary ==="
aws iam get-account-summary --output json 2>/dev/null

echo "=== EBS default encryption ==="
aws ec2 get-ebs-encryption-by-default --query 'EbsEncryptionByDefault' --output text 2>/dev/null

echo "=== S3 account-level public access block ==="
aws s3control get-public-access-block --account-id $(aws sts get-caller-identity --query 'Account' --output text) 2>/dev/null || echo "No account-level S3 public access block"
```

Flag:

- No custom password policy (weak defaults).
- EBS default encryption not enabled.
- Account-level S3 public access block not set.

---

## Step 10 — Generate report

Compile all findings into a timestamped Markdown report:

```
$REPORT_DIR/aws-account-audit-<account-id>-<region>-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# AWS Account Audit Report

| Field | Value |
|---|---|
| Generated | <timestamp> |
| Account | <account-id> |
| Caller | <caller-arn> |
| Region(s) | <audited-regions> |
| Profile | <profile> |

## Executive summary
<verdict: 🟢 healthy / 🟡 needs attention / 🔴 critical findings>
<top 3–5 findings ranked by severity>

## Findings by category
### IAM
### S3
### EC2 & Security Groups
### RDS
### CloudTrail / Config / GuardDuty / SecurityHub
### KMS & Encryption
### ECR

## Recommended actions
<prioritized list with suggested remediation commands>
```

Present the user with:
1. Path to the saved report.
2. Verdict (🟢 / 🟡 / 🔴).
3. Top 3–5 recommended actions.

---

## Safety rules

- Every command in this workflow is **read-only**. No resources are created, modified, or deleted.
- Never print secret values, access keys, or passwords. Only names, ARNs, metadata, and configuration state.
- If a command fails due to IAM permissions, record the failure in the report and continue — do not attempt privilege escalation.
- The `generate-credential-report` call is the only "write-like" API; it generates a report inside IAM but does not modify any resources.
