#!/usr/bin/env bash

###############################################################################
# Fluidity Agent Deployment Script
#
# Builds the Fluidity agent and deploys it to the system, making it available
# as a command-line executable via 'fluidity' command. Manages agent configuration
# with support for command-line overrides.
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
#   - Creates 'fluidity' symlink for easy command-line access
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
#   --query-endpoint <url>     Query Lambda Function URL
#   --kill-endpoint <url>      Kill Lambda Function URL
#   --cert-path <path>         Path to client certificate
#   --key-path <path>          Path to client private key
#   --ca-cert-path <path>      Path to CA certificate
#   --iam-role-arn <arn>       IAM role ARN for authentication
#   --access-key-id <id>       AWS access key ID
#   --secret-access-key <key>  AWS secret access key
#   --install-path <path>      Custom installation path (optional)
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
# After deployment, run the agent with:
#   fluidity --server-ip 192.168.1.100
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
QUERY_ENDPOINT=""
KILL_ENDPOINT=""
CERT_PATH=""
KEY_PATH=""
CA_CERT_PATH=""
LOG_LEVEL="info"
# IAM Configuration
AGENT_IAM_ROLE_ARN=""
AGENT_ACCESS_KEY_ID=""
AGENT_SECRET_ACCESS_KEY=""
REGION=""
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
        if [[ -n "${USERPROFILE:-}" ]]; then
            DEFAULT_INSTALL_PATH="$USERPROFILE\\apps\\fluidity"
        else
            DEFAULT_INSTALL_PATH="$HOME\\apps\\fluidity"
        fi
        AGENT_BINARY="fluidity-agent.exe"
        ;;
    Darwin)
        OS_TYPE="darwin"
        DEFAULT_INSTALL_PATH="$HOME/apps/fluidity"
        AGENT_BINARY="fluidity-agent"
        ;;
    Linux)
        if [[ "$IS_WSL" == "true" ]]; then
            # Running in WSL - use Windows user path
            OS_TYPE="windows-wsl"
            if [[ -n "${USERPROFILE:-}" ]]; then
                DEFAULT_INSTALL_PATH="$USERPROFILE\\apps\\fluidity"
            else
                DEFAULT_INSTALL_PATH="$HOME/apps/fluidity"
            fi
            AGENT_BINARY="fluidity-agent.exe"
        else
            # Native Linux
            OS_TYPE="linux"
            DEFAULT_INSTALL_PATH="$HOME/apps/fluidity"
            AGENT_BINARY="fluidity-agent"
        fi
        ;;
    *)
        OS_TYPE="linux"
        DEFAULT_INSTALL_PATH="$HOME/apps/fluidity"
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

log_success() {
    echo "✓ $*"
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



detect_region() {
    if [[ -z "$REGION" ]]; then
        if REGION=$(aws configure get region 2>/dev/null); then
            [[ -n "$REGION" ]] && log_info "Region auto-detected: $REGION" || {
                log_warn "Region could not be auto-detected from AWS config"
                REGION=""
            }
        else
            log_warn "AWS CLI not available or not configured"
            REGION=""
        fi
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
             --query-endpoint)
                 QUERY_ENDPOINT="$2"
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
            --iam-role-arn)
                AGENT_IAM_ROLE_ARN="$2"
                shift 2
                ;;
            --access-key-id)
                AGENT_ACCESS_KEY_ID="$2"
                shift 2
                ;;
            --secret-access-key)
                AGENT_SECRET_ACCESS_KEY="$2"
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
             query_endpoint)
                 [[ -z "$QUERY_ENDPOINT" ]] && QUERY_ENDPOINT="$value"
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
query_endpoint: "$QUERY_ENDPOINT"
kill_endpoint: "$KILL_ENDPOINT"

# IAM Configuration (for Phase 3 IAM authentication)
# Note: AWS credentials are resolved via AWS SDK default credential chain
# from ~/.aws/credentials, environment variables, or IAM roles
iam_role_arn: "$AGENT_IAM_ROLE_ARN"
aws_region: "$REGION"

# TLS certificates
cert_file: "$CERT_PATH"
key_file: "$KEY_PATH"
ca_cert_file: "$CA_CERT_PATH"

# Logging
log_level: "$LOG_LEVEL"
EOF
    
    # Files are owned by current user in user space installation
    
    log_success "Configuration file created: $CONFIG_FILE"
}

# Setup AWS credentials for IAM authentication
setup_aws_credentials() {
    log_substep "Setting up AWS Credentials"

    # Setup credentials if access keys are provided OR IAM role ARN is provided
    if [[ -z "$AGENT_ACCESS_KEY_ID" && -z "$AGENT_SECRET_ACCESS_KEY" && -z "$AGENT_IAM_ROLE_ARN" ]]; then
        log_info "IAM credentials not configured, skipping AWS credentials setup"
        log_info "AWS SDK will use default credential chain (environment variables, IAM roles, or ~/.aws/credentials)"
        return 0
    fi

    # Check if we have the access keys
    if [[ -z "$AGENT_ACCESS_KEY_ID" || -z "$AGENT_SECRET_ACCESS_KEY" ]]; then
        log_warn "IAM access keys not fully provided, AWS SDK will use default credential chain"
        log_warn "Ensure credentials are available via ~/.aws/credentials, environment variables, or IAM roles"
        return 0
    fi

    # Create AWS credentials directory if it doesn't exist
    AWS_DIR="$HOME/.aws"
    CREDENTIALS_FILE="$AWS_DIR/credentials"

    if [[ ! -d "$AWS_DIR" ]]; then
        mkdir -p "$AWS_DIR"
        chmod 700 "$AWS_DIR"
        log_info "Created AWS credentials directory: $AWS_DIR"
    fi

    # Check if fluidity profile already exists
    if grep -q "\[fluidity\]" "$CREDENTIALS_FILE" 2>/dev/null; then
        log_info "Fluidity profile already exists in AWS credentials"
        # Remove existing fluidity profile and recreate it
        sed -i.bak '/^\[fluidity\]$/,/^$/d' "$CREDENTIALS_FILE"
        # Remove any trailing empty lines that might have been left
        sed -i '' '/^$/N;/^\n$/d' "$CREDENTIALS_FILE"
    fi

    # Add new profile (or recreate existing one)
    {
        echo ""
        echo "[fluidity]"
        echo "aws_access_key_id = $AGENT_ACCESS_KEY_ID"
        echo "aws_secret_access_key = $AGENT_SECRET_ACCESS_KEY"
        echo "region = $REGION"
    } >> "$CREDENTIALS_FILE"
    log_info "Configured fluidity profile in AWS credentials"

    # Set proper permissions
    chmod 600 "$CREDENTIALS_FILE"

    # Set AWS_PROFILE environment variable for the agent
    if [[ "$OS_TYPE" == "windows" ]]; then
        # For Windows, we'll need to set this in the startup script or environment
        log_info "Windows detected - AWS_PROFILE=fluidity needs to be set in environment"
    else
        # For Linux/macOS, add to shell profile so it's set automatically
        SHELL_PROFILE=""
        if [[ -f "$HOME/.zshrc" ]]; then
            SHELL_PROFILE="$HOME/.zshrc"
        elif [[ -f "$HOME/.bashrc" ]]; then
            SHELL_PROFILE="$HOME/.bashrc"
        elif [[ -f "$HOME/.bash_profile" ]]; then
            SHELL_PROFILE="$HOME/.bash_profile"
        fi
        
        if [[ -n "$SHELL_PROFILE" ]]; then
            # Check if AWS_PROFILE is already set in the profile
            if ! grep -q "export AWS_PROFILE=fluidity" "$SHELL_PROFILE" 2>/dev/null; then
                echo "export AWS_PROFILE=fluidity" >> "$SHELL_PROFILE"
                log_info "Added AWS_PROFILE=fluidity to $SHELL_PROFILE"
            fi
        fi
        
        log_info "AWS credentials configured for profile: fluidity"
        log_info "Agent will automatically use AWS_PROFILE=fluidity"
    fi

    log_success "AWS credentials configured securely"
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

     if [[ -n "$QUERY_ENDPOINT" ]]; then
         sed -i "s|^query_endpoint:.*|query_endpoint: \"$QUERY_ENDPOINT\"|" "$temp_file" || echo "query_endpoint: \"$QUERY_ENDPOINT\"" >> "$temp_file"
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
    log_minor "Step 2: Build Agent"
    
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

# Add installation path to Unix shell configuration
add_to_shell_path_unix() {
    local install_path="$1"
    local shell_rc_files=("$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile")

    for rc_file in "${shell_rc_files[@]}"; do
        if [[ -f "$rc_file" ]]; then
            # Check if path is already in the file (more robust check)
            if ! grep -q "^export PATH.*:$install_path[:\"]*$" "$rc_file" 2>/dev/null && \
               ! grep -q "^export PATH.*:$install_path$" "$rc_file" 2>/dev/null && \
               ! grep -q "PATH=.*:$install_path[:\"]*$" "$rc_file" 2>/dev/null; then
                echo "" >> "$rc_file"
                echo "# Added by Fluidity agent installer" >> "$rc_file"
                echo "export PATH=\"\$PATH:$install_path\"" >> "$rc_file"
                log_info "Added to $rc_file"
            else
                log_info "Already configured in $rc_file"
            fi
        fi
    done

    # Also try to add to /etc/bash.bashrc if it exists and writable
    if [[ -w "/etc/bash.bashrc" ]] && \
       ! grep -q "^export PATH.*:$install_path[:\"]*$" "/etc/bash.bashrc" 2>/dev/null && \
       ! grep -q "^export PATH.*:$install_path$" "/etc/bash.bashrc" 2>/dev/null && \
       ! grep -q "PATH=.*:$install_path[:\"]*$" "/etc/bash.bashrc" 2>/dev/null; then
        echo "" >> "/etc/bash.bashrc"
        echo "# Added by Fluidity agent installer" >> "/etc/bash.bashrc"
        echo "export PATH=\"\$PATH:$install_path\"" >> "/etc/bash.bashrc"
        log_info "Added to /etc/bash.bashrc"
    fi
}

# Add installation path to Windows PATH environment variable
add_to_windows_path() {
    local install_path="$1"

    if [[ "$OS_TYPE" == "windows-wsl" ]]; then
        # Running in WSL - update both Windows PATH and WSL shell config
        log_info "Updating Windows PATH via PowerShell..."

        # Convert WSL path to Windows path if needed
        local windows_path
        if [[ "$install_path" == /home/* ]]; then
            # This is a WSL path that maps to Windows
            windows_path=$(wslpath -w "$install_path" 2>/dev/null || echo "$install_path")
        else
            windows_path="$install_path"
        fi

        # Use PowerShell to add to user PATH
        powershell.exe -Command "
            \$currentPath = [Environment]::GetEnvironmentVariable('Path', 'User');
            if (\$currentPath -notlike '*${windows_path}*') {
                \$newPath = \$currentPath + ';${windows_path}';
                [Environment]::SetEnvironmentVariable('Path', \$newPath, 'User');
                Write-Host 'Added ${windows_path} to Windows user PATH';
            } else {
                Write-Host 'Path already in Windows user PATH';
            }
        " 2>/dev/null

        if [[ $? -eq 0 ]]; then
            log_success "Windows PATH updated successfully"
        else
            log_warn "Failed to update Windows PATH - you may need to add manually"
            log_info "Manual addition: $windows_path"
        fi

        # Also add to WSL shell configuration for immediate availability
        log_info "Adding to WSL shell configuration..."
        add_to_shell_path_unix "$install_path"

    else
        # Native Windows - use setx command
        log_info "Updating Windows PATH..."

        # Get current user PATH
        local current_path
        current_path=$(powershell.exe -Command "[Environment]::GetEnvironmentVariable('Path', 'User')" 2>/dev/null | tr -d '\r')

        if [[ "$current_path" != *"$install_path"* ]]; then
            local new_path="$current_path;$install_path"
            # Use setx to update PATH (persistent)
            setx PATH "$new_path" >/dev/null 2>&1
            if [[ $? -eq 0 ]]; then
                log_success "Windows PATH updated successfully"
            else
                log_warn "Failed to update PATH with setx - you may need to add manually"
                log_info "Manual addition: $install_path"
            fi
        else
            log_info "Path already in Windows PATH"
        fi
    fi
}

install_agent() {
    log_minor "Step 3: Install Agent"
    
    local binary_path="$BUILD_DIR/$AGENT_BINARY"
    
    if [[ ! -f "$binary_path" ]]; then
        log_error_start
        echo "Binary not found: $binary_path"
        log_error_end
        exit 1
    fi
    
    log_substep "Creating Installation Directory"

    # Create apps/fluidity directory structure in user space
    if [[ ! -d "$INSTALL_PATH" ]]; then
        log_info "Creating installation directory: $INSTALL_PATH"
        mkdir -p "$INSTALL_PATH" || {
            log_error_start
            echo "Failed to create directory: $INSTALL_PATH"
            echo "Check permissions for your home directory"
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
    cp "$binary_path" "$AGENT_EXE_PATH" || {
        log_error_start
        echo "Failed to copy binary to: $AGENT_EXE_PATH"
        echo "Check permissions for the installation directory"
        log_error_end
        exit 1
    }

    chmod +x "$AGENT_EXE_PATH"
    
    log_substep "Setting File Permissions"
    # Files are already owned by current user since we're installing to user space
    log_info "File permissions set for current user"
    
    if [[ ! -f "$AGENT_EXE_PATH" ]]; then
        log_error_start
        echo "Failed to install agent: $AGENT_EXE_PATH"
        log_error_end
        exit 1
    fi
    
    log_success "Agent binary installed"

    log_substep "Creating Symlink"

    # Create symlink for easier access (fluidity -> fluidity-agent.exe)
    local symlink_path="$INSTALL_PATH/fluidity"
    if [[ -L "$symlink_path" ]]; then
        log_info "Symlink already exists: $symlink_path"
    else
        log_info "Creating symlink: fluidity -> $AGENT_BINARY"
        ln -sf "$AGENT_BINARY" "$symlink_path" || {
            log_warn "Failed to create symlink, continuing without it"
        }
        if [[ -L "$symlink_path" ]]; then
            log_success "Symlink created: fluidity -> $AGENT_BINARY"
        fi
    fi

    log_substep "Adding to PATH"

    # More robust PATH duplication check
    local path_already_in_path=false
    IFS=':' read -ra PATH_ARRAY <<< "$PATH"
    for path_entry in "${PATH_ARRAY[@]}"; do
        if [[ "$path_entry" == "$INSTALL_PATH" ]]; then
            path_already_in_path=true
            break
        fi
    done

    if [[ "$path_already_in_path" == "true" ]]; then
        log_info "Installation path already in PATH"
    else
        log_info "Adding installation path to PATH: $INSTALL_PATH"

        case "$OS_TYPE" in
            "linux"|"darwin")
                # Add to shell configuration files for Unix-like systems
                add_to_shell_path_unix "$INSTALL_PATH"
                ;;
            "windows"|"windows-wsl")
                # Add to Windows PATH environment variable
                add_to_windows_path "$INSTALL_PATH"
                ;;
        esac

        # Update current session PATH
        export PATH="$PATH:$INSTALL_PATH"
        log_info "PATH updated for current session"
    fi

    log_success "Installation complete"
}

# ============================================================================
# CERTIFICATE MANAGEMENT
# ============================================================================

copy_certificates_to_installation() {
    log_substep "Copying Certificates to Installation Directory"

    # Check if certificate paths are provided
    if [[ -z "$CERT_PATH" || -z "$KEY_PATH" || -z "$CA_CERT_PATH" ]]; then
        log_info "Certificate paths not provided, skipping certificate copy"
        return 0
    fi

    # Check if certificate files exist
    if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" || ! -f "$CA_CERT_PATH" ]]; then
        log_warn "Certificate files not found, skipping certificate copy"
        log_warn "Cert: $CERT_PATH"
        log_warn "Key: $KEY_PATH"
        log_warn "CA: $CA_CERT_PATH"
        return 0
    fi

    # Create certs subdirectory in installation directory
    local certs_dir="$INSTALL_PATH/certs"
    mkdir -p "$certs_dir"

    # Copy certificates to installation directory
    log_info "Copying certificates to: $certs_dir"
    cp "$CERT_PATH" "$certs_dir/client.crt" || {
        log_error_start
        echo "Failed to copy client certificate"
        log_error_end
        return 1
    }
    cp "$KEY_PATH" "$certs_dir/client.key" || {
        log_error_start
        echo "Failed to copy client key"
        log_error_end
        return 1
    }
    cp "$CA_CERT_PATH" "$certs_dir/ca.crt" || {
        log_error_start
        echo "Failed to copy CA certificate"
        log_error_end
        return 1
    }

    # Set proper permissions (owner read/write only for private key)
    chmod 644 "$certs_dir/client.crt"
    chmod 644 "$certs_dir/ca.crt"
    chmod 600 "$certs_dir/client.key"

    # Update certificate paths to point to copied files
    CERT_PATH="$certs_dir/client.crt"
    KEY_PATH="$certs_dir/client.key"
    CA_CERT_PATH="$certs_dir/ca.crt"

    log_success "Certificates copied to installation directory"
}

# ============================================================================
# CONFIGURATION
# ============================================================================

setup_configuration() {
    log_minor "Step 4: Configure Agent"

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

    # Copy certificates to installation directory if provided
    copy_certificates_to_installation

    # Always write a fresh config reflecting current CLI overrides + existing values
    mkdir -p "$INSTALL_PATH"
    cat > "$CONFIG_FILE" << EOF
# Fluidity Agent Configuration
# Generated by deploy-agent.sh on $(date)

server_ip: "${SERVER_IP}"
server_port: ${SERVER_PORT}
local_proxy_port: ${LOCAL_PROXY_PORT}

wake_endpoint: "${WAKE_ENDPOINT}"
query_endpoint: "${QUERY_ENDPOINT}"
kill_endpoint: "${KILL_ENDPOINT}"

# IAM Configuration (for Phase 3 IAM authentication)
# Note: AWS credentials are resolved via AWS SDK default credential chain
# from ~/.aws/credentials, environment variables, or IAM roles
iam_role_arn: "${AGENT_IAM_ROLE_ARN}"
aws_region: "${REGION}"

cert_file: "${CERT_PATH}"
key_file: "${KEY_PATH}"
ca_cert_file: "${CA_CERT_PATH}"

log_level: "${LOG_LEVEL}"
EOF

    # File is owned by current user in user space installation

    log_success "Configuration written: $CONFIG_FILE"
}

# ============================================================================
# VERIFICATION
# ============================================================================

verify_installation() {
    log_minor "Step 5: Verify Installation"
    
    log_substep "Checking Agent Binary"
    
    if [[ ! -f "$AGENT_EXE_PATH" ]]; then
        log_error_start
        echo "Agent binary not found: $AGENT_EXE_PATH"
        log_error_end
        return 1
    fi
    
    log_success "Agent binary installed: $AGENT_EXE_PATH"
    
    log_substep "Checking Symlink"

    local symlink_path="$INSTALL_PATH/fluidity"
    if [[ -L "$symlink_path" ]]; then
        log_success "Symlink available: fluidity -> $AGENT_BINARY"
    else
        log_warn "Symlink not found: $symlink_path"
    fi

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
    log_minor "Uninstalling Agent"
    
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
            echo "Failed to remove directory: $INSTALL_PATH"
            echo "Check file permissions and ensure no processes are using the files"
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
    log_minor "Agent Status"
    
    log_substep "Installation Status"

    if [[ -f "$AGENT_EXE_PATH" ]]; then
        local size
        size=$(du -h "$AGENT_EXE_PATH" | cut -f1)
        log_success "Agent installed: $AGENT_EXE_PATH ($size)"
    else
        log_warn "Agent not installed"
    fi

    local symlink_path="$INSTALL_PATH/fluidity"
    if [[ -L "$symlink_path" ]]; then
        log_success "Symlink available: fluidity -> $AGENT_BINARY"
    else
        log_warn "Symlink not available"
    fi

    log_substep "PATH Status"

    if command -v "$AGENT_BINARY" &>/dev/null; then
        log_success "Agent in PATH: $(command -v "$AGENT_BINARY")"
    elif command -v fluidity &>/dev/null; then
        log_success "Agent available via symlink: $(command -v fluidity)"
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
    
    # Validate installation requirements
    detect_region
    
    log_header "Fluidity Agent Deployment"
    log_info "OS: $OS_TYPE"
    if [[ "$IS_WSL" == "true" ]]; then
        log_info "Environment: WSL (Windows Subsystem for Linux)"
    fi
    log_info "Install path: $INSTALL_PATH"
    
    case "$ACTION" in
        deploy)
            log_minor "Step 1: Check Prerequisites"
            check_prerequisites
            
            build_agent
            install_agent
            setup_configuration
            setup_aws_credentials

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
            if grep -q "^\[fluidity\]" ~/.aws/credentials 2>/dev/null; then
                log_info "2. (Optional) Reload shell: source $SHELL"
                log_info "3. Run agent: fluidity"
            else
                log_info "2. Run agent: fluidity (or $AGENT_EXE_PATH)"
            fi
            if [[ "$IS_WSL" == "true" ]]; then
                log_info ""
                log_info "WSL Deployment Details:"
                log_info "- Agent binary location: $AGENT_EXE_PATH (WSL filesystem)"
                log_info "- Configuration location: $CONFIG_FILE (WSL home directory)"
                log_info "- Access from Windows: \\\\wsl.localhost\\\\Ubuntu\\\\opt\\\\fluidity"
                if grep -q "^\[fluidity\]" ~/.aws/credentials 2>/dev/null; then
                    log_info "- Run agent in WSL: wsl fluidity"
                else
                    log_info "- Run agent in WSL: wsl /opt/fluidity/fluidity-agent"
                fi
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
