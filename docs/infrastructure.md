# Infrastructure

AWS CloudFormation manages Fluidity infrastructure via automated deployment scripts.

## Stacks

**Fargate Stack** (ECS server):
```
ECS Cluster: fluidity
├─ ECS Service: fluidity-server
│  └─ Fargate Task (0.25 vCPU, 512MB)
│     └─ Container: fluidity-server (ECR image)
├─ CloudWatch Logs: /ecs/fluidity/server
├─ Security Group: port 8443
└─ IAM Roles: Execution + Task
```

**Lambda Stack** (control plane):
```
API Gateway: /wake, /kill, /status
├─ Wake Lambda: Scale ECS DesiredCount=1
├─ Kill Lambda: Scale ECS DesiredCount=0
└─ Sleep Lambda: Auto-scale down if idle >15min

EventBridge Rules:
├─ rate(5 minutes) → Sleep Lambda
└─ cron(0 23 * * ? *) → Kill Lambda (nightly 11 PM UTC)

S3 Bucket: Lambda artifacts
```

## Quick Deploy

```bash
./scripts/deploy-fluidity.sh deploy
```

Auto-detects AWS region/VPC/subnets and deploys everything.

## Manual Deploy

Set environment:
```bash
export AWS_REGION=us-east-1
export VPC_ID=vpc-xxxxx
export PUBLIC_SUBNETS=subnet-1,subnet-2
export ALLOWED_INGRESS_CIDR=YOUR_IP/32
```

Deploy:
```bash
aws cloudformation deploy \
  --template-file deployments/cloudformation/fargate.yaml \
  --stack-name fluidity-fargate \
  --capabilities CAPABILITY_NAMED_IAM \
  --region $AWS_REGION

aws cloudformation deploy \
  --template-file deployments/cloudformation/lambda.yaml \
  --stack-name fluidity-lambda \
  --capabilities CAPABILITY_NAMED_IAM \
  --region $AWS_REGION
```

## Files

```
deployments/cloudformation/
├── fargate.yaml              # ECS infrastructure
├── lambda.yaml               # Lambda control plane
├── params.json               # Parameters template
├── stack-policy.json         # Deletion protection
└── README.md                 # Parameter descriptions
```

## Troubleshooting

**Stack creation fails**:
```bash
aws cloudformation describe-stack-events --stack-name fluidity-fargate --region $AWS_REGION
```

**Lambda not triggering**:
```bash
aws events list-rules --region $AWS_REGION | grep fluidity
aws events list-targets-by-rule --rule fluidity-sleep-rule --region $AWS_REGION
```

**Check metrics**:
```bash
aws cloudwatch get-metric-statistics \
  --namespace Fluidity \
  --metric-name ActiveConnections \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average \
  --region $AWS_REGION
```

## Cleanup

Remove stacks:
```bash
aws cloudformation delete-stack --stack-name fluidity-fargate
aws cloudformation delete-stack --stack-name fluidity-lambda
aws ecr delete-repository --repository-name fluidity-server --force
```

---

See [Deployment](deployment.md) for full setup | [Architecture](architecture.md) for design
