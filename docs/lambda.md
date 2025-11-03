# Lambda Control Plane

Three Lambda functions manage Fluidity server lifecycle.

**Note for Windows users:** All commands in this guide should be run in WSL (Windows Subsystem for Linux).

---

## Functions

### Wake Lambda
**Trigger:** Agent startup (via API Gateway)  
**Action:** Sets ECS `desiredCount=1` if not already running  
**Returns:** Success message

### Sleep Lambda  
**Trigger:** EventBridge (every 5 minutes)  
**Action:**  
1. Query CloudWatch metrics for `LastActivityEpochSeconds`
2. If idle > threshold (default 15 min), set `desiredCount=0`

### Kill Lambda
**Trigger:** Agent shutdown (API Gateway) OR EventBridge (daily 11 PM UTC)  
**Action:** Immediately set `desiredCount=0`

## Architecture

```
Agent Startup → Wake API → Wake Lambda → ECS desiredCount=1
Agent Shutdown → Kill API → Kill Lambda → ECS desiredCount=0
EventBridge (5 min) → Sleep Lambda → Check metrics → Scale down if idle
EventBridge (11 PM) → Kill Lambda → Shutdown
```

## Deployment

```bash
aws cloudformation deploy \
  --template-file deployments/cloudformation/lambda.yaml \
  --stack-name fluidity-lambda \
  --parameter-overrides \
    ECSClusterName=fluidity \
    ECSServiceName=fluidity-server \
    IdleThresholdMinutes=15 \
    SleepCheckIntervalMinutes=5 \
  --capabilities CAPABILITY_NAMED_IAM
```

## Agent Configuration

```yaml
# configs/agent.yaml
wake_api_endpoint: "https://xxx.execute-api.us-east-1.amazonaws.com/prod/wake"
kill_api_endpoint: "https://xxx.execute-api.us-east-1.amazonaws.com/prod/kill"
api_key: "your-api-key"
connection_timeout: "90s"  # Time to wait for server after wake
connection_retry_interval: "5s"
```

## Server Configuration

Enable metrics emission:
```yaml
# configs/server.yaml (rebuild image after changes)
emit_metrics: true
metrics_interval: "60s"
```

## API Gateway

**Endpoints:**
- `POST /wake` - Start server
- `POST /kill` - Stop server

**Authentication:** API key required

**Rate limiting:** 3 req/sec, 20 burst, 300/month quota

## EventBridge Rules

- **Sleep**: `rate(5 minutes)` - Check for idle and scale down
- **Kill**: `cron(0 23 * * ? *)` - Daily shutdown at 11 PM UTC

## IAM Permissions

**Wake/Kill:**
- `ecs:DescribeServices`
- `ecs:UpdateService`

**Sleep:**
- Above + `cloudwatch:GetMetricData`

## Testing

**Test Wake:**
```bash
API_KEY="your-key"
ENDPOINT="https://xxx.execute-api.us-east-1.amazonaws.com/prod/wake"
curl -X POST $ENDPOINT -H "x-api-key: $API_KEY"
```

**Test Kill:**
```bash
curl -X POST $ENDPOINT/kill -H "x-api-key: $API_KEY"
```

**Verify:**
```bash
aws ecs describe-services --cluster fluidity --services fluidity-server --query 'services[0].desiredCount'
```

## Cost

- Lambda invocations: <$0.05/month
- API Gateway: <$0.10/month
- **Total: ~$0.15/month**

## Monitoring

**CloudWatch Logs:**
```bash
aws logs tail /aws/lambda/fluidity-wake --follow
aws logs tail /aws/lambda/fluidity-sleep --follow
aws logs tail /aws/lambda/fluidity-kill --follow
```

**Metrics:**
- Lambda invocations, errors, duration
- API Gateway requests, 4xx/5xx errors

## Related Documentation

- [Infrastructure Guide](infrastructure.md) - Deployment
- [Deployment Guide](deployment.md) - Setup
- [Architecture](architecture.md) - System design
