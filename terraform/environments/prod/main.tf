# Production Rendezvous Servers
# Deploys multiple rendezvous servers for omerta.run subdomains
#
# CREDENTIALS: AWS credentials are sourced from environment variables:
#   - AWS_ACCESS_KEY_ID
#   - AWS_SECRET_ACCESS_KEY
#   - AWS_REGION (optional, defaults to us-east-1)
#
# See .env.example for required environment variables.

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Uncomment and configure for remote state
  # backend "s3" {
  #   bucket = "omerta-terraform-state"
  #   key    = "prod/rendezvous.tfstate"
  #   region = "us-east-1"
  # }
}

# AWS provider uses credentials from environment variables:
# AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION
provider "aws" {
  region = var.aws_region

  # Credentials are read from environment variables automatically.
  # DO NOT hardcode credentials here.
  #
  # The provider checks these sources in order:
  # 1. Environment variables (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)
  # 2. Shared credentials file (~/.aws/credentials)
  # 3. IAM role (if running on EC2)
}

# Data sources for default VPC (customize for production)
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# User data script to install dependencies and set up systemd service
locals {
  user_data = <<-EOF
    #!/bin/bash
    set -e

    # Update system
    dnf update -y

    # Install Swift dependencies
    dnf install -y git gcc-c++ libcurl-devel libuuid-devel libxml2-devel ncurses-devel

    # Create omerta user
    useradd -r -s /bin/false omerta || true

    # Create directories
    mkdir -p /opt/omerta /var/log/omerta
    chown omerta:omerta /opt/omerta /var/log/omerta

    # Create systemd service (binary will be deployed separately)
    cat > /etc/systemd/system/omerta-rendezvous.service <<'SERVICE'
    [Unit]
    Description=Omerta Rendezvous Server
    After=network.target

    [Service]
    Type=simple
    User=omerta
    Group=omerta
    ExecStart=/opt/omerta/omerta-rendezvous --port 8080 --stun-port 3478 --no-relay --log-level info
    Restart=always
    RestartSec=5
    StandardOutput=append:/var/log/omerta/rendezvous.log
    StandardError=append:/var/log/omerta/rendezvous.log

    [Install]
    WantedBy=multi-user.target
    SERVICE

    systemctl daemon-reload
    systemctl enable omerta-rendezvous

    echo "Setup complete. Deploy binary to /opt/omerta/omerta-rendezvous and start service."
  EOF
}

# Primary rendezvous server
module "rendezvous1" {
  source = "../../modules/rendezvous"

  name          = "omerta-rendezvous1-prod"
  vpc_id        = data.aws_vpc.default.id
  subnet_id     = data.aws_subnets.default.ids[0]
  ami_id        = data.aws_ami.amazon_linux_2023.id
  instance_type = var.instance_type
  key_name      = var.key_name
  volume_size   = 8
  create_eip    = true
  user_data     = local.user_data

  ssh_cidr_blocks = var.ssh_cidr_blocks

  tags = {
    Environment = "prod"
    Service     = "rendezvous"
    Domain      = "rendezvous1.omerta.run"
  }
}

# Secondary rendezvous server (different AZ for redundancy)
module "rendezvous2" {
  source = "../../modules/rendezvous"

  name          = "omerta-rendezvous2-prod"
  vpc_id        = data.aws_vpc.default.id
  subnet_id     = length(data.aws_subnets.default.ids) > 1 ? data.aws_subnets.default.ids[1] : data.aws_subnets.default.ids[0]
  ami_id        = data.aws_ami.amazon_linux_2023.id
  instance_type = var.instance_type
  key_name      = var.key_name
  volume_size   = 8
  create_eip    = true
  user_data     = local.user_data

  ssh_cidr_blocks = var.ssh_cidr_blocks

  tags = {
    Environment = "prod"
    Service     = "rendezvous"
    Domain      = "rendezvous2.omerta.run"
  }
}

# =============================================================================
# Route53 DNS Configuration
# =============================================================================

# Create hosted zone for omerta.run
# After creation, update Squarespace nameservers to point to Route53
resource "aws_route53_zone" "omerta" {
  name    = var.domain_name
  comment = "Managed by Terraform - Omerta infrastructure"

  tags = {
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}

# rendezvous1.omerta.run -> Primary rendezvous server
resource "aws_route53_record" "rendezvous1" {
  zone_id = aws_route53_zone.omerta.zone_id
  name    = "rendezvous1.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [module.rendezvous1.public_ip]
}

# rendezvous2.omerta.run -> Secondary rendezvous server
resource "aws_route53_record" "rendezvous2" {
  zone_id = aws_route53_zone.omerta.zone_id
  name    = "rendezvous2.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [module.rendezvous2.public_ip]
}

# stun1.omerta.run -> Alias to rendezvous1 (for STUN-specific endpoint)
resource "aws_route53_record" "stun1" {
  zone_id = aws_route53_zone.omerta.zone_id
  name    = "stun1.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [module.rendezvous1.public_ip]
}

# stun2.omerta.run -> Alias to rendezvous2 (for STUN-specific endpoint)
resource "aws_route53_record" "stun2" {
  zone_id = aws_route53_zone.omerta.zone_id
  name    = "stun2.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [module.rendezvous2.public_ip]
}

# =============================================================================
# CloudWatch Bandwidth Monitoring & Alerts
# =============================================================================

# SNS topic for alerts (only created if alert_email is provided)
resource "aws_sns_topic" "bandwidth_alerts" {
  count = var.alert_email != "" ? 1 : 0
  name  = "omerta-bandwidth-alerts"

  tags = {
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}

resource "aws_sns_topic_subscription" "bandwidth_alerts_email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.bandwidth_alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Calculate threshold: 80% of monthly cap, converted to bytes per 5-minute period
# Monthly cap (GB) * 0.8 * 1024^3 / (30 days * 24 hours * 12 periods/hour)
locals {
  # Bytes per 5-minute period at 80% of monthly cap
  bandwidth_threshold_bytes = var.bandwidth_cap_gb * 0.8 * 1073741824 / (30 * 24 * 12)
}

# Bandwidth alarm for rendezvous1
resource "aws_cloudwatch_metric_alarm" "rendezvous1_bandwidth" {
  alarm_name          = "omerta-rendezvous1-bandwidth-warning"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "NetworkOut"
  namespace           = "AWS/EC2"
  period              = 300  # 5 minutes
  statistic           = "Sum"
  threshold           = local.bandwidth_threshold_bytes
  alarm_description   = "Bandwidth usage exceeding 80% of ${var.bandwidth_cap_gb}GB monthly cap"
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = module.rendezvous1.instance_id
  }

  # Only send to SNS if email is configured
  alarm_actions = var.alert_email != "" ? [aws_sns_topic.bandwidth_alerts[0].arn] : []
  ok_actions    = var.alert_email != "" ? [aws_sns_topic.bandwidth_alerts[0].arn] : []

  tags = {
    Environment = "prod"
    Service     = "rendezvous"
  }
}

# Bandwidth alarm for rendezvous2
resource "aws_cloudwatch_metric_alarm" "rendezvous2_bandwidth" {
  alarm_name          = "omerta-rendezvous2-bandwidth-warning"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "NetworkOut"
  namespace           = "AWS/EC2"
  period              = 300  # 5 minutes
  statistic           = "Sum"
  threshold           = local.bandwidth_threshold_bytes
  alarm_description   = "Bandwidth usage exceeding 80% of ${var.bandwidth_cap_gb}GB monthly cap"
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = module.rendezvous2.instance_id
  }

  alarm_actions = var.alert_email != "" ? [aws_sns_topic.bandwidth_alerts[0].arn] : []
  ok_actions    = var.alert_email != "" ? [aws_sns_topic.bandwidth_alerts[0].arn] : []

  tags = {
    Environment = "prod"
    Service     = "rendezvous"
  }
}
