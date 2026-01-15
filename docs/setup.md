# Setup Guide

This guide walks through setting up Omerta rendezvous servers on AWS EC2 with Route53 DNS.

## Prerequisites

1. **AWS Account** with permissions for EC2, Route53
2. **AWS CLI** installed and configured
3. **Terraform** >= 1.0 installed
4. **SSH Key Pair** created in AWS EC2
5. **Domain** registered (omerta.run at Squarespace)

## Step 1: Create AWS IAM User

Create an IAM user for Terraform with these permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:*",
        "route53:*",
        "route53domains:*"
      ],
      "Resource": "*"
    }
  ]
}
```

Save the Access Key ID and Secret Access Key.

## Step 2: Create EC2 Key Pair

```bash
# Create a new key pair (or use existing)
aws ec2 create-key-pair --key-name omerta-prod --query 'KeyMaterial' --output text > ~/.ssh/omerta-prod.pem
chmod 600 ~/.ssh/omerta-prod.pem
```

## Step 3: Configure Environment Variables

```bash
# Copy the example file
cp .env.example .env

# Edit with your values
nano .env
```

Required variables:

| Variable | Description |
|----------|-------------|
| `AWS_ACCESS_KEY_ID` | IAM user access key |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret key |
| `AWS_REGION` | AWS region (default: us-east-1) |
| `TF_VAR_key_name` | EC2 key pair name |
| `TF_VAR_ssh_cidr_blocks` | Your IP for SSH access |

```bash
# Source the environment
source .env
```

## Step 4: Initialize and Apply Terraform

```bash
cd terraform/environments/prod

# Initialize Terraform
terraform init

# Preview changes
terraform plan

# Apply (creates EC2 instances and Route53 zone)
terraform apply
```

## Step 5: Configure Squarespace Nameservers

After `terraform apply` completes, it outputs the Route53 nameservers:

```
route53_nameservers = [
  "ns-123.awsdns-45.com",
  "ns-678.awsdns-90.net",
  "ns-111.awsdns-22.org",
  "ns-333.awsdns-44.co.uk",
]
```

Configure these in Squarespace:

1. Log in to [Squarespace Domains](https://account.squarespace.com/domains)
2. Select **omerta.run**
3. Click **DNS Settings**
4. Click **Nameservers**
5. Select **Use custom nameservers**
6. Enter all 4 Route53 nameservers
7. Click **Save**

**Important**: DNS propagation takes 24-48 hours. During this time, existing DNS records may be unavailable.

## Step 6: Build the Binary

```bash
# From repo root
./scripts/build.sh
```

This builds `omerta-rendezvous` for your platform. For cross-compilation to Linux (if building on macOS), see [Cross-Compilation](#cross-compilation).

## Step 7: Deploy to Servers

```bash
# Deploy to all servers
./scripts/deploy.sh prod all

# Or deploy to specific server
./scripts/deploy.sh prod rendezvous1
```

## Step 8: Verify Deployment

```bash
# Check service status
ssh -i ~/.ssh/omerta-prod.pem ec2-user@<IP> "sudo systemctl status omerta-rendezvous"

# Test STUN endpoint
# (use a STUN client or the mesh CLI)

# Check logs
ssh -i ~/.ssh/omerta-prod.pem ec2-user@<IP> "sudo tail -f /var/log/omerta/rendezvous.log"
```

## Cross-Compilation

If building on macOS for Linux deployment, you have two options:

### Option A: Build on EC2

SSH to an EC2 instance and build there:

```bash
ssh -i ~/.ssh/omerta-prod.pem ec2-user@<IP>
# Install Swift, clone repo, build
```

### Option B: Docker Cross-Compile

```bash
docker run --rm -v $(pwd)/omerta:/src -w /src swift:5.9 \
  swift build -c release --product omerta-rendezvous
```

## Troubleshooting

### Terraform can't find credentials

```bash
# Verify environment variables are set
echo $AWS_ACCESS_KEY_ID
echo $TF_VAR_key_name

# Re-source if needed
source .env
```

### SSH connection refused

- Check security group allows your IP
- Verify key pair name matches
- Wait for instance to fully boot (~2 minutes)

### DNS not resolving

- DNS propagation takes up to 48 hours
- Verify nameservers are correctly set in Squarespace
- Check Route53 hosted zone has correct records:
  ```bash
  aws route53 list-resource-record-sets --hosted-zone-id <ZONE_ID>
  ```

### Service won't start

```bash
# Check binary exists and is executable
ssh ec2-user@<IP> "ls -la /opt/omerta/"

# Check service logs
ssh ec2-user@<IP> "sudo journalctl -u omerta-rendezvous -n 50"
```

## Security Notes

- Never commit `.env` or `terraform.tfvars` to version control
- Restrict `ssh_cidr_blocks` to your IP address
- Consider using AWS Secrets Manager for production
- Enable CloudWatch logging for audit trails
- Rotate AWS credentials periodically
