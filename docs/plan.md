# Fluidity Implementation Plan

**Last Updated:** December 9, 2025  
**Current Status:** Dynamic certificates implemented. Outstanding work: unique CN with ARN-based identity.

---

## Objective: Server ARN-Based Certificate Identity with Lazy Certificate Generation

Implement AWS ARN (Amazon Resource Name) as the certificate CommonName with public IP validation via SAN, using lazy certificate generation at first connection:

- **Shared identity** - Both agent and server use the server ARN in certificate CN for mutual recognition
- **IP validation** - Agent cert includes agent public IP in SAN; server cert includes server public IP and agent public IP (discovered at first connection)
- **Lazy generation** - Server generates and signs certificate on first agent connection, capturing agent IP from connection source
- **Works with local agents** - Agent (local/on-prem) receives server ARN and agent public IP from Wake Lambda
- **Full mutual TLS** - Both certificates signed by same CA, validated by CN (identity) and SAN (IP authorization)
- **Deploy and go** - No pre-deployment infrastructure needed (no DynamoDB, no manual setup)
- **Scalable** - One agent can connect to multiple servers (each has unique ARN)

---

## Foundation: Current Implementation ✅

Dynamic certificates already implemented with:

- **CA Lambda**: AWS Lambda function that signs CSRs and issues certificates
- **Agent certificates**: Generated with CN=`fluidity-client`, SAN=agent IP (to be enhanced)
- **Server certificates**: Generated with CN=`fluidity-server`, no SAN (to be enhanced)
- **Caching**: Certificates cached locally with auto-renewal 30 days before expiration
- **Infrastructure**: CloudFormation template for CA Lambda deployment
- **Build status**: All components compile successfully

Current architecture (to be enhanced):
```
Agent (local) → detect local IP → generate CSR (CN=fluidity-client) → CA Lambda
Server (AWS) → generate CSR (CN=fluidity-server) → CA Lambda
Problem: Generic fixed CNs - no per-instance identity
```

Target architecture (with lazy certificate generation):
```
AGENT STARTUP:
  1. Call Wake Lambda → get server_arn, server_public_ip, agent_public_ip_as_seen
  2. Generate CSR: CN=<server_arn>, SAN=agent_public_ip_as_seen
  3. Submit to CA Lambda → cache agent cert

WAKE LAMBDA:
  1. Receives call from agent (extracts agent_public_ip from HTTP source IP)
  2. Stores agent_public_ip in shared cache with TTL (Redis/ElastiCache)
  3. Sets ECS desired count = 1 (triggers server startup)
  4. Returns to agent: { server_arn, server_public_ip, agent_public_ip_as_seen }

SERVER STARTUP:
  1. Discover own ARN from $ECS_TASK_ARN or $SERVER_ARN or EC2 metadata
  2. Discover own public IP from ECS/EC2 metadata
  3. Generate RSA key and cache for reuse
  4. Wait for first agent connection (DO NOT generate cert yet)

AGENT CONNECTS TO SERVER (First Connection):
  1. Initiate TLS handshake to server_public_ip:443
  2. Server sees incoming connection from source IP (e.g., 203.45.67.89)
  3. Server checks if cached cert exists:
     ├─ If cert exists AND contains agent IP in SAN → use existing cert
     └─ If cert missing OR agent IP not in SAN → generate new cert with agent IP
  4. Server generates CSR: CN=<server_arn>, SAN=[server_public_ip, agent_source_ip]
  5. Server submits to CA Lambda → receives and caches signed cert
  6. Server presents cert with agent IP now included in SAN
  7. Agent validates: CN == server_arn ✓, connection IP in SAN ✓
  8. Agent presents cert: CN=<server_arn>, SAN=agent_public_ip ✓
  9. Server validates: CN == self_arn ✓, connection source IP in SAN ✓
  10. Mutual TLS established with full validation

SUBSEQUENT CONNECTIONS (Same or Different Agent):
  Server checks cached cert:
  ├─ Same agent IP: Cert valid, use existing cert (fast path)
  └─ Different agent IP: Regenerate cert with new SAN entry

Benefit: Full IP validation + ARN-based identity + no pre-deployment infrastructure + lazy generation
```

---

## Outstanding Work: Implement ARN-Based Identity with Lazy Certificate Generation

This is a unified implementation of all components to support ARN-based identities with lazy certificate generation. The server generates its certificate on the first agent connection, capturing the agent's IP from the connection source.

### 1. Server ARN and Public IP Discovery (Shared)

**What:** Server discovers its own AWS ARN and public IP at startup

**ARN Discovery - Three-tier fallback (in order):**
1. **ECS Fargate** - `os.Getenv("ECS_TASK_ARN")` (automatic, <1ms, 99.99%)
2. **CloudFormation Parameter** - `os.Getenv("SERVER_ARN")` (explicit, 0ms, 100%)
3. **EC2 Metadata** - Query metadata service (fallback, 500-1000ms, 99.9%)

**Public IP Discovery - Two-tier:**
1. **ECS Task Metadata** - Get public IP from ECS task metadata (if assigned)
2. **EC2 Metadata** - Query EC2 metadata service for public IP (fallback)

**Implementation files:** `internal/shared/certs/arn_discovery.go` and `internal/shared/certs/public_ip_discovery.go`

**Tasks:**
- [ ] Implement ECS Fargate ARN detection
- [ ] Implement CloudFormation parameter ARN detection
- [ ] Implement EC2 metadata ARN fallback
- [ ] Implement ECS task metadata public IP detection
- [ ] Implement EC2 metadata public IP fallback
- [ ] Add fallback chain logic for both ARN and public IP
- [ ] Add error handling and logging for all discoveries
- [ ] Unit tests for discovery methods
- [ ] Reuse discovery logic in Query Lambda and Wake Lambda

---

### 2. CSR Generator: Support ARN as CN with IP in SAN

**What:** Enhance CSR generator to support multiple IPs in SAN and ARN validation

**Implementation file:** `internal/shared/certs/csr_generator.go`

**CSR Signature:**
```go
GenerateCSRWithARNAndMultipleSANs(privateKey, serverARN, []ipAddresses)
  CN = <serverARN>
  SAN = []ipAddresses
  Example: CN=arn:aws:ecs:.../server-xyz, SAN=[54.123.45.67, 203.45.67.89]
```

**Tasks:**
- [ ] Add `GenerateCSRWithARNAndMultipleSANs(privateKey, serverARN, ipList)` function
- [ ] Validate ARN format (arn:aws:...)
- [ ] Validate each IP format (IPv4)
- [ ] Create CSR with CN=<server_arn> and SAN containing all IPs
- [ ] Support updating existing certs with new IPs (append to SAN)
- [ ] Unit tests for CSR generation with various ARN and IP combinations

---

### 3. CA Lambda: Accept ARN CN and Multiple IPs in SAN

**What:** Update CA Lambda to validate and sign certificates with ARN CN patterns

**Implementation file:** AWS Lambda function

**Tasks:**
- [ ] Accept ARN format in CN (validate arn:aws:... pattern)
- [ ] Accept multiple IPs in SAN (validate each as IPv4)
- [ ] Sign CSRs with ARN-based CN and multi-IP SAN
- [ ] Add CN validation: must be valid AWS ARN format
- [ ] Add SAN validation: all entries must be valid IPv4 addresses
- [ ] Add logging for CN and SAN details
- [ ] Update CloudFormation template if needed
- [ ] Test CA Lambda with ARN CN and multi-IP SAN

---

### 4. Wake Lambda Enhancement

**What:** Wake Lambda extracts agent IP and returns server details with agent IP stored in cache

**Implementation file:** AWS Lambda function

**How it works:**
```
Wake Lambda receives call from agent:
  1. Extract HTTP source IP: 203.45.67.89
  2. Discover server_arn: arn:aws:ecs:.../task/server-xyz
  3. Discover server_public_ip: 54.123.45.67
  4. Store agent_public_ip in shared cache with TTL (Redis/ElastiCache)
  5. Set ECS desired count = 1 (trigger server startup)
  6. Return to agent: { server_arn, server_public_ip, agent_public_ip_as_seen }
```

**Tasks:**
- [ ] Extract HTTP source IP from API Gateway / ALB context
- [ ] Use ARN discovery to get server_arn
- [ ] Use public IP discovery to get server_public_ip
- [ ] Store agent_public_ip in shared cache (Redis/ElastiCache) with 1-hour TTL
- [ ] Set ECS task desired count = 1
- [ ] Return all three values: server_arn, server_public_ip, agent_public_ip_as_seen
- [ ] Add error handling if cache is unavailable (warn but proceed)
- [ ] Add logging for all IP and ARN details
- [ ] Test Wake Lambda response structure

---

### 5. Query Lambda Enhancement

**What:** Query Lambda returns server ARN alongside server IP

**Implementation file:** AWS Lambda function

**How it works:**
```
Query Lambda returns:
{
  "server_ip": "54.123.45.67",
  "server_arn": "arn:aws:ecs:us-east-1:123456789:task/server-xyz",
  "agent_ip": "203.45.67.89"  (from cache, if available)
}
```

**Tasks:**
- [ ] Use ARN discovery to get server_arn
- [ ] Include server_arn in response JSON
- [ ] Retrieve agent_ip from shared cache (if available for cert validation)
- [ ] Add error handling if ARN discovery fails (return only server_ip)
- [ ] Add logging for all values
- [ ] Update API documentation
- [ ] Test Query Lambda response structure

---

### 6. Agent: Receive Server Details and Generate Certificate

**What:** Agent receives server details from Wake Lambda and generates certificate with server ARN in CN and agent IP in SAN

**Agent startup flow:**
```
1. Call Wake Lambda → gets { server_arn, server_public_ip, agent_public_ip_as_seen }
2. Detect local IP (for informational logging only)
3. Generate RSA key
4. Generate CSR with:
   CN = <server_arn>
   SAN = [agent_public_ip_as_seen]
5. Call CA Lambda → get signed agent cert
6. Cache cert
7. Ready to connect to server
```

**Implementation file:** `internal/core/agent/` files (certificate manager and startup)

**Tasks:**
- [ ] Extract server_arn from Wake Lambda response
- [ ] Extract server_public_ip from Wake Lambda response
- [ ] Extract agent_public_ip_as_seen from Wake Lambda response
- [ ] Pass all to certificate manager
- [ ] Generate CSR with CN=<server_arn>, SAN=[agent_public_ip_as_seen]
- [ ] Submit to CA Lambda and cache
- [ ] Store server_arn for later validation (during connection)
- [ ] Add logging for all IP and ARN details
- [ ] Add error handling for Wake Lambda failures
- [ ] Unit tests for Wake Lambda response parsing and cert generation

---

### 7. Server: Discover ARN, Generate Key, and Lazy Certificate Generation

**What:** Server discovers its ARN and public IP at startup, generates RSA key, and generates certificate on first agent connection

**Server startup flow:**
```
1. Discover own ARN (via ARN discovery)
2. Discover own public IP (via public IP discovery)
3. Generate RSA key and cache for reuse
4. Log ARN and public IP
5. Start listening on port 443 (wait for first connection)
6. DO NOT generate certificate yet
```

**Server connection flow (First Agent Connection):**
```
1. TLS handshake begins, server sees agent cert with SAN=203.45.67.89
2. Server extracts connection source IP: 203.45.67.89
3. Server checks if cert exists in cache:
   ├─ If cert exists AND already contains 203.45.67.89 in SAN → use it
   └─ If cert missing OR 203.45.67.89 not in SAN → regenerate with new SAN
4. Server generates CSR with:
   CN = <server_arn>
   SAN = [server_public_ip, agent_source_ip]  (append new agent IP if not present)
5. Server calls CA Lambda → receives signed cert
6. Server caches cert
7. Server presents cert with agent IP now in SAN
8. TLS handshake completes
```

**Server connection flow (Subsequent Connections):**
```
1. Server checks cached cert:
   ├─ If agent IP already in SAN → use cached cert (fast path)
   └─ If different agent IP → regenerate cert with new SAN entry
2. Complete TLS handshake
```

**Implementation file:** `internal/core/server/` files (startup, certificate manager, and TLS handler)

**Tasks:**
- [ ] Call ARN discovery on server startup
- [ ] Call public IP discovery on server startup
- [ ] Generate RSA key and cache for reuse
- [ ] Log ARN and public IP at startup
- [ ] Add hook in TLS connection handler to check cert validity
- [ ] Implement lazy cert generation: check if cert needs updating before handshake
- [ ] Extract connection source IP from incoming connection
- [ ] Check if agent IP already in cached cert SAN
- [ ] Regenerate cert with new agent IP if needed (append to SAN)
- [ ] Validate CA Lambda accepts multi-IP SAN updates
- [ ] Add logging for cert generation/update events
- [ ] Add error handling for cert generation failures (warn but allow connection)
- [ ] Add cert renewal check (30 days before expiration)
- [ ] Validate incoming agent certificate CN matches self ARN
- [ ] Add unit tests for cert generation, caching, and update logic
- [ ] Add integration tests for lazy generation on first connection

---

### 8. Runtime Validation: Agent and Server

**What:** Both agent and server validate certificates at connection time

**Agent validation (on connection to server):**
```
Server presents cert:
  ├─ Validate CN == server_arn (from Wake Lambda) ✓
  ├─ Validate connection target IP is in cert SAN ✓
  └─ Mutual TLS established ✓
```

**Server validation (on agent connection):**
```
Agent presents cert:
  ├─ Validate CN == self_arn ✓
  ├─ Validate connection source IP == any IP in agent cert SAN ✓
  └─ Mutual TLS established ✓
```

**Implementation file:** TLS handler in both agent and server

**Tasks:**
- [ ] Agent: Extract and validate server cert CN matches stored server_arn
- [ ] Agent: Extract and validate connection target IP is in server cert SAN
- [ ] Server: Extract and validate agent cert CN matches self ARN
- [ ] Server: Extract and validate connection source IP matches one of agent cert SAN IPs
- [ ] Add detailed logging for all validation steps
- [ ] Add error handling for validation failures (reject connection)
- [ ] Unit tests for validation logic
- [ ] Integration tests for end-to-end validation

---

### 9. Configuration

**Agent config:**
```yaml
ca_service_url: https://...
cert_cache_dir: /var/lib/fluidity/certs
wake_lambda_url: https://...
query_lambda_url: https://...
```

**Server config:**
```yaml
ca_service_url: https://...
cert_cache_dir: /var/lib/fluidity/certs
# ARN auto-discovered from ECS_TASK_ARN / SERVER_ARN / EC2 metadata
# Public IP auto-discovered from ECS/EC2 metadata
```

**No additional infrastructure needed:**
- ✅ Shared cache (Redis/ElastiCache) for agent IP storage (optional, can warn if unavailable)
- ✅ No DynamoDB table
- ✅ No IAM permissions for DynamoDB
- ✅ Simple deploy and go

**Tasks:**
- [ ] Update Agent config schema: add wake_lambda_url, query_lambda_url
- [ ] Update Server config schema: ca_service_url, cert_cache_dir
- [ ] Update CloudFormation templates: add ElastiCache if needed, or document optional cache
- [ ] Config documentation updated
- [ ] Test both local and AWS config scenarios

---

### 10. Testing

**Unit Tests:**
- [ ] Server ARN discovery: ECS Fargate, CloudFormation, EC2 metadata, fallback chain
- [ ] Server public IP discovery: ECS metadata, EC2 metadata, fallback chain
- [ ] CSR generation: ARN as CN with multiple IPs in SAN
- [ ] CSR generation: appending new IPs to existing SAN
- [ ] Wake Lambda: extracts HTTP source IP correctly
- [ ] Wake Lambda: returns server_arn, server_public_ip, agent_public_ip_as_seen
- [ ] Wake Lambda: stores agent_ip in cache correctly
- [ ] Query Lambda: returns server_arn
- [ ] Agent: parses Wake Lambda response correctly
- [ ] Agent: generates cert with CN=<server_arn>, SAN=agent_public_ip
- [ ] Server: checks cert cache for agent IP before regenerating
- [ ] Server: appends new agent IPs to existing cert SAN
- [ ] Validation: Agent validates server cert CN and SAN
- [ ] Validation: Server validates agent cert CN and SAN and source IP

**Integration Tests:**
- [ ] Wake Lambda extracts agent IP from HTTP source
- [ ] Wake Lambda stores agent IP in cache with TTL
- [ ] Wake Lambda returns all three values: server_arn, server_ip, agent_public_ip_as_seen
- [ ] Agent receives all three values and generates correct cert
- [ ] Server discovers its ARN and public IP at startup
- [ ] Server generates cert on first agent connection
- [ ] Server includes both server and agent IPs in cert SAN
- [ ] Query Lambda returns server_arn
- [ ] CA Lambda accepts ARN as CN format
- [ ] CA Lambda accepts multiple IPs in SAN
- [ ] Agent cert validation succeeds with correct server ARN and IP
- [ ] Server cert validation succeeds with correct agent IP
- [ ] Multiple agents connecting to same server: each agent IP added to SAN
- [ ] Same agent reconnecting: reuses cached cert (no regeneration)

**End-to-End Tests:**
- [ ] Full deployment: agent calls Wake Lambda → server startup → agent connects → both have proper certs
- [ ] Agent connects to server: validates server SAN contains expected server IP ✓
- [ ] Server accepts agent: validates agent cert SAN matches connection source IP ✓
- [ ] Multi-server scenario: each server has unique ARN in certificate CN
- [ ] Multi-agent scenario: server cert SAN accumulates all agent IPs over time
- [ ] Error handling: ARN discovery failure (server logs warning, continues with fallback)
- [ ] Error handling: Public IP discovery failure (server logs warning, continues)
- [ ] Error handling: Wake Lambda returns incomplete response (agent handles gracefully)
- [ ] Error handling: Cache unavailable (Wake Lambda warns but returns agent IP anyway)
- [ ] Error handling: CA Lambda rejects invalid ARN (clear error message)
- [ ] Cert renewal: cert regenerated 30 days before expiration
- [ ] Lazy generation latency: first connection takes ~500ms extra for cert generation

---

## Implementation Sequence

1. **Discovery Functions** - Implement ARN and public IP discovery (shared library)
2. **CSR Generator** - Add multi-IP SAN support
3. **CA Lambda** - Accept ARN CN and multi-IP SAN
4. **Wake Lambda** - Extract agent IP, store in cache, return server details
5. **Query Lambda** - Return server ARN
6. **Agent Certificate** - Generate cert from Wake Lambda response
7. **Server Lazy Generation** - Generate cert on first connection with agent IP
8. **Runtime Validation** - Validate certificates at both agent and server
9. **Configuration** - Update all configs for production
10. **Testing** - Comprehensive unit, integration, and end-to-end tests
11. **Documentation** - Deployment, troubleshooting, and architecture updates

---

## Security Benefits

| Scenario | With ARN Identity + IP Validation |
|----------|---|
| Identity validation | CN contains server ARN (per-instance) |
| IP validation (agent) | Agent SAN validated by server against connection source IP |
| IP validation (server) | Server SAN validated by agent against connection target IP |
| Comprehensive validation | Both CN (who) and SAN (where) validated |
| Attacker forges cert | Must use valid server ARN + valid IP (checked by CA Lambda) |
| Agent cert stolen | Rejected if presented from wrong IP (source IP != SAN) |
| Server IP spoofing | Agent validates server IP in SAN matches target |
| Agent IP spoofing | Server validates agent IP in SAN matches source |
| Audit trail | Both sides know exact server ARN and IPs |
| Runtime validation | No pre-coordination needed, validated at connection time |

---

## Success Criteria

- [ ] Wake Lambda returns: server_arn, server_public_ip, agent_public_ip_as_seen
- [ ] Wake Lambda stores agent_ip in shared cache with TTL
- [ ] Query Lambda returns: server_ip, server_arn
- [ ] Server discovers its own ARN correctly (ECS/CloudFormation/EC2 fallback)
- [ ] Server discovers its own public IP correctly (ECS/EC2 metadata fallback)
- [ ] Agent receives server_arn, server_public_ip, agent_public_ip from Wake Lambda
- [ ] Agent generates CSR with CN=<server_arn>, SAN=agent_public_ip
- [ ] Server does NOT generate cert at startup (lazy generation)
- [ ] Server generates cert on first agent connection with agent IP in SAN
- [ ] Server cert CSR has CN=<server_arn>, SAN=[server_public_ip, agent_ip]
- [ ] CA Lambda accepts ARN as CN format
- [ ] CA Lambda accepts multiple IPs in SAN
- [ ] Agent cert SAN has agent's public IP
- [ ] Server cert SAN has both server's public IP and agent's public IP
- [ ] Agent validates server cert: CN == server_arn ✓
- [ ] Agent validates server cert: connection target IP in SAN ✓
- [ ] Server validates agent cert: CN == self_arn ✓
- [ ] Server validates agent cert: connection source IP in SAN ✓
- [ ] Mutual TLS succeeds with full validation
- [ ] Server reuses cached cert for same agent IP (fast path)
- [ ] Server regenerates cert when new agent IP connects (appends to SAN)
- [ ] Multi-agent scenario: server cert SAN accumulates multiple agent IPs
- [ ] First agent connection has ~500ms additional latency (cert generation)
- [ ] Subsequent connections from same agent: no latency (cached cert)
- [ ] Error handling: graceful if ARN discovery fails (warn, use fallback)
- [ ] Error handling: graceful if public IP discovery fails (warn, use fallback)
- [ ] Error handling: graceful if cache unavailable (warn but proceed)
- [ ] Error handling: graceful if CA Lambda unavailable (warn, retry)
- [ ] Logging: clear debug output for ARN discovery, IP discovery, cert generation
- [ ] Logging: clear debug output for all validations
- [ ] All tests passing (unit, integration, end-to-end)
- [ ] No DynamoDB infrastructure required ✅
- [ ] Deploy and go experience ✅

