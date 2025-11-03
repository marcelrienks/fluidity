# Operational Runbook

Daily operations and troubleshooting for production Fluidity deployments.

**Note for Windows users:** All commands in this guide should be run in WSL (Windows Subsystem for Linux).

---

## Daily Operations

### Start Server

```bash
# CloudFormation deployment
aws ecs update-service --cluster fluidity-prod --service fluidity-server-prod --desired-count 1

# Wait for task to start (~60s)
sleep 60

# Get public IP
# (See Fargate Guide for complete script)
```

### Stop Server

```bash
aws ecs update-service --cluster fluidity-prod --service fluidity-server-prod --desired-count 0
```

### Check Status

```bash
aws ecs describe-services \
  --cluster fluidity-prod \
  --services fluidity-server-prod \
  --query 'services[0].{Desired:desiredCount,Running:runningCount,Status:status}'
```

## Monitoring

### View Logs

```bash
# Server logs
aws logs tail /ecs/fluidity/server --follow

# Lambda logs
aws logs tail /aws/lambda/fluidity-wake --follow
aws logs tail /aws/lambda/fluidity-sleep --follow
aws logs tail /aws/lambda/fluidity-kill --follow
```

### Check Metrics

```bash
# Active connections
aws cloudwatch get-metric-statistics \
  --namespace Fluidity \
  --metric-name ActiveConnections \
  --dimensions Name=ServiceName,Value=fluidity-server \
  --statistics Maximum \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300
```

## Troubleshooting

### Agent Cannot Connect

**Check:**
1. Server is running: `aws ecs describe-services...`
2. Get current public IP (changes on restart)
3. Security Group allows your IP
4. Certificates are valid

**Fix:**
```bash
# Update agent config with new IP
# configs/agent.yaml
server_ip: "<new-public-ip>"
```

### Server Not Starting

**Check logs:**
```bash
aws logs tail /ecs/fluidity/server --since 10m
```

**Common issues:**
- Missing certificates
- Subnet not public
- Insufficient Fargate capacity

### Lambda Invocation Failures

**Check:**
```bash
aws logs tail /aws/lambda/fluidity-wake --since 10m
```

**Common issues:**
- IAM permissions
- ECS service name mismatch
- API Gateway authentication

### High Costs

**Check usage:**
```bash
aws ce get-cost-and-usage \
  --time-period Start=2025-10-01,End=2025-10-31 \
  --granularity DAILY \
  --metrics UnblendedCost \
  --filter file://filter.json
```

**Optimize:**
- Ensure Sleep Lambda is running
- Set `desiredCount=0` when not in use
- Adjust idle threshold

## Maintenance

### Certificate Rotation

```bash
# Generate new certificates
./scripts/manage-certs.sh --save-to-secrets

# Rebuild and push image
make -f Makefile.<platform> docker-build-server
docker push <ecr-uri>

# Update service (forces new deployment)
aws ecs update-service --cluster fluidity-prod --service fluidity-server-prod --force-new-deployment
```

### Update Server Config

1. Edit `configs/server.yaml`
2. Rebuild Docker image
3. Push to ECR
4. Update ECS service

### Update Lambda Functions

```bash
cd scripts
./deploy-fluidity.sh -e prod -a deploy
```

## Alerts

**Set up CloudWatch Alarms:**
- Lambda errors > 5 in 5 minutes
- ECS service unhealthy
- High cost anomaly

## Backup

**Configuration files:**
- `configs/*.yaml`
- `deployments/cloudformation/params*.json`

**Certificates:**
- `certs/*.crt`, `certs/*.key`
- AWS Secrets Manager backups

## Disaster Recovery

**Server lost:**
1. Redeploy CloudFormation stack
2. Update agent with new IP

**Certificates compromised:**
1. Generate new certificates
2. Update both server and agent
3. Rebuild and redeploy

## Related Documentation

- [Infrastructure Guide](infrastructure.md) - Deployment
- [Lambda Functions](lambda.md) - Control plane
- [Fargate Guide](fargate.md) - ECS operations
