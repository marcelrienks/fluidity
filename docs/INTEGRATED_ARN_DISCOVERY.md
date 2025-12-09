# Phase 3.4+: Integrated ARN Discovery Architecture

**Document:** Architecture for Unique CN with ARN Discovery  
**Status:** Planned Enhancement  
**Date:** December 9, 2025

## Overview

This document describes the Phase 3.4+ enhancement that adds per-instance identity (ARN-based CN) to certificates through an integrated architecture where Query Lambda provides server ARN to agent, and server self-discovers its own ARN.

## Current State (Phase 3.3)

### Fixed CN Architecture

```
Agent Startup:
├─ Detect local IP
├─ Generate CSR with CN=fluidity-client, SAN=local_ip
├─ Call CA Lambda
└─ Get signed certificate

Server Startup:
├─ Generate CSR with CN=fluidity-server (no SAN)
├─ Call CA Lambda
└─ Get signed certificate

Agent → Server Connection:
├─ Query Lambda returns: {"server_ip": "10.0.1.5"}
├─ Agent validates server CN == "fluidity-server"
├─ Mutual TLS established
└─ Fixed CN used for all instances
```

## Enhanced State (Phase 3.4+)

### Unique CN Architecture with Integrated ARN Discovery

```
Agent Startup:
├─ Detect local IP
├─ Query Lambda returns:
│  ├─ "server_ip": "10.0.1.5"
│  └─ "server_arn": "arn:aws:ecs:region:account:task/abc123"
├─ Generate CSR with CN=<agent_arn>, SAN=local_ip
├─ Call CA Lambda
└─ Get signed certificate

Server Startup:
├─ Discover own ARN from:
│  ├─ ECS_TASK_ARN (ECS Fargate, automatic)
│  ├─ SERVER_ARN env var (CloudFormation parameter)
│  └─ EC2 metadata (fallback for EC2)
├─ Generate CSR with CN=<server_arn> (no SAN)
├─ Call CA Lambda
└─ Get signed certificate

Agent → Server Connection:
├─ Query Lambda returns: {"server_ip": "10.0.1.5", "server_arn": "arn:..."}
├─ Agent validates server CN == expected ARN
├─ Agent validates ARN matches source IP
├─ Mutual TLS established
└─ Unique CN used (per-instance identity)
```

## Design Benefits

### 1. Single Authenticated Source for Server Identity

**Current (Phase 3.3):**
```
Agent gets IP from Query Lambda
Agent connects to that IP
Agent validates CN == "fluidity-server"
Problem: All servers have same CN
```

**Enhanced (Phase 3.4+):**
```
Agent gets IP + ARN from Query Lambda (single call)
Agent connects to that IP
Agent validates CN == that specific ARN
Benefit: Unique identity, can't be substituted
```

### 2. Server Self-Identification

**Current:** Server doesn't need to know its own ARN

**Enhanced:** Server discovers its own ARN
- ECS Fargate: Automatic ($ECS_TASK_ARN)
- CloudFormation: Explicit (SERVER_ARN parameter)
- EC2: Via metadata (fallback)
- Works across all deployment models

### 3. Per-Instance Security

**Threat:** Attacker compromises CA, creates fake "fluidity-server" cert

**Current Defense:**
- Cert must be signed by CA
- Attacker still needs CA key

**Enhanced Defense:**
- Cert must be signed by CA
- Cert CN must match specific ARN
- Attacker needs CA key + correct ARN
- Two factors instead of one

## Integration Points

### Query Lambda Enhanced Response

**Current:**
```json
{
  "server_ip": "10.0.1.5",
  "instance_id": "task-abc123"
}
```

**Enhanced:**
```json
{
  "server_ip": "10.0.1.5",
  "server_arn": "arn:aws:ecs:us-east-1:123456789:task/service/abc123def456",
  "instance_id": "task-abc123",
  "timestamp": "2025-12-09T10:34:28Z"
}
```

**Implementation Changes:**
- Query Lambda retrieves full task ARN (not just ID)
- Return ARN in response alongside IP
- Single API call provides both IP and ARN
- Agent receives both in one go

### Server ARN Discovery

**Three-Tier Fallback:**

```go
// Tier 1: ECS Fargate (automatic, preferred)
arn := os.Getenv("ECS_TASK_ARN")

// Tier 2: CloudFormation parameter (explicit, flexible)
if arn == "" {
    arn = os.Getenv("SERVER_ARN")
}

// Tier 3: EC2 Metadata (fallback, slower)
if arn == "" {
    arn = discoverFromEC2Metadata()
}
```

**Why This Works:**
- ECS Fargate: ~99% of Fluidity deployments (automatic)
- CloudFormation: For any deployment (explicit parameter)
- EC2: Fallback for EC2-direct deployments
- Covers all cases

## Implementation Timeline

### Phase 3.4+ (Future)

**Step 1: Query Lambda Enhancement (1-2 days)**
- Add ARN discovery to Query Lambda
- Return ARN in response
- Test with agent

**Step 2: Server ARN Discovery (1 day)**
- Implement ECS Fargate detection
- Implement CloudFormation parameter
- Implement EC2 metadata fallback

**Step 3: Agent Update (1 day)**
- Use ARN from Query Lambda response
- Pass ARN to certificate manager
- Validate server CN against ARN

**Step 4: Server Update (1 day)**
- Use discovered ARN for CSR
- Generate unique CN certificate
- Log discovered ARN

**Step 5: CSR Generator (1 day)**
- Add `GenerateCSRWithUniqueID()` function
- Support both fixed and unique CN modes

**Step 6: Configuration (1 day)**
- Add `use_unique_cn` flag
- Document migration path
- Add backward compatibility

**Step 7: Testing (2 days)**
- Test with ECS Fargate
- Test with CloudFormation parameter
- Test with EC2 metadata
- Test agent validation

**Step 8: Documentation (1 day)**
- Update certificate guide
- Add ARN discovery guide
- Add configuration examples

**Total: ~9-10 days (1.5 weeks)**

## Configuration

### Agent Configuration (Phase 3.4+)

```yaml
# Enable unique CN validation
use_unique_cn: true

# CA Lambda endpoint
ca_service_url: https://xxx.execute-api.region.amazonaws.com/prod/sign

# Certificate cache
cert_cache_dir: /var/lib/fluidity/certs

# Optional: Specific server ARN to expect (if not using Query Lambda)
expected_server_arn: "arn:aws:ecs:us-east-1:123456789:task/service/server-task"
```

### Server Configuration (Phase 3.4+)

```yaml
# Enable unique CN generation
use_unique_cn: true

# CA Lambda endpoint
ca_service_url: https://xxx.execute-api.region.amazonaws.com/prod/sign

# Certificate cache
cert_cache_dir: /var/lib/fluidity/certs

# ARN Sources (tried in order):
# 1. $ECS_TASK_ARN (automatic on Fargate)
# 2. $SERVER_ARN (CloudFormation parameter)
# 3. EC2 metadata (fallback)
```

### CloudFormation Example (Phase 3.4+)

```yaml
Resources:
  FluidityServerTask:
    Type: AWS::ECS::TaskDefinition
    Properties:
      ContainerDefinitions:
        - Name: fluidity-server
          Image: fluidity-server:latest
          Environment:
            - Name: SERVER_ARN
              Value: !Sub "arn:aws:ecs:${AWS::Region}:${AWS::AccountId}:task/service/${ServiceName}"
            - Name: CA_SERVICE_URL
              Value: !Sub "https://${CALambdaAPI}.execute-api.${AWS::Region}.amazonaws.com/prod/sign"
```

## Backward Compatibility

### Fallback Behavior

```
Phase 3.3 (Current):
- use_unique_cn: false (default)
- CN: fluidity-client / fluidity-server
- Works as normal

Phase 3.4+:
- use_unique_cn: false (still supported, default)
- CN: fluidity-client / fluidity-server
- Works as Phase 3.3

Phase 3.4+ with flag:
- use_unique_cn: true
- CN: <arn>
- Enhanced security
- ARN discovery required
```

### Migration Path

```
Step 1: Deploy Phase 3.4+ code
  → use_unique_cn defaults to false
  → Everything works as Phase 3.3

Step 2: Set use_unique_cn: true
  → Requires ARN discovery
  → Enhanced certificates generated

Step 3: Monitor and validate
  → Confirm mutual TLS works
  → Verify ARN validation

Step 4: Fully adopt
  → Retire fixed CN support (future)
```

## Security Analysis

### Attack Scenarios

**Scenario 1: CA Key Compromise**

Phase 3.3 (Fixed CN):
```
Attacker: "I have CA key, I forge cert with CN=fluidity-server"
Impact: Can impersonate any server
Defense: Only CA key prevents this
```

Phase 3.4+ (Unique CN):
```
Attacker: "I have CA key, I forge cert with CN=fluidity-server"
Agent: "That's wrong, I expect CN=arn:aws:ecs:...:task/abc123"
Impact: Forged cert rejected
Defense: Needs CA key + correct ARN (two factors)
```

**Scenario 2: Certificate Reuse**

Phase 3.3 (Fixed CN):
```
Attacker: "I stole server cert from instance A"
Attacker: "I'll use it on instance B"
Impact: Works if both instances trust same CA
```

Phase 3.4+ (Unique CN):
```
Attacker: "I stole server cert from instance A (CN=arn:...A)"
Instance B: "That ARN is wrong, rejecting cert"
Impact: Cert doesn't validate for different instance
```

**Scenario 3: Audit Trail**

Phase 3.3 (Fixed CN):
```
CloudWatch log: "Connection from fluidity-client"
Auditor: "Which agent is this? Can't tell from cert"
```

Phase 3.4+ (Unique CN):
```
CloudWatch log: "Connection from arn:aws:ec2:region:account:instance/i-abc123"
Auditor: "This is instance i-abc123, I can verify in AWS console"
```

## Performance Impact

### Latency Addition (Phase 3.4+)

**Server Startup:**
- ECS Fargate: +0ms (env var already set)
- CloudFormation: +0ms (env var already set)
- EC2 Metadata: +500-1000ms (first time only, then cached)

**Agent Startup:**
- Query Lambda: +0ms (already getting IP, just adds ARN to response)
- No additional network calls

**Overall:** Negligible impact on startup time

## Testing Strategy

### Unit Tests
- [ ] ARN parsing
- [ ] CSR generation with unique ID
- [ ] CN validation logic

### Integration Tests
- [ ] ECS Fargate ARN discovery
- [ ] CloudFormation parameter ARN
- [ ] EC2 metadata ARN discovery
- [ ] Query Lambda response parsing
- [ ] Agent validates server ARN

### End-to-End Tests
- [ ] Agent → Server with unique CN
- [ ] Server → Agent with unique CN
- [ ] Multi-instance scenario
- [ ] Fallback from unique to fixed CN

## Future Considerations

### OCSP Revocation (Beyond Phase 3.4+)

With unique CN per instance:
- Can revoke specific instance cert via OCSP
- Don't need to revoke all servers
- Incident response improved
- Scalable certificate lifecycle

### Metrics & Monitoring

- Track ARN discovery success rate
- Monitor certificate CN usage (fixed vs unique)
- Alert on ARN discovery failures
- Audit per-instance certificate generation

## Conclusion

Phase 3.4+ enhancement provides:
- ✅ Per-instance identity (ARN in CN)
- ✅ Better audit trail (ARN maps to resource)
- ✅ Enhanced security (ARN + CA key required to forge)
- ✅ Flexible discovery (Fargate auto, CloudFormation explicit, EC2 fallback)
- ✅ Single API call (Query Lambda provides both IP and ARN)
- ✅ Backward compatible (opt-in via flag)

Ready for implementation after Phase 3.3 testing complete.
