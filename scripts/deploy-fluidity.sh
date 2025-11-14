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
#   --server-ip <ip>               Server IP (for agent, defaults to Fargate task public IP)
#   --local-proxy-port <port>      Agent listening port (default: 8080 on Windows, 8080 on Linux/macOS)
#   --cert-path <path>             Path to client certificate (optional)
#   --key-path <path>              Path to client key (optional)
#   --ca-cert-path <path>          Path to CA certificate (optional)
#   --install-path <path>          Custom agent installation path (optional)
#   --skip-build                   Skip building agent, use existing binary
#   --debug                        Enable debug logging
#   --force                        Delete and recreate resources (server only)
#   -h, --help                     Show this help message
#
# EXAMPLES:
#   ./deploy-fluidity.sh deploy
#   ./deploy-fluidity.sh deploy --local-proxy-port 8080
#   ./deploy-fluidity.sh deploy-server --region us-west-2
#   ./deploy-fluidity.sh deploy-agent --server-ip 192.168.1.100
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
LOCAL_PROXY_PORT=""
CERT_PATH=""
KEY_PATH=""
CA_CERT_PATH=""
INSTALL_PATH=""

# Feature Flags
DEBUG=false
FORCE=false
SKIP_BUILD=false

# Endpoints from server deployment
WAKE_ENDPOINT=""
KILL_ENDPOINT=""
SERVER_REGION=""
SERVER_PORT="8443"

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
    echo -e "${PALE_YELLOW}==========================================${RESET}"
}

log_substep() {
    echo ""
    echo ""
    echo -e "${PALE_GREEN}$*${RESET}"
    echo -e "${PALE_GREEN}-------------------------------------${RESET}"
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
            --server-ip)
                SERVER_IP="$2"
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
        local endpoints
        endpoints=$(echo "$output" | grep "export " | grep -E "ENDPOINT|REGION|PORT" || true)
        
        if [[ -n "$endpoints" ]]; then
            log_debug "Extracted endpoints:"
            log_debug "$endpoints"
            
            # Source the endpoints
            eval "$endpoints"
        fi
        
        return 0
    else
        output=$(cat "$temp_output")
        rm -f "$temp_output"
        
        log_error_start
        echo "Server deployment failed"
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
    
    # Pass server configuration
    if [[ -n "$SERVER_IP" ]]; then
        args+=(--server-ip "$SERVER_IP")
    fi
    
    args+=(--server-port "$SERVER_PORT")
    args+=(--local-proxy-port "$LOCAL_PROXY_PORT")
    
    # Pass Lambda endpoints if available
    if [[ -n "$WAKE_ENDPOINT" ]]; then
        args+=(--wake-endpoint "$WAKE_ENDPOINT")
    fi
    
    if [[ -n "$KILL_ENDPOINT" ]]; then
        args+=(--kill-endpoint "$KILL_ENDPOINT")
    fi
    
    # Pass certificate paths if provided
    [[ -n "$CERT_PATH" ]] && args+=(--cert-path "$CERT_PATH")
    [[ -n "$KEY_PATH" ]] && args+=(--key-path "$KEY_PATH")
    [[ -n "$CA_CERT_PATH" ]] && args+=(--ca-cert-path "$CA_CERT_PATH")
    
    # Pass installation path if specified
    [[ -n "$INSTALL_PATH" && "$INSTALL_PATH" != "$DEFAULT_INSTALL_PATH" ]] && args+=(--install-path "$INSTALL_PATH")
    
    # Pass build/debug flags
    [[ "$SKIP_BUILD" == "true" ]] && args+=(--skip-build)
    [[ "$DEBUG" == "true" ]] && args+=(--debug)
    
    log_debug "Calling agent deployment script with: ${args[*]}"
    
    # Run script and display output
    if bash "$agent_script" "${args[@]}"; then
        log_success "Agent deployment completed"
        return 0
    else
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
    
    log_section "Fluidity Complete Deployment"
    log_info "Operating System: $OS_TYPE"
    log_info "Default install path: $DEFAULT_INSTALL_PATH"
    log_info "Default proxy port: $DEFAULT_LOCAL_PROXY_PORT"
    
    case "$ACTION" in
        deploy)
            if ! deploy_server; then
                exit 1
            fi
            
            # Deploy agent with collected endpoints
            if ! deploy_agent; then
                exit 1
            fi
            
            log_success "Complete Fluidity deployment finished successfully"
            log_info ""
            log_info "Summary:"
            log_info "  - Server deployed to AWS"
            log_info "  - Agent deployed to: $INSTALL_PATH"
            log_info "  - Configuration: $INSTALL_PATH/agent.yaml"
            log_info ""
            log_info "Next steps:"
            log_info "1. Start the Fargate task in AWS Console (set DesiredCount=1)"
            log_info "2. Run the agent: $INSTALL_PATH/$([[ "$OS_TYPE" == "windows" ]] && echo "fluidity-agent.exe" || echo "fluidity-agent")"
            log_info ""
            ;;
        
        deploy-server)
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
            if [[ -z "$SERVER_IP" ]]; then
                log_warn "Server IP not provided, agent configuration will require manual input"
            fi
            
            if ! deploy_agent; then
                exit 1
            fi
            
            log_success "Agent deployment finished successfully"
            log_info ""
            log_info "Agent installed to: $INSTALL_PATH"
            log_info "Configuration: $INSTALL_PATH/agent.yaml"
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
