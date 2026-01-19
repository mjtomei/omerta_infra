#!/bin/bash
# Build omerta binaries on a remote EC2 instance
# This is needed when your local machine has a different architecture (e.g., ARM Mac vs x86 EC2)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/omerta-key.pem}"

usage() {
    echo "Usage: $0 <environment> [options]"
    echo ""
    echo "Build omerta binaries on a remote EC2 instance."
    echo ""
    echo "Arguments:"
    echo "  environment   Environment (prod, staging)"
    echo ""
    echo "Options:"
    echo "  --server      Server to build on (bootstrap1 or bootstrap2, default: bootstrap1)"
    echo "  -h, --help    Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 prod                    # Build on bootstrap1"
    echo "  $0 prod --server bootstrap2"
    exit 1
}

# Parse arguments
ENVIRONMENT=""
BUILD_SERVER="bootstrap1"

while [[ $# -gt 0 ]]; do
    case $1 in
        --server)
            BUILD_SERVER="$2"
            shift 2
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

# Get server IP from Terraform
TF_DIR="$ROOT_DIR/terraform/environments/$ENVIRONMENT"
if [ ! -d "$TF_DIR" ]; then
    echo "Error: Environment '$ENVIRONMENT' not found"
    exit 1
fi

cd "$TF_DIR"

if [ ! -f "terraform.tfstate" ]; then
    echo "Error: No terraform state found. Run 'terraform apply' first."
    exit 1
fi

if [ "$BUILD_SERVER" = "bootstrap1" ]; then
    BUILD_IP=$(terraform output -raw bootstrap1_public_ip 2>/dev/null || echo "")
elif [ "$BUILD_SERVER" = "bootstrap2" ]; then
    BUILD_IP=$(terraform output -raw bootstrap2_public_ip 2>/dev/null || echo "")
else
    echo "Error: Unknown server '$BUILD_SERVER'"
    exit 1
fi

if [ -z "$BUILD_IP" ]; then
    echo "Error: Could not get IP for $BUILD_SERVER"
    exit 1
fi

echo "=== Building on $BUILD_SERVER ($BUILD_IP) ==="
echo ""

# Get the current commit hash from the local submodule
cd "$ROOT_DIR/omerta"
COMMIT_HASH=$(git rev-parse HEAD)
REPO_URL=$(git remote get-url origin)
cd "$ROOT_DIR"

echo "Repository: $REPO_URL"
echo "Commit: $COMMIT_HASH"
echo ""

# Build on remote server
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "omerta@$BUILD_IP" << REMOTE
set -e

echo "=== Installing Swift ==="
# Check if Swift is already installed
if command -v swift &> /dev/null; then
    echo "Swift already installed: \$(swift --version | head -1)"
else
    echo "Installing Swift..."
    # Install dependencies
    sudo dnf install -y git gcc-c++ libcurl-devel libuuid-devel libxml2-devel ncurses-devel sqlite-devel python3

    # Download and install Swift
    cd /tmp
    SWIFT_URL="https://download.swift.org/swift-6.0.3-release/amazonlinux2/swift-6.0.3-RELEASE/swift-6.0.3-RELEASE-amazonlinux2.tar.gz"
    echo "Downloading Swift from \$SWIFT_URL..."
    curl -sL "\$SWIFT_URL" -o swift.tar.gz
    sudo mkdir -p /opt/swift
    sudo tar -xzf swift.tar.gz -C /opt/swift --strip-components=1
    rm swift.tar.gz

    # Add to PATH
    echo 'export PATH=/opt/swift/usr/bin:\$PATH' | sudo tee /etc/profile.d/swift.sh
    export PATH=/opt/swift/usr/bin:\$PATH

    echo "Swift installed: \$(swift --version | head -1)"
fi

export PATH=/opt/swift/usr/bin:\$PATH

echo ""
echo "=== Cloning/Updating Repository ==="
cd /home/omerta

if [ -d "omerta" ]; then
    echo "Updating existing repo..."
    cd omerta
    git fetch origin
    git checkout $COMMIT_HASH
else
    echo "Cloning repository..."
    git clone $REPO_URL omerta
    cd omerta
    git checkout $COMMIT_HASH
fi

echo ""
echo "=== Building ==="
swift build -c release --product omerta-stun --product omertad --product omerta

echo ""
echo "=== Installing Binaries ==="
sudo cp .build/release/omerta-stun /opt/omerta/
sudo cp .build/release/omertad /opt/omerta/
sudo cp .build/release/omerta /opt/omerta/
sudo chown omerta:omerta /opt/omerta/*
sudo chmod +x /opt/omerta/*

# Symlink CLI to PATH
sudo ln -sf /opt/omerta/omerta /usr/local/bin/omerta

echo ""
echo "=== Restarting Services ==="
sudo systemctl restart omerta-stun
sudo systemctl restart omertad

sleep 3

echo ""
echo "=== Service Status ==="
sudo systemctl status omerta-stun --no-pager | head -10
echo ""
sudo systemctl status omertad --no-pager | head -10

echo ""
echo "=== Binaries ==="
ls -la /opt/omerta/
REMOTE

echo ""
echo "=== Build complete on $BUILD_SERVER ==="

# Copy binaries to other servers
if [ "$BUILD_SERVER" = "bootstrap1" ]; then
    OTHER_SERVER="bootstrap2"
    OTHER_IP=$(cd "$TF_DIR" && terraform output -raw bootstrap2_public_ip 2>/dev/null || echo "")
else
    OTHER_SERVER="bootstrap1"
    OTHER_IP=$(cd "$TF_DIR" && terraform output -raw bootstrap1_public_ip 2>/dev/null || echo "")
fi

if [ -n "$OTHER_IP" ]; then
    echo ""
    echo "=== Copying binaries to $OTHER_SERVER ($OTHER_IP) ==="

    # Create temp directory
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT

    # Download from build server
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
        "omerta@$BUILD_IP:/opt/omerta/omerta-stun" \
        "omerta@$BUILD_IP:/opt/omerta/omertad" \
        "omerta@$BUILD_IP:/opt/omerta/omerta" \
        "$TEMP_DIR/"

    # Upload to other server
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
        "$TEMP_DIR/omerta-stun" \
        "$TEMP_DIR/omertad" \
        "$TEMP_DIR/omerta" \
        "omerta@$OTHER_IP:/tmp/"

    # Install and restart on other server
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "omerta@$OTHER_IP" << 'REMOTE'
        sudo mv /tmp/omerta-stun /opt/omerta/
        sudo mv /tmp/omertad /opt/omerta/
        sudo mv /tmp/omerta /opt/omerta/
        sudo chown omerta:omerta /opt/omerta/*
        sudo chmod +x /opt/omerta/*
        sudo ln -sf /opt/omerta/omerta /usr/local/bin/omerta

        sudo systemctl restart omerta-stun
        sudo systemctl restart omertad

        sleep 2

        echo "Service status:"
        sudo systemctl status omerta-stun --no-pager | head -5
        echo ""
        sudo systemctl status omertad --no-pager | head -5
REMOTE

    echo ""
    echo "=== Binaries deployed to $OTHER_SERVER ==="
fi

echo ""
echo "=== All servers updated ==="
