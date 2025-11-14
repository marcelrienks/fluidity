#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# build-docker.sh - Build Fluidity Docker images with platform targeting
#
# PURPOSE:
#   Builds Docker images for Fluidity server and/or agent with explicit
#   platform targeting for AWS Fargate (linux/amd64). This script ensures
#   binaries are compiled for the correct architecture before containerization.
#
# FUNCTION:
#   1. Builds Go binaries for linux/amd64 using build-core.sh
#   2. Creates Alpine-based Docker images (~44MB each)
#   3. Tags images with version and latest tags
#   4. Optionally pushes to AWS ECR
#
# USAGE:
#   ./build-docker.sh [OPTIONS]
#
# OPTIONS:
#   --server                Build server Docker image
#   --agent                 Build agent Docker image
#   --version <version>     Build version tag (default: timestamp)
#   --push                  Push to AWS ECR after building
#   --ecr-repo <uri>        ECR repository URI (required with --push)
#   --region <region>       AWS region (required with --push)
#   --platform <platform>   Target platform (default: linux/amd64)
#   --debug                 Enable debug output
#   -h, --help              Show this help message
#
# EXAMPLES:
#   # Build both server and agent locally
#   ./build-docker.sh
#
#   # Build only server for Fargate (explicit platform)
#   ./build-docker.sh --server --platform linux/amd64
#
#   # Build and push to ECR
#   ./build-docker.sh --server --push \
#     --ecr-repo 123456789012.dkr.ecr.us-east-1.amazonaws.com/fluidity-server \
#     --region us-east-1
#
#   # Build with specific version
#   ./build-docker.sh --server --version v1.2.3
#
# NOTES:
#   - AWS Fargate requires linux/amd64 architecture
#   - Binaries are built by build-core.sh before containerization
#   - Docker daemon must be running
#   - For ECR push, AWS CLI must be configured
#
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_ROOT/build"

# Color definitions (light pastel palette)
PALE_BLUE='\033[38;5;153m'       # Light pastel blue (major headers)
PALE_YELLOW='\033[38;5;229m'     # Light pastel yellow (minor headers)
PALE_GREEN='\033[38;5;193m'      # Light pastel green (sub-headers)
WHITE='\033[1;37m'               # Standard white (info logs)
RED='\033[0;31m'                 # Standard red (errors)
RESET='\033[0m'
NC='\033[0m' # No Color

# Default options
BUILD_SERVER=false
BUILD_AGENT=false
BUILD_VERSION=""
PUSH_TO_ECR=false
ECR_REPO=""
REGION=""
TARGET_PLATFORM="linux/amd64"
DEBUG=false

# Derived values
GOOS=""
GOARCH=""

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

log_header() {
    echo ""
    echo ""
    echo -e "${PALE_BLUE}================================================================================${RESET}"
    echo -e "${PALE_BLUE}$*${RESET}"
    echo -e "${PALE_BLUE}================================================================================${RESET}"
}

log_minor() {
    echo ""
    echo ""
    echo -e "${PALE_YELLOW}$*${RESET}"
    echo -e "${PALE_YELLOW}================================================================================${RESET}"
}

log_substep() {
    echo ""
    echo ""
    echo -e "${PALE_GREEN}$*${RESET}"
    echo -e "${PALE_GREEN}--------------------------------------------------------------------------------${RESET}"
}

log_info() {
    echo "[INFO] $*"
}

log_success() {
    echo "✓ $*"
}

log_error() {
    echo -e "${RED}[ERROR] $*${RESET}" >&2
}

log_debug() {
    if [[ "$DEBUG" == "true" ]]; then
        echo "[DEBUG] $*" >&2
    fi
}

# ============================================================================
# HELP & VALIDATION
# ============================================================================

show_help() {
    sed -n '3,/^###############################################################################$/p' "$0" | sed '$d' | sed 's/^# *//'
    exit 0
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --server)
                BUILD_SERVER=true
                shift
                ;;
            --agent)
                BUILD_AGENT=true
                shift
                ;;
            --version)
                BUILD_VERSION="$2"
                shift 2
                ;;
            --push)
                PUSH_TO_ECR=true
                shift
                ;;
            --ecr-repo)
                ECR_REPO="$2"
                shift 2
                ;;
            --region)
                REGION="$2"
                shift 2
                ;;
            --platform)
                TARGET_PLATFORM="$2"
                shift 2
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            -h|--help)
                show_help
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

validate_options() {
    # If no component selected, build both
    if [[ "$BUILD_SERVER" == false && "$BUILD_AGENT" == false ]]; then
        BUILD_SERVER=true
        BUILD_AGENT=true
    fi

    # Generate version if not provided
    if [[ -z "$BUILD_VERSION" ]]; then
        BUILD_VERSION=$(date +%Y%m%d%H%M%S)
        log_debug "Generated build version: $BUILD_VERSION"
    fi

    # Validate push options
    if [[ "$PUSH_TO_ECR" == "true" ]]; then
        if [[ -z "$ECR_REPO" ]]; then
            log_error "--ecr-repo is required when using --push"
            exit 1
        fi
        if [[ -z "$REGION" ]]; then
            log_error "--region is required when using --push"
            exit 1
        fi
    fi

    # Parse platform
    if [[ "$TARGET_PLATFORM" =~ ^linux/(.+)$ ]]; then
        GOOS="linux"
        GOARCH="${BASH_REMATCH[1]}"
    elif [[ "$TARGET_PLATFORM" =~ ^darwin/(.+)$ ]]; then
        GOOS="darwin"
        GOARCH="${BASH_REMATCH[1]}"
    elif [[ "$TARGET_PLATFORM" =~ ^windows/(.+)$ ]]; then
        GOOS="windows"
        GOARCH="${BASH_REMATCH[1]}"
    else
        log_error "Invalid platform format: $TARGET_PLATFORM (expected: os/arch)"
        exit 1
    fi

    log_debug "Target Platform: $TARGET_PLATFORM (GOOS=$GOOS, GOARCH=$GOARCH)"
}

# ============================================================================
# PREREQUISITE CHECKS
# ============================================================================

check_prerequisites() {
    log_minor "Checking Prerequisites"

    # Check Docker
    if ! command -v docker &>/dev/null; then
        log_error "Docker not found"
        echo "Install from: https://www.docker.com/products/docker-desktop"
        exit 1
    fi
    log_debug "Docker found: $(docker --version)"

    # Check Docker daemon and attempt to start if not running
    if ! docker ps &>/dev/null 2>&1; then
        log_info "Docker daemon is not accessible, attempting to start..."
        
        # Detect OS and attempt to start Docker
        if [[ "$(uname -s)" == "Linux" ]]; then
            # Linux: Check if running in WSL
            if grep -qi microsoft /proc/version 2>/dev/null; then
                log_info "WSL detected - attempting to start Docker Desktop via PowerShell"
                if powershell.exe -Command "Start-Process 'C:\Program Files\Docker\Docker\Docker Desktop.exe'" 2>/dev/null; then
                    log_info "Docker Desktop start command sent"
                    log_info "Giving Docker Desktop time to initialize..."
                    sleep 10
                else
                    log_error "Failed to start Docker Desktop"
                    echo "Please start Docker Desktop manually:"
                    echo "  1. Open Docker Desktop application"
                    echo "  2. Ensure WSL 2 integration is enabled in Settings"
                    exit 1
                fi
            else
                # Native Linux
                log_info "Attempting to start Docker service..."
                if command -v systemctl &>/dev/null; then
                    sudo systemctl start docker
                elif command -v service &>/dev/null; then
                    sudo service docker start
                else
                    log_error "Cannot start Docker service automatically"
                    echo "Please start Docker manually: sudo systemctl start docker"
                    exit 1
                fi
            fi
        elif [[ "$(uname -s)" == "Darwin" ]]; then
            # macOS
            log_info "macOS detected - attempting to start Docker Desktop"
            open -a "Docker" 2>/dev/null || {
                log_error "Failed to start Docker Desktop"
                echo "Please start Docker Desktop manually from Applications"
                exit 1
            }
        else
            log_error "Docker daemon is not accessible"
            echo "Please start Docker Desktop manually"
            exit 1
        fi
        
        # Wait for Docker daemon to become available (extended timeout for Windows)
        log_info "Waiting for Docker daemon to start (up to 180 seconds)..."
        local wait_time=0
        local max_wait=180
        local retry_count=0
        while [[ $wait_time -lt $max_wait ]]; do
            # Try to connect to docker daemon
            if docker ps &>/dev/null 2>&1; then
                log_success "Docker daemon is now accessible"
                break
            fi
            
            # For WSL, also check if Docker socket is accessible
            if [[ -S /var/run/docker.sock ]]; then
                # Socket exists, try one more time with explicit socket check
                if docker ps &>/dev/null 2>&1; then
                    log_success "Docker daemon is now accessible"
                    break
                fi
            fi
            
            sleep 3
            wait_time=$((wait_time + 3))
            retry_count=$((retry_count + 1))
            
            # Show progress every 15 seconds
            if [[ $((retry_count % 5)) -eq 0 ]]; then
                log_debug "Still waiting for Docker daemon ($wait_time/${max_wait}s)..."
            fi
            echo -n "."
        done
        echo ""
        
        # Final check with better error messaging
        if ! docker ps &>/dev/null 2>&1; then
            log_error "Docker daemon failed to start within ${max_wait}s"
            
            # Provide WSL-specific troubleshooting
            if grep -qi microsoft /proc/version 2>/dev/null; then
                echo "WSL-specific troubleshooting steps:"
                echo "  1. Ensure Docker Desktop is running on Windows"
                echo "  2. Check that WSL 2 integration is enabled in Docker Desktop settings"
                echo "  3. Verify WSL 2 is the default distro: wsl --set-default-version 2"
                echo "  4. Try manually connecting: docker ps"
                echo "  5. Restart WSL: wsl --shutdown"
                echo ""
            fi
            echo "Please ensure Docker Desktop is running and try again"
            exit 1
        fi
    else
        log_debug "Docker daemon is accessible"
    fi

    # Check build-core.sh exists
    if [[ ! -f "$SCRIPT_DIR/build-core.sh" ]]; then
        log_error "build-core.sh not found at: $SCRIPT_DIR/build-core.sh"
        exit 1
    fi
    log_debug "build-core.sh found"

    # Check Dockerfiles exist
    if [[ "$BUILD_SERVER" == "true" && ! -f "$PROJECT_ROOT/deployments/server/Dockerfile" ]]; then
        log_error "Server Dockerfile not found"
        exit 1
    fi
    if [[ "$BUILD_AGENT" == "true" && ! -f "$PROJECT_ROOT/deployments/agent/Dockerfile" ]]; then
        log_error "Agent Dockerfile not found"
        exit 1
    fi
    log_debug "Dockerfiles verified"

    # Check AWS CLI if pushing
    if [[ "$PUSH_TO_ECR" == "true" ]]; then
        if ! command -v aws &>/dev/null; then
            log_error "AWS CLI not found (required for --push)"
            exit 1
        fi
        log_debug "AWS CLI found: $(aws --version)"
    fi

    log_success "Prerequisites check passed"
}

# ============================================================================
# BUILD FUNCTIONS
# ============================================================================

build_binaries() {
    log_info "Building binaries for $TARGET_PLATFORM..."

    local build_args="--linux"  # Always use --linux flag for cross-compilation
    
    if [[ "$BUILD_SERVER" == "true" && "$BUILD_AGENT" == "false" ]]; then
        build_args="$build_args --server"
    elif [[ "$BUILD_AGENT" == "true" && "$BUILD_SERVER" == "false" ]]; then
        build_args="$build_args --agent"
    fi
    # If both, build-core.sh will build both by default

    log_debug "Running: BUILD_VERSION=$BUILD_VERSION bash $SCRIPT_DIR/build-core.sh $build_args"
    
    if BUILD_VERSION="$BUILD_VERSION" bash "$SCRIPT_DIR/build-core.sh" $build_args; then
        log_success "Binaries built successfully"
    else
        log_error "Binary build failed"
        exit 1
    fi

    # Verify binaries exist
    if [[ "$BUILD_SERVER" == "true" && ! -f "$BUILD_DIR/fluidity-server" ]]; then
        log_error "Server binary not found after build"
        exit 1
    fi
    if [[ "$BUILD_AGENT" == "true" && ! -f "$BUILD_DIR/fluidity-agent" ]]; then
        log_error "Agent binary not found after build"
        exit 1
    fi

    log_debug "Binary verification passed"
}

build_docker_image() {
    local component="$1"  # "server" or "agent"
    local dockerfile="$PROJECT_ROOT/deployments/$component/Dockerfile"
    local image_name="fluidity-$component"
    
    log_substep "Building Docker image: $image_name:$BUILD_VERSION"
    log_debug "Dockerfile: $dockerfile"
    log_debug "Build context: $PROJECT_ROOT"
    log_debug "Platform: $TARGET_PLATFORM"

    # Build with explicit platform (use plain progress to avoid PowerShell parsing issues with buildkit format)
    local build_output
    build_output=$(docker build \
        --platform "$TARGET_PLATFORM" \
        --progress=plain \
        -f "$dockerfile" \
        -t "$image_name:$BUILD_VERSION" \
        "$PROJECT_ROOT" 2>&1)
    
    local build_status=$?
    
    # Filter and display output (remove buildkit format lines and blank lines)
    echo "$build_output" | grep -v -E '^#[0-9]|^$' || true
    
    if [[ $build_status -eq 0 ]]; then
        
        log_success "Docker image built: $image_name:$BUILD_VERSION"
        
        # Show image size
        local size
        size=$(docker images "$image_name:$BUILD_VERSION" --format "{{.Size}}")
        log_info "Image size: $size"
    else
        log_error "Docker build failed for $component"
        return 1
    fi
}

push_to_ecr() {
    local component="$1"
    local image_name="fluidity-$component"
    
    log_info "Pushing $image_name to ECR..."
    
    # Login to ECR
    log_info "Authenticating with ECR..."
    if ! aws ecr get-login-password --region "$REGION" | \
         docker login --username AWS --password-stdin \
         "$(echo "$ECR_REPO" | cut -d/ -f1)" 2>/dev/null; then
        log_error "ECR authentication failed"
        return 1
    fi
    log_debug "ECR authentication successful"

    # Tag for ECR
    local ecr_image="$ECR_REPO:$BUILD_VERSION"
    log_debug "Tagging: $image_name:$BUILD_VERSION -> $ecr_image"
    docker tag "$image_name:$BUILD_VERSION" "$ecr_image"

    # Push to ECR
    log_info "Pushing to ECR: $ecr_image"
    if docker push "$ecr_image"; then
        log_success "Image pushed to ECR: $ecr_image"
    else
        log_error "ECR push failed"
        return 1
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    log_header "Fluidity Docker Build"

    parse_arguments "$@"
    validate_options
    check_prerequisites

    # Build binaries
    log_minor "Step 1: Build Binaries"
    build_binaries

    # Build Docker images
    if [[ "$BUILD_SERVER" == "true" ]]; then
        log_minor "Step 2: Build Server Docker Image"
        build_docker_image "server"
        
        if [[ "$PUSH_TO_ECR" == "true" ]]; then
            push_to_ecr "server"
        fi
    fi

    if [[ "$BUILD_AGENT" == "true" ]]; then
        log_minor "Step 3: Build Agent Docker Image"
        build_docker_image "agent"
        
        if [[ "$PUSH_TO_ECR" == "true" ]]; then
            push_to_ecr "agent"
        fi
    fi

    log_header "Build Summary"
    echo "Version: $BUILD_VERSION"
    echo "Platform: $TARGET_PLATFORM"
    [[ "$BUILD_SERVER" == "true" ]] && echo "Server: fluidity-server:$BUILD_VERSION"
    [[ "$BUILD_AGENT" == "true" ]] && echo "Agent: fluidity-agent:$BUILD_VERSION"
    [[ "$PUSH_TO_ECR" == "true" ]] && echo "ECR: $ECR_REPO:$BUILD_VERSION"

    log_success "Docker build completed successfully"
}

main "$@"
