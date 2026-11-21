#!/bin/bash
set -e
source tgw-lab.env

echo "=== 4. Running Ping Test from EC2-VPC-A ($EC2_A_IP) to EC2-VPC-B ($EC2_B_IP) ==="

echo "Waiting for EC2-VPC-A ($EC2_A_ID) to come online in SSM..."
while [ "$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$EC2_A_ID" --query 'InstanceInformationList[0].PingStatus' --output text)" != "Online" ]; do
  sleep 10
done

echo "Sending ping command via SSM Run Command..."
CMD_ID=$(aws ssm send-command \
  --instance-ids $EC2_A_ID \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[\"ping -c 4 $EC2_B_IP\"]" \
  --query 'Command.CommandId' --output text)

sleep 5

aws ssm get-command-invocation \
  --command-id $CMD_ID \
  --instance-id $EC2_A_ID \
  --query '[Status, StandardOutputContent, StandardErrorContent]' \
  --output text
