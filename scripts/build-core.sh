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

# Logging functions (consistent with deploy-fluidity.sh)
log_header() {
    echo ""
    echo "================================================================================"
    echo "$*"
    echo "================================================================================"
    echo ""
}

log_section() {
    echo ""
    echo "==="
    echo "$*"
    echo "==="
}

log_substep() {
    echo ""
    echo "--- $*"
}

log_info() {
    echo "[INFO] $*"
}

log_success() {
    echo "✓ $*"
}

log_error() {
    echo "[ERROR] $*" >&2
}

log_debug() {
    echo "[DEBUG] $*" >&2
}

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
    log_info "Building for Linux (static binary)"
else
    log_info "Building for current platform"
fi

# Build server
if [[ "$BUILD_SERVER" == true ]]; then
    log_substep "Building Server"
    
    SERVER_DIR="$CMD_DIR/server"
    SERVER_BINARY="fluidity-server${BINARY_SUFFIX}"
    SERVER_IMAGE_TAG="$BUILD_VERSION"
    
    if [[ ! -d "$SERVER_DIR" ]]; then
        log_error "Server directory not found: $SERVER_DIR"
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
        log_error "Failed to build server"
        exit 1
    fi
    
    SIZE=$(du -h "$BUILD_DIR/$SERVER_BINARY" | cut -f1)
    log_success "Server built successfully ($SIZE)"
    log_info "Server image tag: $SERVER_IMAGE_TAG"
fi

# Build agent
if [[ "$BUILD_AGENT" == true ]]; then
    log_substep "Building Agent"
    
    AGENT_DIR="$CMD_DIR/agent"
    AGENT_BINARY="fluidity-agent${BINARY_SUFFIX}"
    
    if [[ ! -d "$AGENT_DIR" ]]; then
        log_error "Agent directory not found: $AGENT_DIR"
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
        log_error "Failed to build agent"
        exit 1
    fi
    
    SIZE=$(du -h "$BUILD_DIR/$AGENT_BINARY" | cut -f1)
    log_success "Agent built successfully ($SIZE)"
fi

# Build lambdas if --all was specified
if [[ "$BUILD_ALL" == true ]]; then
    log_substep "Building Lambda Functions"
    "$SCRIPT_DIR/build-lambdas.sh"
fi

# Summary
log_substep "Build Summary"
if [[ -d "$BUILD_DIR" ]]; then
    ls -lh "$BUILD_DIR" 2>/dev/null | grep -E '(fluidity-|\.zip)' || echo "No binaries found"
fi

echo ""
log_success "Build completed successfully"
log_info "Output directory: $BUILD_DIR"
