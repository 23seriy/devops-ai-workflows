---
description: Read-only S3 security and hygiene audit — public access, bucket policies, ACLs, encryption, versioning, lifecycle, logging, and replication. Generates a markdown report.
argument-hint: "[BUCKET=...] [PROFILE=...] [REGION=...] [DEEP=yes|no] [REPORT_DIR=...]"
---

# /aws-s3-audit — S3 Bucket Security & Hygiene Audit

Read-only sweep of S3 buckets in an account (or a single bucket). Flags public exposure, risky bucket policies and ACLs, missing encryption, unversioned buckets, absent lifecycle rules, no access logging, and versioning/replication gaps. Produces a severity-ranked Markdown report.

Uses `get` / `list` / `describe` calls only. Object data is never read or downloaded.

## Prerequisites

- `aws` CLI v2 configured (`aws sts get-caller-identity` succeeds).
- IAM permissions: `s3:ListAllMyBuckets`, `s3:GetBucket*` (policy, acl, encryption, versioning, lifecycle, logging, location, public-access-block), `s3:GetBucketLocation`.
- Optional: `jq` (richer output — degrades gracefully without it).

## Inputs

- **BUCKET** — audit a single bucket by name. Default: all buckets in the account.
- **PROFILE** — AWS CLI profile. Default: current default profile.
- **REGION** — AWS region for API calls. Default: current default region (bucket location is resolved per bucket regardless).
- **DEEP** — `yes` also reads `<bucket>-access-logs` and checks inventory/metric destinations. Default: `no`.
- **REPORT_DIR** — report output directory. Default: `./aws-s3-audit-reports`.

Confirm all inputs and caller identity with the user **before running any command**.

---

## Step 1 — Verify identity and enumerate buckets

```bash
aws sts get-caller-identity 2>/dev/null

if [ -n "${BUCKET:-}" ]; then
  echo "$BUCKET"
else
  aws s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null | tr '\t' '\n'
fi
```

Stop and report if identity fails. If `BUCKET` is set but not returned by `list-buckets`, report it and exit — never guess a name.

---

## Step 2 — Account-level public-access state

```bash
echo "=== Account public access block ==="
aws s3control get-public-access-block --account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --query 'PublicAccessBlockConfiguration' --output json 2>/dev/null \
  || echo "Not set (account-level block absent)"
```

Flag: any of `BlockPublicAcls`, `IgnorePublicAcls`, `BlockPublicPolicy`, `RestrictPublicBuckets` set to `false`, or the whole configuration missing (no account-wide guardrail).

---

## Step 3 — Per-bucket posture

For each bucket, gather the posture map without touching object data:

```bash
for b in $BUCKETS; do
  echo "=== $b ==="
  region=$(aws s3api get-bucket-location --bucket "$b" --query 'LocationConstraint' --output text 2>/dev/null)
  [ "$region" = "None" ] && region=us-east-1
  echo "region: $region"

  aws s3api get-public-access-block --bucket "$b" \
    --query 'PublicAccessBlockConfiguration' --output json 2>/dev/null \
    || echo "pab: none"

  aws s3api get-bucket-acl --bucket "$b" \
    --query '{owner:Grants[?Grantee.Type==`CanonicalUser`].Grantee.ID, public:Grants[?Grantee.Type==`Group` || Grantee.URI!=null].[Grantee.URI,Permission]}' \
    --output json 2>/dev/null

  aws s3api get-bucket-encryption --bucket "$b" \
    --query 'ServerSideEncryptionConfiguration.Rules[].ApplyServerSideEncryptionByDefault.SSEAlgorithm' \
    --output text 2>/dev/null || echo "encryption: NONE"

  aws s3api get-bucket-versioning --bucket "$b" --query 'Status' --output text 2>/dev/null
  aws s3api get-bucket-lifecycle-configuration --bucket "$b" \
    --query 'Rules[].ID' --output text 2>/dev/null || echo "lifecycle: NONE"
  aws s3api get-bucket-logging --bucket "$b" --query 'LoggingEnabled' --output json 2>/dev/null || echo "logging: NONE"
  aws s3api get-bucket-policy-status --bucket "$b" --query 'PolicyStatus.IsPublic' --output text 2>/dev/null
done
```

Flag per bucket:

- **Public exposure** — `PolicyStatus.IsPublic: true`, an ACL granting `AllUsers`/`AuthenticatedUsers`, or a `get-public-access-block` with `BlockPublicPolicy: false` while a policy allows `"Principal": "*"`.
- **Default encryption missing** — no SSE default (`AES256` or `aws:kms`). S3 applies SSE-S3 to new objects by default, but an explicit config is still expected for compliance.
- **No versioning** — `Status` absent; flag for buckets holding state, backups, or Terraform artifacts.
- **No lifecycle** — flag for log, temp, and data-lake buckets where objects accumulate indefinitely.
- **No access logging / CloudTrail data events** — note as a gap, not necessarily a failure.
- **No bucket policy at all** but public access not blocked — note the implicit exposure path.

---

## Step 4 — Bucket policy risk analysis

```bash
aws s3api get-bucket-policy --bucket "$b" --query Policy --output text 2>/dev/null \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); [print(json.dumps(s,indent=2)) for s in d["Statement"]]' 2>/dev/null \
  || echo "no bucket policy"
```

Flag:

- `Principal: "*"` with `Effect: Allow` and no narrowing `Condition` (e.g. `aws:SourceArn`, `aws:SourceVpce`, `aws:PrincipalOrgID`).
- `Action: "s3:*"` or `"*"` on any resource in the bucket.
- `Condition` allowing non-TLS: `"Bool": {"aws:SecureTransport": "false"}` present with `Effect: Allow` (should be a deny).
- Cross-account principals (`AWS: arn:aws:iam::<other-account>:...`) without justification — flag for review.
- Deny statements referencing `Principal: "*"` without `aws:PrincipalArn`/`aws:PrincipalOrgID` scoping (common footgun that locks out the account root).

---

## Step 5 — DEEP: logging and inventory destinations

Only when `DEEP=yes`:

```bash
echo "=== Bucket logging target existence ==="
target=$(aws s3api get-bucket-logging --bucket "$b" --query 'LoggingEnabled.TargetBucket' --output text 2>/dev/null)
[ -n "$target" ] && [ "$target" != "None" ] && aws s3api head-bucket --bucket "$target" 2>/dev/null && echo "log target OK: $target"

echo "=== Inventory configurations ==="
aws s3api list-bucket-inventory-configurations --bucket "$b" \
  --query 'InventoryConfigurationList[].{Id:Id,Dest:Destination.S3BucketDestination.Bucket,Enabled:IsEnabled}' \
  --output json 2>/dev/null || echo "no inventory"
```

Flag: logging pointing at a deleted/nonexistent bucket, inventory destinations in another account, or logging disabled on buckets holding audit data.

---

## Step 6 — Generate report

Compile all findings into a timestamped Markdown report:

```text
$REPORT_DIR/aws-s3-audit-<account>-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# S3 Audit Report

| Field | Value |
|---|---|
| Generated | <timestamp> |
| Account | <account-id> |
| Scope | <all buckets / single bucket> |
| Buckets audited | <n> |
| Public buckets | <n> |

## Executive summary
<verdict: 🟢 healthy / 🟡 needs attention / 🔴 critical findings>
<top 3–5 findings ranked by severity>

## Findings by category
### Public exposure
### Bucket policies and ACLs
### Encryption
### Versioning and lifecycle
### Logging and monitoring

## Bucket-by-bucket summary
| Bucket | Public? | Encryption | Versioning | Lifecycle | Logging | Verdict |
|---|---|---|---|---|---|---|

## Recommended actions
<prioritized list with specific AWS CLI or console remediation steps>
```

Present the user with:

1. Path to the saved report.
2. Verdict (🟢 / 🟡 / 🔴).
3. Top 3–5 recommended actions.

---

## Safety rules

- Every command in this workflow is **read-only**. No bucket, object, policy, or ACL is created, modified, or deleted.
- Object data is never read, downloaded, or listed beyond what policy/ACL/encryption calls require.
- Never print object contents or presigned URLs found in policies.
- Never suggest `aws s3api put-bucket-policy`, `put-public-access-block`, or `delete-*` as automatic fixes — list them as recommended actions for the user to approve.
- If a command fails due to IAM permissions, record the failure in the report and continue — never attempt privilege escalation.
- Confirm the bucket(s), region, and AWS profile with the user before running any command.
