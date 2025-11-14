# Infrastructure as Code

Fluidity uses AWS CloudFormation for infrastructure management with automated deployment scripts, environment separation (dev/prod), stack protection policies, and drift detection.

---

## Overview

**Two main stacks:**

- **Fargate Stack**: ECS cluster, service, and task definition
- **Lambda Stack**: Control plane (Wake/Sleep/Kill), API Gateway, EventBridge

**Architecture:**

```
┌──────────────────────────────────────────────────────────┐
│         CloudFormation Stack: Fargate                    │
│  ┌────────────────────────────────────────────────────┐  │
│  │ ECS Cluster "fluidity"                             │  │
│  │ ├─ ECS Service "fluidity-server"                   │  │
│  │ │  └─ Fargate Task (0.25 vCPU, 512 MB)             │  │
│  │ │     └─ Container: fluidity-server (ECR image)    │  │
│  │ └─ CloudWatch Logs (/ecs/fluidity/server)          │  │
│  │                                                     │  │
│  │ Security Group (port 8443)                          │  │
│  │ IAM Roles (Execution, Task)                         │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│      CloudFormation Stack: Lambda Control Plane              │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ API Gateway (HTTPS endpoints)                          │  │
│  │ ├─ POST /wake   → Wake Lambda                         │  │
│  │ ├─ POST /kill   → Kill Lambda                         │  │
│  │ └─ GET /status  → Check status                        │  │
│  │                                                       │  │
│  │ Lambda Functions                                      │  │
│  │ ├─ Wake (on API call)                                │  │
│  │ ├─ Sleep (EventBridge every 5 min)                   │  │
│  │ └─ Kill (API call + EventBridge nightly)             │  │
│  │                                                       │  │
│  │ EventBridge Rules                                     │  │
│  │ ├─ Sleep: rate(5 minutes)                            │  │
│  │ └─ Kill: cron(0 23 * * ? *)                          │  │
│  │                                                       │  │
│  │ S3 Bucket (Lambda artifacts)                          │  │
│  └───────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

---

## Quick Deploy

### Prerequisites

```bash
# Install tools
./scripts/setup-prereq-<platform>.sh

# Generate certificates
./scripts/manage-certs.sh
```

### Step 1: Build and Push Server Image

```bash
# Create ECR repository
aws ecr create-repository --repository-name fluidity-server

# Build Linux binary
./scripts/build-core.sh --linux

# Build Docker image
docker build -f deployments/server/Dockerfile -t fluidity-server .

# Tag and push
docker tag fluidity-server:latest <account-id>.dkr.ecr.<region>.amazonaws.com/fluidity-server:latest
docker push <account-id>.dkr.ecr.<region>.amazonaws.com/fluidity-server:latest
```

### Step 2: Deploy Fargate Stack

```bash
cd scripts

# Linux/macOS
./deploy-fluidity.sh -e prod -a deploy

# Windows PowerShell
.\deploy-fluidity.ps1 -Environment prod -Action deploy
```

### Step 3: Deploy Lambda Stack (Optional)

```bash
cd scripts

# Linux/macOS
./deploy-fluidity.sh -e prod -a deploy-lambda

# Windows PowerShell
.\deploy-fluidity.ps1 -Environment prod -Action deploy-lambda
```

---

## File Structure

```
deployments/cloudformation/
├── fargate.yaml              # ECS Fargate cluster and service
├── lambda.yaml               # Lambda control plane infrastructure
├── params.json               # Parameters (replace <> values)
├── stack-policy.json         # Stack deletion protection
├── stack-policy-fargate.json # Fargate-specific protections
└── stack-policy-lambda.json  # Lambda-specific protections

scripts/
├── deploy-fluidity.sh        # Bash deployment script
└── deploy-fluidity.ps1       # PowerShell deployment script
```

---

## Configuration

### Parameters File (`params.json`)

Replace all `<>` placeholders:

```json
{
  "StackName": "fluidity",
  "Environment": "prod",
  "ContainerImage": "<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/fluidity-server:latest",
  "ClusterName": "fluidity-prod",
  "ServiceName": "fluidity-server-prod",
  "VpcId": "<VPC_ID>",
  "PublicSubnets": "<SUBNET_ID_1>,<SUBNET_ID_2>",
  "AllowedIngressCidr": "<YOUR_IP>/32"
}
```

**Get required IDs:**

```bash
# VPC ID
aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text

# Subnet IDs
aws ec2 describe-subnets --filters Name=vpc-id,Values=<VPC_ID> --query 'Subnets[*].SubnetId' --output text

# Your IP
curl ifconfig.me
```

### Environment Variables

**All parameters can be set via environment variables:**

```bash
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=123456789012
export STACK_NAME=fluidity-prod
export CLUSTER_NAME=fluidity-prod
export SERVICE_NAME=fluidity-server-prod
export CONTAINER_IMAGE=123456789012.dkr.ecr.us-east-1.amazonaws.com/fluidity-server:latest
export VPC_ID=vpc-xxxxxxxx
export PUBLIC_SUBNETS=subnet-xxxxxxxx,subnet-yyyyyyyy
export ALLOWED_INGRESS_CIDR=203.0.113.0/32

./deploy-fluidity.sh -e prod -a deploy
```

---

## Stack Management

### Create Stack

```bash
./deploy-fluidity.sh -e prod -a deploy
```

### Update Stack

```bash
# Same command - script detects existing stack
./deploy-fluidity.sh -e prod -a deploy
```

### View Stack Status

```bash
./deploy-fluidity.sh -e prod -a status
```

### View Stack Outputs

```bash
./deploy-fluidity.sh -e prod -a outputs
```

**Expected outputs:**
- Fargate Server IP
- API Gateway URLs (Wake/Kill endpoints)
- Lambda Function ARNs

### Delete Stack

```bash
./deploy-fluidity.sh -e prod -a delete --force
```

---

## CloudFormation Templates

### Fargate Template (`fargate.yaml`)

**Parameters:**
- `ContainerImage` - ECR image URI
- `ClusterName` - ECS cluster name
- `ServiceName` - ECS service name
- `VpcId` - VPC for deployment
- `PublicSubnets` - Comma-separated subnet IDs
- `AllowedIngressCidr` - CIDR for port 8443 access

**Resources:**
- ECS Cluster
- ECS Service
- Fargate Task Definition
- CloudWatch Log Group
- Security Group
- IAM Execution Role
- IAM Task Role

**Outputs:**
- Server Public IP
- Task ARN
- Service ARN

### Lambda Template (`lambda.yaml`)

**Parameters:**
- `LambdaS3Bucket` - S3 bucket with Lambda artifacts
- `LambdaS3KeyPrefix` - S3 prefix for artifacts
- `ECSClusterName` - Target ECS cluster
- `ECSServiceName` - Target ECS service
- `IdleThresholdMinutes` - Idle timeout (default: 15)
- `SleepCheckInterval` - Sleep check frequency (default: 5 min)

**Resources:**
- Lambda Execution Role
- Wake Lambda Function
- Sleep Lambda Function
- Kill Lambda Function
- API Gateway REST API
- API Gateway Deployment
- EventBridge Rules
- S3 Bucket (artifacts)

**Outputs:**
- Wake API Endpoint
- Kill API Endpoint
- Status API Endpoint

---

## Stack Policies

Stack policies prevent accidental modifications or deletions:

**Fargate policy** (`stack-policy-fargate.json`):
- Allows all updates
- Prevents task definition updates (use blue-green deployment instead)

**Lambda policy** (`stack-policy-lambda.json`):
- Allows Lambda function code updates
- Prevents role modifications

**Apply policies:**

```bash
aws cloudformation set-stack-policy \
  --stack-name fluidity-fargate \
  --stack-policy-body file://stack-policy-fargate.json
```

---

## Drift Detection

Detect manual changes to stack resources:

```bash
# Detect drift
aws cloudformation detect-stack-drift --stack-name fluidity-fargate

# Check status
aws cloudformation describe-stack-drift-detection-status \
  --stack-drift-detection-id <drift-id>
```

---

## Common Operations

### Start Server

```bash
aws ecs update-service \
  --cluster fluidity-prod \
  --service fluidity-server-prod \
  --desired-count 1
```

### Stop Server

```bash
aws ecs update-service \
  --cluster fluidity-prod \
  --service fluidity-server-prod \
  --desired-count 0
```

### Update Server Image

```bash
# Push new image to ECR
docker push <account-id>.dkr.ecr.<region>.amazonaws.com/fluidity-server:latest

# Force new deployment
aws ecs update-service \
  --cluster fluidity-prod \
  --service fluidity-server-prod \
  --force-new-deployment
```

### View Logs

```bash
aws logs tail /ecs/fluidity/server --follow
```

### Check Stack Events

```bash
./deploy-fluidity.sh -e prod -a status
```

---

## Monitoring

### CloudWatch Dashboards

```bash
aws cloudwatch put-dashboard \
  --dashboard-name fluidity-server \
  --dashboard-body file://dashboard.json
```

### Alarms

Set up alarms for:
- Task failures
- High CPU/memory
- API errors
- Lambda timeouts

**Example:**

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name fluidity-task-failures \
  --alarm-description "Alert on Fluidity task failures" \
  --metric-name RunningCount \
  --namespace AWS/ECS \
  --statistic Average \
  --period 300 \
  --threshold 0 \
  --comparison-operator LessThanThreshold \
  --alarm-actions <sns-topic-arn>
```

---

## Troubleshooting

### Stack Creation Failed

```bash
# Check events
aws cloudformation describe-stack-events \
  --stack-name fluidity-fargate \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`]'

# View stack status
./deploy-fluidity.sh -e prod -a status
```

### Task Won't Start

```bash
# Check logs
aws logs tail /ecs/fluidity/server --follow

# Check task status
aws ecs describe-tasks \
  --cluster fluidity-prod \
  --tasks $(aws ecs list-tasks --cluster fluidity-prod --query 'taskArns[0]' --output text)
```

### Parameters Not Applied

Ensure using correct parameter file and format:
```bash
# Via command line
./deploy-fluidity.sh -e prod -a deploy

# Or parameters file
./deploy-fluidity.sh -e prod -a deploy --params-file params.json
```

---

## Related Documentation

- **[Fargate Guide](fargate.md)** - ECS Fargate details
- **[Lambda Functions](lambda.md)** - Control plane guide
- **[Deployment Guide](deployment.md)** - All deployment options
- **[Docker Guide](docker.md)** - Container details
