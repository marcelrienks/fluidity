#!/bin/bash
# Setup Prerequisites Script for Ubuntu/Debian
# This script checks for and installs required prerequisites for Fluidity on Ubuntu/Debian-based (including WSL) systems

set -e

HAS_ERRORS=false

# Color definitions (light pastel palette)
PALE_BLUE='\033[38;5;153m'       # Light pastel blue (major headers)
PALE_YELLOW='\033[38;5;229m'     # Light pastel yellow (minor headers)
PALE_GREEN='\033[38;5;193m'      # Light pastel green (sub-headers)
WHITE='\033[1;37m'               # Standard white (info logs)
RED='\033[0;31m'                 # Standard red (errors)
RESET='\033[0m'

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
    echo -e "[ERROR] $*${RESET}" >&2
}

log_debug() {
    echo "[DEBUG] $*" >&2
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check if running as root
is_root() {
    [ "$(id -u)" -eq 0 ]
}

# Check if running interactively (can accept input)
is_interactive() {
    [[ -t 0 ]]
}

log_header "Fluidity Prerequisites Setup (Ubuntu/Debian)"

SUDO=""
if ! is_root; then
    if is_interactive; then
        SUDO="sudo"
        log_info "Note: Some commands will require sudo password."
        echo ""
    else
        log_error "This script requires sudo privileges but is not running interactively."
        echo ""
        log_info "Please run this script directly in a terminal:"
        echo "  bash ./scripts/setup-prereq-ubuntu.sh"
        echo ""
        log_info "Or run with elevated privileges:"
        echo "  sudo bash ./scripts/setup-prereq-ubuntu.sh"
        exit 1
    fi
fi

# 1. Update package manager
log_minor "1/9 Updating package manager..."
$SUDO apt-get update
log_success "Package lists updated"
echo ""

# 2. Check/Install Go
log_minor "2/9 Checking Go (1.24.3 to match toolchain)..."
GO_REQUIRED_VERSION="1.24.3"
GO_INSTALL_NEEDED=false

if command_exists go; then
    GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
    log_info "Found Go version: $GO_VERSION"
    
    # Compare versions (simple string comparison works for most cases)
    if [ "$GO_VERSION" != "$GO_REQUIRED_VERSION" ]; then
        log_info "⚠ Go version mismatch. Required: $GO_REQUIRED_VERSION, Installed: $GO_VERSION"
        GO_INSTALL_NEEDED=true
    else
        log_success "Go $GO_VERSION matches required version"
    fi
else
    log_error "Go is not installed"
    GO_INSTALL_NEEDED=true
fi

if [ "$GO_INSTALL_NEEDED" = true ]; then
    log_info "Installing Go $GO_REQUIRED_VERSION..."
    
    # Remove old Go installation if it exists
    if [ -d "/usr/local/go" ]; then
        log_info "Removing old Go installation..."
        $SUDO rm -rf /usr/local/go
    fi
    
    # Download and install specific Go version
    GO_TARBALL="go${GO_REQUIRED_VERSION}.linux-amd64.tar.gz"
    GO_URL="https://go.dev/dl/${GO_TARBALL}"
    
    log_info "Downloading Go $GO_REQUIRED_VERSION from $GO_URL..."
    if wget -q "$GO_URL" -O "/tmp/$GO_TARBALL"; then
        log_success "Downloaded Go tarball"
        
        log_info "Extracting to /usr/local/go..."
        $SUDO tar -C /usr/local -xzf "/tmp/$GO_TARBALL"
        rm "/tmp/$GO_TARBALL"
        
        # Add to PATH if not already there
        if ! grep -q "/usr/local/go/bin" ~/.bashrc 2>/dev/null; then
            echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
            log_info "Added /usr/local/go/bin to ~/.bashrc"
        fi
        
        # Export for current session
        export PATH=$PATH:/usr/local/go/bin
        
        if command_exists go; then
            GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
            log_success "Go $GO_VERSION installed successfully"
        else
            log_error "Go installation failed. Please install manually from https://go.dev/dl/"
            HAS_ERRORS=true
        fi
    else
        log_error "Failed to download Go. Please install manually from https://go.dev/dl/"
        HAS_ERRORS=true
    fi
fi
echo ""

# 3. Check/Install Make
log_minor "3/9 Checking Make..."
if command_exists make; then
    MAKE_VERSION=$(make --version | head -n 1)
    log_success "Make is installed: $MAKE_VERSION"
else
    log_error "Make is not installed"
    log_info "Installing Make..."
    $SUDO apt-get install -y build-essential
    if command_exists make; then
        log_success "Make installed successfully"
    else
        log_info "Note: Make is optional - you can run build commands manually."
    fi
fi
echo ""

# 4. Check/Install Docker
log_minor "4/9 Checking Docker..."

# Check if running in WSL
IS_WSL=false
if grep -qEi "(Microsoft|WSL)" /proc/version 2>/dev/null ; then
    IS_WSL=true
fi

if command_exists docker; then
    DOCKER_VERSION=$(docker --version 2>&1) || DOCKER_VERSION="unknown"
    log_success "Docker is installed: $DOCKER_VERSION"
    if [ "$IS_WSL" = true ]; then
        log_info "Note: Using Docker Desktop for Windows via WSL integration"
    fi
else
    if [ "$IS_WSL" = true ]; then
        log_info "✗ Docker is not installed in WSL"
        log_info "Note: For WSL, use Docker Desktop for Windows instead of installing Docker in WSL"
        log_info "1. Install Docker Desktop on Windows from https://www.docker.com/products/docker-desktop"
        log_info "2. In Docker Desktop settings, enable 'WSL 2 based engine'"
        log_info "3. Enable integration with your WSL distro in Settings → Resources → WSL Integration"
        log_info "4. Restart WSL terminal after enabling integration"
        log_info "Skipping Docker installation in WSL..."
    else
        log_error "Docker is not installed"
        log_info "Installing Docker..."
        $SUDO apt-get install -y docker.io docker-compose
        if command_exists docker; then
            log_success "Docker installed successfully"
            if command_exists systemctl; then
                $SUDO systemctl start docker 2>/dev/null || log_info "Note: Could not start Docker service (systemctl not available)"
                $SUDO systemctl enable docker 2>/dev/null || true
            fi
            if ! is_root; then
                $SUDO usermod -aG docker $USER
                log_info "⚠ Added $USER to docker group. Please log out and back in for changes to take effect."
            fi
        else
            log_error "Docker installation failed"
            HAS_ERRORS=true
        fi
    fi
fi
echo ""

# 5. Check/Install OpenSSL
log_minor "5/9 Checking OpenSSL..."
if command_exists openssl; then
    OPENSSL_VERSION=$(openssl version)
    log_success "OpenSSL is installed: $OPENSSL_VERSION"
else
    log_error "OpenSSL is not installed"
    log_info "Installing OpenSSL..."
    $SUDO apt-get install -y openssl
    if command_exists openssl; then
        log_success "OpenSSL installed successfully"
    else
        log_error "OpenSSL installation failed"
        HAS_ERRORS=true
    fi
fi
echo ""

# 6. Check/Install zip and unzip
log_minor "6/9 Checking zip and unzip..."
if command_exists zip; then
    ZIP_VERSION=$(zip --version | head -n 2 | tail -n 1)
    log_success "zip is installed: $ZIP_VERSION"
else
    log_error "zip is not installed"
    log_info "Installing zip and unzip..."
    $SUDO apt-get install -y zip unzip
    if command_exists zip; then
        log_success "zip installed successfully"
    else
        log_error "zip installation failed"
        HAS_ERRORS=true
    fi
fi
if command_exists unzip; then
    log_success "unzip is installed"
else
    log_info "Note: unzip required for AWS CLI installation"
fi
echo ""

# 7. Check/Install jq
log_minor "7/9 Checking jq..."
if command_exists jq; then
    JQ_VERSION=$(jq --version)
    log_success "jq is installed: $JQ_VERSION"
else
    log_error "jq is not installed"
    log_info "Installing jq..."
    $SUDO apt-get install -y jq
    if command_exists jq; then
        log_success "jq installed successfully"
    else
        log_error "jq installation failed"
        HAS_ERRORS=true
    fi
fi
echo ""

# 8. Check/Install AWS CLI
log_minor "8/9 Checking AWS CLI v2..."
if command_exists aws; then
    AWS_VERSION=$(aws --version 2>&1)
    log_success "AWS CLI is installed: $AWS_VERSION"
else
    log_error "AWS CLI is not installed"
    log_info "Installing AWS CLI v2..."
    
    # Download AWS CLI v2 installer
    if curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"; then
        log_success "Downloaded AWS CLI installer"
        
        # Unzip and install
        if command_exists unzip; then
            unzip -q /tmp/awscliv2.zip -d /tmp
            $SUDO /tmp/aws/install
            rm -rf /tmp/awscliv2.zip /tmp/aws
            
            if command_exists aws; then
                AWS_VERSION=$(aws --version 2>&1)
                log_success "AWS CLI installed successfully: $AWS_VERSION"
            else
                log_error "AWS CLI installation failed"
                log_info "Please install manually from https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
                HAS_ERRORS=true
            fi
        else
            log_error "unzip command not found (required for AWS CLI installation)"
            HAS_ERRORS=true
        fi
    else
        log_error "Failed to download AWS CLI installer"
        log_info "Please install manually from https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        HAS_ERRORS=true
    fi
fi
echo ""

# 9. Check/Install Node.js, npm, and required npm packages
log_minor "9/9 Checking Node.js (18+), npm, and npm packages..."
NODE_INSTALLED=false
NPM_INSTALLED=false
if command_exists node; then
    NODE_INSTALLED=true
    NODE_VERSION=$(node --version)
    log_success "Node.js is installed: $NODE_VERSION"
else
    log_error "Node.js is not installed"
fi
if command_exists npm; then
    NPM_INSTALLED=true
    NPM_VERSION=$(npm --version)
    log_success "npm is installed: $NPM_VERSION"
else
    log_error "npm is not installed"
fi

if [ "$NODE_INSTALLED" = false ] || [ "$NPM_INSTALLED" = false ]; then
    log_info "Installing Node.js and npm..."
    $SUDO apt-get install -y nodejs npm
    if command_exists node; then
        NODE_INSTALLED=true
        NODE_VERSION=$(node --version)
        log_success "Node.js installed successfully: $NODE_VERSION"
    else
        log_error "Node.js installation failed"
        HAS_ERRORS=true
    fi
    if command_exists npm; then
        NPM_INSTALLED=true
        NPM_VERSION=$(npm --version)
        log_success "npm installed successfully: $NPM_VERSION"
    else
        log_error "npm installation failed"
        HAS_ERRORS=true
    fi
fi

if [ "$NODE_INSTALLED" = true ] && [ "$NPM_INSTALLED" = true ]; then
    log_info "Checking npm packages (ws, https-proxy-agent)..."
    WS_INSTALLED=false
    PROXY_INSTALLED=false
    if npm list -g ws 2>/dev/null | grep -q "ws@"; then
        WS_INSTALLED=true
    fi
    if npm list -g https-proxy-agent 2>/dev/null | grep -q "https-proxy-agent@"; then
        PROXY_INSTALLED=true
    fi
    if [ "$WS_INSTALLED" = false ] || [ "$PROXY_INSTALLED" = false ]; then
        log_info "Installing required npm packages globally..."
        # Try with sudo first
        if $SUDO npm install -g ws https-proxy-agent 2>/dev/null; then
            log_success "npm packages installed globally (with sudo)"
        else
            log_info "sudo npm failed, retrying without sudo (user global install)..."
            if npm install -g ws https-proxy-agent; then
                log_success "npm packages installed globally (user global)"
            else
                log_error "Error installing npm packages globally with and without sudo"
                echo -e "    If you see 'npm: command not found' with sudo, npm may not be in root's PATH."
                echo -e "    You can configure npm to use a user directory for global installs:"
                echo -e "      mkdir -p ~/.npm-global && npm config set prefix '~/.npm-global'"
                echo -e "      export PATH=\"$HOME/.npm-global/bin:$PATH\" (add to ~/.bashrc or ~/.zshrc)"
                HAS_ERRORS=true
            fi
        fi
    else
        log_success "Required npm packages are installed globally"
    fi
    # Always ensure local node_modules for tests
    log_info "Ensuring local node_modules for ws and https-proxy-agent..."
    if npm install ws https-proxy-agent; then
        log_success "Local node_modules installed for ws and https-proxy-agent"
    else
        log_error "Error installing local node_modules for ws and https-proxy-agent"
        HAS_ERRORS=true
    fi
fi
echo ""

# Summary
echo "========================================"
echo "Setup Summary"
echo "========================================"

if [ "$HAS_ERRORS" = true ]; then
    log_info "⚠ Setup completed with errors. Please review the output above."
    log_info "Some prerequisites may need to be installed manually."
    exit 1
else
    log_success "✓ All prerequisites are installed!"
    echo ""
    log_info "Next steps:"
    echo "  1. Close and reopen your terminal to refresh environment variables"
    echo "  2. If Docker was installed, log out and back in to apply docker group membership"
    echo "  3. Generate certificates: cd scripts && ./generate-certs.sh"
    echo "  4. Build the project: make build-linux"
    echo "  5. Run tests: ./scripts/test-local.sh"
    exit 0
fi
