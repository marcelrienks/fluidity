# Infrastructure

AWS CloudFormation manages Fluidity infrastructure via automated deployment scripts.

## Stacks

**Fargate Stack** (ECS server):
```
ECS Cluster: fluidity
├─ Service: fluidity-server (Fargate Task: 0.25 vCPU, 512MB)
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

EventBridge: rate(5 minutes) → Sleep Lambda
```

## Deploy

Quick deploy (auto-detects region/VPC/subnets):
```bash
./scripts/deploy-fluidity.sh deploy
```

Manual deploy:
```bash
export AWS_REGION=us-east-1
export VPC_ID=vpc-xxxxx
export PUBLIC_SUBNETS=subnet-1,subnet-2

aws cloudformation deploy \
  --template-file deployments/cloudformation/fargate.yaml \
  --stack-name fluidity-fargate \
  --capabilities CAPABILITY_NAMED_IAM
```

## Files

```
deployments/cloudformation/
├── fargate.yaml              # ECS infrastructure
├── lambda.yaml               # Lambda control plane
├── params.json               # Parameters
└── README.md                 # Descriptions
```

## Troubleshooting

**Stack failures**:
```bash
aws cloudformation describe-stack-events --stack-name fluidity-fargate
```

**Lambda triggers**:
```bash
aws events list-rules | grep fluidity
aws events list-targets-by-rule --rule fluidity-sleep-rule
```

**Metrics**:
```bash
aws cloudwatch get-metric-statistics \
  --namespace Fluidity \
  --metric-name ActiveConnections \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average
```

## Cleanup

```bash
aws cloudformation delete-stack --stack-name fluidity-fargate
aws cloudformation delete-stack --stack-name fluidity-lambda
aws ecr delete-repository --repository-name fluidity-server --force
```

---

See [Deployment](deployment.md) for full setup | [Architecture](architecture.md) for design
