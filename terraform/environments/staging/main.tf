# Staging Bootstrap Servers
# Uses the same Route53 zone as prod with staging-* prefixes
#
# CREDENTIALS: AWS credentials are sourced from environment variables:
#   - AWS_ACCESS_KEY_ID
#   - AWS_SECRET_ACCESS_KEY
#   - AWS_REGION (optional, defaults to us-east-1)

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Data sources for default VPC
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

# Reference the prod Route53 zone (shared)
data "aws_route53_zone" "omerta" {
  name = var.domain_name
}

locals {
  common_tags = {
    Project     = "omerta"
    Environment = "omerta-staging"
    ManagedBy   = "omerta-terraform"
  }
}

# User data script (same as prod)
locals {
  user_data = <<-EOF
#!/bin/bash
set -e

dnf update -y
dnf install -y git gcc-c++ libcurl-devel libuuid-devel libxml2-devel ncurses-devel wireguard-tools tar gzip

# Install Swift 6.0.3
# Download to /opt to avoid filling /tmp (which is a small tmpfs)
mkdir -p /opt/swift
cd /opt
curl -sL "https://download.swift.org/swift-6.0.3-release/amazonlinux2/swift-6.0.3-RELEASE/swift-6.0.3-RELEASE-amazonlinux2.tar.gz" -o swift.tar.gz
tar -xzf swift.tar.gz -C /opt/swift --strip-components=1
rm swift.tar.gz
echo 'export PATH=/opt/swift/usr/bin:$PATH' > /etc/profile.d/swift.sh
chmod +x /etc/profile.d/swift.sh

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

# Block suspicious IP ranges via iptables
cat > /usr/local/bin/block-suspicious-ranges.sh <<'BLOCKSCRIPT'
#!/bin/bash
# Block known attack source ranges

# Create ipset for efficient blocking (if not exists)
if ! ipset list blocked_ranges &>/dev/null; then
    ipset create blocked_ranges hash:net
fi

# Known malicious/suspicious ranges (hosting providers used for attacks)
ipset add blocked_ranges 104.248.0.0/16 -exist
ipset add blocked_ranges 134.209.0.0/16 -exist
ipset add blocked_ranges 157.245.0.0/16 -exist
ipset add blocked_ranges 165.227.0.0/16 -exist
ipset add blocked_ranges 45.32.0.0/16 -exist
ipset add blocked_ranges 45.63.0.0/16 -exist
ipset add blocked_ranges 45.76.0.0/16 -exist
ipset add blocked_ranges 45.77.0.0/16 -exist
ipset add blocked_ranges 58.218.0.0/16 -exist
ipset add blocked_ranges 58.242.0.0/16 -exist
ipset add blocked_ranges 61.177.0.0/16 -exist
ipset add blocked_ranges 222.186.0.0/16 -exist
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

# Create omerta user
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

# Log rotation
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

# Create omertad config
cat > /home/omerta/.omerta/omertad.conf <<'CONFIG'
port=9999
can-relay=false
can-coordinate-hole-punch=true
CONFIG
chown omerta:omerta /home/omerta/.omerta/omertad.conf

# Create systemd services
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

echo "Staging setup complete."
EOF
}

# Primary staging bootstrap server
module "bootstrap1" {
  source = "../../modules/bootstrap"

  name          = "omerta-bootstrap1-staging"
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
    Domain  = "staging-bootstrap1.omerta.run"
  })
}

# Secondary staging bootstrap server
module "bootstrap2" {
  source = "../../modules/bootstrap"

  name          = "omerta-bootstrap2-staging"
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
    Domain  = "staging-bootstrap2.omerta.run"
  })
}

# =============================================================================
# Route53 DNS Records (using prod zone with staging-* prefixes)
# =============================================================================

resource "aws_route53_record" "bootstrap1" {
  zone_id = data.aws_route53_zone.omerta.zone_id
  name    = "staging-bootstrap1.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [module.bootstrap1.public_ip]
}

resource "aws_route53_record" "bootstrap2" {
  zone_id = data.aws_route53_zone.omerta.zone_id
  name    = "staging-bootstrap2.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [module.bootstrap2.public_ip]
}

resource "aws_route53_record" "stun1" {
  zone_id = data.aws_route53_zone.omerta.zone_id
  name    = "staging-stun1.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [module.bootstrap1.public_ip]
}

resource "aws_route53_record" "stun2" {
  zone_id = data.aws_route53_zone.omerta.zone_id
  name    = "staging-stun2.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [module.bootstrap2.public_ip]
}
