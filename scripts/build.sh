#!/bin/bash
# Build omertad and omerta CLI binaries for deployment
#
# This script supports three build modes:
# 1. Local build (default) - uses Swift on your local machine
# 2. Docker build (--docker) - uses Amazon Linux 2023 container for x86_64 compatibility
# 3. Remote build (--arch-home) - builds via Docker on arch-home x86_64 machine
#
# Use --arch-home when:
# - Building on ARM machines (like Jetson) for x86_64 EC2 deployment
# - Local Docker can't run x86_64 containers efficiently
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OMERTA_DIR="$ROOT_DIR/omerta"
BUILD_DIR="$ROOT_DIR/build"

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Build omerta binaries for deployment."
    echo ""
    echo "Options:"
    echo "  --docker      Build in Amazon Linux 2023 Docker container (local x86_64)"
    echo "  --arch-home   Build via Docker on arch-home (for ARM hosts)"
    echo "  --static      Use static Swift stdlib linking (larger binaries, more portable)"
    echo "  -h, --help    Show this help"
    echo ""
    echo "Examples:"
    echo "  $0                    # Local build using system Swift"
    echo "  $0 --docker           # Build in Docker for EC2 compatibility"
    echo "  $0 --arch-home        # Build on arch-home for ARM hosts"
    echo "  $0 --docker --static  # Docker build with static linking"
    exit 1
}

USE_DOCKER=false
USE_ARCH_HOME=false
USE_STATIC=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --docker)
            USE_DOCKER=true
            shift
            ;;
        --arch-home)
            USE_ARCH_HOME=true
            shift
            ;;
        --static)
            USE_STATIC=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

echo "=== Building Omerta Binaries ==="

# Check if omerta submodule is initialized
if [ ! -f "$OMERTA_DIR/Package.swift" ]; then
    echo "Error: omerta submodule not initialized. Run: git submodule update --init"
    exit 1
fi

# Create build directory
mkdir -p "$BUILD_DIR"

# Build netstack Go library if needed
NETSTACK_DIR="$OMERTA_DIR/omerta_mesh/Sources/OmertaTunnel/Netstack"
CNETSTACK_DIR="$OMERTA_DIR/omerta_mesh/Sources/CNetstack"
if [ -f "$NETSTACK_DIR/Makefile" ]; then
    if [ ! -f "$CNETSTACK_DIR/libnetstack.a" ] || [ "$NETSTACK_DIR/tunnel_netstack.go" -nt "$CNETSTACK_DIR/libnetstack.a" ]; then
        echo "Building netstack Go library..."
        if ! command -v go &> /dev/null; then
            echo "Error: Go is required to build netstack. Install Go first."
            exit 1
        fi
        make -C "$NETSTACK_DIR" clean install
        echo ""
    fi
fi

# Determine build flags
BUILD_FLAGS="-c release --product omertad --product omerta"
if $USE_STATIC; then
    BUILD_FLAGS="$BUILD_FLAGS --static-swift-stdlib"
fi

if $USE_ARCH_HOME; then
    echo "Building on arch-home via Docker (Amazon Linux 2023 + Swift 6.0.3)..."
    echo ""

    # Check arch-home is reachable
    if ! ssh -o ConnectTimeout=5 arch-home 'echo ok' >/dev/null 2>&1; then
        echo "Error: Cannot connect to arch-home. Check SSH config."
        exit 1
    fi

    # Sync code to arch-home
    echo "Syncing code to arch-home..."
    rsync -az --delete --exclude='.git' --exclude='.build' "$OMERTA_DIR/" arch-home:~/omerta-build/

    # Clean build cache to avoid stale incremental builds
    echo "Cleaning build cache..."
    ssh arch-home "docker run --rm -v ~/omerta-build:/build omerta-builder rm -rf /build/.build" 2>/dev/null || true

    # Build netstack first, then each Swift product separately
    echo "Building netstack on arch-home..."
    ssh arch-home "cd ~/omerta-build && docker run --rm -v ~/omerta-build:/build omerta-builder make -C /build/omerta_mesh/Sources/OmertaTunnel/Netstack clean install"

    echo "Building Swift products on arch-home..."
    ssh arch-home "cd ~/omerta-build && docker run --rm -v ~/omerta-build:/build omerta-builder swift build -c release --product omerta"
    ssh arch-home "cd ~/omerta-build && docker run --rm -v ~/omerta-build:/build omerta-builder swift build -c release --product omertad"

    # Copy binaries back
    echo "Copying binaries from arch-home..."
    scp arch-home:~/omerta-build/.build/release/omerta \
        arch-home:~/omerta-build/.build/release/omertad \
        "$BUILD_DIR/"

    # Skip the normal copy step
    BIN_PATH=""

elif $USE_DOCKER; then
    echo "Building in Docker container (Amazon Linux 2023 + Swift 6.0.3)..."
    echo ""

    # Check if Docker image exists, build if not
    if ! docker image inspect omerta-builder >/dev/null 2>&1; then
        echo "Building Docker image (first time only)..."

        # Create Dockerfile
        cat > "$OMERTA_DIR/Dockerfile" << 'DOCKERFILE'
FROM amazonlinux:2023

# Install build dependencies
RUN dnf install -y \
    git \
    gcc-c++ \
    libcurl-devel \
    libuuid-devel \
    libxml2-devel \
    ncurses-devel \
    sqlite-devel \
    python3 \
    tar \
    gzip \
    golang \
    make \
    && dnf clean all

# Install Swift 6.0.3
RUN cd /tmp && \
    curl -sL "https://download.swift.org/swift-6.0.3-release/amazonlinux2/swift-6.0.3-RELEASE/swift-6.0.3-RELEASE-amazonlinux2.tar.gz" -o swift.tar.gz && \
    mkdir -p /opt/swift && \
    tar -xzf swift.tar.gz -C /opt/swift --strip-components=1 && \
    rm swift.tar.gz

ENV PATH="/opt/swift/usr/bin:${PATH}"

WORKDIR /build
DOCKERFILE

        # Create .dockerignore
        echo ".build" > "$OMERTA_DIR/.dockerignore"

        docker build -t omerta-builder "$OMERTA_DIR/"
        rm "$OMERTA_DIR/Dockerfile"
    fi

    # Run build in container (build netstack first, then Swift)
    docker run --rm \
        -v "$OMERTA_DIR:/build" \
        omerta-builder \
        bash -c "make -C /build/omerta_mesh/Sources/OmertaTunnel/Netstack clean install && swift build $BUILD_FLAGS"

    # Get bin path and copy binaries
    BIN_PATH="$OMERTA_DIR/.build/release"
else
    echo "Building locally..."
    echo ""

    cd "$OMERTA_DIR"

    # Build all products
    swift build $BUILD_FLAGS

    # Get bin path
    BIN_PATH=$(swift build -c release --product omertad --show-bin-path)
fi

# Copy binaries to build directory (skip if arch-home already copied them)
if [ -n "$BIN_PATH" ]; then
    echo ""
    echo "Copying binaries..."

    for binary in omertad omerta; do
        if [ -f "$BIN_PATH/$binary" ]; then
            cp "$BIN_PATH/$binary" "$BUILD_DIR/$binary"
            echo "  $binary -> $BUILD_DIR/$binary"
        else
            echo "Error: $binary binary not found at $BIN_PATH/$binary"
            exit 1
        fi
    done
fi

echo ""
echo "=== Build Complete ==="
echo ""
echo "Binaries:"
ls -lh "$BUILD_DIR/omertad" "$BUILD_DIR/omerta"
echo ""
echo "Binary info:"
file "$BUILD_DIR/omerta"
echo ""
echo "To deploy: ./scripts/deploy.sh prod all"
