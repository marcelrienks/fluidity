# Fluidity ARN-Based Certificate Implementation TODO

**Created:** December 9, 2025  
**Status:** In Progress

---

## Step 1: Discovery Functions (Shared Library)

### ARN Discovery
- [ ] Create `internal/shared/certs/arn_discovery.go`
- [ ] Implement `DiscoverServerARN()` function
- [ ] Add ECS Fargate ARN detection (`os.Getenv("ECS_TASK_ARN")`)
- [ ] Add CloudFormation parameter detection (`os.Getenv("SERVER_ARN")`)
- [ ] Add EC2 metadata ARN fallback (HTTP call to metadata service)
- [ ] Implement fallback chain logic
- [ ] Add error handling and logging for each discovery method
- [ ] Write unit tests for ARN discovery (mock env vars and HTTP responses)

### Public IP Discovery
- [ ] Create `internal/shared/certs/public_ip_discovery.go`
- [ ] Implement `DiscoverPublicIP()` function
- [ ] Add ECS task metadata IP detection
- [ ] Add EC2 metadata IP fallback
- [ ] Implement fallback chain logic
- [ ] Add error handling and logging for each discovery method
- [ ] Write unit tests for IP discovery (mock HTTP responses)

---

## Step 2: CSR Generator Enhancement

- [ ] Open `internal/shared/certs/csr_generator.go`
- [ ] Create `GenerateCSRWithARNAndMultipleSANs(privateKey, serverARN string, ipAddresses []string)` function
- [ ] Implement ARN format validation (regex: `^arn:aws:.*`)
- [ ] Implement IPv4 format validation for each IP in list
- [ ] Generate CSR with CN=serverARN
- [ ] Add all IPs to SAN extension
- [ ] Add helper function to append IPs to existing SAN list
- [ ] Write unit tests for various ARN and IP combinations
- [ ] Write unit tests for validation errors (invalid ARN, invalid IP)

---

## Step 3: CA Lambda Update

- [ ] Open CA Lambda function code (`cmd/lambdas/ca/main.go` or similar)
- [ ] Update CSR parsing to accept ARN format in CN
- [ ] Add ARN validation (regex: `^arn:aws:.*`)
- [ ] Update SAN parsing to accept multiple IPs
- [ ] Add IPv4 validation for each SAN entry
- [ ] Update certificate signing to include all SAN entries
- [ ] Add logging for CN and SAN details
- [ ] Update CloudFormation template if IAM permissions needed
- [ ] Write unit tests for ARN CN validation
- [ ] Write integration tests with multi-IP SAN
- [ ] Deploy updated CA Lambda

---

## Step 4: Wake Lambda Enhancement

- [ ] Open Wake Lambda function code (`cmd/lambdas/wake/main.go` or similar)
- [ ] Add HTTP source IP extraction from API Gateway/ALB event context
- [ ] Import and call `DiscoverServerARN()` from Step 1
- [ ] Import and call `DiscoverPublicIP()` from Step 1
- [ ] Add Redis/ElastiCache client initialization
- [ ] Store agent_public_ip in cache with key format `agent_ip:<timestamp>` and 1-hour TTL
- [ ] Add error handling if cache unavailable (warn but proceed)
- [ ] Update response structure to include `server_arn`, `server_public_ip`, `agent_public_ip_as_seen`
- [ ] Add logging for all discovered values and cache operations
- [ ] Write unit tests for IP extraction from API Gateway event
- [ ] Write integration tests for cache storage
- [ ] Update CloudFormation template to include ElastiCache resources (optional)
- [ ] Deploy updated Wake Lambda

---

## Step 5: Query Lambda Enhancement

- [ ] Open Query Lambda function code (`cmd/lambdas/query/main.go` or similar)
- [ ] Import and call `DiscoverServerARN()` from Step 1
- [ ] Add Redis/ElastiCache client initialization
- [ ] Retrieve agent_ip from cache (if available)
- [ ] Update response structure to include `server_arn` and optional `agent_ip`
- [ ] Add error handling if ARN discovery fails (return only server_ip)
- [ ] Add error handling if cache unavailable (skip agent_ip)
- [ ] Add logging for all values
- [ ] Write unit tests for response structure
- [ ] Update API documentation
- [ ] Deploy updated Query Lambda

---

## Step 6: Agent Certificate Generation

- [ ] Open `internal/core/agent/startup.go` (or certificate manager)
- [ ] Update Wake Lambda client to parse new response fields
- [ ] Extract `server_arn` from Wake Lambda response
- [ ] Extract `server_public_ip` from Wake Lambda response
- [ ] Extract `agent_public_ip_as_seen` from Wake Lambda response
- [ ] Update certificate manager to accept server_arn and agent_public_ip
- [ ] Call `GenerateCSRWithARNAndMultipleSANs(privateKey, serverARN, [agent_public_ip_as_seen])`
- [ ] Submit CSR to CA Lambda
- [ ] Cache received certificate
- [ ] Store server_arn in memory for later validation during connection
- [ ] Add error handling for Wake Lambda failures
- [ ] Add logging for all IP and ARN details
- [ ] Write unit tests for Wake Lambda response parsing
- [ ] Write unit tests for certificate generation flow

---

## Step 7: Server Lazy Certificate Generation

### Startup Changes
- [ ] Open `internal/core/server/startup.go`
- [ ] Call `DiscoverServerARN()` at startup
- [ ] Call `DiscoverPublicIP()` at startup
- [ ] Generate RSA key and cache for reuse
- [ ] Log ARN and public IP at startup
- [ ] Remove existing cert generation at startup (if present)
- [ ] Add comment: "DO NOT generate cert yet - lazy generation on first connection"

### TLS Connection Handler
- [ ] Open `internal/core/server/` TLS handler (or create new file)
- [ ] Add hook before TLS handshake to check cert validity
- [ ] Implement `ensureCertificateForConnection(agentIP string)` function
- [ ] Extract connection source IP from incoming connection
- [ ] Check if cached cert exists
- [ ] Check if agent IP already in cached cert SAN
- [ ] If cert missing OR agent IP not in SAN:
  - [ ] Build IP list: `[server_public_ip, agent_source_ip]` or append to existing SAN
  - [ ] Call `GenerateCSRWithARNAndMultipleSANs(privateKey, serverARN, ipList)`
  - [ ] Submit CSR to CA Lambda
  - [ ] Cache received certificate
  - [ ] Log cert generation event
- [ ] If cert exists with agent IP: use cached cert (fast path, log cache hit)
- [ ] Add error handling for cert generation failures (warn but attempt connection)
- [ ] Add cert renewal check (regenerate if <30 days to expiration)
- [ ] Add logging for all cert operations

### Testing
- [ ] Write unit tests for `ensureCertificateForConnection()`
- [ ] Write unit tests for cert caching logic
- [ ] Write unit tests for SAN IP checking
- [ ] Write integration tests for lazy generation on first connection
- [ ] Write integration tests for multi-agent cert accumulation

---

## Step 8: Runtime Validation

### Agent Validation
- [ ] Open `internal/core/agent/` TLS connection code
- [ ] Add TLS config with custom `VerifyPeerCertificate` callback
- [ ] Extract server certificate CN
- [ ] Validate CN == stored server_arn from Wake Lambda
- [ ] Extract server certificate SAN IPs
- [ ] Validate connection target IP is in SAN list
- [ ] Add detailed logging for validation steps
- [ ] Add error handling for validation failures (reject connection with clear message)
- [ ] Write unit tests for validation logic

### Server Validation
- [ ] Open `internal/core/server/` TLS handler
- [ ] Add TLS config with custom `VerifyPeerCertificate` callback
- [ ] Extract agent certificate CN
- [ ] Validate CN == self_arn
- [ ] Extract agent certificate SAN IPs
- [ ] Validate connection source IP is in agent cert SAN list
- [ ] Add detailed logging for validation steps
- [ ] Add error handling for validation failures (reject connection with clear message)
- [ ] Write unit tests for validation logic

### Integration Tests
- [ ] Write end-to-end test: agent connects to server, both validate successfully
- [ ] Write test: agent with wrong ARN is rejected by server
- [ ] Write test: agent connecting from different IP is rejected by server
- [ ] Write test: server with wrong ARN is rejected by agent

---

## Step 9: Configuration Updates

### Agent Config
- [ ] Open `configs/agent.local.yaml` and agent config schema
- [ ] Add `wake_lambda_url` field
- [ ] Add `query_lambda_url` field
- [ ] Ensure `ca_service_url` field exists
- [ ] Ensure `cert_cache_dir` field exists
- [ ] Update config parsing in `internal/core/agent/config.go`
- [ ] Add validation for required fields
- [ ] Update example configs

### Server Config
- [ ] Open `configs/server.local.yaml` and server config schema
- [ ] Ensure `ca_service_url` field exists
- [ ] Ensure `cert_cache_dir` field exists
- [ ] Add optional `cache_endpoint` for Redis/ElastiCache (if used)
- [ ] Update config parsing in `internal/core/server/config.go`
- [ ] Add comments explaining ARN/IP auto-discovery

### CloudFormation Templates
- [ ] Open CloudFormation templates in `deployments/`
- [ ] Add ElastiCache cluster resource (optional, document as optional)
- [ ] Add ElastiCache security group
- [ ] Add IAM permissions for Lambda to access ElastiCache
- [ ] Remove DynamoDB table resources (if any)
- [ ] Remove DynamoDB IAM permissions
- [ ] Update Lambda environment variables with cache endpoint
- [ ] Add outputs for ElastiCache endpoint

### Documentation
- [ ] Document all config fields in `docs/`
- [ ] Add configuration examples for local and AWS deployment
- [ ] Document cache as optional (warn if unavailable but proceed)

---

## Step 10: Comprehensive Testing

### Unit Tests
- [ ] Run all unit tests: `go test ./internal/shared/certs/...`
- [ ] Run all unit tests: `go test ./internal/core/agent/...`
- [ ] Run all unit tests: `go test ./internal/core/server/...`
- [ ] Run all unit tests: `go test ./cmd/lambdas/...`
- [ ] Verify coverage: `go test -cover ./...`
- [ ] Fix any failing tests

### Integration Tests
- [ ] Test Wake Lambda returns correct response structure
- [ ] Test Wake Lambda stores agent IP in cache
- [ ] Test Query Lambda returns server ARN
- [ ] Test CA Lambda accepts ARN CN
- [ ] Test CA Lambda accepts multi-IP SAN
- [ ] Test agent generates correct cert from Wake Lambda response
- [ ] Test server generates cert on first connection
- [ ] Test server includes both server and agent IPs in SAN
- [ ] Test agent and server validate certificates correctly

### End-to-End Tests
- [ ] Deploy all components to test environment
- [ ] Test: Agent calls Wake Lambda → server starts → agent connects → certs validated
- [ ] Test: First connection latency (~500ms for cert generation)
- [ ] Test: Second connection from same agent (fast path, cached cert)
- [ ] Test: Second agent connects (server regenerates cert with new IP)
- [ ] Test: Third agent connects (server cert has 3 IPs in SAN)
- [ ] Test: Multi-server scenario (each server has unique ARN)
- [ ] Test: Error handling - ARN discovery failure
- [ ] Test: Error handling - IP discovery failure
- [ ] Test: Error handling - Cache unavailable
- [ ] Test: Error handling - CA Lambda unavailable
- [ ] Test: Cert renewal (30 days before expiration)
- [ ] Test: Agent with wrong ARN rejected
- [ ] Test: Agent from wrong IP rejected

### Performance Tests
- [ ] Measure first connection latency
- [ ] Measure subsequent connection latency
- [ ] Measure cert generation time
- [ ] Measure cache hit rate

---

## Step 11: Documentation

### Architecture Documentation
- [ ] Update `docs/architecture.md` with lazy generation flow
- [ ] Add sequence diagram for first agent connection
- [ ] Add sequence diagram for subsequent connections
- [ ] Document multi-agent cert accumulation
- [ ] Add diagrams showing ARN and IP discovery flows

### Deployment Guide
- [ ] Update `docs/deployment.md` with new Lambda functions
- [ ] Document ElastiCache setup (mark as optional)
- [ ] Document ARN and IP discovery behavior
- [ ] Add troubleshooting section for lazy generation
- [ ] Document first connection latency expectation

### Configuration Reference
- [ ] Document all agent config fields
- [ ] Document all server config fields
- [ ] Document Lambda environment variables
- [ ] Add configuration examples for different deployment scenarios

### Troubleshooting Guide
- [ ] Document ARN discovery failure scenarios
- [ ] Document IP discovery failure scenarios
- [ ] Document cache unavailable scenarios
- [ ] Document cert generation failures
- [ ] Document validation failures and error messages
- [ ] Add debugging tips for lazy generation issues

### Runbook Updates
- [ ] Update `docs/runbook.md` with lazy generation operations
- [ ] Add monitoring recommendations (cert generation events, cache hits/misses)
- [ ] Add alerting recommendations (cert generation failures, validation failures)
- [ ] Document manual cert regeneration procedure (if needed)

---

## Final Checklist

- [ ] All unit tests passing
- [ ] All integration tests passing
- [ ] All end-to-end tests passing
- [ ] Code review completed
- [ ] Documentation reviewed and updated
- [ ] CloudFormation templates validated
- [ ] Deployed to staging environment
- [ ] Smoke tests in staging passed
- [ ] Performance benchmarks meet expectations
- [ ] Security review completed
- [ ] Ready for production deployment

---

## Notes

- **Critical Path**: Steps 1 → 2 → 3 must complete before Steps 4-7 can proceed
- **Parallel Work**: Steps 4, 5, 6, 7 can be developed in parallel after Step 3
- **Testing**: Continuous testing throughout implementation, comprehensive test suite in Step 10
- **Estimated Timeline**: ~10-12 days total (1 day per major step + 2 days testing/docs)
