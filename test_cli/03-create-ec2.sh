#!/bin/bash
set -euo pipefail

source tgw-lab.env
REGION=$(aws configure get region)

# Helper for idempotent Security Group Ingress Rules
add_ingress_rule() {
  local output
  if ! output=$(aws ec2 authorize-security-group-ingress "$@" 2>&1); then
    if [[ "$output" == *"InvalidPermission.Duplicate"* ]]; then
      echo "Ingress rule already exists, skipping."
    else
      echo "$output" >&2
      return 1
    fi
  fi
}

echo "=== 3. Creating Security Groups, IAM Role, SSM Endpoints & EC2 Instances ==="

# 1. Create or Fetch Security Groups
SG_A_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_A_ID" "Name=group-name,Values=SG-VPC-A" --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG_A_ID" == "None" ] || [ -z "$SG_A_ID" ]; then
  SG_A_ID=$(aws ec2 create-security-group --group-name SG-VPC-A --description "Allow ICMP and SSM" --vpc-id "$VPC_A_ID" --query 'GroupId' --output text)
fi
add_ingress_rule --group-id "$SG_A_ID" --protocol icmp --port -1 --cidr 10.2.0.0/16
add_ingress_rule --group-id "$SG_A_ID" --protocol tcp --port 443 --cidr 10.1.0.0/16

SG_B_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_B_ID" "Name=group-name,Values=SG-VPC-B" --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG_B_ID" == "None" ] || [ -z "$SG_B_ID" ]; then
  SG_B_ID=$(aws ec2 create-security-group --group-name SG-VPC-B --description "Allow ICMP and SSM" --vpc-id "$VPC_B_ID" --query 'GroupId' --output text)
fi
add_ingress_rule --group-id "$SG_B_ID" --protocol icmp --port -1 --cidr 10.1.0.0/16
add_ingress_rule --group-id "$SG_B_ID" --protocol tcp --port 443 --cidr 10.2.0.0/16

# 2. Create IAM Role & Instance Profile for SSM
ROLE_NAME="TGW-Lab-SSM-Role"
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' > /dev/null
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

if ! aws iam get-instance-profile --instance-profile-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$ROLE_NAME" > /dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$ROLE_NAME" --role-name "$ROLE_NAME"
  echo "Waiting 10s for IAM Instance Profile propagation..."
  sleep 10
fi

# 3. Create VPC Endpoints for SSM (Only if they don't already exist)
for SVC in ssm ssmmessages ec2messages; do
  SVC_NAME="com.amazonaws.$REGION.$SVC"

  EP_A=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_A_ID" "Name=service-name,Values=$SVC_NAME" "Name=vpc-endpoint-state,Values=pending,available" --query 'VpcEndpoints[0].VpcEndpointId' --output text)
  if [ "$EP_A" == "None" ] || [ -z "$EP_A" ]; then
    aws ec2 create-vpc-endpoint --vpc-id "$VPC_A_ID" --vpc-endpoint-type Interface \
      --service-name "$SVC_NAME" --subnet-ids "$SUBNET_A_ID" \
      --security-group-ids "$SG_A_ID" --private-dns-enabled > /dev/null
  fi

  EP_B=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_B_ID" "Name=service-name,Values=$SVC_NAME" "Name=vpc-endpoint-state,Values=pending,available" --query 'VpcEndpoints[0].VpcEndpointId' --output text)
  if [ "$EP_B" == "None" ] || [ -z "$EP_B" ]; then
    aws ec2 create-vpc-endpoint --vpc-id "$VPC_B_ID" --vpc-endpoint-type Interface \
      --service-name "$SVC_NAME" --subnet-ids "$SUBNET_B_ID" \
      --security-group-ids "$SG_B_ID" --private-dns-enabled > /dev/null
  fi
done

# 4. Launch or Fetch Existing t2.micro Instances
AMI_ID=$(aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query 'Parameters[0].Value' --output text)

EC2_A_ID=$(aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC_A_ID" "Name=tag:Name,Values=EC2-VPC-A" "Name=instance-state-name,Values=pending,running" --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [ "$EC2_A_ID" == "None" ] || [ -z "$EC2_A_ID" ]; then
  EC2_A_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type t2.micro \
    --subnet-id "$SUBNET_A_ID" --security-group-ids "$SG_A_ID" \
    --iam-instance-profile Name="$ROLE_NAME" \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=EC2-VPC-A}]' \
    --query 'Instances[0].InstanceId' --output text)
fi

EC2_B_ID=$(aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC_B_ID" "Name=tag:Name,Values=EC2-VPC-B" "Name=instance-state-name,Values=pending,running" --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [ "$EC2_B_ID" == "None" ] || [ -z "$EC2_B_ID" ]; then
  EC2_B_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type t2.micro \
    --subnet-id "$SUBNET_B_ID" --security-group-ids "$SG_B_ID" \
    --iam-instance-profile Name="$ROLE_NAME" \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=EC2-VPC-B}]' \
    --query 'Instances[0].InstanceId' --output text)
fi

echo "Waiting for EC2 instances to enter 'running' state..."
aws ec2 wait instance-running --instance-ids "$EC2_A_ID" "$EC2_B_ID"

EC2_A_IP=$(aws ec2 describe-instances --instance-ids "$EC2_A_ID" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
EC2_B_IP=$(aws ec2 describe-instances --instance-ids "$EC2_B_ID" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

# 5. Update tgw-lab.env cleanly without duplicate entries
sed -i '/^\(SG_A_ID\|SG_B_ID\|EC2_A_ID\|EC2_B_ID\|EC2_A_IP\|EC2_B_IP\)=/d' tgw-lab.env
cat <<EOF >> tgw-lab.env
SG_A_ID=$SG_A_ID
SG_B_ID=$SG_B_ID
EC2_A_ID=$EC2_A_ID
EC2_B_ID=$EC2_B_ID
EC2_A_IP=$EC2_A_IP
EC2_B_IP=$EC2_B_IP
EOF

echo "EC2-VPC-A ($EC2_A_ID - $EC2_A_IP) and EC2-VPC-B ($EC2_B_ID - $EC2_B_IP) are running."
