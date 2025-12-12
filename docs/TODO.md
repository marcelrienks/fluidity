# Outstanding Work - Fluidity ARN-Based Certificates

**Status**: ~95% Complete. Core implementation done; CA certificate generation and deployment flow complete. Needs runtime integration verification and comprehensive testing.

---

## Completed Tasks ✅

### Pre-Deployment CA Certificate
- ✅ Created `scripts/generate-ca-certs.sh` - Generates CA certificate and uploads to AWS Secrets Manager
- ✅ Updated `docs/deployment.md` - Clear instructions for CA setup before deployment
- ✅ Documented certificate generation timeline

### Code & Deployment Alignment
- ✅ Server: Uses lazy certificate generation (key at startup, cert on first connection)
- ✅ Agent: Generates certificate at startup using Wake Lambda response
- ✅ CloudFormation: Aligned with runtime certificate generation
- ✅ Deploy script: No pre-deployment certificate generation for agent/server

---

## Outstanding Tasks

### 1. Runtime Integration Verification

Validation functions exist but need integration into actual connection handlers.

**Agent Connection** (`internal/core/agent/`):

- [ ] Call `CreateARNValidatingClientConfig()` when establishing TLS connection
  - Pass: serverARN (from cert manager), targetIP (connection target)
- [ ] Verify TLS handshake uses validating config with `VerifyPeerCertificate` callback

**Server Connection** (`internal/core/server/`):

- [ ] Call `CreateARNValidatingServerConfig()` or add manual validation
  - Pass: serverARN (from cert manager)
- [ ] Extract source IP from incoming connection (for lazy cert generation)
  - Used as agentIP parameter in `EnsureCertificateForConnection()`
- [ ] Validate client IP after TLS handshake with `ValidateClientIPOnConnection()`

**Verification Commands**:

```bash
grep -r "CreateARNValidatingClientConfig" internal/core/agent/
grep -r "CreateARNValidatingServerConfig" internal/core/server/
grep -r "RemoteAddr\|sourceIP" internal/core/server/
grep -r "EnsureCertificateForConnection" internal/core/server/
```

---

### 2. Integration Tests

- [ ] Wake Lambda extracts agent IP from HTTP source correctly
- [ ] Wake Lambda returns: serverARN, serverPublicIP, agentPublicIP
- [ ] Agent receives Wake response and generates cert with CN=serverARN, SAN=[agentIP]
- [ ] Server discovers ARN/IP at startup
- [ ] Server generates cert on first connection with both server and agent IPs
- [ ] Agent validates server cert: CN == serverARN ✓
- [ ] Agent validates server cert: connection IP in SAN ✓
- [ ] Server validates agent cert: CN == serverARN ✓
- [ ] Server validates agent cert: source IP in SAN ✓
- [ ] Second agent connects: server cert SAN updated with new IP
- [ ] Same agent reconnects: uses cached cert (no regeneration)
- [ ] Multi-agent scenario: server cert accumulates IPs over time

---

### 3. End-to-End Tests

- [ ] Full flow: Wake Lambda → Server starts → Agent connects → Mutual validation ✓
- [ ] First connection: ~500ms latency (cert generation)
- [ ] Subsequent connections: fast (cached cert)
- [ ] Error handling: ARN discovery failure (graceful degradation)
- [ ] Error handling: IP discovery failure (graceful degradation)
- [ ] Error handling: Wake Lambda unreachable (retry logic)
- [ ] Certificate renewal: 30 days before expiration
- [ ] All unit tests passing: `go test ./...`

---

### 4. Documentation Updates

**Architecture** (`docs/architecture.md`):

- [ ] Add sequence diagram: first agent connection (lazy generation)
- [ ] Add sequence diagram: subsequent connections (cached cert)
- [ ] Document multi-agent cert SAN accumulation
- [ ] ARN discovery fallback chain

**Deployment** (`docs/deployment.md`):

- [ ] Document Wake Lambda response with ARN fields
- [ ] Document Query Lambda returns serverARN
- [ ] Document agent receives serverARN from Wake Lambda
- [ ] Document server auto-discovers ARN
- [ ] Document first connection ~500ms latency
- [ ] Configuration examples: agent with wake/query endpoints
- [ ] Configuration examples: server with ARN-based lazy generation

**Runbook** (`docs/runbook.md`):

- [ ] Troubleshooting: ARN discovery failures
- [ ] Troubleshooting: IP discovery failures
- [ ] Troubleshooting: Certificate validation failures
- [ ] Troubleshooting: Multi-agent scenarios

---

### 5. Code Review Checklist

Before marking complete, verify:

```bash
# Agent integration
grep -r "NewCertManagerWithARN" internal/core/agent/
grep -r "GetServerARN" internal/core/agent/
grep -r "EnsureCertificate" internal/core/agent/

# Server integration
grep -r "NewCertManagerWithLazyGen" internal/core/server/
grep -r "InitializeKey" internal/core/server/
grep -r "EnsureCertificateForConnection" internal/core/server/

# Build test
go test ./...
```

---

## Definition of Done

- [ ] All runtime integration verified (validation is called in connections)
- [ ] All integration and E2E tests passing
- [ ] Documentation updated with ARN-based flow and examples
- [ ] No compilation errors or warnings
- [ ] `go test ./...` passes (excluding CA Lambda which needs secrets)

---

## Phase 1: Architecture Simplification (CRITICAL)

### 1.1 Dynamic Certificate Generation - Make It Default/Only Mode
**Rationale**: Remove configuration complexity by making dynamic cert generation the only supported mode

- [ ] Remove `use_secrets_manager` configuration option from agent config
- [ ] Remove `use_dynamic_certs` boolean flag - always true
- [ ] Remove certificate file path options from agent config (cert_file, key_file, ca_cert_file)
- [ ] Update agent config struct to remove unused certificate file fields
- [ ] Update agent main.go to remove multi-mode certificate loading logic
- [ ] Update deploy-agent.sh to remove --cert-path, --key-path, --ca-cert-path CLI options
- [ ] Remove CertificatesSecretArn from Fargate CloudFormation template
- [ ] Remove Secrets section from Fargate task container definition

### 1.2 CloudFormation - Integrate CA Lambda Into Main Lambda Stack
**Rationale**: Simplify deployment by making CA Lambda part of the control plane stack, not separate

- [ ] Move CA Lambda function into lambda.yaml CloudFormation template
- [ ] Add CA Lambda function resource to lambda.yaml
- [ ] Add CA Lambda environment variables (CA_SECRET_NAME)
- [ ] Add CA Lambda IAM role and permissions to lambda.yaml
- [ ] Add CA API Gateway endpoint to lambda.yaml
- [ ] Add CA Lambda outputs (CAAPIEndpoint) to lambda.yaml
- [ ] Remove separate ca-lambda.yaml CloudFormation template from deployments/cloudformation/
- [ ] Update deploy-server.sh to remove CA_STACK_NAME and CA_TEMPLATE references
- [ ] Update deploy-server.sh to retrieve CAAPIEndpoint from LAMBDA_STACK_NAME (not separate CA stack)
- [ ] Update deploy-fluidity.sh to get CA_SERVICE_URL from lambda_params exports instead of CA stack

### 1.3 Deployment Script Simplification - Agent
**Rationale**: Remove options that don't align with runtime cert generation architecture

- [ ] Remove --cert-path, --key-path, --ca-cert-path options from deploy-agent.sh
- [ ] Remove --preserve-config option from deploy-agent.sh
- [ ] Remove --iam-role-arn, --access-key-id, --secret-access-key options from deploy-agent.sh
- [ ] Keep only required options:
  - [ ] --wake-endpoint (required)
  - [ ] --query-endpoint (required)
  - [ ] --kill-endpoint (required)
  - [ ] --ca-service-url (auto-filled from deployment)
  - [ ] --server-port (optional, default 8443)
  - [ ] --local-proxy-port (optional, default 8080)
  - [ ] --log-level (optional, default info)
- [ ] Remove aws_profile, iam_role_arn from agent.yaml generation
- [ ] Remove IAM credential setup from deploy-agent.sh

### 1.4 Deployment Script Simplification - Server
**Rationale**: Simplify to essential deployment steps only

- [ ] Remove certificate handling code from deploy-server.sh
- [ ] Remove pre-deployment cert parameters and validation
- [ ] Remove unused configuration collection code
- [ ] Simplify deployment to core steps: Build Lambdas → Upload S3 → Deploy Fargate → Deploy Lambda (with CA)

### 1.5 Deployment Script Simplification - Fluidity Master
**Rationale**: Simplify main deployment flow

- [ ] Remove certificate path collection from deploy-fluidity.sh
- [ ] Remove IAM credential handling from deploy-fluidity.sh
- [ ] Remove cert-path, key-path, ca-cert-path argument passing
- [ ] Simplify to: Deploy server → Deploy agent (with auto-filled ca_service_url)

### 1.6 Agent Configuration - Minimal Design
**Rationale**: Configuration should only include required runtime settings

Minimal agent.yaml should contain:
```yaml
# Server discovery endpoints
wake_endpoint: "<url>"
query_endpoint: "<url>"
kill_endpoint: "<url>"

# Certificate generation (runtime)
ca_service_url: "<url>"
cert_cache_dir: "/path/to/certs"

# Tunnel settings
server_port: 8443
local_proxy_port: 8080

# Logging
log_level: "info"
```

- [ ] Remove iam_role_arn (use AWS SDK default credential chain)
- [ ] Remove aws_profile (use AWS SDK default credential chain)
- [ ] Remove aws_region (use AWS SDK default region)
- [ ] Remove cert_file, key_file, ca_cert_file (never used in dynamic mode)
- [ ] Remove use_dynamic_certs flag (always true)
- [ ] Remove use_secrets_manager flag (not supported)
- [ ] Remove server_ip from config (discovered at runtime via Wake/Query)

---

## Phase 2: Testing & Validation

### 2.1 Integration Tests
**Status**: Not Started

- [ ] Wake Lambda IP extraction from HTTP source
- [ ] Wake Lambda returns serverARN, serverPublicIP, agentPublicIP
- [ ] Query Lambda returns serverARN correctly
- [ ] Agent certificate generation with serverARN and agentIP
- [ ] Server lazy certificate generation on first connection
- [ ] Server certificate includes both serverIP and agentIP in SAN
- [ ] Multi-agent SAN accumulation (cert SAN grows with new agents)
- [ ] CA Lambda signing of valid CSRs
- [ ] CA Lambda rejection of invalid CSRs
- [ ] TLS validation: Agent validates serverARN in server cert
- [ ] TLS validation: Agent validates server connection IP in SAN
- [ ] TLS validation: Server validates serverARN in agent cert
- [ ] TLS validation: Server validates agent source IP in SAN
- [ ] Certificate caching: Same agent doesn't regenerate
- [ ] Certificate renewal: Expired certs are regenerated

### 2.2 End-to-End Testing
**Status**: Not Started

- [ ] Full deployment flow: deploy-fluidity.sh deploy (no flags)
- [ ] Agent starts without -c flag (auto-discovers config)
- [ ] Agent calls Wake Lambda successfully
- [ ] Agent certificate generation from CA Lambda
- [ ] Server starts and discovers ARN
- [ ] Server accepts first agent connection with dynamic cert
- [ ] First connection latency approximately 500ms
- [ ] Second connection reuses cached cert
- [ ] Second connection latency <10ms
- [ ] Multiple agents connect (SAN accumulation)
- [ ] Network traffic flows through tunnel
- [ ] HTTP requests properly proxied

### 2.3 Error Scenarios
**Status**: Not Started

- [ ] Missing ca_service_url in agent config → clear error message
- [ ] Missing serverARN from Wake Lambda → clear error with context
- [ ] Missing agentPublicIP from Wake Lambda → clear error with context
- [ ] CA Lambda unreachable → retry with backoff
- [ ] CA Lambda returns error → logged with context
- [ ] Invalid CSR format → CA Lambda rejects
- [ ] Invalid ARN format → validation rejects
- [ ] Invalid IP format → validation rejects
- [ ] Certificate cache directory not writable → error
- [ ] Certificate cache directory missing → auto-created
- [ ] Secrets Manager CA certificate missing → error with recovery steps
- [ ] Server IP discovery timeout → retry with backoff
- [ ] Agent IP discovery timeout → retry with backoff

### 2.4 Performance Benchmarks
**Status**: Not Started

- [ ] First connection certificate generation: target ~500ms
- [ ] Cached certificate reuse: target <10ms
- [ ] CSR generation time: measure and document
- [ ] CA Lambda response time: measure and document
- [ ] Certificate validation time: measure and document
- [ ] Multi-agent SAN update time: measure with 10+ agents

---

## Phase 3: Documentation Updates

### 3.1 Deployment Documentation
**File**: `docs/deployment.md`

- [ ] Remove "Prepare Certificates" deployment section
- [ ] Update to reflect CA cert as only pre-deployment requirement
- [ ] Document: Pre-deployment CA certificate setup (generate-ca-certs.sh)
- [ ] Document: Single deployment command (./deploy-fluidity.sh deploy)
- [ ] Document: No certificate parameters needed
- [ ] Document: Agent auto-discovers configuration
- [ ] Remove all certificate path parameters
- [ ] Remove IAM credential setup steps
- [ ] Document: Expected startup times and behavior
- [ ] Document: Multi-region deployment (if applicable)

### 3.2 Certificate Architecture Documentation
**File**: `docs/certificate.md`

- [ ] Remove legacy certificate section
- [ ] Remove Secrets Manager section
- [ ] Document: Dynamic cert generation as only mode
- [ ] Document: ARN-based identity system
- [ ] Document: IP-based authorization via SAN
- [ ] Document: Runtime generation flow (agent perspective)
- [ ] Document: Runtime generation flow (server perspective)
- [ ] Document: CA Lambda role and responsibilities
- [ ] Document: Certificate caching strategy
- [ ] Document: Multi-agent SAN accumulation

### 3.3 Architecture Documentation
**File**: `docs/architecture.md` (if exists, or create)

- [ ] Add sequence diagram: Agent startup and certificate generation
- [ ] Add sequence diagram: Server startup and ARN discovery
- [ ] Add sequence diagram: First agent connection (lazy cert generation)
- [ ] Add sequence diagram: Subsequent agent connection (cached cert)
- [ ] Add sequence diagram: Multi-agent SAN accumulation
- [ ] Document: ARN discovery fallback chain
- [ ] Document: IP discovery methods (ECS metadata, EC2 metadata)
- [ ] Document: Certificate SAN structure and validation
- [ ] Document: Error handling and recovery

### 3.4 Runbook/Troubleshooting Documentation
**File**: `docs/runbook.md`

- [ ] Troubleshooting: Agent fails to discover serverARN
- [ ] Troubleshooting: Server fails to discover its ARN
- [ ] Troubleshooting: Agent fails to discover server IP
- [ ] Troubleshooting: CA Lambda returns error
- [ ] Troubleshooting: Certificate validation failures
- [ ] Troubleshooting: Multi-agent connection issues
- [ ] Troubleshooting: Permission denied errors
- [ ] Troubleshooting: Timeout errors
- [ ] Common issues and resolutions checklist
- [ ] Log patterns to look for in debugging

### 3.5 Configuration Examples
**File**: `docs/deployment.md` or new `docs/configuration.md`

- [ ] Minimal agent.yaml example (only required fields)
- [ ] Lambda endpoint environment variables
- [ ] Server configuration example
- [ ] Common configuration mistakes and fixes

---

## Phase 4: Code Quality & Testing

### 4.1 Unit Test Coverage
**Status**: Not Started

- [ ] ARN validation function tests
- [ ] IP validation function tests
- [ ] Certificate generation function tests
- [ ] Certificate caching function tests
- [ ] Wake Lambda response parsing tests
- [ ] Query Lambda response parsing tests
- [ ] Configuration loading tests (minimal config)
- [ ] Error handling function tests

### 4.2 Code Review Checklist
**Status**: Not Started

- [ ] All unused configuration options removed
- [ ] No certificate file fallback code remaining
- [ ] No Secrets Manager code paths remaining
- [ ] Dynamic cert is only path taken
- [ ] All validation functions properly called
- [ ] Error messages clear and actionable
- [ ] No commented-out legacy code
- [ ] CA Lambda properly integrated into Lambda stack

### 4.3 Build & Compilation
**Status**: Not Started

- [ ] No compilation warnings
- [ ] No linting errors: `golangci-lint run ./...`
- [ ] All imports used
- [ ] No dead code detected
- [ ] go fmt passes
- [ ] go vet passes

---

## Definition of Done

When all items complete:

**Architecture**
- ✅ Dynamic certificates is the only supported mode
- ✅ CA Lambda integrated into main Lambda CloudFormation stack
- ✅ No pre-deployed certificates (except CA certificate)
- ✅ No Secrets Manager certificate support
- ✅ No legacy multi-mode configuration

**Deployment**
- ✅ Single deployment command: ./deploy-fluidity.sh deploy
- ✅ No certificate parameters needed
- ✅ No IAM credential parameters needed
- ✅ CA certificate pre-setup documented (one-time)
- ✅ Agent auto-discovers configuration

**Configuration**
- ✅ Minimal agent.yaml with only required fields
- ✅ No unused configuration options
- ✅ Clear documentation for each field

**Testing**
- ✅ All integration tests passing
- ✅ All E2E tests passing
- ✅ All error scenarios tested
- ✅ Performance benchmarks documented

**Documentation**
- ✅ Deployment guide updated
- ✅ Certificate architecture documented
- ✅ Architecture diagrams complete
- ✅ Troubleshooting guide complete
- ✅ Configuration examples provided

