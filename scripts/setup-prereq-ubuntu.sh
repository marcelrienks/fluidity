#!/bin/bash#!/bin/bash#!/bin/bash

# Setup Prerequisites Script for Ubuntu/Debian Linux

# This script checks for and installs required prerequisites for Fluidity on Ubuntu/Debian-based systems (including WSL)# Setup Prerequisites Script for Ubuntu/Debian Linux# Setup Prerequisites Script for Arch Linux/Hyprland



set -e# This script checks for and installs required prerequisites for Fluidity on Ubuntu/Debian-based systems (including WSL)# This script checks for and installs required prerequisites for Fluidity on Arch-based systems



echo "========================================"

echo "Fluidity Prerequisites Setup (Ubuntu/Debian)"

echo "========================================"set -eset -e

echo ""



HAS_ERRORS=false

echo "========================================"echo "========================================"

# Colors

RED='\033[0;31m'echo "Fluidity Prerequisites Setup (Ubuntu/Debian)"echo "Fluidity Prerequisites Setup (Arch/Hyprland)"

GREEN='\033[0;32m'

YELLOW='\033[1;33m'echo "========================================"echo "========================================"

CYAN='\033[0;36m'

NC='\033[0m' # No Colorecho ""echo ""



# Function to check if a command exists

command_exists() {

    command -v "$1" >/dev/null 2>&1HAS_ERRORS=falseHAS_ERRORS=false

}



# Function to check if running as root

is_root() {# Colors# Colors

    [ "$(id -u)" -eq 0 ]

}RED='\033[0;31m'RED='\033[0;31m'



SUDO=""GREEN='\033[0;32m'GREEN='\033[0;32m'

if ! is_root; then

    SUDO="sudo"YELLOW='\033[1;33m'YELLOW='\033[1;33m'

    echo -e "${YELLOW}Note: Some commands will require sudo password.${NC}"

    echo ""CYAN='\033[0;36m'CYAN='\033[0;36m'

fi

NC='\033[0m' # No ColorNC='\033[0m' # No Color

# 1. Update package manager

echo -e "${YELLOW}[1/6] Updating package manager...${NC}"

$SUDO apt-get update

echo -e "${GREEN}  ✓ Package lists updated${NC}"# Function to check if a command exists# Function to check if a command exists

echo ""

command_exists() {command_exists() {

# 2. Check/Install Go

echo -e "${YELLOW}[2/6] Checking Go (1.21+)...${NC}"    command -v "$1" >/dev/null 2>&1    command -v "$1" >/dev/null 2>&1

if command_exists go; then

    GO_VERSION=$(go version)}}

    echo -e "${GREEN}  ✓ Go is installed: $GO_VERSION${NC}"

else

    echo -e "${RED}  ✗ Go is not installed${NC}"

    echo -e "${YELLOW}  Installing Go...${NC}"# Function to check if running as root# Function to check if running as root

    

    # Check if we can install from aptis_root() {is_root() {

    GO_APT_VERSION=$($SUDO apt-cache show golang-go 2>/dev/null | grep "^Version:" | head -1 | awk '{print $2}' | cut -d'.' -f2)

        [ "$(id -u)" -eq 0 ]    [ "$(id -u)" -eq 0 ]

    if [ -n "$GO_APT_VERSION" ] && [ "$GO_APT_VERSION" -ge 21 ]; then

        # apt version is 1.21+, use it}}

        $SUDO apt-get install -y golang-go

    else

        # Download and install manually

        echo -e "${YELLOW}  Installing Go 1.21 manually (apt version too old)...${NC}"SUDO=""SUDO=""

        cd /tmp

        wget -q https://go.dev/dl/go1.21.0.linux-amd64.tar.gzif ! is_root; thenif ! is_root; then

        $SUDO rm -rf /usr/local/go

        $SUDO tar -C /usr/local -xzf go1.21.0.linux-amd64.tar.gz    SUDO="sudo"    SUDO="sudo"

        rm go1.21.0.linux-amd64.tar.gz

            echo -e "${YELLOW}Note: Some commands will require sudo password.${NC}"    echo -e "${YELLOW}Note: Some commands will require sudo password.${NC}"

        # Add to PATH if not already there

        if ! grep -q "/usr/local/go/bin" ~/.bashrc; then    echo ""    echo ""

            echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc

            echo 'export PATH=$PATH:$HOME/go/bin' >> ~/.bashrcfifi

        fi

        export PATH=$PATH:/usr/local/go/bin

        export PATH=$PATH:$HOME/go/bin

    fi# 1. Update package manager# 1. Update package manager

    

    if command_exists go; thenecho -e "${YELLOW}[1/6] Updating package manager...${NC}"echo -e "${YELLOW}[1/6] Updating package manager...${NC}"

        GO_VERSION=$(go version)

        echo -e "${GREEN}  ✓ Go installed successfully: $GO_VERSION${NC}"$SUDO apt-get update$SUDO pacman -Sy

    else

        echo -e "${RED}  ✗ Go installation failed. Please install manually.${NC}"echo -e "${GREEN}  ✓ Package lists updated${NC}"echo -e "${GREEN}  ✓ Package lists updated${NC}"

        echo -e "${YELLOW}    Visit: https://go.dev/doc/install${NC}"

        HAS_ERRORS=trueecho ""echo ""

    fi

fi

echo ""

# 2. Check/Install Go# 7. Check/Install Node.js and npm packages

# 3. Check/Install Make

echo -e "${YELLOW}[3/6] Checking Make...${NC}"echo -e "${YELLOW}[2/6] Checking Go (1.21+)...${NC}"echo -e "${YELLOW}[7/7] Checking Node.js (18+), npm, and npm packages...${NC}"

if command_exists make; then

    MAKE_VERSION=$(make --version | head -n 1)if command_exists go; thenNODE_INSTALLED=false

    echo -e "${GREEN}  ✓ Make is installed: $MAKE_VERSION${NC}"

else    GO_VERSION=$(go version)NPM_INSTALLED=false

    echo -e "${RED}  ✗ Make is not installed${NC}"

    echo -e "${YELLOW}  Installing Make...${NC}"    echo -e "${GREEN}  ✓ Go is installed: $GO_VERSION${NC}"if command_exists node; then

    $SUDO apt-get install -y build-essential

    if command_exists make; thenelse    NODE_INSTALLED=true

        echo -e "${GREEN}  ✓ Make installed successfully${NC}"

    else    echo -e "${RED}  ✗ Go is not installed${NC}"    NODE_VERSION=$(node --version)

        echo -e "${YELLOW}  Note: Make is optional - you can run build commands manually.${NC}"

    fi    echo -e "${YELLOW}  Installing Go...${NC}"    echo -e "${GREEN}  ✓ Node.js is installed: $NODE_VERSION${NC}"

fi

echo ""    else



# 4. Check/Install Docker    # Check if we can install from apt    echo -e "${RED}  ✗ Node.js is not installed${NC}"

echo -e "${YELLOW}[4/6] Checking Docker...${NC}"

if command_exists docker; then    GO_APT_VERSION=$($SUDO apt-cache show golang-go 2>/dev/null | grep "^Version:" | head -1 | awk '{print $2}' | cut -d'.' -f2)fi

    DOCKER_VERSION=$(docker --version)

    echo -e "${GREEN}  ✓ Docker is installed: $DOCKER_VERSION${NC}"    if command_exists npm; then

else

    echo -e "${RED}  ✗ Docker is not installed${NC}"    if [ -n "$GO_APT_VERSION" ] && [ "$GO_APT_VERSION" -ge 21 ]; then    NPM_INSTALLED=true

    echo -e "${YELLOW}  Installing Docker...${NC}"

            # apt version is 1.21+, use it    NPM_VERSION=$(npm --version)

    # Install prerequisites

    $SUDO apt-get install -y ca-certificates curl gnupg lsb-release        $SUDO apt-get install -y golang-go    echo -e "${GREEN}  ✓ npm is installed: $NPM_VERSION${NC}"

    

    # Add Docker's official GPG key    elseelse

    $SUDO mkdir -p /etc/apt/keyrings

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg        # Download and install manually    echo -e "${RED}  ✗ npm is not installed${NC}"

    

    # Set up the repository        echo -e "${YELLOW}  Installing Go 1.21 manually (apt version too old)...${NC}"fi

    echo \

      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \        cd /tmp

      $(lsb_release -cs) stable" | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null

            wget -q https://go.dev/dl/go1.21.0.linux-amd64.tar.gzif [ "$NODE_INSTALLED" = false ] || [ "$NPM_INSTALLED" = false ]; then

    # Install Docker Engine

    $SUDO apt-get update        $SUDO rm -rf /usr/local/go    echo -e "${YELLOW}  Installing Node.js and npm...${NC}"

    $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

            $SUDO tar -C /usr/local -xzf go1.21.0.linux-amd64.tar.gz    case $DISTRO in

    if command_exists docker; then

        echo -e "${GREEN}  ✓ Docker installed successfully${NC}"        rm go1.21.0.linux-amd64.tar.gz        ubuntu|debian)

        

        # Start Docker service                    curl -fsSL https://deb.nodesource.com/setup_lts.x | $SUDO -E bash -

        $SUDO systemctl start docker 2>/dev/null || echo -e "${YELLOW}  Note: Docker service management not available (normal for WSL)${NC}"

        $SUDO systemctl enable docker 2>/dev/null || true        # Add to PATH if not already there            $SUDO apt install -y nodejs npm

        

        # Add user to docker group        if ! grep -q "/usr/local/go/bin" ~/.bashrc; then            ;;

        if ! is_root; then

            $SUDO usermod -aG docker $USER            echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc        fedora)

            echo -e "${YELLOW}  ⚠ Added $USER to docker group. Please log out and back in for changes to take effect.${NC}"

        fi            echo 'export PATH=$PATH:$HOME/go/bin' >> ~/.bashrc            curl -fsSL https://rpm.nodesource.com/setup_lts.x | $SUDO bash -

    else

        echo -e "${RED}  ✗ Docker installation failed${NC}"        fi            $SUDO dnf install -y nodejs npm

        echo -e "${YELLOW}    For WSL, you may need to install Docker Desktop for Windows instead.${NC}"

        HAS_ERRORS=true        export PATH=$PATH:/usr/local/go/bin            ;;

    fi

fi        export PATH=$PATH:$HOME/go/bin        centos|rhel)

echo ""

    fi            curl -fsSL https://rpm.nodesource.com/setup_lts.x | $SUDO bash -

# 5. Check/Install OpenSSL

echo -e "${YELLOW}[5/6] Checking OpenSSL...${NC}"                $SUDO yum install -y nodejs npm

if command_exists openssl; then

    OPENSSL_VERSION=$(openssl version)    if command_exists go; then            ;;

    echo -e "${GREEN}  ✓ OpenSSL is installed: $OPENSSL_VERSION${NC}"

else        GO_VERSION=$(go version)        arch|manjaro)

    echo -e "${RED}  ✗ OpenSSL is not installed${NC}"

    echo -e "${YELLOW}  Installing OpenSSL...${NC}"        echo -e "${GREEN}  ✓ Go installed successfully: $GO_VERSION${NC}"            $SUDO pacman -S --noconfirm nodejs npm

    $SUDO apt-get install -y openssl

    if command_exists openssl; then    else            ;;

        echo -e "${GREEN}  ✓ OpenSSL installed successfully${NC}"

    else        echo -e "${RED}  ✗ Go installation failed. Please install manually.${NC}"        *)

        echo -e "${RED}  ✗ OpenSSL installation failed${NC}"

        HAS_ERRORS=true        echo -e "${YELLOW}    Visit: https://go.dev/doc/install${NC}"            echo -e "${RED}  ✗ Cannot install Node.js and npm automatically${NC}"

    fi

fi        HAS_ERRORS=true            echo -e "${YELLOW}    Please install manually from https://nodejs.org/${NC}"

echo ""

    fi            HAS_ERRORS=true

# 6. Check/Install Node.js, npm, and required npm packages

echo -e "${YELLOW}[6/6] Checking Node.js (18+), npm, and npm packages...${NC}"fi            ;;

NODE_INSTALLED=false

NPM_INSTALLED=falseecho ""    esac

if command_exists node; then

    NODE_INSTALLED=true    if command_exists node; then

    NODE_VERSION=$(node --version)

    echo -e "${GREEN}  ✓ Node.js is installed: $NODE_VERSION${NC}"# 3. Check/Install Make        NODE_INSTALLED=true

else

    echo -e "${RED}  ✗ Node.js is not installed${NC}"echo -e "${YELLOW}[3/6] Checking Make...${NC}"        NODE_VERSION=$(node --version)

fi

if command_exists npm; thenif command_exists make; then        echo -e "${GREEN}  ✓ Node.js installed successfully: $NODE_VERSION${NC}"

    NPM_INSTALLED=true

    NPM_VERSION=$(npm --version)    MAKE_VERSION=$(make --version | head -n 1)    else

    echo -e "${GREEN}  ✓ npm is installed: $NPM_VERSION${NC}"

else    echo -e "${GREEN}  ✓ Make is installed: $MAKE_VERSION${NC}"        echo -e "${RED}  ✗ Node.js installation failed${NC}"

    echo -e "${RED}  ✗ npm is not installed${NC}"

fielse        HAS_ERRORS=true



if [ "$NODE_INSTALLED" = false ] || [ "$NPM_INSTALLED" = false ]; then    echo -e "${RED}  ✗ Make is not installed${NC}"    fi

    echo -e "${YELLOW}  Installing Node.js and npm...${NC}"

        echo -e "${YELLOW}  Installing Make...${NC}"    if command_exists npm; then

    # Install Node.js 18.x from NodeSource

    curl -fsSL https://deb.nodesource.com/setup_18.x | $SUDO -E bash -    $SUDO apt-get install -y build-essential        NPM_INSTALLED=true

    $SUDO apt-get install -y nodejs

        if command_exists make; then        NPM_VERSION=$(npm --version)

    if command_exists node; then

        NODE_INSTALLED=true        echo -e "${GREEN}  ✓ Make installed successfully${NC}"        echo -e "${GREEN}  ✓ npm installed successfully: $NPM_VERSION${NC}"

        NODE_VERSION=$(node --version)

        echo -e "${GREEN}  ✓ Node.js installed successfully: $NODE_VERSION${NC}"    else    else

    else

        echo -e "${RED}  ✗ Node.js installation failed${NC}"        echo -e "${YELLOW}  Note: Make is optional - you can run build commands manually.${NC}"        echo -e "${RED}  ✗ npm installation failed${NC}"

        HAS_ERRORS=true

    fi    fi        HAS_ERRORS=true

    if command_exists npm; then

        NPM_INSTALLED=truefi    fi

        NPM_VERSION=$(npm --version)

        echo -e "${GREEN}  ✓ npm installed successfully: $NPM_VERSION${NC}"echo ""fi

    else

        echo -e "${RED}  ✗ npm installation failed${NC}"

        HAS_ERRORS=true

    fi# 4. Check/Install Dockerif [ "$NODE_INSTALLED" = true ] && [ "$NPM_INSTALLED" = true ]; then

fi

echo -e "${YELLOW}[4/6] Checking Docker...${NC}"    echo -e "${YELLOW}  Checking npm packages (ws, https-proxy-agent)...${NC}"

if [ "$NODE_INSTALLED" = true ] && [ "$NPM_INSTALLED" = true ]; then

    echo -e "${YELLOW}  Checking npm packages (ws, https-proxy-agent)...${NC}"if command_exists docker; then    WS_INSTALLED=false

    WS_INSTALLED=false

    PROXY_INSTALLED=false    DOCKER_VERSION=$(docker --version)    PROXY_INSTALLED=false

    if npm list -g ws 2>/dev/null | grep -q "ws@"; then

        WS_INSTALLED=true    echo -e "${GREEN}  ✓ Docker is installed: $DOCKER_VERSION${NC}"    if npm list -g ws 2>/dev/null | grep -q "ws@"; then

    fi

    if npm list -g https-proxy-agent 2>/dev/null | grep -q "https-proxy-agent@"; thenelse        WS_INSTALLED=true

        PROXY_INSTALLED=true

    fi    echo -e "${RED}  ✗ Docker is not installed${NC}"    fi

    if [ "$WS_INSTALLED" = false ] || [ "$PROXY_INSTALLED" = false ]; then

        echo -e "${YELLOW}  Installing required npm packages globally...${NC}"    echo -e "${YELLOW}  Installing Docker...${NC}"    if npm list -g https-proxy-agent 2>/dev/null | grep -q "https-proxy-agent@"; then

        # Try with sudo first

        if $SUDO npm install -g ws https-proxy-agent 2>/dev/null; then            PROXY_INSTALLED=true

            echo -e "${GREEN}  ✓ npm packages installed globally (with sudo)${NC}"

        else    # Install prerequisites    fi

            echo -e "${YELLOW}  sudo npm failed, retrying without sudo (user global install)...${NC}"

            if npm install -g ws https-proxy-agent; then    $SUDO apt-get install -y ca-certificates curl gnupg lsb-release    if [ "$WS_INSTALLED" = false ] || [ "$PROXY_INSTALLED" = false ]; then

                echo -e "${GREEN}  ✓ npm packages installed globally (user global)${NC}"

            else            echo -e "${YELLOW}  Installing required npm packages...${NC}"

                echo -e "${RED}  ✗ Error installing npm packages globally with and without sudo${NC}"

                echo -e "${YELLOW}    If you see 'npm: command not found' with sudo, npm may not be in root's PATH."    # Add Docker's official GPG key        if $SUDO npm install -g ws https-proxy-agent; then

                echo -e "${YELLOW}    You can configure npm to use a user directory for global installs:"

                echo -e "${YELLOW}      mkdir -p ~/.npm-global && npm config set prefix '~/.npm-global'"    $SUDO mkdir -p /etc/apt/keyrings            echo -e "${GREEN}  ✓ npm packages installed successfully${NC}"

                echo -e "${YELLOW}      export PATH=\"\$HOME/.npm-global/bin:\$PATH\" (add to ~/.bashrc or ~/.zshrc)"

                HAS_ERRORS=true    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg        else

            fi

        fi                echo -e "${RED}  ✗ Error installing npm packages${NC}"

    else

        echo -e "${GREEN}  ✓ Required npm packages are installed globally${NC}"    # Set up the repository            HAS_ERRORS=true

    fi

    # Always ensure local node_modules for tests    echo \        fi

    echo -e "${YELLOW}  Ensuring local node_modules for ws and https-proxy-agent...${NC}"

    if npm install ws https-proxy-agent; then      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \    else

        echo -e "${GREEN}  ✓ Local node_modules installed for ws and https-proxy-agent${NC}"

    else      $(lsb_release -cs) stable" | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null        echo -e "${GREEN}  ✓ Required npm packages are installed${NC}"

        echo -e "${RED}  ✗ Error installing local node_modules for ws and https-proxy-agent${NC}"

        HAS_ERRORS=true        fi

    fi

fi    # Install Docker Enginefi

echo ""

    $SUDO apt-get updateecho ""

# Summary

echo "========================================"    $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin    fi

echo "Setup Summary"

echo "========================================"    fi



if [ "$HAS_ERRORS" = true ]; then    if command_exists docker; thenecho ""

    echo -e "${YELLOW}⚠ Setup completed with errors. Please review the output above.${NC}"

    echo -e "${YELLOW}  Some prerequisites may need to be installed manually.${NC}"        echo -e "${GREEN}  ✓ Docker installed successfully${NC}"

    exit 1

else        # 6. Check/Install Node.js, npm, and required npm packages

    echo -e "${GREEN}✓ All prerequisites are installed!${NC}"

    echo ""        # Start Docker serviceecho -e "${YELLOW}[6/6] Checking Node.js (18+) and npm packages...${NC}"

    echo -e "${CYAN}Next steps:${NC}"

    echo "  1. Close and reopen your terminal to refresh environment variables"        $SUDO systemctl start docker 2>/dev/null || echo -e "${YELLOW}  Note: Docker service management not available (normal for WSL)${NC}"if command_exists node; then

    echo "  2. If Docker was installed, log out and back in to apply docker group membership"

    echo "  3. Generate certificates: ./scripts/manage-certs.sh"        $SUDO systemctl enable docker 2>/dev/null || true    NODE_VERSION=$(node --version)

    echo "  4. Build the project: make -f Makefile.linux build"

    echo "  5. Run tests: ./scripts/test-local.sh"            echo -e "${GREEN}  ✓ Node.js is installed: $NODE_VERSION${NC}"

    exit 0

fi        # Add user to docker group    echo -e "${YELLOW}  Checking npm packages (ws, https-proxy-agent)...${NC}"


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
