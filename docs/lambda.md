````markdown
# Lambda Control Plane

Three Lambda functions manage Fluidity server lifecycle using **Lambda Function URLs** (no API Gateway).

**Note for Windows users:** All commands in this guide should be run in WSL (Windows Subsystem for Linux).

---

## Architecture

```
Agent Startup → Wake Function URL → Wake Lambda → ECS desiredCount=1
Agent Shutdown → Kill Function URL → Kill Lambda → ECS desiredCount=0
EventBridge (5 min) → Sleep Lambda (direct) → Check metrics → Scale down if idle
EventBridge (11 PM) → Kill Lambda (direct) → Shutdown
```

## Functions

### Wake Lambda
**Trigger:** Agent startup (via Function URL POST)  
**Action:** Sets ECS `desiredCount=1` if not already running  
**Function URL:** `https://<function-url-id>.lambda-url.<region>.on.aws/`

### Sleep Lambda  
**Trigger:** EventBridge (every 5 minutes, direct) or Function URL  
**Action:**  
1. Query CloudWatch metrics for `LastActivityEpochSeconds`
2. If idle > threshold (default 15 min), set `desiredCount=0`

**Function URL:** `https://<function-url-id>.lambda-url.<region>.on.aws/` (optional)

### Kill Lambda
**Trigger:** Agent shutdown (via Function URL POST) OR EventBridge (daily 11 PM UTC)  
**Action:** Immediately set `desiredCount=0`

**Function URL:** `https://<function-url-id>.lambda-url.<region>.on.aws/`

---

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

---

## Getting Function URLs

After deployment, retrieve the Function URLs from CloudFormation outputs:

```bash
# Get all outputs
aws cloudformation describe-stacks \
  --stack-name fluidity-lambda \
  --query 'Stacks[0].Outputs' \
  --output table

# Get Wake Function URL specifically
aws cloudformation describe-stacks \
  --stack-name fluidity-lambda \
  --query 'Stacks[0].Outputs[?OutputKey==`WakeAPIEndpoint`].OutputValue' \
  --output text

# Get Kill Function URL specifically
aws cloudformation describe-stacks \
  --stack-name fluidity-lambda \
  --query 'Stacks[0].Outputs[?OutputKey==`KillAPIEndpoint`].OutputValue' \
  --output text
```

---

## Agent Configuration

```yaml
# configs/agent.yaml
server_host: "<SERVER_PUBLIC_IP>"
server_port: 8443
wake_api_endpoint: "https://xxxxx.lambda-url.region.on.aws/"
kill_api_endpoint: "https://xxxxx.lambda-url.region.on.aws/"
connection_timeout: "90s"     # Time to wait for server after wake
connection_retry_interval: "5s"
cert_file: "./certs/client.crt"
key_file: "./certs/client.key"
ca_file: "./certs/ca.crt"
```

**Key differences from API Gateway:**
- No `api_key` needed
- Simpler endpoint format (no `/prod` or `/wake` path)
- Direct POST invokes Lambda function
- HTTPS enforced by AWS

---

## Server Configuration

Enable metrics emission for Sleep Lambda idle detection:

```yaml
# configs/server.yaml (rebuild Docker image after changes)
emit_metrics: true
metrics_interval: "60s"
```

---

## Invoking Functions

### Wake Lambda (Agent Startup)

```bash
WAKE_URL="https://xxxxx.lambda-url.region.on.aws/"
curl -X POST $WAKE_URL \
  -H "Content-Type: application/json" \
  -d '{}'
```

**Response Example:**
```json
{
  "statusCode": 200,
  "headers": {"Content-Type": "application/json"},
  "body": "{\"status\":\"waking\",\"desiredCount\":1,\"runningCount\":0,\"estimatedStartTime\":\"2025-11-13T12:34:56Z\",\"message\":\"Service wake initiated...\"}"
}
```

### Kill Lambda (Agent Shutdown)

```bash
KILL_URL="https://xxxxx.lambda-url.region.on.aws/"
curl -X POST $KILL_URL \
  -H "Content-Type: application/json" \
  -d '{}'
```

**Response Example:**
```json
{
  "statusCode": 200,
  "headers": {"Content-Type": "application/json"},
  "body": "{\"status\":\"killed\",\"desiredCount\":0,\"message\":\"Service shutdown initiated...\"}"
}
```

### Sleep Lambda (EventBridge)

EventBridge invokes Sleep Lambda directly (no Function URL needed):

```bash
# Manual test via CloudWatch Events
aws lambda invoke \
  --function-name fluidity-lambda-sleep \
  --payload '{}' \
  response.json

cat response.json
```

**Or manually via Function URL:**
```bash
SLEEP_URL="https://xxxxx.lambda-url.region.on.aws/"
curl -X POST $SLEEP_URL \
  -H "Content-Type: application/json" \
  -d '{}'
```

---

## EventBridge Rules

Automatically created by CloudFormation:

- **Sleep**: `rate(5 minutes)` - Invokes Sleep Lambda every 5 minutes
- **Kill**: `cron(0 23 * * ? *)` - Invokes Kill Lambda daily at 11 PM UTC

These rules invoke Lambdas directly, not via Function URLs.

---

## IAM Permissions

Each Lambda has minimal, role-specific permissions:

**Wake Lambda:**
- `ecs:DescribeServices`
- `ecs:UpdateService`

**Sleep Lambda:**
- `ecs:DescribeServices`
- `ecs:UpdateService`
- `cloudwatch:GetMetricData`

**Kill Lambda:**
- `ecs:UpdateService`

---

## Testing

**Test Wake Lambda:**
```bash
WAKE_URL="https://xxxxx.lambda-url.region.on.aws/"
curl -X POST $WAKE_URL \
  -H "Content-Type: application/json" \
  -d '{}' | jq .
```

**Test Kill Lambda:**
```bash
KILL_URL="https://xxxxx.lambda-url.region.on.aws/"
curl -X POST $KILL_URL \
  -H "Content-Type: application/json" \
  -d '{}' | jq .
```

**Verify ECS service state:**
```bash
aws ecs describe-services \
  --cluster fluidity \
  --services fluidity-server \
  --query 'services[0].{Desired:desiredCount,Running:runningCount,Pending:pendingCount,Status:status}' \
  --output table
```

---

## Cost

- Lambda Function URLs: No additional charge (included in Lambda pricing)
- Lambda invocations: <$0.05/month (free tier covers 1M invocations)
- **Total: ~$0.05/month** (90% cheaper than API Gateway)

---

## Monitoring

**CloudWatch Logs:**
```bash
aws logs tail /aws/lambda/fluidity-lambda-wake --follow
aws logs tail /aws/lambda/fluidity-lambda-sleep --follow
aws logs tail /aws/lambda/fluidity-lambda-kill --follow
```

**Lambda Metrics (Wake):**
```bash
# Invocations
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Invocations \
  --dimensions Name=FunctionName,Value=fluidity-lambda-wake \
  --statistics Sum,Average \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300

# Errors
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Errors \
  --dimensions Name=FunctionName,Value=fluidity-lambda-wake \
  --statistics Sum \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300

# Duration
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Duration \
  --dimensions Name=FunctionName,Value=fluidity-lambda-wake \
  --statistics Average,Maximum \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300
```

---

## Security

**Function URL Security:**
- Public endpoints by default (no authentication required)
- HTTPS only (enforced by AWS)
- Optional: Restrict via resource-based IAM policies
- Agent validates mTLS certificates when contacting server

**Best Practices:**
- Monitor CloudWatch Logs for errors
- Set up CloudWatch alarms for Lambda failures
- Use IAM resource policies to restrict access if needed
- Keep Lambda roles with minimal permissions (already configured)

---

## Troubleshooting

**Function URL returns error:**
```bash
# Check function exists
aws lambda get-function --function-name fluidity-lambda-wake

# View recent logs
aws logs tail /aws/lambda/fluidity-lambda-wake --follow --since 10m

# Check for errors
aws logs filter-log-events \
  --log-group-name /aws/lambda/fluidity-lambda-wake \
  --filter-pattern "ERROR"
```

**Wake Lambda fails to update ECS:**
- Verify cluster name: `aws ecs describe-clusters --clusters fluidity`
- Verify service exists: `aws ecs describe-services --cluster fluidity --services fluidity-server`
- Check IAM role: `aws iam get-role --role-name <role-name>`

**Sleep Lambda not scaling down:**
- Verify server metrics enabled: `grep emit_metrics configs/server.yaml`
- Check CloudWatch metrics: `aws cloudwatch list-metrics --namespace Fluidity`
- Verify Sleep Lambda has `cloudwatch:GetMetricData` permission

**Connection timeout in agent:**
- Increase `connection_timeout` in agent config if server takes > 90s to start
- Check Wake Lambda was invoked: `aws logs tail /aws/lambda/fluidity-lambda-wake`
- Verify server security group allows agent IP on port 8443

---

## Migration from API Gateway

Previously, Fluidity used API Gateway REST API with API keys and rate limiting.

**Benefits of Lambda Function URLs:**
- 90% cost reduction
- Simpler architecture (fewer AWS resources)
- Faster invocation
- No API key management needed
- Direct Lambda invocation

**Key Differences:**

| Aspect | API Gateway | Function URL |
|--------|-------------|--------------|
| Cost | ~$0.35/month | <$0.05/month |
| Endpoint | `https://<api-id>.execute-api.region.amazonaws.com/prod/wake` | `https://<id>.lambda-url.region.on.aws/` |
| Auth | API keys | Optional policies |
| CORS | Configurable | Built-in |
| Rate limit | Quota-based | Lambda concurrency |
| Paths | `/wake`, `/kill` | Single function |

---

## Related Documentation

- [Infrastructure Guide](infrastructure.md) - CloudFormation details
- [Deployment Guide](deployment.md) - Full setup
- [Architecture](architecture.md) - System design

````
