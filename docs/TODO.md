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
