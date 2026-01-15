# Omerta Infrastructure

Infrastructure and deployment code for Omerta rendezvous servers on AWS EC2.

## Overview

This repository contains:
- Terraform configurations for provisioning EC2 instances
- Deployment scripts for building and deploying the `omerta-rendezvous` server
- DNS configuration for subdomains under `mtomei.com`

## Architecture

Rendezvous servers provide three services for the Omerta mesh network:
- **Signaling Server** (WebSocket, port 8080) - Peer coordination and NAT traversal signaling
- **STUN Server** (UDP, port 3478) - Public endpoint discovery for NAT detection
- **Relay Server** (UDP, port 3479) - Fallback relay for symmetric NAT scenarios

## Planned Subdomains

| Subdomain | Purpose |
|-----------|---------|
| `rendezvous1.mtomei.com` | Primary rendezvous server |
| `rendezvous2.mtomei.com` | Secondary rendezvous server |
| `stun1.mtomei.com` | STUN-only endpoint (alias) |

## Directory Structure

```
omerta-infra/
├── omerta/                    # Omerta source (submodule)
├── terraform/
│   ├── modules/
│   │   └── rendezvous/        # Reusable EC2 + security group module
│   └── environments/
│       ├── prod/              # Production configuration
│       └── staging/           # Staging configuration
├── scripts/
│   ├── build.sh               # Build omerta-rendezvous binary
│   └── deploy.sh              # Deploy to EC2 instances
└── docs/
    └── setup.md               # Setup and deployment guide
```

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.0
- Swift toolchain (for building omerta-rendezvous)
- Domain `mtomei.com` with Route53 or external DNS

## Quick Start

```bash
# Initialize submodule
git submodule update --init

# Build the rendezvous server
./scripts/build.sh

# Deploy infrastructure (staging)
cd terraform/environments/staging
terraform init
terraform apply

# Deploy binary to servers
./scripts/deploy.sh staging
```

## Ports Required

Security groups must allow:
- TCP 22 (SSH)
- TCP 8080 (WebSocket signaling)
- UDP 3478 (STUN)
- UDP 3479 (Relay)
