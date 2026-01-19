#!/bin/bash
# Update omerta bootstrap servers: pull code, build, deploy, restart
# Supports rolling updates for zero-downtime deployments
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OMERTA_DIR="$ROOT_DIR/omerta"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/omerta-key.pem}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 <environment> [options]"
    echo ""
    echo "Updates bootstrap servers with latest code, binaries, and optionally configs."
    echo ""
    echo "Arguments:"
    echo "  environment       Environment to update (prod, staging)"
    echo ""
    echo "Options:"
    echo "  --server NAME     Update specific server only (bootstrap1, bootstrap2)"
    echo "  --skip-pull       Skip git submodule update (use existing code)"
    echo "  --skip-build      Skip build (use existing binaries)"
    echo "  --arch-home       Build via Docker on arch-home (for ARM hosts)"
    echo "  --docker          Build in local Docker container"
    echo "  --config          Also update omertad.conf from Terraform"
    echo "  --rolling         Rolling update (one server at a time, wait for health)"
    echo "  --dry-run         Show what would be done without doing it"
    echo "  -h, --help        Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 prod                      # Full update: pull, build, deploy all"
    echo "  $0 prod --arch-home          # Build on arch-home (for ARM hosts)"
    echo "  $0 prod --rolling            # Rolling update for zero downtime"
    echo "  $0 prod --server bootstrap1  # Update bootstrap1 only"
    echo "  $0 prod --skip-pull          # Rebuild and deploy without pulling"
    echo "  $0 prod --config             # Update binaries and config files"
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
SERVER="all"
SKIP_PULL=false
SKIP_BUILD=false
UPDATE_CONFIG=false
ROLLING=false
DRY_RUN=false
BUILD_FLAG=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --server)
            SERVER="$2"
            shift 2
            ;;
        --skip-pull)
            SKIP_PULL=true
            shift
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --arch-home)
            BUILD_FLAG="--arch-home"
            shift
            ;;
        --docker)
            BUILD_FLAG="--docker"
            shift
            ;;
        --config)
            UPDATE_CONFIG=true
            shift
            ;;
        --rolling)
            ROLLING=true
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

# Verify environment exists
TF_DIR="$ROOT_DIR/terraform/environments/$ENVIRONMENT"
if [ ! -d "$TF_DIR" ]; then
    log_error "Environment '$ENVIRONMENT' not found at $TF_DIR"
    exit 1
fi

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║           Omerta Bootstrap Server Update                   ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Environment:   $ENVIRONMENT"
echo "Server:        $SERVER"
echo "Skip pull:     $SKIP_PULL"
echo "Skip build:    $SKIP_BUILD"
echo "Build method:  ${BUILD_FLAG:-local}"
echo "Update config: $UPDATE_CONFIG"
echo "Rolling:       $ROLLING"
echo "Dry run:       $DRY_RUN"
echo ""

if $DRY_RUN; then
    log_warn "DRY RUN MODE - no changes will be made"
    echo ""
fi

# Step 1: Pull latest code
if ! $SKIP_PULL; then
    log "Updating omerta submodule..."
    if $DRY_RUN; then
        echo "  Would run: git submodule update --remote --merge"
    else
        cd "$ROOT_DIR"
        git submodule update --remote --merge

        # Show what changed
        cd "$OMERTA_DIR"
        CURRENT_COMMIT=$(git rev-parse --short HEAD)
        log_success "Submodule updated to commit $CURRENT_COMMIT"

        # Show recent commits
        echo ""
        echo "Recent commits:"
        git log --oneline -5
        echo ""
    fi
else
    log "Skipping submodule update (--skip-pull)"
fi

# Step 2: Build binaries
if ! $SKIP_BUILD; then
    log "Building binaries${BUILD_FLAG:+ ($BUILD_FLAG)}..."
    if $DRY_RUN; then
        echo "  Would run: ./scripts/build.sh $BUILD_FLAG"
    else
        "$SCRIPT_DIR/build.sh" $BUILD_FLAG
    fi
else
    log "Skipping build (--skip-build)"
    # Verify binaries exist
    BUILD_DIR="$ROOT_DIR/build"
    if [ ! -f "$BUILD_DIR/omertad" ] || [ ! -f "$BUILD_DIR/omerta" ]; then
        log_error "Binaries not found in $BUILD_DIR. Remove --skip-build or run build.sh first."
        exit 1
    fi
fi

# Step 3: Get server IPs from Terraform
cd "$TF_DIR"
if [ ! -f "terraform.tfstate" ]; then
    log_error "No terraform state found. Run 'terraform apply' first."
    exit 1
fi

BOOTSTRAP1_IP=$(terraform output -raw bootstrap1_public_ip 2>/dev/null || echo "")
BOOTSTRAP2_IP=$(terraform output -raw bootstrap2_public_ip 2>/dev/null || echo "")

# Build server list
declare -a SERVERS_TO_UPDATE
case "$SERVER" in
    all)
        [ -n "$BOOTSTRAP1_IP" ] && SERVERS_TO_UPDATE+=("bootstrap1:$BOOTSTRAP1_IP")
        [ -n "$BOOTSTRAP2_IP" ] && SERVERS_TO_UPDATE+=("bootstrap2:$BOOTSTRAP2_IP")
        ;;
    bootstrap1)
        [ -n "$BOOTSTRAP1_IP" ] && SERVERS_TO_UPDATE+=("bootstrap1:$BOOTSTRAP1_IP")
        ;;
    bootstrap2)
        [ -n "$BOOTSTRAP2_IP" ] && SERVERS_TO_UPDATE+=("bootstrap2:$BOOTSTRAP2_IP")
        ;;
    *)
        log_error "Unknown server: $SERVER"
        exit 1
        ;;
esac

if [ ${#SERVERS_TO_UPDATE[@]} -eq 0 ]; then
    log_error "No servers found to update"
    exit 1
fi

# Step 4: Deploy to servers
deploy_to_server() {
    local name=$1
    local ip=$2

    echo ""
    log "Deploying to $name ($ip)..."

    if $DRY_RUN; then
        echo "  Would upload: omertad, omerta"
        if $UPDATE_CONFIG; then
            echo "  Would update: /home/omerta/.omerta/omertad.conf"
        fi
        echo "  Would restart: omertad"
        return 0
    fi

    BUILD_DIR="$ROOT_DIR/build"

    # Upload binaries
    log "  Uploading binaries..."
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "$BUILD_DIR/omertad" \
        "$BUILD_DIR/omerta" \
        "omerta@$ip:/tmp/"

    # Prepare config update command if needed
    CONFIG_CMD=""
    if $UPDATE_CONFIG; then
        log "  Updating config..."
        # Generate config from current Terraform values
        # Note: For more complex config updates, you might want to template this
        CONFIG_CMD='
        # Update omertad.conf (preserving network= line)
        NETWORK_LINE=$(grep "^network=" /home/omerta/.omerta/omertad.conf 2>/dev/null || echo "")
        cat > /tmp/omertad.conf.new << CONF
# Omerta Daemon Configuration
# Updated by update.sh

# Mesh port
port=9999

# Relay mode - disabled to minimize bandwidth costs
can-relay=false

# Hole punch coordination - enabled for NAT traversal
can-coordinate-hole-punch=true
CONF
        if [ -n "$NETWORK_LINE" ]; then
            echo "$NETWORK_LINE" >> /tmp/omertad.conf.new
        fi
        sudo mv /tmp/omertad.conf.new /home/omerta/.omerta/omertad.conf
        sudo chown omerta:omerta /home/omerta/.omerta/omertad.conf
        '
    fi

    # Install and restart
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "omerta@$ip" << REMOTE
        set -e

        # Install binaries
        sudo mv /tmp/omertad /opt/omerta/omertad
        sudo mv /tmp/omerta /opt/omerta/omerta
        sudo chmod +x /opt/omerta/omertad /opt/omerta/omerta
        sudo chown omerta:omerta /opt/omerta/omertad /opt/omerta/omerta
        sudo ln -sf /opt/omerta/omerta /usr/local/bin/omerta

        $CONFIG_CMD

        # Graceful restart for omertad if running
        if sudo systemctl is-active --quiet omertad; then
            echo "Gracefully restarting omertad..."
            sudo -u omerta /opt/omerta/omertad restart --timeout 30 || true
        fi
        sudo systemctl restart omertad

        sleep 2

        # Verify services are running
        if ! sudo systemctl is-active --quiet omertad; then
            echo "ERROR: omertad failed to start"
            sudo journalctl -u omertad -n 10 --no-pager
            exit 1
        fi

        echo "Services running successfully"
REMOTE

    log_success "Deployed to $name"
}

wait_for_health() {
    local name=$1
    local ip=$2
    local max_attempts=30
    local attempt=1

    log "  Waiting for $name to be healthy..."

    while [ $attempt -le $max_attempts ]; do
        if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "omerta@$ip" \
            "sudo systemctl is-active --quiet omertad" 2>/dev/null; then
            log_success "  $name is healthy"
            return 0
        fi
        echo -n "."
        sleep 2
        ((attempt++))
    done

    log_error "  $name failed health check after $max_attempts attempts"
    return 1
}

# Deploy to servers
if $ROLLING && [ ${#SERVERS_TO_UPDATE[@]} -gt 1 ]; then
    log "Starting rolling update..."
    for server_info in "${SERVERS_TO_UPDATE[@]}"; do
        name="${server_info%%:*}"
        ip="${server_info##*:}"

        deploy_to_server "$name" "$ip"

        if ! $DRY_RUN; then
            wait_for_health "$name" "$ip"
            log "Waiting 10 seconds before next server..."
            sleep 10
        fi
    done
else
    for server_info in "${SERVERS_TO_UPDATE[@]}"; do
        name="${server_info%%:*}"
        ip="${server_info##*:}"
        deploy_to_server "$name" "$ip"
    done
fi

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                    Update Complete                         ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

if ! $DRY_RUN; then
    log "Checking final status..."
    for server_info in "${SERVERS_TO_UPDATE[@]}"; do
        name="${server_info%%:*}"
        ip="${server_info##*:}"
        echo ""
        echo "=== $name ($ip) ==="
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "omerta@$ip" \
            "sudo systemctl status omertad --no-pager -l 2>&1 | head -5" \
            2>/dev/null || echo "Could not get status"
    done
fi

echo ""
log_success "All updates complete!"
