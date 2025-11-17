#!/usr/bin/env bash

###############################################################################
# Fluidity Agent Deployment Script
# 
# Builds the Fluidity agent and deploys it to the system, making it available 
# as a command-line executable. Manages agent configuration with support for
# command-line overrides.
#
# Configuration Management:
#   - Loads config from agent.yaml in installation directory
#   - Command-line arguments override config file values
#   - At startup, agent requests missing required configuration
#   - Deploy script can provide all config values via command-line
#
# FUNCTION:
#   - Builds the Fluidity agent binary from source
#   - Deploys to system installation directory
#   - Manages configuration file (creation, updates, overrides)
#   - Adds to system PATH for command-line access
#
# USAGE:
#   ./deploy-agent.sh [action] [options]
#
# ACTIONS:
#   deploy      Build and deploy agent (default)
#   uninstall   Remove agent from system
#   status      Show deployment status
#
# OPTIONS:
#   --server-ip <ip>           Server IP address
#   --server-port <port>       Server port (default: 8443)
#   --local-proxy-port <port>  Agent listening port (default: 8080)
#   --wake-endpoint <url>      Wake Lambda Function URL
#   --kill-endpoint <url>      Kill Lambda Function URL
#   --cert-path <path>         Path to client certificate
#   --key-path <path>          Path to client private key
#   --ca-cert-path <path>      Path to CA certificate
#   --install-path <path>      Custom installation path (optional)
#   --skip-build               Use existing binary in build directory
#   --log-level <level>        Log level (info/debug/error, default: info)
#   --debug                    Enable debug logging
#   -h, --help                 Show this help message
#
# EXAMPLES:
#   ./deploy-agent.sh deploy --server-ip 192.168.1.100 --server-port 8443 --local-proxy-port 8080
#   ./deploy-agent.sh deploy --server-ip 192.168.1.100 --wake-endpoint <url> --kill-endpoint <url>
#   ./deploy-agent.sh status
#   ./deploy-agent.sh uninstall
#
###############################################################################

set -euo pipefail

# ============================================================================
# CONFIGURATION & DEFAULTS
# ============================================================================

ACTION="${1:-deploy}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_ROOT/build"
CMD_DIR="$PROJECT_ROOT/cmd/core/agent"

# Agent Configuration (from command-line or config file)
SERVER_IP=""
SERVER_PORT="8443"
LOCAL_PROXY_PORT="8080"
WAKE_ENDPOINT=""
KILL_ENDPOINT=""
CERT_PATH=""
KEY_PATH=""
CA_CERT_PATH=""
LOG_LEVEL="info"
INSTALL_PATH=""
CONFIG_FILE=""

# Feature Flags
DEBUG=false
SKIP_BUILD=false

# Detect OS and set defaults
# Check if running in WSL
IS_WSL=false
if [[ -f /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL=true
fi

case "$(uname -s)" in
    MINGW64_NT*|MSYS_NT*|CYGWIN*)
        OS_TYPE="windows"
        DEFAULT_INSTALL_PATH="C:\\Program Files\\fluidity"
        AGENT_BINARY="fluidity-agent.exe"
        ;;
    Darwin)
        OS_TYPE="darwin"
        DEFAULT_INSTALL_PATH="/usr/local/bin"
        AGENT_BINARY="fluidity-agent"
        ;;
    Linux)
        if [[ "$IS_WSL" == "true" ]]; then
            # Running in WSL - use Windows installation path
            OS_TYPE="windows-wsl"
            DEFAULT_INSTALL_PATH="C:\\Program Files\\fluidity"
            AGENT_BINARY="fluidity-agent.exe"
        else
            # Native Linux
            OS_TYPE="linux"
            DEFAULT_INSTALL_PATH="/opt/fluidity"
            AGENT_BINARY="fluidity-agent"
        fi
        ;;
    *)
        OS_TYPE="linux"
        DEFAULT_INSTALL_PATH="/opt/fluidity"
        AGENT_BINARY="fluidity-agent"
        ;;
esac

INSTALL_PATH="${INSTALL_PATH:-$DEFAULT_INSTALL_PATH}"
CONFIG_FILE="$INSTALL_PATH/agent.yaml"
AGENT_EXE_PATH="$INSTALL_PATH/$AGENT_BINARY"
BUILD_VERSION=$(date +%Y%m%d%H%M%S)

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

log_info() {
    echo "[INFO] $*"
}

log_debug() {
    if [[ "$DEBUG" == "true" ]]; then
        echo "[DEBUG] $*" >&2
    fi
}

log_warn() {
    echo "[WARN] $*" >&2
}

log_error_start() {
    echo ""
    echo -e "${RED}================================================================================${RESET}"
    echo -e "${RED}ERROR${RESET}"
    echo -e "${RED}================================================================================${RESET}"
}

log_error_end() {
    echo -e "${RED}================================================================================${RESET}"
    echo ""
}

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

log_success() {
    echo "✓ $*"
}

# Convert WSL path to Windows path for display purposes
wsl_to_windows_path() {
    local wsl_path="$1"
    if [[ "$IS_WSL" == "true" && "$wsl_path" == /home/* ]]; then
        # /home/user -> AppData in Windows
        local username=$(whoami)
        echo "%APPDATA%\\fluidity (from WSL: $wsl_path)"
    elif [[ "$IS_WSL" == "true" && "$wsl_path" == /opt/* ]]; then
        # /opt -> Windows program files equivalent in WSL
        echo "WSL: $wsl_path (Windows accessible via: \\\\wsl.localhost\\\\Ubuntu\\$wsl_path)"
    else
        echo "$wsl_path"
    fi
}

check_sudo() {
    # Check if we have sudo access
    if [[ "$EUID" -ne 0 ]]; then
        log_error_start
        echo "This script requires sudo/root access for installation"
        echo ""
        echo "Please run with sudo:"
        echo "  sudo $0 ${@}"
        log_error_end
        exit 1
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
    shift || true
    while [[ $# -gt 0 ]]; do
        case $1 in
            --server-ip)
                SERVER_IP="$2"
                shift 2
                ;;
            --server-port)
                SERVER_PORT="$2"
                shift 2
                ;;
            --local-proxy-port)
                LOCAL_PROXY_PORT="$2"
                shift 2
                ;;
            --wake-endpoint)
                WAKE_ENDPOINT="$2"
                shift 2
                ;;
            --kill-endpoint)
                KILL_ENDPOINT="$2"
                shift 2
                ;;
            --cert-path)
                CERT_PATH="$2"
                shift 2
                ;;
            --key-path)
                KEY_PATH="$2"
                shift 2
                ;;
            --ca-cert-path)
                CA_CERT_PATH="$2"
                shift 2
                ;;
            --install-path)
                INSTALL_PATH="$2"
                AGENT_EXE_PATH="$INSTALL_PATH/$AGENT_BINARY"
                CONFIG_FILE="$INSTALL_PATH/agent.yaml"
                shift 2
                ;;
            --log-level)
                LOG_LEVEL="$2"
                shift 2
                ;;
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            -h|--help)
                show_help
                ;;
            *)
                log_error_start
                echo "Unknown option: $1"
                log_error_end
                exit 1
                ;;
        esac
    done
}

validate_action() {
    case "$ACTION" in
        deploy|uninstall|status)
            ;;
        -h|--help)
            show_help
            ;;
        *)
            log_error_start
            echo "Invalid action: $ACTION"
            echo "Valid actions: deploy, uninstall, status"
            log_error_end
            exit 1
            ;;
    esac
}

# ============================================================================
# CONFIGURATION FILE MANAGEMENT
# ============================================================================

load_config_file() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_debug "Config file not found: $CONFIG_FILE"
        return 0
    fi

    log_debug "Loading configuration from: $CONFIG_FILE"
    
    # Parse YAML configuration file (simple parsing for our use case)
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue
        
        # Trim whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        
        # Remove quotes from value if present
        value="${value%\"}"
        value="${value#\"}"
        
        case "$key" in
            server_ip)
                [[ -z "$SERVER_IP" ]] && SERVER_IP="$value"
                ;;
            server_port)
                [[ -z "$SERVER_PORT" || "$SERVER_PORT" == "8443" ]] && SERVER_PORT="$value"
                ;;
            local_proxy_port)
                [[ -z "$LOCAL_PROXY_PORT" || "$LOCAL_PROXY_PORT" == "8080" ]] && LOCAL_PROXY_PORT="$value"
                ;;
            wake_endpoint)
                [[ -z "$WAKE_ENDPOINT" ]] && WAKE_ENDPOINT="$value"
                ;;
            kill_endpoint)
                [[ -z "$KILL_ENDPOINT" ]] && KILL_ENDPOINT="$value"
                ;;
            cert_file)
                [[ -z "$CERT_PATH" ]] && CERT_PATH="$value"
                ;;
            key_file)
                [[ -z "$KEY_PATH" ]] && KEY_PATH="$value"
                ;;
            ca_cert_file)
                [[ -z "$CA_CERT_PATH" ]] && CA_CERT_PATH="$value"
                ;;
            log_level)
                [[ -z "$LOG_LEVEL" || "$LOG_LEVEL" == "info" ]] && LOG_LEVEL="$value"
                ;;
        esac
    done < "$CONFIG_FILE"
}

create_config_file() {
    log_substep "Creating Configuration File"
    
    mkdir -p "$INSTALL_PATH"
    
    # Server IP is not set during deployment
    # It will be obtained from wake function when agent starts
    # Or can be manually added to config later
    
    # Create or overwrite configuration file
    cat > "$CONFIG_FILE" << EOF
# Fluidity Agent Configuration
# Generated by deploy-agent.sh on $(date)

# Server configuration
# The server_ip will be obtained from the wake function at runtime
# Or can be set manually here
server_ip: ""
server_port: $SERVER_PORT
local_proxy_port: $LOCAL_PROXY_PORT

# Lambda endpoints (optional, for control plane integration)
wake_endpoint: "$WAKE_ENDPOINT"
kill_endpoint: "$KILL_ENDPOINT"

# TLS certificates
cert_file: "$CERT_PATH"
key_file: "$KEY_PATH"
ca_cert_file: "$CA_CERT_PATH"

# Logging
log_level: "$LOG_LEVEL"
EOF
    
    # Fix permissions on config directory
    if [[ -n "$SUDO_USER" ]]; then
        chown -R "$SUDO_USER:$SUDO_USER" "$INSTALL_PATH" 2>/dev/null || true
    fi
    
    log_success "Configuration file created: $CONFIG_FILE"
}

update_config_file() {
    log_substep "Updating Configuration File"
    
    mkdir -p "$INSTALL_PATH"
    
    # Update configuration with provided values
    local updated=false
    
    # Create a temporary file for updates
    local temp_file="$CONFIG_FILE.tmp"
    cp "$CONFIG_FILE" "$temp_file" 2>/dev/null || touch "$temp_file"
    
    # Update each value if provided
    if [[ -n "$SERVER_IP" ]]; then
        sed -i "s/^server_ip:.*/server_ip: \"$SERVER_IP\"/" "$temp_file" || echo "server_ip: \"$SERVER_IP\"" >> "$temp_file"
        updated=true
    fi
    
    if [[ -n "$SERVER_PORT" && "$SERVER_PORT" != "8443" ]]; then
        sed -i "s/^server_port:.*/server_port: $SERVER_PORT/" "$temp_file" || echo "server_port: $SERVER_PORT" >> "$temp_file"
        updated=true
    fi
    
    if [[ -n "$LOCAL_PROXY_PORT" && "$LOCAL_PROXY_PORT" != "8080" ]]; then
        sed -i "s/^local_proxy_port:.*/local_proxy_port: $LOCAL_PROXY_PORT/" "$temp_file" || echo "local_proxy_port: $LOCAL_PROXY_PORT" >> "$temp_file"
        updated=true
    fi
    
    if [[ -n "$WAKE_ENDPOINT" ]]; then
        sed -i "s|^wake_endpoint:.*|wake_endpoint: \"$WAKE_ENDPOINT\"|" "$temp_file" || echo "wake_endpoint: \"$WAKE_ENDPOINT\"" >> "$temp_file"
        updated=true
    fi
    
    if [[ -n "$KILL_ENDPOINT" ]]; then
        sed -i "s|^kill_endpoint:.*|kill_endpoint: \"$KILL_ENDPOINT\"|" "$temp_file" || echo "kill_endpoint: \"$KILL_ENDPOINT\"" >> "$temp_file"
        updated=true
    fi
    
    if [[ "$updated" == "true" ]]; then
        mv "$temp_file" "$CONFIG_FILE"
        log_success "Configuration file updated"
    else
        rm "$temp_file"
    fi
}

validate_config() {
    log_substep "Validating Configuration"
    
    # Server IP is optional - can be obtained from wake function or added manually later
    if [[ -z "$SERVER_IP" ]]; then
        log_warn "Server IP not configured"
        log_warn "The agent can obtain it by calling the wake function"
        log_warn "Or add it manually to: $CONFIG_FILE"
    else
        log_info "Server IP configured: $SERVER_IP"
    fi
    
    log_success "Configuration is valid"
}

# ============================================================================
# PREREQUISITE CHECKS
# ============================================================================

check_prerequisites() {
    log_substep "Checking Prerequisites"

    if ! command -v go &>/dev/null; then
        log_error_start
        echo "Go not found"
        echo "Agent build requires Go 1.21+"
        echo "Install from: https://golang.org/dl/"
        log_error_end
        
        if [[ "$SKIP_BUILD" != "true" ]]; then
            exit 1
        else
            log_info "Skipping build as requested"
        fi
    else
        GO_VERSION=$(go version | awk '{print $3}')
        log_info "Go version: $GO_VERSION"
    fi
}

# ============================================================================
# BUILD
# ============================================================================

build_agent() {
    log_section "Step 2: Build Agent"
    
    if [[ "$SKIP_BUILD" == "true" ]]; then
        log_info "Skipping build as requested"
        
        if [[ ! -f "$BUILD_DIR/$AGENT_BINARY" ]]; then
            log_error_start
            echo "Binary not found: $BUILD_DIR/$AGENT_BINARY"
            log_error_end
            exit 1
        fi
        
        log_success "Using existing binary"
        return
    fi
    
    log_substep "Building Agent Binary"
    
    if [[ ! -d "$CMD_DIR" ]]; then
        log_error_start
        echo "Agent directory not found: $CMD_DIR"
        log_error_end
        exit 1
    fi
    
    mkdir -p "$BUILD_DIR"
    local output_path="$BUILD_DIR/$AGENT_BINARY"
    
    log_info "Compiling: $AGENT_BINARY"
    
    (
        cd "$CMD_DIR"
        
        go build \
            -ldflags='-s -w' \
            -o "$output_path" \
            . || {
            log_error_start
            echo "Go build failed"
            log_error_end
            exit 1
        }
    )
    
    if [[ ! -f "$output_path" ]]; then
        log_error_start
        echo "Build output not found: $output_path"
        log_error_end
        exit 1
    fi
    
    local size
    size=$(du -h "$output_path" | cut -f1)
    log_success "Agent built successfully ($size)"
}

# ============================================================================
# INSTALLATION
# ============================================================================

install_agent() {
    log_section "Step 3: Install Agent"
    
    local binary_path="$BUILD_DIR/$AGENT_BINARY"
    
    if [[ ! -f "$binary_path" ]]; then
        log_error_start
        echo "Binary not found: $binary_path"
        log_error_end
        exit 1
    fi
    
    log_substep "Creating Installation Directory"
    
    # Check if we need sudo for Linux system directories
    SUDO=""
    if [[ "$OS_TYPE" == "linux" && "$INSTALL_PATH" == /opt/* || "$INSTALL_PATH" == /usr/local/* ]]; then
        if [[ ! -d "$INSTALL_PATH" ]] && [[ ! -w "$(dirname "$INSTALL_PATH")" ]]; then
            log_info "Elevated privileges required for installation to: $INSTALL_PATH"
            SUDO="sudo"
        fi
    fi
    
    if [[ ! -d "$INSTALL_PATH" ]]; then
        log_info "Creating installation directory: $INSTALL_PATH"
        $SUDO mkdir -p "$INSTALL_PATH" || {
            log_error_start
            echo "Failed to create directory: $INSTALL_PATH"
            echo "Try running with: sudo bash scripts/deploy-agent.sh deploy"
            log_error_end
            exit 1
        }
    else
        log_info "Installation directory already exists: $INSTALL_PATH"
    fi
    
    if pgrep -f "$AGENT_BINARY" &>/dev/null; then
        log_info "Stopping running agent instances..."
        killall "$AGENT_BINARY" 2>/dev/null || true
        sleep 2
    fi
    
    log_substep "Installing Agent Binary"
    log_info "Copying: $binary_path to $AGENT_EXE_PATH"
    $SUDO cp "$binary_path" "$AGENT_EXE_PATH" || {
        log_error_start
        echo "Failed to copy binary to: $AGENT_EXE_PATH"
        echo "Try running with: sudo bash scripts/deploy-agent.sh deploy"
        log_error_end
        exit 1
    }
    
    $SUDO chmod +x "$AGENT_EXE_PATH"
    
    log_substep "Fixing File Permissions"
    # Change ownership to current user so they can access the files
    local current_user
    current_user=$(whoami)
    if [[ "$current_user" != "root" ]]; then
        log_warn "Cannot change permissions - script not running as root"
    else
        chown -R "$SUDO_USER:$SUDO_USER" "$INSTALL_PATH" 2>/dev/null || {
            log_warn "Could not change ownership to $SUDO_USER - you may need to adjust permissions manually"
        }
        log_info "Permissions fixed for user: $SUDO_USER"
    fi
    
    if [[ ! -f "$AGENT_EXE_PATH" ]]; then
        log_error_start
        echo "Failed to install agent: $AGENT_EXE_PATH"
        log_error_end
        exit 1
    fi
    
    log_success "Agent binary installed"
    
    log_substep "Adding to PATH"
    
    if [[ ":$PATH:" == *":$INSTALL_PATH:"* ]]; then
        log_info "Installation path already in PATH"
    else
        log_info "Installation path: $INSTALL_PATH"
        log_info "To add to PATH, update your shell configuration:"
        log_info "  export PATH=\"\$PATH:$INSTALL_PATH\""
    fi
    
    log_success "Installation complete"
}

# ============================================================================
# CONFIGURATION
# ============================================================================

setup_configuration() {
    log_section "Step 4: Configure Agent"
 
    # Load existing config if available (for potential merging)
    if [[ -f "$CONFIG_FILE" ]]; then
        load_config_file
    fi

    # If a build-time development config exists and no installed config yet, copy it first
    local build_config="$BUILD_DIR/agent.yaml"
    if [[ ! -f "$CONFIG_FILE" && -f "$build_config" ]]; then
        log_info "Installing build config: $build_config -> $CONFIG_FILE"
        mkdir -p "$INSTALL_PATH"
        cp "$build_config" "$CONFIG_FILE"
        load_config_file
    fi

    # Always write a fresh config reflecting current CLI overrides + existing values
    mkdir -p "$INSTALL_PATH"
    cat > "$CONFIG_FILE" << EOF
# Fluidity Agent Configuration
# Generated by deploy-agent.sh on $(date)

server_ip: "${SERVER_IP}"
server_port: ${SERVER_PORT}
local_proxy_port: ${LOCAL_PROXY_PORT}

wake_endpoint: "${WAKE_ENDPOINT}"
kill_endpoint: "${KILL_ENDPOINT}"

cert_file: "${CERT_PATH}"
key_file: "${KEY_PATH}"
ca_cert_file: "${CA_CERT_PATH}"

log_level: "${LOG_LEVEL}"
EOF

    if [[ -n "$SUDO_USER" ]]; then
        chown "$SUDO_USER:$SUDO_USER" "$CONFIG_FILE" 2>/dev/null || true
    fi

    log_success "Configuration written: $CONFIG_FILE"
}

# ============================================================================
# VERIFICATION
# ============================================================================

verify_installation() {
    log_section "Step 5: Verify Installation"
    
    log_substep "Checking Agent Binary"
    
    if [[ ! -f "$AGENT_EXE_PATH" ]]; then
        log_error_start
        echo "Agent binary not found: $AGENT_EXE_PATH"
        log_error_end
        return 1
    fi
    
    log_success "Agent binary installed: $AGENT_EXE_PATH"
    
    log_substep "Checking Configuration"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_warn "Configuration file not found: $CONFIG_FILE"
        return 1
    fi
    
    log_success "Configuration file present: $CONFIG_FILE"
    
    log_substep "Agent Information"
    log_info "Installation path: $INSTALL_PATH"
    log_info "Configuration path: $CONFIG_FILE"
    if [[ "$IS_WSL" == "true" ]]; then
        log_info ""
        log_info "WSL Environment Details:"
        log_info "- Running in: Windows Subsystem for Linux (WSL)"
        log_info "- Agent accessible from Windows: \\\\wsl.localhost\\\\Ubuntu\\\\opt\\\\fluidity\\\\fluidity-agent"
        log_info "- Configuration in Windows: %APPDATA%\\fluidity (symlinked from /home/marcelr/.config/fluidity)"
    fi
    
    log_success "Installation verified"
    return 0
}

# ============================================================================
# UNINSTALL
# ============================================================================

uninstall_agent() {
    log_section "Uninstalling Agent"
    
    log_substep "Stopping Agent Processes"
    
    if pgrep -f "$AGENT_BINARY" &>/dev/null; then
        log_info "Stopping running processes..."
        killall "$AGENT_BINARY" 2>/dev/null || true
        sleep 2
        log_success "Agent processes stopped"
    else
        log_info "No running processes found"
    fi
    
    log_substep "Removing Installation Directory"
    
    if [[ -d "$INSTALL_PATH" ]]; then
        log_info "Removing: $INSTALL_PATH"
        rm -rf "$INSTALL_PATH" || {
            log_error_start
            echo "Failed to remove directory (try with sudo): $INSTALL_PATH"
            log_error_end
            return 1
        }
        log_success "Installation directory removed"
    else
        log_info "Installation directory not found"
    fi
    
    log_substep "Configuration Files"
    
    log_info "Configuration directory: $INSTALL_PATH"
    log_info "To remove configuration files, run:"
    log_info "  rm -rf $INSTALL_PATH"
    
    log_success "Agent uninstall complete"
}

# ============================================================================
# STATUS
# ============================================================================

show_status() {
    log_section "Agent Status"
    
    log_substep "Installation Status"
    
    if [[ -f "$AGENT_EXE_PATH" ]]; then
        local size
        size=$(du -h "$AGENT_EXE_PATH" | cut -f1)
        log_success "Agent installed: $AGENT_EXE_PATH ($size)"
    else
        log_warn "Agent not installed"
    fi
    
    log_substep "PATH Status"
    
    if command -v "$AGENT_BINARY" &>/dev/null; then
        log_success "Agent in PATH: $(command -v "$AGENT_BINARY")"
    else
        log_warn "Agent not in PATH"
    fi
    
    log_substep "Configuration Status"
    
    if [[ -f "$CONFIG_FILE" ]]; then
        log_success "Configuration found: $CONFIG_FILE"
        log_info "Configuration content:"
        sed 's/^/  /' "$CONFIG_FILE"
    else
        log_warn "Configuration not found: $CONFIG_FILE"
    fi
    
    log_substep "Process Status"
    
    if pgrep -f "$AGENT_BINARY" &>/dev/null; then
        local count
        count=$(pgrep -f "$AGENT_BINARY" | wc -l)
        log_success "Agent is running ($count process(es))"
    else
        log_warn "Agent is not running"
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    validate_action
    parse_arguments "$@"
    
    # Check for sudo/root access
    check_sudo
    
    log_section "Fluidity Agent Deployment"
    log_info "OS: $OS_TYPE"
    if [[ "$IS_WSL" == "true" ]]; then
        log_info "Environment: WSL (Windows Subsystem for Linux)"
    fi
    log_info "Install path: $INSTALL_PATH"
    
    case "$ACTION" in
        deploy)
            log_section "Step 1: Check Prerequisites"
            check_prerequisites
            
            build_agent
            install_agent
            setup_configuration
            
            if ! validate_config; then
                exit 1
            fi
            
            if ! verify_installation; then
                exit 1
            fi
            
            log_success "Deployment completed successfully"
            log_info ""
            log_info "Next steps:"
            log_info "1. Review configuration: $CONFIG_FILE"
            log_info "2. Run agent: $AGENT_EXE_PATH"
            if [[ "$IS_WSL" == "true" ]]; then
                log_info ""
                log_info "WSL Deployment Details:"
                log_info "- Agent binary location: $AGENT_EXE_PATH (WSL filesystem)"
                log_info "- Configuration location: $CONFIG_FILE (WSL home directory)"
                log_info "- Access from Windows: \\\\wsl.localhost\\\\Ubuntu\\\\opt\\\\fluidity"
                log_info "- Run agent in WSL: wsl /opt/fluidity/fluidity-agent"
            fi
            log_info ""
            ;;
        
        uninstall)
            read -p "Are you sure you want to uninstall the agent? (yes/no): " confirm
            if [[ "$confirm" == "yes" ]]; then
                uninstall_agent
                log_success "Uninstall complete"
            else
                log_warn "Uninstall cancelled"
            fi
            ;;
        
        status)
            show_status
            ;;
    esac
    
    echo ""
}

# Execute main
main "$@"
