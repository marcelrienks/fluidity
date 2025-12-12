#!/usr/bin/env bash

###############################################################################
# Fluidity Server Deployment Script
# 
# Builds and deploys the Fluidity server and Lambda functions to AWS using CloudFormation.
# Automatically detects missing AWS parameters, generates certificates if needed,
# and builds all components in a single command.
#
# FUNCTION:
#   Provisions and manages Fluidity server infrastructure on AWS including:
#   - ECS Fargate cluster and server deployment
#   - Lambda control plane (Wake/Sleep/Kill functions)
#   - Lambda Function URLs (no API Gateway needed)
#   - EventBridge scheduling
#   - CloudWatch monitoring
#
# USAGE:
#   ./deploy-server.sh [action] [options]
#
# ACTIONS:
#   deploy      Deploy all infrastructure (default)
#   delete      Delete all infrastructure
#   status      Show current stack status
#   outputs     Display stack outputs
#
# OPTIONS:
#   --region <region>              AWS region (auto-detect from AWS config)
#   --vpc-id <vpc>                 VPC ID (auto-detect default VPC)
#   --public-subnets <subnets>     Comma-separated subnet IDs (auto-detect)
#   --allowed-cidr <cidr>          Allowed ingress CIDR (auto-detect your IP)
#   --log-level <level>            Server log level (debug|info|warn|error)
#   --debug                        Enable debug logging
#   --force                        Delete and recreate all resources (instead of update)
#   -h, --help                     Show this help message
#
# EXAMPLES:
#   ./deploy-server.sh deploy
#   ./deploy-server.sh deploy --debug
#   ./deploy-server.sh deploy --log-level debug
#   ./deploy-server.sh delete
#   ./deploy-server.sh outputs
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

# Server Configuration
LOG_LEVEL=""

# Feature Flags
DEBUG=false
FORCE=false
ACCOUNT_ID=""
BUILD_VERSION=""

# Stack Names
STACK_NAME="fluidity"
FARGATE_STACK_NAME="${STACK_NAME}-fargate"
LAMBDA_STACK_NAME="${STACK_NAME}-lambda"
CA_STACK_NAME="${STACK_NAME}-ca"

# Paths
FARGATE_TEMPLATE="$CLOUDFORMATION_DIR/fargate.yaml"
LAMBDA_TEMPLATE="$CLOUDFORMATION_DIR/lambda.yaml"
CA_TEMPLATE="$CLOUDFORMATION_DIR/ca-lambda.yaml"
TEMP_PARAMS_DIR="/tmp/fluidity-deploy-server-$$"

# Storage for error logs
ERROR_LOG=""

# Source shared logging library
source "$(dirname "${BASH_SOURCE[0]}")/lib-logging.sh"

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
            --log-level)
                LOG_LEVEL="$2"
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

    if ! command -v aws &>/dev/null; then
        log_error_start
        echo "AWS CLI not found"
        echo "Install from: https://aws.amazon.com/cli/"
        log_error_end
        exit 1
    fi
    log_debug "AWS CLI found"

    if ! command -v jq &>/dev/null; then
        log_error_start
        echo "jq not found (required for JSON processing)"
        echo "Install from: https://stedolan.github.io/jq/"
        log_error_end
        exit 1
    fi
    log_debug "jq found"

    if ! ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>&1); then
        log_error_start
        echo "Failed to get AWS Account ID"
        echo "Ensure AWS credentials are configured: aws configure"
        log_error_end
        exit 1
    fi
    log_info "AWS Account: $ACCOUNT_ID"
    log_debug "Account ID: $ACCOUNT_ID"

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

    if [[ -z "$ALLOWED_CIDR" ]]; then
        PUBLIC_IP=""
        
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
# NOTE: Certificates are generated at runtime by server and agent using CA Lambda.
# No pre-deployment certificate generation is needed.
# The CA certificate and signing key are stored in AWS Secrets Manager
# and accessed by the CA Lambda function during certificate signing.

# ============================================================================
# BUILD & DEPLOYMENT
# ============================================================================

build_lambda_functions() {
    BUILD_VERSION=$(date +%Y%m%d%H%M%S)
    export BUILD_VERSION
    log_info "Build version: $BUILD_VERSION"
    log_debug "Calling: bash $SCRIPT_DIR/build-lambdas.sh"

    local timeout_cmd="timeout"
    if ! command -v timeout &> /dev/null; then
        if command -v gtimeout &> /dev/null; then
            timeout_cmd="gtimeout"
        else
            log_debug "timeout/gtimeout not found, running without timeout"
            timeout_cmd=""
        fi
    fi

    if [ -n "$timeout_cmd" ]; then
        $timeout_cmd 300 bash "$SCRIPT_DIR/build-lambdas.sh" 2>&1 | tee /tmp/lambda_build_$$.log
        local exit_code=${PIPESTATUS[0]}
        
        if [ $exit_code -eq 0 ]; then
            log_success "Lambda functions built"
            log_debug "Lambda build output saved to /tmp/lambda_build_$$.log"
            rm -f /tmp/lambda_build_$$.log
            log_debug "Lambda build artifacts in: $PROJECT_ROOT/build/lambdas"
            return 0
        else
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
        bash "$SCRIPT_DIR/build-lambdas.sh" 2>&1 | tee /tmp/lambda_build_$$.log
        local exit_code=${PIPESTATUS[0]}
        
        if [ $exit_code -eq 0 ]; then
            log_success "Lambda functions built"
            log_debug "Lambda build output saved to /tmp/lambda_build_$$.log"
            rm -f /tmp/lambda_build_$$.log
            log_debug "Lambda build artifacts in: $PROJECT_ROOT/build/lambdas"
            return 0
        else
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
    local ecr_repo="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/fluidity-server"

    log_info "ECR repository: $ecr_repo"

    if ! aws ecr describe-repositories --repository-names fluidity-server --region "$REGION" &>/dev/null; then
        log_info "Creating ECR repository..."
        aws ecr create-repository --repository-name fluidity-server --region "$REGION" >/dev/null 2>&1 || true
    fi
    log_debug "ECR repository verified"

    log_info "Building and pushing Docker image for Fargate (linux/amd64)..."
    if bash "$SCRIPT_DIR/build-docker.sh" \
        --server \
        --version "$build_version" \
        --platform linux/amd64 \
        --push \
        --ecr-repo "$ecr_repo" \
        --region "$REGION"; then
        log_success "Docker image built and pushed to ECR"
    else
        log_error_start
        echo "Docker build or push failed"
        log_error_end
        ERROR_LOG+=$'Docker build/push failed\n'
        return 1
    fi

    log_debug "Image URI: $ecr_repo:$build_version"
    DOCKER_IMAGE_URI="$ecr_repo:$build_version"
}

upload_lambda_to_s3() {
    local build_version="$1"
    local lambda_s3_bucket="fluidity-lambda-artifacts-${ACCOUNT_ID}-${REGION}"

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

    local lambda_build_dir="$PROJECT_ROOT/build/lambdas"
    if [[ ! -d "$lambda_build_dir" ]]; then
        log_error_start
        echo "Lambda build directory not found: $lambda_build_dir"
        log_error_end
        ERROR_LOG+=$'Lambda build directory not found\n'
        return 1
    fi
    log_debug "Lambda build directory exists: $lambda_build_dir"

    local func_count=0
    for func in wake sleep kill query; do
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

        for func in wake sleep kill query; do
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

        local events
        events=$(aws cloudformation describe-stack-events \
            --stack-name "$stack_name" \
            --region "$REGION" \
            --query 'StackEvents[*].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
            --output text 2>/dev/null || echo "")

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
# RETENTION POLICIES
# ============================================================================

set_retention_policies() {
    log_minor "Step 8: Configure Retention Policies"
    
    log_substep "Setting CloudWatch Logs Retention"
    local log_group="/ecs/fluidity/server"
    if aws logs describe-log-groups --log-group-name-prefix "$log_group" --region "$REGION" &>/dev/null; then
        log_info "Setting retention to 7 days for: $log_group"
        if aws logs put-retention-policy \
            --log-group-name "$log_group" \
            --retention-in-days 7 \
            --region "$REGION" >/dev/null 2>&1; then
            log_success "CloudWatch Logs retention set to 7 days"
        else
            log_info "Failed to set log retention (may not have permissions)"
        fi
    else
        log_info "Log group not found (will be created with 7-day retention on next task run)"
    fi
    
    log_substep "Setting ECR Lifecycle Policy"
    local ecr_repo="fluidity-server"
    if aws ecr describe-repositories --repository-names "$ecr_repo" --region "$REGION" &>/dev/null 2>&1; then
        local lifecycle_policy=$(cat <<'EOF'
{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Keep only the latest image (by push date)",
      "selection": {
        "tagStatus": "any",
        "countType": "imageCountMoreThan",
        "countNumber": 1
      },
      "action": {
        "type": "expire"
      }
    }
  ]
}
EOF
)
        if echo "$lifecycle_policy" | aws ecr put-lifecycle-policy \
            --repository-name "$ecr_repo" \
            --lifecycle-policy-text file:///dev/stdin \
            --region "$REGION" >/dev/null 2>&1; then
            log_success "ECR lifecycle policy set (keeping only latest image, deleting older)"
        else
            log_info "Failed to set ECR lifecycle policy"
        fi
    fi
    
    log_substep "Cleaning Old S3 Lambda Artifacts"
    local s3_bucket="fluidity-lambda-artifacts-${ACCOUNT_ID}-${REGION}"
    if aws s3 ls "s3://$s3_bucket" --region "$REGION" &>/dev/null 2>&1; then
        local current_version
        current_version=$(aws cloudformation describe-stacks \
            --stack-name "$LAMBDA_STACK_NAME" \
            --region "$REGION" \
            --query 'Stacks[0].Parameters[?ParameterKey==`BuildVersion`].ParameterValue' \
            --output text 2>/dev/null)
        
        if [[ -n "$current_version" && "$current_version" != "None" ]]; then
            log_info "Current build version: $current_version"
            log_info "Deleting old Lambda artifacts (keeping only $current_version)"
            
            local deleted_count=0
        for func in wake sleep kill query; do
                local all_zips
                all_zips=$(aws s3 ls "s3://$s3_bucket/fluidity/${func}-" --region "$REGION" 2>/dev/null | awk '{print $4}' || echo "")
                
                if [[ -n "$all_zips" ]]; then
                    echo "$all_zips" | while read -r zip_file; do
                        if [[ -n "$zip_file" && "$zip_file" != "${func}-${current_version}.zip" ]]; then
                            if aws s3 rm "s3://$s3_bucket/fluidity/$zip_file" --region "$REGION" >/dev/null 2>&1; then
                                log_debug "Deleted: $zip_file"
                                deleted_count=$((deleted_count + 1))
                            fi
                        fi
                    done
                fi
            done
            
            log_success "S3 cleanup complete (keeping only current build: $current_version)"
        else
            log_info "Could not determine current build version, skipping S3 cleanup"
        fi
    fi
    
    log_success "Retention policies configured"
}

# ============================================================================
# CLEANUP & OUTPUT
# ============================================================================

get_stack_output() {
    local stack_name="$1"
    local output_key="$2"
    
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='$output_key'].OutputValue" \
        --output text 2>/dev/null || echo ""
}

collect_endpoints() {
    log_debug "Collecting deployment endpoints..."
    
    # Get server public IP command (need to extract when task is running)
    SERVER_IP_COMMAND=$(get_stack_output "$FARGATE_STACK_NAME" "GetPublicIPCommand")
    
    # Get Lambda endpoints
    WAKE_ENDPOINT=$(get_stack_output "$LAMBDA_STACK_NAME" "WakeAPIEndpoint")
    KILL_ENDPOINT=$(get_stack_output "$LAMBDA_STACK_NAME" "KillAPIEndpoint")
    QUERY_ENDPOINT=$(get_stack_output "$LAMBDA_STACK_NAME" "QueryAPIEndpoint")
    SLEEP_ENDPOINT=$(get_stack_output "$LAMBDA_STACK_NAME" "SleepScheduleRuleName")
    
    # Get CA Lambda endpoint (if CA stack exists)
    CA_SERVICE_URL=$(get_stack_output "$CA_STACK_NAME" "CAAPIEndpoint" 2>/dev/null || echo "")

    # Get IAM resources
    AGENT_IAM_ROLE_ARN=$(get_stack_output "$LAMBDA_STACK_NAME" "AgentIAMRoleArn")
    AGENT_ACCESS_KEY_ID=$(get_stack_output "$LAMBDA_STACK_NAME" "AgentIAMUserAccessKey")
    AGENT_SECRET_ACCESS_KEY=$(get_stack_output "$LAMBDA_STACK_NAME" "AgentIAMUserSecretKey")
    
    # Construct sleep endpoint from kill endpoint pattern
    if [[ -n "$KILL_ENDPOINT" ]]; then
        SLEEP_ENDPOINT="${KILL_ENDPOINT%/kill*}/sleep"
    fi
    
    log_debug "Wake endpoint: $WAKE_ENDPOINT"
    log_debug "Kill endpoint: $KILL_ENDPOINT"
    log_debug "Sleep endpoint: $SLEEP_ENDPOINT"
    
    log_info "Wake Lambda URL: $WAKE_ENDPOINT"
    log_info "Kill Lambda URL: $KILL_ENDPOINT"
}

output_stack_info() {
    log_minor "Deployment Complete"
    log_substep "Stack Outputs"

    for stack_name in "$FARGATE_STACK_NAME" "$LAMBDA_STACK_NAME"; do
        if aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" &>/dev/null 2>&1; then
            outputs=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' --output json 2>/dev/null)
            if [[ -n "$outputs" ]]; then
                echo ""
                log_info "$stack_name:"
                echo "$outputs" | jq -r '.[] | "  \(.[0]): \(.[1] // "None")"' 2>/dev/null
            fi
        fi
    done
    
    log_substep "Endpoint Summary"
    collect_endpoints
}

export_endpoints() {
    # Export endpoints as environment variables that can be sourced
    echo "export SERVER_REGION='$REGION'"
    echo "export SERVER_IP_COMMAND=\"$SERVER_IP_COMMAND\""
    echo "export WAKE_ENDPOINT='$WAKE_ENDPOINT'"
    echo "export KILL_ENDPOINT='$KILL_ENDPOINT'"
    echo "export QUERY_ENDPOINT='$QUERY_ENDPOINT'"
    echo "export CA_SERVICE_URL='$CA_SERVICE_URL'"
    echo "export SERVER_PORT='8443'"
    echo "export AGENT_IAM_ROLE_ARN='$AGENT_IAM_ROLE_ARN'"
    echo "export AGENT_ACCESS_KEY_ID='$AGENT_ACCESS_KEY_ID'"
    echo "export AGENT_SECRET_ACCESS_KEY='$AGENT_SECRET_ACCESS_KEY'"
}

cleanup() {
    rm -rf "$TEMP_PARAMS_DIR" 2>/dev/null || true
}

# ============================================================================
# ACTIONS
# ============================================================================

action_deploy() {
    mkdir -p "$TEMP_PARAMS_DIR"

    log_minor "Step 1.5: Apply Log Level Configuration"
    if [[ -n "$LOG_LEVEL" ]]; then
        log_info "Applying log level to server configuration: $LOG_LEVEL"
        
        if [[ -f "$PROJECT_ROOT/configs/server.yaml" ]]; then
            sed -i '' "s/log_level: .*/log_level: $LOG_LEVEL/" "$PROJECT_ROOT/configs/server.yaml"
            log_success "Updated server.yaml with log_level: $LOG_LEVEL"
        fi
        if [[ -f "$PROJECT_ROOT/configs/server.docker.yaml" ]]; then
            sed -i '' "s/log_level: .*/log_level: $LOG_LEVEL/" "$PROJECT_ROOT/configs/server.docker.yaml"
            log_success "Updated server.docker.yaml with log_level: $LOG_LEVEL"
        fi
    fi

    log_minor "Step 2: Build and Upload Lambda Functions to S3"
    log_substep "Building Lambda Functions"
    if ! build_lambda_functions; then
        return 1
    fi
    
    log_substep "Uploading Lambda Functions to S3"
    if ! upload_lambda_to_s3 "$BUILD_VERSION"; then
        return 1
    fi
    lambda_s3_bucket="$LAMBDA_S3_BUCKET"

    log_minor "Step 3: Build and Push Fargate Docker Image to ECR"
    if ! build_and_push_docker_image "$BUILD_VERSION"; then
        return 1
    fi
    docker_image=$(echo "$DOCKER_IMAGE_URI" | tail -1)

    log_minor "Step 4: Deploy Fargate Server Stack"
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
  {"ParameterKey": "LogRetentionDays", "ParameterValue": "7"}
]
EOF
    deploy_cloudformation_stack "$FARGATE_STACK_NAME" "$FARGATE_TEMPLATE" "$fargate_params" || return 1

    log_minor "Step 6: Verify S3 Lambda Artifacts are Available"
    verify_s3_resources "$BUILD_VERSION" "$lambda_s3_bucket" || return 1

    log_minor "Step 7: Deploy Lambda Control Plane Stack"
    
    log_substep "Cleaning up existing Lambda log groups (idempotent)"
    for log_group in "/aws/lambda/fluidity-lambda-kill" "/aws/lambda/fluidity-lambda-sleep" "/aws/lambda/fluidity-lambda-wake" "/aws/lambda/fluidity-lambda-query"; do
        if aws logs describe-log-groups --log-group-name-prefix "$log_group" --region "$REGION" 2>/dev/null | grep -q "\"logGroupName\": \"$log_group\""; then
            log_info "Deleting existing log group: $log_group"
            aws logs delete-log-group --log-group-name "$log_group" --region "$REGION" 2>/dev/null || true
        fi
    done
    
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
  {"ParameterKey": "KillLambdaTimeout", "ParameterValue": "30"}
]
EOF
    deploy_cloudformation_stack "$LAMBDA_STACK_NAME" "$LAMBDA_TEMPLATE" "$lambda_params" || return 1

    set_retention_policies
    log_success "Server deployment completed successfully"
}

action_delete() {
    log_minor "Step 1: Delete CloudFormation Stacks"

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

    log_minor "Step 2: Delete ECR Repository"
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

    log_minor "Step 3: Delete S3 Bucket and Contents"
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

    log_minor "Step 4: Delete Secrets Manager Secret"
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

    log_minor "Step 5: Delete CloudWatch Log Groups"
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
    log_minor "Stack Status"

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
    log_minor "Stack Outputs"

    for stack_name in "$FARGATE_STACK_NAME" "$LAMBDA_STACK_NAME"; do
        log_substep "$stack_name"
        if outputs=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' --output json 2>/dev/null); then
            # Format outputs as key: value on separate lines
            echo "$outputs" | jq -r '.[] | "\(.key): \(.value // "None")"' 2>/dev/null || {
                # Fallback if jq parsing fails
                echo "$outputs" | jq -r '.[] | "\(.[0]): \(.[1] // "None")"' 2>/dev/null
            }
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
    validate_action
    parse_arguments "$@"
    trap cleanup EXIT

    log_header "Fluidity Server Deployment"

    log_minor "Step 1: Check Prerequisites and Detect AWS Parameters"
    check_prerequisites

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

    if [[ "$ACTION" == "deploy" ]]; then
        auto_detect_parameters
        log_info "Parameters: Region=$REGION VPC=$VPC_ID"
        [[ "$FORCE" == "true" ]] && log_info "Force mode: Enabled (will delete and recreate all resources)"
    fi

    case "$ACTION" in
        deploy)
            if action_deploy; then
                output_stack_info
                log_success "Deployment finished successfully"
                # Export endpoints for use by calling script
                log_debug "Exporting endpoints..."
                export_endpoints
            else
                log_error_start
                echo "$ERROR_LOG"
                log_error_end
                output_stack_info
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

main "$@"
