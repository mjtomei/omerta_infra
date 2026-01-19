# Omerta Bootstrap Server Module
# Creates an EC2 instance running omertad

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# IAM role for EC2 instance (CloudWatch agent permissions)
resource "aws_iam_role" "instance" {
  name = "${var.name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name}-profile"
  role = aws_iam_role.instance.name

  tags = var.tags
}

# Security group for omerta server
resource "aws_security_group" "bootstrap" {
  name        = "${var.name}-sg"
  description = "Security group for Omerta Mesh servers"
  vpc_id      = var.vpc_id

  # SSH access
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_cidr_blocks
  }

  # Omertad mesh network (UDP)
  ingress {
    description = "Omertad Mesh"
    from_port   = 9999
    to_port     = 9999
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

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
resource "aws_instance" "bootstrap" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.bootstrap.id]
  subnet_id              = var.subnet_id
  iam_instance_profile   = aws_iam_instance_profile.instance.name

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
resource "aws_eip" "bootstrap" {
  count    = var.create_eip ? 1 : 0
  instance = aws_instance.bootstrap.id
  domain   = "vpc"

  tags = merge(var.tags, {
    Name = "${var.name}-eip"
  })
}
