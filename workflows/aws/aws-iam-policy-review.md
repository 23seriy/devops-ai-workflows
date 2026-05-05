---
description: Explain an IAM policy and flag risky permissions. Detects admin-equivalent access, privilege escalation paths, wildcard actions, missing conditions, and overly broad resource scopes. Read-only, generates a markdown report.
---

# /aws-iam-policy-review — IAM Policy Security Review

Analyse an IAM policy (managed, inline, or local JSON file) and flag security risks: admin-equivalent permissions, privilege escalation paths, wildcard actions/resources, missing conditions, and overly permissive trust policies. All operations are **read-only**.

## Prerequisites

- `aws` CLI v2 installed and configured.
- IAM permissions: `iam:GetPolicy*`, `iam:GetRole*`, `iam:GetUser*`, `iam:GetGroup*`, `iam:ListAttachedRole*`, `iam:SimulatePrincipalPolicy` (optional), `access-analyzer:*` (optional).
- Optional: `jq`.

## Inputs

Ask the user for one of the following:

- **POLICY_ARN** — ARN of a managed policy (AWS or customer). Example: `arn:aws:iam::123456789012:policy/MyPolicy`.
- **PRINCIPAL_ARN** — ARN of a user, role, or group. The workflow will review all policies attached to this principal.
- **POLICY_FILE** — local path to a JSON policy document.

Optional:

- **REGION** — Default: current default region.
- **REPORT_DIR** — Default: `./aws-iam-policy-review-reports`.

---

## Step 1 — Resolve and fetch the policy document(s)

// turbo

```bash
aws sts get-caller-identity

# Option A: Single managed policy by ARN
if [ -n "$POLICY_ARN" ]; then
  echo "=== Policy metadata ==="
  aws iam get-policy --policy-arn "$POLICY_ARN" --output json
  VERSION=$(aws iam get-policy --policy-arn "$POLICY_ARN" --query 'Policy.DefaultVersionId' --output text)
  echo "=== Policy document (version $VERSION) ==="
  aws iam get-policy-version --policy-arn "$POLICY_ARN" --version-id "$VERSION" --query 'PolicyVersion.Document' --output json
fi

# Option B: All policies for a principal
if [ -n "$PRINCIPAL_ARN" ]; then
  PRINCIPAL_TYPE=$(echo "$PRINCIPAL_ARN" | grep -oE '(user|role|group)')
  PRINCIPAL_NAME=$(echo "$PRINCIPAL_ARN" | awk -F/ '{print $NF}')

  echo "=== Principal: $PRINCIPAL_TYPE/$PRINCIPAL_NAME ==="

  case $PRINCIPAL_TYPE in
    user)
      echo "--- Attached managed policies ---"
      aws iam list-attached-user-policies --user-name "$PRINCIPAL_NAME" --output json
      echo "--- Inline policies ---"
      for pol in $(aws iam list-user-policies --user-name "$PRINCIPAL_NAME" --query 'PolicyNames[]' --output text); do
        echo "-- Inline: $pol --"
        aws iam get-user-policy --user-name "$PRINCIPAL_NAME" --policy-name "$pol" --query 'PolicyDocument' --output json
      done
      echo "--- Group memberships ---"
      aws iam list-groups-for-user --user-name "$PRINCIPAL_NAME" --query 'Groups[].GroupName' --output text
      for grp in $(aws iam list-groups-for-user --user-name "$PRINCIPAL_NAME" --query 'Groups[].GroupName' --output text); do
        echo "-- Group $grp attached policies --"
        aws iam list-attached-group-policies --group-name "$grp" --output json
        for gpol in $(aws iam list-group-policies --group-name "$grp" --query 'PolicyNames[]' --output text); do
          echo "-- Group $grp inline: $gpol --"
          aws iam get-group-policy --group-name "$grp" --policy-name "$gpol" --query 'PolicyDocument' --output json
        done
      done
      ;;
    role)
      echo "--- Trust policy ---"
      aws iam get-role --role-name "$PRINCIPAL_NAME" --query 'Role.AssumeRolePolicyDocument' --output json
      echo "--- Attached managed policies ---"
      aws iam list-attached-role-policies --role-name "$PRINCIPAL_NAME" --output json
      echo "--- Inline policies ---"
      for pol in $(aws iam list-role-policies --role-name "$PRINCIPAL_NAME" --query 'PolicyNames[]' --output text); do
        echo "-- Inline: $pol --"
        aws iam get-role-policy --role-name "$PRINCIPAL_NAME" --policy-name "$pol" --query 'PolicyDocument' --output json
      done
      echo "--- Permission boundary ---"
      aws iam get-role --role-name "$PRINCIPAL_NAME" --query 'Role.PermissionsBoundary' --output json 2>/dev/null || echo "No permission boundary"
      ;;
    group)
      echo "--- Attached managed policies ---"
      aws iam list-attached-group-policies --group-name "$PRINCIPAL_NAME" --output json
      echo "--- Inline policies ---"
      for pol in $(aws iam list-group-policies --group-name "$PRINCIPAL_NAME" --query 'PolicyNames[]' --output text); do
        echo "-- Inline: $pol --"
        aws iam get-group-policy --group-name "$PRINCIPAL_NAME" --policy-name "$pol" --query 'PolicyDocument' --output json
      done
      ;;
  esac
fi

# Option C: Local file
if [ -n "$POLICY_FILE" ]; then
  echo "=== Policy document from file ==="
  cat "$POLICY_FILE"
fi
```

---

## Step 2 — Static analysis: dangerous patterns

For each collected policy document, the agent should check for the following patterns:

### Admin-equivalent access

```
Effect: Allow, Action: "*", Resource: "*"
Effect: Allow, Action: "iam:*", Resource: "*"
Effect: Allow, Action: ["s3:*", "ec2:*", ...many services...], Resource: "*"
```

### Privilege escalation paths

The following action combinations allow a principal to escalate its own or others' privileges:

| Escalation vector | Actions needed |
|---|---|
| Create new policy version | `iam:CreatePolicyVersion` |
| Set default policy version | `iam:SetDefaultPolicyVersion` |
| Create access key for another user | `iam:CreateAccessKey` on `Resource: *` |
| Create login profile | `iam:CreateLoginProfile` on `Resource: *` |
| Attach admin policy | `iam:AttachUserPolicy` or `iam:AttachRolePolicy` |
| Put user/role policy inline | `iam:PutUserPolicy` or `iam:PutRolePolicy` |
| Add user to group | `iam:AddUserToGroup` |
| Pass role + launch | `iam:PassRole` + `lambda:CreateFunction` + `lambda:InvokeFunction` |
| Pass role + EC2 | `iam:PassRole` + `ec2:RunInstances` |
| Pass role + CloudFormation | `iam:PassRole` + `cloudformation:CreateStack` |
| Update Lambda code | `lambda:UpdateFunctionCode` |
| Update assume role policy | `iam:UpdateAssumeRolePolicy` |
| STS assume role to admin role | `sts:AssumeRole` on admin role ARN |

### Wildcard resources

```
Resource: "*" combined with sensitive actions (iam:*, s3:Delete*, ec2:Terminate*, rds:Delete*, kms:Decrypt)
```

### Missing conditions

Flag `Allow` statements without `Condition` blocks for:

- `iam:PassRole` (should restrict which roles can be passed).
- `sts:AssumeRole` (should restrict source IP, MFA, or external ID).
- `s3:*` on sensitive buckets.
- Any action on `Resource: *`.

### Overly broad NotAction / NotResource

```
Effect: Allow, NotAction: [<small deny list>]  → allows everything else
Effect: Allow, NotResource: [<small list>]      → allows all other resources
```

---

## Step 3 — Trust policy analysis (roles only)

// turbo

```bash
if [ -n "$PRINCIPAL_ARN" ] && echo "$PRINCIPAL_ARN" | grep -q ':role/'; then
  ROLE_NAME=$(echo "$PRINCIPAL_ARN" | awk -F/ '{print $NF}')
  echo "=== Trust policy ==="
  aws iam get-role --role-name "$ROLE_NAME" --query 'Role.AssumeRolePolicyDocument' --output json

  echo "=== Who can assume this role? ==="
  aws iam get-role --role-name "$ROLE_NAME" --query 'Role.AssumeRolePolicyDocument.Statement[]' --output json | jq -r '
    .[] | select(.Effect=="Allow") |
    "Principal: \(.Principal // "none") Condition: \(.Condition // "none")"
  '
fi
```

Flag:

- Trust policy allowing `Principal: "*"` (any AWS account can assume).
- Trust policy without `Condition` (no MFA, no external ID, no source restriction).
- Cross-account trust without `aws:PrincipalOrgID` condition.
- Service principals that seem unusual for the role's purpose.

---

## Step 4 — IAM Access Analyzer findings (if available)

// turbo

```bash
echo "=== IAM Access Analyzer analyzers ==="
aws accessanalyzer list-analyzers --query 'analyzers[].{Name:name,Type:type,Status:status}' --output table 2>/dev/null || echo "Access Analyzer not available or no permission"

echo "=== Active findings ==="
for analyzer in $(aws accessanalyzer list-analyzers --query 'analyzers[?status==`ACTIVE`].name' --output text 2>/dev/null); do
  echo "--- Analyzer: $analyzer ---"
  aws accessanalyzer list-findings --analyzer-name "$analyzer" \
    --filter '{"status":{"eq":["ACTIVE"]}}' \
    --query 'findings[].{Resource:resource,ResourceType:resourceType,Condition:condition,Action:action,Principal:principal,Status:status}' \
    --output json 2>/dev/null | jq -r '.[:30] | .[]' || true
done
```

Flag:

- External access findings for the resources this policy grants access to.
- Unused access findings for the reviewed principal.

---

## Step 5 — Policy simulation (optional, if PRINCIPAL_ARN provided)

```bash
if [ -n "$PRINCIPAL_ARN" ]; then
  echo "=== Simulating high-risk actions ==="
  DANGEROUS_ACTIONS=(
    "iam:CreateUser"
    "iam:CreateAccessKey"
    "iam:AttachUserPolicy"
    "iam:AttachRolePolicy"
    "iam:PutUserPolicy"
    "iam:PutRolePolicy"
    "iam:CreatePolicyVersion"
    "iam:PassRole"
    "sts:AssumeRole"
    "s3:DeleteBucket"
    "ec2:TerminateInstances"
    "rds:DeleteDBInstance"
    "kms:Decrypt"
    "lambda:CreateFunction"
    "lambda:UpdateFunctionCode"
    "cloudformation:CreateStack"
  )
  for action in "${DANGEROUS_ACTIONS[@]}"; do
    result=$(aws iam simulate-principal-policy \
      --policy-source-arn "$PRINCIPAL_ARN" \
      --action-names "$action" \
      --query 'EvaluationResults[0].{Action:EvalActionName,Decision:EvalDecision}' \
      --output text 2>/dev/null)
    echo "$action → $result"
  done
fi
```

Flag:

- Any dangerous action that evaluates to `allowed`.
- Focus on privilege escalation vectors identified in Step 2.

---

## Step 6 — Generate report

Compile all findings into a timestamped Markdown report:

```
$REPORT_DIR/aws-iam-policy-review-<principal-or-policy-name>-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# IAM Policy Review Report

| Field | Value |
|---|---|
| Generated | <timestamp> |
| Account | <account-id> |
| Reviewed | <policy ARN / principal ARN / file path> |
| Policies analysed | <count> |

## Risk summary
<🟢 low risk / 🟡 medium risk / 🔴 high risk>

## Findings

### 🔴 Critical
<admin-equivalent access, privilege escalation paths>

### 🟡 Warning
<wildcard resources, missing conditions, broad NotAction>

### 🔵 Info
<trust policy observations, Access Analyzer findings>

## Policy explanation
<plain-English summary of what this policy/principal can do>

## Privilege escalation paths
<if any found, describe the chain>

## Recommended actions
<specific remediation: tighten resources, add conditions, remove unused permissions>
```

Present the user with:
1. Path to the saved report.
2. Risk verdict (🟢 / 🟡 / 🔴).
3. Top findings and recommended fixes.

---

## Safety rules

- Every command is **read-only**. No policies, users, roles, or resources are modified.
- `iam:SimulatePrincipalPolicy` is a read-only simulation — it does not execute any actions.
- Never print secret values, access keys, or passwords. Only policy documents, ARNs, and metadata.
- If a command fails due to IAM permissions, record the failure and continue.
- When printing policy documents, redact any embedded secrets if found (though well-formed policies should not contain secrets).
