# =============================================================================
# AWS Configuration
# =============================================================================
# All sensitive values should be set via environment variables:
#   TF_VAR_key_name=your-key-pair
#   TF_VAR_ssh_cidr_blocks='["1.2.3.4/32"]'
#
# AWS credentials are read from:
#   AWS_ACCESS_KEY_ID
#   AWS_SECRET_ACCESS_KEY
#   AWS_REGION (optional)

variable "aws_region" {
  description = "AWS region (can also be set via AWS_REGION env var)"
  type        = string
  default     = "us-east-1"
}

variable "domain_name" {
  description = "Domain name for Route53 hosted zone"
  type        = string
  default     = "mtomei.com"
}

# =============================================================================
# EC2 Configuration
# =============================================================================

variable "instance_type" {
  description = "EC2 instance type for rendezvous servers"
  type        = string
  default     = "t3.small"
}

variable "key_name" {
  description = "SSH key pair name (set via TF_VAR_key_name env var)"
  type        = string
  # No default - must be provided via environment variable
}

variable "ssh_cidr_blocks" {
  description = "CIDR blocks allowed for SSH access (set via TF_VAR_ssh_cidr_blocks env var)"
  type        = list(string)
  default     = []  # Empty default - should be set to your IP
}
