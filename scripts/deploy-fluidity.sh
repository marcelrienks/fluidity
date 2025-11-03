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
    echo "Error: Certificates not found in $CERTS_DIR"
    echo "Run: ./scripts/manage-certs.sh"
    exit 1
fi

CERT_PEM=$(cat "$CERTS_DIR/server.crt" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
KEY_PEM=$(cat "$CERTS_DIR/server.key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
CA_PEM=$(cat "$CERTS_DIR/ca.crt" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

# Helper functions
deploy_stack() {
    local stack_name="$1"
    local template="$2"
    local params_file="$3"
    
    echo "Deploying $stack_name..."
    
    # Check if stack exists
    if aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" &>/dev/null; then
        echo "Updating existing stack..."
        aws cloudformation update-stack \
            --stack-name "$stack_name" \
            --template-body file://"$template" \
            --parameters file://"$params_file" \
            --capabilities CAPABILITY_NAMED_IAM \
            --region "$REGION" \
            --tags Key=Application,Value=Fluidity Key=ManagedBy,Value=CloudFormation 2>&1 | tee /tmp/cfn-update.log
        
        if grep -q "No updates are to be performed" /tmp/cfn-update.log; then
            echo "No changes detected"
        else
            echo "Waiting for stack update..."
            echo "Monitor progress: https://console.aws.amazon.com/cloudformation/home?region=$REGION#/stacks"
            
            # Poll for stack events
            last_event_time=""
            while true; do
                stack_status=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" --query 'Stacks[0].StackStatus' --output text 2>&1)
                
                # Get new events
                if [ -z "$last_event_time" ]; then
                    events=$(aws cloudformation describe-stack-events --stack-name "$stack_name" --region "$REGION" --max-items 10 --query 'StackEvents[*].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]' --output json 2>&1)
                    events=$(echo "$events" | jq -r 'reverse | .[] | @tsv')
                else
                    events=$(aws cloudformation describe-stack-events --stack-name "$stack_name" --region "$REGION" --query "StackEvents[?Timestamp>'$last_event_time'].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]" --output json 2>&1)
                    events=$(echo "$events" | jq -r 'reverse | .[] | @tsv')
                fi
                
                # Display events
                if [ -n "$events" ]; then
                    while IFS=$'\t' read -r timestamp resource status reason; do
                        last_event_time="$timestamp"
                        short_time=$(date -d "$timestamp" "+%H:%M:%S" 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "$timestamp" "+%H:%M:%S" 2>/dev/null || echo "$timestamp")
                        
                        if [[ "$status" == *"FAILED"* ]] || [[ "$status" == *"ROLLBACK"* ]]; then
                            echo -e "\033[0;31m[$short_time] $resource - $status${reason:+: $reason}\033[0m"
                        elif [[ "$status" == *"COMPLETE"* ]]; then
                            echo -e "\033[0;32m[$short_time] $resource - $status\033[0m"
                        else
                            echo -e "\033[0;33m[$short_time] $resource - $status\033[0m"
                        fi
                    done <<< "$events"
                fi
                
                # Check if stack is done
                if [[ "$stack_status" == *"COMPLETE" ]] || [[ "$stack_status" == *"FAILED" ]]; then
                    if [[ "$stack_status" != "UPDATE_COMPLETE" ]]; then
                        echo "Stack update ended with status: $stack_status"
                        return 1
                    fi
                    break
                fi
                
                sleep 5
            done
        fi
    else
        echo "Creating new stack..."
        aws cloudformation create-stack \
            --stack-name "$stack_name" \
            --template-body file://"$template" \
            --parameters file://"$params_file" \
            --capabilities CAPABILITY_NAMED_IAM \
            --region "$REGION" \
            --tags Key=Application,Value=Fluidity Key=ManagedBy,Value=CloudFormation
        
        echo "Waiting for stack creation..."
        echo "Monitor progress: https://console.aws.amazon.com/cloudformation/home?region=$REGION#/stacks"
        
        # Poll for stack events
        last_event_time=""
        while true; do
            stack_status=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" --query 'Stacks[0].StackStatus' --output text 2>&1)
            
            # Get new events
            if [ -z "$last_event_time" ]; then
                events=$(aws cloudformation describe-stack-events --stack-name "$stack_name" --region "$REGION" --max-items 10 --query 'StackEvents[*].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]' --output json 2>&1)
                events=$(echo "$events" | jq -r 'reverse | .[] | @tsv')
            else
                events=$(aws cloudformation describe-stack-events --stack-name "$stack_name" --region "$REGION" --query "StackEvents[?Timestamp>'$last_event_time'].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]" --output json 2>&1)
                events=$(echo "$events" | jq -r 'reverse | .[] | @tsv')
            fi
            
            # Display events
            if [ -n "$events" ]; then
                while IFS=$'\t' read -r timestamp resource status reason; do
                    last_event_time="$timestamp"
                    short_time=$(date -d "$timestamp" "+%H:%M:%S" 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "$timestamp" "+%H:%M:%S" 2>/dev/null || echo "$timestamp")
                    
                    if [[ "$status" == *"FAILED"* ]] || [[ "$status" == *"ROLLBACK"* ]]; then
                        echo -e "\033[0;31m[$short_time] $resource - $status${reason:+: $reason}\033[0m"
                    elif [[ "$status" == *"COMPLETE"* ]]; then
                        echo -e "\033[0;32m[$short_time] $resource - $status\033[0m"
                    else
                        echo -e "\033[0;33m[$short_time] $resource - $status\033[0m"
                    fi
                done <<< "$events"
            fi
            
            # Check if stack is done
            if [[ "$stack_status" == *"COMPLETE" ]] || [[ "$stack_status" == *"FAILED" ]]; then
                if [[ "$stack_status" != "CREATE_COMPLETE" ]]; then
                    echo "Stack creation ended with status: $stack_status"
                    return 1
                fi
                break
            fi
            
            sleep 5
        done
    fi
    
    echo "$stack_name deployed successfully"
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
        # Build Lambda functions
        echo "Building Lambda functions..."
        bash "$SCRIPT_DIR/build-lambdas.sh"
        
        # Ensure S3 bucket exists
        if ! aws s3 ls "s3://$LAMBDA_S3_BUCKET" --region "$REGION" &>/dev/null; then
            echo "Creating S3 bucket: $LAMBDA_S3_BUCKET"
            aws s3 mb "s3://$LAMBDA_S3_BUCKET" --region "$REGION"
        fi
        
        # Upload Lambda packages
        echo "Uploading Lambda packages..."
        LAMBDA_BUILD_DIR="$(dirname "$SCRIPT_DIR")/build/lambdas"
        for func in wake sleep kill; do
            aws s3 cp "$LAMBDA_BUILD_DIR/${func}.zip" "s3://$LAMBDA_S3_BUCKET/${LAMBDA_S3_KEY_PREFIX}${func}.zip" --region "$REGION"
        done
        
        # Create Fargate parameters file
        FARGATE_PARAMS="/tmp/fluidity-fargate-params-$$.json"
        cat > "$FARGATE_PARAMS" << EOF
[
  {"ParameterKey": "ClusterName", "ParameterValue": "fluidity"},
  {"ParameterKey": "ServiceName", "ParameterValue": "fluidity-server"},
  {"ParameterKey": "ContainerImage", "ParameterValue": "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/fluidity-server:latest"},
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
  {"ParameterKey": "CertPem", "ParameterValue": $(echo "$CERT_PEM" | jq -Rs .)},
  {"ParameterKey": "KeyPem", "ParameterValue": $(echo "$KEY_PEM" | jq -Rs .)},
  {"ParameterKey": "CaPem", "ParameterValue": $(echo "$CA_PEM" | jq -Rs .)}
]
EOF
        
        # Create Lambda parameters file
        LAMBDA_PARAMS="/tmp/fluidity-lambda-params-$$.json"
        cat > "$LAMBDA_PARAMS" << EOF
[
  {"ParameterKey": "LambdaS3Bucket", "ParameterValue": "$LAMBDA_S3_BUCKET"},
  {"ParameterKey": "LambdaS3KeyPrefix", "ParameterValue": "$LAMBDA_S3_KEY_PREFIX"},
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
        
        # Deploy stacks
        deploy_stack "$FARGATE_STACK_NAME" "$FARGATE_TEMPLATE" "$FARGATE_PARAMS"
        deploy_stack "$LAMBDA_STACK_NAME" "$LAMBDA_TEMPLATE" "$LAMBDA_PARAMS"
        
        # Clean up temp files
        rm -f "$FARGATE_PARAMS" "$LAMBDA_PARAMS"
        
        # Show outputs
        echo ""
        echo "=== Fargate Stack Outputs ==="
        aws cloudformation describe-stacks --stack-name "$FARGATE_STACK_NAME" --region "$REGION" --query 'Stacks[0].Outputs' --output table
        echo ""
        echo "=== Lambda Stack Outputs ==="
        aws cloudformation describe-stacks --stack-name "$LAMBDA_STACK_NAME" --region "$REGION" --query 'Stacks[0].Outputs' --output table
        ;;
        
    delete)
        if [[ "$FORCE" != true ]]; then
            read -p "Delete $STACK_NAME? Type 'yes' to confirm: " confirm
            [[ "$confirm" != "yes" ]] && echo "Cancelled" && exit 0
        fi
        
        delete_stack "$LAMBDA_STACK_NAME"
        delete_stack "$FARGATE_STACK_NAME"
        
        # Clean up S3 bucket
        if aws s3 ls "s3://$LAMBDA_S3_BUCKET" --region "$REGION" &>/dev/null; then
            echo "Deleting S3 bucket contents..."
            aws s3 rm "s3://$LAMBDA_S3_BUCKET" --recursive --region "$REGION"
            aws s3 rb "s3://$LAMBDA_S3_BUCKET" --region "$REGION"
        fi
        
        echo "All resources deleted"
        ;;
        
    status)
        echo "=== Stack Status ==="
        for stack in "$FARGATE_STACK_NAME" "$LAMBDA_STACK_NAME"; do
            status=$(aws cloudformation describe-stacks --stack-name "$stack" --region "$REGION" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")
            echo "$stack: $status"
        done
        ;;
        
    outputs)
        echo "=== Fargate Stack Outputs ==="
        aws cloudformation describe-stacks --stack-name "$FARGATE_STACK_NAME" --region "$REGION" --query 'Stacks[0].Outputs' --output table 2>/dev/null || echo "Stack not found"
        echo ""
        echo "=== Lambda Stack Outputs ==="
        aws cloudformation describe-stacks --stack-name "$LAMBDA_STACK_NAME" --region "$REGION" --query 'Stacks[0].Outputs' --output table 2>/dev/null || echo "Stack not found"
        ;;
esac

echo "Done"

