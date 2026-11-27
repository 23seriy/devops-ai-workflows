# AWS Agent Rules

Agent-agnostic safety guardrails for AWS work. Reference from a project's `CLAUDE.md`, paste into a system prompt, or include as context when working on cloud infrastructure.

## Account and identity safety — non-negotiable

- ALWAYS run `aws sts get-caller-identity` before any AWS command and confirm the account ID and role match the intended target.
- NEVER assume the region — read it from the profile/config (`aws configure get region`) or ask; do not let it default silently for write operations.
- NEVER switch accounts, assume a different role, or retry with alternate credentials after an access-denied error. Report it and stop.
- NEVER run IAM `create`, `put`, `attach`, or `delete` operations without explicit user confirmation and a rollback plan.
- NEVER disable CloudTrail, GuardDuty, Security Hub, or organization-level guardrails, even temporarily.

## Read-only first

- Default to read-only APIs: `describe-*`, `list-*`, `get-*`, `head-*`.
- Never use `describe` output as a mutation shortcut — confirm parameters with the user first.
- Treat `aws s3 ls`/`s3 cp` as potentially expensive on large buckets; scope with a prefix and report what you intend to list.

## Data and secrets

- NEVER print secret values: `aws secretsmanager get-secret-value`, `aws ssm get-parameter --with-decryption`, and `aws kms decrypt` expose plaintext. Report ARNs/names/key IDs only.
- NEVER download objects from buckets for analysis; use metadata (`head-object`, `list-objects-v2`) unless the user explicitly asks.
- NEVER paste credentials, presigned URLs, or account IDs from one customer into another's context.
- NEVER enable public access on S3 buckets or security groups (`0.0.0.0/0`) without explicit confirmation and a documented justification.

## Destructive operations

- ALWAYS show what will change before proposing `delete-*`, `terminate-instances`, `modify-*`, `put-bucket-policy`, `update-service`, or `drain`-equivalent actions.
- NEVER run `aws ec2 terminate-instances`, `aws rds delete-db-instance/delete-db-cluster`, `aws s3 rm`, or `aws cloudformation delete-stack` in production without explicit confirmation, and prefer "stop" or "snapshot first" alternatives.
- For irreversible actions, recommend a backup/snapshot step and wait for the user to confirm it completed.
- ALWAYS prefer changes through Infrastructure as Code over ad-hoc CLI mutations; if a CLI fix is necessary, note that it must be reconciled in IaC afterwards.

## Cost awareness

- Before creating resources (`run-instances`, `create-db-instance`, `create-nat-gateway`, etc.), state the expected cost or the resource class.
- Flag accidentally expensive patterns: unused NAT gateways, idle load balancers, snapshots with no retention, log groups with infinite retention, over-provisioned EBS.
- Never delete "unused" resources to save cost without confirming with the owner — usage metrics can be misleading.

## Debugging approach

- Start with service health APIs: CloudWatch metrics/alarms, `describe-*` events, AWS Health, and service-specific logs before touching resources.
- Check the *event* history (`describe-events`, `describe-db-events`, ECS service events) before metric trends — they say *what* happened.
- When a call fails with AccessDenied, check IAM policy and SCPs; do not attempt privilege escalation.
- Use least-privilege read-only roles (`ReadOnlyAccess`, `SecurityAudit`, `ViewOnlyAccess`) for investigations.
