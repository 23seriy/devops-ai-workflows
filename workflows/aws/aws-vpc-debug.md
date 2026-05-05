---
description: Diagnose AWS VPC connectivity issues. Traces the path between a source and destination across security groups, NACLs, route tables, NAT/IGW/TGW, VPC endpoints, and DNS. Read-only, generates a markdown report.
---

# /aws-vpc-debug — AWS VPC Connectivity Triage

Diagnose why traffic between a source and destination in AWS is blocked or misconfigured. Walks through VPC topology, route tables, security groups, NACLs, NAT/IGW/TGW/peering, VPC endpoints, and DNS resolution. All commands are **read-only**.

## Prerequisites

- `aws` CLI v2 installed and configured.
- IAM permissions: `ec2:Describe*`, `elasticloadbalancing:Describe*`, `rds:Describe*`, `route53:List*`, `logs:FilterLogEvents` (for VPC Flow Logs). `ReadOnlyAccess` covers all of these.
- Optional: `jq`, `dig`/`nslookup`.

## Inputs

Ask the user for the following:

- **SOURCE** *(required)* — Instance ID, ENI ID, private IP, or subnet ID of the traffic source.
- **DESTINATION** *(required)* — IP address, hostname, RDS endpoint, ALB/NLB DNS, VPC endpoint, or CIDR.
- **PORT** *(required)* — destination port (e.g. `443`, `5432`).
- **PROTOCOL** — `tcp` or `udp`. Default: `tcp`.
- **REGION** — Default: current default region.
- **REPORT_DIR** — Default: `./aws-vpc-debug-reports`.

---

## Step 1 — Verify identity and resolve source/destination

// turbo

```bash
aws sts get-caller-identity
REGION=${REGION:-$(aws configure get region)}

echo "=== Resolve SOURCE ==="
# If SOURCE looks like an instance ID
if echo "$SOURCE" | grep -qE '^i-[0-9a-f]+$'; then
  aws ec2 describe-instances --region $REGION --instance-ids $SOURCE \
    --query 'Reservations[0].Instances[0].{InstanceId:InstanceId,PrivateIp:PrivateIpAddress,PublicIp:PublicIpAddress,SubnetId:SubnetId,VpcId:VpcId,SecurityGroups:SecurityGroups[].GroupId,Name:Tags[?Key==`Name`]|[0].Value}' \
    --output json
fi

# If SOURCE looks like an ENI
if echo "$SOURCE" | grep -qE '^eni-[0-9a-f]+$'; then
  aws ec2 describe-network-interfaces --region $REGION --network-interface-ids $SOURCE \
    --query 'NetworkInterfaces[0].{Id:NetworkInterfaceId,PrivateIp:PrivateIpAddress,SubnetId:SubnetId,VpcId:VpcId,SecurityGroups:Groups[].GroupId,Description:Description}' \
    --output json
fi

echo "=== Resolve DESTINATION ==="
# If DESTINATION is a hostname, resolve it
if echo "$DESTINATION" | grep -qE '[a-zA-Z]'; then
  echo "DNS resolution:"
  dig +short "$DESTINATION" 2>/dev/null || nslookup "$DESTINATION" 2>/dev/null || echo "Could not resolve"
fi

# If DESTINATION looks like an RDS endpoint
if echo "$DESTINATION" | grep -qE '\.rds\.amazonaws\.com$'; then
  dbid=$(echo "$DESTINATION" | cut -d. -f1)
  aws rds describe-db-instances --region $REGION --db-instance-identifier "$dbid" \
    --query 'DBInstances[0].{Id:DBInstanceIdentifier,Endpoint:Endpoint,VpcSecurityGroups:VpcSecurityGroups[].VpcSecurityGroupId,SubnetGroup:DBSubnetGroup.DBSubnetGroupName}' \
    --output json 2>/dev/null || true
fi
```

Stop if the source cannot be resolved — report the error and suggest checking the instance/ENI ID.

---

## Step 2 — VPC and subnet topology

// turbo

```bash
echo "=== Source VPC ==="
aws ec2 describe-vpcs --region $REGION --vpc-ids $SRC_VPC_ID \
  --query 'Vpcs[0].{VpcId:VpcId,CidrBlock:CidrBlock,IsDefault:IsDefault,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output json 2>/dev/null

echo "=== Source subnet ==="
aws ec2 describe-subnets --region $REGION --subnet-ids $SRC_SUBNET_ID \
  --query 'Subnets[0].{SubnetId:SubnetId,CidrBlock:CidrBlock,AZ:AvailabilityZone,MapPublicIp:MapPublicIpOnLaunch,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output json 2>/dev/null

echo "=== Destination VPC (if resolvable) ==="
# If destination IP is private, find which VPC/subnet it belongs to
if echo "$DEST_IP" | grep -qE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)'; then
  aws ec2 describe-network-interfaces --region $REGION \
    --filters Name=addresses.private-ip-address,Values=$DEST_IP \
    --query 'NetworkInterfaces[0].{VpcId:VpcId,SubnetId:SubnetId,SecurityGroups:Groups[].GroupId,Description:Description}' \
    --output json 2>/dev/null || echo "Destination IP not found as ENI address"
fi

echo "=== VPC peering connections ==="
aws ec2 describe-vpc-peering-connections --region $REGION \
  --filters Name=status-code,Values=active \
  --query 'VpcPeeringConnections[].{Id:VpcPeeringConnectionId,Requester:RequesterVpcInfo.{VpcId:VpcId,CidrBlock:CidrBlock},Accepter:AccepterVpcInfo.{VpcId:VpcId,CidrBlock:CidrBlock}}' \
  --output json 2>/dev/null | head -100

echo "=== Transit Gateway attachments ==="
aws ec2 describe-transit-gateway-attachments --region $REGION \
  --query 'TransitGatewayAttachments[].{TgwId:TransitGatewayId,AttachmentId:TransitGatewayAttachmentId,ResourceType:ResourceType,ResourceId:ResourceId,State:State}' \
  --output table 2>/dev/null || echo "No TGW or no permission"
```

Flag:

- Source and destination in different VPCs without peering/TGW.
- Public vs private subnet classification.

---

## Step 3 — Route tables

// turbo

```bash
echo "=== Source subnet route table ==="
RT_ID=$(aws ec2 describe-route-tables --region $REGION \
  --filters Name=association.subnet-id,Values=$SRC_SUBNET_ID \
  --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)
[ "$RT_ID" = "None" ] || [ -z "$RT_ID" ] && RT_ID=$(aws ec2 describe-route-tables --region $REGION \
  --filters Name=association.main,Values=true Name=vpc-id,Values=$SRC_VPC_ID \
  --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)
echo "Route table: $RT_ID"

aws ec2 describe-route-tables --region $REGION --route-table-ids $RT_ID \
  --query 'RouteTables[0].Routes[].{Destination:DestinationCidrBlock,Target:GatewayId||NatGatewayId||TransitGatewayId||VpcPeeringConnectionId||NetworkInterfaceId,State:State}' \
  --output table 2>/dev/null

echo "=== Does a route exist to destination? ==="
# The agent should check if DEST_IP or DEST_CIDR matches any route in the table
# and identify the next hop (IGW, NAT, TGW, peering, etc.)
```

Flag:

- No route to destination CIDR → traffic will be dropped.
- Route via NAT Gateway but destination is public → check NAT Gateway health.
- Route via IGW but instance has no public IP → traffic won't return.
- Blackhole routes.

---

## Step 4 — Security groups

// turbo

```bash
echo "=== Source security group outbound rules ==="
for sg in $SRC_SECURITY_GROUPS; do
  echo "--- SG: $sg ---"
  aws ec2 describe-security-groups --region $REGION --group-ids $sg \
    --query 'SecurityGroups[0].IpPermissionsEgress[].{Proto:IpProtocol,FromPort:FromPort,ToPort:ToPort,CidrRanges:IpRanges[].CidrIp,SGRefs:UserIdGroupPairs[].GroupId}' \
    --output json 2>/dev/null
done

echo "=== Destination security group inbound rules ==="
for sg in $DST_SECURITY_GROUPS; do
  echo "--- SG: $sg ---"
  aws ec2 describe-security-groups --region $REGION --group-ids $sg \
    --query 'SecurityGroups[0].IpPermissions[].{Proto:IpProtocol,FromPort:FromPort,ToPort:ToPort,CidrRanges:IpRanges[].CidrIp,SGRefs:UserIdGroupPairs[].GroupId}' \
    --output json 2>/dev/null
done
```

Flag:

- Source SG egress does not allow traffic to destination IP/port.
- Destination SG ingress does not allow traffic from source IP/SG on the required port.
- Remember: SGs are stateful; if outbound is allowed, return traffic is auto-allowed.

---

## Step 5 — Network ACLs

// turbo

```bash
echo "=== Source subnet NACL ==="
SRC_NACL=$(aws ec2 describe-network-acls --region $REGION \
  --filters Name=association.subnet-id,Values=$SRC_SUBNET_ID \
  --query 'NetworkAcls[0].NetworkAclId' --output text 2>/dev/null)
echo "NACL: $SRC_NACL"

aws ec2 describe-network-acls --region $REGION --network-acl-ids $SRC_NACL \
  --query 'NetworkAcls[0].Entries[]' --output json 2>/dev/null | jq -r 'sort_by(.RuleNumber) | .[] | "\(.Egress|if . then "OUTBOUND" else "INBOUND" end) rule=\(.RuleNumber) action=\(.RuleAction) proto=\(.Protocol) cidr=\(.CidrBlock) ports=\(.PortRange.From // "all")-\(.PortRange.To // "all")"'

echo "=== Destination subnet NACL (if known) ==="
if [ -n "$DST_SUBNET_ID" ]; then
  DST_NACL=$(aws ec2 describe-network-acls --region $REGION \
    --filters Name=association.subnet-id,Values=$DST_SUBNET_ID \
    --query 'NetworkAcls[0].NetworkAclId' --output text 2>/dev/null)
  echo "NACL: $DST_NACL"
  aws ec2 describe-network-acls --region $REGION --network-acl-ids $DST_NACL \
    --query 'NetworkAcls[0].Entries[]' --output json 2>/dev/null | jq -r 'sort_by(.RuleNumber) | .[] | "\(.Egress|if . then "OUTBOUND" else "INBOUND" end) rule=\(.RuleNumber) action=\(.RuleAction) proto=\(.Protocol) cidr=\(.CidrBlock) ports=\(.PortRange.From // "all")-\(.PortRange.To // "all")"'
fi
```

Flag:

- NACL deny rules matching the traffic before an allow rule (lower rule number = higher priority).
- NACLs are **stateless**: both inbound AND outbound rules must allow traffic + return traffic (ephemeral ports).
- Missing outbound allow for ephemeral ports (1024–65535) on the destination NACL.

---

## Step 6 — NAT Gateway, Internet Gateway, VPC Endpoints

// turbo

```bash
echo "=== Internet Gateway ==="
aws ec2 describe-internet-gateways --region $REGION \
  --filters Name=attachment.vpc-id,Values=$SRC_VPC_ID \
  --query 'InternetGateways[].{Id:InternetGatewayId,State:Attachments[0].State}' \
  --output table 2>/dev/null

echo "=== NAT Gateways in VPC ==="
aws ec2 describe-nat-gateways --region $REGION \
  --filter Name=vpc-id,Values=$SRC_VPC_ID Name=state,Values=available \
  --query 'NatGateways[].{Id:NatGatewayId,SubnetId:SubnetId,PublicIp:NatGatewayAddresses[0].PublicIp,State:State}' \
  --output table 2>/dev/null

echo "=== VPC Endpoints ==="
aws ec2 describe-vpc-endpoints --region $REGION \
  --filters Name=vpc-id,Values=$SRC_VPC_ID \
  --query 'VpcEndpoints[].{Id:VpcEndpointId,Service:ServiceName,Type:VpcEndpointType,State:State,RouteTableIds:RouteTableIds,SubnetIds:SubnetIds}' \
  --output json 2>/dev/null | jq -r '.[] | "\(.Id) \(.Service) type=\(.Type) state=\(.State)"'
```

Flag:

- Private subnet routing to IGW instead of NAT → traffic won't work for internet-bound flows.
- NAT Gateway in a different AZ from the source → cross-AZ data charges.
- Missing VPC endpoint for AWS service destinations (S3, DynamoDB, etc.) → traffic goes via NAT/IGW.
- VPC endpoint not in the correct subnet or route table.

---

## Step 7 — DNS resolution

// turbo

```bash
echo "=== VPC DNS settings ==="
aws ec2 describe-vpc-attribute --region $REGION --vpc-id $SRC_VPC_ID --attribute enableDnsSupport
aws ec2 describe-vpc-attribute --region $REGION --vpc-id $SRC_VPC_ID --attribute enableDnsHostnames

echo "=== Route 53 private hosted zones for this VPC ==="
aws route53 list-hosted-zones-by-vpc --vpc-id $SRC_VPC_ID --vpc-region $REGION \
  --query 'HostedZoneSummaries[].{Id:HostedZoneId,Name:Name}' --output table 2>/dev/null || echo "No private hosted zones or no permission"

echo "=== Route 53 resolver endpoints ==="
aws route53resolver list-resolver-endpoints --region $REGION \
  --query 'ResolverEndpoints[].{Id:Id,Name:Name,Direction:Direction,Status:Status,IpAddressCount:IpAddressCount}' \
  --output table 2>/dev/null || echo "No resolver endpoints or no permission"

echo "=== External DNS resolution ==="
if echo "$DESTINATION" | grep -qE '[a-zA-Z]'; then
  dig +short "$DESTINATION" 2>/dev/null || nslookup "$DESTINATION" 2>/dev/null || echo "Cannot resolve from this machine"
fi
```

Flag:

- `enableDnsSupport` or `enableDnsHostnames` disabled.
- Destination hostname not resolvable.
- Missing private hosted zone association for cross-VPC DNS.

---

## Step 8 — VPC Flow Logs (if available)

```bash
echo "=== VPC Flow Log configuration ==="
aws ec2 describe-flow-logs --region $REGION \
  --filter Name=resource-id,Values=$SRC_VPC_ID \
  --query 'FlowLogs[].{Id:FlowLogId,Status:FlowLogStatus,Destination:LogDestinationType,LogGroup:LogGroupName,TrafficType:TrafficType}' \
  --output table 2>/dev/null

echo "=== Sample rejected flows (last 1h, if CloudWatch destination) ==="
FLOW_LOG_GROUP=$(aws ec2 describe-flow-logs --region $REGION \
  --filter Name=resource-id,Values=$SRC_VPC_ID Name=log-destination-type,Values=cloud-watch-logs \
  --query 'FlowLogs[0].LogGroupName' --output text 2>/dev/null)
if [ -n "$FLOW_LOG_GROUP" ] && [ "$FLOW_LOG_GROUP" != "None" ]; then
  aws logs filter-log-events --region $REGION \
    --log-group-name "$FLOW_LOG_GROUP" \
    --filter-pattern "REJECT" \
    --start-time $(($(date +%s) - 3600))000 \
    --limit 30 \
    --query 'events[].message' --output text 2>/dev/null | head -30
else
  echo "No CloudWatch-based flow logs found for this VPC"
fi
```

Flag:

- REJECT entries matching the source/destination pair.
- No flow logs configured (cannot diagnose historically).

---

## Step 9 — Connection summary and diagnosis

Based on all findings, the agent should produce a clear path analysis:

```
Source (instance/ENI/IP)
  → Source Security Group (egress)
  → Source NACL (outbound)
  → Route Table (next hop)
  → [NAT Gateway / IGW / TGW / Peering / VPC Endpoint]
  → Destination NACL (inbound)
  → Destination Security Group (ingress)
  → Destination (instance/ENI/RDS/ALB)
```

For each hop, indicate ✅ PASS or ❌ BLOCKED with the specific rule or reason.

---

## Step 10 — Generate report

Compile all findings into a timestamped Markdown report:

```
$REPORT_DIR/aws-vpc-debug-<source>-<dest>-<port>-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# AWS VPC Connectivity Debug Report

| Field | Value |
|---|---|
| Generated | <timestamp> |
| Account | <account-id> |
| Region | <region> |
| Source | <source-id> / <source-ip> |
| Destination | <dest> / <dest-ip> |
| Port/Protocol | <port>/<protocol> |

## Verdict
<✅ Traffic should flow / ❌ Traffic is blocked at <component>>

## Path analysis
<hop-by-hop table with pass/block status>

## Findings
### Security Groups
### Network ACLs
### Route Tables
### NAT / IGW / TGW
### VPC Endpoints
### DNS
### Flow Logs

## Recommended fix
<specific remediation steps>
```

---

## Safety rules

- Every command is **read-only**. No security groups, NACLs, routes, or resources are modified.
- Never print secret values. Only resource IDs, CIDRs, ports, and rule metadata.
- If a command fails due to IAM permissions, record the failure and continue.
- VPC Flow Log queries are read-only but may be slow on large log groups; the workflow limits results to 30 entries.
