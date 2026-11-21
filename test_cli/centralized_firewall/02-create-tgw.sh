#!/bin/bash
set -euo pipefail
source tgw-lab.env

echo "=== 2. Creating Dedicated TGW Subnets & Transit Gateway ==="

# Detect the Availability Zone of Subnet A so TGW attachments stay AZ-aligned
AZ_NAME=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_A_ID" --query 'Subnets[0].AvailabilityZone' --output text)

# 1. Create Dedicated TGW Attachment Subnets (/28) in VPC A and VPC B
TGW_SUBNET_A_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_A_ID" \
  --cidr-block 10.1.255.0/28 \
  --availability-zone "$AZ_NAME" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=TGW-Att-Subnet-A}]' \
  --query 'Subnet.SubnetId' --output text)

TGW_SUBNET_B_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_B_ID" \
  --cidr-block 10.2.255.0/28 \
  --availability-zone "$AZ_NAME" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=TGW-Att-Subnet-B}]' \
  --query 'Subnet.SubnetId' --output text)

# 2. Create Transit Gateway
TGW_ID=$(aws ec2 create-transit-gateway \
  --description "TGW-Custom-Routing" \
  --options DefaultRouteTableAssociation=disable,DefaultRouteTablePropagation=disable \
  --tag-specifications 'ResourceType=transit-gateway,Tags=[{Key=Name,Value=My-Custom-TGW}]' \
  --query 'TransitGateway.TransitGatewayId' --output text)

echo "Waiting for Transit Gateway ($TGW_ID) to become available..."
while [ "$(aws ec2 describe-transit-gateways --transit-gateway-ids "$TGW_ID" --query 'TransitGateways[0].State' --output text)" != "available" ]; do
  sleep 10
done

# 3. Attach VPC A and VPC B using the Dedicated TGW Subnets
echo "Attaching VPC A and VPC B to Transit Gateway via dedicated subnets..."
TGW_ATT_A_ID=$(aws ec2 create-transit-gateway-vpc-attachment \
  --transit-gateway-id "$TGW_ID" \
  --vpc-id "$VPC_A_ID" \
  --subnet-ids "$TGW_SUBNET_A_ID" \
  --tag-specifications 'ResourceType=transit-gateway-attachment,Tags=[{Key=Name,Value=TGW-Att-VPC-A}]' \
  --query 'TransitGatewayVpcAttachment.TransitGatewayAttachmentId' --output text)

TGW_ATT_B_ID=$(aws ec2 create-transit-gateway-vpc-attachment \
  --transit-gateway-id "$TGW_ID" \
  --vpc-id "$VPC_B_ID" \
  --subnet-ids "$TGW_SUBNET_B_ID" \
  --tag-specifications 'ResourceType=transit-gateway-attachment,Tags=[{Key=Name,Value=TGW-Att-VPC-B}]' \
  --query 'TransitGatewayVpcAttachment.TransitGatewayAttachmentId' --output text)

echo "Waiting for TGW Attachments to become available..."
while [ "$(aws ec2 describe-transit-gateway-vpc-attachments --transit-gateway-attachment-ids "$TGW_ATT_A_ID" --query 'TransitGatewayVpcAttachments[0].State' --output text)" != "available" ] || \
      [ "$(aws ec2 describe-transit-gateway-vpc-attachments --transit-gateway-attachment-ids "$TGW_ATT_B_ID" --query 'TransitGatewayVpcAttachments[0].State' --output text)" != "available" ]; do
  sleep 10
done

# 4. Create Spoke TGW Route Table & Associate Spoke Attachments
echo "Creating Spoke TGW Route Table..."
TGW_SHARED_RTB_ID=$(aws ec2 create-transit-gateway-route-table \
  --transit-gateway-id "$TGW_ID" \
  --tag-specifications 'ResourceType=transit-gateway-route-table,Tags=[{Key=Name,Value=TGW-Spoke-RTB}]' \
  --query 'TransitGatewayRouteTable.TransitGatewayRouteTableId' --output text)

while [ "$(aws ec2 describe-transit-gateway-route-tables --transit-gateway-route-table-ids "$TGW_SHARED_RTB_ID" --query 'TransitGatewayRouteTables[0].State' --output text)" != "available" ]; do
  sleep 5
done

aws ec2 associate-transit-gateway-route-table --transit-gateway-route-table-id "$TGW_SHARED_RTB_ID" --transit-gateway-attachment-id "$TGW_ATT_A_ID" > /dev/null
aws ec2 associate-transit-gateway-route-table --transit-gateway-route-table-id "$TGW_SHARED_RTB_ID" --transit-gateway-attachment-id "$TGW_ATT_B_ID" > /dev/null

# 5. Update Spoke VPC Main Route Tables (Workload Subnets -> TGW)
RTB_A_ID=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_A_ID" "Name=association.main,Values=true" --query 'RouteTables[0].RouteTableId' --output text)
aws ec2 create-route --route-table-id "$RTB_A_ID" --destination-cidr-block 10.2.0.0/16 --transit-gateway-id "$TGW_ID" > /dev/null

RTB_B_ID=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_B_ID" "Name=association.main,Values=true" --query 'RouteTables[0].RouteTableId' --output text)
aws ec2 create-route --route-table-id "$RTB_B_ID" --destination-cidr-block 10.1.0.0/16 --transit-gateway-id "$TGW_ID" > /dev/null

# Save variables cleanly to tgw-lab.env
sed -i '/^\(AZ_NAME\|TGW_SUBNET_A_ID\|TGW_SUBNET_B_ID\|TGW_ID\|TGW_ATT_A_ID\|TGW_ATT_B_ID\|TGW_SHARED_RTB_ID\)=/d' tgw-lab.env
cat <<EOF >> tgw-lab.env
AZ_NAME=$AZ_NAME
TGW_SUBNET_A_ID=$TGW_SUBNET_A_ID
TGW_SUBNET_B_ID=$TGW_SUBNET_B_ID
TGW_ID=$TGW_ID
TGW_ATT_A_ID=$TGW_ATT_A_ID
TGW_ATT_B_ID=$TGW_ATT_B_ID
TGW_SHARED_RTB_ID=$TGW_SHARED_RTB_ID
EOF

echo "Dedicated TGW subnets and Transit Gateway configured successfully."
