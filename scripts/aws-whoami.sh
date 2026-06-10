#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────
# aws-whoami.sh — Quick AWS identity and account context
# ────────────────────────────────────────────────────────────────
# Usage: ./aws-whoami.sh [profile]
#
# Shows: caller identity, account alias, region, organization,
# and SSO role (if using AWS SSO).
# ────────────────────────────────────────────────────────────────
set -euo pipefail

PROFILE="${1:-}"

aws_cmd() {
  if [ -n "$PROFILE" ]; then
    aws --profile "$PROFILE" "$@"
  else
    aws "$@"
  fi
}

echo "🔍 AWS Identity Check"
echo "====================="
echo ""

echo "--- Caller Identity ---"
aws_cmd sts get-caller-identity --output table 2>&1

echo ""
echo "--- Region ---"
REGION=$(aws_cmd configure get region 2>/dev/null || echo "not set")
echo "Region: $REGION"

echo ""
echo "--- Account Aliases ---"
aws_cmd iam list-account-aliases --query 'AccountAliases[]' --output text 2>/dev/null || echo "(none or no permission)"

echo ""
echo "--- Organization ---"
aws_cmd organizations describe-organization --query 'Organization.{Id:Id,Master:MasterAccountId,Email:MasterAccountEmail}' --output table 2>/dev/null || echo "Not in an org (or no permission)"

echo ""
echo "--- SSO Role (if applicable) ---"
ARN=$(aws_cmd sts get-caller-identity --query 'Arn' --output text 2>/dev/null)
if echo "$ARN" | grep -q 'assumed-role'; then
  ROLE=$(echo "$ARN" | awk -F/ '{print $2}')
  USER=$(echo "$ARN" | awk -F/ '{print $3}')
  echo "Role: $ROLE"
  echo "User: $USER"
else
  echo "Not using assumed role"
fi
