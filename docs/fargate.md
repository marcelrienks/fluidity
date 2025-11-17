# AWS Fargate Deployment

Deploy Fluidity server to AWS ECS using Fargate for serverless container execution.

---

## Architecture

```
┌─────────────────────────────────────┐
│  AWS VPC                             │
│  ┌───────────────────────────────┐  │
│  │  ECS Cluster (Fargate)        │  │
│  │  ┌─────────────────────────┐  │  │
│  │  │ ECS Service             │  │  │
│  │  │ ├─ Fargate Task         │  │  │
│  │  │ │  └─ fluidity-server   │  │  │
│  │  │ │     (0.25 vCPU, 512MB)│  │  │
│  │  │ └─ Public IP            │  │  │
│  │  └─────────────────────────┘  │  │
│  ├─ CloudWatch Logs                │  │
│  └─ Security Group (port 8443)     │  │
└─────────────────────────────────────┘
```

**Benefits:**
- No EC2 instance management
- Automatic scaling
- Pay per second
- CloudWatch integration

---

## Quick Deployment

### 1. Build and Push to ECR

```bash
# Create repository
aws ecr create-repository --repository-name fluidity-server

# Login
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-east-1.amazonaws.com

# Build and push
./scripts/build-core.sh --linux
docker build -f deployments/server/Dockerfile -t fluidity-server .
docker tag fluidity-server:latest <account-id>.dkr.ecr.us-east-1.amazonaws.com/fluidity-server:latest
docker push <account-id>.dkr.ecr.us-east-1.amazonaws.com/fluidity-server:latest
```

### 2. Deploy via CloudFormation

```bash
cd scripts
./deploy-fluidity.sh -e prod -a deploy  # Linux/macOS
.\deploy-fluidity.ps1 -Environment prod -Action deploy  # Windows
```

### 3. Get Public IP

```bash
# Get ENI from task
aws ecs describe-tasks \
  --cluster fluidity-prod \
  --tasks $(aws ecs list-tasks --cluster fluidity-prod --query 'taskArns[0]' --output text) \
  --query 'tasks[0].attachments[0].details[1].value' \
  --output text

# Get IP from ENI
aws ec2 describe-network-interfaces \
  --network-interface-ids <eni-id> \
  --query 'NetworkInterfaces[0].Association.PublicIp' \
  --output text
```

### 4. Configure Local Agent

**`configs/agent.yaml`:**
```yaml
server_ip: "<fargate-public-ip>"
server_port: 8443
local_proxy_port: 8080
cert_file: "./certs/client.crt"
key_file: "./certs/client.key"
ca_cert_file: "./certs/ca.crt"
```

### 5. Test

```bash
./build/fluidity-agent -config configs/agent.yaml
curl -x http://127.0.0.1:8080 http://example.com
```

---

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
      "hostPort": 8443,
      "protocol": "tcp"
    }],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/fluidity/server",
        "awslogs-region": "us-east-1",
        "awslogs-stream-prefix": "ecs"
      }
    },
    "mountPoints": [{
      "sourceVolume": "certs",
      "containerPath": "/root/certs",
      "readOnly": true
    }, {
      "sourceVolume": "config",
      "containerPath": "/root/config",
      "readOnly": true
    }]
  }],
  "volumes": [{
    "name": "certs",
    "host": {}
  }, {
    "name": "config",
    "host": {}
  }]
}
```

---

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
  --network-configuration "awsvpcConfiguration={subnets=[<subnet-id>],securityGroups=[<sg-id>],assignPublicIp=ENABLED}" \
  --load-balancers targetGroupArn=<target-group-arn>,containerName=fluidity-server,containerPort=8443
```

---

## Start/Stop Server

### Start Server

```bash
aws ecs update-service \
  --cluster fluidity \
  --service fluidity-server \
  --desired-count 1
```

### Stop Server

```bash
aws ecs update-service \
  --cluster fluidity \
  --service fluidity-server \
  --desired-count 0
```

### Check Status

```bash
aws ecs describe-services \
  --cluster fluidity \
  --services fluidity-server \
  --query 'services[0].{Running:runningCount,Desired:desiredCount}'
```

---

## Monitoring

### View Logs

```bash
aws logs tail /ecs/fluidity/server --follow
```

### CloudWatch Metrics

```bash
aws cloudwatch list-metrics \
  --namespace AWS/ECS \
  --dimensions Name=ServiceName,Value=fluidity-server
```

### Health Checks

```bash
aws ecs describe-tasks \
  --cluster fluidity \
  --tasks $(aws ecs list-tasks --cluster fluidity --query 'taskArns[0]' --output text) \
  --query 'tasks[0].{Status:lastStatus,Health:healthStatus}'
```

---

## Troubleshooting

### Task Won't Start

**Check logs:**
```bash
aws logs tail /ecs/fluidity/server --follow
```

**Common issues:**
- Image not found in ECR
- Insufficient capacity (try different AZ)
- Security group blocks required ports

### No Public IP

```bash
# Ensure task has ENI attached
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[*].{IP:Association.PublicIp,Status:Status}'
```

### Certificate Errors

Regenerate certificates and redeploy:
```bash
./scripts/generate-certs.sh
docker build -f deployments/server/Dockerfile -t fluidity-server .
docker push <account-id>.dkr.ecr.us-east-1.amazonaws.com/fluidity-server:latest
aws ecs update-service --cluster fluidity --service fluidity-server --force-new-deployment
```

### Slow Startup

First cold start (pulling image) takes 20-30s. Subsequent starts are faster.

---

## Scaling

### Increase Desired Count

```bash
aws ecs update-service \
  --cluster fluidity \
  --service fluidity-server \
  --desired-count 3
```

### Change Task Size

```bash
aws ecs register-task-definition \
  --family fluidity-server \
  --cpu "512" \
  --memory "1024"
```

Then update service to use new revision.

---

## Related Documentation

- [Deployment Guide](deployment.md) - Complete deployment options
- [Infrastructure as Code](infrastructure.md) - CloudFormation details
- [Lambda Functions](lambda.md) - Control plane guide
- [Docker Guide](docker.md) - Container details
