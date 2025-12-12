#!/usr/bin/env bash

###############################################################################
# Fluidity CA Certificate Generation Script
# 
# Generates self-signed CA certificate and private key for the Fluidity
# Certificate Authority Lambda function. This certificate is used to sign
# all agent and server certificates at runtime.
#
# USAGE:
#   ./generate-ca-certs.sh [options]
#
# OPTIONS:
#   --certs-dir DIR          Output directory for certificates (default: ./certs)
#   --save-to-secrets        Store CA certificate in AWS Secrets Manager
#   --secret-name NAME       AWS Secrets Manager secret name (default: fluidity/ca-certificate)
#   --help                   Show this help message
#
# EXAMPLES:
#   ./generate-ca-certs.sh                                # Generate to ./certs
#   ./generate-ca-certs.sh --save-to-secrets              # Upload to AWS Secrets Manager
#   ./generate-ca-certs.sh --secret-name my/ca-secret    # Custom secret name
#
# NOTES:
#   - CA certificate is valid for 5 years
#   - CA certificate should be generated ONCE per AWS account
#   - Store the CA certificate securely (backup ./certs/ca.* files)
#   - CloudFormation will reference this secret when deploying CA Lambda
#
###############################################################################

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

CERTS_DIR="${PROJECT_ROOT}/certs"
SAVE_TO_SECRETS=false
SECRET_NAME="fluidity/ca-certificate"
VALIDITY_DAYS=1825  # 5 years - CA certificates should be long-lived

# CA Certificate configuration
COUNTRY="US"
STATE="State"
LOCALITY="Locality"
ORGANIZATION="Fluidity"
COMMON_NAME_CA="Fluidity-CA"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

log_info() {
    echo "[INFO] $*"
}

log_success() {
    echo "[SUCCESS] $*"
}

log_error() {
    echo "[ERROR] $*" >&2
}

log_warn() {
    echo "[WARN] $*" >&2
}

show_help() {
    sed -n '1,/^###############################################################################$/p' "$0" | tail -n +2
}

# ============================================================================
# CA CERTIFICATE GENERATION
# ============================================================================

generate_ca_certificate() {
    log_info "Generating CA certificate (valid for $VALIDITY_DAYS days)..."
    
    openssl req -x509 -newkey rsa:4096 -nodes \
        -keyout "$CERTS_DIR/ca.key" \
        -out "$CERTS_DIR/ca.crt" \
        -days "$VALIDITY_DAYS" \
        -subj "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/CN=$COMMON_NAME_CA"
    
    log_success "CA certificate generated"
}

store_in_secrets_manager() {
    log_info "Storing CA certificate in AWS Secrets Manager (secret: $SECRET_NAME)..."
    
    # Read CA certificate and key
    local ca_cert
    ca_cert=$(cat "$CERTS_DIR/ca.crt")
    local ca_key
    ca_key=$(cat "$CERTS_DIR/ca.key")
    
    # Create JSON secret value
    local secret_json
    secret_json=$(cat <<EOF
{
  "ca_cert": $(echo "$ca_cert" | jq -Rs .),
  "ca_key": $(echo "$ca_key" | jq -Rs .)
}
EOF
    )
    
    # Check if secret already exists
    if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" &>/dev/null 2>&1; then
        log_info "Secret already exists, updating..."
        
        if ! aws secretsmanager update-secret \
            --secret-id "$SECRET_NAME" \
            --secret-string "$secret_json" &>/dev/null; then
            log_error "Failed to update secret: $SECRET_NAME"
            return 1
        fi
        
        log_success "Secret updated: $SECRET_NAME"
    else
        log_info "Creating new secret..."
        
        if ! aws secretsmanager create-secret \
            --name "$SECRET_NAME" \
            --description "Fluidity CA Certificate and Key for certificate signing" \
            --secret-string "$secret_json" \
            --tags Key=Application,Value=Fluidity Key=Purpose,Value=CA &>/dev/null; then
            log_error "Failed to create secret: $SECRET_NAME"
            return 1
        fi
        
        log_success "Secret created: $SECRET_NAME"
    fi
    
    # Verify secret was stored correctly
    if ! aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" &>/dev/null; then
        log_error "Failed to verify secret: $SECRET_NAME"
        return 1
    fi
    
    log_success "CA certificate verified in AWS Secrets Manager"
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --certs-dir)
                CERTS_DIR="$2"
                shift 2
                ;;
            --save-to-secrets)
                SAVE_TO_SECRETS=true
                shift
                ;;
            --secret-name)
                SECRET_NAME="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Check if OpenSSL is available
    if ! command -v openssl &>/dev/null; then
        log_error "OpenSSL not found. Please install OpenSSL:"
        echo "  Linux/WSL: sudo apt-get install openssl"
        echo "  macOS: brew install openssl"
        echo "  Windows: Use WSL or install OpenSSL for Windows"
        exit 1
    fi
    
    # Check if jq is available (needed for JSON encoding in Secrets Manager)
    if [[ "$SAVE_TO_SECRETS" == "true" ]] && ! command -v jq &>/dev/null; then
        log_error "jq not found (required for --save-to-secrets). Please install jq:"
        echo "  Linux/WSL: sudo apt-get install jq"
        echo "  macOS: brew install jq"
        exit 1
    fi
    
    # Create certificates directory
    mkdir -p "$CERTS_DIR"
    log_info "Using certificates directory: $CERTS_DIR"
    
    # Check if CA certificate already exists
    if [[ -f "$CERTS_DIR/ca.crt" ]] && [[ -f "$CERTS_DIR/ca.key" ]]; then
        log_warn "CA certificate already exists at $CERTS_DIR"
        read -p "Do you want to regenerate it? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Keeping existing CA certificate"
            
            # Still upload to Secrets Manager if requested
            if [[ "$SAVE_TO_SECRETS" == "true" ]]; then
                store_in_secrets_manager || return 1
            fi
            
            return 0
        fi
    fi
    
    # Generate CA certificate
    generate_ca_certificate
    
    # Set restrictive permissions on private key
    chmod 0600 "$CERTS_DIR/ca.key"
    chmod 0644 "$CERTS_DIR/ca.crt"
    
    log_success "CA certificate generation complete"
    log_info "CA certificate location: $CERTS_DIR"
    log_info "  CA certificate: $CERTS_DIR/ca.crt"
    log_info "  CA private key: $CERTS_DIR/ca.key"
    
    # Display certificate details
    log_info "CA certificate details:"
    openssl x509 -in "$CERTS_DIR/ca.crt" -text -noout | grep -E "Subject:|Issuer:|Not Before|Not After:" || true
    
    # Store in Secrets Manager if requested
    if [[ "$SAVE_TO_SECRETS" == "true" ]]; then
        if ! command -v aws &>/dev/null; then
            log_error "AWS CLI not found. Cannot store certificates in AWS Secrets Manager."
            log_info "Install AWS CLI or run: aws secretsmanager create-secret --name $SECRET_NAME --secret-string '...'"
            exit 1
        fi
        
        store_in_secrets_manager || return 1
    fi
    
    log_success "CA certificate ready for Fluidity deployment"
}

main "$@"
