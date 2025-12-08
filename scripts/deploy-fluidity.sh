#!/usr/bin/env bash

###############################################################################
# Fluidity Complete Deployment Script
# 
# Orchestrates deployment of both Fluidity server (to AWS) and agent (to local system).
# Automatically detects OS-specific defaults and passes server endpoints to agent.
#
# FUNCTION:
#   Coordinates end-to-end Fluidity deployment:
#   - Detects OS and sets appropriate defaults (install path, port)
#   - Deploys server and Lambda to AWS
#   - Collects endpoint information from CloudFormation outputs
#   - Deploys and configures agent with server details
#
# DEPLOYMENT FLOW:
#   1. Validate prerequisites and OS
#   2. Deploy server to AWS (CloudFormation + ECS + Lambda)
#   3. Collect server and Lambda endpoints from CloudFormation
#   4. Deploy agent to local system with collected endpoints
#   5. Verify complete deployment
#
# USAGE:
#   ./deploy-fluidity.sh [action] [options]
#
# ACTIONS:
#   deploy           Deploy both server and agent (default)
#   deploy-server    Deploy only server to AWS
#   deploy-agent     Deploy only agent to local system
#   delete           Delete AWS infrastructure only
#   status           Show deployment status
#
# OPTIONS:
#   --region <region>              AWS region (auto-detect from AWS config)
#   --vpc-id <vpc>                 VPC ID (auto-detect default VPC)
#   --public-subnets <subnets>     Comma-separated subnet IDs (auto-detect)
#   --allowed-cidr <cidr>          Allowed ingress CIDR (auto-detect your IP)
#   --local-proxy-port <port>      Agent listening port (default: 8080 on Windows, 8080 on Linux/macOS)
#   --cert-path <path>             Path to client certificate (optional)
#   --key-path <path>              Path to client key (optional)
#   --ca-cert-path <path>          Path to CA certificate (optional)
#   --install-path <path>          Custom agent installation path (optional)
#   --log-level <level>            Log level for server and agent (debug|info|warn|error)
#   --wake-endpoint <url>          Override wake function endpoint
#   --kill-endpoint <url>          Override kill function endpoint
#   --iam-role-arn <arn>           IAM role ARN for agent authentication
#   --access-key-id <id>           AWS access key ID for agent
#   --secret-access-key <key>      AWS secret access key for agent
#   --skip-build                   Skip building agent, use existing binary
#   --debug                        Enable debug logging
#   --force                        Delete and recreate resources (server only)
#   -h, --help                     Show this help message
#
# EXAMPLES:
#   ./deploy-fluidity.sh deploy
#   ./deploy-fluidity.sh deploy --local-proxy-port 8080
#   ./deploy-fluidity.sh deploy --log-level debug
#   ./deploy-fluidity.sh deploy-server --region us-west-2
#   ./deploy-fluidity.sh deploy-agent
#   ./deploy-fluidity.sh status
#   ./deploy-fluidity.sh delete
#
###############################################################################

set -euo pipefail

# ============================================================================
# CONFIGURATION & DEFAULTS
# ============================================================================

ACTION="${1:-deploy}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# AWS Configuration
AWS_REGION=""
VPC_ID=""
PUBLIC_SUBNETS=""
ALLOWED_CIDR=""

# Agent Configuration
SERVER_IP=""
SERVER_PORT="8443"  # Allow override though server binary listens 8443
LOCAL_PROXY_PORT=""
CERT_PATH=""
KEY_PATH=""
CA_CERT_PATH=""
INSTALL_PATH=""
LOG_LEVEL=""

# Feature Flags
DEBUG=false
FORCE=false
SKIP_BUILD=false

# Endpoints from server deployment
WAKE_ENDPOINT=""
KILL_ENDPOINT=""
QUERY_ENDPOINT=""
SERVER_REGION=""
SERVER_PORT="8443"
SERVER_IP_COMMAND=""

# Agent installation details
AGENT_INSTALL_PATH=""
AGENT_CONFIG_PATH=""

# Detect OS and set defaults
case "$(uname -s)" in
    MINGW64_NT*|MSYS_NT*|CYGWIN*)
        OS_TYPE="windows"
        DEFAULT_INSTALL_PATH="C:\\Program Files\\fluidity"
        DEFAULT_LOCAL_PROXY_PORT="8080"
        ;;
    Darwin)
        OS_TYPE="darwin"
        DEFAULT_INSTALL_PATH="/usr/local/opt/fluidity"
        DEFAULT_LOCAL_PROXY_PORT="8080"
        ;;
    Linux)
        OS_TYPE="linux"
        DEFAULT_INSTALL_PATH="/opt/fluidity"
        DEFAULT_LOCAL_PROXY_PORT="8080"
        ;;
    *)
        OS_TYPE="unknown"
        DEFAULT_INSTALL_PATH="/opt/fluidity"
        DEFAULT_LOCAL_PROXY_PORT="8080"
        ;;
esac

INSTALL_PATH="${INSTALL_PATH:-$DEFAULT_INSTALL_PATH}"
LOCAL_PROXY_PORT="${LOCAL_PROXY_PORT:-$DEFAULT_LOCAL_PROXY_PORT}"

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



check_aws_credentials() {
    # Check if action requires AWS credentials
    if [[ "$ACTION" == "deploy" || "$ACTION" == "deploy-server" || "$ACTION" == "delete" ]]; then
        # Test if AWS credentials are available
        if ! aws sts get-caller-identity &>/dev/null; then
            log_error_start
            echo "AWS credentials not found or not configured"
            echo ""
            echo "This can happen if:"
            echo "  1. AWS credentials are not configured"
            echo ""
            echo "Solutions:"
            echo "  Option 1: Configure AWS credentials first"
            echo "    aws configure"
            echo ""
            log_error_end
            exit 1
        fi
    fi
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
            --region)
                AWS_REGION="$2"
                shift 2
                ;;
            --vpc-id)
                VPC_ID="$2"
                shift 2
                ;;
            --public-subnets)
                PUBLIC_SUBNETS="$2"
                shift 2
                ;;
            --allowed-cidr)
                ALLOWED_CIDR="$2"
                shift 2
                ;;
            --local-proxy-port)
                LOCAL_PROXY_PORT="$2"
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
                shift 2
                ;;
            --log-level)
                LOG_LEVEL="$2"
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
            --query-endpoint)
                QUERY_ENDPOINT="$2"
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
            --force)
                FORCE=true
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
        deploy|deploy-server|deploy-agent|delete|status)
            ;;
        -h|--help)
            show_help
            ;;
        *)
            log_error_start
            echo "Invalid action: $ACTION"
            echo "Valid actions: deploy, deploy-server, deploy-agent, delete, status"
            log_error_end
            exit 1
            ;;
    esac
}

# ============================================================================
# DEPLOYMENT FUNCTIONS
# ============================================================================

deploy_server() {
    log_section "Deploying Server to AWS"
    
    local server_script="$SCRIPT_DIR/deploy-server.sh"
    
    if [[ ! -f "$server_script" ]]; then
        log_error_start
        echo "Server deployment script not found: $server_script"
        log_error_end
        exit 1
    fi
    
    local args=("deploy")
    [[ -n "$AWS_REGION" ]] && args+=(--region "$AWS_REGION")
    [[ -n "$VPC_ID" ]] && args+=(--vpc-id "$VPC_ID")
    [[ -n "$PUBLIC_SUBNETS" ]] && args+=(--public-subnets "$PUBLIC_SUBNETS")
    [[ -n "$ALLOWED_CIDR" ]] && args+=(--allowed-cidr "$ALLOWED_CIDR")
    [[ -n "$LOG_LEVEL" ]] && args+=(--log-level "$LOG_LEVEL")
    [[ "$FORCE" == "true" ]] && args+=(--force)
    [[ "$DEBUG" == "true" ]] && args+=(--debug)
    
    log_debug "Calling server deployment script with: ${args[*]}"
    
    # Run script and capture output for endpoint extraction
    local output
    local temp_output="/tmp/fluidity-deploy-server-$$.log"
    
    if bash "$server_script" "${args[@]}" 2>&1 | tee "$temp_output"; then
        output=$(cat "$temp_output")
        rm -f "$temp_output"
        
        log_success "Server deployment completed"
        
        # Extract endpoints from export_endpoints output
        local temp_exports="/tmp/fluidity-exports-$$.sh"
        echo "$output" | grep "^export " > "$temp_exports" 2>/dev/null || true
        
        if [[ -s "$temp_exports" ]]; then
            log_debug "Extracted endpoints from server deployment"
            
            # Extract each variable individually to avoid shell metacharacter issues
            SERVER_REGION=$(grep "^export SERVER_REGION=" "$temp_exports" | cut -d"'" -f2)
            WAKE_ENDPOINT=$(grep "^export WAKE_ENDPOINT=" "$temp_exports" | cut -d"'" -f2)
            KILL_ENDPOINT=$(grep "^export KILL_ENDPOINT=" "$temp_exports" | cut -d"'" -f2)
            QUERY_ENDPOINT=$(grep "^export QUERY_ENDPOINT=" "$temp_exports" | cut -d"'" -f2)
            SERVER_PORT=$(grep "^export SERVER_PORT=" "$temp_exports" | cut -d"'" -f2)
            AGENT_IAM_ROLE_ARN=$(grep "^export AGENT_IAM_ROLE_ARN=" "$temp_exports" | cut -d"'" -f2)
            AGENT_ACCESS_KEY_ID=$(grep "^export AGENT_ACCESS_KEY_ID=" "$temp_exports" | cut -d"'" -f2)
            AGENT_SECRET_ACCESS_KEY=$(grep "^export AGENT_SECRET_ACCESS_KEY=" "$temp_exports" | cut -d"'" -f2)

            # Set certificate paths to local certs directory (generated during server deployment)
            if [[ -f "./certs/client.crt" && -f "./certs/client.key" && -f "./certs/ca.crt" ]]; then
                CERT_PATH="./certs/client.crt"
                KEY_PATH="./certs/client.key"
                CA_CERT_PATH="./certs/ca.crt"
                log_debug "Certificate paths set to local certs directory"
            else
                log_warn "Certificate files not found in ./certs/ directory"
            fi

            # For SERVER_IP_COMMAND, extract everything between the quotes (handling the complex command)
            SERVER_IP_COMMAND=$(sed -n 's/^export SERVER_IP_COMMAND="\(.*\)"$/\1/p' "$temp_exports")

            log_debug "Extracted SERVER_REGION: $SERVER_REGION"
            log_debug "Extracted WAKE_ENDPOINT: $WAKE_ENDPOINT"
            log_debug "Extracted KILL_ENDPOINT: $KILL_ENDPOINT"
            log_debug "Extracted QUERY_ENDPOINT: $QUERY_ENDPOINT"
            log_debug "Extracted SERVER_PORT: $SERVER_PORT"
            log_debug "Extracted AGENT_IAM_ROLE_ARN: $AGENT_IAM_ROLE_ARN"
            log_debug "Extracted AGENT_ACCESS_KEY_ID: [REDACTED]"
            log_debug "Extracted AGENT_SECRET_ACCESS_KEY: [REDACTED]"
            log_debug "Extracted SERVER_IP_COMMAND length: ${#SERVER_IP_COMMAND}"
            
            rm -f "$temp_exports"
        fi
        
        return 0
    else
        output=$(cat "$temp_output")
        rm -f "$temp_output"
        
        log_error_start
        echo "Server deployment failed"
        echo ""
        echo "If the error mentions AWS credentials, ensure you ran this command with:"
        echo "  $0 deploy"
        echo ""
        echo "The -E flag preserves environment variables including AWS credentials."
        log_error_end
        return 1
    fi
}

deploy_agent() {
    log_section "Deploying Agent to Local System"
    
    local agent_script="$SCRIPT_DIR/deploy-agent.sh"
    
    if [[ ! -f "$agent_script" ]]; then
        log_error_start
        echo "Agent deployment script not found: $agent_script"
        log_error_end
        exit 1
    fi
    
    local args=("deploy")

    args+=(--server-port "$SERVER_PORT")
    args+=(--local-proxy-port "$LOCAL_PROXY_PORT")
    
    # Pass Lambda endpoints if available
    if [[ -n "$WAKE_ENDPOINT" ]]; then
        args+=(--wake-endpoint "$WAKE_ENDPOINT")
    fi
    
    if [[ -n "$KILL_ENDPOINT" ]]; then
        args+=(--kill-endpoint "$KILL_ENDPOINT")
    fi

    if [[ -n "$QUERY_ENDPOINT" ]]; then
        args+=(--query-endpoint "$QUERY_ENDPOINT")
    fi

    # Pass log level if provided
    if [[ -n "$LOG_LEVEL" ]]; then
        args+=(--log-level "$LOG_LEVEL")
    fi
    
    # Pass certificate paths if provided
    [[ -n "$CERT_PATH" ]] && args+=(--cert-path "$CERT_PATH")
    [[ -n "$KEY_PATH" ]] && args+=(--key-path "$KEY_PATH")
    [[ -n "$CA_CERT_PATH" ]] && args+=(--ca-cert-path "$CA_CERT_PATH")

    # Pass IAM credentials for Lambda authentication
    [[ -n "$AGENT_IAM_ROLE_ARN" ]] && args+=(--iam-role-arn "$AGENT_IAM_ROLE_ARN")
    [[ -n "$AGENT_ACCESS_KEY_ID" ]] && args+=(--access-key-id "$AGENT_ACCESS_KEY_ID")
    [[ -n "$AGENT_SECRET_ACCESS_KEY" ]] && args+=(--secret-access-key "$AGENT_SECRET_ACCESS_KEY")

    # Pass installation path if specified
    [[ -n "$INSTALL_PATH" && "$INSTALL_PATH" != "$DEFAULT_INSTALL_PATH" ]] && args+=(--install-path "$INSTALL_PATH")
    
    # Pass build/debug flags
    [[ "$SKIP_BUILD" == "true" ]] && args+=(--skip-build)
    [[ "$DEBUG" == "true" ]] && args+=(--debug)
    
    log_debug "Calling agent deployment script with: ${args[*]}"
    
    # Run script and capture output
    local agent_output
    local temp_agent_output="/tmp/fluidity-deploy-agent-$$.log"
    
    if bash "$agent_script" "${args[@]}" 2>&1 | tee "$temp_agent_output"; then
        agent_output=$(cat "$temp_agent_output")
        rm -f "$temp_agent_output"
        
        # Extract agent installation details from output
        AGENT_INSTALL_PATH=$(echo "$agent_output" | awk -F': ' '/Agent binary installed:/{print $2; exit}' | sed -E 's/\r$//')
        AGENT_CONFIG_PATH=$(echo "$agent_output" | awk -F': ' '/Configuration file (created|written):/{print $2; exit}' | sed -E 's/\r$//')
        
        # Fallback to using INSTALL_PATH if extraction fails
        if [[ -z "$AGENT_INSTALL_PATH" ]]; then
            AGENT_INSTALL_PATH="$INSTALL_PATH"
        fi
        
        log_success "Agent deployment completed"
        return 0
    else
        agent_output=$(cat "$temp_agent_output")
        rm -f "$temp_agent_output"
        
        log_error_start
        echo "Agent deployment failed"
        log_error_end
        return 1
    fi
}

delete_server() {
    log_section "Deleting AWS Infrastructure"
    
    local server_script="$SCRIPT_DIR/deploy-server.sh"
    
    if [[ ! -f "$server_script" ]]; then
        log_error_start
        echo "Server deployment script not found: $server_script"
        log_error_end
        exit 1
    fi
    
    read -p "Are you sure you want to delete the AWS infrastructure? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_warn "Deletion cancelled"
        return 0
    fi
    
    local args=("delete")
    [[ -n "$AWS_REGION" ]] && args+=(--region "$AWS_REGION")
    [[ "$DEBUG" == "true" ]] && args+=(--debug)
    
    log_debug "Calling server deletion with: ${args[*]}"
    
    # Run script and display output
    if bash "$server_script" "${args[@]}"; then
        log_success "Infrastructure deletion completed"
        return 0
    else
        log_error_start
        echo "Infrastructure deletion failed"
        log_error_end
        return 1
    fi
}

show_status() {
    log_section "Fluidity Deployment Status"
    
    log_substep "Server Status (AWS)"
    
    local server_script="$SCRIPT_DIR/deploy-server.sh"
    
    if [[ -f "$server_script" ]]; then
        local args=("status")
        [[ -n "$AWS_REGION" ]] && args+=(--region "$AWS_REGION")
        [[ "$DEBUG" == "true" ]] && args+=(--debug)
        
        bash "$server_script" "${args[@]}" || true
    else
        log_info "Server deployment script not found"
    fi
    
    log_substep "Agent Status"
    
    local agent_script="$SCRIPT_DIR/deploy-agent.sh"
    
    if [[ -f "$agent_script" ]]; then
        bash "$agent_script" status || true
    else
        log_info "Agent deployment script not found"
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    validate_action
    parse_arguments "$@"

    # Check AWS credentials availability
    check_aws_credentials
    
    log_header "Fluidity Complete Deployment"
    if [[ -n "$LOG_LEVEL" ]]; then
        log_info "Debug logging enabled for all components: log_level=$LOG_LEVEL"
    fi
    log_info "Operating System: $OS_TYPE"
    log_info "Default install path: $DEFAULT_INSTALL_PATH"
    log_info "Default proxy port: $DEFAULT_LOCAL_PROXY_PORT"
    log_debug "Deployment action: $ACTION"
    
    case "$ACTION" in
        deploy)
            log_minor "Starting Full Deployment (Server + Agent)"
            if ! deploy_server; then
                exit 1
            fi
            
            log_minor "Server deployment completed, now deploying agent"
            # Deploy agent with collected endpoints (IP can be provided manually or obtained from wake function later)
            deploy_agent
            
            log_success "Complete Fluidity deployment finished successfully"
            log_info ""
            log_minor "Deployment Summary"
            
            log_substep "AWS Server Deployment"
            log_info "Region: $SERVER_REGION"
            log_info "Wake Lambda: $WAKE_ENDPOINT"
            log_info "Kill Lambda: $KILL_ENDPOINT"
            log_info "Query Lambda: $QUERY_ENDPOINT"
            log_info "Server Port: $SERVER_PORT"
            log_info "Server IP: (Agent obtains server IP from lifecycle wake/query at runtime)"
            
            log_substep "Local Agent Deployment"
            log_info "Installation Path: $AGENT_INSTALL_PATH"
            log_info "Configuration File: $AGENT_CONFIG_PATH"
            log_info "Proxy Port: $LOCAL_PROXY_PORT"
            
            log_substep "Next Steps"
            log_info "1. Update agent configuration with server IP (if not auto-detected):"
            log_info "   Edit: $AGENT_CONFIG_PATH"
            log_info "   Set server_ip to the Fargate task public IP"
            log_info ""
            log_info "2. Start the server (Fargate task):"
            log_info "   aws ecs update-service --cluster fluidity --service fluidity-server --desired-count 1 --region $SERVER_REGION"
            log_info ""
            log_info "3. Start the agent:"
            if [[ "$OS_TYPE" == "windows" ]]; then
                log_info "   $AGENT_INSTALL_PATH\\fluidity-agent.exe"
            else
                log_info "   $AGENT_INSTALL_PATH/fluidity-agent"
            fi
            log_info ""
            log_info "4. Test the connection:"
            log_info "   curl -x http://127.0.0.1:$LOCAL_PROXY_PORT http://example.com"
            log_info ""
            ;;
        
        deploy-server)
            log_minor "Starting Server Deployment (AWS ECS + Lambda)"
            if ! deploy_server; then
                exit 1
            fi
            
            log_success "Server deployment finished successfully"
            log_info ""
            log_info "To deploy agent with server endpoints, run:"
            log_info "  ./deploy-fluidity.sh deploy-agent"
            log_info ""
            ;;
        
        deploy-agent)
            log_minor "Starting Agent Deployment (Local System)"
            if [[ -z "$SERVER_IP" ]]; then
                log_warn "Server IP not provided, agent configuration will require manual input or will be obtained from wake function"
            fi
            
            if ! deploy_agent; then
                exit 1
            fi
            
            log_success "Agent deployment finished successfully"
            log_info ""
            log_section "Agent Deployment Summary"
            log_info "Installation Path: $AGENT_INSTALL_PATH"
            log_info "Configuration File: $AGENT_CONFIG_PATH"
            log_info "Proxy Port: $LOCAL_PROXY_PORT"
            log_info ""
            ;;
        
        delete)
            if ! delete_server; then
                exit 1
            fi
            
            log_success "Deletion complete"
            log_info ""
            log_info "To uninstall the agent, run:"
            log_info "  ./deploy-agent.sh uninstall"
            log_info ""
            ;;
        
        status)
            show_status
            ;;
    esac
    
    echo ""
}

# Execute main
main "$@"
