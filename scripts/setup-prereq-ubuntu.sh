#!/bin/bash
# Setup Prerequisites Script for Ubuntu/Debian
# This script checks for and installs required prerequisites for Fluidity on Ubuntu/Debian-based (including WSL) systems

set -e

echo "========================================"
echo "Fluidity Prerequisites Setup (Ubuntu/Debian)"
echo "========================================"
echo ""

HAS_ERRORS=false

# Color definitions (progressive light blue)
LIGHT_BLUE_1='\033[1;38;5;117m'  # Very light blue/cyan (brightest)
LIGHT_BLUE_2='\033[38;5;75m'     # Noticeably darker light blue
LIGHT_BLUE_3='\033[38;5;33m'     # More pronounced darker light blue
RESET='\033[0m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

log_section() {
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

SUDO=""
if ! is_root; then
    if is_interactive; then
        SUDO="sudo"
        echo -e "${YELLOW}Note: Some commands will require sudo password.${NC}"
        echo ""
    else
        echo -e "${RED}Error: This script requires sudo privileges but is not running interactively.${NC}"
        echo -e "${YELLOW}Please run this script directly in a terminal:${NC}"
        echo -e "${CYAN}  bash ./scripts/setup-prereq-ubuntu.sh${NC}"
        echo ""
        echo -e "${YELLOW}Or run with elevated privileges:${NC}"
        echo -e "${CYAN}  sudo bash ./scripts/setup-prereq-ubuntu.sh${NC}"
        exit 1
    fi
fi

# 1. Update package manager
echo -e "${YELLOW}[1/9] Updating package manager...${NC}"
$SUDO apt-get update
echo -e "${GREEN}  ✓ Package lists updated${NC}"
echo ""

# 2. Check/Install Go
echo -e "${YELLOW}[2/9] Checking Go (1.24.3 to match toolchain)...${NC}"
GO_REQUIRED_VERSION="1.24.3"
GO_INSTALL_NEEDED=false

if command_exists go; then
    GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
    echo -e "${CYAN}  Found Go version: $GO_VERSION${NC}"
    
    # Compare versions (simple string comparison works for most cases)
    if [ "$GO_VERSION" != "$GO_REQUIRED_VERSION" ]; then
        echo -e "${YELLOW}  ⚠ Go version mismatch. Required: $GO_REQUIRED_VERSION, Installed: $GO_VERSION${NC}"
        GO_INSTALL_NEEDED=true
    else
        echo -e "${GREEN}  ✓ Go $GO_VERSION matches required version${NC}"
    fi
else
    echo -e "${RED}  ✗ Go is not installed${NC}"
    GO_INSTALL_NEEDED=true
fi

if [ "$GO_INSTALL_NEEDED" = true ]; then
    echo -e "${YELLOW}  Installing Go $GO_REQUIRED_VERSION...${NC}"
    
    # Remove old Go installation if it exists
    if [ -d "/usr/local/go" ]; then
        echo -e "${YELLOW}  Removing old Go installation...${NC}"
        $SUDO rm -rf /usr/local/go
    fi
    
    # Download and install specific Go version
    GO_TARBALL="go${GO_REQUIRED_VERSION}.linux-amd64.tar.gz"
    GO_URL="https://go.dev/dl/${GO_TARBALL}"
    
    echo -e "${YELLOW}  Downloading Go $GO_REQUIRED_VERSION from $GO_URL...${NC}"
    if wget -q "$GO_URL" -O "/tmp/$GO_TARBALL"; then
        echo -e "${GREEN}  ✓ Downloaded Go tarball${NC}"
        
        echo -e "${YELLOW}  Extracting to /usr/local/go...${NC}"
        $SUDO tar -C /usr/local -xzf "/tmp/$GO_TARBALL"
        rm "/tmp/$GO_TARBALL"
        
        # Add to PATH if not already there
        if ! grep -q "/usr/local/go/bin" ~/.bashrc 2>/dev/null; then
            echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
            echo -e "${YELLOW}  Added /usr/local/go/bin to ~/.bashrc${NC}"
        fi
        
        # Export for current session
        export PATH=$PATH:/usr/local/go/bin
        
        if command_exists go; then
            GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
            echo -e "${GREEN}  ✓ Go $GO_VERSION installed successfully${NC}"
        else
            echo -e "${RED}  ✗ Go installation failed. Please install manually from https://go.dev/dl/${NC}"
            HAS_ERRORS=true
        fi
    else
        echo -e "${RED}  ✗ Failed to download Go. Please install manually from https://go.dev/dl/${NC}"
        HAS_ERRORS=true
    fi
fi
echo ""

# 3. Check/Install Make
echo -e "${YELLOW}[3/9] Checking Make...${NC}"
if command_exists make; then
    MAKE_VERSION=$(make --version | head -n 1)
    echo -e "${GREEN}  ✓ Make is installed: $MAKE_VERSION${NC}"
else
    echo -e "${RED}  ✗ Make is not installed${NC}"
    echo -e "${YELLOW}  Installing Make...${NC}"
    $SUDO apt-get install -y build-essential
    if command_exists make; then
        echo -e "${GREEN}  ✓ Make installed successfully${NC}"
    else
        echo -e "${YELLOW}  Note: Make is optional - you can run build commands manually.${NC}"
    fi
fi
echo ""

# 4. Check/Install Docker
echo -e "${YELLOW}[4/9] Checking Docker...${NC}"

# Check if running in WSL
IS_WSL=false
if grep -qEi "(Microsoft|WSL)" /proc/version 2>/dev/null ; then
    IS_WSL=true
fi

if command_exists docker; then
    DOCKER_VERSION=$(docker --version 2>&1) || DOCKER_VERSION="unknown"
    echo -e "${GREEN}  ✓ Docker is installed: $DOCKER_VERSION${NC}"
    if [ "$IS_WSL" = true ]; then
        echo -e "${CYAN}  Note: Using Docker Desktop for Windows via WSL integration${NC}"
    fi
else
    if [ "$IS_WSL" = true ]; then
        echo -e "${YELLOW}  ✗ Docker is not installed in WSL${NC}"
        echo -e "${CYAN}  Note: For WSL, use Docker Desktop for Windows instead of installing Docker in WSL${NC}"
        echo -e "${CYAN}  1. Install Docker Desktop on Windows from https://www.docker.com/products/docker-desktop${NC}"
        echo -e "${CYAN}  2. In Docker Desktop settings, enable 'WSL 2 based engine'${NC}"
        echo -e "${CYAN}  3. Enable integration with your WSL distro in Settings → Resources → WSL Integration${NC}"
        echo -e "${CYAN}  4. Restart WSL terminal after enabling integration${NC}"
        echo -e "${YELLOW}  Skipping Docker installation in WSL...${NC}"
    else
        echo -e "${RED}  ✗ Docker is not installed${NC}"
        echo -e "${YELLOW}  Installing Docker...${NC}"
        $SUDO apt-get install -y docker.io docker-compose
        if command_exists docker; then
            echo -e "${GREEN}  ✓ Docker installed successfully${NC}"
            if command_exists systemctl; then
                $SUDO systemctl start docker 2>/dev/null || echo -e "${YELLOW}  Note: Could not start Docker service (systemctl not available)${NC}"
                $SUDO systemctl enable docker 2>/dev/null || true
            fi
            if ! is_root; then
                $SUDO usermod -aG docker $USER
                echo -e "${YELLOW}  ⚠ Added $USER to docker group. Please log out and back in for changes to take effect.${NC}"
            fi
        else
            echo -e "${RED}  ✗ Docker installation failed${NC}"
            HAS_ERRORS=true
        fi
    fi
fi
echo ""

# 5. Check/Install OpenSSL
echo -e "${YELLOW}[5/9] Checking OpenSSL...${NC}"
if command_exists openssl; then
    OPENSSL_VERSION=$(openssl version)
    echo -e "${GREEN}  ✓ OpenSSL is installed: $OPENSSL_VERSION${NC}"
else
    echo -e "${RED}  ✗ OpenSSL is not installed${NC}"
    echo -e "${YELLOW}  Installing OpenSSL...${NC}"
    $SUDO apt-get install -y openssl
    if command_exists openssl; then
        echo -e "${GREEN}  ✓ OpenSSL installed successfully${NC}"
    else
        echo -e "${RED}  ✗ OpenSSL installation failed${NC}"
        HAS_ERRORS=true
    fi
fi
echo ""

# 6. Check/Install zip and unzip
echo -e "${YELLOW}[6/9] Checking zip and unzip...${NC}"
if command_exists zip; then
    ZIP_VERSION=$(zip --version | head -n 2 | tail -n 1)
    echo -e "${GREEN}  ✓ zip is installed: $ZIP_VERSION${NC}"
else
    echo -e "${RED}  ✗ zip is not installed${NC}"
    echo -e "${YELLOW}  Installing zip and unzip...${NC}"
    $SUDO apt-get install -y zip unzip
    if command_exists zip; then
        echo -e "${GREEN}  ✓ zip installed successfully${NC}"
    else
        echo -e "${RED}  ✗ zip installation failed${NC}"
        HAS_ERRORS=true
    fi
fi
if command_exists unzip; then
    echo -e "${GREEN}  ✓ unzip is installed${NC}"
else
    echo -e "${YELLOW}  Note: unzip required for AWS CLI installation${NC}"
fi
echo ""

# 7. Check/Install jq
echo -e "${YELLOW}[7/9] Checking jq...${NC}"
if command_exists jq; then
    JQ_VERSION=$(jq --version)
    echo -e "${GREEN}  ✓ jq is installed: $JQ_VERSION${NC}"
else
    echo -e "${RED}  ✗ jq is not installed${NC}"
    echo -e "${YELLOW}  Installing jq...${NC}"
    $SUDO apt-get install -y jq
    if command_exists jq; then
        echo -e "${GREEN}  ✓ jq installed successfully${NC}"
    else
        echo -e "${RED}  ✗ jq installation failed${NC}"
        HAS_ERRORS=true
    fi
fi
echo ""

# 8. Check/Install AWS CLI
echo -e "${YELLOW}[8/9] Checking AWS CLI v2...${NC}"
if command_exists aws; then
    AWS_VERSION=$(aws --version 2>&1)
    echo -e "${GREEN}  ✓ AWS CLI is installed: $AWS_VERSION${NC}"
else
    echo -e "${RED}  ✗ AWS CLI is not installed${NC}"
    echo -e "${YELLOW}  Installing AWS CLI v2...${NC}"
    
    # Download AWS CLI v2 installer
    if curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"; then
        echo -e "${GREEN}  ✓ Downloaded AWS CLI installer${NC}"
        
        # Unzip and install
        if command_exists unzip; then
            unzip -q /tmp/awscliv2.zip -d /tmp
            $SUDO /tmp/aws/install
            rm -rf /tmp/awscliv2.zip /tmp/aws
            
            if command_exists aws; then
                AWS_VERSION=$(aws --version 2>&1)
                echo -e "${GREEN}  ✓ AWS CLI installed successfully: $AWS_VERSION${NC}"
            else
                echo -e "${RED}  ✗ AWS CLI installation failed${NC}"
                echo -e "${YELLOW}  Please install manually from https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html${NC}"
                HAS_ERRORS=true
            fi
        else
            echo -e "${RED}  ✗ unzip command not found (required for AWS CLI installation)${NC}"
            HAS_ERRORS=true
        fi
    else
        echo -e "${RED}  ✗ Failed to download AWS CLI installer${NC}"
        echo -e "${YELLOW}  Please install manually from https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html${NC}"
        HAS_ERRORS=true
    fi
fi
echo ""

# 9. Check/Install Node.js, npm, and required npm packages
echo -e "${YELLOW}[9/9] Checking Node.js (18+), npm, and npm packages...${NC}"
NODE_INSTALLED=false
NPM_INSTALLED=false
if command_exists node; then
    NODE_INSTALLED=true
    NODE_VERSION=$(node --version)
    echo -e "${GREEN}  ✓ Node.js is installed: $NODE_VERSION${NC}"
else
    echo -e "${RED}  ✗ Node.js is not installed${NC}"
fi
if command_exists npm; then
    NPM_INSTALLED=true
    NPM_VERSION=$(npm --version)
    echo -e "${GREEN}  ✓ npm is installed: $NPM_VERSION${NC}"
else
    echo -e "${RED}  ✗ npm is not installed${NC}"
fi

if [ "$NODE_INSTALLED" = false ] || [ "$NPM_INSTALLED" = false ]; then
    echo -e "${YELLOW}  Installing Node.js and npm...${NC}"
    $SUDO apt-get install -y nodejs npm
    if command_exists node; then
        NODE_INSTALLED=true
        NODE_VERSION=$(node --version)
        echo -e "${GREEN}  ✓ Node.js installed successfully: $NODE_VERSION${NC}"
    else
        echo -e "${RED}  ✗ Node.js installation failed${NC}"
        HAS_ERRORS=true
    fi
    if command_exists npm; then
        NPM_INSTALLED=true
        NPM_VERSION=$(npm --version)
        echo -e "${GREEN}  ✓ npm installed successfully: $NPM_VERSION${NC}"
    else
        echo -e "${RED}  ✗ npm installation failed${NC}"
        HAS_ERRORS=true
    fi
fi

if [ "$NODE_INSTALLED" = true ] && [ "$NPM_INSTALLED" = true ]; then
    echo -e "${YELLOW}  Checking npm packages (ws, https-proxy-agent)...${NC}"
    WS_INSTALLED=false
    PROXY_INSTALLED=false
    if npm list -g ws 2>/dev/null | grep -q "ws@"; then
        WS_INSTALLED=true
    fi
    if npm list -g https-proxy-agent 2>/dev/null | grep -q "https-proxy-agent@"; then
        PROXY_INSTALLED=true
    fi
    if [ "$WS_INSTALLED" = false ] || [ "$PROXY_INSTALLED" = false ]; then
        echo -e "${YELLOW}  Installing required npm packages globally...${NC}"
        # Try with sudo first
        if $SUDO npm install -g ws https-proxy-agent 2>/dev/null; then
            echo -e "${GREEN}  ✓ npm packages installed globally (with sudo)${NC}"
        else
            echo -e "${YELLOW}  sudo npm failed, retrying without sudo (user global install)...${NC}"
            if npm install -g ws https-proxy-agent; then
                echo -e "${GREEN}  ✓ npm packages installed globally (user global)${NC}"
            else
                echo -e "${RED}  ✗ Error installing npm packages globally with and without sudo${NC}"
                echo -e "${YELLOW}    If you see 'npm: command not found' with sudo, npm may not be in root's PATH."
                echo -e "${YELLOW}    You can configure npm to use a user directory for global installs:"
                echo -e "${YELLOW}      mkdir -p ~/.npm-global && npm config set prefix '~/.npm-global'"
                echo -e "${YELLOW}      export PATH=\"$HOME/.npm-global/bin:$PATH\" (add to ~/.bashrc or ~/.zshrc)"
                HAS_ERRORS=true
            fi
        fi
    else
        echo -e "${GREEN}  ✓ Required npm packages are installed globally${NC}"
    fi
    # Always ensure local node_modules for tests
    echo -e "${YELLOW}  Ensuring local node_modules for ws and https-proxy-agent...${NC}"
    if npm install ws https-proxy-agent; then
        echo -e "${GREEN}  ✓ Local node_modules installed for ws and https-proxy-agent${NC}"
    else
        echo -e "${RED}  ✗ Error installing local node_modules for ws and https-proxy-agent${NC}"
        HAS_ERRORS=true
    fi
fi
echo ""

# Summary
echo "========================================"
echo "Setup Summary"
echo "========================================"

if [ "$HAS_ERRORS" = true ]; then
    echo -e "${YELLOW}⚠ Setup completed with errors. Please review the output above.${NC}"
    echo -e "${YELLOW}  Some prerequisites may need to be installed manually.${NC}"
    exit 1
else
    echo -e "${GREEN}✓ All prerequisites are installed!${NC}"
    echo ""
    echo -e "${CYAN}Next steps:${NC}"
    echo "  1. Close and reopen your terminal to refresh environment variables"
    echo "  2. If Docker was installed, log out and back in to apply docker group membership"
    echo "  3. Generate certificates: cd scripts && ./generate-certs.sh"
    echo "  4. Build the project: make build-linux"
    echo "  5. Run tests: ./scripts/test-local.sh"
    exit 0
fi
