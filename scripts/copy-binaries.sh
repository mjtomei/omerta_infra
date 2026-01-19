#!/bin/bash
# Copy binaries from one server to others
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/omerta-key.pem}"

usage() {
    echo "Usage: $0 <environment> <source-server> [target-server]"
    echo ""
    echo "Copy binaries from one server to another."
    echo ""
    echo "Arguments:"
    echo "  environment     Environment (prod, staging)"
    echo "  source-server   Server to copy from (bootstrap1 or bootstrap2)"
    echo "  target-server   Server to copy to (bootstrap1, bootstrap2, or 'all')"
    echo ""
    echo "Examples:"
    echo "  $0 prod bootstrap1 bootstrap2   # Copy from bootstrap1 to bootstrap2"
    echo "  $0 prod bootstrap1 all          # Copy from bootstrap1 to all other servers"
    exit 1
}

if [ -z "$1" ] || [ -z "$2" ]; then
    usage
fi

ENVIRONMENT="$1"
SOURCE_SERVER="$2"
TARGET_SERVER="${3:-all}"

# Get server IPs from Terraform
TF_DIR="$ROOT_DIR/terraform/environments/$ENVIRONMENT"
cd "$TF_DIR"

BOOTSTRAP1_IP=$(terraform output -raw bootstrap1_public_ip 2>/dev/null || echo "")
BOOTSTRAP2_IP=$(terraform output -raw bootstrap2_public_ip 2>/dev/null || echo "")

if [ "$SOURCE_SERVER" = "bootstrap1" ]; then
    SOURCE_IP="$BOOTSTRAP1_IP"
elif [ "$SOURCE_SERVER" = "bootstrap2" ]; then
    SOURCE_IP="$BOOTSTRAP2_IP"
else
    echo "Error: Unknown source server '$SOURCE_SERVER'"
    exit 1
fi

# Determine target servers
declare -a TARGETS
if [ "$TARGET_SERVER" = "all" ]; then
    if [ "$SOURCE_SERVER" = "bootstrap1" ]; then
        TARGETS=("bootstrap2:$BOOTSTRAP2_IP")
    else
        TARGETS=("bootstrap1:$BOOTSTRAP1_IP")
    fi
elif [ "$TARGET_SERVER" = "bootstrap1" ]; then
    TARGETS=("bootstrap1:$BOOTSTRAP1_IP")
elif [ "$TARGET_SERVER" = "bootstrap2" ]; then
    TARGETS=("bootstrap2:$BOOTSTRAP2_IP")
else
    echo "Error: Unknown target server '$TARGET_SERVER'"
    exit 1
fi

# Create temp directory for binaries
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "=== Downloading binaries from $SOURCE_SERVER ($SOURCE_IP) ==="
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
    "omerta@$SOURCE_IP:/opt/omerta/omertad" \
    "omerta@$SOURCE_IP:/opt/omerta/omerta" \
    "$TEMP_DIR/"

echo "Downloaded binaries:"
ls -la "$TEMP_DIR/"
echo ""

for target_info in "${TARGETS[@]}"; do
    name="${target_info%%:*}"
    ip="${target_info##*:}"

    echo "=== Copying to $name ($ip) ==="

    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
        "$TEMP_DIR/omertad" \
        "$TEMP_DIR/omerta" \
        "omerta@$ip:/tmp/"

    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "omerta@$ip" << 'REMOTE'
        sudo mv /tmp/omertad /opt/omerta/
        sudo mv /tmp/omerta /opt/omerta/
        sudo chown omerta:omerta /opt/omerta/*
        sudo chmod +x /opt/omerta/*
        sudo ln -sf /opt/omerta/omerta /usr/local/bin/omerta

        sudo systemctl restart omertad

        sleep 2

        echo "Service status:"
        sudo systemctl status omertad --no-pager | head -5
REMOTE

    echo "Copied to $name successfully!"
    echo ""
done

echo "=== Copy complete ==="
