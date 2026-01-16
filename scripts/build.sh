#!/bin/bash
# Build omerta-stun and omertad binaries for deployment
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OMERTA_DIR="$ROOT_DIR/omerta"
BUILD_DIR="$ROOT_DIR/build"

echo "=== Building Omerta Binaries ==="

# Check if omerta submodule is initialized
if [ ! -f "$OMERTA_DIR/Package.swift" ]; then
    echo "Error: omerta submodule not initialized. Run: git submodule update --init"
    exit 1
fi

# Create build directory
mkdir -p "$BUILD_DIR"

cd "$OMERTA_DIR"

# Build all products
echo "Building omerta-stun..."
swift build -c release --product omerta-stun

echo "Building omertad..."
swift build -c release --product omertad

echo "Building omerta CLI..."
swift build -c release --product omerta

# Get bin path
BIN_PATH=$(swift build -c release --product omerta-stun --show-bin-path)

# Copy binaries to build directory
echo "Copying binaries..."

if [ -f "$BIN_PATH/omerta-stun" ]; then
    cp "$BIN_PATH/omerta-stun" "$BUILD_DIR/omerta-stun"
    echo "  omerta-stun -> $BUILD_DIR/omerta-stun"
else
    echo "Error: omerta-stun binary not found"
    exit 1
fi

if [ -f "$BIN_PATH/omertad" ]; then
    cp "$BIN_PATH/omertad" "$BUILD_DIR/omertad"
    echo "  omertad -> $BUILD_DIR/omertad"
else
    echo "Error: omertad binary not found"
    exit 1
fi

if [ -f "$BIN_PATH/omerta" ]; then
    cp "$BIN_PATH/omerta" "$BUILD_DIR/omerta"
    echo "  omerta -> $BUILD_DIR/omerta"
else
    echo "Error: omerta binary not found"
    exit 1
fi

echo ""
echo "=== Build Complete ==="
echo ""
echo "Binaries:"
ls -lh "$BUILD_DIR/omerta-stun" "$BUILD_DIR/omertad" "$BUILD_DIR/omerta"
echo ""
echo "To deploy: ./scripts/deploy.sh prod all"
