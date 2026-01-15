# Production Rendezvous Servers
# Deploys multiple rendezvous servers for mtomei.com subdomains

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

provider "aws" {
  region = var.aws_region
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
    ExecStart=/opt/omerta/omerta-rendezvous --port 8080 --stun-port 3478 --relay-port 3479 --log-level info
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
  volume_size   = 20
  create_eip    = true
  user_data     = local.user_data

  ssh_cidr_blocks = var.ssh_cidr_blocks

  tags = {
    Environment = "prod"
    Service     = "rendezvous"
    Domain      = "rendezvous1.mtomei.com"
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
  volume_size   = 20
  create_eip    = true
  user_data     = local.user_data

  ssh_cidr_blocks = var.ssh_cidr_blocks

  tags = {
    Environment = "prod"
    Service     = "rendezvous"
    Domain      = "rendezvous2.mtomei.com"
  }
}

# Route53 DNS records (optional - uncomment if using Route53)
# data "aws_route53_zone" "mtomei" {
#   name = "mtomei.com."
# }
#
# resource "aws_route53_record" "rendezvous1" {
#   zone_id = data.aws_route53_zone.mtomei.zone_id
#   name    = "rendezvous1.mtomei.com"
#   type    = "A"
#   ttl     = 300
#   records = [module.rendezvous1.public_ip]
# }
#
# resource "aws_route53_record" "rendezvous2" {
#   zone_id = data.aws_route53_zone.mtomei.zone_id
#   name    = "rendezvous2.mtomei.com"
#   type    = "A"
#   ttl     = 300
#   records = [module.rendezvous2.public_ip]
# }
#
# resource "aws_route53_record" "stun1" {
#   zone_id = data.aws_route53_zone.mtomei.zone_id
#   name    = "stun1.mtomei.com"
#   type    = "A"
#   ttl     = 300
#   records = [module.rendezvous1.public_ip]
# }
