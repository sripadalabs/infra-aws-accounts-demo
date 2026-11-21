#!/bin/bash
set -euo pipefail

if [ ! -f tgw-lab.env ]; then
  echo "tgw-lab.env not found. Run scripts 1–3 first."
  exit 1
fi

source tgw-lab.env

echo "=== 4. Creating Centralized Inspection VPC & AWS Network Firewall ==="

# 1. Create Inspection VPC & Dedicated Subnets (TGW Subnet + Firewall Subnet)
INSP_VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.100.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=Inspection-VPC}]' \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id "$INSP_VPC_ID" --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id "$INSP_VPC_ID" --enable-dns-hostnames '{"Value":true}'

INSP_TGW_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$INSP_VPC_ID" \
  --cidr-block 10.100.1.0/28 \
  --availability-zone "$AZ_NAME" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=Inspection-TGW-Subnet}]' \
  --query 'Subnet.SubnetId' --output text)

INSP_FW_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$INSP_VPC_ID" \
  --cidr-block 10.100.2.0/28 \
  --availability-zone "$AZ_NAME" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=Inspection-Firewall-Subnet}]' \
  --query 'Subnet.SubnetId' --output text)

# 2. Attach Inspection VPC to Transit Gateway (Appliance Mode ENABLED for stateful symmetry)
echo "Attaching Inspection VPC to Transit Gateway with Appliance Mode enabled..."
TGW_ATT_INSP_ID=$(aws ec2 create-transit-gateway-vpc-attachment \
  --transit-gateway-id "$TGW_ID" \
  --vpc-id "$INSP_VPC_ID" \
  --subnet-ids "$INSP_TGW_SUBNET_ID" \
  --options ApplianceModeSupport=enable \
  --tag-specifications 'ResourceType=transit-gateway-attachment,Tags=[{Key=Name,Value=TGW-Att-Inspection-VPC}]' \
  --query 'TransitGatewayVpcAttachment.TransitGatewayAttachmentId' --output text)

while [ "$(aws ec2 describe-transit-gateway-vpc-attachments --transit-gateway-attachment-ids "$TGW_ATT_INSP_ID" --query 'TransitGatewayVpcAttachments[0].State' --output text)" != "available" ]; do
  sleep 10
done

# 3. Create Stateful Rule Group (Strict Source & Destination CIDR Allowlist)
RG_NAME="TGW-Lab-CIDR-Allowlist-RG"
echo "Creating Stateful Rule Group ($RG_NAME)..."
RG_ARN=$(aws network-firewall create-rule-group \
  --rule-group-name "$RG_NAME" \
  --type STATEFUL \
  --capacity 100 \
  --description "Only allow explicitly matched Source and Destination VPC CIDRs" \
  --rule-group '{
    "StatefulRuleOptions": {
      "RuleOrder": "STRICT_ORDER"
    },
    "RulesSource": {
      "StatefulRules": [
        {
          "Action": "PASS",
          "Header": {
            "Protocol": "IP",
            "Source": "10.1.0.0/16",
            "SourcePort": "ANY",
            "Direction": "FORWARD",
            "Destination": "10.2.0.0/16",
            "DestinationPort": "ANY"
          },
          "RuleOptions": [
            { "Keyword": "sid", "Settings": ["100"] }
          ]
        },
        {
          "Action": "PASS",
          "Header": {
            "Protocol": "IP",
            "Source": "10.2.0.0/16",
            "SourcePort": "ANY",
            "Direction": "FORWARD",
            "Destination": "10.1.0.0/16",
            "DestinationPort": "ANY"
          },
          "RuleOptions": [
            { "Keyword": "sid", "Settings": ["101"] }
          ]
        }
      ]
    }
  }' \
  --query 'RuleGroupResponse.RuleGroupArn' --output text)

# 4. Create Firewall Policy (Forward all stateless packets to stateful engine; drop unmatched)
POLICY_NAME="TGW-Lab-Inspection-Policy"
echo "Creating Firewall Policy ($POLICY_NAME)..."
POLICY_ARN=$(aws network-firewall create-firewall-policy \
  --firewall-policy-name "$POLICY_NAME" \
  --description "Strict CIDR inspection policy for Centralized Inspection VPC" \
  --firewall-policy "{
    \"StatelessDefaultActions\": [\"aws:forward_to_sfe\"],
    \"StatelessFragmentDefaultActions\": [\"aws:forward_to_sfe\"],
    \"StatefulEngineOptions\": {
      \"RuleOrder\": \"STRICT_ORDER\"
    },
    \"StatefulDefaultActions\": [\"aws:drop_strict\"],
    \"StatefulRuleGroupReferences\": [
      {
        \"ResourceArn\": \"$RG_ARN\",
        \"Priority\": 10
      }
    ]
  }" \
  --query 'FirewallPolicyResponse.FirewallPolicyArn' --output text)

# 5. Deploy AWS Network Firewall into the Dedicated Firewall Subnet
FW_NAME="TGW-Lab-Firewall"
echo "Creating Network Firewall ($FW_NAME) in Firewall Subnet ($INSP_FW_SUBNET_ID)..."
FW_ARN=$(aws network-firewall create-firewall \
  --firewall-name "$FW_NAME" \
  --firewall-policy-arn "$POLICY_ARN" \
  --vpc-id "$INSP_VPC_ID" \
  --subnet-mappings SubnetId="$INSP_FW_SUBNET_ID" \
  --no-delete-protection \
  --query 'Firewall.FirewallArn' --output text)

echo "Waiting for Network Firewall ($FW_NAME) and its VPC Endpoint to reach READY state (~3–5 mins)..."
while true; do
  FW_STATUS=$(aws network-firewall describe-firewall \
    --firewall-name "$FW_NAME" \
    --query 'FirewallStatus.Status' --output text)
  [ "$FW_STATUS" == "READY" ] && break
  sleep 15
done

# Extract the Network Firewall VPC Endpoint ID (vpce-...) created in INSP_FW_SUBNET_ID
FW_VPCE_ID=$(aws network-firewall describe-firewall \
  --firewall-name "$FW_NAME" \
  --query "FirewallStatus.SyncStates.\"$AZ_NAME\".Attachment.EndpointId" --output text)

echo "Network Firewall VPC Endpoint ready: $FW_VPCE_ID"

# 6. Configure Separate VPC Route Tables in Inspection VPC (Prevents Routing Loops)
echo "Configuring Inspection VPC Subnet Route Tables..."

# Route Table A: Attached to Inspection TGW Subnet -> Sends all traffic to Firewall VPC Endpoint
INSP_TGW_RTB_ID=$(aws ec2 create-route-table \
  --vpc-id "$INSP_VPC_ID" \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=Inspection-TGW-Subnet-RTB}]' \
  --query 'RouteTable.RouteTableId' --output text)

aws ec2 associate-route-table \
  --route-table-id "$INSP_TGW_RTB_ID" \
  --subnet-id "$INSP_TGW_SUBNET_ID" > /dev/null

aws ec2 create-route \
  --route-table-id "$INSP_TGW_RTB_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --vpc-endpoint-id "$FW_VPCE_ID" > /dev/null

# Route Table B: Attached to Inspection Firewall Subnet -> Sends inspected traffic back to Transit Gateway
INSP_FW_RTB_ID=$(aws ec2 create-route-table \
  --vpc-id "$INSP_VPC_ID" \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=Inspection-FW-Subnet-RTB}]' \
  --query 'RouteTable.RouteTableId' --output text)

aws ec2 associate-route-table \
  --route-table-id "$INSP_FW_RTB_ID" \
  --subnet-id "$INSP_FW_SUBNET_ID" > /dev/null

aws ec2 create-route \
  --route-table-id "$INSP_FW_RTB_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --transit-gateway-id "$TGW_ID" > /dev/null

# 7. Configure Two-Hop Transit Gateway Route Tables
echo "Configuring Transit Gateway Spoke & Post-Inspection Route Tables..."

# Spoke TGW Route Table (TGW_SHARED_RTB_ID): Send spoke traffic to Inspection VPC Attachment
aws ec2 create-transit-gateway-route \
  --transit-gateway-route-table-id "$TGW_SHARED_RTB_ID" \
  --destination-cidr-block 10.1.0.0/16 \
  --transit-gateway-attachment-id "$TGW_ATT_INSP_ID" > /dev/null

aws ec2 create-transit-gateway-route \
  --transit-gateway-route-table-id "$TGW_SHARED_RTB_ID" \
  --destination-cidr-block 10.2.0.0/16 \
  --transit-gateway-attachment-id "$TGW_ATT_INSP_ID" > /dev/null

# Post-Inspection TGW Route Table: Associated with Inspection VPC Attachment -> Routes to Spoke VPCs
TGW_INSP_RTB_ID=$(aws ec2 create-transit-gateway-route-table \
  --transit-gateway-id "$TGW_ID" \
  --tag-specifications 'ResourceType=transit-gateway-route-table,Tags=[{Key=Name,Value=TGW-Post-Inspection-RTB}]' \
  --query 'TransitGatewayRouteTable.TransitGatewayRouteTableId' --output text)

while [ "$(aws ec2 describe-transit-gateway-route-tables --transit-gateway-route-table-ids "$TGW_INSP_RTB_ID" --query 'TransitGatewayRouteTables[0].State' --output text)" != "available" ]; do
  sleep 5
done

aws ec2 associate-transit-gateway-route-table \
  --transit-gateway-route-table-id "$TGW_INSP_RTB_ID" \
  --transit-gateway-attachment-id "$TGW_ATT_INSP_ID" > /dev/null

aws ec2 create-transit-gateway-route \
  --transit-gateway-route-table-id "$TGW_INSP_RTB_ID" \
  --destination-cidr-block 10.1.0.0/16 \
  --transit-gateway-attachment-id "$TGW_ATT_A_ID" > /dev/null

aws ec2 create-transit-gateway-route \
  --transit-gateway-route-table-id "$TGW_INSP_RTB_ID" \
  --destination-cidr-block 10.2.0.0/16 \
  --transit-gateway-attachment-id "$TGW_ATT_B_ID" > /dev/null

# 8. Save All New Resource IDs to tgw-lab.env
sed -i '/^\(INSP_VPC_ID\|INSP_TGW_SUBNET_ID\|INSP_FW_SUBNET_ID\|TGW_ATT_INSP_ID\|FW_NAME\|FW_ARN\|POLICY_ARN\|RG_ARN\|FW_VPCE_ID\|INSP_TGW_RTB_ID\|INSP_FW_RTB_ID\|TGW_INSP_RTB_ID\)=/d' tgw-lab.env
cat <<EOF >> tgw-lab.env
INSP_VPC_ID=$INSP_VPC_ID
INSP_TGW_SUBNET_ID=$INSP_TGW_SUBNET_ID
INSP_FW_SUBNET_ID=$INSP_FW_SUBNET_ID
TGW_ATT_INSP_ID=$TGW_ATT_INSP_ID
FW_NAME=$FW_NAME
FW_ARN=$FW_ARN
POLICY_ARN=$POLICY_ARN
RG_ARN=$RG_ARN
FW_VPCE_ID=$FW_VPCE_ID
INSP_TGW_RTB_ID=$INSP_TGW_RTB_ID
INSP_FW_RTB_ID=$INSP_FW_RTB_ID
TGW_INSP_RTB_ID=$TGW_INSP_RTB_ID
EOF

echo "=== Centralized Inspection VPC & Network Firewall configured successfully! ==="
