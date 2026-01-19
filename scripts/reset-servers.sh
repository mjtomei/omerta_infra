#!/bin/bash
# Reset bootstrap servers: destroy instances, recreate, deploy, init network
#
# This script performs a full reset of the bootstrap infrastructure:
# 1. Pull latest omerta code
# 2. Build binaries (via arch-home)
# 3. Taint and recreate EC2 instances (keeps Route53, EIPs, security groups)
# 4. Deploy binaries
# 5. Initialize the network
#
# Use this when you need fresh instances (e.g., after disk format changes)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Source environment variables if .env exists
if [ -f "$ROOT_DIR/.env" ]; then
    source "$ROOT_DIR/.env"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    echo "Usage: $0 <environment> [options]"
    echo ""
    echo "Reset bootstrap servers with fresh instances and latest code."
    echo ""
    echo "Arguments:"
    echo "  environment       Environment (prod, staging)"
    echo ""
    echo "Options:"
    echo "  --skip-pull       Skip git pull (use existing code)"
    echo "  --skip-build      Skip build (use existing binaries)"
    echo "  --skip-destroy    Skip instance destruction (just deploy and init)"
    echo "  --dry-run         Show what would be done without doing it"
    echo "  -h, --help        Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 prod                  # Full reset: pull, build, destroy, deploy, init"
    echo "  $0 prod --skip-destroy   # Just update: pull, build, deploy, init"
    echo "  $0 prod --dry-run        # Preview what would happen"
    exit 1
}

log() {
    echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠${NC} $1"
}

log_error() {
    echo -e "${RED}[$(date '+%H:%M:%S')] ✗${NC} $1"
}

# Parse arguments
ENVIRONMENT=""
SKIP_PULL=false
SKIP_BUILD=false
SKIP_DESTROY=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-pull)
            SKIP_PULL=true
            shift
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --skip-destroy)
            SKIP_DESTROY=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "Unknown option: $1"
            usage
            ;;
        *)
            if [ -z "$ENVIRONMENT" ]; then
                ENVIRONMENT="$1"
            else
                echo "Unexpected argument: $1"
                usage
            fi
            shift
            ;;
    esac
done

if [ -z "$ENVIRONMENT" ]; then
    echo "Error: environment required"
    usage
fi

TF_DIR="$ROOT_DIR/terraform/environments/$ENVIRONMENT"
if [ ! -d "$TF_DIR" ]; then
    log_error "Environment '$ENVIRONMENT' not found"
    exit 1
fi

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║              Bootstrap Server Reset                        ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Environment:   $ENVIRONMENT"
echo "Skip pull:     $SKIP_PULL"
echo "Skip build:    $SKIP_BUILD"
echo "Skip destroy:  $SKIP_DESTROY"
echo "Dry run:       $DRY_RUN"
echo ""

if ! $SKIP_DESTROY && ! $DRY_RUN; then
    log_warn "This will DESTROY and recreate the EC2 instances!"
    log_warn "Route53, EIPs, and security groups will be preserved."
    echo ""
    log_warn "The following will be PERMANENTLY LOST:"
    echo "         - Omerta network state and identity keys"
    echo "         - All user attestations stored on these nodes"
    echo "         - Any other data on the instances"
    echo ""
    echo -e "To confirm, type ${RED}reset ${ENVIRONMENT}${NC} and press Enter:"
    read -r CONFIRMATION
    if [ "$CONFIRMATION" != "reset $ENVIRONMENT" ]; then
        echo "Confirmation did not match. Aborted."
        exit 1
    fi
    echo ""
fi

if $DRY_RUN; then
    log_warn "DRY RUN MODE - no changes will be made"
    echo ""
fi

# Step 1: Pull latest code
if ! $SKIP_PULL; then
    log "Step 1: Pulling latest omerta code..."
    if $DRY_RUN; then
        echo "  Would run: cd omerta && git pull"
    else
        cd "$ROOT_DIR/omerta"
        git pull
        COMMIT=$(git rev-parse --short HEAD)
        log_success "Pulled latest code (commit: $COMMIT)"
    fi
else
    log "Step 1: Skipping pull (--skip-pull)"
fi
echo ""

# Step 2: Build binaries
if ! $SKIP_BUILD; then
    log "Step 2: Building binaries on arch-home..."
    if $DRY_RUN; then
        echo "  Would run: ./scripts/build.sh --arch-home"
    else
        if ! "$SCRIPT_DIR/build.sh" --arch-home; then
            log_error "Build failed!"
            exit 1
        fi
        log_success "Binaries built"
    fi
else
    log "Step 2: Skipping build (--skip-build)"
fi
echo ""

# Step 3: Taint and recreate instances
if ! $SKIP_DESTROY; then
    log "Step 3: Recreating EC2 instances..."
    cd "$TF_DIR"

    if $DRY_RUN; then
        echo "  Would run: terraform taint 'module.bootstrap1.aws_instance.bootstrap'"
        echo "  Would run: terraform taint 'module.bootstrap2.aws_instance.bootstrap'"
        echo "  Would run: terraform apply -auto-approve"
        echo "  Would run: ssh-keygen -R <bootstrap1_ip>"
        echo "  Would run: ssh-keygen -R <bootstrap2_ip>"
    else
        log "  Tainting bootstrap1 instance..."
        terraform taint 'module.bootstrap1.aws_instance.bootstrap'

        log "  Tainting bootstrap2 instance..."
        terraform taint 'module.bootstrap2.aws_instance.bootstrap'

        log "  Running terraform apply..."
        terraform apply -auto-approve

        log_success "Instances recreated"

        # Remove old SSH host keys for the recreated instances
        log "  Clearing old SSH host keys..."
        BOOTSTRAP1_IP=$(terraform output -raw bootstrap1_public_ip 2>/dev/null || echo "")
        BOOTSTRAP2_IP=$(terraform output -raw bootstrap2_public_ip 2>/dev/null || echo "")
        [ -n "$BOOTSTRAP1_IP" ] && ssh-keygen -R "$BOOTSTRAP1_IP" 2>/dev/null || true
        [ -n "$BOOTSTRAP2_IP" ] && ssh-keygen -R "$BOOTSTRAP2_IP" 2>/dev/null || true

        # Wait for cloud-init to complete on both instances
        log "  Waiting for cloud-init to complete (this may take a few minutes)..."
        SSH_KEY="${SSH_KEY:-$HOME/.ssh/omerta-key.pem}"
        for ip in "$BOOTSTRAP1_IP" "$BOOTSTRAP2_IP"; do
            if [ -n "$ip" ]; then
                log "    Waiting for $ip..."
                until ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "omerta@$ip" "cloud-init status --wait" 2>/dev/null; do
                    sleep 10
                done
            fi
        done
        log_success "Cloud-init completed on all instances"
    fi
else
    log "Step 3: Skipping instance destruction (--skip-destroy)"
fi
echo ""

# Step 4: Deploy binaries
log "Step 4: Deploying binaries..."
if $DRY_RUN; then
    echo "  Would run: ./scripts/deploy.sh $ENVIRONMENT all"
else
    "$SCRIPT_DIR/deploy.sh" "$ENVIRONMENT" all
    log_success "Binaries deployed"
fi
echo ""

# Step 5: Initialize network
log "Step 5: Initializing network..."
if $DRY_RUN; then
    echo "  Would run: ./scripts/init-network.sh $ENVIRONMENT"
else
    "$SCRIPT_DIR/init-network.sh" "$ENVIRONMENT"
    log_success "Network initialized"
fi
echo ""

echo "╔════════════════════════════════════════════════════════════╗"
echo "║                 Reset Complete                             ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
log_success "All steps completed successfully!"
echo ""
echo "Next steps:"
echo "  - Check network-link.txt for the new invite link"
echo "  - Test connectivity with: omerta network join <link>"
echo ""
