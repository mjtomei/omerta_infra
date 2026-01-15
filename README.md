# Omerta Infrastructure

Infrastructure and deployment code for Omerta rendezvous servers on AWS EC2 with Route53 DNS.

## Overview

This repository contains:
- Terraform configurations for EC2 instances and Route53 DNS
- Build and deployment scripts for `omerta-rendezvous`
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
                    │  rendezvous1.mtomei.com ──┐     │
                    │  rendezvous2.mtomei.com ──┼──►  │
                    │  stun1.mtomei.com ────────┤     │
                    │  stun2.mtomei.com ────────┘     │
                    └─────────────────────────────────┘
                           │                │
                           ▼                ▼
              ┌────────────────┐  ┌────────────────┐
              │  EC2 Instance  │  │  EC2 Instance  │
              │  rendezvous1   │  │  rendezvous2   │
              │                │  │                │
              │ WebSocket:8080 │  │ WebSocket:8080 │
              │ STUN:3478/udp  │  │ STUN:3478/udp  │
              │ Relay:3479/udp │  │ Relay:3479/udp │
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

# 3. Deploy infrastructure
cd terraform/environments/prod
terraform init
terraform apply

# 4. Configure Squarespace nameservers (see output)

# 5. Build and deploy binary
cd ../../..
./scripts/build.sh
./scripts/deploy.sh prod all
```

## DNS Configuration

After `terraform apply`, you'll see Route53 nameservers in the output. Configure these in Squarespace:

1. Log in to Squarespace Domains
2. Select mtomei.com → DNS Settings → Nameservers
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
│   ├── build.sh                     # Build omerta-rendezvous
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
| `rendezvous1.mtomei.com` | EC2 #1 | Primary rendezvous |
| `rendezvous2.mtomei.com` | EC2 #2 | Secondary rendezvous |
| `stun1.mtomei.com` | EC2 #1 | STUN endpoint alias |
| `stun2.mtomei.com` | EC2 #2 | STUN endpoint alias |

## Ports

| Port | Protocol | Service |
|------|----------|---------|
| 22 | TCP | SSH (restricted to your IP) |
| 8080 | TCP | WebSocket signaling |
| 3478 | UDP | STUN server |
| 3479 | UDP | Relay server |

## Documentation

- [Detailed Setup Guide](docs/setup.md) - Step-by-step instructions
- [Omerta Mesh Docs](omerta/docs/) - Protocol documentation

## Cost Estimate

| Resource | Monthly Cost |
|----------|--------------|
| 2x t3.small EC2 | ~$30 |
| Route53 hosted zone | ~$0.50 |
| 2x Elastic IPs (in use) | $0 |
| Data transfer | Variable |

**Total**: ~$30-35/month
