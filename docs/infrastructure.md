# Infrastructure as Code

Complete guide to deploying and managing Fluidity using AWS CloudFormation.

**Note for Windows users:** All commands in this guide should be run in WSL (Windows Subsystem for Linux).

---

## Overview



**Two CloudFormation stacks:**Fluidity uses AWS CloudFormation for infrastructure management with automated deployment scripts, environment separation (dev/prod), stack protection policies, and drift detection.

- **Fargate Stack**: ECS cluster, service, task definition

- **Lambda Stack**: Control plane (Wake/Sleep/Kill), API Gateway, EventBridge**Two main stacks:**

- **Fargate Stack**: ECS cluster, service, and task definition

## Quick Deploy- **Lambda Stack**: Control plane (Wake/Sleep/Kill), API Gateway, EventBridge



### 1. Push Image to ECR## Quick Start



```bash### 1. Build and Push Docker Image

make -f Makefile.<platform> docker-build-server

docker tag fluidity-server:latest <account-id>.dkr.ecr.us-east-1.amazonaws.com/fluidity-server:latest```bash

aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-east-1.amazonaws.commake -f Makefile.linux docker-build-server

docker push <account-id>.dkr.ecr.us-east-1.amazonaws.com/fluidity-server:latestdocker tag fluidity-server:latest YOUR_ACCOUNT_ID.dkr.ecr.YOUR_REGION.amazonaws.com/fluidity-server:latest

```aws ecr get-login-password --region YOUR_REGION | docker login --username AWS --password-stdin YOUR_ACCOUNT_ID.dkr.ecr.YOUR_REGION.amazonaws.com

docker push YOUR_ACCOUNT_ID.dkr.ecr.YOUR_REGION.amazonaws.com/fluidity-server:latest

### 2. Configure Parameters```



Edit `deployments/cloudformation/params.json`:### 2. Configure Parameters

- Set `VpcId` and `PublicSubnets`

- Set `AllowedIngressCidr` to your IP (`x.x.x.x/32`)Edit `deployments/cloudformation/params.json`:

- Update `ContainerImage` with ECR URI- Replace `YOUR_ACCOUNT_ID`, `YOUR_REGION`

- Set `VpcId` and `PublicSubnets`

### 3. Deploy- Set `AllowedIngressCidr` to your public IP (`x.x.x.x/32`)

- Update `ContainerImage` with your ECR URI

```bash

cd scripts### 3. Deploy Infrastructure

./deploy-fluidity.sh -e prod -a deploy              # Linux/macOS

.\deploy-fluidity.ps1 -Environment prod -Action deploy  # Windows```powershell

```cd scripts

./deploy-fluidity.ps1 -Environment prod -Action deploy

## Manage```



**Start server:**Or with Bash:

```bash```bash

aws ecs update-service --cluster fluidity-prod --service fluidity-server-prod --desired-count 1cd scripts

```./deploy-fluidity.sh -e prod -a deploy

```

**Stop server:**

```bash## File Structure

aws ecs update-service --cluster fluidity-prod --service fluidity-server-prod --desired-count 0

``````

deployments/cloudformation/

**Get public IP:**├── fargate.yaml              # ECS Fargate cluster and service

```bash├── lambda.yaml               # Lambda control plane infrastructure

# Get task ARN, then ENI, then IP (see Fargate Guide)├── params-dev.json           # Development parameters

```├── params-prod.json          # Production parameters

├── stack-policy.json         # Stack deletion protection

**View status:**└── README.md

```bash

cd scriptsscripts/

./deploy-fluidity.sh -e prod -a status├── deploy-fluidity.ps1       # PowerShell deployment script

```└── deploy-fluidity.sh        # Bash deployment script

```

**View outputs:**

```bash## Configuration

./deploy-fluidity.sh -e prod -a outputs

```### Parameters Reference



**Delete:**| Parameter | Purpose | Dev Value | Prod Value |

```bash|-----------|---------|-----------|-----------|

./deploy-fluidity.sh -e prod -a delete| `ClusterName` | ECS cluster name | `fluidity-dev` | `fluidity-prod` |

```| `ServiceName` | ECS service name | `fluidity-server-dev` | `fluidity-server-prod` |

| `ContainerImage` | ECR image URI | Required | Required |

## Monitoring| `VpcId` | VPC for deployment | Required | Required |

| `PublicSubnets` | Subnets for tasks | Required | Required |

**CloudWatch Logs:**| `AllowedIngressCidr` | IP whitelist | Required | Required |

```bash| `Cpu` | Task CPU | 256 | 256 |

aws logs tail /ecs/fluidity/server --follow| `Memory` | Task memory (MB) | 512 | 512 |

aws logs tail /aws/lambda/fluidity-wake --follow| `DesiredCount` | Running tasks | 0 | 0 |

```| `LogRetentionDays` | Log retention | 7 | 30 |

| `IdleThresholdMinutes` | Idle timeout | 5 | 15 |

**CloudWatch Metrics:**| `SleepCheckIntervalMinutes` | Check frequency | 2 | 5 |

- `Fluidity/ActiveConnections`

- `Fluidity/LastActivityEpochSeconds`**Environment Differences:**

- **Dev**: Optimized for testing (faster iterations, shorter timeouts)

**CloudWatch Dashboard:** Auto-created with Lambda metrics- **Prod**: Conservative settings (longer timeouts, more logs)



## Drift Detection## Deployment Operations



Check for manual changes:### Deploy Infrastructure

```bash

./deploy-fluidity.sh -e prod -a status```powershell

```./deploy-fluidity.ps1 -Environment prod -Action deploy

```

Fix drift by redeploying.

Creates or updates both stacks and applies protection policies.

## Cost Estimation

### Check Status

| Scenario | Fargate | Lambda | Total/Month |

|----------|---------|--------|-------------|```powershell

| 2h/day | $0.27 | $0.05 | **$0.32** |./deploy-fluidity.ps1 -Environment prod -Action status

| 8h/day | $1.08 | $0.05 | **$1.13** |```

| 24/7 | $8.64 | $0.05 | **$8.69** |

Displays stack status and performs drift detection to identify manual changes.

## Related Documentation

### View Outputs

- [Deployment Guide](deployment.md) - All options

- [Fargate Guide](fargate.md) - ECS details  ```powershell

- [Lambda Functions](lambda.md) - Control plane./deploy-fluidity.ps1 -Environment prod -Action outputs

```

Shows all stack outputs including API endpoints and ARNs.

### Delete Stack

```powershell
./deploy-fluidity.ps1 -Environment prod -Action delete -Force
```

### Start Server

```powershell
aws ecs update-service `
  --cluster fluidity-prod `
  --service fluidity-server-prod `
  --desired-count 1
```

### Stop Server

```powershell
aws ecs update-service `
  --cluster fluidity-prod `
  --service fluidity-server-prod `
  --desired-count 0
```

Or use Lambda Sleep function (automatic on idle).

### Get Public IP

After starting the server:

```powershell
$taskArn = aws ecs list-tasks --cluster fluidity-prod --service-name fluidity-server-prod --query 'taskArns[0]' --output text
$eniId = aws ecs describe-tasks --cluster fluidity-prod --tasks $taskArn --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text
aws ec2 describe-network-interfaces --network-interface-ids $eniId --query 'NetworkInterfaces[0].Association.PublicIp' --output text
```

## Drift Detection

Detect manual changes made outside CloudFormation:

```powershell
./deploy-fluidity.ps1 -Environment prod -Action status
```

**Results:**
- `IN_SYNC`: Stack matches template ✓
- `DRIFTED`: Manual changes detected
- `UNKNOWN`: Detection in progress

Reconcile drift by redeploying:
```powershell
./deploy-fluidity.ps1 -Environment prod -Action deploy
```

## Stack Protection

Stack policies prevent accidental deletion of:
- API Gateway (REST API and Stage)
- Lambda functions (Wake, Sleep, Kill)
- EventBridge rules
- ECS Service and TaskDefinition
- IAM roles

Applied automatically during deployment. To manually apply:

```powershell
aws cloudformation set-stack-policy `
  --stack-name fluidity-prod-fargate `
  --stack-policy-body file://stack-policy.json
```

## Monitoring

### CloudWatch Alarms

Three CloudWatch alarms are automatically created:
- **Wake Lambda Errors**: Alerts when Wake Lambda execution fails
- **Sleep Lambda Errors**: Alerts when Sleep Lambda execution fails
- **Kill Lambda Errors**: Alerts when Kill Lambda execution fails

All alarms send notifications to an SNS topic configured during deployment.

**Configure Email Notifications:**

```bash
# Get SNS topic ARN from stack outputs
TOPIC_ARN=$(aws cloudformation describe-stacks \
  --stack-name fluidity-lambda \
  --query 'Stacks[0].Outputs[?OutputKey==`AlarmNotificationTopicArn`].OutputValue' \
  --output text)

# Subscribe your email
aws sns subscribe \
  --topic-arn $TOPIC_ARN \
  --protocol email \
  --notification-endpoint your-email@example.com
```

Confirm the subscription email from AWS SNS.

### CloudWatch Dashboard

A dashboard is automatically created with:
- Lambda metrics (invocations, errors, duration, throttles)
- Fluidity server metrics (active connections, last activity)
- API Gateway metrics (requests, 4xx/5xx errors)
- Lambda error logs from the last hour

**Access Dashboard:**

```bash
# Get dashboard URL from stack outputs
aws cloudformation describe-stacks \
  --stack-name fluidity-lambda \
  --query 'Stacks[0].Outputs[?OutputKey==`DashboardURL`].OutputValue' \
  --output text
```

Or access via AWS Console: CloudWatch → Dashboards → `fluidity-dashboard`

### CloudWatch Logs

```bash
# Container logs
aws logs tail /ecs/fluidity/server --follow

# Lambda logs
aws logs tail /aws/lambda/fluidity-wake --follow
aws logs tail /aws/lambda/fluidity-sleep --follow
aws logs tail /aws/lambda/fluidity-kill --follow

# API Gateway logs
aws logs tail /aws/apigateway/fluidity-api-execution --follow
```

### CloudWatch Metrics

```bash
# Server active connections
aws cloudwatch get-metric-statistics \
  --namespace Fluidity \
  --metric-name ActiveConnections \
  --dimensions Name=ServiceName,Value=fluidity-server \
  --statistics Maximum,Average \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --output table

# Lambda invocations
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Invocations \
  --dimensions Name=FunctionName,Value=fluidity-wake \
  --statistics Sum \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --output table
```

## Troubleshooting

### Stack Creation Failed

Check stack events:
```powershell
aws cloudformation describe-stack-events `
  --stack-name fluidity-prod-fargate `
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`]' `
  --output table
```

### Task Stuck in PENDING

Check task status:
```powershell
aws ecs describe-tasks --cluster fluidity-prod `
  --tasks $(aws ecs list-tasks --cluster fluidity-prod --service-name fluidity-server-prod --query 'taskArns[0]' --output text) `
  --output json
```

**Common causes:**
- Subnets not public or `AssignPublicIp` not enabled
- Insufficient Fargate capacity
- Security group blocking access

### Lambda Invocation Failures

Check logs:
```bash
aws logs tail /aws/lambda/fluidity-prod-wake --follow --since 10m
```

**Common causes:**
- IAM permissions insufficient
- ECS cluster/service name mismatch
- Network connectivity issues

### Stack in UPDATE_ROLLBACK_FAILED

Recover:
```powershell
aws cloudformation continue-update-rollback --stack-name fluidity-prod-fargate
```

## Cost Analysis

| Scenario | Fargate | Lambda | API Gateway | Total/Month |
|----------|---------|--------|-------------|------------|
| Dev (2h/day) | $0.27 | $0.05 | $0.10 | **$0.42** |
| Regular (8h/day) | $1.08 | $0.05 | $0.10 | **$1.23** |
| 24/7 | $8.64 | $0.05 | $0.10 | **$8.79** |

**Cost Optimization:** Lambda Sleep function reduces costs by 70-94% through automatic idle shutdown.

## Security

### IAM Least-Privilege

Each Lambda function has minimal permissions:
- **Wake**: `ecs:DescribeServices`, `ecs:UpdateService`
- **Sleep**: + `cloudwatch:GetMetricData`
- **Kill**: `ecs:UpdateService` only

### API Gateway Security

- API key required for all endpoints
- Rate limiting: 3 req/sec, 20 burst
- Monthly quota: 300 requests
- CloudWatch logging enabled

### Network Security

- Security group restricts port 8443
- `AllowedIngressCidr` whitelist configurable
- mTLS authentication for agent-server communication
- TLS 1.3 encryption in transit

## Best Practices

1. **Environment Separation**: Use separate dev/prod stacks with different parameters
2. **Parameters Management**: Store in version control; use `.gitignore` for sensitive values
3. **Stack Policies**: Keep policies enabled to prevent accidents
4. **Cost Optimization**: Set `DesiredCount=0` when not in use; rely on Lambda control plane for idle shutdown
5. **Monitoring**: Enable CloudWatch Logs and set up alarms
6. **Security**: Restrict `AllowedIngressCidr` to your IP; use Secrets Manager for sensitive data
7. **CI/CD Integration**: Automate deployments via GitHub Actions or other CI/CD tools

## CI/CD Integration Example

GitHub Actions workflow:

```yaml
name: Deploy Fluidity

on:
  push:
    branches: [main]
    paths:
      - 'deployments/cloudformation/**'

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v1
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: us-east-1
      - name: Deploy to prod
        run: |
          cd scripts
          chmod +x deploy-fluidity.sh
          ./deploy-fluidity.sh -e prod -a deploy -f
```

## Architecture

```
┌─────────────────────────────────────────────────┐
│        CloudFormation Stack: Fargate            │
│  ┌─────────────────────────────────────────┐   │
│  │ ECS Cluster "fluidity"                  │   │
│  │ ├─ ECS Service "fluidity-server"        │   │
│  │ │  └─ Fargate Task (0.25 vCPU, 512 MB)  │   │
│  │ └─ CloudWatch Logs                      │   │
│  │                                         │   │
│  │ Security Group (port 8443)              │   │
│  │ IAM Roles (Execution, Task)             │   │
│  └─────────────────────────────────────────┘   │
└─────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│       CloudFormation Stack: Lambda Control Plane         │
│  ┌────────────────────────────────────────────────────┐  │
│  │ Lambda Functions                                   │  │
│  │ ├─ Wake Lambda (check state, scale up)            │  │
│  │ ├─ Sleep Lambda (query metrics, scale down)       │  │
│  │ └─ Kill Lambda (immediate shutdown)               │  │
│  │                                                    │  │
│  │ API Gateway (/wake, /kill endpoints)              │  │
│  │ ├─ Authentication (API key)                       │  │
│  │ ├─ Rate limiting (3 req/s, 20 burst)              │  │
│  │ └─ CloudWatch Logs                                │  │
│  │                                                    │  │
│  │ EventBridge Rules                                  │  │
│  │ ├─ Sleep (every 5 minutes)                        │  │
│  │ └─ Kill (daily 11 PM UTC)                         │  │
│  │                                                    │  │
│  │ IAM Roles (least-privilege)                       │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

## Building and Pushing Docker Image to ECR

### Prerequisites

1. **AWS CLI** v2 installed and configured
2. **Docker** installed and configured
3. **AWS ECR** repository created

### Quick Start

```bash
# Create ECR repository
aws ecr create-repository --repository-name fluidity-server --region us-east-1

# Get ECR login
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 123456789012.dkr.ecr.us-east-1.amazonaws.com

# Build image with certificates baked in
# IMPORTANT: Certificates must be in the certs/ directory before building
cd deployments
make -f ../Makefile.<platform> docker-build-server  # windows, linux, or macos

# Tag for ECR
docker tag fluidity-server:latest 123456789012.dkr.ecr.us-east-1.amazonaws.com/fluidity-server:latest

# Push to ECR
docker push 123456789012.dkr.ecr.us-east-1.amazonaws.com/fluidity-server:latest
```

### Baking Certificates into Docker Image

The Docker image must include TLS certificates at `/root/certs/`. The simplest approach:

1. Generate certificates locally:
   ```bash
   ./scripts/manage-certs.sh              # All platforms (use WSL on Windows)
   ```

2. Modify `deployments/server/Dockerfile` to copy certificates:
   ```dockerfile
   # Add after COPY build/fluidity-server .
   COPY certs/ca.crt ./certs/
   COPY certs/server.crt ./certs/
   COPY certs/server.key ./certs/
   ```

3. Rebuild and push:
   ```bash
   make -f Makefile.<platform> docker-build-server
   docker tag fluidity-server:latest <ECR_URI>
   docker push <ECR_URI>
   ```

### Alternative: Using AWS Secrets Manager

For production deployments, store certificates in AWS Secrets Manager:

1. Store certificates:
   ```bash
   aws secretsmanager create-secret \
     --name fluidity/server/ca-cert \
     --secret-string file://certs/ca.crt
   
   aws secretsmanager create-secret \
     --name fluidity/server/server-cert \
     --secret-string file://certs/server.crt
   
   aws secretsmanager create-secret \
     --name fluidity/server/server-key \
     --secret-string file://certs/server.key
   ```

2. Modify CloudFormation task definition to inject secrets as environment variables
3. Update application to read from environment or write to files on startup

## Related Documentation

- **[Deployment Guide](deployment.md)** - All deployment options
- **[Architecture](architecture.md)** - System design
- **[Fargate Guide](fargate.md)** - AWS ECS details
- **[Lambda Guide](lambda.md)** - Control plane details
- **[Certificate Management](certificate-management.md)** - Certificate generation
- **[Project Plan](plan.md)** - Roadmap and progress
