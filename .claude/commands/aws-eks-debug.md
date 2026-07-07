---
description: Read-only EKS cluster diagnostics — node groups, OIDC, add-ons, IAM roles for service accounts, networking, logging, and version skew. Generates a markdown report.
argument-hint: "CLUSTER=... [PROFILE=...] [REGION=...] [REPORT_DIR=...]"
---

# /aws-eks-debug — EKS Cluster Diagnostics

Read-only deep-dive into an EKS cluster from the AWS control-plane perspective. Covers cluster health, managed and self-managed node groups, OIDC/IRSA, EKS add-ons, networking (VPC CNI, security groups), logging, version skew, and IAM. Produces a severity-ranked Markdown report.

Complements `/k8s-debug` (cluster-level kubectl diagnostics) — run both for a full picture.

## Prerequisites

- `aws` CLI v2 configured (`aws sts get-caller-identity` succeeds).
- `kubectl` configured for the target cluster (optional — used for cross-referencing node status).
- IAM permissions: `AmazonEKSReadOnlyAccess` or equivalent (`eks:Describe*`, `eks:List*`, `ec2:Describe*`, `iam:Get*`, `iam:List*`).
- Optional: `jq` (richer output — degrades gracefully without it).

## Inputs

- **CLUSTER** *(required)* — EKS cluster name.
- **PROFILE** — AWS CLI profile. Default: current default profile.
- **REGION** — AWS region. Default: current default region.
- **REPORT_DIR** — report output directory. Default: `./aws-eks-debug-reports`.

Confirm all inputs, region, and caller identity with the user **before running any command**.

---

## Step 1 — Verify identity and cluster access

```bash
aws sts get-caller-identity --profile "${PROFILE:-default}" 2>/dev/null || aws sts get-caller-identity
aws configure get region

aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
  --query 'cluster.{Name:name,Version:version,Status:status,Endpoint:endpoint,RoleArn:roleArn,Created:createdAt}' \
  --output table 2>/dev/null
```

Stop and report if `describe-cluster` fails — the cluster may not exist in this region/account, or IAM permissions are insufficient. Never try alternative regions or profiles.

---

## Step 2 — Cluster health and configuration

```bash
echo "=== Cluster detail ==="
aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --output json 2>/dev/null \
  | jq '{name:.cluster.name, version:.cluster.version, status:.cluster.status,
         platformVersion:.cluster.platformVersion,
         endpoint:.cluster.endpoint,
         privateAccess:.cluster.resourcesVpcConfig.endpointPrivateAccess,
         publicAccess:.cluster.resourcesVpcConfig.endpointPublicAccess,
         publicCidrs:.cluster.resourcesVpcConfig.publicAccessCidrs,
         vpcId:.cluster.resourcesVpcConfig.vpcId,
         subnets:.cluster.resourcesVpcConfig.subnetIds,
         securityGroups:.cluster.resourcesVpcConfig.clusterSecurityGroupId,
         loggingTypes:[.cluster.logging.clusterLogging[]? | select(.enabled==true) | .types[]],
         tags:.cluster.tags}' 2>/dev/null \
  || aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --output table
```

Flag:
- Cluster status not `ACTIVE`.
- Public endpoint access enabled with `0.0.0.0/0` CIDR (no IP allowlist).
- All control-plane logging types not enabled (`api`, `audit`, `authenticator`, `controllerManager`, `scheduler`).

---

## Step 3 — Kubernetes version and upgrade readiness

```bash
echo "=== Cluster Kubernetes version ==="
aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
  --query 'cluster.{Version:version,PlatformVersion:platformVersion,Status:status}' --output table

echo "=== EKS available versions (to identify if cluster is behind) ==="
aws eks describe-addon-versions --region "$REGION" \
  --query 'addons[0].addonVersions[0].compatibilities[].clusterVersion' --output text 2>/dev/null | tr '\t' '\n' | sort -rV | head -5

echo "=== Node groups and their AMI/Kubernetes versions ==="
for ng in $(aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$REGION" \
  --query 'nodegroups[]' --output text 2>/dev/null); do
  aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$ng" --region "$REGION" \
    --query 'nodegroup.{Name:nodegroupName,Version:version,ReleaseVersion:releaseVersion,Status:status,DesiredSize:scalingConfig.desiredSize,MinSize:scalingConfig.minSize,MaxSize:scalingConfig.maxSize,CapacityType:capacityType,AmiType:amiType}' \
    --output table 2>/dev/null
done
```

Flag:
- Node groups running a Kubernetes version behind the control plane (version skew risk).
- Cluster on an EKS-deprecated version (check against current EKS release calendar).

---

## Step 4 — Managed node groups health

```bash
echo "=== Node groups list ==="
aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$REGION" --output table

echo "=== Node group details ==="
for ng in $(aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$REGION" \
  --query 'nodegroups[]' --output text 2>/dev/null); do
  echo "--- Node group: $ng ---"
  aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$ng" --region "$REGION" \
    --output json 2>/dev/null | jq '{
      name: .nodegroup.nodegroupName,
      status: .nodegroup.status,
      capacityType: .nodegroup.capacityType,
      amiType: .nodegroup.amiType,
      instanceTypes: .nodegroup.instanceTypes,
      scaling: .nodegroup.scalingConfig,
      diskSize: .nodegroup.diskSize,
      labels: .nodegroup.labels,
      taints: .nodegroup.taints,
      updateConfig: .nodegroup.updateConfig,
      health: .nodegroup.health,
      launchTemplate: .nodegroup.launchTemplate
    }' 2>/dev/null \
    || aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$ng" --region "$REGION" --output table
done
```

Flag:
- Node group status not `ACTIVE` (e.g., `DEGRADED`, `CREATE_FAILED`, `UPDATE_FAILED`).
- Health issues reported in `.nodegroup.health.issues`.
- `maxUnavailable` not set in `updateConfig` (defaults to 1 — may be too slow or too risky).
- Spot capacity type without on-demand fallback for critical workloads.

---

## Step 5 — Self-managed node groups and Fargate profiles

```bash
echo "=== Fargate profiles ==="
aws eks list-fargate-profiles --cluster-name "$CLUSTER" --region "$REGION" \
  --query 'fargateProfileNames[]' --output text 2>/dev/null | tr '\t' '\n' | while read fp; do
  [ -z "$fp" ] && continue
  aws eks describe-fargate-profile --cluster-name "$CLUSTER" --fargate-profile-name "$fp" --region "$REGION" \
    --query 'fargateProfile.{Name:fargateProfileName,Status:status,Selectors:selectors,PodExecutionRoleArn:podExecutionRoleArn}' \
    --output json 2>/dev/null
done || echo "No Fargate profiles or no permission"

echo "=== Auto Scaling Groups (self-managed nodes) ==="
aws autoscaling describe-auto-scaling-groups --region "$REGION" \
  --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER" \
  --query 'AutoScalingGroups[].{Name:AutoScalingGroupName,Min:MinSize,Max:MaxSize,Desired:DesiredCapacity,Instances:Instances[].InstanceId|length(@)}' \
  --output table 2>/dev/null || echo "No ASGs tagged for this cluster or no permission"
```

Flag:
- Fargate profiles in non-ACTIVE state.
- Self-managed ASG desired capacity at maximum (scaling headroom exhausted).

---

## Step 6 — OIDC and IAM Roles for Service Accounts (IRSA)

```bash
echo "=== OIDC provider for cluster ==="
OIDC_URL=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
  --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null)
echo "OIDC issuer: $OIDC_URL"

OIDC_ID=$(echo "$OIDC_URL" | sed 's|.*/||')
echo "OIDC ID: $OIDC_ID"

echo "=== OIDC provider registered in IAM ==="
aws iam list-open-id-connect-providers \
  --query "OIDCProviderList[?contains(Arn, '$OIDC_ID')].Arn" \
  --output text 2>/dev/null || echo "Could not list OIDC providers"

echo "=== IAM roles with IRSA trust policy (sample — first 20) ==="
aws iam list-roles --query 'Roles[].{RoleName:RoleName,Arn:Arn}' --output text 2>/dev/null \
  | awk '{print $2}' | head -100 | while read arn; do
    policy=$(aws iam get-role --role-name "$(basename "$arn")" \
      --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null)
    echo "$policy" | grep -q "$OIDC_ID" 2>/dev/null \
      && echo "IRSA-ROLE: $(basename "$arn")"
  done | head -20
```

Flag:
- OIDC issuer URL present in the cluster but no matching OIDC provider registered in IAM (IRSA will not work).
- No IRSA roles found (may mean pods are using node instance profile — broader permissions than needed).

---

## Step 7 — EKS add-ons

```bash
echo "=== Installed add-ons ==="
aws eks list-addons --cluster-name "$CLUSTER" --region "$REGION" --output table

echo "=== Add-on details ==="
for addon in $(aws eks list-addons --cluster-name "$CLUSTER" --region "$REGION" \
  --query 'addons[]' --output text 2>/dev/null); do
  aws eks describe-addon --cluster-name "$CLUSTER" --addon-name "$addon" --region "$REGION" \
    --query 'addon.{Name:addonName,Version:addonVersion,Status:status,ServiceAccountRole:serviceAccountRoleArn,Health:health,ConfigurationSchema:configurationSchema}' \
    --output json 2>/dev/null | jq 'del(.ConfigurationSchema)' 2>/dev/null \
    || aws eks describe-addon --cluster-name "$CLUSTER" --addon-name "$addon" --region "$REGION" \
       --query 'addon.{Name:addonName,Version:addonVersion,Status:status,Health:health}' --output table
done

echo "=== Latest available versions for installed add-ons ==="
for addon in $(aws eks list-addons --cluster-name "$CLUSTER" --region "$REGION" \
  --query 'addons[]' --output text 2>/dev/null); do
  CLUSTER_VER=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
    --query 'cluster.version' --output text 2>/dev/null)
  latest=$(aws eks describe-addon-versions --addon-name "$addon" --kubernetes-version "$CLUSTER_VER" \
    --query 'addons[0].addonVersions[0].addonVersion' --output text 2>/dev/null)
  current=$(aws eks describe-addon --cluster-name "$CLUSTER" --addon-name "$addon" --region "$REGION" \
    --query 'addon.addonVersion' --output text 2>/dev/null)
  echo "add-on=$addon current=$current latest=$latest"
done
```

Flag:
- Add-on status not `ACTIVE` (e.g., `DEGRADED`, `CREATE_FAILED`).
- Add-on health issues.
- Add-ons significantly behind latest available version for the cluster's Kubernetes version.
- Add-on using node instance profile instead of a dedicated IRSA role (`serviceAccountRoleArn` empty).

---

## Step 8 — VPC CNI and networking

```bash
echo "=== VPC and subnets used by cluster ==="
aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.{VpcId:vpcId,Subnets:subnetIds,SecurityGroups:securityGroupIds,ClusterSG:clusterSecurityGroupId}' \
  --output json 2>/dev/null

echo "=== Cluster security group rules ==="
CLUSTER_SG=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text 2>/dev/null)
[ -n "$CLUSTER_SG" ] && aws ec2 describe-security-groups --group-ids "$CLUSTER_SG" --region "$REGION" \
  --query 'SecurityGroups[].{GroupId:GroupId,GroupName:GroupName,InboundRules:IpPermissions[].{Proto:IpProtocol,Ports:[FromPort,ToPort],Sources:IpRanges[].CidrIp}}' \
  --output json 2>/dev/null

echo "=== Subnet available IP counts (risk: IP exhaustion with VPC CNI) ==="
SUBNET_IDS=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.subnetIds[]' --output text 2>/dev/null | tr '\t' ' ')
[ -n "$SUBNET_IDS" ] && aws ec2 describe-subnets --subnet-ids $SUBNET_IDS --region "$REGION" \
  --query 'Subnets[].{Id:SubnetId,AZ:AvailabilityZone,CidrBlock:CidrBlock,AvailableIPs:AvailableIpAddressCount,Tags:Tags[?Key==`Name`].Value|[0]}' \
  --output table 2>/dev/null

echo "=== VPC CNI add-on config (max pods, prefix delegation) ==="
aws eks describe-addon --cluster-name "$CLUSTER" --addon-name vpc-cni --region "$REGION" \
  --query 'addon.{Version:addonVersion,Config:configurationValues,Status:status}' \
  --output json 2>/dev/null || echo "vpc-cni add-on not managed by EKS (may be self-managed)"
```

Flag:
- Subnets with fewer than 20 available IPs (pod scheduling will fail as IPs are exhausted).
- Cluster security group with overly broad inbound rules.
- VPC CNI not managed as EKS add-on (harder to patch and update).

---

## Step 9 — Control-plane logging

```bash
echo "=== Enabled control-plane log types ==="
aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
  --query 'cluster.logging.clusterLogging' --output json 2>/dev/null

echo "=== CloudWatch log group for cluster ==="
LOG_GROUP="/aws/eks/$CLUSTER/cluster"
aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --region "$REGION" \
  --query 'logGroups[].{Name:logGroupName,RetentionDays:retentionInDays,StoredBytes:storedBytes}' \
  --output table 2>/dev/null || echo "Log group $LOG_GROUP not found"
```

Flag:
- Not all five log types enabled (`api`, `audit`, `authenticator`, `controllerManager`, `scheduler`).
- Log group retention not set (logs stored indefinitely — cost risk).
- Log group not found (logging enabled but logs not yet appearing — may be normal for new clusters).

---

## Step 10 — IAM and access entries

```bash
echo "=== Cluster role ARN ==="
aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
  --query 'cluster.roleArn' --output text 2>/dev/null

echo "=== Access entries (EKS access API — clusters with platform version >= eks.2 on k8s 1.29+) ==="
aws eks list-access-entries --cluster-name "$CLUSTER" --region "$REGION" \
  --query 'accessEntries[]' --output text 2>/dev/null | head -30 \
  || echo "Access entries API not supported for this cluster version, or no permission"

echo "=== aws-auth ConfigMap (legacy IAM mapping) ==="
# kubectl required — degrade gracefully if not available or not configured
kubectl get configmap aws-auth -n kube-system -o yaml 2>/dev/null \
  | grep -v "^\s*\(mapRoles\|mapUsers\|data\|apiVersion\|kind\|metadata\):" \
  | grep -v "^\s*$" \
  | head -40 \
  || echo "kubectl not configured or no RBAC to read aws-auth"
```

Flag:
- Cluster role ARN does not match expected naming convention or account.
- `aws-auth` ConfigMap grants `system:masters` to broad principals (IAM users, roles with `*`).
- Access entries with `AmazonEKSClusterAdminPolicy` for non-admin identities.

---

## Step 11 — Generate report

Compile all findings into a timestamped Markdown report:

```text
$REPORT_DIR/aws-eks-debug-<cluster>-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# EKS Cluster Debug Report

| Field | Value |
|---|---|
| Generated | <timestamp> |
| Cluster | <name> |
| Region | <region> |
| Account | <account-id> |
| Caller | <caller-arn> |
| Kubernetes Version | <version> |
| Platform Version | <platform-version> |
| Status | <status> |

## Executive summary
<verdict: 🟢 healthy / 🟡 needs attention / 🔴 critical findings>
<top 3–5 findings ranked by severity>

## Findings by category
### Cluster health
### Version and upgrade readiness
### Node groups
### OIDC / IRSA
### Add-ons
### Networking (VPC CNI, subnets)
### Control-plane logging
### IAM and access

## Recommended actions
<prioritized list with suggested AWS CLI or kubectl commands>
```

Present the user with:

1. Path to the saved report.
2. Verdict (🟢 / 🟡 / 🔴).
3. Top 3–5 recommended actions.

---

## Safety rules

- Every command in this workflow is **read-only**. No cluster or AWS resources are created, modified, or deleted.
- Never print secret values, tokens, or kubeconfig credentials. Report only names, ARNs, and configuration metadata.
- If a command fails due to IAM or RBAC permissions, record the failure in the report and continue — never attempt privilege escalation.
- Confirm cluster name, region, and AWS profile with the user before running any command.
