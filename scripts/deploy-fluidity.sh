#!/usr/bin/env bash

###############################################################################
# Fluidity Deployment Script
# 
# Deploys complete Fluidity infrastructure to AWS using CloudFormation.
# Automatically detects missing AWS parameters, generates certificates if needed,
# and builds all components in a single command.
#
# FUNCTION:
#   Provisions and manages Fluidity tunnel infrastructure on AWS including:
#   - ECS Fargate cluster and server deployment
#   - Lambda control plane (Wake/Sleep/Kill functions)
#   - API Gateway with authentication
#   - EventBridge scheduling
#   - CloudWatch monitoring
#
# USAGE:
#   ./deploy-fluidity.sh [action] [options]
#
# ACTIONS:
#   deploy      Deploy all infrastructure (default)
#   delete      Delete all infrastructure
#   status      Show current stack status
#   outputs     Display stack outputs and API credentials
#
# OPTIONS:
#   --region <region>              AWS region (auto-detect from AWS config)
#   --vpc-id <vpc>                 VPC ID (auto-detect default VPC)
#   --public-subnets <subnets>     Comma-separated subnet IDs (auto-detect)
#   --allowed-cidr <cidr>          Allowed ingress CIDR (auto-detect your IP)
#   --debug                        Enable debug logging
#   --force                        Delete and recreate all resources (instead of update)
#   -h, --help                     Show this help message
#
# EXAMPLES:
#   ./deploy-fluidity.sh deploy
#   ./deploy-fluidity.sh deploy --debug
#   ./deploy-fluidity.sh deploy --force --region us-west-2
#   ./deploy-fluidity.sh delete
#   ./deploy-fluidity.sh outputs
#
###############################################################################

set -euo pipefail

# ============================================================================
# CONFIGURATION & DEFAULTS
# ============================================================================

ACTION="${1:-deploy}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CERTS_DIR="$PROJECT_ROOT/certs"
CLOUDFORMATION_DIR="$PROJECT_ROOT/deployments/cloudformation"

# AWS Configuration
REGION=""
VPC_ID=""
PUBLIC_SUBNETS=""
ALLOWED_CIDR=""

# Feature Flags
DEBUG=false
FORCE=false
ACCOUNT_ID=""
BUILD_VERSION=""

# Stack Names
STACK_NAME="fluidity"
FARGATE_STACK_NAME="${STACK_NAME}-fargate"
LAMBDA_STACK_NAME="${STACK_NAME}-lambda"

# Paths
FARGATE_TEMPLATE="$CLOUDFORMATION_DIR/fargate.yaml"
LAMBDA_TEMPLATE="$CLOUDFORMATION_DIR/lambda.yaml"
TEMP_PARAMS_DIR="/tmp/fluidity-deploy-$$"

# Storage for error logs
ERROR_LOG=""
API_ENDPOINT=""
API_KEY_ID=""

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

log_error_start() {
    echo ""
    echo "================================================================================"
    echo "ERROR"
    echo "================================================================================"
}

log_error_end() {
    echo "================================================================================"
    echo ""
}

log_section() {
    echo ""
    echo ">>> $*"
}

log_substep() {
    echo "=== $*"
}

log_success() {
    echo "✓ $*"
}

# ============================================================================
# HELP & VALIDATION
# ============================================================================

show_help() {
    # Extract and display help from header comments
    sed -n '3,/^###############################################################################$/p' "$0" | sed '$d' | sed 's/^# *//'
    exit 0
}

parse_arguments() {
    shift || true
    while [[ $# -gt 0 ]]; do
        case $1 in
            --region)
                REGION="$2"
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
        deploy|delete|status|outputs)
            ;;
        -h|--help)
            show_help
            ;;
        *)
            log_error_start
            echo "Invalid action: $ACTION"
            echo "Valid actions: deploy, delete, status, outputs"
            log_error_end
            exit 1
            ;;
    esac
}

# ============================================================================
# PREREQUISITE CHECKS
# ============================================================================

check_prerequisites() {
    log_substep "Checking Prerequisites"

    # Check AWS CLI
    if ! command -v aws &>/dev/null; then
        log_error_start
        echo "AWS CLI not found"
        echo "Install from: https://aws.amazon.com/cli/"
        log_error_end
        exit 1
    fi
    log_debug "AWS CLI found"

    # Check Docker
    if ! command -v docker &>/dev/null; then
        log_error_start
        echo "Docker not found"
        echo "Install from: https://www.docker.com/products/docker-desktop"
        log_error_end
        exit 1
    fi
    log_debug "Docker found"

    # Check if Docker daemon is accessible
    if ! docker ps &>/dev/null 2>&1; then
        log_error_start
        echo "Docker daemon is not accessible"
        echo "Please ensure Docker Desktop is running:"
        echo "  - macOS/Windows: Open Docker Desktop application"
        echo "  - Linux: Ensure Docker service is running (systemctl start docker)"
        echo "  - Windows+WSL: Enable Docker Desktop WSL 2 integration in settings"
        log_error_end
        exit 1
    fi
    log_debug "Docker daemon is accessible"

    # Check jq
    if ! command -v jq &>/dev/null; then
        log_error_start
        echo "jq not found (required for JSON processing)"
        echo "Install from: https://stedolan.github.io/jq/"
        log_error_end
        exit 1
    fi
    log_debug "jq found"

    # Get AWS Account ID
    if ! ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>&1); then
        log_error_start
        echo "Failed to get AWS Account ID"
        echo "Ensure AWS credentials are configured: aws configure"
        log_error_end
        exit 1
    fi
    log_info "AWS Account: $ACCOUNT_ID"
    log_debug "Account ID: $ACCOUNT_ID"

    # Check templates exist
    if [[ ! -f "$FARGATE_TEMPLATE" ]]; then
        log_error_start
        echo "Fargate template not found: $FARGATE_TEMPLATE"
        log_error_end
        exit 1
    fi
    log_debug "Fargate template found"

    if [[ ! -f "$LAMBDA_TEMPLATE" ]]; then
        log_error_start
        echo "Lambda template not found: $LAMBDA_TEMPLATE"
        log_error_end
        exit 1
    fi
    log_debug "Lambda template found"
}

# ============================================================================
# AWS PARAMETER AUTO-DETECTION
# ============================================================================

auto_detect_parameters() {
    log_substep "Detecting AWS Parameters"

    # Detect Region
    if [[ -z "$REGION" ]]; then
        if REGION=$(aws configure get region 2>/dev/null); then
            [[ -n "$REGION" ]] && log_info "Region auto-detected: $REGION" || {
                read -p "Enter AWS Region (e.g., us-east-1): " REGION
                [[ -z "$REGION" ]] && {
                    log_error_start
                    echo "Region is required"
                    log_error_end
                    exit 1
                }
            }
        else
            read -p "Enter AWS Region (e.g., us-east-1): " REGION
            [[ -z "$REGION" ]] && {
                log_error_start
                echo "Region is required"
                log_error_end
                exit 1
            }
        fi
    fi
    log_debug "Region: $REGION"

    # Detect VPC ID
    if [[ -z "$VPC_ID" ]]; then
        if VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text 2>/dev/null); then
            if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
                log_info "VPC auto-detected: $VPC_ID"
            else
                read -p "Enter VPC ID (e.g., vpc-abc123): " VPC_ID
                [[ -z "$VPC_ID" ]] && {
                    log_error_start
                    echo "VPC ID is required"
                    log_error_end
                    exit 1
                }
            fi
        else
            read -p "Enter VPC ID (e.g., vpc-abc123): " VPC_ID
            [[ -z "$VPC_ID" ]] && {
                log_error_start
                echo "VPC ID is required"
                log_error_end
                exit 1
            }
        fi
    fi
    log_debug "VPC ID: $VPC_ID"

    # Detect Public Subnets
    if [[ -z "$PUBLIC_SUBNETS" ]]; then
        if SUBNET_LIST=$(aws ec2 describe-subnets --region "$REGION" --filters Name=vpc-id,Values="$VPC_ID" --query 'Subnets[*].SubnetId' --output text 2>/dev/null); then
            if [[ -n "$SUBNET_LIST" ]]; then
                PUBLIC_SUBNETS=$(echo "$SUBNET_LIST" | tr '\t' ',')
                log_info "Subnets auto-detected: $PUBLIC_SUBNETS"
            else
                read -p "Enter Public Subnet IDs (comma-separated): " PUBLIC_SUBNETS
                [[ -z "$PUBLIC_SUBNETS" ]] && {
                    log_error_start
                    echo "Public Subnets are required"
                    log_error_end
                    exit 1
                }
            fi
        else
            read -p "Enter Public Subnet IDs (comma-separated): " PUBLIC_SUBNETS
            [[ -z "$PUBLIC_SUBNETS" ]] && {
                log_error_start
                echo "Public Subnets are required"
                log_error_end
                exit 1
            }
        fi
    fi
    log_debug "Public Subnets: $PUBLIC_SUBNETS"

    # Detect Public IP (Allowed CIDR)
    if [[ -z "$ALLOWED_CIDR" ]]; then
        PUBLIC_IP=""
        
        # Try multiple IP detection services with fallbacks
        for service in "https://icanhazip.com" "https://ifconfig.me" "https://api.ipify.org" "https://ident.me"; do
            log_debug "Attempting to get public IP from: $service"
            if PUBLIC_IP=$(curl -s --max-time 3 "$service" 2>/dev/null); then
                PUBLIC_IP=$(echo "$PUBLIC_IP" | tr -d '\n' | tr -d ' ')
                if [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    ALLOWED_CIDR="${PUBLIC_IP}/32"
                    log_info "Public IP auto-detected: $ALLOWED_CIDR"
                    break
                fi
            fi
        done
        
        # If all services failed, prompt user
        if [[ -z "$ALLOWED_CIDR" ]]; then
            log_debug "Failed to auto-detect public IP from all services"
            read -p "Enter Allowed Ingress CIDR (e.g., 1.2.3.4/32): " ALLOWED_CIDR
            [[ -z "$ALLOWED_CIDR" ]] && {
                log_error_start
                echo "Allowed Ingress CIDR is required"
                log_error_end
                exit 1
            }
        fi
    fi
    log_debug "Allowed CIDR: $ALLOWED_CIDR"
}

# ============================================================================
# CERTIFICATE MANAGEMENT
# ============================================================================

ensure_certificates() {
    if [[ ! -f "$CERTS_DIR/server.crt" ]] || [[ ! -f "$CERTS_DIR/server.key" ]] || [[ ! -f "$CERTS_DIR/ca.crt" ]]; then
        log_info "Certificates not found, generating..."
        if bash "$SCRIPT_DIR/manage-certs.sh"; then
            log_success "Certificates generated"
        else
            log_error_start
            echo "Failed to generate certificates"
            echo "Run manually: ./scripts/manage-certs.sh"
            log_error_end
            exit 1
        fi
    else
        log_success "Certificates found"
    fi
    log_debug "Certificates location: $CERTS_DIR"
}

store_certificates_in_secrets_manager() {
    local secret_name="fluidity-certificates"

    log_info "Storing certificates in AWS Secrets Manager..."

    # Check if secret exists and its status
    local secret_status
    if secret_status=$(aws secretsmanager describe-secret --secret-id "$secret_name" --region "$REGION" --query 'DeletedDate' --output text 2>/dev/null); then
        if [[ "$secret_status" != "None" && -n "$secret_status" ]]; then
            log_info "Secret is marked for deletion, waiting for removal (max 30s)..."
            local retry_count=0
            while [ $retry_count -lt 15 ]; do
                if ! aws secretsmanager describe-secret --secret-id "$secret_name" --region "$REGION" &>/dev/null 2>&1; then
                    log_debug "Secret deletion complete"
                    break
                fi
                sleep 2
                retry_count=$((retry_count + 1))
            done
        fi
    fi

    # Build JSON with properly escaped certificates
    local secret_json
    secret_json=$(jq -n \
        --arg cert "$(cat "$CERTS_DIR/server.crt")" \
        --arg key "$(cat "$CERTS_DIR/server.key")" \
        --arg ca "$(cat "$CERTS_DIR/ca.crt")" \
        '{cert_pem: $cert, key_pem: $key, ca_pem: $ca}')
    
    if [[ -z "$secret_json" ]]; then
        log_error_start
        echo "Failed to build secret JSON from certificates"
        log_error_end
        return 1
    fi
    log_debug "Secret JSON created successfully"

    # Create or update secret
    if aws secretsmanager describe-secret --secret-id "$secret_name" --region "$REGION" &>/dev/null 2>&1; then
        log_debug "Updating existing secret: $secret_name"
        if ! aws secretsmanager put-secret-value \
            --secret-id "$secret_name" \
            --secret-string "$secret_json" \
            --region "$REGION" >/dev/null 2>&1; then
            log_error_start
            echo "Failed to update Secrets Manager secret"
            log_error_end
            return 1
        fi
        log_success "Secret updated: $secret_name"
    else
        log_debug "Creating new secret: $secret_name"
        if ! aws secretsmanager create-secret \
            --name "$secret_name" \
            --description "TLS certificates for Fluidity server" \
            --secret-string "$secret_json" \
            --region "$REGION" \
            --tags Key=Application,Value=Fluidity Key=ManagedBy,Value=DeployScript >/dev/null 2>&1; then
            log_error_start
            echo "Failed to create Secrets Manager secret"
            log_error_end
            return 1
        fi
        log_success "Secret created: $secret_name"
    fi

    # Get ARN
    local secret_arn
    secret_arn=$(aws secretsmanager describe-secret --secret-id "$secret_name" --region "$REGION" --query 'ARN' --output text 2>&1)
    if [[ $? -ne 0 || -z "$secret_arn" ]]; then
        log_error_start
        echo "Failed to retrieve Secrets Manager secret ARN"
        log_error_end
        return 1
    fi
    
    log_success "Certificates stored in Secrets Manager"
    log_debug "Secret ARN: $secret_arn"

    echo "$secret_arn"
}

# ============================================================================
# BUILD & DEPLOYMENT
# ============================================================================

build_lambda_functions() {
    BUILD_VERSION=$(date +%Y%m%d%H%M%S)
    log_info "Build version: $BUILD_VERSION"
    log_debug "Calling: bash $SCRIPT_DIR/build-lambdas.sh"

    # Determine which timeout command to use (BSD timeout on macOS, GNU timeout on Linux)
    local timeout_cmd="timeout"
    if ! command -v timeout &> /dev/null; then
        if command -v gtimeout &> /dev/null; then
            timeout_cmd="gtimeout"
        else
            log_debug "timeout/gtimeout not found, running without timeout"
            timeout_cmd=""
        fi
    fi

    # Run with timeout and capture output
    if [ -n "$timeout_cmd" ]; then
        if $timeout_cmd 300 bash "$SCRIPT_DIR/build-lambdas.sh" 2>&1 | tee /tmp/lambda_build_$$.log; then
            log_success "Lambda functions built"
            log_debug "Lambda build output saved to /tmp/lambda_build_$$.log"
            rm -f /tmp/lambda_build_$$.log
            log_debug "Lambda build artifacts in: $PROJECT_ROOT/build/lambdas"
            return 0
        else
            local exit_code=$?
            log_error_start
            if [ $exit_code -eq 124 ]; then
                echo "Lambda build timed out after 300s"
            else
                echo "Lambda build failed with exit code $exit_code"
            fi
            echo "Build output:"
            cat /tmp/lambda_build_$$.log 2>/dev/null || echo "(no output captured)"
            log_error_end
            ERROR_LOG+=$'Lambda build failed\n'
            rm -f /tmp/lambda_build_$$.log
            return 1
        fi
    else
        if bash "$SCRIPT_DIR/build-lambdas.sh" 2>&1 | tee /tmp/lambda_build_$$.log; then
            log_success "Lambda functions built"
            log_debug "Lambda build output saved to /tmp/lambda_build_$$.log"
            rm -f /tmp/lambda_build_$$.log
            log_debug "Lambda build artifacts in: $PROJECT_ROOT/build/lambdas"
            return 0
        else
            local exit_code=$?
            log_error_start
            echo "Lambda build failed with exit code $exit_code"
            echo "Build output:"
            cat /tmp/lambda_build_$$.log 2>/dev/null || echo "(no output captured)"
            log_error_end
            ERROR_LOG+=$'Lambda build failed\n'
            rm -f /tmp/lambda_build_$$.log
            return 1
        fi
    fi
}

build_and_push_docker_image() {
    local build_version="$1"

    # Build core binaries
    log_info "Building core binaries..."
    if ! BUILD_VERSION="$build_version" bash "$SCRIPT_DIR/build-core.sh" --linux >/dev/null 2>&1; then
        log_error_start
        echo "Core build failed"
        log_error_end
        ERROR_LOG+=$'Core build failed\n'
        return 1
    fi
    log_success "Core binaries built"

    # ECR setup
    local ecr_repo="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/fluidity-server"
    log_info "ECR repository: $ecr_repo"

    # Ensure ECR repo exists
    if ! aws ecr describe-repositories --repository-names fluidity-server --region "$REGION" &>/dev/null; then
        log_info "Creating ECR repository..."
        aws ecr create-repository --repository-name fluidity-server --region "$REGION" >/dev/null 2>&1 || true
    fi
    log_debug "ECR repository verified"

    # Docker build
    log_info "Building Docker image..."
    if ! docker build -f "$PROJECT_ROOT/deployments/server/Dockerfile" -t fluidity-server:"$build_version" "$PROJECT_ROOT" >/dev/null 2>&1; then
        log_error_start
        echo "Docker build failed"
        log_error_end
        ERROR_LOG+=$'Docker build failed\n'
        return 1
    fi
    log_success "Docker image built"

    # Docker push
    log_info "Logging into ECR..."
    if ! aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com" >/dev/null 2>&1; then
        log_error_start
        echo "ECR login failed"
        log_error_end
        ERROR_LOG+=$'ECR login failed\n'
        return 1
    fi

    log_info "Tagging and pushing Docker image..."
    docker tag fluidity-server:"$build_version" "$ecr_repo:$build_version"
    if ! docker push "$ecr_repo:$build_version" >/dev/null 2>&1; then
        log_error_start
        echo "Docker push to ECR failed"
        log_error_end
        ERROR_LOG+=$'Docker push failed\n'
        return 1
    fi
    log_success "Docker image pushed to ECR"

    log_debug "Image URI: $ecr_repo:$build_version"
    DOCKER_IMAGE_URI="$ecr_repo:$build_version"
}

upload_lambda_to_s3() {
    local build_version="$1"
    local lambda_s3_bucket="fluidity-lambda-artifacts-${ACCOUNT_ID}-${REGION}"

    # Ensure S3 bucket exists
    if ! aws s3 ls "s3://$lambda_s3_bucket" --region "$REGION" &>/dev/null; then
        log_info "Creating S3 bucket: $lambda_s3_bucket"
        if ! aws s3 mb "s3://$lambda_s3_bucket" --region "$REGION"; then
            log_error_start
            echo "Failed to create S3 bucket: $lambda_s3_bucket"
            log_error_end
            ERROR_LOG+=$'S3 bucket creation failed\n'
            return 1
        fi
        log_success "S3 bucket created"
    else
        log_info "S3 bucket already exists: $lambda_s3_bucket"
    fi
    log_debug "S3 bucket ready: $lambda_s3_bucket"

    # Verify Lambda build directory exists
    local lambda_build_dir="$PROJECT_ROOT/build/lambdas"
    if [[ ! -d "$lambda_build_dir" ]]; then
        log_error_start
        echo "Lambda build directory not found: $lambda_build_dir"
        log_error_end
        ERROR_LOG+=$'Lambda build directory not found\n'
        return 1
    fi
    log_debug "Lambda build directory exists: $lambda_build_dir"

    # Upload functions
    local func_count=0
    for func in wake sleep kill; do
        local zip_name="${func}-${build_version}.zip"
        local zip_path="$lambda_build_dir/$zip_name"
        
        if [[ ! -f "$zip_path" ]]; then
            log_error_start
            echo "Lambda ZIP file not found: $zip_path"
            log_error_end
            ERROR_LOG+=$"Lambda ZIP not found: $zip_name\n"
            return 1
        fi
        
        log_info "Uploading $zip_name..."
        if ! aws s3 cp "$zip_path" "s3://$lambda_s3_bucket/fluidity/$zip_name" --region "$REGION"; then
            log_error_start
            echo "Failed to upload $zip_name to S3"
            log_error_end
            ERROR_LOG+=$"Failed to upload $zip_name\n"
            return 1
        fi
        log_success "$zip_name uploaded"
        func_count=$((func_count + 1))
    done

    log_success "All $func_count Lambda functions uploaded"
    log_debug "Lambda artifacts in S3: s3://$lambda_s3_bucket/fluidity/"
    LAMBDA_S3_BUCKET="$lambda_s3_bucket"
}

verify_s3_resources() {
    local build_version="$1"
    local lambda_s3_bucket="$2"
    local max_retries=30
    local retry_delay=2
    local total_wait=0
    local max_total_wait=60

    log_substep "Verifying S3 Resource Propagation"
    log_info "Checking Lambda artifacts in S3 (up to ${max_total_wait}s with backoff)"

    local all_found=false
    local attempt=0

    while [[ $total_wait -lt $max_total_wait ]]; do
        attempt=$((attempt + 1))
        all_found=true

        for func in wake sleep kill; do
            local zip_name="${func}-${build_version}.zip"
            if aws s3 ls "s3://$lambda_s3_bucket/fluidity/$zip_name" --region "$REGION" &>/dev/null; then
                log_debug "✓ Found: $zip_name"
            else
                log_debug "✗ Not found: $zip_name (attempt $attempt)"
                all_found=false
            fi
        done

        if [[ "$all_found" == "true" ]]; then
            log_success "All S3 resources verified and propagated"
            log_info "Waiting additional 10s to ensure complete propagation..."
            sleep 10
            return 0
        fi

        if [[ $total_wait -lt $max_total_wait ]]; then
            log_info "Retrying in ${retry_delay}s... (${total_wait}s/${max_total_wait}s)"
            sleep "$retry_delay"
            total_wait=$((total_wait + retry_delay))
        fi
    done

    log_error_start
    echo "S3 resources not fully propagated after ${max_total_wait}s"
    echo "This may cause Lambda deployment to fail"
    log_error_end
    return 1
}

deploy_cloudformation_stack() {
    local stack_name="$1"
    local template="$2"
    local params_file="$3"

    log_info "Deploying CloudFormation stack: $stack_name"

    # Check if stack exists
    if aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" &>/dev/null; then
        if [[ "$FORCE" == "true" ]]; then
            log_info "Force flag enabled, deleting and recreating stack..."
            aws cloudformation delete-stack --stack-name "$stack_name" --region "$REGION"
            if ! aws cloudformation wait stack-delete-complete --stack-name "$stack_name" --region "$REGION" 2>/dev/null; then
                log_error_start
                echo "Stack deletion failed or timed out: $stack_name"
                log_error_end
                ERROR_LOG+=$"Stack deletion failed: $stack_name\n"
                return 1
            fi
            log_debug "Stack deleted successfully, creating new stack..."
            aws cloudformation create-stack \
                --stack-name "$stack_name" \
                --template-body file://"$template" \
                --parameters file://"$params_file" \
                --capabilities CAPABILITY_NAMED_IAM \
                --region "$REGION" \
                --tags Key=Application,Value=Fluidity Key=ManagedBy,Value=DeployScript >/dev/null
            if ! wait_for_stack_creation "$stack_name"; then
                log_error_start
                echo "Stack creation failed or timed out: $stack_name"
                log_error_end
                ERROR_LOG+=$"Stack creation failed: $stack_name\n"
                return 1
            fi
            log_success "Stack recreated: $stack_name"
        else
            log_debug "Stack exists, updating..."
            aws cloudformation update-stack \
                --stack-name "$stack_name" \
                --template-body file://"$template" \
                --parameters file://"$params_file" \
                --capabilities CAPABILITY_NAMED_IAM \
                --region "$REGION" \
                --tags Key=Application,Value=Fluidity Key=ManagedBy,Value=DeployScript >/dev/null 2>&1 || {
                    # If no updates are to be performed, that's okay
                    log_debug "No updates to be performed or stack update already in progress"
                }
            if ! aws cloudformation wait stack-update-complete --stack-name "$stack_name" --region "$REGION" 2>/dev/null; then
                log_debug "Stack update timed out or no updates needed (this may be okay)"
            fi
            log_success "Stack updated: $stack_name"
        fi
    else
        log_debug "Stack does not exist, creating..."
        aws cloudformation create-stack \
            --stack-name "$stack_name" \
            --template-body file://"$template" \
            --parameters file://"$params_file" \
            --capabilities CAPABILITY_NAMED_IAM \
            --region "$REGION" \
            --tags Key=Application,Value=Fluidity Key=ManagedBy,Value=DeployScript >/dev/null
        if ! wait_for_stack_creation "$stack_name"; then
            log_error_start
            echo "Stack creation failed or timed out: $stack_name"
            log_error_end
            # Get failed events for diagnostics
            log_error_start
            echo "CloudFormation Stack Events:"
            aws cloudformation describe-stack-events \
                --stack-name "$stack_name" \
                --region "$REGION" \
                --query 'StackEvents[?ResourceStatus==`CREATE_FAILED` || ResourceStatus==`ROLLBACK_IN_PROGRESS` || ResourceStatus==`ROLLBACK_COMPLETE`].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
                --output table 2>/dev/null || true
            log_error_end
            ERROR_LOG+=$"Stack creation failed: $stack_name\n"
            return 1
        fi
        log_success "Stack created: $stack_name"
    fi
}

wait_for_stack_creation() {
    local stack_name="$1"
    local timeout=600
    local elapsed=0
    local poll_interval=10
    local last_event_timestamp=""

    log_info "Waiting for stack creation to complete (max ${timeout}s)..."

    while [ $elapsed -lt $timeout ]; do
        local status
        status=$(aws cloudformation describe-stacks \
            --stack-name "$stack_name" \
            --region "$REGION" \
            --query 'Stacks[0].StackStatus' \
            --output text 2>/dev/null)

        # Get recent events
        local events
        events=$(aws cloudformation describe-stack-events \
            --stack-name "$stack_name" \
            --region "$REGION" \
            --query 'StackEvents[*].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
            --output text 2>/dev/null || echo "")

        # Show new events
        if [[ -n "$events" ]]; then
            echo "$events" | while IFS=$'\t' read -r timestamp resource_id resource_status resource_reason; do
                if [[ -n "$timestamp" && "$timestamp" != "$last_event_timestamp" ]]; then
                    if [[ "$resource_status" == "CREATE_FAILED" || "$resource_status" == "ROLLBACK_IN_PROGRESS" ]]; then
                        log_error_start
                        echo "$timestamp | $resource_id | $resource_status | $resource_reason"
                        log_error_end
                    elif [[ "$resource_status" != "CREATE_IN_PROGRESS" ]]; then
                        log_debug "$timestamp | $resource_id | $resource_status"
                    fi
                    last_event_timestamp="$timestamp"
                fi
            done
        fi

        case "$status" in
            CREATE_COMPLETE)
                return 0
                ;;
            ROLLBACK_COMPLETE|CREATE_FAILED|ROLLBACK_IN_PROGRESS)
                log_error_start
                echo "Stack creation failed with status: $status"
                log_error_end
                return 1
                ;;
            CREATE_IN_PROGRESS|UPDATE_IN_PROGRESS|UPDATE_COMPLETE_CLEANUP_IN_PROGRESS)
                sleep $poll_interval
                elapsed=$((elapsed + poll_interval))
                ;;
            *)
                log_debug "Stack status: $status (elapsed: ${elapsed}s)"
                sleep $poll_interval
                elapsed=$((elapsed + poll_interval))
                ;;
        esac
    done

    log_error_start
    echo "Stack creation timed out after ${timeout}s"
    log_error_end
    return 1
}

# ============================================================================
# CLEANUP & OUTPUT
# ============================================================================

output_api_credentials() {
    log_section "API Credentials"

    # Get Lambda outputs
    API_ENDPOINT=$(aws cloudformation describe-stacks \
        --stack-name "$LAMBDA_STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`KillAPIEndpoint`].OutputValue' \
        --output text 2>/dev/null) || API_ENDPOINT="Not found"

    API_KEY_ID=$(aws cloudformation describe-stacks \
        --stack-name "$LAMBDA_STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`APIKeyId`].OutputValue' \
        --output text 2>/dev/null) || API_KEY_ID="Not found"

    log_info "API Endpoint: $API_ENDPOINT"
    log_info "API Key ID: $API_KEY_ID"

    if [[ "$API_KEY_ID" != "Not found" && -n "$API_KEY_ID" ]]; then
        log_info "To get API key value, run:"
        log_info "  aws apigateway get-api-key --api-key $API_KEY_ID --include-value --region $REGION"
    fi
}

cleanup() {
    rm -rf "$TEMP_PARAMS_DIR" 2>/dev/null || true
}

# ============================================================================
# ACTIONS
# ============================================================================

action_deploy() {
    mkdir -p "$TEMP_PARAMS_DIR"

    # Step 2: Build and upload Lambda functions to S3
    log_section "Step 2: Build and Upload Lambda Functions to S3"
    
    log_substep "Building Lambda Functions"
    if ! build_lambda_functions; then
        return 1
    fi
    
    log_substep "Uploading Lambda Functions to S3"
    if ! upload_lambda_to_s3 "$BUILD_VERSION"; then
        return 1
    fi
    lambda_s3_bucket="$LAMBDA_S3_BUCKET"

    # Step 3: Build and push Fargate Docker image to ECR
    log_section "Step 3: Build and Push Fargate Docker Image to ECR"
    if ! build_and_push_docker_image "$BUILD_VERSION"; then
        return 1
    fi
    docker_image=$(echo "$DOCKER_IMAGE_URI" | tail -1)

    # Step 4: Prepare certificates and store in Secrets Manager
    log_section "Step 4: Prepare Certificates and Store in Secrets Manager"
    
    log_substep "Ensuring Certificates Exist"
    ensure_certificates
    
    log_substep "Storing Certificates in Secrets Manager"
    secret_arn=$(store_certificates_in_secrets_manager) || return 1
    secret_arn=$(echo "$secret_arn" | tail -1)

    # Step 5: Deploy Fargate server stack
    log_section "Step 5: Deploy Fargate Server Stack"
    local fargate_params="$TEMP_PARAMS_DIR/fargate-params.json"
    cat > "$fargate_params" << EOF
[
  {"ParameterKey": "ClusterName", "ParameterValue": "fluidity"},
  {"ParameterKey": "ServiceName", "ParameterValue": "fluidity-server"},
  {"ParameterKey": "ContainerImage", "ParameterValue": "$docker_image"},
  {"ParameterKey": "ContainerPort", "ParameterValue": "8443"},
  {"ParameterKey": "Cpu", "ParameterValue": "256"},
  {"ParameterKey": "Memory", "ParameterValue": "512"},
  {"ParameterKey": "DesiredCount", "ParameterValue": "0"},
  {"ParameterKey": "VpcId", "ParameterValue": "$VPC_ID"},
  {"ParameterKey": "PublicSubnets", "ParameterValue": "$PUBLIC_SUBNETS"},
  {"ParameterKey": "AllowedIngressCidr", "ParameterValue": "$ALLOWED_CIDR"},
  {"ParameterKey": "AssignPublicIp", "ParameterValue": "ENABLED"},
  {"ParameterKey": "LogGroupName", "ParameterValue": "/ecs/fluidity/server"},
  {"ParameterKey": "LogRetentionDays", "ParameterValue": "30"},
  {"ParameterKey": "CertificatesSecretArn", "ParameterValue": "$secret_arn"}
]
EOF
    deploy_cloudformation_stack "$FARGATE_STACK_NAME" "$FARGATE_TEMPLATE" "$fargate_params" || return 1

    # Step 6: Verify S3 Lambda artifacts are available for deployment
    log_section "Step 6: Verify S3 Lambda Artifacts are Available"
    verify_s3_resources "$BUILD_VERSION" "$lambda_s3_bucket" || return 1

    # Step 7: Deploy Lambda control plane stack
    log_section "Step 7: Deploy Lambda Control Plane Stack"
    local lambda_params="$TEMP_PARAMS_DIR/lambda-params.json"
    cat > "$lambda_params" << EOF
[
  {"ParameterKey": "LambdaS3Bucket", "ParameterValue": "$lambda_s3_bucket"},
  {"ParameterKey": "LambdaS3KeyPrefix", "ParameterValue": "fluidity/"},
  {"ParameterKey": "BuildVersion", "ParameterValue": "$BUILD_VERSION"},
  {"ParameterKey": "ECSClusterName", "ParameterValue": "fluidity"},
  {"ParameterKey": "ECSServiceName", "ParameterValue": "fluidity-server"},
  {"ParameterKey": "IdleThresholdMinutes", "ParameterValue": "15"},
  {"ParameterKey": "LookbackPeriodMinutes", "ParameterValue": "10"},
  {"ParameterKey": "SleepCheckIntervalMinutes", "ParameterValue": "5"},
  {"ParameterKey": "DailyKillTime", "ParameterValue": "cron(0 23 * * ? *)"},
  {"ParameterKey": "WakeLambdaTimeout", "ParameterValue": "30"},
  {"ParameterKey": "SleepLambdaTimeout", "ParameterValue": "60"},
  {"ParameterKey": "KillLambdaTimeout", "ParameterValue": "30"},
  {"ParameterKey": "APIThrottleBurstLimit", "ParameterValue": "20"},
  {"ParameterKey": "APIThrottleRateLimit", "ParameterValue": "3"},
  {"ParameterKey": "APIQuotaLimit", "ParameterValue": "300"}
]
EOF
    deploy_cloudformation_stack "$LAMBDA_STACK_NAME" "$LAMBDA_TEMPLATE" "$lambda_params" || return 1

    log_success "Deployment completed successfully"
}

action_delete() {
    log_section "Step 1: Delete CloudFormation Stacks"

    for stack_name in "$LAMBDA_STACK_NAME" "$FARGATE_STACK_NAME"; do
        if aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" &>/dev/null 2>&1; then
            log_info "Deleting CloudFormation stack: $stack_name"
            aws cloudformation delete-stack --stack-name "$stack_name" --region "$REGION"
            if aws cloudformation wait stack-delete-complete --stack-name "$stack_name" --region "$REGION" 2>/dev/null; then
                log_success "CloudFormation stack deleted: $stack_name"
            else
                log_info "Stack deletion in progress or timed out: $stack_name"
            fi
        else
            log_info "CloudFormation stack not found: $stack_name"
        fi
    done

    # Step 2: Delete ECR repository
    log_section "Step 2: Delete ECR Repository"
    if aws ecr describe-repositories --repository-names fluidity-server --region "$REGION" &>/dev/null 2>&1; then
        log_info "Deleting ECR repository: fluidity-server"
        if aws ecr delete-repository --repository-name fluidity-server --region "$REGION" --force >/dev/null 2>&1; then
            log_success "ECR repository deleted"
        else
            log_info "Failed to delete ECR repository (may be in use)"
        fi
    else
        log_info "ECR repository not found"
    fi

    # Step 3: Delete S3 bucket and contents
    log_section "Step 3: Delete S3 Bucket and Contents"
    local lambda_s3_bucket="fluidity-lambda-artifacts-${ACCOUNT_ID}-${REGION}"
    if aws s3 ls "s3://$lambda_s3_bucket" --region "$REGION" &>/dev/null 2>&1; then
        log_info "Deleting S3 bucket and contents: $lambda_s3_bucket"
        if aws s3 rm "s3://$lambda_s3_bucket" --recursive --region "$REGION" >/dev/null 2>&1 && \
           aws s3 rb "s3://$lambda_s3_bucket" --region "$REGION" >/dev/null 2>&1; then
            log_success "S3 bucket deleted"
        else
            log_info "Failed to delete S3 bucket (may be in use or contain protected objects)"
        fi
    else
        log_info "S3 bucket not found"
    fi

    # Step 4: Delete Secrets Manager secret
    log_section "Step 4: Delete Secrets Manager Secret"
    if aws secretsmanager describe-secret --secret-id fluidity-certificates --region "$REGION" &>/dev/null 2>&1; then
        log_info "Deleting Secrets Manager secret: fluidity-certificates"
        if aws secretsmanager delete-secret --secret-id fluidity-certificates --region "$REGION" --force-delete-without-recovery >/dev/null 2>&1; then
            log_success "Secrets Manager secret deleted"
        else
            log_info "Failed to delete Secrets Manager secret"
        fi
    else
        log_info "Secrets Manager secret not found"
    fi

    # Step 5: Delete CloudWatch log groups
    log_section "Step 5: Delete CloudWatch Log Groups"
    local log_patterns=("/ecs/fluidity" "/aws/lambda/fluidity" "API-Gateway-Execution-Logs" "scheduler-")
    
    for pattern in "${log_patterns[@]}"; do
        local log_groups
        log_groups=$(aws logs describe-log-groups --region "$REGION" --query "logGroups[?contains(logGroupName, '$pattern')].logGroupName" --output text 2>/dev/null)
        
        if [[ -n "$log_groups" ]]; then
            log_info "Found log groups matching pattern: $pattern"
            echo "$log_groups" | tr '\t' '\n' | while read -r log_group; do
                if [[ -n "$log_group" ]]; then
                    if aws logs delete-log-group --log-group-name "$log_group" --region "$REGION" >/dev/null 2>&1; then
                        log_success "Deleted: $log_group"
                    else
                        log_info "Failed to delete: $log_group"
                    fi
                fi
            done
        fi
    done

    log_success "Infrastructure cleanup completed"
}

action_status() {
    log_section "Stack Status"

    for stack_name in "$FARGATE_STACK_NAME" "$LAMBDA_STACK_NAME"; do
        local status
        if status=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" --query 'Stacks[0].StackStatus' --output text 2>/dev/null); then
            log_info "$stack_name: $status"
        else
            log_info "$stack_name: Not found"
        fi
    done
}

action_outputs() {
    log_section "Stack Outputs"

    for stack_name in "$FARGATE_STACK_NAME" "$LAMBDA_STACK_NAME"; do
        log_substep "$stack_name"
        if aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' --output table 2>/dev/null; then
            :
        else
            log_info "Stack not found"
        fi
        echo ""
    done
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    # Parse command line
    validate_action
    parse_arguments "$@"

    # Traps
    trap cleanup EXIT

    # Step 1: Check prerequisites and detect AWS parameters
    log_section "Step 1: Check Prerequisites and Detect AWS Parameters"
    check_prerequisites

    # Detect region for all actions (needed for AWS API calls)
    if [[ -z "$REGION" ]]; then
        if REGION=$(aws configure get region 2>/dev/null); then
            [[ -n "$REGION" ]] && log_debug "Region auto-detected: $REGION" || {
                log_error_start
                echo "Region could not be auto-detected. Set it with: aws configure set region us-east-1"
                log_error_end
                exit 1
            }
        else
            log_error_start
            echo "Region could not be auto-detected. Set it with: aws configure set region us-east-1"
            log_error_end
            exit 1
        fi
    fi

    # Deploy-specific steps (need full parameter detection)
    if [[ "$ACTION" == "deploy" ]]; then
        auto_detect_parameters
        log_info "Parameters: Region=$REGION VPC=$VPC_ID"
        [[ "$FORCE" == "true" ]] && log_info "Force mode: Enabled (will delete and recreate all resources)"
    fi

    # Execute action
    case "$ACTION" in
        deploy)
            if action_deploy; then
                output_api_credentials
                log_success "Deployment finished successfully"
            else
                log_error_start
                echo "$ERROR_LOG"
                log_error_end
                output_api_credentials
                exit 1
            fi
            ;;
        delete)
            action_delete
            ;;
        status)
            action_status
            ;;
        outputs)
            action_outputs
            ;;
    esac
}

# Execute main
main "$@"
