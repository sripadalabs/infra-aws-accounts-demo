#!/bin/bash
set -e

echo "=== 1. Creating VPC A and VPC B ==="

VPC_A_ID=$(aws ec2 create-vpc --cidr-block 10.1.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=VPC-A}]' \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id $VPC_A_ID --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id $VPC_A_ID --enable-dns-hostnames '{"Value":true}'

SUBNET_A_ID=$(aws ec2 create-subnet --vpc-id $VPC_A_ID --cidr-block 10.1.1.0/24 \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=Subnet-A}]' \
  --query 'Subnet.SubnetId' --output text)

VPC_B_ID=$(aws ec2 create-vpc --cidr-block 10.2.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=VPC-B}]' \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id $VPC_B_ID --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id $VPC_B_ID --enable-dns-hostnames '{"Value":true}'

SUBNET_B_ID=$(aws ec2 create-subnet --vpc-id $VPC_B_ID --cidr-block 10.2.1.0/24 \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=Subnet-B}]' \
  --query 'Subnet.SubnetId' --output text)

# Save IDs for subsequent scripts
cat <<EOF > tgw-lab.env
VPC_A_ID=$VPC_A_ID
SUBNET_A_ID=$SUBNET_A_ID
VPC_B_ID=$VPC_B_ID
SUBNET_B_ID=$SUBNET_B_ID
EOF

echo "VPC A ($VPC_A_ID) and VPC B ($VPC_B_ID) created. IDs saved to tgw-lab.env."
