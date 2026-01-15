#!/bin/bash
# Deploy omerta-rendezvous binary to EC2 instances
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT_DIR/build"
BINARY="$BUILD_DIR/omerta-rendezvous"

usage() {
    echo "Usage: $0 <environment> [server]"
    echo ""
    echo "Arguments:"
    echo "  environment   Environment to deploy to (prod, staging)"
    echo "  server        Optional: specific server (rendezvous1, rendezvous2, or 'all')"
    echo ""
    echo "Examples:"
    echo "  $0 prod all              # Deploy to all prod servers"
    echo "  $0 prod rendezvous1      # Deploy to rendezvous1 only"
    echo "  $0 staging               # Deploy to all staging servers"
    exit 1
}

if [ -z "$1" ]; then
    usage
fi

ENVIRONMENT="$1"
SERVER="${2:-all}"

# Check binary exists
if [ ! -f "$BINARY" ]; then
    echo "Error: Binary not found at $BINARY"
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
RENDEZVOUS1_IP=$(terraform output -raw rendezvous1_public_ip 2>/dev/null || echo "")
RENDEZVOUS2_IP=$(terraform output -raw rendezvous2_public_ip 2>/dev/null || echo "")

deploy_to_server() {
    local ip=$1
    local name=$2

    echo ""
    echo "=== Deploying to $name ($ip) ==="

    # Upload binary
    echo "Uploading binary..."
    scp -o StrictHostKeyChecking=no "$BINARY" "ec2-user@$ip:/tmp/omerta-rendezvous"

    # Install and restart service
    echo "Installing and restarting service..."
    ssh -o StrictHostKeyChecking=no "ec2-user@$ip" << 'REMOTE'
        sudo mv /tmp/omerta-rendezvous /opt/omerta/omerta-rendezvous
        sudo chmod +x /opt/omerta/omerta-rendezvous
        sudo chown omerta:omerta /opt/omerta/omerta-rendezvous
        sudo systemctl restart omerta-rendezvous
        sleep 2
        sudo systemctl status omerta-rendezvous --no-pager
REMOTE

    echo "Deployed to $name successfully!"
}

case "$SERVER" in
    all)
        [ -n "$RENDEZVOUS1_IP" ] && deploy_to_server "$RENDEZVOUS1_IP" "rendezvous1"
        [ -n "$RENDEZVOUS2_IP" ] && deploy_to_server "$RENDEZVOUS2_IP" "rendezvous2"
        ;;
    rendezvous1)
        if [ -z "$RENDEZVOUS1_IP" ]; then
            echo "Error: rendezvous1 IP not found"
            exit 1
        fi
        deploy_to_server "$RENDEZVOUS1_IP" "rendezvous1"
        ;;
    rendezvous2)
        if [ -z "$RENDEZVOUS2_IP" ]; then
            echo "Error: rendezvous2 IP not found"
            exit 1
        fi
        deploy_to_server "$RENDEZVOUS2_IP" "rendezvous2"
        ;;
    *)
        echo "Error: Unknown server '$SERVER'"
        usage
        ;;
esac

echo ""
echo "=== Deployment complete ==="
