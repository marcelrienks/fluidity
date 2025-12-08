#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Fluidity Core Build Script
#
# Compiles Fluidity server and agent binaries with support for:
# - Native builds (current platform)
# - Linux builds (for Docker/deployment)
# - Individual or combined builds
#
# USAGE:
#   ./build-core.sh [OPTIONS]
#
# OPTIONS:
#   --agent              Build only the agent
#   --server             Build only the server
#   --linux              Build for Linux (static binary)
#   --clean              Clean build directory before building
#   --all                Build everything (server, agent, lambdas)
#   --debug              Enable debug logging
#   -h, --help           Show this help message
#
# EXAMPLES:
#   ./build-core.sh                      # Build server and agent for current platform
#   ./build-core.sh --linux              # Build server and agent for Linux
#   ./build-core.sh --agent --linux      # Build only agent for Linux
#   ./build-core.sh --clean --all        # Clean, then build everything
#
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_ROOT/build"
CMD_DIR="$PROJECT_ROOT/cmd/core"

# Source shared logging library
source "$SCRIPT_DIR/lib-logging.sh"

# Build version
BUILD_VERSION="${BUILD_VERSION:-$(date +%Y%m%d%H%M%S)}"
mkdir -p "$BUILD_DIR"
echo "$BUILD_VERSION" > "$BUILD_DIR/.build_version"

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
            sed -n '3,/^###############################################################################$/p' "$0" | sed '$d' | sed 's/^# *//'
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
        --debug)
            DEBUG=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
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

# ============================================================================
# BUILD FUNCTIONS
# ============================================================================

# Clean if requested
if [[ "$CLEAN" == true ]]; then
    log_minor "Cleaning Build Directory"
    rm -rf "$BUILD_DIR"
    log_success "Build directory cleaned"
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
    log_minor "Build Server"
    
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
    
    log_substep "Compiling Server Binary"
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
    log_minor "Build Agent"
    
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
    
    log_substep "Compiling Agent Binary"
    echo "Compiling: $AGENT_BINARY"
    eval $BUILD_CMD
    
    if [[ ! -f "$BUILD_DIR/$AGENT_BINARY" ]]; then
        log_error "Failed to build agent"
        exit 1
    fi
    
    SIZE=$(du -h "$BUILD_DIR/$AGENT_BINARY" | cut -f1)
    log_success "Agent built successfully ($SIZE)"

    # Provide a default development config alongside the built binary
    DEFAULT_CONFIG_SOURCE="${PROJECT_ROOT}/configs/agent.local.yaml"
    FALLBACK_CONFIG_SOURCE="${PROJECT_ROOT}/configs/agent.yaml"
    TARGET_CONFIG="${BUILD_DIR}/agent.yaml"
    if [[ -f "$TARGET_CONFIG" ]]; then
        log_info "Existing build config retained: $TARGET_CONFIG"
    else
        if [[ -f "$DEFAULT_CONFIG_SOURCE" ]]; then
            cp "$DEFAULT_CONFIG_SOURCE" "$TARGET_CONFIG"
            log_success "Copied development config to build directory (agent.yaml)"
        elif [[ -f "$FALLBACK_CONFIG_SOURCE" ]]; then
            cp "$FALLBACK_CONFIG_SOURCE" "$TARGET_CONFIG"
            log_success "Copied fallback config to build directory (agent.yaml)"
        else
            log_info "No template agent config found to copy into build directory"
        fi
    fi
fi

# Build lambdas if --all was specified
if [[ "$BUILD_ALL" == true ]]; then
    log_minor "Build Lambda Functions"
    "$SCRIPT_DIR/build-lambdas.sh"
fi

# Summary
log_minor "Build Summary"
if [[ -d "$BUILD_DIR" ]]; then
    ls -lh "$BUILD_DIR" 2>/dev/null | grep -E '(fluidity-|\.zip)' || echo "No binaries found"
fi

echo ""
log_success "Build completed successfully"
log_info "Output directory: $BUILD_DIR"
