# Omerta Infrastructure

Infrastructure and deployment code for Omerta rendezvous servers on AWS EC2 with Route53 DNS.

## Overview

This repository contains:
- Terraform configurations for EC2 instances and Route53 DNS
- Build and deployment scripts for `omerta-stun` and `omertad`
- Network key generation and seeding for mesh network
- Documentation for Squarespace to Route53 DNS delegation

## Architecture

```
                    ┌─────────────────────────────────┐
                    │         Squarespace             │
                    │   (Domain Registration Only)    │
                    │                                 │
                    │   Nameservers → Route53         │
                    └─────────────────────────────────┘
                                   │
                                   ▼
                    ┌─────────────────────────────────┐
                    │        AWS Route53              │
                    │                                 │
                    │  rendezvous1.omerta.run ──┐     │
                    │  rendezvous2.omerta.run ──┼──►  │
                    │  stun1.omerta.run ────────┤     │
                    │  stun2.omerta.run ────────┘     │
                    └─────────────────────────────────┘
                           │                │
                           ▼                ▼
              ┌────────────────┐  ┌────────────────┐
              │  EC2 Instance  │  │  EC2 Instance  │
              │  rendezvous1   │  │  rendezvous2   │
              │                │  │                │
              │ STUN:3478/udp  │  │ STUN:3478/udp  │
              │ Mesh:9999/udp  │  │ Mesh:9999/udp  │
              └────────────────┘  └────────────────┘
```

## Credentials & Security

**All credentials are sourced from environment variables. Nothing is hardcoded.**

| Variable | Purpose |
|----------|---------|
| `AWS_ACCESS_KEY_ID` | AWS authentication |
| `AWS_SECRET_ACCESS_KEY` | AWS authentication |
| `AWS_REGION` | AWS region (default: us-east-1) |
| `TF_VAR_key_name` | EC2 SSH key pair name |
| `TF_VAR_ssh_cidr_blocks` | IP allowlist for SSH |

```bash
# Setup
cp .env.example .env
# Edit .env with your values
source .env
```

**Git hooks protect against accidental credential commits:**
```bash
./scripts/setup-hooks.sh  # Run once after cloning
```

The pre-commit hook will **block commits** containing:
- Any changes to `.env.example` (protected file)
- Any `.env` files (`.env`, `.env.local`, `.env.production`, etc.)
- Credential files (`*.pem`, `*.key`, `credentials*`, `secrets*`, etc.)

## Quick Start

```bash
# 1. Initialize submodule and git hooks
git submodule update --init
./scripts/setup-hooks.sh

# 2. Configure credentials
cp .env.example .env
nano .env  # Add your AWS credentials
source .env

# 3. Create the omerta network locally
omerta network create --name "omerta-prod" \
  --bootstrap "rendezvous1.omerta.run:9999" \
  --bootstrap "rendezvous2.omerta.run:9999"

# Copy the omerta://join/... link and add to .env:
# TF_VAR_omerta_network_link="omerta://join/..."
source .env

# 4. Deploy infrastructure
cd terraform/environments/prod
terraform init
terraform apply

# 5. Configure Squarespace nameservers (see output)

# 6. Build and deploy binaries
cd ../../..
./scripts/build.sh
./scripts/deploy.sh prod all

# 7. Join network on first boot (SSH to each server)
ssh ec2-user@rendezvous1.omerta.run
sudo -u omerta /opt/omerta/first-boot.sh
sudo systemctl start omertad
```

## Network Seeding

The network is created locally using `omerta network create`, then passed to Terraform:

1. Create the network locally (generates encryption key + bootstrap peers)
2. Set `TF_VAR_omerta_network_link` with the `omerta://join/...` link
3. Terraform distributes the link to EC2 instances
4. Run `first-boot.sh` on each server to join the network

**Important:** Keep the network link secure - it contains the encryption key.

## DNS Configuration

After `terraform apply`, you'll see Route53 nameservers in the output. Configure these in Squarespace:

1. Log in to Squarespace Domains
2. Select omerta.run → DNS Settings → Nameservers
3. Choose "Use custom nameservers"
4. Enter the 4 Route53 nameservers from Terraform output
5. Save and wait for propagation (up to 48 hours)

## Directory Structure

```
omerta-infra/
├── omerta/                          # Source code (submodule)
├── terraform/
│   ├── modules/rendezvous/          # Reusable EC2 + security group
│   └── environments/prod/           # Production configuration
├── scripts/
│   ├── build.sh                     # Build omerta-stun, omertad, omerta
│   ├── deploy.sh                    # Deploy to EC2
│   └── setup-hooks.sh               # Configure git hooks
├── .githooks/
│   └── pre-commit                   # Blocks credential commits
├── docs/
│   └── setup.md                     # Detailed setup guide
├── .env.example                     # Environment template
└── README.md
```

## DNS Records Created

| Subdomain | Points To | Purpose |
|-----------|-----------|---------|
| `rendezvous1.omerta.run` | EC2 #1 | Primary rendezvous |
| `rendezvous2.omerta.run` | EC2 #2 | Secondary rendezvous |
| `stun1.omerta.run` | EC2 #1 | STUN endpoint alias |
| `stun2.omerta.run` | EC2 #2 | STUN endpoint alias |

## Ports

| Port | Protocol | Service |
|------|----------|---------|
| 22 | TCP | SSH (restricted to your IP) |
| 3478 | UDP | STUN server (omerta-stun) |
| 9999 | UDP | Mesh network (omertad) |

## Services

| Service | Binary | Config | Description |
|---------|--------|--------|-------------|
| `omerta-stun` | `/opt/omerta/omerta-stun` | CLI flags | STUN server for NAT detection |
| `omertad` | `/opt/omerta/omertad` | `/home/omerta/.omerta/omertad.conf` | Mesh daemon for peer discovery |

**Managing omertad:**
```bash
# View status
sudo systemctl status omertad

# Restart with new config
sudo systemctl reload omertad

# View logs
sudo tail -f /var/log/omerta/omertad.log

# Use CLI
sudo -u omerta /opt/omerta/omerta network list
sudo -u omerta /opt/omerta/omerta mesh peers
```

## Documentation

- [Detailed Setup Guide](docs/setup.md) - Step-by-step instructions
- [Omerta Mesh Docs](omerta/docs/) - Protocol documentation

## Cost Estimate

| Resource | Monthly Cost |
|----------|--------------|
| 2x t3.micro EC2 (us-west-2) | ~$15 |
| Route53 hosted zone | ~$0.50 |
| 2x Elastic IPs (in use) | $0 |
| 2x EBS 8GB gp3 | ~$1.28 |
| Data transfer (STUN only) | ~$0.05 |
| CloudWatch alarms | $0.20 |
| EBS snapshots (7 days retention) | ~$0.50 |

**Total**: ~$18/month

## Cost Controls

- **Relay disabled**: omertad runs with `can-relay=false` to minimize bandwidth. Edit `/home/omerta/.omerta/omertad.conf` to enable if peers need data relay.
- **Bandwidth monitoring**: CloudWatch alarms at 80% of 10GB/month cap
- **Email alerts**: Optional notifications when bandwidth spikes

Set `TF_VAR_alert_email` to receive bandwidth warnings.

## Backups

EBS snapshots are automated via AWS Data Lifecycle Manager (DLM):

| Setting | Default | Description |
|---------|---------|-------------|
| `enable_ebs_snapshots` | `true` | Enable/disable automated snapshots |
| `snapshot_retention_days` | `7` | Days to retain snapshots |
| `snapshot_schedule_cron` | `cron(0 3 * * ? *)` | Daily at 3 AM UTC |

Snapshots capture all EBS volumes on instances tagged with `Backup=true`. This preserves network state, identity data, and configuration for disaster recovery.

**Future backup features (planned):**
- Infrastructure redundancy (multi-region, failover)
- Attestation data export to S3
- Key material backup system
