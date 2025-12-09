# Server ARN Discovery Methods

**Document:** Technical Guide for Server Self-Identification  
**Date:** December 9, 2025  
**Scope:** Phase 3.4+ Enhancement - Unique CN Implementation

## Overview

Servers need to discover their own AWS resource ARN to use as the certificate CN. Unlike agents (which get ARN from Query Lambda), servers must retrieve it directly from their environment.

## Method 1: ECS Fargate (Recommended for ECS) ✅

### How It Works

ECS Fargate automatically provides the task ARN via environment variable:
```bash
$ECS_TASK_ARN=arn:aws:ecs:us-east-1:123456789:task/service/abc123def456
```

### Implementation

```go
func DiscoverServerARNFromECSFargate() (string, error) {
    arn := os.Getenv("ECS_TASK_ARN")
    if arn == "" {
        return "", fmt.Errorf("ECS_TASK_ARN not set - not running on ECS Fargate")
    }
    return arn, nil
}
```

### Advantages ✅
- ✅ No API calls needed
- ✅ Available immediately at startup
- ✅ Highly reliable (provided by ECS runtime)
- ✅ Works offline (no network required)
- ✅ Standard ECS behavior (no special config)

### Disadvantages ❌
- ❌ Only works on ECS Fargate
- ❌ Won't work on EC2, Lambda, or local

### Availability
- **ECS Fargate:** ✅ Yes (automatic)
- **ECS on EC2:** ⚠️ Maybe (requires agent to set)
- **EC2 (standalone):** ❌ No
- **Lambda:** ❌ No
- **Local/Dev:** ❌ No

---

## Method 2: CloudFormation Parameter (Recommended for Non-ECS) ✅

### How It Works

Pass ARN as environment variable set during deployment:

**CloudFormation Template:**
```yaml
Resources:
  FluidityServer:
    Type: AWS::ECS::TaskDefinition
    Properties:
      ContainerDefinitions:
        - Name: fluidity-server
          Environment:
            - Name: SERVER_ARN
              Value: !Sub "arn:aws:ecs:${AWS::Region}:${AWS::AccountId}:task/service/${ServiceName}"
```

### Implementation

```go
func DiscoverServerARNFromCloudFormation() (string, error) {
    arn := os.Getenv("SERVER_ARN")
    if arn == "" {
        return "", fmt.Errorf("SERVER_ARN environment variable not set")
    }
    return arn, nil
}
```

### Advantages ✅
- ✅ Works with any deployment model
- ✅ Explicit, clear ownership (no magic)
- ✅ Can be set in CloudFormation, Terraform, Helm
- ✅ Works in EC2, Lambda, on-prem
- ✅ Easy to audit (value in template)

### Disadvantages ❌
- ❌ Requires manual setup (not automatic like ECS Fargate)
- ❌ Risk of mismatch between actual and configured ARN
- ❌ Need to pass ARN to deployment

### Availability
- **ECS Fargate:** ✅ Yes (if set in task definition)
- **ECS on EC2:** ✅ Yes (if set in task definition)
- **EC2 (standalone):** ✅ Yes (if set in user data / launch template)
- **Lambda:** ✅ Yes (if set in environment)
- **Local/Dev:** ✅ Yes (if set in shell)

---

## Method 3: EC2 Instance Metadata (For EC2 Direct)

### How It Works

Query EC2 metadata service to get instance ID, then build ARN:

```
GET http://169.254.169.254/latest/meta-data/instance-id
→ i-1234567890abcdef0

Build ARN: arn:aws:ec2:region:account:instance/i-1234567890abcdef0
```

### Implementation

```go
func DiscoverServerARNFromEC2Metadata() (string, error) {
    // Get instance ID
    instanceID, err := getEC2InstanceID()
    if err != nil {
        return "", err
    }
    
    // Get region
    region, err := getEC2Region()
    if err != nil {
        return "", err
    }
    
    // Get account ID (via STS)
    account, err := getAWSAccountID()
    if err != nil {
        return "", err
    }
    
    arn := fmt.Sprintf("arn:aws:ec2:%s:%s:instance/%s", region, account, instanceID)
    return arn, nil
}
```

### Challenges
- Requires network access (metadata service)
- Requires IAM permissions (STS GetCallerIdentity)
- Multiple API calls (~3 calls minimum)
- ~500-1000ms latency
- Fails if metadata service unavailable

### Advantages ✅
- ✅ Automatic (no config needed)
- ✅ Works on any EC2 instance

### Disadvantages ❌
- ❌ Network calls required
- ❌ IAM permissions required
- ❌ Slower (~1 second)
- ❌ Fails if metadata service down
- ❌ Not suitable for on-prem

### Availability
- **ECS Fargate:** ⚠️ Maybe (can access metadata)
- **EC2 (standalone):** ✅ Yes
- **Lambda:** ⚠️ Complex (doesn't use EC2 ARN)
- **On-prem:** ❌ No

---

## Method 4: Lambda Function Context (For Lambda)

### How It Works

Lambda runtime provides context with function ARN:

```go
import "github.com/aws/aws-lambda-go/lambda"

func Handler(ctx context.Context) error {
    lc, ok := lambdacontext.FromContext(ctx)
    arn := lc.InvokedFunctionArn
    // arn: arn:aws:lambda:region:account:function:function-name
}
```

### Advantages ✅
- ✅ Automatic (from Lambda runtime)
- ✅ No API calls needed
- ✅ Perfectly reliable

### Disadvantages ❌
- ❌ Only works in Lambda
- ❌ Fluidity server likely not running in Lambda (uses Fargate)

---

## Recommended Strategy

### Priority Order

**For Fluidity (ECS Fargate primary deployment):**

```go
func DiscoverServerARN() (string, error) {
    // Priority 1: ECS Fargate (automatic, preferred)
    if arn := os.Getenv("ECS_TASK_ARN"); arn != "" {
        return arn, nil
    }
    
    // Priority 2: CloudFormation/Manual (explicit, flexible)
    if arn := os.Getenv("SERVER_ARN"); arn != "" {
        return arn, nil
    }
    
    // Priority 3: EC2 Metadata (for EC2 deployments)
    if arn, err := discoverFromEC2Metadata(); err == nil {
        return arn, nil
    }
    
    // Priority 4: Lambda context (if running in Lambda)
    if arn, err := discoverFromLambdaContext(); err == nil {
        return arn, nil
    }
    
    return "", fmt.Errorf("unable to discover server ARN from any source")
}
```

### Configuration

```yaml
# agent.yaml - Tell agent which server ARN to expect
expected_server_arn: "arn:aws:ecs:us-east-1:123456789:task/service/abc123"

# OR get from Query Lambda response (Phase 3.4+ feature)
use_query_lambda_arn: true  # Use ARN from Query Lambda
```

## Implementation Considerations

### Fallback Chain

Server startup:
1. Try ECS Fargate → success, use it
2. Try CloudFormation env var → success, use it
3. Try EC2 metadata → success, use it
4. Try Lambda context → success, use it
5. All failed → Log error, fall back to fixed CN (Phase 3.3)

### Error Handling

```go
arn, err := DiscoverServerARN()
if err != nil {
    log.Warn("Could not discover server ARN, using fixed CN",
             "error", err.Error())
    // Fall back to Phase 3.3 behavior: CN=fluidity-server
    usedFixedCN = true
} else {
    log.Info("Discovered server ARN", "arn", arn)
    // Use unique CN with ARN
}
```

### Performance Impact

| Method | Latency | Reliability | Recommended |
|--------|---------|-------------|-------------|
| ECS Fargate | <1ms | 99.99% | ✅ |
| CloudFormation | 0ms | 100% | ✅ |
| EC2 Metadata | 500-1000ms | 99.9% | ⚠️ Fallback |
| Lambda Context | <1ms | 100% | ✅ (If Lambda) |

### Security Considerations

1. **ARN Validation**
   - Agent validates server ARN matches expected (from Query Lambda)
   - Prevents wrong instance from using server cert

2. **ARN Disclosure**
   - ARN in certificate is discoverable
   - ARN is not secret (just AWS resource identifier)
   - Safe to include in certificate

3. **ARN Spoofing**
   - Attacker could claim wrong ARN in CSR
   - CA Lambda should validate against Query Lambda result
   - Server ARN validation prevents this

---

## Conclusion

**ECS Fargate (Current Standard):** ✅
- Use `$ECS_TASK_ARN` (automatic, built-in)
- No additional setup needed

**CloudFormation (Flexible):** ✅
- Use `SERVER_ARN` environment variable
- Works with any deployment model
- Explicit and auditable

**EC2 Metadata (Fallback):** ⚠️
- Use as fallback for EC2 deployments
- Adds ~1 second latency
- Requires IAM permissions

**Recommendation:** Implement all three, use fallback chain. ECS Fargate gets ARN automatically, other deployments set `SERVER_ARN` via deployment tooling.

For Phase 3.4+ unique CN feature, this provides complete server self-identification capability across all AWS deployment models.
