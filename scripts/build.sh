#!/bin/bash
# Build omerta-stun and omerta-mesh binaries for deployment
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

# Build both products
echo "Building omerta-stun..."
swift build -c release --product OmertaSTUNCLI

echo "Building omerta-mesh..."
swift build -c release --product OmertaMeshCLI

# Get bin path
BIN_PATH=$(swift build -c release --product OmertaSTUNCLI --show-bin-path)

# Copy binaries to build directory
echo "Copying binaries..."

if [ -f "$BIN_PATH/OmertaSTUNCLI" ]; then
    cp "$BIN_PATH/OmertaSTUNCLI" "$BUILD_DIR/omerta-stun"
    echo "  omerta-stun -> $BUILD_DIR/omerta-stun"
else
    echo "Error: OmertaSTUNCLI binary not found"
    exit 1
fi

if [ -f "$BIN_PATH/OmertaMeshCLI" ]; then
    cp "$BIN_PATH/OmertaMeshCLI" "$BUILD_DIR/omerta-mesh"
    echo "  omerta-mesh -> $BUILD_DIR/omerta-mesh"
else
    echo "Error: OmertaMeshCLI binary not found"
    exit 1
fi

echo ""
echo "=== Build Complete ==="
echo ""
echo "Binaries:"
ls -lh "$BUILD_DIR/omerta-stun" "$BUILD_DIR/omerta-mesh"
echo ""
echo "To deploy: ./scripts/deploy.sh prod all"
