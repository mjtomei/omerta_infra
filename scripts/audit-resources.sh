#!/bin/bash
# Audit all AWS resources created by omerta-infra
# Run this monthly to check for orphaned resources
set -e

REGION="${AWS_REGION:-us-west-2}"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║           Omerta AWS Resource Audit                        ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Region: $REGION"
echo "Looking for resources tagged with Project=omerta"
echo ""

echo "=== EC2 Instances ==="
aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:Project,Values=omerta" \
  --query 'Reservations[].Instances[?State.Name!=`terminated`].[InstanceId,InstanceType,State.Name,Tags[?Key==`Name`].Value|[0]]' \
  --output table 2>/dev/null || echo "  (none or no access)"
echo ""

echo "=== Elastic IPs ==="
aws ec2 describe-addresses \
  --region "$REGION" \
  --filters "Name=tag:Project,Values=omerta" \
  --query 'Addresses[].[PublicIp,InstanceId,Tags[?Key==`Name`].Value|[0]]' \
  --output table 2>/dev/null || echo "  (none or no access)"
echo ""

echo "=== Unattached Elastic IPs (costs \$3.65/month each!) ==="
aws ec2 describe-addresses \
  --region "$REGION" \
  --filters "Name=tag:Project,Values=omerta" \
  --query 'Addresses[?InstanceId==`null`].[PublicIp,AllocationId]' \
  --output table 2>/dev/null || echo "  (none)"
echo ""

echo "=== Security Groups ==="
aws ec2 describe-security-groups \
  --region "$REGION" \
  --filters "Name=tag:Project,Values=omerta" \
  --query 'SecurityGroups[].[GroupId,GroupName]' \
  --output table 2>/dev/null || echo "  (none or no access)"
echo ""

echo "=== EBS Snapshots (from DLM backups) ==="
aws ec2 describe-snapshots \
  --region "$REGION" \
  --owner-ids self \
  --filters "Name=tag:Project,Values=omerta" \
  --query 'Snapshots[].[SnapshotId,VolumeSize,StartTime,Description]' \
  --output table 2>/dev/null || echo "  (none or no access)"
echo ""

echo "=== Route53 Hosted Zones ==="
aws route53 list-hosted-zones \
  --query 'HostedZones[].[Name,Id]' \
  --output table 2>/dev/null || echo "  (none or no access)"
echo ""

echo "=== SNS Topics ==="
aws sns list-topics \
  --region "$REGION" \
  --query 'Topics[?contains(TopicArn, `omerta`)].[TopicArn]' \
  --output table 2>/dev/null || echo "  (none or no access)"
echo ""

echo "=== CloudWatch Alarms ==="
aws cloudwatch describe-alarms \
  --region "$REGION" \
  --alarm-name-prefix "omerta-" \
  --query 'MetricAlarms[].[AlarmName,StateValue]' \
  --output table 2>/dev/null || echo "  (none or no access)"
echo ""

echo "=== DLM Lifecycle Policies ==="
aws dlm describe-lifecycle-policies \
  --region "$REGION" \
  --query 'Policies[].[PolicyId,Description,State]' \
  --output table 2>/dev/null || echo "  (none or no access)"
echo ""

echo "=== IAM Roles (omerta-*) ==="
aws iam list-roles \
  --query 'Roles[?starts_with(RoleName, `omerta-`)].[RoleName,CreateDate]' \
  --output table 2>/dev/null || echo "  (none or no access)"
echo ""

echo "=== All Resources by Tag ==="
aws resourcegroupstaggingapi get-resources \
  --region "$REGION" \
  --tag-filters Key=Project,Values=omerta \
  --query 'ResourceTagMappingList[].[ResourceARN]' \
  --output table 2>/dev/null || echo "  (none or no access)"
echo ""

echo "════════════════════════════════════════════════════════════"
echo "To destroy all resources: cd terraform/environments/prod && terraform destroy"
echo "════════════════════════════════════════════════════════════"
