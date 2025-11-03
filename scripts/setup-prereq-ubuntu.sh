#!/bin/bash#!/bin/bash

# Setup Prerequisites Script for Ubuntu/Debian Linux# Setup Prerequisites Script for Arch Linux/Hyprland

# This script checks for and installs required prerequisites for Fluidity on Ubuntu/Debian-based systems (including WSL)# This script checks for and installs required prerequisites for Fluidity on Arch-based systems



set -eset -e



echo "========================================"echo "========================================"

echo "Fluidity Prerequisites Setup (Ubuntu/Debian)"echo "Fluidity Prerequisites Setup (Arch/Hyprland)"

echo "========================================"echo "========================================"

echo ""echo ""



HAS_ERRORS=falseHAS_ERRORS=false



# Colors# Colors

RED='\033[0;31m'RED='\033[0;31m'

GREEN='\033[0;32m'GREEN='\033[0;32m'

YELLOW='\033[1;33m'YELLOW='\033[1;33m'

CYAN='\033[0;36m'CYAN='\033[0;36m'

NC='\033[0m' # No ColorNC='\033[0m' # No Color



# Function to check if a command exists# Function to check if a command exists

command_exists() {command_exists() {

    command -v "$1" >/dev/null 2>&1    command -v "$1" >/dev/null 2>&1

}}



# Function to check if running as root# Function to check if running as root

is_root() {is_root() {

    [ "$(id -u)" -eq 0 ]    [ "$(id -u)" -eq 0 ]

}}



SUDO=""SUDO=""

if ! is_root; thenif ! is_root; then

    SUDO="sudo"    SUDO="sudo"

    echo -e "${YELLOW}Note: Some commands will require sudo password.${NC}"    echo -e "${YELLOW}Note: Some commands will require sudo password.${NC}"

    echo ""    echo ""

fifi



# 1. Update package manager# 1. Update package manager

echo -e "${YELLOW}[1/6] Updating package manager...${NC}"echo -e "${YELLOW}[1/6] Updating package manager...${NC}"

$SUDO apt-get update$SUDO pacman -Sy

echo -e "${GREEN}  ✓ Package lists updated${NC}"echo -e "${GREEN}  ✓ Package lists updated${NC}"

echo ""echo ""



# 2. Check/Install Go# 7. Check/Install Node.js and npm packages

echo -e "${YELLOW}[2/6] Checking Go (1.21+)...${NC}"echo -e "${YELLOW}[7/7] Checking Node.js (18+), npm, and npm packages...${NC}"

if command_exists go; thenNODE_INSTALLED=false

    GO_VERSION=$(go version)NPM_INSTALLED=false

    echo -e "${GREEN}  ✓ Go is installed: $GO_VERSION${NC}"if command_exists node; then

else    NODE_INSTALLED=true

    echo -e "${RED}  ✗ Go is not installed${NC}"    NODE_VERSION=$(node --version)

    echo -e "${YELLOW}  Installing Go...${NC}"    echo -e "${GREEN}  ✓ Node.js is installed: $NODE_VERSION${NC}"

    else

    # Check if we can install from apt    echo -e "${RED}  ✗ Node.js is not installed${NC}"

    GO_APT_VERSION=$($SUDO apt-cache show golang-go 2>/dev/null | grep "^Version:" | head -1 | awk '{print $2}' | cut -d'.' -f2)fi

    if command_exists npm; then

    if [ -n "$GO_APT_VERSION" ] && [ "$GO_APT_VERSION" -ge 21 ]; then    NPM_INSTALLED=true

        # apt version is 1.21+, use it    NPM_VERSION=$(npm --version)

        $SUDO apt-get install -y golang-go    echo -e "${GREEN}  ✓ npm is installed: $NPM_VERSION${NC}"

    elseelse

        # Download and install manually    echo -e "${RED}  ✗ npm is not installed${NC}"

        echo -e "${YELLOW}  Installing Go 1.21 manually (apt version too old)...${NC}"fi

        cd /tmp

        wget -q https://go.dev/dl/go1.21.0.linux-amd64.tar.gzif [ "$NODE_INSTALLED" = false ] || [ "$NPM_INSTALLED" = false ]; then

        $SUDO rm -rf /usr/local/go    echo -e "${YELLOW}  Installing Node.js and npm...${NC}"

        $SUDO tar -C /usr/local -xzf go1.21.0.linux-amd64.tar.gz    case $DISTRO in

        rm go1.21.0.linux-amd64.tar.gz        ubuntu|debian)

                    curl -fsSL https://deb.nodesource.com/setup_lts.x | $SUDO -E bash -

        # Add to PATH if not already there            $SUDO apt install -y nodejs npm

        if ! grep -q "/usr/local/go/bin" ~/.bashrc; then            ;;

            echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc        fedora)

            echo 'export PATH=$PATH:$HOME/go/bin' >> ~/.bashrc            curl -fsSL https://rpm.nodesource.com/setup_lts.x | $SUDO bash -

        fi            $SUDO dnf install -y nodejs npm

        export PATH=$PATH:/usr/local/go/bin            ;;

        export PATH=$PATH:$HOME/go/bin        centos|rhel)

    fi            curl -fsSL https://rpm.nodesource.com/setup_lts.x | $SUDO bash -

                $SUDO yum install -y nodejs npm

    if command_exists go; then            ;;

        GO_VERSION=$(go version)        arch|manjaro)

        echo -e "${GREEN}  ✓ Go installed successfully: $GO_VERSION${NC}"            $SUDO pacman -S --noconfirm nodejs npm

    else            ;;

        echo -e "${RED}  ✗ Go installation failed. Please install manually.${NC}"        *)

        echo -e "${YELLOW}    Visit: https://go.dev/doc/install${NC}"            echo -e "${RED}  ✗ Cannot install Node.js and npm automatically${NC}"

        HAS_ERRORS=true            echo -e "${YELLOW}    Please install manually from https://nodejs.org/${NC}"

    fi            HAS_ERRORS=true

fi            ;;

echo ""    esac

    if command_exists node; then

# 3. Check/Install Make        NODE_INSTALLED=true

echo -e "${YELLOW}[3/6] Checking Make...${NC}"        NODE_VERSION=$(node --version)

if command_exists make; then        echo -e "${GREEN}  ✓ Node.js installed successfully: $NODE_VERSION${NC}"

    MAKE_VERSION=$(make --version | head -n 1)    else

    echo -e "${GREEN}  ✓ Make is installed: $MAKE_VERSION${NC}"        echo -e "${RED}  ✗ Node.js installation failed${NC}"

else        HAS_ERRORS=true

    echo -e "${RED}  ✗ Make is not installed${NC}"    fi

    echo -e "${YELLOW}  Installing Make...${NC}"    if command_exists npm; then

    $SUDO apt-get install -y build-essential        NPM_INSTALLED=true

    if command_exists make; then        NPM_VERSION=$(npm --version)

        echo -e "${GREEN}  ✓ Make installed successfully${NC}"        echo -e "${GREEN}  ✓ npm installed successfully: $NPM_VERSION${NC}"

    else    else

        echo -e "${YELLOW}  Note: Make is optional - you can run build commands manually.${NC}"        echo -e "${RED}  ✗ npm installation failed${NC}"

    fi        HAS_ERRORS=true

fi    fi

echo ""fi



# 4. Check/Install Dockerif [ "$NODE_INSTALLED" = true ] && [ "$NPM_INSTALLED" = true ]; then

echo -e "${YELLOW}[4/6] Checking Docker...${NC}"    echo -e "${YELLOW}  Checking npm packages (ws, https-proxy-agent)...${NC}"

if command_exists docker; then    WS_INSTALLED=false

    DOCKER_VERSION=$(docker --version)    PROXY_INSTALLED=false

    echo -e "${GREEN}  ✓ Docker is installed: $DOCKER_VERSION${NC}"    if npm list -g ws 2>/dev/null | grep -q "ws@"; then

else        WS_INSTALLED=true

    echo -e "${RED}  ✗ Docker is not installed${NC}"    fi

    echo -e "${YELLOW}  Installing Docker...${NC}"    if npm list -g https-proxy-agent 2>/dev/null | grep -q "https-proxy-agent@"; then

            PROXY_INSTALLED=true

    # Install prerequisites    fi

    $SUDO apt-get install -y ca-certificates curl gnupg lsb-release    if [ "$WS_INSTALLED" = false ] || [ "$PROXY_INSTALLED" = false ]; then

            echo -e "${YELLOW}  Installing required npm packages...${NC}"

    # Add Docker's official GPG key        if $SUDO npm install -g ws https-proxy-agent; then

    $SUDO mkdir -p /etc/apt/keyrings            echo -e "${GREEN}  ✓ npm packages installed successfully${NC}"

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg        else

                echo -e "${RED}  ✗ Error installing npm packages${NC}"

    # Set up the repository            HAS_ERRORS=true

    echo \        fi

      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \    else

      $(lsb_release -cs) stable" | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null        echo -e "${GREEN}  ✓ Required npm packages are installed${NC}"

        fi

    # Install Docker Enginefi

    $SUDO apt-get updateecho ""

    $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin    fi

    fi

    if command_exists docker; thenecho ""

        echo -e "${GREEN}  ✓ Docker installed successfully${NC}"

        # 6. Check/Install Node.js, npm, and required npm packages

        # Start Docker serviceecho -e "${YELLOW}[6/6] Checking Node.js (18+) and npm packages...${NC}"

        $SUDO systemctl start docker 2>/dev/null || echo -e "${YELLOW}  Note: Docker service management not available (normal for WSL)${NC}"if command_exists node; then

        $SUDO systemctl enable docker 2>/dev/null || true    NODE_VERSION=$(node --version)

            echo -e "${GREEN}  ✓ Node.js is installed: $NODE_VERSION${NC}"

        # Add user to docker group    echo -e "${YELLOW}  Checking npm packages (ws, https-proxy-agent)...${NC}"

        if ! is_root; then    WS_INSTALLED=false

            $SUDO usermod -aG docker $USER    PROXY_INSTALLED=false

            echo -e "${YELLOW}  ⚠ Added $USER to docker group. Please log out and back in for changes to take effect.${NC}"    if npm list -g ws 2>/dev/null | grep -q "ws@"; then

        fi        WS_INSTALLED=true

    else    fi

        echo -e "${RED}  ✗ Docker installation failed${NC}"    if npm list -g https-proxy-agent 2>/dev/null | grep -q "https-proxy-agent@"; then

        echo -e "${YELLOW}    For WSL, you may need to install Docker Desktop for Windows instead.${NC}"        PROXY_INSTALLED=true

        HAS_ERRORS=true    fi

    fi    if [ "$WS_INSTALLED" = false ] || [ "$PROXY_INSTALLED" = false ]; then

fi        echo -e "${YELLOW}  Installing required npm packages...${NC}"

echo ""        if $SUDO npm install -g ws https-proxy-agent; then

            echo -e "${GREEN}  ✓ npm packages installed successfully${NC}"

# 5. Check/Install OpenSSL        else

echo -e "${YELLOW}[5/6] Checking OpenSSL...${NC}"            echo -e "${RED}  ✗ Error installing npm packages${NC}"

if command_exists openssl; then            HAS_ERRORS=true

    OPENSSL_VERSION=$(openssl version)        fi

    echo -e "${GREEN}  ✓ OpenSSL is installed: $OPENSSL_VERSION${NC}"    else

else        echo -e "${GREEN}  ✓ Required npm packages are installed${NC}"

    echo -e "${RED}  ✗ OpenSSL is not installed${NC}"    fi

    echo -e "${YELLOW}  Installing OpenSSL...${NC}"else

    $SUDO apt-get install -y openssl    echo -e "${RED}  ✗ Node.js is not installed${NC}"

    if command_exists openssl; then    echo -e "${YELLOW}  Installing Node.js and npm...${NC}"

        echo -e "${GREEN}  ✓ OpenSSL installed successfully${NC}"    $SUDO pacman -S --noconfirm nodejs npm

    else    if command_exists node; then

        echo -e "${RED}  ✗ OpenSSL installation failed${NC}"        echo -e "${GREEN}  ✓ Node.js installed successfully${NC}"

        HAS_ERRORS=true        echo -e "${YELLOW}  Installing required npm packages...${NC}"

    fi        if $SUDO npm install -g ws https-proxy-agent; then

fi            echo -e "${GREEN}  ✓ npm packages installed successfully${NC}"

echo ""        else

            echo -e "${RED}  ✗ Error installing npm packages${NC}"

# 6. Check/Install Node.js, npm, and required npm packages            HAS_ERRORS=true

echo -e "${YELLOW}[6/6] Checking Node.js (18+), npm, and npm packages...${NC}"        fi

NODE_INSTALLED=false    else

NPM_INSTALLED=false        echo -e "${RED}  ✗ Node.js installation failed${NC}"

if command_exists node; then        HAS_ERRORS=true

    NODE_INSTALLED=true    fi

    NODE_VERSION=$(node --version)fi

    echo -e "${GREEN}  ✓ Node.js is installed: $NODE_VERSION${NC}"echo ""

else

    echo -e "${RED}  ✗ Node.js is not installed${NC}"# Summary

fiecho "========================================"

if command_exists npm; thenecho "Setup Summary"

    NPM_INSTALLED=trueecho "========================================"

    NPM_VERSION=$(npm --version)

    echo -e "${GREEN}  ✓ npm is installed: $NPM_VERSION${NC}"if [ "$HAS_ERRORS" = true ]; then

else    echo -e "${YELLOW}⚠ Setup completed with errors. Please review the output above.${NC}"

    echo -e "${RED}  ✗ npm is not installed${NC}"    echo -e "${YELLOW}  Some prerequisites may need to be installed manually.${NC}"

fi    exit 1

else

if [ "$NODE_INSTALLED" = false ] || [ "$NPM_INSTALLED" = false ]; then    echo -e "${GREEN}✓ All prerequisites are installed!${NC}"

    echo -e "${YELLOW}  Installing Node.js and npm...${NC}"    echo ""

        echo -e "${CYAN}Next steps:${NC}"

    # Install Node.js 18.x from NodeSource    echo "  1. Close and reopen your terminal to refresh environment variables"

    curl -fsSL https://deb.nodesource.com/setup_18.x | $SUDO -E bash -    echo "  2. If Docker was installed, log out and back in to apply docker group membership"

    $SUDO apt-get install -y nodejs    echo "  3. Generate certificates: cd scripts && ./generate-certs.sh"

        echo "  4. Build the project: make build-linux"

    if command_exists node; then    echo "  5. Run tests: ./scripts/test-local.sh"

        NODE_INSTALLED=true    exit 0

        NODE_VERSION=$(node --version)fi

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
                echo -e "${YELLOW}      export PATH=\"\$HOME/.npm-global/bin:\$PATH\" (add to ~/.bashrc or ~/.zshrc)"
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
    echo "  3. Generate certificates: ./scripts/manage-certs.sh"
    echo "  4. Build the project: make -f Makefile.linux build"
    echo "  5. Run tests: ./scripts/test-local.sh"
    exit 0
fi
