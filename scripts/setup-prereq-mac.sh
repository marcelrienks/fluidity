#!/bin/bash
# Setup Prerequisites Script for macOS
# This script checks for and installs required prerequisites for Fluidity

set -e

HAS_ERRORS=false

# Source shared logging library
source "$(dirname "${BASH_SOURCE[0]}")/lib-logging.sh"

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

log_header "Fluidity Prerequisites Setup (macOS)"

# 1. Check/Install Homebrew
log_minor "1/9 Checking Homebrew..."
if command_exists brew; then
    BREW_VERSION=$(brew --version | head -n 1)
    log_success "Homebrew is installed: $BREW_VERSION"
else
    log_error "Homebrew is not installed"
    log_info "Installing Homebrew..."
    if /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
        # Add Homebrew to PATH for this session
        if [[ $(uname -m) == "arm64" ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        else
            eval "$(/usr/local/bin/brew shellenv)"
        fi
        log_success "Homebrew installed successfully"
    else
        log_error "Homebrew installation failed"
        HAS_ERRORS=true
    fi
fi
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
        sudo rm -rf /usr/local/go
    fi
    
    # Determine architecture
    ARCH=$(uname -m)
    if [ "$ARCH" = "arm64" ]; then
        GO_ARCH="darwin-arm64"
    else
        GO_ARCH="darwin-amd64"
    fi
    
    # Download and install specific Go version
    GO_TARBALL="go${GO_REQUIRED_VERSION}.${GO_ARCH}.tar.gz"
    GO_URL="https://go.dev/dl/${GO_TARBALL}"
    
    log_info "Downloading Go $GO_REQUIRED_VERSION for macOS ($ARCH) from $GO_URL..."
    if curl -sL "$GO_URL" -o "/tmp/$GO_TARBALL"; then
        log_success "Downloaded Go tarball"
        
        log_info "Extracting to /usr/local/go..."
        sudo tar -C /usr/local -xzf "/tmp/$GO_TARBALL"
        rm "/tmp/$GO_TARBALL"
        
        # Add to PATH if not already there
        if ! grep -q "/usr/local/go/bin" ~/.zshrc 2>/dev/null; then
            echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.zshrc
            log_info "Added /usr/local/go/bin to ~/.zshrc"
        fi
        if ! grep -q "/usr/local/go/bin" ~/.bash_profile 2>/dev/null; then
            echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bash_profile
            log_info "Added /usr/local/go/bin to ~/.bash_profile"
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
    log_info "Installing Xcode Command Line Tools (includes Make)..."
    if xcode-select --install 2>/dev/null; then
        log_info "⚠ Please complete the Xcode Command Line Tools installation dialog"
        log_info "  Then run this script again"
        exit 0
    else
        # Already installed or error
        if command_exists make; then
            log_success "Make is available"
        else
            log_error "Make installation failed"
            log_info "  Note: Make is optional - you can run build commands manually."
        fi
    fi
fi
echo ""

# 4. Check/Install Docker
log_minor "4/9 Checking Docker..."
if command_exists docker; then
    DOCKER_VERSION=$(docker --version 2>&1) || DOCKER_VERSION="unknown"
    log_success "Docker is installed: $DOCKER_VERSION"
else
    log_error "Docker is not installed"
    log_info "Installing Docker via Homebrew..."
    if brew install --cask docker; then
        log_info "⚠ Docker installed. Please:"
        log_info "  1. Launch Docker Desktop from Applications"
        log_info "  2. Complete the Docker Desktop setup wizard"
        log_info "  3. Ensure Docker is running before building containers"
    else
        log_error "Docker installation failed"
        log_info "  Please install manually from https://www.docker.com/products/docker-desktop"
        HAS_ERRORS=true
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
    log_info "Installing OpenSSL via Homebrew..."
    if brew install openssl; then
        log_success "OpenSSL installed successfully"
        log_info "⚠ You may need to add OpenSSL to your PATH:"
        log_info "  export PATH=\"/opt/homebrew/opt/openssl@3/bin:\$PATH\""
    else
        log_error "OpenSSL installation failed"
        HAS_ERRORS=true
    fi
fi
echo ""

# 6. Check/Install zip
log_minor "6/9 Checking zip..."
if command_exists zip; then
    ZIP_VERSION=$(zip --version | head -n 2 | tail -n 1)
    log_success "zip is installed: $ZIP_VERSION"
else
    log_error "zip is not installed"
    log_info "Installing zip via Homebrew..."
    if brew install zip; then
        log_success "zip installed successfully"
    else
        log_error "zip installation failed"
        HAS_ERRORS=true
    fi
fi
echo ""

# 7. Check/Install jq
log_minor "7/9 Checking jq..."
if command_exists jq; then
    JQ_VERSION=$(jq --version)
    log_success "jq is installed: $JQ_VERSION"
else
    log_error "jq is not installed"
    log_info "Installing jq via Homebrew..."
    if brew install jq; then
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
    log_info "Installing AWS CLI v2 via Homebrew..."
    
    if command_exists brew; then
        if brew install awscli; then
            if command_exists aws; then
                AWS_VERSION=$(aws --version 2>&1)
                log_success "AWS CLI installed successfully: $AWS_VERSION"
            else
                log_error "AWS CLI installation failed"
                log_info "Please install manually from https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
                HAS_ERRORS=true
            fi
        else
            log_error "Homebrew installation of AWS CLI failed"
            log_info "Trying manual installation..."
            
            # Determine architecture
            ARCH=$(uname -m)
            if [[ "$ARCH" == "arm64" ]]; then
                AWS_PKG_URL="https://awscli.amazonaws.com/AWSCLIV2-arm64.pkg"
            else
                AWS_PKG_URL="https://awscli.amazonaws.com/AWSCLIV2.pkg"
            fi
            
            if curl -s "$AWS_PKG_URL" -o "/tmp/AWSCLIV2.pkg"; then
                log_success "Downloaded AWS CLI installer"
                sudo installer -pkg /tmp/AWSCLIV2.pkg -target /
                rm /tmp/AWSCLIV2.pkg
                
                if command_exists aws; then
                    AWS_VERSION=$(aws --version 2>&1)
                    log_success "AWS CLI installed successfully: $AWS_VERSION"
                else
                    log_error "AWS CLI installation failed"
                    HAS_ERRORS=true
                fi
            else
                log_error "Failed to download AWS CLI installer"
                HAS_ERRORS=true
            fi
        fi
    else
        log_error "Homebrew not available for AWS CLI installation"
        HAS_ERRORS=true
    fi
fi
echo ""

# 9. Check/Install Node.js, npm, and npm packages
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
    log_info "Installing Node.js and npm via Homebrew..."
    if brew install node; then
        if command_exists node; then
            NODE_INSTALLED=true
            NODE_VERSION=$(node --version)
            log_success "Node.js installed successfully: $NODE_VERSION"
        fi
        if command_exists npm; then
            NPM_INSTALLED=true
            NPM_VERSION=$(npm --version)
            log_success "npm installed successfully: $NPM_VERSION"
        fi
    else
        log_error "Node.js/npm installation failed. Please install manually from https://nodejs.org/"
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
        log_info "Installing required npm packages..."
        if npm install -g ws https-proxy-agent; then
            log_success "npm packages installed successfully"
        else
            log_error "Error installing npm packages"
            HAS_ERRORS=true
        fi
    else
        log_success "Required npm packages are installed"
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
    echo "  2. Generate certificates: cd scripts && ./generate-certs.sh"
    echo "  3. Build the project: make build-macos"
    echo "  4. Run tests: ./scripts/test-local.sh"
    exit 0
fi
