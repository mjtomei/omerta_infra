#!/bin/bash
# Build the omerta-rendezvous binary for Linux deployment
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OMERTA_DIR="$ROOT_DIR/omerta"
BUILD_DIR="$ROOT_DIR/build"

echo "=== Building omerta-rendezvous ==="

# Check if omerta submodule is initialized
if [ ! -f "$OMERTA_DIR/Package.swift" ]; then
    echo "Error: omerta submodule not initialized. Run: git submodule update --init"
    exit 1
fi

# Create build directory
mkdir -p "$BUILD_DIR"

cd "$OMERTA_DIR"

# Build for release
echo "Building release binary..."
swift build -c release --product omerta-rendezvous

# Copy binary to build directory
BINARY_PATH=$(swift build -c release --product omerta-rendezvous --show-bin-path)/omerta-rendezvous

if [ -f "$BINARY_PATH" ]; then
    cp "$BINARY_PATH" "$BUILD_DIR/"
    echo "Binary copied to: $BUILD_DIR/omerta-rendezvous"

    # Show binary info
    file "$BUILD_DIR/omerta-rendezvous"
    ls -lh "$BUILD_DIR/omerta-rendezvous"
else
    echo "Error: Binary not found at $BINARY_PATH"
    exit 1
fi

echo ""
echo "=== Build complete ==="
echo "Binary: $BUILD_DIR/omerta-rendezvous"
