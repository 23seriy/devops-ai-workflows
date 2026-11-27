# Terraform Plan Review Report

> Example output from `/terraform-plan-review`. Account IDs, CIDRs, and names are fictional.

| Field | Value |
|---|---|
| Generated | 2026-03-14 09:42:10 UTC |
| Plan source | `plan.out` |
| Resources | 42 to add, 3 to change, 2 to destroy |
| Highest risk | 🔴 Critical |

## Executive summary

🔴 **Critical.** The plan **replaces** the primary RDS instance (`aws_db_instance.main`) because `engine_version` changed, and **destroys** two security groups still referenced by other resources. Both are high-impact.

## Findings

### 🔴 Critical — immediate attention

- **Replace** `aws_db_instance.main` — `engine_version` `"15.4" → "16.2"` forces replacement of a database with `deletion_protection = false`. Risk: data loss + multi-minute outage.
  - Recommended: use a blue/green deployment or snapshot-and-restore, and enable `deletion_protection` first.
- **Destroy** `aws_security_group.web_sg` — still attached to `aws_lb.frontend` (not in this plan). Risk: apply fails or opens implicit default.
- **Destroy** `aws_security_group.internal_sg` — referenced by an EKS node group with `create_before_destroy = false`.

### 🟡 Warning — review carefully

- **Change** `aws_security_group.app_sg` — ingress `0.0.0.0/0:22` added. Risk: SSH exposed to the internet.
- **Change** `aws_iam_policy.app_task` — adds `s3:*` on `*`. Risk: privilege expansion.
- **Replace** `aws_instance.bastion` — `ami` change; acceptable (stateless), but verify no SSH session state depends on it.

### 🟢 Safe — low risk

- 40 `aws_route53_record` additions (new service records).
- 2 tag-only changes.

## Recommended actions

1. Gate the RDS replace: enable `deletion_protection`, perform via blue/green or snapshot+restore, not in-place.
2. Remove the security-group destroys until references are migrated (add explicit `depends_on` review).
3. Reject the `0.0.0.0/0:22` ingress; use SSM Session Manager instead.
4. Split the IAM change into its own reviewed plan.
