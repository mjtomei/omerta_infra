# Rendezvous Server Module
# Creates an EC2 instance configured to run omerta-rendezvous

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Security group for rendezvous server
resource "aws_security_group" "rendezvous" {
  name        = "${var.name}-sg"
  description = "Security group for Omerta rendezvous server"
  vpc_id      = var.vpc_id

  # SSH access
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_cidr_blocks
  }

  # WebSocket signaling server
  ingress {
    description = "WebSocket Signaling"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # STUN server (UDP)
  ingress {
    description = "STUN"
    from_port   = 3478
    to_port     = 3478
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Relay server (UDP) - disabled by default, uncomment if using relay
  # ingress {
  #   description = "Relay"
  #   from_port   = 3479
  #   to_port     = 3479
  #   protocol    = "udp"
  #   cidr_blocks = ["0.0.0.0/0"]
  # }

  # Allow all outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.name}-sg"
  })
}

# EC2 instance
resource "aws_instance" "rendezvous" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.rendezvous.id]
  subnet_id              = var.subnet_id

  root_block_device {
    volume_size = var.volume_size
    volume_type = "gp3"
  }

  user_data = var.user_data

  tags = merge(var.tags, {
    Name = var.name
  })
}

# Elastic IP for stable public address
resource "aws_eip" "rendezvous" {
  count    = var.create_eip ? 1 : 0
  instance = aws_instance.rendezvous.id
  domain   = "vpc"

  tags = merge(var.tags, {
    Name = "${var.name}-eip"
  })
}
