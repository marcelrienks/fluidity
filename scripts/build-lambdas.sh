#!/usr/bin/env bash
set -euo pipefail

#
# build-lambdas.sh - Build and package Lambda functions for AWS deployment
#
# This script compiles the Go Lambda functions and packages them as ZIP files
# ready for deployment to AWS Lambda.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_ROOT/build/lambdas"
LAMBDAS_DIR="$PROJECT_ROOT/cmd/lambdas"
BUILD_VERSION="${BUILD_VERSION:-$(date +%Y%m%d%H%M%S)}"
echo "$BUILD_VERSION" > "$BUILD_DIR/.build_version"

echo "Building Lambda functions..."

# Create build directory
mkdir -p "$BUILD_DIR"

# List of Lambda functions to build
FUNCTIONS=("wake" "sleep" "kill")

for func in "${FUNCTIONS[@]}"; do
    echo ""
    echo "=== Building $func Lambda ==="
    
    FUNC_DIR="$LAMBDAS_DIR/$func"
    OUTPUT_DIR="$BUILD_DIR/$func"
    
    if [[ ! -d "$FUNC_DIR" ]]; then
        echo "[ERROR] Lambda function directory not found: $FUNC_DIR"
        exit 1
    fi
    
    # Create output directory
    mkdir -p "$OUTPUT_DIR"
    
    # Build for Linux (Lambda runtime)
    echo "Compiling Go binary for Linux..."
    cd "$FUNC_DIR"
    GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -ldflags="-s -w" -o "$OUTPUT_DIR/bootstrap" .
    
    if [[ ! -f "$OUTPUT_DIR/bootstrap" ]]; then
        echo "[ERROR] Failed to build $func Lambda"
        exit 1
    fi
    
    # Package as ZIP with version
    echo "Packaging as ZIP..."
    cd "$OUTPUT_DIR"
    ZIP_NAME="${func}-${BUILD_VERSION}.zip"
    zip -q "$BUILD_DIR/$ZIP_NAME" bootstrap
    rm bootstrap
    # Show size
    SIZE=$(du -h "$BUILD_DIR/$ZIP_NAME" | cut -f1)
    echo "[OK] Created $ZIP_NAME ($SIZE)"
done

echo ""
echo "=== Build Summary ==="
ls -lh "$BUILD_DIR"/*.zip
echo "Build version: $BUILD_VERSION"

echo ""
echo "[OK] All Lambda functions built successfully"
echo "Output directory: $BUILD_DIR"
