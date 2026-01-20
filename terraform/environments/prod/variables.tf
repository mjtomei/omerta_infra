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
  default     = "us-west-2"
}

variable "domain_name" {
  description = "Domain name for Route53 hosted zone"
  type        = string
  default     = "omerta.run"
}

# =============================================================================
# EC2 Configuration
# =============================================================================

variable "instance_type" {
  description = "EC2 instance type for bootstrap servers"
  type        = string
  default     = "t3.micro"
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

variable "ssh_ipv6_cidr_blocks" {
  description = "IPv6 CIDR blocks allowed for SSH access (set via TF_VAR_ssh_ipv6_cidr_blocks env var)"
  type        = list(string)
  default     = ["::/0"]  # Allow all IPv6 by default (SSH keys still required)
}

# =============================================================================
# Cost Controls
# =============================================================================

variable "bandwidth_cap_gb" {
  description = "Monthly bandwidth cap in GB per instance. Alarm triggers at 80% of this."
  type        = number
  default     = 10  # 10GB/month = ~$0.90 max bandwidth cost per server
}

variable "alert_email" {
  description = "Email for bandwidth alerts (set via TF_VAR_alert_email env var)"
  type        = string
  default     = ""  # Optional - no alerts if empty
}

# =============================================================================
# Backup Configuration
# =============================================================================

variable "enable_ebs_snapshots" {
  description = "Enable automated EBS snapshots via Data Lifecycle Manager"
  type        = bool
  default     = true
}

variable "snapshot_retention_days" {
  description = "Number of days to retain EBS snapshots"
  type        = number
  default     = 7
}

variable "snapshot_schedule_cron" {
  description = "Cron expression for snapshot schedule (UTC). Default: daily at 3 AM UTC"
  type        = string
  default     = "cron(0 3 * * ? *)"
}

# =============================================================================
# Network Configuration
# =============================================================================
# Network is initialized on the EC2 instances using scripts/init-network.sh
# after deployment. No pre-configuration needed.
