#!/bin/bash
# Setup Prerequisites Script for Arch Linux/Hyprland
# This script checks for and installs required prerequisites for Fluidity on Arch-based systems

set -e

echo "========================================"
echo "Fluidity Prerequisites Setup (Arch/Hyprland)"
echo "========================================"
echo ""

HAS_ERRORS=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check if running as root
is_root() {
    [ "$(id -u)" -eq 0 ]
}

SUDO=""
if ! is_root; then
    SUDO="sudo"
    echo -e "${YELLOW}Note: Some commands will require sudo password.${NC}"
    echo ""
fi

# 1. Update package manager
echo -e "${YELLOW}[1/6] Updating package manager...${NC}"
$SUDO pacman -Sy
echo -e "${GREEN}  ✓ Package lists updated${NC}"
echo ""

# 2. Check/Install Go
echo -e "${YELLOW}[2/6] Checking Go (1.24.3 to match toolchain)...${NC}"
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
echo -e "${YELLOW}[3/6] Checking Make...${NC}"
if command_exists make; then
    MAKE_VERSION=$(make --version | head -n 1)
    echo -e "${GREEN}  ✓ Make is installed: $MAKE_VERSION${NC}"
else
    echo -e "${RED}  ✗ Make is not installed${NC}"
    echo -e "${YELLOW}  Installing Make...${NC}"
    $SUDO pacman -S --noconfirm base-devel
    if command_exists make; then
        echo -e "${GREEN}  ✓ Make installed successfully${NC}"
    else
        echo -e "${YELLOW}  Note: Make is optional - you can run build commands manually.${NC}"
    fi
fi
echo ""

# 4. Check/Install Docker
echo -e "${YELLOW}[4/6] Checking Docker...${NC}"
if command_exists docker; then
    DOCKER_VERSION=$(docker --version)
    echo -e "${GREEN}  ✓ Docker is installed: $DOCKER_VERSION${NC}"
else
    echo -e "${RED}  ✗ Docker is not installed${NC}"
    echo -e "${YELLOW}  Installing Docker...${NC}"
    $SUDO pacman -S --noconfirm docker docker-compose
    if command_exists docker; then
        echo -e "${GREEN}  ✓ Docker installed successfully${NC}"
        $SUDO systemctl start docker
        $SUDO systemctl enable docker
        if ! is_root; then
            $SUDO usermod -aG docker $USER
            echo -e "${YELLOW}  ⚠ Added $USER to docker group. Please log out and back in for changes to take effect.${NC}"
        fi
    else
        echo -e "${RED}  ✗ Docker installation failed${NC}"
        HAS_ERRORS=true
    fi
fi
echo ""

# 5. Check/Install OpenSSL
echo -e "${YELLOW}[5/6] Checking OpenSSL...${NC}"
if command_exists openssl; then
    OPENSSL_VERSION=$(openssl version)
    echo -e "${GREEN}  ✓ OpenSSL is installed: $OPENSSL_VERSION${NC}"
else
    echo -e "${RED}  ✗ OpenSSL is not installed${NC}"
    echo -e "${YELLOW}  Installing OpenSSL...${NC}"
    $SUDO pacman -S --noconfirm openssl
    if command_exists openssl; then
        echo -e "${GREEN}  ✓ OpenSSL installed successfully${NC}"
    else
        echo -e "${RED}  ✗ OpenSSL installation failed${NC}"
        HAS_ERRORS=true
    fi
fi
echo ""

# 6. Check/Install Node.js, npm, and required npm packages
echo -e "${YELLOW}[6/6] Checking Node.js (18+), npm, and npm packages...${NC}"
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
    $SUDO pacman -S --noconfirm nodejs npm
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
