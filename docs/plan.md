# Fluidity Implementation Plan

**Last Updated:** December 9, 2025  
**Current Status:** Dynamic certificates implemented. Outstanding work: unique CN with ARN-based identity.

---

## Objective: Server ARN-Based Certificate Identity with Public IP Validation

Implement AWS ARN (Amazon Resource Name) as the certificate CommonName with public IP validation via SAN for comprehensive mutual authentication:

- **Shared identity** - Both agent and server use the server ARN in certificate CN for mutual recognition
- **IP validation** - Agent cert includes agent public IP in SAN; server cert includes server public IP in SAN
- **Runtime validation** - Server validates agent IP from agent cert SAN at connection time (no pre-storage needed)
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

Target architecture (after implementation):
```
AGENT STARTUP:
  1. Call Wake Lambda → get server_arn, server_public_ip, agent_public_ip_as_seen
  2. Generate CSR: CN=<server_arn>, SAN=agent_public_ip_as_seen
  3. Submit to CA Lambda → cache cert

WAKE LAMBDA:
  1. Receives call from agent (extracts agent_public_ip from HTTP source IP)
  2. Sets ECS desired count = 1 (triggers server startup)
  3. Returns to agent: { server_arn, server_public_ip, agent_public_ip_as_seen }

SERVER STARTUP:
  1. Discover own ARN from $ECS_TASK_ARN or $SERVER_ARN or EC2 metadata
  2. Discover own public IP from ECS/EC2 metadata
  3. Generate CSR: CN=<server_arn>, SAN=server_public_ip
  4. Submit to CA Lambda → cache cert

MUTUAL VALIDATION AT CONNECTION:
  Agent → Server:
    • Server presents cert: CN=server_arn ✓, SAN=server_public_ip ✓
    • Agent validates: CN == server_arn (from Wake Lambda) ✓
    • Agent validates: connection target IP == server_public_ip in SAN ✓
  
  Server → Agent:
    • Agent presents cert: CN=server_arn ✓, SAN=agent_public_ip ✓
    • Server validates: CN == self_arn ✓
    • Server validates: connection source IP == agent_public_ip in SAN ✓

Benefit: Full IP validation + ARN-based identity + no pre-deployment infrastructure
```

---

## Outstanding Work: Implement Unique CN with ARN

### 1. Query Lambda Enhancement (1 day)

**What:** Enhance Query Lambda to return server ARN alongside server IP

**Current behavior:**
```json
{ "server_ip": "10.0.1.5" }
```

**Target behavior:**
```json
{
  "server_ip": "10.0.1.5",
  "server_arn": "arn:aws:ecs:us-east-1:123456789:task/service/abc123def456"
}
```

**Tasks:**
- [ ] Query Lambda: Add ARN discovery from its own execution context (reuse server ARN discovery logic)
- [ ] Query Lambda: Include ARN in response JSON
- [ ] Test Query Lambda returns both: server_ip and server_arn
- [ ] Update API documentation

---

### 2. Wake Lambda Enhancement (1 day)

**What:** Wake Lambda extracts agent public IP from HTTP source IP and returns it to agent (no storage needed)

**How it works:**
```
Wake Lambda receives call from agent
  ├─ Extract HTTP source IP: 203.45.67.89
  ├─ Determine server_arn: arn:aws:ecs:.../task/server-xyz
  ├─ Set ECS desired count = 1 (trigger server startup)
  └─ Return to agent: { server_arn, server_public_ip, agent_public_ip_as_seen }
```

**Implementation:**
- [ ] Wake Lambda: Extract HTTP source IP from request context
- [ ] Wake Lambda: Include agent_public_ip_as_seen in response
- [ ] Wake Lambda: Discover server ARN (for response)
- [ ] Test Wake Lambda returns all three: server_arn, server_ip, agent_public_ip
- [ ] Update response structure

---

### 3. Server ARN Discovery and Public IP Discovery (1 day)

**What:** Server discovers its own AWS ARN and public IP at startup (no DynamoDB needed)

**ARN Discovery - Three-tier fallback (in order):**

1. **ECS Fargate** - `os.Getenv("ECS_TASK_ARN")` (automatic, <1ms, 99.99%)
2. **CloudFormation Parameter** - `os.Getenv("SERVER_ARN")` (explicit, 0ms, 100%)
3. **EC2 Metadata** - Query metadata service (fallback, 500-1000ms, 99.9%)

**Public IP Discovery - Two-tier:**

1. **ECS Task Metadata** - Get public IP from ECS task metadata (if assigned)
2. **EC2 Metadata** - Query EC2 metadata service for public IP
   - Falls back if ECS metadata not available

**Server startup:**
```
1. Discover server_arn (above)
2. Discover server_public_ip (above)
3. Generate certificate: CN=<server_arn>, SAN=server_public_ip
4. Cache certificate
5. Agent IP will be validated from agent cert SAN at connection time
```

**Implementation file:** `internal/shared/certs/arn_discovery.go` and `internal/shared/certs/public_ip_discovery.go`

**Tasks:**
- [ ] Implement ECS Fargate ARN detection
- [ ] Implement CloudFormation parameter ARN detection
- [ ] Implement EC2 metadata ARN fallback
- [ ] Implement ECS task metadata public IP detection
- [ ] Implement EC2 metadata public IP fallback
- [ ] Add fallback chain logic for both ARN and public IP
- [ ] Add error handling and logging for all discoveries
- [ ] Unit tests for discovery methods

---

### 4. Agent: Receive Server Details from Wake Lambda and Generate Cert (1 day)

**What:** Agent receives server ARN, server IP, and its own public IP from Wake Lambda; generates certificate with both ARN identity and public IP validation

**Agent startup flow:**
```
1. Call Wake Lambda
2. Wake Lambda sees source IP: 203.45.67.89 (agent's public IP)
3. Wake Lambda returns:
   {
     "server_arn": "arn:aws:ecs:us-east-1:123456789:task/server-xyz",
     "server_public_ip": "54.123.45.67",
     "agent_public_ip_as_seen": "203.45.67.89"
   }
4. Detect local IP (for informational logging only)
5. Generate CSR with:
   CN = <server_arn>
   SAN = agent_public_ip_as_seen (203.45.67.89)
6. Call CA Lambda → get signed agent cert
7. Cache cert

Later, when connecting to server:
8. Call Query Lambda → get server_ip, server_arn, agent_public_ip
9. Connect to server_public_ip: 54.123.45.67
10. Server presents cert:
    CN = <server_arn> ✓
    SAN = [54.123.45.67, 203.45.67.89] ✓
11. Agent validates:
    • CN == <server_arn> from Wake Lambda ✓
    • Connection target IP matches server SAN ✓
12. Agent presents cert:
    CN = <server_arn> ✓
    SAN = 203.45.67.89 ✓
13. Mutual TLS established with full validation
```

**Why this works:**
- Agent doesn't need its own ARN (runs locally, not in AWS)
- Agent gets server_arn and agent_public_ip from Wake Lambda (authenticated call)
- Agent cert SAN contains agent's public IP for server to validate at runtime
- Server cert SAN contains server's public IP for agent to validate

**Implementation file:** `internal/core/agent/` files

**Tasks:**
- [ ] Extract server_arn from Wake Lambda response
- [ ] Extract server_public_ip from Wake Lambda response
- [ ] Extract agent_public_ip_as_seen from Wake Lambda response
- [ ] Pass all to certificate manager
- [ ] Generate CSR with CN=<server_arn>, SAN=agent_public_ip_as_seen
- [ ] Submit to CA Lambda and cache
- [ ] Validate server certificate CN matches server ARN from Wake Lambda
- [ ] Validate server certificate SAN contains expected server IP
- [ ] Add logging for all IP and ARN details

---

### 5. Server: Discover Details and Generate Cert (1 day)

**What:** Server discovers its ARN and public IP, generates certificate (agent IP validated at runtime from agent cert)

**Server startup flow:**
```
1. Discover own ARN from:
   - $ECS_TASK_ARN (ECS Fargate, automatic)
   - $SERVER_ARN (CloudFormation param, explicit)
   - EC2 metadata (fallback)
   Example: arn:aws:ecs:us-east-1:123456789:task/server-xyz

2. Discover own public IP from:
   - ECS task metadata (if assigned)
   - EC2 metadata service (fallback)
   Example: 54.123.45.67

3. Generate RSA key

4. Generate CSR with:
   CN = <server_arn>
   SAN = server_public_ip
   Example: CN=arn:aws:ecs:.../server-xyz, SAN=54.123.45.67

5. Call CA Lambda → get signed server cert

6. Cache cert

Later, when agent connects:
7. Agent presents cert:
   CN = <server_arn> ✓
   SAN = 203.45.67.89 (agent's public IP) ✓

8. Server validates:
   • CN == self_arn ✓
   • Connection source IP (203.45.67.89) == agent cert SAN (203.45.67.89) ✓
   • Full mutual TLS established ✓
```

**Implementation file:** `internal/core/server/` files

**Tasks:**
- [ ] Call ARN discovery on server startup
- [ ] Call public IP discovery on server startup
- [ ] Generate CSR with CN=<server_arn>, SAN=server_public_ip
- [ ] Submit to CA Lambda and cache
- [ ] Validate incoming agent certificate CN matches self ARN
- [ ] Validate connection source IP matches agent cert SAN (runtime validation)
- [ ] Add logging for ARN, IPs, and validation details

---

### 6. CSR Generator and CA Lambda: Support ARN as CN with IP in SAN (1 day)

**What:** Enhance CSR generator and CA Lambda to create certificates with server ARN as CN and IP in SAN

**Agent CSR:**
```
GenerateCSRWithARNAndSAN(privateKey, serverARN, agentPublicIP)
  CN = <serverARN>
  SAN = agentPublicIP
  Example: CN=arn:aws:ecs:.../task/server-xyz, SAN=203.45.67.89
```

**Server CSR:**
```
GenerateCSRWithARNAndSAN(privateKey, serverARN, serverPublicIP)
  CN = <serverARN>
  SAN = serverPublicIP
  Example: CN=arn:aws:ecs:.../task/server-xyz, SAN=54.123.45.67
```

**Implementation files:** `internal/shared/certs/csr_generator.go` and CA Lambda

**Tasks:**
- [ ] Add `GenerateCSRWithARNAndSAN(privateKey, serverARN, ipAddress)` function
- [ ] Validate ARN format (arn:aws:...)
- [ ] Validate IP format (IPv4)
- [ ] Create CSR with CN=<server_arn> and SAN=<ip_address>
- [ ] Update CA Lambda: accept ARN-based CN patterns
- [ ] Add CN validation in CA Lambda (must be valid AWS ARN format)
- [ ] Add SAN validation in CA Lambda (must be valid IP address)

---

### 7. Configuration (1 day)

**What:** Ensure server ARN discovery and IP discovery are configured (no DynamoDB needed)

**Agent config:**
```yaml
ca_service_url: https://...
cert_cache_dir: /var/lib/fluidity/certs
# Server ARN, server IP, and agent public IP received from Wake Lambda
```

**Server config:**
```yaml
ca_service_url: https://...
cert_cache_dir: /var/lib/fluidity/certs
# ARN auto-discovered from ECS_TASK_ARN / SERVER_ARN / EC2 metadata
# Public IP auto-discovered from ECS/EC2 metadata
```

**No additional infrastructure needed:**
- ✅ No DynamoDB table
- ✅ No IAM permissions for DynamoDB
- ✅ Simple deploy and go
**Tasks:**
- [ ] Update Agent config: ca_service_url, cert_cache_dir
- [ ] Update Server config: ca_service_url, cert_cache_dir
- [ ] Update CloudFormation templates: remove DynamoDB references
- [ ] Config documentation updated

---

### 8. Testing (2 days)

**Unit Tests:**
- [ ] Server ARN discovery: ECS Fargate, CloudFormation, EC2 metadata
- [ ] Server public IP discovery: ECS metadata, EC2 metadata
- [ ] ARN and IP discovery: fallback chain logic
- [ ] CSR generation: ARN as CN with IP SAN (both agent and server)
- [ ] Wake Lambda: extracts HTTP source IP correctly
- [ ] Wake Lambda: returns server_arn, server_ip, agent_public_ip
- [ ] Agent config: parses Wake Lambda response correctly

**Integration Tests:**
- [ ] Wake Lambda extracts agent IP from HTTP source
- [ ] Wake Lambda returns server_arn, server_ip, agent_public_ip_as_seen
- [ ] Agent receives all three values from Wake Lambda
- [ ] Agent generates cert with CN=<server_arn>, SAN=agent_public_ip
- [ ] Server discovers its ARN and public IP
- [ ] Server generates cert with CN=<server_arn>, SAN=server_public_ip
- [ ] Query Lambda returns server_arn
- [ ] CA Lambda accepts ARN as CN
- [ ] CA Lambda accepts IP in SAN

**End-to-End Tests:**
- [ ] Full deployment: agent calls Wake Lambda → server startup → both have proper certs
- [ ] Agent connects to server: validates server SAN contains expected server IP ✓
- [ ] Server accepts agent: validates agent cert SAN matches connection source IP ✓
- [ ] Server validates connection source IP matches agent SAN ✓
- [ ] Agent validates connection target IP matches server SAN ✓
- [ ] Multi-server scenario: each server has unique ARN
- [ ] Error handling: ARN discovery failures
- [ ] Error handling: public IP discovery failures
- [ ] Error handling: Wake Lambda missing server_arn

---

## Implementation Sequence

1. **Server ARN and Public IP Discovery** - implement discovery methods
2. **Wake Lambda Enhancement** - extract agent IP, return to agent with server ARN
3. **Query Lambda Enhancement** - return server_arn
4. **CSR Generator Enhancement** - support ARN as CN with IP in SAN
5. **Agent Certificate Generation** - use server_arn in CN, agent_public_ip in SAN
6. **Server Certificate Generation** - use server_arn in CN, server_public_ip in SAN
7. **Runtime Validation** - validate agent IP from agent cert SAN at connection time
8. **Configuration** - finalize configs (no DynamoDB needed)
9. **Testing** - comprehensive validation
10. **Documentation** - deployment, troubleshooting

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
- [ ] Query Lambda returns: server_ip, server_arn
- [ ] Server discovers its own ARN correctly (ECS/CloudFormation/EC2)
- [ ] Server discovers its own public IP correctly (ECS/EC2 metadata)
- [ ] Agent receives server_arn, server_public_ip, agent_public_ip from Wake Lambda
- [ ] Agent generates CSR with CN=<server_arn>, SAN=agent_public_ip
- [ ] Server generates CSR with CN=<server_arn>, SAN=server_public_ip
- [ ] CA Lambda accepts ARN as CN format
- [ ] CA Lambda accepts IP in SAN
- [ ] Agent cert SAN has agent's public IP
- [ ] Server cert SAN has server's public IP
- [ ] Agent validates server cert: CN == server_arn ✓
- [ ] Agent validates server cert: connection target IP in SAN ✓
- [ ] Server validates agent cert: CN == self_arn ✓
- [ ] Server validates agent cert: connection source IP == agent cert SAN ✓
- [ ] Mutual TLS succeeds with full validation
- [ ] Agent cert rejected by different server (different ARN)
- [ ] Error handling: graceful if ARN discovery fails
- [ ] Error handling: graceful if public IP discovery fails
- [ ] Logging: clear debug output for all discoveries and validations
- [ ] All tests passing
- [ ] No DynamoDB infrastructure required ✅
- [ ] Deploy and go experience ✅

