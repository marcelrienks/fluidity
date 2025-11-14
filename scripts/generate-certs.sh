#!/bin/bash

# Fluidity Certificate Generation Script
# Generates development certificates and optionally saves them to AWS Secrets Manager
# Usage: ./scripts/generate-certs.sh [--save-to-secrets] [--secret-name <name>] [--certs-dir <dir>]

set -euo pipefail

# Default values
CERTS_DIR="./certs"
DAYS=730  # 2 years
SAVE_TO_SECRETS=false
SECRET_NAME="fluidity/certificates"
COMMAND="generate"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --save-to-secrets)
            SAVE_TO_SECRETS=true
            shift
            ;;
        --secret-name)
            SECRET_NAME="$2"
            shift 2
            ;;
        --certs-dir)
            CERTS_DIR="$2"
            shift 2
            ;;
        --help)
            show_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

show_usage() {
    cat << EOF
Fluidity Certificate Management Script

Usage: ./scripts/generate-certs.sh [OPTIONS]

Options:
  --save-to-secrets      Save generated certificates to AWS Secrets Manager
  --secret-name NAME     AWS Secrets Manager secret name (default: fluidity/certificates)
  --certs-dir DIR        Directory for certificates (default: ./certs)
  --help                 Show this help message

Examples:
  # Generate certificates only
  ./scripts/generate-certs.sh

  # Generate and save to Secrets Manager
  ./scripts/generate-certs.sh --save-to-secrets

  # Generate and save to custom secret name
  ./scripts/generate-certs.sh --save-to-secrets --secret-name my-app/certs

  # Generate in custom directory
  ./scripts/generate-certs.sh --certs-dir /path/to/certs

EOF
}

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
    echo -e "${PALE_GREEN}================================================================================${RESET}"
}

log_info() {
    echo "[INFO] $*"
}

log_success() {
    echo "✓ $*"
}

log_error() {
    echo "[ERROR] $*" >&2
}

# ============================================================================
# CERTIFICATE GENERATION FUNCTIONS
# ============================================================================

generate_certificates() {
    log_section "Fluidity Certificate Generation"
    
    # Create certs directory if it doesn't exist
    mkdir -p "$CERTS_DIR"
    log_info "Certificates directory: $CERTS_DIR"
    log_info "Validity period: $DAYS days"
    echo ""
    
    # Generate CA private key
    echo "1. Generating CA private key..."
    openssl genrsa -out "$CERTS_DIR/ca.key" 4096 2>/dev/null
    
    # Generate CA certificate
    echo "2. Generating CA certificate..."
    openssl req -new -x509 -days $DAYS -key "$CERTS_DIR/ca.key" -out "$CERTS_DIR/ca.crt" \
        -subj "/C=US/ST=CA/L=SF/O=Fluidity/OU=Dev/CN=Fluidity-CA" 2>/dev/null
    
    # Generate server private key
    echo "3. Generating server private key..."
    openssl genrsa -out "$CERTS_DIR/server.key" 4096 2>/dev/null
    
    # Generate server certificate signing request
    echo "4. Generating server CSR..."
    openssl req -new -key "$CERTS_DIR/server.key" -out "$CERTS_DIR/server.csr" \
        -subj "/C=US/ST=CA/L=SF/O=Fluidity/OU=Server/CN=fluidity-server" 2>/dev/null
    
    # Create server certificate extensions file
    cat > "$CERTS_DIR/server.ext" << EXTEOF
[v3_req]
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = fluidity-server
DNS.2 = localhost
DNS.3 = host.docker.internal
IP.1 = 127.0.0.1
IP.2 = ::1
EXTEOF
    
    # Generate server certificate signed by CA
    echo "5. Generating server certificate..."
    openssl x509 -req -in "$CERTS_DIR/server.csr" -CA "$CERTS_DIR/ca.crt" -CAkey "$CERTS_DIR/ca.key" \
        -CAcreateserial -out "$CERTS_DIR/server.crt" -days $DAYS \
        -extensions v3_req -extfile "$CERTS_DIR/server.ext" 2>/dev/null
    
    # Generate client private key
    echo "6. Generating client private key..."
    openssl genrsa -out "$CERTS_DIR/client.key" 4096 2>/dev/null
    
    # Generate client certificate signing request
    echo "7. Generating client CSR..."
    openssl req -new -key "$CERTS_DIR/client.key" -out "$CERTS_DIR/client.csr" \
        -subj "/C=US/ST=CA/L=SF/O=Fluidity/OU=Client/CN=fluidity-client" 2>/dev/null
    
    # Create client certificate extensions file
    cat > "$CERTS_DIR/client.ext" << EXTEOF
[v3_req]
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage = clientAuth
EXTEOF
    
    # Generate client certificate signed by CA
    echo "8. Generating client certificate..."
    openssl x509 -req -in "$CERTS_DIR/client.csr" -CA "$CERTS_DIR/ca.crt" -CAkey "$CERTS_DIR/ca.key" \
        -CAcreateserial -out "$CERTS_DIR/client.crt" -days $DAYS \
        -extensions v3_req -extfile "$CERTS_DIR/client.ext" 2>/dev/null
    
    # Clean up temporary files
    rm -f "$CERTS_DIR/server.csr" "$CERTS_DIR/server.ext" "$CERTS_DIR/client.csr" "$CERTS_DIR/client.ext"
    
    # Set appropriate permissions
    chmod 600 "$CERTS_DIR"/*.key
    chmod 644 "$CERTS_DIR"/*.crt
    
    log_success "Certificates generated successfully"
    echo ""
    log_substep "Files Created"
    log_info "CA certificate: $CERTS_DIR/ca.crt"
    log_info "CA private key: $CERTS_DIR/ca.key"
    log_info "Server certificate: $CERTS_DIR/server.crt"
    log_info "Server private key: $CERTS_DIR/server.key"
    log_info "Client certificate: $CERTS_DIR/client.crt"
    log_info "Client private key: $CERTS_DIR/client.key"
    echo ""
    echo "⚠️  WARNING: These certificates are for development only!"
    echo "For production, use properly signed certificates from a trusted CA."
    echo ""
}

# ============================================================================
# SECRETS MANAGER FUNCTIONS
# ============================================================================

save_to_secrets_manager() {
    log_section "Saving Certificates to AWS Secrets Manager"
    
    log_info "Secret name: $SECRET_NAME"
    log_info "Certificate file: $CERTS_DIR/server.crt"
    log_info "Key file: $CERTS_DIR/server.key"
    log_info "CA file: $CERTS_DIR/ca.crt"
    echo ""
    
    # Check files exist
    if [ ! -f "$CERTS_DIR/server.crt" ]; then
        log_error "Certificate file not found: $CERTS_DIR/server.crt"
        exit 1
    fi
    
    if [ ! -f "$CERTS_DIR/server.key" ]; then
        log_error "Key file not found: $CERTS_DIR/server.key"
        exit 1
    fi
    
    if [ ! -f "$CERTS_DIR/ca.crt" ]; then
        log_error "CA file not found: $CERTS_DIR/ca.crt"
        exit 1
    fi
    
    # Read and base64 encode the certificates
    log_info "Encoding certificates..."
    CERT_PEM=$(base64 -w 0 < "$CERTS_DIR/server.crt")
    KEY_PEM=$(base64 -w 0 < "$CERTS_DIR/server.key")
    CA_PEM=$(base64 -w 0 < "$CERTS_DIR/ca.crt")
    
    # Create the JSON secret
    SECRET_JSON=$(cat <<EOF
{
  "cert_pem": "$CERT_PEM",
  "key_pem": "$KEY_PEM",
  "ca_pem": "$CA_PEM"
}
EOF
)
    
    # Save to AWS Secrets Manager
    log_info "Contacting AWS Secrets Manager..."
    
    if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" &>/dev/null; then
        log_info "Secret exists, updating..."
        aws secretsmanager update-secret \
            --secret-id "$SECRET_NAME" \
            --secret-string "$SECRET_JSON" >/dev/null
        log_success "Secret updated successfully!"
    else
        log_info "Secret does not exist, creating..."
        aws secretsmanager create-secret \
            --name "$SECRET_NAME" \
            --secret-string "$SECRET_JSON" >/dev/null
        log_success "Secret created successfully!"
    fi
    
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================

# Check if OpenSSL is available
if ! command -v openssl &> /dev/null; then
    log_error "OpenSSL not found!"
    echo "Please install OpenSSL and ensure it's in your PATH."
    exit 1
fi

# Check if AWS CLI is available (if saving to secrets)
if [ "$SAVE_TO_SECRETS" = true ]; then
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not found!"
        echo "Please install the AWS CLI and ensure it's in your PATH."
        echo "Visit: https://aws.amazon.com/cli/"
        exit 1
    fi
fi

# Generate certificates
generate_certificates

# Save to Secrets Manager if requested
if [ "$SAVE_TO_SECRETS" = true ]; then
    save_to_secrets_manager
    log_substep "Configuration for Fluidity"
    log_info "use_secrets_manager: true"
    log_info "secrets_manager_name: $SECRET_NAME"
    echo ""
fi

log_section "Certificate management complete!"
