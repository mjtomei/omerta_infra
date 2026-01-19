#!/bin/bash
# Deploy omertad and omerta CLI binaries to EC2 instances
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT_DIR/build"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/omerta-key.pem}"

usage() {
    echo "Usage: $0 <environment> [server]"
    echo ""
    echo "Arguments:"
    echo "  environment   Environment to deploy to (prod, staging)"
    echo "  server        Optional: specific server (bootstrap1, bootstrap2, or 'all')"
    echo ""
    echo "Examples:"
    echo "  $0 prod all              # Deploy to all prod servers"
    echo "  $0 prod bootstrap1      # Deploy to bootstrap1 only"
    echo "  $0 staging               # Deploy to all staging servers"
    exit 1
}

if [ -z "$1" ]; then
    usage
fi

ENVIRONMENT="$1"
SERVER="${2:-all}"

# Check binaries exist
if [ ! -f "$BUILD_DIR/omertad" ] || [ ! -f "$BUILD_DIR/omerta" ]; then
    echo "Error: Binaries not found in $BUILD_DIR"
    echo "Run ./scripts/build.sh first"
    exit 1
fi

# Get IPs from Terraform outputs
TF_DIR="$ROOT_DIR/terraform/environments/$ENVIRONMENT"
if [ ! -d "$TF_DIR" ]; then
    echo "Error: Environment '$ENVIRONMENT' not found"
    exit 1
fi

cd "$TF_DIR"

# Check if Terraform has been applied
if [ ! -f "terraform.tfstate" ]; then
    echo "Error: No terraform state found. Run 'terraform apply' first."
    exit 1
fi

# Get server IPs
BOOTSTRAP1_IP=$(terraform output -raw bootstrap1_public_ip 2>/dev/null || echo "")
BOOTSTRAP2_IP=$(terraform output -raw bootstrap2_public_ip 2>/dev/null || echo "")

deploy_to_server() {
    local ip=$1
    local name=$2

    echo ""
    echo "=== Deploying to $name ($ip) ==="

    # Upload binaries
    echo "Uploading binaries..."
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
        "$BUILD_DIR/omertad" \
        "$BUILD_DIR/omerta" \
        "omerta@$ip:/tmp/"

    # Install and restart services
    echo "Installing binaries and restarting services..."
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "omerta@$ip" << 'REMOTE'
        # Install omertad
        sudo mv /tmp/omertad /opt/omerta/omertad
        sudo chmod +x /opt/omerta/omertad
        sudo chown omerta:omerta /opt/omerta/omertad

        # Install omerta CLI
        sudo mv /tmp/omerta /opt/omerta/omerta
        sudo chmod +x /opt/omerta/omerta
        sudo chown omerta:omerta /opt/omerta/omerta

        # Add to PATH via symlink
        sudo ln -sf /opt/omerta/omerta /usr/local/bin/omerta

        # Use omertad restart for graceful shutdown if running, otherwise just restart
        if sudo systemctl is-active --quiet omertad; then
            echo "Gracefully restarting omertad..."
            sudo -u omerta /opt/omerta/omertad restart --timeout 30 || true
        fi
        sudo systemctl restart omertad

        sleep 2

        echo ""
        echo "Service status:"
        echo "---------------"
        sudo systemctl status omertad --no-pager -l | head -10
REMOTE

    echo "Deployed to $name successfully!"
}

case "$SERVER" in
    all)
        [ -n "$BOOTSTRAP1_IP" ] && deploy_to_server "$BOOTSTRAP1_IP" "bootstrap1"
        [ -n "$BOOTSTRAP2_IP" ] && deploy_to_server "$BOOTSTRAP2_IP" "bootstrap2"
        ;;
    bootstrap1)
        if [ -z "$BOOTSTRAP1_IP" ]; then
            echo "Error: bootstrap1 IP not found"
            exit 1
        fi
        deploy_to_server "$BOOTSTRAP1_IP" "bootstrap1"
        ;;
    bootstrap2)
        if [ -z "$BOOTSTRAP2_IP" ]; then
            echo "Error: bootstrap2 IP not found"
            exit 1
        fi
        deploy_to_server "$BOOTSTRAP2_IP" "bootstrap2"
        ;;
    *)
        echo "Error: Unknown server '$SERVER'"
        usage
        ;;
esac

echo ""
echo "=== Deployment complete ==="
