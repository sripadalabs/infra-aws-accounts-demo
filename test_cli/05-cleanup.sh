#!/bin/bash
set -euo pipefail

if [ ! -f tgw-lab.env ]; then
  echo "tgw-lab.env not found. Nothing to clean up."
  exit 0
fi

source tgw-lab.env

echo "=== 5. Cleaning Up All TGW Lab Resources ==="

# Helper function to retry deletion while AWS releases underlying ENIs
retry_delete() {
  local label="$1"
  shift
  for i in {1..12}; do
    if "$@" >/dev/null 2>&1; then
      echo "Deleted $label."
      return 0
    fi
    sleep 5
  done
  echo "Warning: Could not delete $label after 60s (may still have dependencies)."
}

# 1. Terminate EC2 Instances
EC2_IDS=()
[ -n "${EC2_A_ID:-}" ] && EC2_IDS+=("$EC2_A_ID")
[ -n "${EC2_B_ID:-}" ] && EC2_IDS+=("$EC2_B_ID")

if [ ${#EC2_IDS[@]} -gt 0 ]; then
  ACTIVE_EC2=$(aws ec2 describe-instances \
    --instance-ids "${EC2_IDS[@]}" \
    --filters "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
    --query 'Reservations[*].Instances[*].InstanceId' --output text 2>/dev/null || true)

  if [ -n "$ACTIVE_EC2" ] && [ "$ACTIVE_EC2" != "None" ]; then
    echo "Terminating EC2 instances ($ACTIVE_EC2)..."
    aws ec2 terminate-instances --instance-ids $ACTIVE_EC2 >/dev/null 2>&1 || true
    aws ec2 wait instance-terminated --instance-ids $ACTIVE_EC2 2>/dev/null || true
    echo "EC2 instances terminated."
  else
    echo "EC2 instances do not exist or are already terminated. Skipping..."
  fi
fi

# 2. Delete Interface VPC Endpoints (must be deleted before Security Groups & Subnets)
VPC_IDS=()
[ -n "${VPC_A_ID:-}" ] && VPC_IDS+=("$VPC_A_ID")
[ -n "${VPC_B_ID:-}" ] && VPC_IDS+=("$VPC_B_ID")

if [ ${#VPC_IDS[@]} -gt 0 ]; then
  echo "Checking for VPC Endpoints..."
  VPC_CSV=$(IFS=,; echo "${VPC_IDS[*]}")
  VPCE_IDS=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=$VPC_CSV" "Name=vpc-endpoint-state,Values=pending,available,deleting" \
    --query 'VpcEndpoints[*].VpcEndpointId' --output text 2>/dev/null || true)

  if [ -n "$VPCE_IDS" ] && [ "$VPCE_IDS" != "None" ]; then
    echo "Deleting VPC Endpoints ($VPCE_IDS)..."
    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $VPCE_IDS >/dev/null 2>&1 || true

    echo "Waiting for VPC Endpoints and their ENIs to fully delete..."
    while true; do
      REMAINING_VPCE=$(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=$VPC_CSV" "Name=vpc-endpoint-state,Values=pending,available,deleting" \
        --query 'VpcEndpoints[*].VpcEndpointId' --output text 2>/dev/null || true)
      [ -z "$REMAINING_VPCE" ] || [ "$REMAINING_VPCE" == "None" ] && break
      sleep 5
    done
    # Brief buffer for underlying Requester-Managed ENIs to detach
    sleep 10
  else
    echo "No active VPC Endpoints found. Skipping..."
  fi
fi

# 3. Delete Transit Gateway VPC Attachments
TGW_ATT_IDS=()
[ -n "${TGW_ATT_A_ID:-}" ] && TGW_ATT_IDS+=("$TGW_ATT_A_ID")
[ -n "${TGW_ATT_B_ID:-}" ] && TGW_ATT_IDS+=("$TGW_ATT_B_ID")

if [ ${#TGW_ATT_IDS[@]} -gt 0 ]; then
  EXISTING_ATTS=$(aws ec2 describe-transit-gateway-vpc-attachments \
    --transit-gateway-attachment-ids "${TGW_ATT_IDS[@]}" \
    --filters "Name=state,Values=pending,available,modifying,deleting" \
    --query 'TransitGatewayVpcAttachments[*].TransitGatewayAttachmentId' --output text 2>/dev/null || true)

  if [ -n "$EXISTING_ATTS" ] && [ "$EXISTING_ATTS" != "None" ]; then
    for ATT_ID in $EXISTING_ATTS; do
      echo "Deleting TGW Attachment ($ATT_ID)..."
      aws ec2 delete-transit-gateway-vpc-attachment --transit-gateway-attachment-id "$ATT_ID" >/dev/null 2>&1 || true
    done

    echo "Waiting for TGW Attachments to fully delete..."
    while true; do
      ACTIVE_ATTS=$(aws ec2 describe-transit-gateway-vpc-attachments \
        --transit-gateway-attachment-ids $EXISTING_ATTS \
        --filters "Name=state,Values=pending,available,modifying,deleting" \
        --query 'TransitGatewayVpcAttachments[*].TransitGatewayAttachmentId' --output text 2>/dev/null || true)
      [ -z "$ACTIVE_ATTS" ] || [ "$ACTIVE_ATTS" == "None" ] && break
      sleep 5
    done
  else
    echo "No active TGW Attachments found. Skipping..."
  fi
fi

# 4. Disassociate & Delete Custom Transit Gateway Route Table
if [ -n "${TGW_SHARED_RTB_ID:-}" ]; then
  RTB_STATE=$(aws ec2 describe-transit-gateway-route-tables \
    --transit-gateway-route-table-ids "$TGW_SHARED_RTB_ID" \
    --query 'TransitGatewayRouteTables[0].State' --output text 2>/dev/null || echo "deleted")

  if [ "$RTB_STATE" != "deleted" ] && [ "$RTB_STATE" != "None" ] && [ -n "$RTB_STATE" ]; then
    echo "Ensuring all associations are cleared on TGW Route Table ($TGW_SHARED_RTB_ID)..."
    ASSOC_ATTS=$(aws ec2 get-transit-gateway-route-table-associations \
      --transit-gateway-route-table-id "$TGW_SHARED_RTB_ID" \
      --query 'Associations[?State!=`disassociated`].TransitGatewayAttachmentId' --output text 2>/dev/null || true)

    if [ -n "$ASSOC_ATTS" ] && [ "$ASSOC_ATTS" != "None" ]; then
      for ATT_ID in $ASSOC_ATTS; do
        aws ec2 disassociate-transit-gateway-route-table \
          --transit-gateway-route-table-id "$TGW_SHARED_RTB_ID" \
          --transit-gateway-attachment-id "$ATT_ID" >/dev/null 2>&1 || true
      done
    fi

    # Wait until AWS fully drops all association records
    while true; do
      REMAINING_ASSOC=$(aws ec2 get-transit-gateway-route-table-associations \
        --transit-gateway-route-table-id "$TGW_SHARED_RTB_ID" \
        --query 'Associations[*].TransitGatewayAttachmentId' --output text 2>/dev/null || true)
      [ -z "$REMAINING_ASSOC" ] || [ "$REMAINING_ASSOC" == "None" ] && break
      sleep 3
    done

    echo "Deleting custom TGW Route Table ($TGW_SHARED_RTB_ID)..."
    aws ec2 delete-transit-gateway-route-table --transit-gateway-route-table-id "$TGW_SHARED_RTB_ID" >/dev/null 2>&1 || true
  else
    echo "Custom TGW Route Table ($TGW_SHARED_RTB_ID) does not exist or is already deleted. Skipping..."
  fi
fi

# 5. Delete Transit Gateway
if [ -n "${TGW_ID:-}" ]; then
  TGW_STATE=$(aws ec2 describe-transit-gateways \
    --transit-gateway-ids "$TGW_ID" \
    --query 'TransitGateways[0].State' --output text 2>/dev/null || echo "deleted")

  if [ "$TGW_STATE" != "deleted" ] && [ "$TGW_STATE" != "None" ] && [ -n "$TGW_STATE" ]; then
    echo "Deleting Transit Gateway ($TGW_ID)..."
    aws ec2 delete-transit-gateway --transit-gateway-id "$TGW_ID" >/dev/null 2>&1 || true
  else
    echo "Transit Gateway ($TGW_ID) does not exist or is already deleted. Skipping..."
  fi
fi

# 6. Delete Security Groups, Subnets, Custom VPC Route Tables, and VPCs
echo "Checking Security Groups, Subnets, and VPCs..."

for SG_ID in "${SG_A_ID:-}" "${SG_B_ID:-}"; do
  if [ -n "$SG_ID" ]; then
    EXISTS=$(aws ec2 describe-security-groups \
      --group-ids "$SG_ID" \
      --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
    if [ -n "$EXISTS" ] && [ "$EXISTS" != "None" ]; then
      retry_delete "Security Group ($SG_ID)" aws ec2 delete-security-group --group-id "$SG_ID"
    else
      echo "Security Group ($SG_ID) does not exist. Skipping..."
    fi
  fi
done

for SUBNET_ID in "${SUBNET_A_ID:-}" "${SUBNET_B_ID:-}"; do
  if [ -n "$SUBNET_ID" ]; then
    EXISTS=$(aws ec2 describe-subnets \
      --subnet-ids "$SUBNET_ID" \
      --query 'Subnets[0].SubnetId' --output text 2>/dev/null || true)
    if [ -n "$EXISTS" ] && [ "$EXISTS" != "None" ]; then
      retry_delete "Subnet ($SUBNET_ID)" aws ec2 delete-subnet --subnet-id "$SUBNET_ID"
    else
      echo "Subnet ($SUBNET_ID) does not exist. Skipping..."
    fi
  fi
done

for VPC_ID in "${VPC_IDS[@]}"; do
  VPC_EXISTS=$(aws ec2 describe-vpcs \
    --vpc-ids "$VPC_ID" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)
  if [ -n "$VPC_EXISTS" ] && [ "$VPC_EXISTS" != "None" ]; then
    CUSTOM_RTBS=$(aws ec2 describe-route-tables \
      --filters "Name=vpc-id,Values=$VPC_ID" \
      --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text 2>/dev/null || true)
    if [ -n "$CUSTOM_RTBS" ] && [ "$CUSTOM_RTBS" != "None" ]; then
      for RTB_ID in $CUSTOM_RTBS; do
        retry_delete "Custom Route Table ($RTB_ID)" aws ec2 delete-route-table --route-table-id "$RTB_ID"
      done
    fi
    retry_delete "VPC ($VPC_ID)" aws ec2 delete-vpc --vpc-id "$VPC_ID"
  else
    echo "VPC ($VPC_ID) does not exist. Skipping..."
  fi
done

# 7. Clean up IAM Role & Instance Profile (Independent checks for partial runs)
ROLE_NAME="TGW-Lab-SSM-Role"
echo "Checking IAM Role and Instance Profile ($ROLE_NAME)..."

if aws iam get-instance-profile --instance-profile-name "$ROLE_NAME" >/dev/null 2>&1; then
  ATTACHED_ROLES=$(aws iam get-instance-profile \
    --instance-profile-name "$ROLE_NAME" \
    --query 'InstanceProfile.Roles[*].RoleName' --output text 2>/dev/null || true)
  if echo "$ATTACHED_ROLES" | grep -qw "$ROLE_NAME"; then
    aws iam remove-role-from-instance-profile --instance-profile-name "$ROLE_NAME" --role-name "$ROLE_NAME" >/dev/null 2>&1 || true
  fi
  aws iam delete-instance-profile --instance-profile-name "$ROLE_NAME" >/dev/null 2>&1 || true
  echo "Deleted Instance Profile ($ROLE_NAME)."
else
  echo "Instance Profile ($ROLE_NAME) does not exist. Skipping..."
fi

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  POLICY_ARN="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  ATTACHED_POLICIES=$(aws iam list-attached-role-policies \
    --role-name "$ROLE_NAME" \
    --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null || true)
  if echo "$ATTACHED_POLICIES" | grep -qw "$POLICY_ARN"; then
    aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
  fi
  aws iam delete-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || true
  echo "Deleted IAM Role ($ROLE_NAME)."
else
  echo "IAM Role ($ROLE_NAME) does not exist. Skipping..."
fi

# Remove local environment state file
rm -f tgw-lab.env

echo "=== Cleanup complete! All resources have been removed. ==="
