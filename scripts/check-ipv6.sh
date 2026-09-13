#!/usr/bin/env bash
# Diagnose EC2 IPv6 egress: ENI address, VPC/subnet IPv6 CIDR, route table, EOIGW/IGW, security group.
# Run on the EC2 instance itself. Requires `aws` CLI with EC2 describe permissions
# (instance profile or configured credentials) — no credentials needed for the IMDS calls.
set -uo pipefail

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
echo "Instance: $INSTANCE_ID  Region: $REGION"

echo "=== IMDS: does the primary ENI have an IPv6 address? ==="
MAC=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/mac)
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/network/interfaces/macs/$MAC/ipv6s"; echo

echo "=== OS-level: interface + routes ==="
ip -6 addr
ip -6 route

echo "=== AWS: instance -> subnet -> VPC ==="
aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
  --query 'Reservations[0].Instances[0].{VpcId:VpcId,SubnetId:SubnetId,SecurityGroups:SecurityGroups,Ipv6Addresses:NetworkInterfaces[0].Ipv6Addresses}'

SUBNET_ID=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" --query 'Reservations[0].Instances[0].SubnetId' --output text)
VPC_ID=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" --query 'Reservations[0].Instances[0].VpcId' --output text)

echo "=== VPC IPv6 CIDR associations ==="
aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$REGION" --query 'Vpcs[0].Ipv6CidrBlockAssociationSet'

echo "=== Subnet IPv6 config ==="
aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --region "$REGION" \
  --query 'Subnets[0].{Ipv6CidrBlockAssociationSet:Ipv6CidrBlockAssociationSet,AssignIpv6AddressOnCreation:AssignIpv6AddressOnCreation}'

echo "=== Route table for this subnet (looking for ::/0) ==="
RTB_ID=$(aws ec2 describe-route-tables --region "$REGION" --filters "Name=association.subnet-id,Values=$SUBNET_ID" --query 'RouteTables[0].RouteTableId' --output text)
if [ "$RTB_ID" = "None" ]; then
  RTB_ID=$(aws ec2 describe-route-tables --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" --query 'RouteTables[0].RouteTableId' --output text)
fi
echo "Route table: $RTB_ID"
aws ec2 describe-route-tables --route-table-ids "$RTB_ID" --region "$REGION" --query 'RouteTables[0].Routes'

echo "=== Egress-only internet gateways in this VPC ==="
aws ec2 describe-egress-only-internet-gateways --region "$REGION" \
  --query "EgressOnlyInternetGateways[?Attachments[?VpcId=='$VPC_ID']]"

echo "=== Internet gateway attached to this VPC ==="
aws ec2 describe-internet-gateways --region "$REGION" \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[0].InternetGatewayId'

echo "=== Security group outbound rules (looking for ::/0 egress) ==="
SG_IDS=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text)
aws ec2 describe-security-groups --group-ids $SG_IDS --region "$REGION" --query 'SecurityGroups[].{GroupId:GroupId,Egress:IpPermissionsEgress}'
