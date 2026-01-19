# Production Bootstrap Servers
# Deploys multiple bootstrap servers for omerta.run subdomains
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
  #   key    = "prod/bootstrap.tfstate"
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

# =============================================================================
# Network Configuration
# =============================================================================
# Network is initialized on the EC2 instances after deployment.
# Run scripts/init-network.sh to create the omerta-main network.
#
# The init script will:
# 1. Create the network on bootstrap1
# 2. Join bootstrap2 to the network
# 3. Add both nodes as bootstrap peers
# 4. Generate the final invite link

# Common tags for all resources - makes them easy to find and audit
locals {
  common_tags = {
    Project     = "omerta"
    Environment = "omerta-prod"
    ManagedBy   = "omerta-terraform"
  }
}

# User data script to install dependencies and set up systemd services
locals {
  user_data = <<-EOF
#!/bin/bash
set -e

# Update system
dnf update -y

# Install dependencies
dnf install -y git gcc-c++ libcurl-devel libuuid-devel libxml2-devel ncurses-devel wireguard-tools tar gzip

# Install Swift 6.0.3 for Amazon Linux 2
# Download to /opt to avoid filling /tmp (which is a small tmpfs)
mkdir -p /opt/swift
cd /opt
curl -sL "https://download.swift.org/swift-6.0.3-release/amazonlinux2/swift-6.0.3-RELEASE/swift-6.0.3-RELEASE-amazonlinux2.tar.gz" -o swift.tar.gz
tar -xzf swift.tar.gz -C /opt/swift --strip-components=1
rm swift.tar.gz
echo 'export PATH=/opt/swift/usr/bin:$PATH' > /etc/profile.d/swift.sh
chmod +x /etc/profile.d/swift.sh

# Install CloudWatch agent for disk and process monitoring
dnf install -y amazon-cloudwatch-agent

# Install and configure fail2ban for SSH protection
dnf install -y fail2ban
cat > /etc/fail2ban/jail.local <<'FAIL2BAN'
[DEFAULT]
# Aggressive settings - ban for 24h after 3 attempts in 10 min
bantime = 24h
findtime = 10m
maxretry = 3
# Increase ban time for repeat offenders
bantime.increment = true
bantime.factor = 24
bantime.maxtime = 1w

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/secure
maxretry = 3
bantime = 24h
FAIL2BAN

# Block known malicious IP ranges (data centers commonly used for attacks)
# These are hosting/VPS providers frequently used for SSH brute force
cat > /etc/fail2ban/jail.d/blocklist.conf <<'BLOCKLIST'
[DEFAULT]
# Known malicious ranges will be blocked via iptables below
BLOCKLIST

# Block suspicious IP ranges via iptables
# Common attack sources: certain hosting providers, Tor exit nodes, etc.
cat > /usr/local/bin/block-suspicious-ranges.sh <<'BLOCKSCRIPT'
#!/bin/bash
# Block known attack source ranges
# These are hosting/VPS providers commonly used for SSH attacks

# Create ipset for efficient blocking (if not exists)
if ! ipset list blocked_ranges &>/dev/null; then
    ipset create blocked_ranges hash:net
fi

# Known malicious/suspicious ranges (hosting providers used for attacks)
# DigitalOcean scanner ranges (not blocking all DO, just known bad)
ipset add blocked_ranges 104.248.0.0/16 -exist
ipset add blocked_ranges 134.209.0.0/16 -exist
ipset add blocked_ranges 157.245.0.0/16 -exist
ipset add blocked_ranges 165.227.0.0/16 -exist

# Choopa/Vultr scanner ranges
ipset add blocked_ranges 45.32.0.0/16 -exist
ipset add blocked_ranges 45.63.0.0/16 -exist
ipset add blocked_ranges 45.76.0.0/16 -exist
ipset add blocked_ranges 45.77.0.0/16 -exist

# Known Chinese attack ranges (adjust if you need China access)
ipset add blocked_ranges 58.218.0.0/16 -exist
ipset add blocked_ranges 58.242.0.0/16 -exist
ipset add blocked_ranges 61.177.0.0/16 -exist
ipset add blocked_ranges 222.186.0.0/16 -exist

# Russian attack ranges (adjust if you need Russia access)
ipset add blocked_ranges 5.188.0.0/16 -exist
ipset add blocked_ranges 193.106.0.0/16 -exist

# Apply iptables rules - allow only STUN and omertad from blocked ranges, drop everything else
# Rules are evaluated in order, so ACCEPT rules must come before DROP

# Allow STUN (UDP 3478) from blocked ranges
if ! iptables -C INPUT -p udp --dport 3478 -m set --match-set blocked_ranges src -j ACCEPT 2>/dev/null; then
    iptables -I INPUT -p udp --dport 3478 -m set --match-set blocked_ranges src -j ACCEPT
fi

# Allow omertad (UDP 9999) from blocked ranges
if ! iptables -C INPUT -p udp --dport 9999 -m set --match-set blocked_ranges src -j ACCEPT 2>/dev/null; then
    iptables -I INPUT -p udp --dport 9999 -m set --match-set blocked_ranges src -j ACCEPT
fi

# Drop all other traffic from blocked ranges
if ! iptables -C INPUT -m set --match-set blocked_ranges src -j DROP 2>/dev/null; then
    iptables -A INPUT -m set --match-set blocked_ranges src -j DROP
fi
BLOCKSCRIPT
chmod +x /usr/local/bin/block-suspicious-ranges.sh

# Install ipset and apply blocks
dnf install -y ipset
/usr/local/bin/block-suspicious-ranges.sh

# Make blocks persist across reboots
cat > /etc/systemd/system/block-suspicious-ranges.service <<'SYSTEMD'
[Unit]
Description=Block suspicious IP ranges
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/block-suspicious-ranges.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SYSTEMD
systemctl enable block-suspicious-ranges

systemctl enable fail2ban
systemctl start fail2ban

# Create omerta user with home directory
useradd -r -m -d /home/omerta -s /bin/bash omerta || true

# Create directories
mkdir -p /opt/omerta /var/log/omerta /home/omerta/.omerta
chown -R omerta:omerta /opt/omerta /var/log/omerta /home/omerta/.omerta

# Set up SSH access for omerta user (copy ec2-user's authorized_keys)
mkdir -p /home/omerta/.ssh
cp /home/ec2-user/.ssh/authorized_keys /home/omerta/.ssh/authorized_keys
chown -R omerta:omerta /home/omerta/.ssh
chmod 700 /home/omerta/.ssh
chmod 600 /home/omerta/.ssh/authorized_keys

# Set up passwordless sudo for omerta user
echo 'omerta ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/omerta
chmod 440 /etc/sudoers.d/omerta

# Configure log rotation to prevent disk from filling up
cat > /etc/logrotate.d/omerta <<'LOGROTATE'
/var/log/omerta/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
LOGROTATE

# Configure CloudWatch agent for disk and process monitoring
mkdir -p /opt/aws/amazon-cloudwatch-agent/etc
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'CWAGENT'
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "root"
  },
  "metrics": {
    "namespace": "Omerta/System",
    "append_dimensions": {
      "InstanceId": "$${aws:InstanceId}"
    },
    "metrics_collected": {
      "disk": {
        "measurement": ["used_percent"],
        "metrics_collection_interval": 60,
        "resources": ["/"],
        "drop_device": true
      },
      "procstat": [
        {
          "pattern": "omertad",
          "measurement": ["pid_count"]
        },
        {
          "pattern": "omerta-stun",
          "measurement": ["pid_count"]
        }
      ]
    }
  }
}
CWAGENT

# Start CloudWatch agent
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
systemctl enable amazon-cloudwatch-agent

# Create omertad config file
# Note: network= line will be added by init-network.sh after network creation
# Note: can-relay is false to minimize bandwidth costs.
# Set can-relay=true if you need to relay data for peers who can't establish direct connections.
cat > /home/omerta/.omerta/omertad.conf <<'CONFIG'
# Omerta Daemon Configuration
# Generated by Terraform

# Mesh port
port=9999

# Relay mode - disabled to minimize bandwidth costs
# Enable if peers need data relay for connectivity
can-relay=false

# Hole punch coordination - enabled for NAT traversal
can-coordinate-hole-punch=true
CONFIG
chown omerta:omerta /home/omerta/.omerta/omertad.conf

# Create omerta-stun systemd service
cat > /etc/systemd/system/omerta-stun.service <<'SERVICE'
[Unit]
Description=Omerta STUN Server
After=network.target

[Service]
Type=simple
User=omerta
Group=omerta
ExecStart=/opt/omerta/omerta-stun --port 3478 --log-level info
Restart=always
RestartSec=5
StandardOutput=append:/var/log/omerta/stun.log
StandardError=append:/var/log/omerta/stun.log

[Install]
WantedBy=multi-user.target
SERVICE

# Create omertad systemd service
# Note: Network ID will be set after first boot when joining the network
cat > /etc/systemd/system/omertad.service <<'SERVICE'
[Unit]
Description=Omerta Daemon
After=network.target

[Service]
Type=simple
User=omerta
Group=omerta
WorkingDirectory=/home/omerta
ExecStart=/opt/omerta/omertad start --config /home/omerta/.omerta/omertad.conf
ExecReload=/opt/omerta/omertad restart --config /home/omerta/.omerta/omertad.conf
Restart=always
RestartSec=5
StandardOutput=append:/var/log/omerta/omertad.log
StandardError=append:/var/log/omerta/omertad.log

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable omerta-stun
systemctl enable omertad

echo "Setup complete. Deploy binaries and run init-network.sh to initialize the network."
EOF
}

# Primary bootstrap server
module "bootstrap1" {
  source = "../../modules/bootstrap"

  name          = "omerta-bootstrap1-prod"
  vpc_id        = data.aws_vpc.default.id
  subnet_id     = data.aws_subnets.default.ids[0]
  ami_id        = data.aws_ami.amazon_linux_2023.id
  instance_type = var.instance_type
  key_name      = var.key_name
  volume_size   = 30
  create_eip    = true
  user_data     = local.user_data

  ssh_cidr_blocks = var.ssh_cidr_blocks

  tags = merge(local.common_tags, {
    Service = "bootstrap"
    Domain  = "bootstrap1.omerta.run"
    Backup  = "true"
  })
}

# Secondary bootstrap server (different AZ for redundancy)
module "bootstrap2" {
  source = "../../modules/bootstrap"

  name          = "omerta-bootstrap2-prod"
  vpc_id        = data.aws_vpc.default.id
  subnet_id     = length(data.aws_subnets.default.ids) > 1 ? data.aws_subnets.default.ids[1] : data.aws_subnets.default.ids[0]
  ami_id        = data.aws_ami.amazon_linux_2023.id
  instance_type = var.instance_type
  key_name      = var.key_name
  volume_size   = 30
  create_eip    = true
  user_data     = local.user_data

  ssh_cidr_blocks = var.ssh_cidr_blocks

  tags = merge(local.common_tags, {
    Service = "bootstrap"
    Domain  = "bootstrap2.omerta.run"
    Backup  = "true"
  })
}

# =============================================================================
# Route53 DNS Configuration
# =============================================================================

# Create hosted zone for omerta.run
# After creation, update Squarespace nameservers to point to Route53
resource "aws_route53_zone" "omerta" {
  name    = var.domain_name
  comment = "Managed by Terraform - Omerta infrastructure"

  tags = local.common_tags
}

# bootstrap1.omerta.run -> Primary bootstrap server
resource "aws_route53_record" "bootstrap1" {
  zone_id = aws_route53_zone.omerta.zone_id
  name    = "bootstrap1.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [module.bootstrap1.public_ip]
}

# bootstrap2.omerta.run -> Secondary bootstrap server
resource "aws_route53_record" "bootstrap2" {
  zone_id = aws_route53_zone.omerta.zone_id
  name    = "bootstrap2.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [module.bootstrap2.public_ip]
}

# stun1.omerta.run -> Alias to bootstrap1 (for STUN-specific endpoint)
resource "aws_route53_record" "stun1" {
  zone_id = aws_route53_zone.omerta.zone_id
  name    = "stun1.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [module.bootstrap1.public_ip]
}

# stun2.omerta.run -> Alias to bootstrap2 (for STUN-specific endpoint)
resource "aws_route53_record" "stun2" {
  zone_id = aws_route53_zone.omerta.zone_id
  name    = "stun2.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [module.bootstrap2.public_ip]
}

# =============================================================================
# CloudWatch Bandwidth Monitoring & Alerts
# =============================================================================

# SNS topic for alerts (only created if alert_email is provided)
resource "aws_sns_topic" "bandwidth_alerts" {
  count = var.alert_email != "" ? 1 : 0
  name  = "omerta-bandwidth-alerts"

  tags = local.common_tags
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

# Bandwidth alarm for bootstrap1
resource "aws_cloudwatch_metric_alarm" "bootstrap1_bandwidth" {
  alarm_name          = "omerta-bootstrap1-bandwidth-warning"
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
    InstanceId = module.bootstrap1.instance_id
  }

  # Only send to SNS if email is configured
  alarm_actions = var.alert_email != "" ? [aws_sns_topic.bandwidth_alerts[0].arn] : []
  ok_actions    = var.alert_email != "" ? [aws_sns_topic.bandwidth_alerts[0].arn] : []

  tags = merge(local.common_tags, {
    Service = "bootstrap"
  })
}

# Bandwidth alarm for bootstrap2
resource "aws_cloudwatch_metric_alarm" "bootstrap2_bandwidth" {
  alarm_name          = "omerta-bootstrap2-bandwidth-warning"
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
    InstanceId = module.bootstrap2.instance_id
  }

  alarm_actions = var.alert_email != "" ? [aws_sns_topic.bandwidth_alerts[0].arn] : []
  ok_actions    = var.alert_email != "" ? [aws_sns_topic.bandwidth_alerts[0].arn] : []

  tags = merge(local.common_tags, {
    Service = "bootstrap"
  })
}

# =============================================================================
# EBS Snapshot Automation (Data Lifecycle Manager)
# =============================================================================
# Automated daily snapshots of bootstrap node EBS volumes for disaster recovery.
# Identity attestation data and configuration are preserved in these snapshots.

# IAM role for DLM
resource "aws_iam_role" "dlm_lifecycle_role" {
  count = var.enable_ebs_snapshots ? 1 : 0
  name  = "omerta-dlm-lifecycle-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "dlm.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "dlm_lifecycle" {
  count      = var.enable_ebs_snapshots ? 1 : 0
  role       = aws_iam_role.dlm_lifecycle_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

# DLM lifecycle policy for EBS snapshots
resource "aws_dlm_lifecycle_policy" "ebs_snapshots" {
  count       = var.enable_ebs_snapshots ? 1 : 0
  description = "Automated EBS snapshots for Omerta bootstrap nodes"
  state       = "ENABLED"

  execution_role_arn = aws_iam_role.dlm_lifecycle_role[0].arn

  policy_details {
    resource_types = ["INSTANCE"]

    # Target instances with the Backup=true tag
    target_tags = {
      Backup = "true"
    }

    schedule {
      name = "Daily snapshots"

      create_rule {
        cron_expression = var.snapshot_schedule_cron
      }

      retain_rule {
        count = var.snapshot_retention_days
      }

      tags_to_add = {
        SnapshotCreator = "DLM"
        Project         = "omerta"
        Environment     = "omerta-prod"
        Service         = "bootstrap"
      }

      copy_tags = true
    }
  }

  tags = local.common_tags
}

# =============================================================================
# System Health Alarms (Disk Space, Process Monitoring)
# =============================================================================
# These alarms use CloudWatch agent metrics from the Omerta/System namespace.
# Metrics are collected every 60 seconds.

# Disk space alarm for bootstrap1 (>80% used)
resource "aws_cloudwatch_metric_alarm" "bootstrap1_disk" {
  alarm_name          = "omerta-bootstrap1-disk-space-warning"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "disk_used_percent"
  namespace           = "Omerta/System"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Disk usage exceeding 80% on bootstrap1"
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = module.bootstrap1.instance_id
    path       = "/"
  }

  alarm_actions = var.alert_email != "" ? [aws_sns_topic.bandwidth_alerts[0].arn] : []
  ok_actions    = var.alert_email != "" ? [aws_sns_topic.bandwidth_alerts[0].arn] : []

  tags = merge(local.common_tags, {
    Service = "bootstrap"
  })
}

# Disk space alarm for bootstrap2 (>80% used)
resource "aws_cloudwatch_metric_alarm" "bootstrap2_disk" {
  alarm_name          = "omerta-bootstrap2-disk-space-warning"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "disk_used_percent"
  namespace           = "Omerta/System"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Disk usage exceeding 80% on bootstrap2"
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = module.bootstrap2.instance_id
    path       = "/"
  }

  alarm_actions = var.alert_email != "" ? [aws_sns_topic.bandwidth_alerts[0].arn] : []
  ok_actions    = var.alert_email != "" ? [aws_sns_topic.bandwidth_alerts[0].arn] : []

  tags = merge(local.common_tags, {
    Service = "bootstrap"
  })
}

# Process alarm for omertad on bootstrap1 (alert if not running)
resource "aws_cloudwatch_metric_alarm" "bootstrap1_omertad" {
  alarm_name          = "omerta-bootstrap1-omertad-not-running"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "procstat_lookup_pid_count"
  namespace           = "Omerta/System"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "omertad process not running on bootstrap1"
  treat_missing_data  = "breaching"

  dimensions = {
    InstanceId = module.bootstrap1.instance_id
    pattern    = "omertad"
  }

  alarm_actions = var.alert_email != "" ? [aws_sns_topic.bandwidth_alerts[0].arn] : []
  ok_actions    = var.alert_email != "" ? [aws_sns_topic.bandwidth_alerts[0].arn] : []

  tags = merge(local.common_tags, {
    Service = "bootstrap"
  })
}

# Process alarm for omertad on bootstrap2 (alert if not running)
resource "aws_cloudwatch_metric_alarm" "bootstrap2_omertad" {
  alarm_name          = "omerta-bootstrap2-omertad-not-running"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "procstat_lookup_pid_count"
  namespace           = "Omerta/System"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "omertad process not running on bootstrap2"
  treat_missing_data  = "breaching"

  dimensions = {
    InstanceId = module.bootstrap2.instance_id
    pattern    = "omertad"
  }

  alarm_actions = var.alert_email != "" ? [aws_sns_topic.bandwidth_alerts[0].arn] : []
  ok_actions    = var.alert_email != "" ? [aws_sns_topic.bandwidth_alerts[0].arn] : []

  tags = merge(local.common_tags, {
    Service = "bootstrap"
  })
}

# Process alarm for omerta-stun on bootstrap1 (alert if not running)
resource "aws_cloudwatch_metric_alarm" "bootstrap1_stun" {
  alarm_name          = "omerta-bootstrap1-stun-not-running"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "procstat_lookup_pid_count"
  namespace           = "Omerta/System"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "omerta-stun process not running on bootstrap1"
  treat_missing_data  = "breaching"

  dimensions = {
    InstanceId = module.bootstrap1.instance_id
    pattern    = "omerta-stun"
  }

  alarm_actions = var.alert_email != "" ? [aws_sns_topic.bandwidth_alerts[0].arn] : []
  ok_actions    = var.alert_email != "" ? [aws_sns_topic.bandwidth_alerts[0].arn] : []

  tags = merge(local.common_tags, {
    Service = "bootstrap"
  })
}

# Process alarm for omerta-stun on bootstrap2 (alert if not running)
resource "aws_cloudwatch_metric_alarm" "bootstrap2_stun" {
  alarm_name          = "omerta-bootstrap2-stun-not-running"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "procstat_lookup_pid_count"
  namespace           = "Omerta/System"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "omerta-stun process not running on bootstrap2"
  treat_missing_data  = "breaching"

  dimensions = {
    InstanceId = module.bootstrap2.instance_id
    pattern    = "omerta-stun"
  }

  alarm_actions = var.alert_email != "" ? [aws_sns_topic.bandwidth_alerts[0].arn] : []
  ok_actions    = var.alert_email != "" ? [aws_sns_topic.bandwidth_alerts[0].arn] : []

  tags = merge(local.common_tags, {
    Service = "bootstrap"
  })
}
