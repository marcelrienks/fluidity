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

# 7. Check/Install Node.js and npm packages
echo -e "${YELLOW}[7/7] Checking Node.js (18+), npm, and npm packages...${NC}"
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
    case $DISTRO in
        ubuntu|debian)
            curl -fsSL https://deb.nodesource.com/setup_lts.x | $SUDO -E bash -
            $SUDO apt install -y nodejs npm
            ;;
        fedora)
            curl -fsSL https://rpm.nodesource.com/setup_lts.x | $SUDO bash -
            $SUDO dnf install -y nodejs npm
            ;;
        centos|rhel)
            curl -fsSL https://rpm.nodesource.com/setup_lts.x | $SUDO bash -
            $SUDO yum install -y nodejs npm
            ;;
        arch|manjaro)
            $SUDO pacman -S --noconfirm nodejs npm
            ;;
        *)
            echo -e "${RED}  ✗ Cannot install Node.js and npm automatically${NC}"
            echo -e "${YELLOW}    Please install manually from https://nodejs.org/${NC}"
            HAS_ERRORS=true
            ;;
    esac
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
        echo -e "${YELLOW}  Installing required npm packages...${NC}"
        if $SUDO npm install -g ws https-proxy-agent; then
            echo -e "${GREEN}  ✓ npm packages installed successfully${NC}"
        else
            echo -e "${RED}  ✗ Error installing npm packages${NC}"
            HAS_ERRORS=true
        fi
    else
        echo -e "${GREEN}  ✓ Required npm packages are installed${NC}"
    fi
fi
echo ""
    fi
fi
echo ""

# 6. Check/Install Node.js, npm, and required npm packages
echo -e "${YELLOW}[6/6] Checking Node.js (18+) and npm packages...${NC}"
if command_exists node; then
    NODE_VERSION=$(node --version)
    echo -e "${GREEN}  ✓ Node.js is installed: $NODE_VERSION${NC}"
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
        echo -e "${YELLOW}  Installing required npm packages...${NC}"
        if $SUDO npm install -g ws https-proxy-agent; then
            echo -e "${GREEN}  ✓ npm packages installed successfully${NC}"
        else
            echo -e "${RED}  ✗ Error installing npm packages${NC}"
            HAS_ERRORS=true
        fi
    else
        echo -e "${GREEN}  ✓ Required npm packages are installed${NC}"
    fi
else
    echo -e "${RED}  ✗ Node.js is not installed${NC}"
    echo -e "${YELLOW}  Installing Node.js and npm...${NC}"
    $SUDO pacman -S --noconfirm nodejs npm
    if command_exists node; then
        echo -e "${GREEN}  ✓ Node.js installed successfully${NC}"
        echo -e "${YELLOW}  Installing required npm packages...${NC}"
        if $SUDO npm install -g ws https-proxy-agent; then
            echo -e "${GREEN}  ✓ npm packages installed successfully${NC}"
        else
            echo -e "${RED}  ✗ Error installing npm packages${NC}"
            HAS_ERRORS=true
        fi
    else
        echo -e "${RED}  ✗ Node.js installation failed${NC}"
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
