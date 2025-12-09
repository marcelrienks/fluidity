# Fluidity Implementation Status

Project phase tracking and completed work summary.

## Current Phase: Phase 2 - Complete ✅

All core functionality has been successfully implemented, tested, and verified through manual testing.

---

## Completed Work Summary

Phase 2 is complete. All work items have been successfully implemented and documented in version control. Refer to git history for implementation details.

---

## Known Limitations & Future Work

### Phase 3: Dynamic Certificate Management (Option 6, Variant B)

**Status**: In Progress ⚙️ (Phase 3.1-3.2 Complete ✅)

**Objective**: Eliminate static certificate pre-generation and IP address hardcoding by implementing dynamic, locally-generated certificates at runtime.

**Problem Being Solved**:

- Current approach requires pre-generating certificates with hardcoded IP ranges
- IP addresses may change (CloudFront, Elastic IP reassignment, failover)
- Multiple servers require unique certificates with their specific IPs
- Current design with 1:1 agent/server relationships means each pair needs custom certificates

**Solution: Local Certificate Generation with CA Signing (Option 6, Variant B)**

#### Overview

```
Both Agent and Server generate their own certificates at startup:

Agent Startup:
├─ Detect local IP (eth0/en0 preferred)
├─ Generate CSR with IP as SAN
├─ Request CA signing from Lambda service
├─ Receive signed client.crt
└─ Connect to server with own certificate

Server Startup:
├─ Generate CSR with CommonName only (NO IP SAN)
├─ Request CA signing from Lambda service
├─ Receive signed server.crt
└─ Listen for agent connections
(Note: Server public IP known to agent via Query Lambda)

Connection:
├─ Agent validates server certificate (signed by CA, CN=fluidity-server) ✓
├─ Server validates agent certificate (signed by CA, IP SAN matches source) ✓
└─ Both trust CA (chain of trust)
```

#### Architecture Components

1. **Static CA Certificate** (One-time setup)
   - Generate once during project setup
   - Store securely in AWS Secrets Manager
   - Distribute to all agents and servers at deployment
   - Never changes (provides trust anchor)

2. **Lambda CA Service**
   - Receives Certificate Signing Requests (CSR)
   - Validates CSR format and CN/SAN structure
   - Signs with stored CA private key
   - Returns signed certificate with 1-year validity
   - **Note:** Validates CN is either "fluidity-client" or "fluidity-server"

3. **Agent Initialization** (Option A: IP-based SAN)
   - Detect local IP via network interfaces (eth0/en0 preferred)
   - Generate 2048-bit RSA key pair
   - Create CSR with CommonName=fluidity-client, SAN=detected local IP
   - Call CA Lambda function with CSR
   - Cache signed certificate locally
   - Use certificate for all server connections
   - **Server-side validation:** Verifies agent cert IP SAN matches connection source IP

4. **Server Initialization** (Option A: CN-only, no SAN IP)
   - Generate 2048-bit RSA key pair
   - Create CSR with CommonName=fluidity-server, SAN=(empty/not set)
   - Call CA Lambda function with CSR
   - Cache signed certificate locally
   - Use certificate for TLS listener
   - **Design Rationale:** Server doesn't know its public IP at generation time (may be behind load balancer, CloudFront, or have dynamic IP)
   - **Agent-side validation:** Verifies server cert CN=fluidity-server and is signed by CA; trusts IP from Query Lambda (separate, authenticated source)

#### Implementation Details

**Files to Create**:

- `internal/shared/certs/ca_client.go` - CA service client for Lambda calls
- `internal/shared/certs/csr_generator.go` - CSR generation and validation
- `internal/core/agent/cert_manager.go` - Agent certificate initialization
- `internal/core/server/cert_manager.go` - Server certificate initialization
- `cmd/lambdas/ca/main.go` - CA signing Lambda function
- `deployments/cloudformation/ca-lambda.yaml` - CloudFormation template for CA Lambda

**Configuration Changes**:

- `agent.yaml`: Add `ca_service_url` and `cert_cache_dir` parameters
- `server.yaml`: Add `ca_service_url` and `cert_cache_dir` parameters
- CloudFormation: Add CA Lambda function and environment variables

**Code Changes**:

- Agent: Add certificate initialization in `main.go` startup
- Server: Add certificate initialization in `main.go` startup
- Agent: Add IP detection for local IP (network interfaces)
- Server: No IP detection needed (uses CN-based validation)
- Both: Add CSR generation with crypto/x509
- CA Lambda: Add CSR parsing and certificate signing with crypto/x509

#### Design Decision: Option A (CN-based Server Validation)

**Why server certificate has no IP SAN:**

The implementation uses **Option A** design pattern:
- **Agent certificate:** Includes IP SAN (agent's detected local IP)
- **Server certificate:** No IP SAN (only CN=fluidity-server)

**Rationale:**

1. **Server doesn't know its public IP at startup**
   - Server may be behind load balancer (Elastic Load Balancer)
   - Server may be behind CloudFront or other CDN
   - Server may have dynamically assigned IP
   - EC2 metadata only returns private IP for containers

2. **Agent has authenticated IP source already**
   - Agent gets server IP from Query Lambda (AWS API call)
   - Query Lambda result is authenticated separately
   - No need for redundant IP validation in certificate

3. **Security not compromised**
   - Agent validates server cert CN=fluidity-server
   - Agent validates cert is signed by trusted CA
   - TLS 1.3 encryption prevents MITM
   - Agent validates agent's own IP SAN (bidirectional validation)
   - This matches HTTPS pattern: domain in cert, not IP

4. **Eliminates overlap with Query Lambda**
   - Server doesn't try to detect its own IP
   - Single source of truth for IP (Query Lambda)
   - Simpler deployment, fewer failure modes

#### Advantages

✅ **Dynamic IP Support**

- No hardcoded IP ranges
- Works with CloudFront, Elastic IPs, any IP
- Multiple servers on same infrastructure

✅ **Multi-Server Compatibility**

- Each server generates its own certificate
- Each agent gets certificate for its local IP
- Perfect for 1:1 agent/server architecture

✅ **Zero Pre-Generation**

- No manual certificate generation script
- Deployment step: just run binary
- Certs generated at startup automatically

✅ **Secure**

- CA-signed certificates (chain of trust)
- Proper mutual authentication
- Audit trail: can log each CA request

✅ **Scalable**

- Add new servers/agents without manual cert steps
- Works with auto-scaling groups
- Works with infrastructure as code (Terraform, CloudFormation)

✅ **Low Operational Overhead**

- Automatic certificate generation
- 1-year validity (minimal renewal concerns)
- No certificate distribution needed

#### Disadvantages

❌ **Additional Lambda Function**

- Requires CA Lambda deployment
- Lambda cold start adds ~100-200ms to startup
- Small monthly Lambda cost (~$0.20/month for typical usage)

❌ **Startup Time**

- IP detection: ~50ms
- CSR generation: ~50ms
- Lambda signing: ~200ms (includes cold start)
- Total: ~300-400ms additional startup time

❌ **CA Key Management**

- CA private key must be stored securely
- AWS Secrets Manager required (best practice)
- Must rotate CA key periodically (annual)

❌ **Dependency on Lambda**

- Agent/server can't start if CA Lambda is unreachable
- Requires network access to Lambda at startup
- Caching helps, but first boot requires connectivity

#### Phase 3 Sub-Tasks

- [x] Design CA Lambda function (CSR validation, signing)
- [x] Implement IP detection (EC2 metadata, network interfaces)
- [x] Implement CSR generation in shared package
- [x] Implement Agent certificate manager
- [x] Implement Server certificate manager
- [x] Create CA Lambda CloudFormation template
- [x] Add CA service client (retry logic, error handling)
- [ ] Testing: Local certificate generation
- [ ] Testing: CA Lambda signing
- [ ] Testing: Multi-server scenarios
- [ ] Documentation: Certificate management guide
- [ ] Documentation: CA Lambda operations
- [ ] Remove old `generate-certs.sh` script
- [ ] Update deployment guides to reference new approach

#### Timeline Estimate

- Design & API: 2 days
- CA Lambda implementation: 3 days
- Agent/Server integration: 4 days
- Testing (unit, integration, E2E): 5 days
- Documentation: 2 days
- **Total: ~16 days** (2-3 weeks)

#### Rollout Plan

**Phase 3.1**: CA Lambda infrastructure

- Implement and deploy CA Lambda
- Test with manual CSR requests
- Document CA operations

**Phase 3.2**: Agent certificate management

- Implement IP detection
- Implement CSR generation
- Implement CA client
- Test with local agent startup

**Phase 3.3**: Server certificate management

- Implement server-side certificate manager
- Test with local server startup
- Integration tests (agent + server with dynamic certs)

**Phase 3.4**: Deprecation

- Remove old `generate-certs.sh` dependencies
- Update all documentation
- Update deployment scripts

### Phase 3.4+: Enhanced Unique CN with ARN Discovery (Future Enhancement)

**Status**: Planned for Phase 3.4+ ⏳

**Objective**: Add optional per-instance identity (ARN-based CN) to certificates for enhanced security and audit capabilities.

**Current State (Phase 3.3)**: Fixed CN validation
- Agent cert: CN=fluidity-client (with IP SAN)
- Server cert: CN=fluidity-server (no SAN)
- Simple, secure, works everywhere

**Enhanced State (Phase 3.4+)**: Unique CN per instance
- Agent cert: CN=<agent_arn> (with IP SAN)
- Server cert: CN=<server_arn> (no SAN)
- Per-instance identity, better audit trail

#### Architecture: Integrated ARN Discovery

**Query Lambda Enhancement (Extended Response)**

```json
{
  "server_ip": "10.0.1.5",
  "server_arn": "arn:aws:ecs:us-east-1:123456789:task/service/abc123def456",
  "timestamp": "2025-12-09T10:34:28Z"
}
```

Agent receives both IP and ARN from Query Lambda in single call:
- Agent uses IP to connect to server
- Agent uses ARN to validate server's certificate CN
- Single authenticated source for both values

**Server ARN Discovery (From ECS/CloudFormation)**

Server can retrieve its own ARN from multiple sources:
1. **ECS Fargate (Best)**: `$ECS_TASK_ARN` environment variable
   - Automatically provided by ECS
   - Always available in Fargate
   - No additional API calls needed

2. **CloudFormation (Fallback)**: Via stack parameters
   - Pass task ARN via environment variable
   - Set during deployment

3. **EC2 (Fallback)**: Via IAM role
   - Use boto3/aws-cli to describe self
   - Requires IAM permissions

#### Implementation Plan (Phase 3.4+)

**Step 1: Update Query Lambda Response**
```go
type QueryResponse struct {
    ServerIP  string `json:"server_ip"`
    ServerARN string `json:"server_arn"`
}
```

**Step 2: Server ARN Discovery**
```go
// Server startup
arn := os.Getenv("ECS_TASK_ARN")  // Fargate provides this
if arn == "" {
    arn = os.Getenv("SERVER_ARN")  // CloudFormation parameter
}
if arn == "" {
    arn = discoverARNFromEC2Metadata()  // Fallback
}
```

**Step 3: Agent Configuration Enhancement**
```yaml
# Optional: Enable unique CN validation
use_unique_cn: false  # Phase 3.3 (default, fixed CN)
use_unique_cn: true   # Phase 3.4+ (unique CN per instance)
```

**Step 4: Certificate Generation with Unique CN**
```go
// Agent uses server ARN from Query Lambda response
csrBytes, err := certs.GenerateCSRWithUniqueID("fluidity-agent", agentARN, privKey)

// Server uses its own discovered ARN
csrBytes, err := certs.GenerateCSRWithUniqueID("fluidity-server", serverARN, privKey)
```

#### Security Benefits

**Threat Mitigation:**

1. **CA Key Compromise** (With Unique CN)
   ```
   Attacker: "I have CA key, I'll forge fluidity-server cert"
   Defense: "Wrong ARN, cert invalid for this instance"
   Result: Attacker needs correct ARN + CA key (much harder)
   ```

2. **Certificate Reuse**
   ```
   Attacker: "I'll use leaked server cert from instance A for instance B"
   Defense: "CN=arn:instance-A, but server is instance-B"
   Result: Cert won't validate
   ```

3. **Audit Trail**
   ```
   Certificate CN directly maps to AWS resource
   → CloudWatch logs show which instance used which cert
   → Compliance auditors can verify per-instance certificates
   ```

#### Configuration Example (Phase 3.4+)

```yaml
# agent.yaml
use_unique_cn: true
ca_service_url: https://xxx.execute-api.region.amazonaws.com/prod/sign
cert_cache_dir: /var/lib/fluidity/certs

# server.yaml
use_unique_cn: true
ca_service_url: https://xxx.execute-api.region.amazonaws.com/prod/sign
cert_cache_dir: /var/lib/fluidity/certs
```

#### Compatibility & Rollout

✅ **Backward Compatible**
- Phase 3.3: Works with fixed CN
- Phase 3.4+: Optional feature flag (default off)
- Can enable per-deployment
- No breaking changes

**Migration Path:**
```
Phase 3.3 (Current):  use_unique_cn: false  ← Works now
     ↓
Phase 3.4+:          use_unique_cn: true   ← Opt-in enhancement
     ↓
Future:              use_unique_cn: true   ← Can default to true
```

#### Implementation Effort

- Update Query Lambda: 1-2 days
- Update Agent cert manager: 1 day
- Update Server cert manager: 1 day
- Testing: 2 days
- Documentation: 1 day
- **Total: ~6-7 days** (1-1.5 weeks)

#### Phase 3.4+ Sub-Tasks

- [ ] Update Query Lambda to return ARN
- [ ] Implement server ARN discovery (ECS/CloudFormation)
- [ ] Add GenerateCSRWithUniqueID function
- [ ] Update agent cert manager for unique CN
- [ ] Update server cert manager for unique CN
- [ ] Add use_unique_cn configuration flag
- [ ] Test with ECS task ARN discovery
- [ ] Test with CloudFormation parameter
- [ ] Test agent ARN validation from Query Lambda
- [ ] Documentation: Unique CN operations guide
- [ ] Migration guide: Fixed CN → Unique CN

### Optional Improvements (Post Phase 3)

- [ ] Metrics dashboard (CloudWatch integration)
- [ ] Advanced logging aggregation
- [ ] Health check improvements
- [ ] Certificate auto-renewal before expiration
- [ ] CA key rotation automation

---

## Deployment Guide

### Quick Start (Production)

```bash
./scripts/deploy-fluidity.sh deploy
fluidity
curl -x http://127.0.0.1:8080 http://example.com
```

### Local Development

```bash
./scripts/generate-certs.sh
./scripts/build-core.sh
./build/fluidity-server -config configs/server.local.yaml  # Terminal 1
./build/fluidity-agent -config configs/agent.local.yaml    # Terminal 2
curl -x http://127.0.0.1:8080 http://example.com
```

### Docker Testing

```bash
./scripts/build-docker.sh --server --agent
docker-compose -f deployments/docker-compose.test.yml up
```

See [Deployment Guide](deployment.md) for detailed instructions.

---

## Documentation

- **[Architecture](architecture.md)**: System design and component details
- **[Deployment](deployment.md)**: Setup for all environments (local, Docker, AWS)
- **[Development](development.md)**: Development environment and coding practices
- **[Infrastructure](infrastructure.md)**: AWS CloudFormation templates
- **[Certificate](certificate.md)**: mTLS certificate generation and management
- **[Launch](LAUNCH.md)**: Quick reference for running agent and browser
- **[Product](product.md)**: Features and capabilities overview

---

## Version Information

- **Status**: Phase 2 Complete
- **Build Version**: b7cde93 (Logging standardization)
- **Go Version**: 1.23+
- **Docker Image Size**: ~44MB (Alpine)
- **Last Updated**: December 8, 2025

---

## Notes for Future Development

1. **Code Quality**: All code follows Go conventions with gofmt and proper error handling
2. **Testing Strategy**: Comprehensive unit and integration tests, plus manual verification
3. **Logging**: Structured JSON logging with configurable levels (debug, info, warn, error)
4. **Security**: mTLS only, no unencrypted communications, SigV4 signature validation
5. **Performance**: Efficient WebSocket tunneling, connection pooling, circuit breaker pattern

---

See [Deployment](deployment.md) for current operations and [Development](development.md) for contributing
