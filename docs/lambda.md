# Lambda Control Plane

Three Lambda functions manage Fluidity server lifecycle using **Lambda Function URLs** (no API Gateway) for on-demand operation.

**Note for Windows users:** All commands in this guide should be run in WSL (Windows Subsystem for Linux).

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│            API Gateway (HTTP/HTTPS)                     │
│  POST /wake    POST /kill    GET /status                │
└────────────┬──────────────────┬──────────────┬──────────┘
             │                  │              │
       ┌─────▼──────┐      ┌────▼──────┐  ┌───▼──────┐
       │Wake Lambda │      │Kill Lambda│  │Status API│
       └─────┬──────┘      └────┬──────┘  └──────────┘
             │                  │
             └──────────┬───────┘
                        │
               ┌────────▼─────────┐
               │   ECS Service    │
               │ (DesiredCount=1) │
               └──────────────────┘

┌──────────────────────────────────────────────────┐
│         EventBridge Rules (Scheduled)            │
│  every 5 min  Sleep Lambda  Check metrics        │
│  nightly 11PM Kill Lambda   Shutdown             │
└──────────────────────────────────────────────────┘
```

---

## Functions

### Wake Lambda

**Purpose:** Start Fargate server (scale to 1)

**Trigger:** 
- API call via API Gateway
- Manual agent startup

**Execution:**
```bash
curl -X POST https://api-gateway-url/wake \
  -H "Authorization: Bearer <api-key>" \
  -d '{"clusterName":"fluidity-prod","serviceName":"fluidity-server-prod"}'
```

**Response:**
```json
{
  "action": "wake",
  "desiredCount": 1,
  "runningCount": 0,
  "message": "Server starting, will be available in 20-30 seconds"
}
```

**Code:** `internal/lambdas/wake/wake.go`

---

### Sleep Lambda

**Purpose:** Auto-scale down when idle (scale to 0)

**Trigger:** EventBridge rule (every 5 minutes)

**Logic:**
1. Fetch server metrics from CloudWatch
2. Check last activity timestamp
3. If idle > threshold (default 15 min), scale to 0
4. Log action

**Configuration:**

```yaml
# configs/server.yaml
emit_metrics: true
metrics_interval: "60s"
```

**CloudWatch Metrics Used:**
- `Fluidity/ActiveConnections`
- `Fluidity/LastActivityEpochSeconds`

**Response:**
```json
{
  "action": "sleep",
  "desiredCount": 0,
  "reason": "Idle for 15+ minutes",
  "savedAt": "2024-01-15T10:30:00Z"
}
```

**Code:** `internal/lambdas/sleep/sleep.go`

---

### Kill Lambda

**Purpose:** Immediate server shutdown (emergency/scheduled)

**Trigger:**
- API call (emergency)
- EventBridge rule (nightly at 11 PM UTC)

**Execution (API):**
```bash
curl -X POST https://api-gateway-url/kill \
  -H "Authorization: Bearer <api-key>" \
  -d '{"clusterName":"fluidity-prod","serviceName":"fluidity-server-prod"}'
```

**Response:**
```json
{
  "action": "kill",
  "desiredCount": 0,
  "killedAt": "2024-01-15T23:00:00Z"
}
```

**Code:** `internal/lambdas/kill/kill.go`

---

## Deployment

### 1. Build Lambda Functions

```bash
./scripts/build-lambdas.sh              # Linux/macOS
.\scripts\build-lambdas.ps1             # Windows
```

**Output:**
```
build/lambdas/
├── wake
├── sleep
└── kill
```

### 2. Deploy via CloudFormation

```bash
cd scripts

# Linux/macOS
./deploy-fluidity.sh -e prod -a deploy-lambda

# Windows PowerShell
.\deploy-fluidity.ps1 -Environment prod -Action deploy-lambda
```

**Parameters:**
- `ECSClusterName` - Target cluster (e.g., `fluidity-prod`)
- `ECSServiceName` - Target service (e.g., `fluidity-server-prod`)
- `IdleThresholdMinutes` - Idle timeout for sleep (default: 15)
- `SleepCheckInterval` - Sleep check frequency (default: 5 min)
- `LambdaS3Bucket` - S3 bucket with artifacts
- `LambdaS3KeyPrefix` - S3 key prefix

### 3. Test Functions

```bash
# Test Wake
aws lambda invoke \
  --function-name fluidity-wake \
  --payload '{"clusterName":"fluidity-prod","serviceName":"fluidity-server-prod"}' \
  response.json
cat response.json

# Test Kill
aws lambda invoke \
  --function-name fluidity-kill \
  --payload '{"clusterName":"fluidity-prod","serviceName":"fluidity-server-prod"}' \
  response.json
cat response.json

# Test Sleep (no payload needed)
aws lambda invoke \
  --function-name fluidity-sleep \
  response.json
cat response.json
```

---

## API Usage

### Wake Endpoint

**Request:**
```bash
curl -X POST https://<api-gateway-url>/wake \
  -H "Content-Type: application/json" \
  -d '{
    "clusterName": "fluidity-prod",
    "serviceName": "fluidity-server-prod"
  }'
```

**Response:**
```json
{
  "action": "wake",
  "desiredCount": 1,
  "runningCount": 0,
  "message": "Server starting..."
}
```

### Kill Endpoint

**Request:**
```bash
curl -X POST https://<api-gateway-url>/kill \
  -H "Content-Type: application/json" \
  -d '{
    "clusterName": "fluidity-prod",
    "serviceName": "fluidity-server-prod"
  }'
```

**Response:**
```json
{
  "action": "kill",
  "desiredCount": 0,
  "killedAt": "2024-01-15T23:00:00Z"
}
```

### Status Endpoint

**Request:**
```bash
curl -X GET https://<api-gateway-url>/status \
  -H "Content-Type: application/json"
```

**Response:**
```json
{
  "clusterName": "fluidity-prod",
  "serviceName": "fluidity-server-prod",
  "desiredCount": 1,
  "runningCount": 1,
  "deployments": 1,
  "events": [
    {
      "id": "1",
      "createdAt": "2024-01-15T10:30:00Z",
      "message": "service was unable to place a Fargate task"
    }
  ]
}
```

---

## Configuration

### Environment Variables

Set in Lambda environment:

```bash
ECS_CLUSTER_NAME=fluidity-prod
ECS_SERVICE_NAME=fluidity-server-prod
IDLE_THRESHOLD_MINUTES=15
SLEEP_CHECK_INTERVAL_MINUTES=5
```

### EventBridge Rules

**Sleep Rule:**
```yaml
Schedule: rate(5 minutes)
Target: Sleep Lambda
```

**Kill Rule:**
```yaml
Schedule: cron(0 23 * * ? *)    # 11 PM UTC daily
Target: Kill Lambda
```

---

## Monitoring

### CloudWatch Logs

View Lambda execution logs:

```bash
# Wake Lambda
aws logs tail /aws/lambda/fluidity-wake --follow

# Sleep Lambda
aws logs tail /aws/lambda/fluidity-sleep --follow

# Kill Lambda
aws logs tail /aws/lambda/fluidity-kill --follow
```

### CloudWatch Metrics

**Lambda Metrics:**
- `Duration` - Execution time
- `Errors` - Failed invocations
- `Throttles` - Rate-limited invocations
- `ConcurrentExecutions` - Concurrent running instances

**CloudWatch Alarms:**

```bash
# Alert on Lambda errors
aws cloudwatch put-metric-alarm \
  --alarm-name fluidity-lambda-errors \
  --alarm-description "Alert on Lambda function errors" \
  --metric-name Errors \
  --namespace AWS/Lambda \
  --statistic Sum \
  --period 300 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold
```

---

## Testing

### Unit Tests

```bash
cd tests/lambda/
pytest -v                          # All tests
pytest test_wake.py -v            # Wake function
pytest test_sleep.py -v           # Sleep function
pytest test_kill.py -v            # Kill function
```

**Test scenarios:**
- Wake when task stopped
- Wake when already running (idempotent)
- Sleep when idle
- No sleep when active
- Kill immediate shutdown

### Integration Tests

```bash
# Deploy test stack
aws cloudformation deploy \
  --template-file deployments/cloudformation/lambda.yaml \
  --stack-name fluidity-lambda-test \
  --parameter-overrides \
    ECSClusterName=fluidity-test \
    ECSServiceName=fluidity-server-test

# Test Wake
aws lambda invoke \
  --function-name fluidity-lambda-test-wake \
  --payload '{"clusterName":"fluidity-test","serviceName":"fluidity-server-test"}' \
  response.json

# Verify server started
aws ecs describe-services \
  --cluster fluidity-test \
  --services fluidity-server-test \
  --query 'services[0].{Desired:desiredCount,Running:runningCount}'
```

---

## Lifecycle Example

1. **Agent starts on local machine**
   - Agent calls Wake Lambda via API Gateway
   - Wake Lambda scales Fargate service to 1
   - Server starts and becomes reachable

2. **Agent forwards traffic**
   - HTTP requests tunneled through mTLS
   - Server metrics updated with activity

3. **No traffic for 15 minutes**
   - Sleep Lambda (EventBridge every 5 min) runs
   - Detects idle > 15 minutes
   - Scales service to 0

4. **Manual shutdown or 11 PM UTC**
   - Kill Lambda runs (API or scheduled)
   - Scales service to 0 immediately

5. **Agent disconnects**
   - Client closes connection
   - Waits for reconnect signal

---

## Troubleshooting

### Wake Lambda Fails

**Check logs:**
```bash
aws logs tail /aws/lambda/fluidity-wake --follow
```

**Common issues:**
- Cluster/service name incorrect
- Missing ECS permissions in Lambda role
- Subnet/security group issues

### Sleep Lambda Never Fires

**Verify EventBridge rule:**
```bash
aws events describe-rule --name fluidity-sleep-rule

aws events list-targets-by-rule --rule fluidity-sleep-rule
```

**Check metrics:**
```bash
aws cloudwatch get-metric-statistics \
  --namespace Fluidity \
  --metric-name ActiveConnections \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average
```

### API Gateway Timeout

**Increase timeout:**
```bash
aws apigateway update-integration \
  --rest-api-id <api-id> \
  --resource-id <resource-id> \
  --http-method POST \
  --type AWS_PROXY \
  --integration-http-method POST \
  --timeout-in-millis 30000    # 30 seconds
```

---

## Advanced Configuration

### Custom Idle Threshold

Edit CloudFormation parameters:

```bash
./deploy-fluidity.sh -e prod -a deploy-lambda \
  --idle-threshold-minutes 30
```

### Disable Sleep Lambda

Set `DailyKillTime` to prevent automatic shutdown:

```bash
aws cloudformation update-stack \
  --stack-name fluidity-lambda \
  --use-previous-template \
  --parameters ParameterKey=SleepEnabled,ParameterValue=false
```

### Add Custom Metrics

Modify Sleep Lambda to check custom metrics:

```python
# internal/lambdas/sleep/sleep.go
response := cwClient.GetMetricStatistics(ctx, &cloudwatch.GetMetricStatisticsInput{
    Namespace: aws.String("Fluidity"),
    MetricName: aws.String("CustomMetric"),
    // ... custom logic
})
```

---

## Related Documentation

- **[Deployment Guide](deployment.md)** - All deployment options
- **[Infrastructure as Code](infrastructure.md)** - CloudFormation details
- **[Fargate Guide](fargate.md)** - ECS setup
- **[Architecture](architecture.md)** - System design
- **[Testing Guide](testing.md)** - Test strategy
