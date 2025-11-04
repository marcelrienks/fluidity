#!/usr/bin/env bash
set -euo pipefail

#
# build.sh - Build Fluidity server and agent binaries
#
# This script compiles the Fluidity server and agent with support for:
# - Native builds (current platform)
# - Linux builds (for Docker/deployment)
# - Individual or combined builds
#
# Usage:
#   ./build.sh [OPTIONS]
#
# Options:
#   --help, -h           Show this help message
#   --agent              Build only the agent
#   --server             Build only the server
#   --linux              Build for Linux (static binary)
#   --clean              Clean build directory before building
#   --all                Build everything (server, agent, lambdas)
#
# Examples:
#   ./build.sh                      # Build server and agent for current platform
#   ./build.sh --linux              # Build server and agent for Linux
#   ./build.sh --agent --linux      # Build only agent for Linux
#   ./build.sh --clean --all        # Clean, then build everything
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_ROOT/build"
CMD_DIR="$PROJECT_ROOT/cmd/core"
BUILD_VERSION="${BUILD_VERSION:-$(date +%Y%m%d%H%M%S)}"
echo "$BUILD_VERSION" > "$BUILD_DIR/.build_version"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default options
BUILD_AGENT=false
BUILD_SERVER=false
BUILD_LINUX=false
CLEAN=false
BUILD_ALL=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            grep '^#' "$0" | grep -v '#!/usr/bin/env' | sed 's/^# //; s/^#//'
            exit 0
            ;;
        --agent)
            BUILD_AGENT=true
            shift
            ;;
        --server)
            BUILD_SERVER=true
            shift
            ;;
        --linux)
            BUILD_LINUX=true
            shift
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        --all)
            BUILD_ALL=true
            shift
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# If no specific component selected, build both
if [[ "$BUILD_AGENT" == false && "$BUILD_SERVER" == false && "$BUILD_ALL" == false ]]; then
    BUILD_AGENT=true
    BUILD_SERVER=true
fi

# If --all is set, build everything
if [[ "$BUILD_ALL" == true ]]; then
    BUILD_AGENT=true
    BUILD_SERVER=true
fi

# Clean if requested
if [[ "$CLEAN" == true ]]; then
    echo -e "${YELLOW}Cleaning build directory...${NC}"
    rm -rf "$BUILD_DIR"
    echo -e "${GREEN}✓ Build directory cleaned${NC}"
    echo ""
fi

# Create build directory
mkdir -p "$BUILD_DIR"

# Determine build flags
GOOS=""
GOARCH=""
CGO_ENABLED=""
BINARY_SUFFIX=""

if [[ "$BUILD_LINUX" == true ]]; then
    GOOS="linux"
    GOARCH="amd64"
    CGO_ENABLED="0"
    echo -e "${CYAN}Building for Linux (static binary)${NC}"
else
    echo -e "${CYAN}Building for current platform${NC}"
fi

echo ""

# Build server
if [[ "$BUILD_SERVER" == true ]]; then
    echo -e "${YELLOW}=== Building Server ===${NC}"
    
    SERVER_DIR="$CMD_DIR/server"
    SERVER_BINARY="fluidity-server${BINARY_SUFFIX}"
    SERVER_IMAGE_TAG="$BUILD_VERSION"
    
    if [[ ! -d "$SERVER_DIR" ]]; then
        echo -e "${RED}[ERROR] Server directory not found: $SERVER_DIR${NC}"
        exit 1
    fi
    
    cd "$SERVER_DIR"
    
    BUILD_CMD="go build -ldflags='-s -w' -o $BUILD_DIR/$SERVER_BINARY ."
    
    if [[ -n "$GOOS" ]]; then
    BUILD_CMD="GOOS=$GOOS GOARCH=$GOARCH CGO_ENABLED=$CGO_ENABLED $BUILD_CMD"
    fi
    
    echo "Compiling: $SERVER_BINARY"
    eval $BUILD_CMD
    
    if [[ ! -f "$BUILD_DIR/$SERVER_BINARY" ]]; then
        echo -e "${RED}[ERROR] Failed to build server${NC}"
        exit 1
    fi
    
    SIZE=$(du -h "$BUILD_DIR/$SERVER_BINARY" | cut -f1)
    echo -e "${GREEN}✓ Server built successfully ($SIZE)${NC}"
    echo "Server image tag: $SERVER_IMAGE_TAG"
    echo ""
fi

# Build agent
if [[ "$BUILD_AGENT" == true ]]; then
    echo -e "${YELLOW}=== Building Agent ===${NC}"
    
    AGENT_DIR="$CMD_DIR/agent"
    AGENT_BINARY="fluidity-agent${BINARY_SUFFIX}"
    
    if [[ ! -d "$AGENT_DIR" ]]; then
        echo -e "${RED}[ERROR] Agent directory not found: $AGENT_DIR${NC}"
        exit 1
    fi
    
    cd "$AGENT_DIR"
    
    BUILD_CMD="go build -ldflags='-s -w' -o $BUILD_DIR/$AGENT_BINARY ."
    
    if [[ -n "$GOOS" ]]; then
        BUILD_CMD="GOOS=$GOOS GOARCH=$GOARCH CGO_ENABLED=$CGO_ENABLED $BUILD_CMD"
    fi
    
    echo "Compiling: $AGENT_BINARY"
    eval $BUILD_CMD
    
    if [[ ! -f "$BUILD_DIR/$AGENT_BINARY" ]]; then
        echo -e "${RED}[ERROR] Failed to build agent${NC}"
        exit 1
    fi
    
    SIZE=$(du -h "$BUILD_DIR/$AGENT_BINARY" | cut -f1)
    echo -e "${GREEN}✓ Agent built successfully ($SIZE)${NC}"
    echo ""
fi

# Build lambdas if --all was specified
if [[ "$BUILD_ALL" == true ]]; then
    echo -e "${YELLOW}=== Building Lambda Functions ===${NC}"
    "$SCRIPT_DIR/build-lambdas.sh"
    echo ""
fi

# Summary
echo -e "${CYAN}=== Build Summary ===${NC}"
if [[ -d "$BUILD_DIR" ]]; then
    ls -lh "$BUILD_DIR" 2>/dev/null | grep -E '(fluidity-|\.zip)' || echo "No binaries found"
fi

echo ""
echo -e "${GREEN}[OK] Build completed successfully${NC}"
echo "Output directory: $BUILD_DIR"
