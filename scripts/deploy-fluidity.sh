#!/usr/bin/env bash
set -euo pipefail

#
# deploy-fluidity.sh - Deploy Fluidity infrastructure to AWS using CloudFormation
#
# Usage:
#   ./deploy-fluidity.sh [OPTIONS]
#
# Options:
#   -a, --action ACTION        Action to perform: deploy, delete, status, outputs (default: deploy)
#   -s, --stack-name NAME      CloudFormation stack name (default: fluidity)
#   -f, --force                Skip confirmation prompts
#   -h, --help                 Show this help message
#
# Required Parameters:
#   --account-id ID            [OPTIONAL if AWS CLI configured] AWS Account ID (12 digits)
#                              Auto-detected from AWS credentials if not provided
#                              Get: aws sts get-caller-identity --query Account --output text
#   --region REGION            [REQUIRED] AWS Region (e.g., us-east-1)
#   --vpc-id VPC               [REQUIRED] VPC ID
#                              Get: aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text
#   --public-subnets SUBNETS   [REQUIRED] Comma-separated list of public subnet IDs (minimum 2)
#                              Get: aws ec2 describe-subnets --filters Name=vpc-id,Values=<VPC_ID> --query 'Subnets[*].SubnetId' --output text | tr '\t' ','
#   --allowed-cidr CIDR        [REQUIRED] Allowed ingress CIDR (e.g., 1.2.3.4/32)
#                              Get: curl -s https://ifconfig.me && echo '/32'
#
# Optional Parameters (with defaults):
#   --container-image IMAGE    Container image URI (default: <account-id>.dkr.ecr.<region>.amazonaws.com/fluidity-server:latest)
#   --cluster-name NAME        ECS cluster name (default: fluidity)
#   --service-name NAME        ECS service name (default: fluidity-server)
#   --container-port PORT      Container port (default: 8443)
#   --cpu CPU                  CPU units - 256=0.25vCPU, 512=0.5vCPU, 1024=1vCPU (default: 256)
#   --memory MEMORY            Memory in MB (default: 512)
#   --desired-count COUNT      Initial desired task count, 0=stopped (default: 0)
#
# Examples:
#   # Deploy with required parameters (Account ID auto-detected)
#   ./deploy-fluidity.sh -a deploy --region us-east-1 --vpc-id vpc-abc123 --public-subnets subnet-1,subnet-2 --allowed-cidr 1.2.3.4/32
#
#   # Quick deploy using AWS CLI to gather values
#   VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
#   SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID --query 'Subnets[*].SubnetId' --output text | tr '\t' ',')
#   MY_IP=$(curl -s ifconfig.me)/32
#   ./deploy-fluidity.sh -a deploy --region us-east-1 --vpc-id $VPC_ID --public-subnets $SUBNETS --allowed-cidr $MY_IP
#
#   # Deploy with custom optional parameters
#   ./deploy-fluidity.sh -a deploy --region us-east-1 --vpc-id vpc-abc123 --public-subnets subnet-1,subnet-2 --allowed-cidr 1.2.3.4/32 --cpu 512 --memory 1024 --desired-count 1
#
#   # Check stack status
#   ./deploy-fluidity.sh -a status
#
#   # Delete stack
#   ./deploy-fluidity.sh -a delete -f
#

# Default values
ACTION="${ACTION:-deploy}"
STACK_NAME="${STACK_NAME:-fluidity}"
FORCE=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUDFORMATION_DIR="$(dirname "$SCRIPT_DIR")/deployments/cloudformation"

# AWS Configuration
ACCOUNT_ID=""
REGION=""
VPC_ID=""
PUBLIC_SUBNETS=""
ALLOWED_CIDR=""

# Container Configuration
CONTAINER_IMAGE=""
CLUSTER_NAME="fluidity"
SERVICE_NAME="fluidity-server"
CONTAINER_PORT="8443"
CPU="256"
MEMORY="512"
DESIRED_COUNT="0"

# Logging Configuration
LOG_GROUP_NAME="/ecs/fluidity/server"
LOG_RETENTION_DAYS="30"

# Lambda Configuration
IDLE_THRESHOLD_MINUTES="15"
LOOKBACK_PERIOD_MINUTES="10"
SLEEP_CHECK_INTERVAL_MINUTES="5"
DAILY_KILL_TIME="cron(0 23 * * ? *)"
WAKE_LAMBDA_TIMEOUT="30"
SLEEP_LAMBDA_TIMEOUT="60"
KILL_LAMBDA_TIMEOUT="30"

# API Gateway Configuration
API_THROTTLE_BURST_LIMIT="20"
API_THROTTLE_RATE_LIMIT="3"
API_QUOTA_LIMIT="300"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -a|--action)
            ACTION="$2"
            shift 2
            ;;
        -s|--stack-name)
            STACK_NAME="$2"
            shift 2
            ;;
        -p|--parameters)
            PARAMETERS_FILE="$2"
            shift 2
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        --account-id)
            ACCOUNT_ID="$2"
            shift 2
            ;;
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
        --container-image)
            CONTAINER_IMAGE="$2"
            shift 2
            ;;
        --cluster-name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --service-name)
            SERVICE_NAME="$2"
            shift 2
            ;;
        --container-port)
            CONTAINER_PORT="$2"
            shift 2
            ;;
        --cpu)
            CPU="$2"
            shift 2
            ;;
        --memory)
            MEMORY="$2"
            shift 2
            ;;
        --desired-count)
            DESIRED_COUNT="$2"
            shift 2
            ;;
        -h|--help)
            grep '^#' "$0" | tail -n +3 | head -n -1
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate action
if [[ ! "$ACTION" =~ ^(deploy|delete|status|outputs)$ ]]; then
    echo "Error: Action must be 'deploy', 'delete', 'status', or 'outputs'"
    exit 1
fi

# Set defaults
FARGATE_STACK_NAME="${STACK_NAME}-fargate"
LAMBDA_STACK_NAME="${STACK_NAME}-lambda"
FARGATE_TEMPLATE="$CLOUDFORMATION_DIR/fargate.yaml"
LAMBDA_TEMPLATE="$CLOUDFORMATION_DIR/lambda.yaml"
STACK_POLICY="$CLOUDFORMATION_DIR/stack-policy.json"
CAPABILITIES="CAPABILITY_NAMED_IAM"

# Check if AWS CLI is installed and configured
echo "Checking AWS CLI configuration..."

AWS_CONFIGURED=false
if command -v aws &> /dev/null; then
    CALLER_IDENTITY=$(aws sts get-caller-identity 2>&1)
    if [[ $? -eq 0 ]]; then
        AWS_CONFIGURED=true
        CALLER_ACCOUNT=$(echo "$CALLER_IDENTITY" | jq -r '.Account')
        CALLER_ARN=$(echo "$CALLER_IDENTITY" | jq -r '.Arn')
        echo "[OK] AWS CLI is configured"
        echo "  Account: $CALLER_ACCOUNT"
        echo "  User: $CALLER_ARN"
        
        # Auto-populate ACCOUNT_ID if not provided
        if [[ -z "$ACCOUNT_ID" ]]; then
            ACCOUNT_ID="$CALLER_ACCOUNT"
            echo "[OK] Using Account ID from AWS credentials: $ACCOUNT_ID"
        fi
    fi
fi

if [[ "$AWS_CONFIGURED" == false ]]; then
    echo ""
    echo "[ERROR] AWS CLI is not configured"
    echo ""
    echo "The AWS CLI needs to be configured with your credentials before running this script."
    
    echo ""
    echo "To configure AWS CLI:"
    echo "  1. Run: aws configure"
    echo "  2. Enter your AWS Access Key ID"
    echo "  3. Enter your AWS Secret Access Key"
    echo "  4. Enter your default region (e.g., us-east-1)"
    echo "  5. Enter default output format: json"
    
    echo ""
    echo "To get AWS credentials:"
    echo "  1. Log in to AWS Console: https://console.aws.amazon.com"
    echo "  2. Go to: IAM > Users > [Your User] > Security Credentials"
    echo "  3. Create Access Key > CLI"
    echo "  4. Copy the Access Key ID and Secret Access Key"
    
    echo ""
    echo "After configuring AWS CLI, run this script again."
    echo ""
    exit 1
fi

# Auto-gather missing required parameters from AWS
echo "Checking required parameters..."

USE_CMDLINE_PARAMS=true
GATHERED_PARAMS=()

# Try to auto-detect Region from AWS CLI default configuration if not provided
if [[ -z "$REGION" ]]; then
    echo "Region not provided, attempting to auto-detect..."
    REGION=$(aws configure get region 2>&1)
    if [[ $? -eq 0 ]] && [[ -n "$REGION" ]]; then
        GATHERED_PARAMS+=("Region")
        echo "[OK] Auto-detected Region: $REGION"
    else
        REGION=""
    fi
fi

# Try to auto-detect VpcId from default VPC if not provided
if [[ -z "$VPC_ID" ]] && [[ -n "$REGION" ]]; then
    echo "VpcId not provided, attempting to auto-detect default VPC..."
    VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text 2>&1)
    if [[ $? -eq 0 ]] && [[ -n "$VPC_ID" ]] && [[ "$VPC_ID" != "None" ]]; then
        GATHERED_PARAMS+=("VpcId")
        echo "[OK] Auto-detected VpcId: $VPC_ID"
    else
        VPC_ID=""
    fi
fi

# Try to auto-detect PublicSubnets from VPC if not provided
if [[ -z "$PUBLIC_SUBNETS" ]] && [[ -n "$VPC_ID" ]] && [[ -n "$REGION" ]]; then
    echo "PublicSubnets not provided, attempting to auto-detect from VPC..."
    SUBNET_LIST=$(aws ec2 describe-subnets --region "$REGION" --filters Name=vpc-id,Values="$VPC_ID" Name=map-public-ip-on-launch,Values=true --query 'Subnets[*].SubnetId' --output text 2>&1)
    if [[ $? -eq 0 ]] && [[ -n "$SUBNET_LIST" ]]; then
        PUBLIC_SUBNETS=$(echo "$SUBNET_LIST" | tr '\t' ',')
        if [[ -n "$PUBLIC_SUBNETS" ]]; then
            GATHERED_PARAMS+=("PublicSubnets")
            echo "[OK] Auto-detected PublicSubnets: $PUBLIC_SUBNETS"
        else
            PUBLIC_SUBNETS=""
        fi
    else
        PUBLIC_SUBNETS=""
    fi
fi

# Try to auto-detect public IP for AllowedIngressCidr if not provided
if [[ -z "$ALLOWED_CIDR" ]]; then
    echo "AllowedIngressCidr not provided, attempting to auto-detect public IP..."
    PUBLIC_IP=""
    
    # Try multiple IP services for reliability
    IP_SERVICES=(
        "https://api.ipify.org"
        "https://ifconfig.me/ip"
        "https://icanhazip.com"
    )
    
    for service in "${IP_SERVICES[@]}"; do
        PUBLIC_IP=$(curl -s --max-time 10 "$service" 2>/dev/null | tr -d '[:space:]')
        if [[ "$PUBLIC_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            break
        fi
        PUBLIC_IP=""
    done
    
    if [[ -n "$PUBLIC_IP" ]] && [[ "$PUBLIC_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        ALLOWED_CIDR="$PUBLIC_IP/32"
        GATHERED_PARAMS+=("AllowedIngressCidr")
        echo "[OK] Auto-detected AllowedIngressCidr: $ALLOWED_CIDR"
    else
        ALLOWED_CIDR=""
    fi
fi

if [[ ${#GATHERED_PARAMS[@]} -gt 0 ]]; then
    echo ""
    echo "Auto-gathered parameters: ${GATHERED_PARAMS[*]}"
fi

# Validate all required parameters are now available
MISSING_PARAMS=()
[[ -z "$REGION" ]] && MISSING_PARAMS+=("--region")
[[ -z "$VPC_ID" ]] && MISSING_PARAMS+=("--vpc-id")
[[ -z "$PUBLIC_SUBNETS" ]] && MISSING_PARAMS+=("--public-subnets")
[[ -z "$ALLOWED_CIDR" ]] && MISSING_PARAMS+=("--allowed-cidr")

if [[ ${#MISSING_PARAMS[@]} -gt 0 ]]; then
    echo ""
    echo "[ERROR] Missing required parameters:"
    for param in "${MISSING_PARAMS[@]}"; do
        echo "  - $param"
    done
    
    echo ""
    echo "Unable to auto-detect all required parameters."
    echo "Please provide these parameters as command-line arguments:"
    echo "  --region          : Your AWS region (e.g., us-east-1, eu-west-1)"
    echo "  --vpc-id          : aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text"
    echo "  --public-subnets  : aws ec2 describe-subnets --filters Name=vpc-id,Values=<VPC_ID> --query 'Subnets[*].SubnetId' --output text | tr '\t' ','"
    echo "  --allowed-cidr    : Your public IP with /32 CIDR (e.g., 1.2.3.4/32)"
    
    echo ""
    echo "Example usage:"
    echo "  ./deploy-fluidity.sh -a deploy --region us-east-1 --vpc-id vpc-abc123 --public-subnets subnet-1,subnet-2 --allowed-cidr 1.2.3.4/32"
    echo ""
    echo "Note: Account ID is automatically detected from your AWS credentials"
    
    echo ""
    echo "For detailed help: ./deploy-fluidity.sh --help"
    echo ""
    exit 1
fi

# Set ContainerImage default if not provided
if [[ -z "$CONTAINER_IMAGE" ]]; then
    CONTAINER_IMAGE="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/fluidity-server:latest"
fi

echo "[OK] All required parameters validated successfully"

# Set Lambda S3 bucket name
LAMBDA_S3_BUCKET="fluidity-lambda-artifacts-${ACCOUNT_ID}-${REGION}"
LAMBDA_S3_KEY_PREFIX="fluidity/"

# Build and upload Lambda functions
echo ""
echo "=== Building Lambda Functions ==="
BUILD_SCRIPT="$SCRIPT_DIR/build-lambdas.sh"
if [[ ! -f "$BUILD_SCRIPT" ]]; then
    echo "[ERROR] Build script not found: $BUILD_SCRIPT"
    exit 1
fi

# Build Lambdas
bash "$BUILD_SCRIPT"

# Ensure S3 bucket exists
echo ""
echo "=== Preparing Lambda Artifacts Bucket ==="
if aws s3 ls "s3://$LAMBDA_S3_BUCKET" --region "$REGION" 2>&1 | grep -q 'NoSuchBucket'; then
    echo "Creating S3 bucket: $LAMBDA_S3_BUCKET"
    aws s3 mb "s3://$LAMBDA_S3_BUCKET" --region "$REGION"
else
    echo "S3 bucket exists: $LAMBDA_S3_BUCKET"
fi

# Upload Lambda packages to S3
echo ""
echo "=== Uploading Lambda Packages to S3 ==="
LAMBDA_BUILD_DIR="$(dirname "$SCRIPT_DIR")/build/lambdas"
for func in wake sleep kill; do
    echo "Uploading ${func}.zip..."
    aws s3 cp "$LAMBDA_BUILD_DIR/${func}.zip" "s3://$LAMBDA_S3_BUCKET/${LAMBDA_S3_KEY_PREFIX}${func}.zip" --region "$REGION"
done
echo "[OK] Lambda packages uploaded"

# Load TLS certificates for CloudFormation
echo "Loading TLS certificates..."

CERTS_DIR="$(dirname "$SCRIPT_DIR")/certs"
SERVER_CERT_PATH="$CERTS_DIR/server.crt"
SERVER_KEY_PATH="$CERTS_DIR/server.key"
CA_CERT_PATH="$CERTS_DIR/ca.crt"

if [[ ! -f "$SERVER_CERT_PATH" ]]; then
    echo "[ERROR] Server certificate not found: $SERVER_CERT_PATH"
    echo "Run the certificate generation script first:"
    echo "  ./scripts/manage-certs.sh"
    exit 1
fi

if [[ ! -f "$SERVER_KEY_PATH" ]]; then
    echo "[ERROR] Server key not found: $SERVER_KEY_PATH"
    exit 1
fi

if [[ ! -f "$CA_CERT_PATH" ]]; then
    echo "[ERROR] CA certificate not found: $CA_CERT_PATH"
    exit 1
fi

# Read certificate files as plain text (CloudFormation will handle storage in Secrets Manager)
CERT_PEM=$(cat "$SERVER_CERT_PATH" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
KEY_PEM=$(cat "$SERVER_KEY_PATH" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
CA_PEM=$(cat "$CA_CERT_PATH" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

echo "[OK] Certificates loaded"

# Skip the parameters file logic since we're using command-line/auto-detected params
if false; then
    # Use parameters file
    PARAMETERS_FILE="${PARAMETERS_FILE:-$CLOUDFORMATION_DIR/params.json}"
    
    if [[ ! -f "$PARAMETERS_FILE" ]]; then
        echo "Error: Parameters file not found: $PARAMETERS_FILE"
        echo ""
        echo "Either provide command-line parameters or create the parameters file."
        exit 1
    fi
    
    # Validate parameters file has been configured
    echo "Validating parameters file..."
    PARAMS_CONTENT=$(cat "$PARAMETERS_FILE")
    PLACEHOLDERS=$(echo "$PARAMS_CONTENT" | grep -oE '<[A-Z_]+>' | sort -u || true)
    
    if [[ -n "$PLACEHOLDERS" ]]; then
        echo ""
        echo "[ERROR] Parameters file contains unconfigured placeholders"
        echo ""
        echo "Found placeholders in $PARAMETERS_FILE :"
        
        echo "$PLACEHOLDERS" | while IFS= read -r placeholder; do
            echo "  - $placeholder"
        done
        
        echo ""
        echo "The params.json file is for reference only. You must provide parameters via command-line arguments:"
        echo "  ./deploy-fluidity.sh -a deploy --account-id <id> --region <region> --vpc-id <vpc> --public-subnets <subnet1,subnet2> --allowed-cidr <ip>/32"
        
        echo ""
        echo "How to get required parameter values:"
        echo "  --account-id      : aws sts get-caller-identity --query Account --output text"
        echo "  --region          : Your AWS region (e.g., us-east-1, eu-west-1)"
        echo "  --vpc-id          : aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text"
        echo "  --public-subnets  : aws ec2 describe-subnets --filters Name=vpc-id,Values=<VPC_ID> --query 'Subnets[*].SubnetId' --output text | tr '\t' ','"
        echo "  --allowed-cidr    : curl -s https://ifconfig.me && echo '/32'"
        
        echo ""
        echo "For detailed help: ./deploy-fluidity.sh --help"
        echo ""
        exit 1
    fi
    
    echo "[OK] Parameters file validated successfully"
fi

if [[ ! -f "$FARGATE_TEMPLATE" ]]; then
    echo "Error: Fargate template not found: $FARGATE_TEMPLATE"
    exit 1
fi

if [[ ! -f "$LAMBDA_TEMPLATE" ]]; then
    echo "Error: Lambda template not found: $LAMBDA_TEMPLATE"
    exit 1
fi

# Helper functions
get_stack_status() {
    local stack_name="$1"
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query 'Stacks[0].StackStatus' \
        --output text 2>/dev/null || echo "DOES_NOT_EXIST"
}

wait_for_stack() {
    local stack_name="$1"
    local operation="$2"  # 'create' or 'update'
    
    echo "Monitoring stack events (Ctrl+C to stop monitoring, stack will continue)..."
    echo ""
    
    local last_event_time=""
    local status=""
    local final_statuses=""
    
    if [[ "$operation" == "create" ]]; then
        final_statuses="CREATE_COMPLETE|CREATE_FAILED|ROLLBACK_COMPLETE|ROLLBACK_FAILED"
    else
        final_statuses="UPDATE_COMPLETE|UPDATE_FAILED|UPDATE_ROLLBACK_COMPLETE|UPDATE_ROLLBACK_FAILED"
    fi
    
    while true; do
        # Get current stack status
        status=$(get_stack_status "$stack_name")
        
        # Check if we've reached a final state
        if echo "$status" | grep -qE "$final_statuses"; then
            echo ""
            if echo "$status" | grep -q "COMPLETE"; then
                echo "[OK] Stack $operation completed: $status"
                return 0
            else
                echo "[ERROR] Stack $operation failed: $status"
                return 1
            fi
        fi
        
        # Get latest events (only new ones)
        local events
        if [[ -z "$last_event_time" ]]; then
            # First iteration - get last 5 events
            events=$(aws cloudformation describe-stack-events \
                --stack-name "$stack_name" \
                --region "$REGION" \
                --max-items 5 \
                --query 'StackEvents[].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
                --output text 2>/dev/null | tail -r 2>/dev/null || tac 2>/dev/null || awk '{a[i++]=$0} END {for (j=i-1; j>=0;) print a[j--] }')
        else
            # Subsequent iterations - get events newer than last seen
            events=$(aws cloudformation describe-stack-events \
                --stack-name "$stack_name" \
                --region "$REGION" \
                --query "StackEvents[?Timestamp>\`$last_event_time\`].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]" \
                --output text 2>/dev/null | tail -r 2>/dev/null || tac 2>/dev/null || awk '{a[i++]=$0} END {for (j=i-1; j>=0;) print a[j--] }')
        fi
        
        # Display new events
        if [[ -n "$events" ]]; then
            while IFS=$'\t' read -r timestamp resource status reason; do
                # Update last seen timestamp
                last_event_time="$timestamp"
                
                # Format and display event
                local short_time=$(echo "$timestamp" | cut -d'T' -f2 | cut -d'.' -f1)
                local display_reason=""
                if [[ -n "$reason" ]] && [[ "$reason" != "None" ]] && [[ "$reason" != "-" ]]; then
                    display_reason=" - $reason"
                fi
                
                # Color code based on status
                if echo "$status" | grep -q "FAILED"; then
                    echo "[$short_time] ❌ $resource: $status$display_reason"
                elif echo "$status" | grep -q "COMPLETE"; then
                    echo "[$short_time] ✓ $resource: $status"
                elif echo "$status" | grep -q "IN_PROGRESS"; then
                    echo "[$short_time] ⏳ $resource: $status"
                else
                    echo "[$short_time] ℹ️  $resource: $status$display_reason"
                fi
            done <<< "$events"
        fi
        
        # Wait before next poll
        sleep 3
    done
}

deploy_stack() {
    local stack_name="$1"
    local template="$2"
    local stack_type="$3"  # 'fargate' or 'lambda'
    
    echo ""
    echo "=== Deploying $stack_name ==="
    
    local status
    status=$(get_stack_status "$stack_name")
    
    # Build parameters based on stack type
    local params_file=""
    local params_arg=""
    
    if [[ "$stack_type" == "fargate" ]]; then
        # Create parameters JSON file for certificates (too large for command-line)
        params_file="/tmp/fluidity-fargate-params-$$.json"
        
        cat > "$params_file" << EOF
[
  {"ParameterKey": "ClusterName", "ParameterValue": "$CLUSTER_NAME"},
  {"ParameterKey": "ServiceName", "ParameterValue": "$SERVICE_NAME"},
  {"ParameterKey": "ContainerImage", "ParameterValue": "$CONTAINER_IMAGE"},
  {"ParameterKey": "ContainerPort", "ParameterValue": "$CONTAINER_PORT"},
  {"ParameterKey": "Cpu", "ParameterValue": "$CPU"},
  {"ParameterKey": "Memory", "ParameterValue": "$MEMORY"},
  {"ParameterKey": "DesiredCount", "ParameterValue": "$DESIRED_COUNT"},
  {"ParameterKey": "VpcId", "ParameterValue": "$VPC_ID"},
  {"ParameterKey": "PublicSubnets", "ParameterValue": "$PUBLIC_SUBNETS"},
  {"ParameterKey": "AllowedIngressCidr", "ParameterValue": "$ALLOWED_CIDR"},
  {"ParameterKey": "AssignPublicIp", "ParameterValue": "ENABLED"},
  {"ParameterKey": "LogGroupName", "ParameterValue": "$LOG_GROUP_NAME"},
  {"ParameterKey": "LogRetentionDays", "ParameterValue": "$LOG_RETENTION_DAYS"},
  {"ParameterKey": "CertPem", "ParameterValue": $(echo "$CERT_PEM" | jq -Rs .)},
  {"ParameterKey": "KeyPem", "ParameterValue": $(echo "$KEY_PEM" | jq -Rs .)},
  {"ParameterKey": "CaPem", "ParameterValue": $(echo "$CA_PEM" | jq -Rs .)}
]
EOF
        params_arg="file://$params_file"
    elif [[ "$stack_type" == "lambda" ]]; then
        # Lambda stack parameters - use JSON file for consistency
        params_file="/tmp/fluidity-lambda-params-$$.json"
        
        cat > "$params_file" << EOF
[
  {"ParameterKey": "LambdaS3Bucket", "ParameterValue": "$LAMBDA_S3_BUCKET"},
  {"ParameterKey": "LambdaS3KeyPrefix", "ParameterValue": "$LAMBDA_S3_KEY_PREFIX"},
  {"ParameterKey": "ECSClusterName", "ParameterValue": "$CLUSTER_NAME"},
  {"ParameterKey": "ECSServiceName", "ParameterValue": "$SERVICE_NAME"},
  {"ParameterKey": "IdleThresholdMinutes", "ParameterValue": "$IDLE_THRESHOLD_MINUTES"},
  {"ParameterKey": "LookbackPeriodMinutes", "ParameterValue": "$LOOKBACK_PERIOD_MINUTES"},
  {"ParameterKey": "SleepCheckIntervalMinutes", "ParameterValue": "$SLEEP_CHECK_INTERVAL_MINUTES"},
  {"ParameterKey": "DailyKillTime", "ParameterValue": "$DAILY_KILL_TIME"},
  {"ParameterKey": "WakeLambdaTimeout", "ParameterValue": "$WAKE_LAMBDA_TIMEOUT"},
  {"ParameterKey": "SleepLambdaTimeout", "ParameterValue": "$SLEEP_LAMBDA_TIMEOUT"},
  {"ParameterKey": "KillLambdaTimeout", "ParameterValue": "$KILL_LAMBDA_TIMEOUT"},
  {"ParameterKey": "APIThrottleBurstLimit", "ParameterValue": "$API_THROTTLE_BURST_LIMIT"},
  {"ParameterKey": "APIThrottleRateLimit", "ParameterValue": "$API_THROTTLE_RATE_LIMIT"},
  {"ParameterKey": "APIQuotaLimit", "ParameterValue": "$API_QUOTA_LIMIT"}
]
EOF
        params_arg="file://$params_file"
    fi
    
    if [[ "$status" == "DOES_NOT_EXIST" ]]; then
        echo "Creating new stack: $stack_name"
        
        aws cloudformation create-stack \
            --stack-name "$stack_name" \
            --template-body "file://$template" \
            --parameters $params_arg \
            --capabilities "$CAPABILITIES" \
            --region "$REGION" \
            --tags \
                "Key=Application,Value=Fluidity" \
                "Key=ManagedBy,Value=CloudFormation" \
            --output text
        
        wait_for_stack "$stack_name" "create"
        
        # Clean up temp file if Fargate
        if [[ -n "$params_file" ]] && [[ -f "$params_file" ]]; then
            rm -f "$params_file"
        fi
        
        echo "[OK] Stack created successfully"
    else
        echo "Updating existing stack: $stack_name (Current status: $status)"
        
        local update_output
        update_output=$(aws cloudformation update-stack \
            --stack-name "$stack_name" \
            --template-body "file://$template" \
            --parameters $params_arg \
            --capabilities "$CAPABILITIES" \
            --region "$REGION" \
            --tags \
                "Key=Application,Value=Fluidity" \
                "Key=ManagedBy,Value=CloudFormation" \
            --output text 2>&1 || true)
        
        if echo "$update_output" | grep -q "No updates are to be performed"; then
            # Clean up temp file
            if [[ -n "$params_file" ]] && [[ -f "$params_file" ]]; then
                rm -f "$params_file"
            fi
            echo "[OK] Stack is already up to date (no changes)"
        else
            wait_for_stack "$stack_name" "update"
            
            # Clean up temp file
            if [[ -n "$params_file" ]] && [[ -f "$params_file" ]]; then
                rm -f "$params_file"
            fi
            
            echo "[OK] Stack updated successfully"
        fi
    fi
}

get_stack_outputs() {
    local stack_name="$1"
    
    local outputs
    outputs=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query 'Stacks[0].Outputs' \
        --output json 2>/dev/null || echo "null")
    
    if [[ "$outputs" == "null" ]] || [[ -z "$outputs" ]]; then
        echo "No outputs found for stack: $stack_name"
    else
        echo ""
        echo "=== Stack Outputs ===" 
        echo "$outputs" | jq -r '.[] | "\(.OutputKey): \(.OutputValue)"'
    fi
}

get_stack_drift_status() {
    local stack_name="$1"
    
    echo ""
    echo "=== Checking Stack Drift ==="
    
    local drift_id
    drift_id=$(aws cloudformation detect-stack-drift \
        --stack-name "$stack_name" \
        --query 'StackDriftDetectionId' \
        --output text)
    
    echo "Drift detection started: $drift_id"
    echo "Checking status..."
    
    sleep 3
    
    local status
    status=$(aws cloudformation describe-stack-drift-detection-status \
        --stack-drift-detection-id "$drift_id" \
        --query 'StackDriftDetectionStatus' \
        --output text)
    
    if [[ "$status" == "DETECTION_COMPLETE" ]]; then
        local drift
        drift=$(aws cloudformation describe-stack-drift-detection-status \
            --stack-drift-detection-id "$drift_id" \
            --query 'StackDriftStatus' \
            --output text)
        
        if [[ "$drift" == "DRIFTED" ]]; then
            echo "[WARNING] DRIFTED: Stack has manual changes"
        elif [[ "$drift" == "IN_SYNC" ]]; then
            echo "[OK] IN_SYNC: Stack matches template"
        else
            echo "Status: $drift"
        fi
    else
        echo "Detection status: $status"
    fi
}

# Main execution
case "$ACTION" in
    deploy)
        deploy_stack "$FARGATE_STACK_NAME" "$FARGATE_TEMPLATE" "fargate"
        deploy_stack "$LAMBDA_STACK_NAME" "$LAMBDA_TEMPLATE" "lambda"
        
        echo ""
        echo "=== Applying Stack Policies ==="
        
        # Apply Fargate stack policy
        FARGATE_STACK_POLICY="$CLOUDFORMATION_DIR/stack-policy-fargate.json"
        if [[ -f "$FARGATE_STACK_POLICY" ]]; then
            echo "Applying policy to Fargate stack..."
            aws cloudformation set-stack-policy \
                --stack-name "$FARGATE_STACK_NAME" \
                --stack-policy-body "file://$FARGATE_STACK_POLICY"
            echo "[OK] Fargate stack policy applied"
        fi
        
        # Apply Lambda stack policy
        LAMBDA_STACK_POLICY="$CLOUDFORMATION_DIR/stack-policy-lambda.json"
        if [[ -f "$LAMBDA_STACK_POLICY" ]]; then
            echo "Applying policy to Lambda stack..."
            aws cloudformation set-stack-policy \
                --stack-name "$LAMBDA_STACK_NAME" \
                --stack-policy-body "file://$LAMBDA_STACK_POLICY"
            echo "[OK] Lambda stack policy applied"
        fi
        
        get_stack_outputs "$FARGATE_STACK_NAME"
        get_stack_outputs "$LAMBDA_STACK_NAME"
        ;;
    delete)
        if [[ "$FORCE" != true ]]; then
            echo "Are you sure you want to DELETE $STACK_NAME? (type 'yes' to confirm)"
            read -r confirm
            if [[ "$confirm" != "yes" ]]; then
                echo "Delete cancelled"
                exit 0
            fi
        fi
        
        echo ""
        echo "=== Deleting $STACK_NAME ==="
        
        # Remove stack policies first (they prevent deletion)
        echo "Removing stack policies..."
        aws cloudformation delete-stack-policy \
            --stack-name "$FARGATE_STACK_NAME" --region "$REGION" 2>/dev/null || true
        aws cloudformation delete-stack-policy \
            --stack-name "$LAMBDA_STACK_NAME" --region "$REGION" 2>/dev/null || true
        
        # Delete CloudFormation stacks
        echo "Deleting CloudFormation stacks..."
        aws cloudformation delete-stack --stack-name "$FARGATE_STACK_NAME" --region "$REGION"
        aws cloudformation delete-stack --stack-name "$LAMBDA_STACK_NAME" --region "$REGION"
        
        echo "Waiting for stacks to be deleted..."
        aws cloudformation wait stack-delete-complete --stack-name "$FARGATE_STACK_NAME" --region "$REGION"
        aws cloudformation wait stack-delete-complete --stack-name "$LAMBDA_STACK_NAME" --region "$REGION"
        echo "[OK] Stacks deleted"
        
        # Clean up Lambda S3 bucket
        echo ""
        echo "=== Cleaning Up Lambda Artifacts ==="
        LAMBDA_S3_BUCKET="fluidity-lambda-artifacts-${ACCOUNT_ID}-${REGION}"
        
        # Check if bucket exists
        if aws s3 ls "s3://$LAMBDA_S3_BUCKET" --region "$REGION" 2>/dev/null; then
            echo "Emptying S3 bucket: $LAMBDA_S3_BUCKET"
            aws s3 rm "s3://$LAMBDA_S3_BUCKET" --recursive --region "$REGION"
            
            echo "Deleting S3 bucket: $LAMBDA_S3_BUCKET"
            aws s3 rb "s3://$LAMBDA_S3_BUCKET" --region "$REGION"
            echo "[OK] Lambda artifacts bucket deleted"
        else
            echo "S3 bucket does not exist or already deleted"
        fi
        
        echo ""
        echo "[OK] All resources deleted successfully"
        ;;
    status)
        echo ""
        echo "=== Stack Status ==="
        
        local fargate_status
        fargate_status=$(get_stack_status "$FARGATE_STACK_NAME")
        local lambda_status
        lambda_status=$(get_stack_status "$LAMBDA_STACK_NAME")
        
        echo "Fargate Stack: $fargate_status"
        echo "Lambda Stack: $lambda_status"
        
        if [[ ! "$fargate_status" =~ DELETE ]] && [[ "$fargate_status" != "DOES_NOT_EXIST" ]]; then
            get_stack_drift_status "$FARGATE_STACK_NAME"
        fi
        ;;
    outputs)
        get_stack_outputs "$FARGATE_STACK_NAME"
        get_stack_outputs "$LAMBDA_STACK_NAME"
        ;;
esac

echo ""
echo "[OK] Operation completed successfully"
