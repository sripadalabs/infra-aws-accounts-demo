#!/bin/bash
set -e
source tgw-lab.env

echo "=== 2. Creating Transit Gateway (Custom Route Table) ==="

TGW_ID=$(aws ec2 create-transit-gateway \
  --description "TGW-Custom-Routing" \
  --options DefaultRouteTableAssociation=disable,DefaultRouteTablePropagation=disable \
  --tag-specifications 'ResourceType=transit-gateway,Tags=[{Key=Name,Value=My-Custom-TGW}]' \
  --query 'TransitGateway.TransitGatewayId' --output text)

echo "Waiting for Transit Gateway ($TGW_ID) to become available..."
while [ "$(aws ec2 describe-transit-gateways --transit-gateway-ids $TGW_ID --query 'TransitGateways[0].State' --output text)" != "available" ]; do
  sleep 10
done

echo "Attaching VPC A and VPC B to Transit Gateway..."
TGW_ATT_A_ID=$(aws ec2 create-transit-gateway-vpc-attachment \
  --transit-gateway-id $TGW_ID --vpc-id $VPC_A_ID --subnet-ids $SUBNET_A_ID \
  --tag-specifications 'ResourceType=transit-gateway-attachment,Tags=[{Key=Name,Value=TGW-Att-VPC-A}]' \
  --query 'TransitGatewayVpcAttachment.TransitGatewayAttachmentId' --output text)

TGW_ATT_B_ID=$(aws ec2 create-transit-gateway-vpc-attachment \
  --transit-gateway-id $TGW_ID --vpc-id $VPC_B_ID --subnet-ids $SUBNET_B_ID \
  --tag-specifications 'ResourceType=transit-gateway-attachment,Tags=[{Key=Name,Value=TGW-Att-VPC-B}]' \
  --query 'TransitGatewayVpcAttachment.TransitGatewayAttachmentId' --output text)

echo "Waiting for TGW Attachments to become available..."
while [ "$(aws ec2 describe-transit-gateway-vpc-attachments --transit-gateway-attachment-ids $TGW_ATT_A_ID --query 'TransitGatewayVpcAttachments[0].State' --output text)" != "available" ] || \
      [ "$(aws ec2 describe-transit-gateway-vpc-attachments --transit-gateway-attachment-ids $TGW_ATT_B_ID --query 'TransitGatewayVpcAttachments[0].State' --output text)" != "available" ]; do
  sleep 10
done

echo "Creating shared custom TGW Route Table..."
TGW_SHARED_RTB_ID=$(aws ec2 create-transit-gateway-route-table \
  --transit-gateway-id $TGW_ID \
  --tag-specifications 'ResourceType=transit-gateway-route-table,Tags=[{Key=Name,Value=TGW-Shared-RTB}]' \
  --query 'TransitGatewayRouteTable.TransitGatewayRouteTableId' --output text)

while [ "$(aws ec2 describe-transit-gateway-route-tables --transit-gateway-route-table-ids $TGW_SHARED_RTB_ID --query 'TransitGatewayRouteTables[0].State' --output text)" != "available" ]; do
  sleep 5
done

# Associate and Propagate both attachments
aws ec2 associate-transit-gateway-route-table --transit-gateway-route-table-id $TGW_SHARED_RTB_ID --transit-gateway-attachment-id $TGW_ATT_A_ID > /dev/null
aws ec2 associate-transit-gateway-route-table --transit-gateway-route-table-id $TGW_SHARED_RTB_ID --transit-gateway-attachment-id $TGW_ATT_B_ID > /dev/null
aws ec2 enable-transit-gateway-route-table-propagation --transit-gateway-route-table-id $TGW_SHARED_RTB_ID --transit-gateway-attachment-id $TGW_ATT_A_ID > /dev/null
aws ec2 enable-transit-gateway-route-table-propagation --transit-gateway-route-table-id $TGW_SHARED_RTB_ID --transit-gateway-attachment-id $TGW_ATT_B_ID > /dev/null

# Update VPC Route Tables
RTB_A_ID=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_A_ID" --query 'RouteTables[0].RouteTableId' --output text)
aws ec2 create-route --route-table-id $RTB_A_ID --destination-cidr-block 10.2.0.0/16 --transit-gateway-id $TGW_ID > /dev/null

RTB_B_ID=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_B_ID" --query 'RouteTables[0].RouteTableId' --output text)
aws ec2 create-route --route-table-id $RTB_B_ID --destination-cidr-block 10.1.0.0/16 --transit-gateway-id $TGW_ID > /dev/null

cat <<EOF >> tgw-lab.env
TGW_ID=$TGW_ID
TGW_ATT_A_ID=$TGW_ATT_A_ID
TGW_ATT_B_ID=$TGW_ATT_B_ID
TGW_SHARED_RTB_ID=$TGW_SHARED_RTB_ID
EOF

echo "Transit Gateway and routes configured successfully."
