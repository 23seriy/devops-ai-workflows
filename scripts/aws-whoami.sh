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

PROFILE_FLAG=""
[ -n "${1:-}" ] && PROFILE_FLAG="--profile $1"

echo "🔍 AWS Identity Check"
echo "====================="
echo ""

echo "--- Caller Identity ---"
aws sts get-caller-identity $PROFILE_FLAG --output table 2>&1

echo ""
echo "--- Region ---"
REGION=$(aws configure get region $PROFILE_FLAG 2>/dev/null || echo "not set")
echo "Region: $REGION"

echo ""
echo "--- Account Aliases ---"
aws iam list-account-aliases $PROFILE_FLAG --query 'AccountAliases[]' --output text 2>/dev/null || echo "(none or no permission)"

echo ""
echo "--- Organization ---"
aws organizations describe-organization $PROFILE_FLAG --query 'Organization.{Id:Id,Master:MasterAccountId,Email:MasterAccountEmail}' --output table 2>/dev/null || echo "Not in an org (or no permission)"

echo ""
echo "--- SSO Role (if applicable) ---"
ARN=$(aws sts get-caller-identity $PROFILE_FLAG --query 'Arn' --output text 2>/dev/null)
if echo "$ARN" | grep -q 'assumed-role'; then
  ROLE=$(echo "$ARN" | awk -F/ '{print $2}')
  USER=$(echo "$ARN" | awk -F/ '{print $3}')
  echo "Role: $ROLE"
  echo "User: $USER"
else
  echo "Not using assumed role"
fi
