#!/usr/bin/env bash
set -euo pipefail

# deploy-fluidity.sh - Deploy Fluidity infrastructure to AWS
# Usage: ./deploy-fluidity.sh <action> --region <region> --vpc-id <vpc> --public-subnets <subnets> --allowed-cidr <cidr>
# Actions: deploy, delete, status, outputs
# Example: ./deploy-fluidity.sh deploy --region us-east-1 --vpc-id vpc-abc123 --public-subnets subnet-1,subnet-2 --allowed-cidr 1.2.3.4/32

# Defaults
ACTION="${1:-deploy}"
STACK_NAME="fluidity"
FORCE=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUDFORMATION_DIR="$(dirname "$SCRIPT_DIR")/deployments/cloudformation"

# Required parameters
REGION=""
VPC_ID=""
PUBLIC_SUBNETS=""
ALLOWED_CIDR=""

# Parse arguments
shift || true
while [[ $# -gt 0 ]]; do
    case $1 in
        --region) REGION="$2"; shift 2 ;;
        --vpc-id) VPC_ID="$2"; shift 2 ;;
        --public-subnets) PUBLIC_SUBNETS="$2"; shift 2 ;;
        --allowed-cidr) ALLOWED_CIDR="$2"; shift 2 ;;
    -f|--force) FORCE=true; shift ;;
        -h|--help)
            echo "Usage: $0 <action> --region <region> --vpc-id <vpc> --public-subnets <subnets> --allowed-cidr <cidr>"
            echo "Actions: deploy, delete, status, outputs"
            echo "Get parameters:"
            echo "  Region:       Your AWS region (e.g., us-east-1)"
            echo "  VpcId:        aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text"
            echo "  PublicSubnets: aws ec2 describe-subnets --filters Name=vpc-id,Values=<VPC_ID> --query 'Subnets[*].SubnetId' --output text | tr '\t' ','"
            echo "  AllowedCidr:  curl -s ifconfig.me && echo '/32'"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate action
if [[ ! "$ACTION" =~ ^(deploy|delete|status|outputs)$ ]]; then
    echo "Error: Action must be 'deploy', 'delete', 'status', or 'outputs'"
    exit 1
fi

# Check AWS CLI and get Account ID
echo "Checking AWS CLI..."
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI not found. Install from: https://aws.amazon.com/cli/"
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>&1)
if [[ $? -ne 0 ]]; then
    echo "Error: AWS CLI not configured. Run: aws configure"
    exit 1
fi

echo "Account: $ACCOUNT_ID"

# Auto-detect and prompt for required parameters (deploy action only)
if [[ "$ACTION" == "deploy" ]]; then
    # Try to auto-detect Region
    if [[ -z "$REGION" ]]; then
        echo ""
        echo "Attempting to auto-detect Region..."
        REGION=$(aws configure get region 2>&1)
        if [[ $? -eq 0 && -n "$REGION" ]]; then
            echo "Auto-detected Region: $REGION"
        else
            REGION=""
            echo "Command: aws configure get region"
            read -p "Enter AWS Region (e.g., us-east-1): " REGION
            if [[ -z "$REGION" ]]; then
                echo "Error: Region is required"
                exit 1
            fi
        fi
    fi
    
    # Try to auto-detect VpcId
    if [[ -z "$VPC_ID" ]]; then
        echo ""
        echo "Attempting to auto-detect default VPC..."
        VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text 2>&1)
        if [[ $? -eq 0 && "$VPC_ID" != "None" && -n "$VPC_ID" ]]; then
            echo "Auto-detected VpcId: $VPC_ID"
        else
            VPC_ID=""
            echo "Command: aws ec2 describe-vpcs --region $REGION --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text"
            read -p "Enter VPC ID (e.g., vpc-abc123): " VPC_ID
            if [[ -z "$VPC_ID" ]]; then
                echo "Error: VpcId is required"
                exit 1
            fi
        fi
    fi
    
    # Try to auto-detect PublicSubnets
    if [[ -z "$PUBLIC_SUBNETS" ]]; then
        echo ""
        echo "Attempting to auto-detect public subnets..."
        SUBNET_LIST=$(aws ec2 describe-subnets --region "$REGION" --filters Name=vpc-id,Values="$VPC_ID" --query 'Subnets[*].SubnetId' --output text 2>&1)
        if [[ $? -eq 0 && -n "$SUBNET_LIST" ]]; then
            PUBLIC_SUBNETS=$(echo "$SUBNET_LIST" | tr '\t' ',')
            echo "Auto-detected PublicSubnets: $PUBLIC_SUBNETS"
        else
            PUBLIC_SUBNETS=""
            echo "Command: aws ec2 describe-subnets --region $REGION --filters Name=vpc-id,Values=$VPC_ID --query 'Subnets[*].SubnetId' --output text"
            read -p "Enter Public Subnet IDs (comma-separated, minimum 2): " PUBLIC_SUBNETS
            if [[ -z "$PUBLIC_SUBNETS" ]]; then
                echo "Error: PublicSubnets is required"
                exit 1
            fi
        fi
    fi
    
    # Try to auto-detect public IP for AllowedIngressCidr
    if [[ -z "$ALLOWED_CIDR" ]]; then
        echo ""
        echo "Attempting to auto-detect your public IP..."
        PUBLIC_IP=$(curl -s --max-time 10 https://icanhazip.com 2>/dev/null)
        if [[ $? -eq 0 && "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ALLOWED_CIDR="${PUBLIC_IP}/32"
            echo "Auto-detected AllowedIngressCidr: $ALLOWED_CIDR"
        else
            echo "Could not auto-detect public IP. Get it manually:"
            echo "  Command: curl -s https://icanhazip.com && echo '/32'"
            echo "  Or visit: https://icanhazip.com"
            read -p "Enter Allowed Ingress CIDR (e.g., 1.2.3.4/32): " ALLOWED_CIDR
            if [[ -z "$ALLOWED_CIDR" ]]; then
                echo "Error: AllowedIngressCidr is required"
                exit 1
            fi
        fi
    fi
    
    echo ""
    echo "Deployment Parameters:"
    echo "  Region:             $REGION"
    echo "  VpcId:              $VPC_ID"
    echo "  PublicSubnets:      $PUBLIC_SUBNETS"
    echo "  AllowedIngressCidr: $ALLOWED_CIDR"
    echo ""
fi

# Set Lambda S3 bucket name
LAMBDA_S3_BUCKET="fluidity-lambda-artifacts-${ACCOUNT_ID}-${REGION}"
LAMBDA_S3_KEY_PREFIX="fluidity/"

# Set stack names and templates
FARGATE_STACK_NAME="${STACK_NAME}-fargate"
LAMBDA_STACK_NAME="${STACK_NAME}-lambda"
FARGATE_TEMPLATE="$CLOUDFORMATION_DIR/fargate.yaml"
LAMBDA_TEMPLATE="$CLOUDFORMATION_DIR/lambda.yaml"

# Load certificates
echo "Loading certificates..."
CERTS_DIR="$(dirname "$SCRIPT_DIR")/certs"
if [[ ! -f "$CERTS_DIR/server.crt" ]] || [[ ! -f "$CERTS_DIR/server.key" ]] || [[ ! -f "$CERTS_DIR/ca.crt" ]]; then
    echo "Certificates not found in $CERTS_DIR"
    echo "Generating certificates automatically..."
    if bash "$SCRIPT_DIR/manage-certs.sh"; then
        echo "✓ Certificates generated successfully"
    else
        echo "Error: Certificate generation failed"
        echo "Run: ./scripts/manage-certs.sh"
        exit 1
    fi
fi

# Create or update Secrets Manager secret with certificates
SECRET_NAME="fluidity-certificates"
echo "Creating/updating Secrets Manager secret..."

# Build JSON with properly escaped certificates
SECRET_JSON=$(jq -n \
  --arg cert "$(cat "$CERTS_DIR/server.crt")" \
  --arg key "$(cat "$CERTS_DIR/server.key")" \
  --arg ca "$(cat "$CERTS_DIR/ca.crt")" \
  '{cert_pem: $cert, key_pem: $key, ca_pem: $ca}')

# Try to create secret, if it exists, update it
if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" &>/dev/null; then
    echo "Updating existing secret..."
    aws secretsmanager put-secret-value \
        --secret-id "$SECRET_NAME" \
        --secret-string "$SECRET_JSON" \
        --region "$REGION" > /dev/null
else
    echo "Creating new secret..."
    aws secretsmanager create-secret \
        --name "$SECRET_NAME" \
        --description "TLS certificates for Fluidity server" \
        --secret-string "$SECRET_JSON" \
        --region "$REGION" \
        --tags Key=Application,Value=Fluidity Key=ManagedBy,Value=DeployScript > /dev/null
fi

SECRET_ARN=$(aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" --query 'ARN' --output text)
echo "✓ Secret ready: $SECRET_ARN"

# Helper functions
print_final_instructions() {
    echo ""
    echo "=== Fargate Stack Outputs ==="
    aws cloudformation describe-stacks --stack-name "$FARGATE_STACK_NAME" --region "$REGION" --query 'Stacks[0].Outputs' --output text | cat || echo "(No outputs)"
    echo ""
    echo "=== Lambda Stack Outputs ==="
    aws cloudformation describe-stacks --stack-name "$LAMBDA_STACK_NAME" --region "$REGION" --query 'Stacks[0].Outputs' --output text | cat || echo "(No outputs)"
    echo -e "\n=== Fluidity Lambda API Deployment Complete ==="
    API_ENDPOINT=$(aws cloudformation describe-stacks --stack-name fluidity-lambda --query 'Stacks[0].Outputs[?OutputKey==`KillAPIEndpoint`].OutputValue' --output text 2>/dev/null)
    API_KEY_ID=$(aws cloudformation describe-stacks --stack-name fluidity-lambda --query 'Stacks[0].Outputs[?OutputKey==`APIKeyId`].OutputValue' --output text 2>/dev/null)
    echo "Kill API Endpoint: $API_ENDPOINT"
    echo "API Key ID: $API_KEY_ID"
    echo "To retrieve the API key value, run:"
    echo "  aws apigateway get-api-key --api-key $API_KEY_ID --include-value --region $REGION"
    echo -e "\nNext steps:"
    echo "1. Configure your agent with the Kill API endpoint and API key."
    echo "2. You can set these in the agent config file or pass as arguments."
    echo "Example agent config snippet:"
    echo "kill_api_endpoint: '$API_ENDPOINT'"
    echo "api_key: '<API_KEY_VALUE>'"
}
deploy_stack() {
    local stack_name="$1"
    local template="$2"
    local params_file="$3"
    
    echo "Deploying $stack_name..."
    
    # Check if stack exists
        if aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" &>/dev/null; then
            aws cloudformation update-stack \
                --stack-name "$stack_name" \
                --template-body file://"$template" \
                --parameters file://"$params_file" \
                --capabilities CAPABILITY_NAMED_IAM \
                --region "$REGION" \
                --tags Key=Application,Value=Fluidity Key=ManagedBy,Value=CloudFormation > /dev/null
            aws cloudformation wait stack-update-complete --stack-name "$stack_name" --region "$REGION"
        else
            aws cloudformation create-stack \
                --stack-name "$stack_name" \
                --template-body file://"$template" \
                --parameters file://"$params_file" \
                --capabilities CAPABILITY_NAMED_IAM \
                --region "$REGION" \
                --tags Key=Application,Value=Fluidity Key=ManagedBy,Value=CloudFormation > /dev/null
            aws cloudformation wait stack-create-complete --stack-name "$stack_name" --region "$REGION"
    fi
    echo "$stack_name: deployment finished"
}

delete_stack() {
    local stack_name="$1"
    echo "Deleting $stack_name..."
    aws cloudformation delete-stack --stack-name "$stack_name" --region "$REGION"
    echo "Waiting for $stack_name deletion..."
    aws cloudformation wait stack-delete-complete --stack-name "$stack_name" --region "$REGION" || true
}

# Main execution
case "$ACTION" in
    deploy)
        echo ""
        echo "========================================"
        echo "Building Fluidity Components"
        echo "========================================"
        echo ""

        error_log=""

        # PHASE 1: Build and upload Lambda ZIPs
    echo "Building Lambda functions..."
    BUILD_VERSION=$(date +%Y%m%d%H%M%S)
    # Building Lambda functions
        BUILD_VERSION="$BUILD_VERSION" bash "$SCRIPT_DIR/build-lambdas.sh"
        if [ $? -ne 0 ]; then
            error_log+=$'\nError: Lambda build failed'
        else
            echo "✓ Lambda functions built successfully"
        fi
        echo ""
        # Ensure S3 bucket exists
        if ! aws s3 ls "s3://$LAMBDA_S3_BUCKET" --region "$REGION" &>/dev/null; then
            echo "Creating S3 bucket: $LAMBDA_S3_BUCKET"
            aws s3 mb "s3://$LAMBDA_S3_BUCKET" --region "$REGION" || error_log+=$'\nError: Failed to create S3 bucket'
        fi
        # Upload Lambda packages
        echo "Uploading Lambda packages..."
        LAMBDA_BUILD_DIR="$(dirname "$SCRIPT_DIR")/build/lambdas"
        for func in wake sleep kill; do
            ZIP_NAME="${func}-${BUILD_VERSION}.zip"
            aws s3 cp "$LAMBDA_BUILD_DIR/$ZIP_NAME" "s3://$LAMBDA_S3_BUCKET/${LAMBDA_S3_KEY_PREFIX}$ZIP_NAME" --region "$REGION" || error_log+=$"\nError: Failed to upload $ZIP_NAME"
        done
    echo "Uploading Lambda packages to S3..."
        max_total_wait=60
        sleep_interval=2
        start_time=$(date +%s)
        while true; do
            all_exist=true
            for func in wake sleep kill; do
                ZIP_NAME="${func}-${BUILD_VERSION}.zip"
                S3_KEY="${LAMBDA_S3_KEY_PREFIX}$ZIP_NAME"
                aws s3api head-object --bucket "$LAMBDA_S3_BUCKET" --key "$S3_KEY" --region "$REGION" >/dev/null 2>&1
                if [ $? -eq 0 ]; then
                    echo "✓ S3 object exists: $S3_KEY"
                else
                    echo "Waiting for S3 object: $S3_KEY"
                    all_exist=false
                fi
            done
            if [ "$all_exist" = true ]; then
                echo "All S3 Lambda ZIPs found."
                break
            fi
            now=$(date +%s)
            elapsed=$((now - start_time))
            if [ $elapsed -ge $max_total_wait ]; then
                error_log+=$'\nERROR: Not all S3 Lambda ZIPs found after $max_total_wait seconds. Aborting deploy.'
                break
            fi
            sleep $sleep_interval
        done

        # PHASE 2: Build and deploy Fargate
    echo "Building core binaries (server and agent)..."
    # Building core binaries (server and agent)
        BUILD_VERSION="$BUILD_VERSION" bash "$SCRIPT_DIR/build-core.sh" --linux
        if [ $? -ne 0 ]; then
            error_log+=$'\nError: Core build failed'
        else
            echo "✓ Core binaries built successfully"
        fi
        echo ""
    echo "Building and pushing Docker image to ECR..."
        ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
        ECR_REPO="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/fluidity-server"
        SERVER_IMAGE_TAG="$BUILD_VERSION"
        if ! aws ecr describe-repositories --repository-names fluidity-server --region "$REGION" &>/dev/null; then
            echo "Note: ECR repository will be created by CloudFormation stack"
            echo "Creating temporary ECR repository for initial deployment..."
            aws ecr create-repository --repository-name fluidity-server --region "$REGION" > /dev/null 2>&1 || true
        fi
        echo "Logging in to ECR..."
        aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
        echo "Building Docker image..."
        docker build -f "$SCRIPT_DIR/../deployments/server/Dockerfile" -t fluidity-server:$SERVER_IMAGE_TAG "$SCRIPT_DIR/.."
        if [ $? -ne 0 ]; then
            error_log+=$'\nError: Docker build failed'
        fi
    echo "Tagging and pushing Docker image to ECR..."
        docker tag fluidity-server:$SERVER_IMAGE_TAG "$ECR_REPO:$SERVER_IMAGE_TAG"
        docker push "$ECR_REPO:$SERVER_IMAGE_TAG"
        if [ $? -ne 0 ]; then
            error_log+=$'\nError: Docker push to ECR failed'
        else
            echo "✓ Docker image pushed to ECR"
        fi
        echo ""

        # Create Fargate parameters file
        FARGATE_PARAMS="/tmp/fluidity-fargate-params-$$.json"
        cat > "$FARGATE_PARAMS" << EOF
[
  {"ParameterKey": "ClusterName", "ParameterValue": "fluidity"},
  {"ParameterKey": "ServiceName", "ParameterValue": "fluidity-server"},
  {"ParameterKey": "ContainerImage", "ParameterValue": "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/fluidity-server:$SERVER_IMAGE_TAG"},
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
  {"ParameterKey": "CertificatesSecretArn", "ParameterValue": "$SECRET_ARN"}
]
EOF

        # PHASE 3: Deploy Lambda stack
        echo "=== PHASE 3: Deploy Lambda stack ==="
        # Create Lambda parameters file
        LAMBDA_PARAMS="/tmp/fluidity-lambda-params-$$.json"
        cat > "$LAMBDA_PARAMS" << EOF
[
  {"ParameterKey": "LambdaS3Bucket", "ParameterValue": "$LAMBDA_S3_BUCKET"},
  {"ParameterKey": "LambdaS3KeyPrefix", "ParameterValue": "$LAMBDA_S3_KEY_PREFIX$BUILD_VERSION/"},
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

        # Always print final instructions, even on error
        trap print_final_instructions EXIT
        # Deploy stacks
        deploy_stack "$FARGATE_STACK_NAME" "$FARGATE_TEMPLATE" "$FARGATE_PARAMS" || error_log+=$'\nError: Fargate stack deployment failed'
        # Retry Lambda stack deployment if rollback or failure detected
        max_lambda_retries=3
        lambda_attempt=1
        while [ $lambda_attempt -le $max_lambda_retries ]; do
            lambda_status=$(aws cloudformation describe-stacks --stack-name "$LAMBDA_STACK_NAME" --region "$REGION" --query 'Stacks[0].StackStatus' --output text 2>/dev/null)
            if [[ "$lambda_status" == "ROLLBACK_COMPLETE" ]]; then
                echo "Lambda stack is in ROLLBACK_COMPLETE state. Deleting before retry..."
                aws cloudformation delete-stack --stack-name "$LAMBDA_STACK_NAME" --region "$REGION"
                aws cloudformation wait stack-delete-complete --stack-name "$LAMBDA_STACK_NAME" --region "$REGION" || true
                sleep 5
            fi
            deploy_stack "$LAMBDA_STACK_NAME" "$LAMBDA_TEMPLATE" "$LAMBDA_PARAMS" || error_log+=$'\nError: Lambda stack deployment failed'
            lambda_status=$(aws cloudformation describe-stacks --stack-name "$LAMBDA_STACK_NAME" --region "$REGION" --query 'Stacks[0].StackStatus' --output text 2>/dev/null)
            if [[ "$lambda_status" == *"ROLLBACK"* ]] || [[ "$lambda_status" == *"FAILED"* ]]; then
                echo "Lambda stack failed or rolled back (attempt $lambda_attempt/$max_lambda_retries). Retrying..."
                aws cloudformation delete-stack --stack-name "$LAMBDA_STACK_NAME" --region "$REGION"
                aws cloudformation wait stack-delete-complete --stack-name "$LAMBDA_STACK_NAME" --region "$REGION" || true
                sleep 5
                lambda_attempt=$((lambda_attempt+1))
            else
                break
            fi
        done
        if [[ "$lambda_status" == *"ROLLBACK"* ]] || [[ "$lambda_status" == *"FAILED"* ]]; then
            error_log+=$'\nERROR: Lambda stack failed after $max_lambda_retries attempts.'
        fi
        # Clean up temp files
        rm -f "$FARGATE_PARAMS" "$LAMBDA_PARAMS"

        # Final output section with border
        echo -e "\n============================================================"
        echo "FINAL OUTPUTS AND SECRETS:"
        print_final_instructions
        if [ -n "$error_log" ]; then
            echo -e "\nFAILURE LOG:"
            echo "$error_log"
        fi
        if [ -n "$error_log" ]; then
            echo "$error_log"
            print_final_instructions
            exit 1
        fi
        echo "✓ Lambda functions built successfully"
        echo ""
        # Ensure S3 bucket exists
        if ! aws s3 ls "s3://$LAMBDA_S3_BUCKET" --region "$REGION" &>/dev/null; then
            echo "Creating S3 bucket: $LAMBDA_S3_BUCKET"
            aws s3 mb "s3://$LAMBDA_S3_BUCKET" --region "$REGION" || error_log+=$'\nError: Failed to create S3 bucket'
        fi
        # Upload Lambda packages
        echo "Uploading Lambda packages..."
        LAMBDA_BUILD_DIR="$(dirname "$SCRIPT_DIR")/build/lambdas"
        for func in wake sleep kill; do
            ZIP_NAME="${func}-${BUILD_VERSION}.zip"
            aws s3 cp "$LAMBDA_BUILD_DIR/$ZIP_NAME" "s3://$LAMBDA_S3_BUCKET/${LAMBDA_S3_KEY_PREFIX}$ZIP_NAME" --region "$REGION" || error_log+=$"\nError: Failed to upload $ZIP_NAME"
        done
        echo "Verifying S3 Lambda ZIPs exist before continuing..."
        max_total_wait=60
        sleep_interval=2
        start_time=$(date +%s)
        while true; do
            all_exist=true
            for func in wake sleep kill; do
                ZIP_NAME="${func}-${BUILD_VERSION}.zip"
                S3_KEY="${LAMBDA_S3_KEY_PREFIX}$ZIP_NAME"
                aws s3api head-object --bucket "$LAMBDA_S3_BUCKET" --key "$S3_KEY" --region "$REGION" >/dev/null 2>&1
                if [ $? -eq 0 ]; then
                    echo "✓ S3 object exists: $S3_KEY"
                else
                    echo "Waiting for S3 object: $S3_KEY"
                    all_exist=false
                fi
            done
            if [ "$all_exist" = true ]; then
                echo "All S3 Lambda ZIPs found."
                break
            fi
            now=$(date +%s)
            elapsed=$((now - start_time))
            if [ $elapsed -ge $max_total_wait ]; then
                error_log+=$'\nERROR: Not all S3 Lambda ZIPs found after $max_total_wait seconds. Aborting deploy.'
                echo "$error_log"
                print_final_instructions
                exit 1
            fi
            sleep $sleep_interval
        done

        # PHASE 2: Build and deploy Fargate
        echo "=== PHASE 2: Build and deploy Fargate ==="
        echo "Building core binaries (server and agent)..."
        BUILD_VERSION="$BUILD_VERSION" bash "$SCRIPT_DIR/build-core.sh" --linux || error_log+=$'\nError: Core build failed'
        if [ -n "$error_log" ]; then
            echo "$error_log"
            print_final_instructions
            exit 1
        fi
        echo "✓ Core binaries built successfully"
        echo ""
        echo "Building and pushing Docker image to ECR..."
        ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
        ECR_REPO="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/fluidity-server"
        SERVER_IMAGE_TAG="$BUILD_VERSION"
        if ! aws ecr describe-repositories --repository-names fluidity-server --region "$REGION" &>/dev/null; then
            echo "Note: ECR repository will be created by CloudFormation stack"
            echo "Creating temporary ECR repository for initial deployment..."
            aws ecr create-repository --repository-name fluidity-server --region "$REGION" > /dev/null 2>&1 || true
        fi
        echo "Logging in to ECR..."
        aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
        echo "Building Docker image..."
        docker build -f "$SCRIPT_DIR/../deployments/server/Dockerfile" -t fluidity-server:$SERVER_IMAGE_TAG "$SCRIPT_DIR/.."
        echo "Tagging and pushing to ECR..."
        docker tag fluidity-server:$SERVER_IMAGE_TAG "$ECR_REPO:$SERVER_IMAGE_TAG"
        docker push "$ECR_REPO:$SERVER_IMAGE_TAG"
    echo "Docker image pushed to ECR."

        # Create Fargate parameters file
        FARGATE_PARAMS="/tmp/fluidity-fargate-params-$$.json"
        cat > "$FARGATE_PARAMS" << EOF
[
  {"ParameterKey": "ClusterName", "ParameterValue": "fluidity"},
  {"ParameterKey": "ServiceName", "ParameterValue": "fluidity-server"},
    {"ParameterKey": "ContainerImage", "ParameterValue": "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/fluidity-server:$SERVER_IMAGE_TAG"},
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
  {"ParameterKey": "CertificatesSecretArn", "ParameterValue": "$SECRET_ARN"}
]
EOF

        # PHASE 3: Deploy Lambda stack
    echo "Deploying Lambda stack..."
        # Create Lambda parameters file
        LAMBDA_PARAMS="/tmp/fluidity-lambda-params-$$.json"
        cat > "$LAMBDA_PARAMS" << EOF
[
  {"ParameterKey": "LambdaS3Bucket", "ParameterValue": "$LAMBDA_S3_BUCKET"},
  {"ParameterKey": "LambdaS3KeyPrefix", "ParameterValue": "$LAMBDA_S3_KEY_PREFIX$BUILD_VERSION/"},
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

        # Always print final instructions, even on error
        trap print_final_instructions EXIT
        # Deploy stacks
        deploy_stack "$FARGATE_STACK_NAME" "$FARGATE_TEMPLATE" "$FARGATE_PARAMS" || error_log+=$'\nError: Fargate stack deployment failed'
        # Retry Lambda stack deployment if rollback or failure detected
        max_lambda_retries=3
        lambda_attempt=1
        while [ $lambda_attempt -le $max_lambda_retries ]; do
            # Check if stack exists and is in ROLLBACK_COMPLETE state
            lambda_status=$(aws cloudformation describe-stacks --stack-name "$LAMBDA_STACK_NAME" --region "$REGION" --query 'Stacks[0].StackStatus' --output text 2>/dev/null)
            if [[ "$lambda_status" == "ROLLBACK_COMPLETE" ]]; then
                echo "Lambda stack is in ROLLBACK_COMPLETE state. Deleting before retry..."
                aws cloudformation delete-stack --stack-name "$LAMBDA_STACK_NAME" --region "$REGION"
                aws cloudformation wait stack-delete-complete --stack-name "$LAMBDA_STACK_NAME" --region "$REGION" || true
                sleep 5
            fi
            deploy_stack "$LAMBDA_STACK_NAME" "$LAMBDA_TEMPLATE" "$LAMBDA_PARAMS" || error_log+=$'\nError: Lambda stack deployment failed'
            lambda_status=$(aws cloudformation describe-stacks --stack-name "$LAMBDA_STACK_NAME" --region "$REGION" --query 'Stacks[0].StackStatus' --output text 2>/dev/null)
            if [[ "$lambda_status" == *"ROLLBACK"* ]] || [[ "$lambda_status" == *"FAILED"* ]]; then
                echo "Lambda stack failed or rolled back (attempt $lambda_attempt/$max_lambda_retries). Retrying..."
                aws cloudformation delete-stack --stack-name "$LAMBDA_STACK_NAME" --region "$REGION"
                aws cloudformation wait stack-delete-complete --stack-name "$LAMBDA_STACK_NAME" --region "$REGION" || true
                sleep 5
                lambda_attempt=$((lambda_attempt+1))
            else
                break
            fi
        done
        if [[ "$lambda_status" == *"ROLLBACK"* ]] || [[ "$lambda_status" == *"FAILED"* ]]; then
            error_log+=$'\nERROR: Lambda stack failed after $max_lambda_retries attempts.'
        fi
        # Clean up temp files
        rm -f "$FARGATE_PARAMS" "$LAMBDA_PARAMS"

        # Final output section with border
        echo -e "\n--------------"
        if [ -n "$error_log" ]; then
            echo "Failure..."
            echo "--------------"
        fi
    print_final_instructions

