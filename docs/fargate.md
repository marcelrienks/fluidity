# AWS Fargate Deployment

# AWS Fargate Deployment

Deploy Fluidity server on AWS ECS Fargate with CloudFormation automation.

**Note for Windows users:** All commands in this guide should be run in WSL (Windows Subsystem for Linux).

---

## Overview

## Architecture

- ECS Cluster (Fargate)
- Task Definition (0.25 vCPU, 512 MB)
- Service with dynamic `desiredCount` (0 = stopped, 1 = running)
- Public IP + Security Group (port 8443)
- CloudWatch Logs

**Cost:** ~$0.012/hour (~$0.50-3/month depending on usage)

## Quick Deployment

### 1. Build and Push to ECR

```bash
# Create repository
aws ecr create-repository --repository-name fluidity-server

# Login
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-east-1.amazonaws.com

# Build and push
make -f Makefile.<platform> docker-build-server
docker tag fluidity-server:latest <account-id>.dkr.ecr.us-east-1.amazonaws.com/fluidity-server:latest
docker push <account-id>.dkr.ecr.us-east-1.amazonaws.com/fluidity-server:latest
```

### 2. Deploy via CloudFormation

```bash
cd scripts
./deploy-fluidity.sh -e prod -a deploy  # All platforms (use WSL on Windows)
```

Or manually create:
- ECS Cluster
- Task Definition (see template below)
- Service

### 3. Start/Stop

**Start:**
```bash
aws ecs update-service \
  --cluster fluidity \
  --service fluidity-server \
  --desired-count 1
```

**Stop:**
```bash
aws ecs update-service \
  --cluster fluidity \
  --service fluidity-server \
  --desired-count 0
```

### 4. Get Public IP

```bash
# Get task ARN
TASK_ARN=$(aws ecs list-tasks \
  --cluster fluidity \
  --service-name fluidity-server \
  --query 'taskArns[0]' \
  --output text)

# Get ENI ID
ENI_ID=$(aws ecs describe-tasks \
  --cluster fluidity \
  --tasks $TASK_ARN \
  --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' \
  --output text)

# Get public IP
aws ec2 describe-network-interfaces \
  --network-interface-ids $ENI_ID \
  --query 'NetworkInterfaces[0].Association.PublicIp' \
  --output text
```

## Task Definition Template

```json
{
  "family": "fluidity-server",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "arn:aws:iam::<account-id>:role/ecsTaskExecutionRole",
  "containerDefinitions": [{
    "name": "fluidity-server",
    "image": "<account-id>.dkr.ecr.us-east-1.amazonaws.com/fluidity-server:latest",
    "essential": true,
    "portMappings": [{
      "containerPort": 8443,
      "protocol": "tcp"
    }],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/fluidity/server",
        "awslogs-region": "us-east-1",
        "awslogs-stream-prefix": "ecs"
      }
    }
  }]
}
```

## Manual Setup Steps

### 1. Create Resources

**Log group:**
```bash
aws logs create-log-group --log-group-name /ecs/fluidity/server
```

**Security group:**
```bash
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)

SG_ID=$(aws ec2 create-security-group \
  --group-name fluidity-sg \
  --description "Fluidity server" \
  --vpc-id $VPC_ID \
  --query 'GroupId' \
  --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 8443 \
  --cidr <your-ip>/32
```

### 2. Create ECS Cluster

```bash
aws ecs create-cluster --cluster-name fluidity
```

### 3. Register Task Definition

```bash
aws ecs register-task-definition --cli-input-json file://task-definition.json
```

### 4. Create Service

```bash
aws ecs create-service \
  --cluster fluidity \
  --service-name fluidity-server \
  --task-definition fluidity-server \
  --desired-count 0 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-xxx],securityGroups=[$SG_ID],assignPublicIp=ENABLED}"
```

## Configure Local Agent

```yaml
# configs/agent.yaml
server_ip: "<public-ip-from-step-4>"
server_port: 8443
local_proxy_port: 8080
cert_file: "./certs/client.crt"
key_file: "./certs/client.key"
ca_cert_file: "./certs/ca.crt"
```

## Troubleshooting

**Task stuck in PENDING:**
- Check subnets are public
- Verify `assignPublicIp=ENABLED`
- Check Fargate capacity

**Cannot connect:**
- Verify Security Group allows your IP
- Check task is RUNNING
- Verify certificates match

**View logs:**
```bash
aws logs tail /ecs/fluidity/server --follow
```

## Related Documentation

- [Docker Guide](docker.md) - Building images
- [Infrastructure Guide](infrastructure.md) - CloudFormation deployment
- [Lambda Functions](lambda.md) - Automated lifecycle
