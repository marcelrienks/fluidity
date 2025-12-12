# Outstanding Work - Fluidity ARN-Based Certificates
## Outstanding Tasks - Optimized Execution Order

## Phase 1: Core Implementation

### 1. Runtime Integration Verification ✅

Validation functions exist but need integration into actual connection handlers.

**Agent Connection** (`internal/core/agent/`):

- [x] Call `CreateARNValidatingClientConfig()` when establishing TLS connection
  - Pass: serverARN (from cert manager), targetIP (connection target)
- [x] Verify TLS handshake uses validating config with `VerifyPeerCertificate` callback

**Server Connection** (`internal/core/server/`):

- [x] Call `CreateARNValidatingServerConfig()` or add manual validation
  - Pass: serverARN (from cert manager)
- [x] Extract source IP from incoming connection (for lazy cert generation)
  - Used as agentIP parameter in `EnsureCertificateForConnection()`
- [x] Validate client IP after TLS handshake with `ValidateClientIPOnConnection()`

### 2. Dynamic Certificate Generation - Make It Default/Only Mode ✅ COMPLETE
**Rationale**: Remove configuration complexity by making dynamic cert generation the only supported mode

- [x] Remove `use_secrets_manager` configuration option from agent config
- [x] Remove `use_dynamic_certs` boolean flag - always true
- [x] Remove certificate file path options from agent config (cert_file, key_file - but kept ca_cert_file for CA validation)
- [x] Update agent config struct to remove unused certificate file fields
- [x] Update agent main.go to remove multi-mode certificate loading logic
- [x] Update deploy-agent.sh to remove --cert-path, --key-path, --ca-cert-path CLI options
- [x] Remove CertificatesSecretArn from Fargate CloudFormation template (not in codebase)
- [x] Remove Secrets section from Fargate task container definition (not in codebase)

### 3. CloudFormation - Integrate CA Lambda Into Main Lambda Stack ✅ COMPLETE
**Rationale**: Simplify deployment by making CA Lambda part of the control plane stack, not separate

- [x] Move CA Lambda function into lambda.yaml CloudFormation template
- [x] Add CA Lambda function resource to lambda.yaml
- [x] Add CA Lambda environment variables (CA_SECRET_NAME)
- [x] Add CA Lambda IAM role and permissions to lambda.yaml
- [x] Add CA API Gateway endpoint to lambda.yaml
- [x] Add CA Lambda outputs (CAAPIEndpoint) to lambda.yaml
- [x] Remove separate ca-lambda.yaml CloudFormation template from deployments/cloudformation/
- [x] Update deploy-server.sh to remove CA_STACK_NAME and CA_TEMPLATE references
- [x] Update deploy-server.sh to retrieve CAAPIEndpoint from LAMBDA_STACK_NAME (not separate CA stack)
- [x] No deploy-fluidity.sh changes needed (didn't reference CA stack)

### 4. Agent Configuration - Minimal Design ✅ COMPLETE
**Rationale**: Configuration should only include required runtime settings

Minimal agent.yaml now contains:
```yaml
# Server discovery endpoints (required)
wake_endpoint: ""
query_endpoint: ""
kill_endpoint: ""

# Dynamic certificate generation (required)
ca_service_url: ""
cert_cache_dir: "./certs"

# Tunnel settings
server_port: 8443
local_proxy_port: 8080

# Logging
log_level: "info"
```

- [x] Removed iam_role_arn (uses AWS SDK default credential chain)
- [x] Removed aws_profile (uses AWS SDK default credential chain)
- [x] Removed aws_region (uses AWS SDK default region)
- [x] Removed cert_file, key_file (dynamic mode only)
- [x] Kept ca_cert_file (needed for TLS root CA validation)
- [x] Removed use_dynamic_certs flag (always true)
- [x] Removed use_secrets_manager flag (not supported)
- [x] Server_ip not required in config (discovered at runtime via Wake/Query)
- [x] Updated agent.yaml with minimal config template
- [x] Updated agent.local.yaml for local development
- [x] Updated agent.docker.yaml for docker-compose
- [x] Updated agent.windows-docker.yaml for Windows Docker

### 5. Deployment Script Simplification - Server
**Rationale**: Simplify to essential deployment steps only

- [ ] Remove certificate handling code from deploy-server.sh
- [ ] Remove pre-deployment cert parameters and validation
- [ ] Remove unused configuration collection code
- [ ] Simplify deployment to core steps: Build Lambdas → Upload S3 → Deploy Fargate → Deploy Lambda (with CA)

### 6. Deployment Script Simplification - Agent ✅ COMPLETE
**Rationale**: Remove options that don't align with runtime cert generation architecture

- [x] Remove --cert-path, --key-path, --ca-cert-path options from deploy-agent.sh
- [x] Remove --iam-role-arn, --access-key-id, --secret-access-key options from deploy-agent.sh
- [x] Keep only required options:
  - [x] --wake-endpoint (required)
  - [x] --query-endpoint (required)
  - [x] --kill-endpoint (required)
  - [x] --ca-service-url (auto-filled from deployment)
  - [x] --server-port (optional, default 8443)
  - [x] --local-proxy-port (optional, default 8080)
  - [x] --log-level (optional, default info)
- [x] Remove aws_profile, iam_role_arn from agent.yaml generation
- [x] Remove setup_aws_credentials function call from deploy-agent.sh

### 7. Deployment Script Simplification - Fluidity Master ✅ COMPLETE
**Rationale**: Simplify main deployment flow

- [x] Remove certificate path collection from deploy-fluidity.sh
- [x] Remove IAM credential handling from deploy-fluidity.sh
- [x] Remove cert-path, key-path, ca-cert-path argument passing
- [x] Simplify to: Deploy server → Deploy agent (with auto-filled ca_service_url)

## Phase 2: Code Quality & Cleanup

### 8. Unit Test Coverage
**Status**: Not Started

- [ ] ARN validation function tests
- [ ] IP validation function tests
- [ ] Certificate generation function tests
- [ ] Certificate caching function tests
- [ ] Wake Lambda response parsing tests
- [ ] Query Lambda response parsing tests
- [ ] Configuration loading tests (minimal config)
- [ ] Error handling function tests

### 9. Code Review Checklist
**Status**: Not Started

- [ ] All unused configuration options removed
- [ ] No certificate file fallback code remaining
- [ ] No Secrets Manager code paths remaining
- [ ] Dynamic cert is only path taken
- [ ] All validation functions properly called
- [ ] Error messages clear and actionable
- [ ] No commented-out legacy code
- [ ] CA Lambda properly integrated into Lambda stack

### 10. Build & Compilation
**Status**: Not Started

- [ ] No compilation warnings
- [ ] No linting errors: `golangci-lint run ./...`
- [ ] All imports used
- [ ] No dead code detected
- [ ] go fmt passes
- [ ] go vet passes

## Phase 3: Integration Testing

### 11. Integration Tests
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

### 12. Error Scenarios Testing
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

### 13. End-to-End Testing
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

### 14. Performance Benchmarks
**Status**: Not Started

- [ ] First connection certificate generation: target ~500ms
- [ ] Cached certificate reuse: target <10ms
- [ ] CSR generation time: measure and document
- [ ] CA Lambda response time: measure and document
- [ ] Certificate validation time: measure and document
- [ ] Multi-agent SAN update time: measure with 10+ agents

## Definition of Done

When all items complete:

**Architecture**
- ✅ Dynamic certificates is the only supported mode
- ✅ CA Lambda integrated into main Lambda CloudFormation stack
- ✅ No pre-deployed certificates (except CA certificate)
- ✅ No Secrets Manager certificate support
- ✅ No legacy multi-mode configuration

**Implementation**
- ✅ ARN validation integrated into agent connection handlers
- ✅ ARN validation integrated into server connection handlers
- ✅ IP validation on all connections
- ✅ Configuration simplified to minimal required fields
- ✅ Deployment scripts simplified and streamlined

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

**Quality**
- ✅ All unit tests passing
- ✅ All integration tests passing
- ✅ All E2E tests passing
- ✅ All error scenarios tested
- ✅ Performance benchmarks documented
- ✅ No linting or compilation errors
- ✅ Code review checklist complete
