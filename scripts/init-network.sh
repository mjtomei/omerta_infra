#!/bin/bash
# Initialize the omerta-main network on bootstrap servers
#
# This script orchestrates network creation across bootstrap1 and bootstrap2:
# 1. bootstrap1 creates the network (becomes first bootstrap peer)
# 2. bootstrap2 joins the network
# 3. Both nodes add bootstrap2 as a bootstrap peer
# 4. Generate final invite link with both bootstrap peers
#
# Run from your local machine after deploying binaries.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

NETWORK_NAME="omerta-main"

usage() {
    echo "Usage: $0 <environment> [options]"
    echo ""
    echo "Initialize the omerta-main network on bootstrap servers."
    echo ""
    echo "Arguments:"
    echo "  environment   Environment (prod, staging)"
    echo ""
    echo "Options:"
    echo "  --force       Recreate network even if it exists"
    echo "  --dry-run     Show what would be done without doing it"
    echo "  -h, --help    Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 prod           # Initialize network on prod servers"
    echo "  $0 prod --force   # Recreate network (WARNING: breaks existing peers)"
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
FORCE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE=true
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

# Get server info from Terraform
TF_DIR="$ROOT_DIR/terraform/environments/$ENVIRONMENT"
if [ ! -d "$TF_DIR" ]; then
    log_error "Environment '$ENVIRONMENT' not found"
    exit 1
fi

cd "$TF_DIR"

if [ ! -f "terraform.tfstate" ]; then
    log_error "No terraform state found. Run 'terraform apply' first."
    exit 1
fi

BOOTSTRAP1_IP=$(terraform output -raw bootstrap1_public_ip 2>/dev/null || echo "")
BOOTSTRAP2_IP=$(terraform output -raw bootstrap2_public_ip 2>/dev/null || echo "")

if [ -z "$BOOTSTRAP1_IP" ] || [ -z "$BOOTSTRAP2_IP" ]; then
    log_error "Could not get server IPs from Terraform"
    exit 1
fi

# Get domain names from terraform outputs or construct them
DOMAIN=$(terraform output -raw domain_name 2>/dev/null || echo "omerta.run")
BOOTSTRAP1_DOMAIN="bootstrap1.${DOMAIN}"
BOOTSTRAP2_DOMAIN="bootstrap2.${DOMAIN}"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║         Omerta Network Initialization                      ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Network name:  $NETWORK_NAME"
echo "Environment:   $ENVIRONMENT"
echo "Bootstrap1:    $BOOTSTRAP1_DOMAIN ($BOOTSTRAP1_IP)"
echo "Bootstrap2:    $BOOTSTRAP2_DOMAIN ($BOOTSTRAP2_IP)"
echo ""

if $DRY_RUN; then
    log_warn "DRY RUN MODE - no changes will be made"
    echo ""
fi

# Helper to run commands on a server
run_on() {
    local ip=$1
    local name=$2
    shift 2
    local cmd="$@"

    if $DRY_RUN; then
        echo "  [$name] Would run: $cmd"
        return 0
    fi

    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "ec2-user@$ip" \
        "sudo -u omerta bash -c '$cmd'"
}

# Helper to get command output from a server
get_from() {
    local ip=$1
    shift
    local cmd="$@"

    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "ec2-user@$ip" \
        "sudo -u omerta bash -c '$cmd'" 2>/dev/null
}

# Check if network already exists on bootstrap1
log "Checking if network already exists on bootstrap1..."
EXISTING_NETWORK=$(get_from "$BOOTSTRAP1_IP" "/opt/omerta/omerta network list 2>/dev/null | grep -i '$NETWORK_NAME' || true")

if [ -n "$EXISTING_NETWORK" ] && ! $FORCE; then
    log_warn "Network '$NETWORK_NAME' already exists on bootstrap1"
    echo ""
    echo "Current network info:"
    run_on "$BOOTSTRAP1_IP" "bootstrap1" "/opt/omerta/omerta network list"
    echo ""
    echo "To recreate the network, use --force (WARNING: this breaks existing peers)"
    exit 0
fi

if [ -n "$EXISTING_NETWORK" ] && $FORCE; then
    log_warn "Force flag set - will recreate network (existing peers will be orphaned)"
    echo ""
    read -p "Are you sure you want to continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# Step 1: Create network on bootstrap1
log "Step 1: Creating network on bootstrap1..."

if $DRY_RUN; then
    echo "  Would run: omerta network create --name $NETWORK_NAME --endpoint $BOOTSTRAP1_DOMAIN:9999"
    INITIAL_LINK="omerta://join/dry-run-link"
    BOOTSTRAP1_PEER_ID="dry-run-peer-id-1"
else
    # Create network and capture output
    CREATE_OUTPUT=$(run_on "$BOOTSTRAP1_IP" "bootstrap1" \
        "/opt/omerta/omerta network create --name '$NETWORK_NAME' --endpoint '$BOOTSTRAP1_DOMAIN:9999' 2>&1")

    echo "$CREATE_OUTPUT"

    # Extract the invite link from output
    INITIAL_LINK=$(echo "$CREATE_OUTPUT" | grep -o 'omerta://join/[^ ]*' | head -1)

    if [ -z "$INITIAL_LINK" ]; then
        log_error "Failed to get invite link from network creation"
        exit 1
    fi

    # Get bootstrap1's peer ID
    BOOTSTRAP1_PEER_ID=$(get_from "$BOOTSTRAP1_IP" \
        "/opt/omerta/omerta network show 2>/dev/null | grep -i 'peer.*id' | grep -o '[a-f0-9]\\{16\\}' | head -1")

    if [ -z "$BOOTSTRAP1_PEER_ID" ]; then
        # Try to extract from the link or bootstrap list
        BOOTSTRAP1_PEER_ID=$(echo "$INITIAL_LINK" | grep -o '[a-f0-9]\{16\}' | head -1)
    fi
fi

log_success "Network created on bootstrap1"
echo "  Initial link: $INITIAL_LINK"
echo "  Bootstrap1 peer ID: $BOOTSTRAP1_PEER_ID"
echo ""

# Step 2: Join network on bootstrap2
log "Step 2: Joining network on bootstrap2..."

if $DRY_RUN; then
    echo "  Would run: omerta network join '$INITIAL_LINK'"
    BOOTSTRAP2_PEER_ID="dry-run-peer-id-2"
else
    JOIN_OUTPUT=$(run_on "$BOOTSTRAP2_IP" "bootstrap2" \
        "/opt/omerta/omerta network join '$INITIAL_LINK' 2>&1")

    echo "$JOIN_OUTPUT"

    # Get bootstrap2's peer ID
    BOOTSTRAP2_PEER_ID=$(get_from "$BOOTSTRAP2_IP" \
        "/opt/omerta/omerta network show 2>/dev/null | grep -i 'peer.*id' | grep -o '[a-f0-9]\\{16\\}' | head -1")

    if [ -z "$BOOTSTRAP2_PEER_ID" ]; then
        log_error "Failed to get bootstrap2's peer ID"
        exit 1
    fi
fi

log_success "Bootstrap2 joined the network"
echo "  Bootstrap2 peer ID: $BOOTSTRAP2_PEER_ID"
echo ""

# Step 3: Add bootstrap2 as a bootstrap peer on both nodes
BOOTSTRAP2_PEER="$BOOTSTRAP2_PEER_ID@$BOOTSTRAP2_DOMAIN:9999"

log "Step 3: Adding bootstrap2 as bootstrap peer on both nodes..."

if $DRY_RUN; then
    echo "  [bootstrap1] Would run: omerta network bootstrap add '$BOOTSTRAP2_PEER'"
    echo "  [bootstrap2] Would run: omerta network bootstrap add '$BOOTSTRAP2_PEER'"
else
    # Add on bootstrap1
    run_on "$BOOTSTRAP1_IP" "bootstrap1" \
        "/opt/omerta/omerta network bootstrap add '$BOOTSTRAP2_PEER'" || true

    # Add on bootstrap2
    run_on "$BOOTSTRAP2_IP" "bootstrap2" \
        "/opt/omerta/omerta network bootstrap add '$BOOTSTRAP2_PEER'" || true
fi

log_success "Bootstrap2 added as bootstrap peer"
echo ""

# Step 4: Update omertad config with network ID on both nodes
log "Step 4: Configuring omertad with network ID..."

if ! $DRY_RUN; then
    # Get network ID
    NETWORK_ID=$(get_from "$BOOTSTRAP1_IP" \
        "/opt/omerta/omerta network list 2>/dev/null | grep -o '[a-f0-9]\\{16\\}' | head -1")

    if [ -n "$NETWORK_ID" ]; then
        for server_info in "bootstrap1:$BOOTSTRAP1_IP" "bootstrap2:$BOOTSTRAP2_IP"; do
            name="${server_info%%:*}"
            ip="${server_info##*:}"

            log "  Updating omertad.conf on $name..."
            ssh -o StrictHostKeyChecking=no "ec2-user@$ip" << REMOTE
                # Check if network= line exists
                if grep -q "^network=" /home/omerta/.omerta/omertad.conf 2>/dev/null; then
                    sudo -u omerta sed -i "s/^network=.*/network=$NETWORK_ID/" /home/omerta/.omerta/omertad.conf
                else
                    echo "network=$NETWORK_ID" | sudo -u omerta tee -a /home/omerta/.omerta/omertad.conf > /dev/null
                fi
REMOTE
        done
        log_success "omertad configured with network ID: $NETWORK_ID"
    else
        log_warn "Could not determine network ID - manual config may be needed"
    fi
fi

echo ""

# Step 5: Restart omertad on both nodes
log "Step 5: Restarting omertad on both nodes..."

if ! $DRY_RUN; then
    for server_info in "bootstrap1:$BOOTSTRAP1_IP" "bootstrap2:$BOOTSTRAP2_IP"; do
        name="${server_info%%:*}"
        ip="${server_info##*:}"

        log "  Restarting omertad on $name..."
        ssh -o StrictHostKeyChecking=no "ec2-user@$ip" \
            "sudo systemctl restart omertad" || true
    done

    sleep 3
    log_success "omertad restarted"
fi

echo ""

# Step 6: Generate final invite link
log "Step 6: Generating final invite link..."

if $DRY_RUN; then
    FINAL_LINK="omerta://join/dry-run-final-link"
else
    FINAL_LINK=$(get_from "$BOOTSTRAP1_IP" \
        "/opt/omerta/omerta network invite 2>/dev/null | grep -o 'omerta://join/[^ ]*' | head -1")
fi

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║            Network Initialization Complete                 ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Network: $NETWORK_NAME"
if [ -n "$NETWORK_ID" ]; then
    echo "Network ID: $NETWORK_ID"
fi
echo ""
echo "Bootstrap peers:"
echo "  1. ${BOOTSTRAP1_PEER_ID:-unknown}@$BOOTSTRAP1_DOMAIN:9999"
echo "  2. ${BOOTSTRAP2_PEER_ID:-unknown}@$BOOTSTRAP2_DOMAIN:9999"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "INVITE LINK (share with users to join the network):"
echo ""
echo "  $FINAL_LINK"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Save the link to a file
if ! $DRY_RUN; then
    LINK_FILE="$ROOT_DIR/network-link.txt"
    echo "$FINAL_LINK" > "$LINK_FILE"
    log_success "Invite link saved to: $LINK_FILE"
fi

echo ""
log_success "Network initialization complete!"
