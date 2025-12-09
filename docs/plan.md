# Fluidity Implementation Plan

**Last Updated:** December 9, 2025  
**Current Status:** Dynamic certificates implemented. Outstanding work: unique CN with ARN-based identity.

---

## Objective: Server ARN-Based Certificate Identity with Public IP Validation

Implement AWS ARN (Amazon Resource Name) as the certificate CommonName with public IP validation via SAN for comprehensive mutual authentication:

- **Shared identity** - Both agent and server use the server ARN in certificate CN for mutual recognition
- **IP validation** - Agent cert includes agent public IP in SAN; server cert includes both server and agent public IPs in SAN
- **Works with local agents** - Agent (local/on-prem) receives server ARN and agent public IP from Wake Lambda
- **Full mutual TLS** - Both certificates signed by same CA, validated by CN (identity) and SAN (IP authorization)
- **Secure IP passing** - Agent IP passed via Wake Lambda → DynamoDB → Server reads at startup
- **Scalable** - One agent can connect to multiple servers (each has unique ARN and knows its expected agent IP)

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
  2. Detect local IP
  3. Generate CSR: CN=<server_arn>, SAN=agent_public_ip_as_seen
  4. Submit to CA Lambda → cache cert

WAKE LAMBDA:
  1. Receives call from agent (extracts agent_public_ip from HTTP source IP)
  2. Stores agent_public_ip in DynamoDB: { server_arn, agent_ip: 203.45.67.89 }
  3. Sets ECS desired count = 1 (triggers server startup)
  4. Returns to agent: { server_arn, server_public_ip, agent_public_ip_as_seen }

SERVER STARTUP:
  1. Discover own ARN from $ECS_TASK_ARN or $SERVER_ARN or EC2 metadata
  2. Discover own public IP from ECS/EC2 metadata
  3. Query DynamoDB: get agent_public_ip for this server_arn
  4. Generate CSR: CN=<server_arn>, SAN=[server_public_ip, agent_public_ip]
  5. Submit to CA Lambda → cache cert

MUTUAL VALIDATION AT CONNECTION:
  Agent → Server:
    • Server presents cert: CN=server_arn ✓, SAN=[server_public_ip, agent_public_ip] ✓
    • Agent validates: connection target IP matches server_public_ip in SAN ✓
  
  Server → Agent:
    • Agent presents cert: CN=server_arn ✓, SAN=agent_public_ip ✓
    • Server validates: connection source IP matches agent_public_ip in SAN ✓

Benefit: Full IP validation + ARN-based identity + mutual recognition
```

---

## Outstanding Work: Implement Unique CN with ARN

### 1. Query Lambda Enhancement (1-2 days)

**What:** Enhance Query Lambda to return server ARN and agent public IP alongside server IP

**Current behavior:**
```json
{ "server_ip": "10.0.1.5" }
```

**Target behavior:**
```json
{
  "server_ip": "10.0.1.5",
  "server_arn": "arn:aws:ecs:us-east-1:123456789:task/service/abc123def456",
  "agent_public_ip": "203.45.67.89"
}
```

**Tasks:**
- [ ] Query Lambda: Add ARN discovery from its own execution context
- [ ] Query Lambda: Query DynamoDB to get agent_public_ip for this server_arn
- [ ] Query Lambda: Include ARN and agent_public_ip in response JSON
- [ ] Test Query Lambda returns all three: server_ip, server_arn, agent_public_ip
- [ ] Update API documentation

---

### 2. Wake Lambda Enhancement: Store Agent IP (1 day)

**What:** Wake Lambda extracts agent public IP from HTTP source IP and stores in DynamoDB for server to retrieve at startup

**How it works:**
```
Wake Lambda receives call from agent
  ├─ Extract HTTP source IP: 203.45.67.89
  ├─ Determine server_arn: arn:aws:ecs:.../task/server-xyz
  ├─ Store in DynamoDB table: fluidity_agent_ips
  │  └─ Key: server_arn
  │  └─ Value: { agent_public_ip: 203.45.67.89, timestamp: now }
  ├─ Set ECS desired count = 1 (trigger server startup)
  └─ Return to agent: { server_arn, server_public_ip, agent_public_ip_as_seen }
```

**Implementation:**
- [ ] Create DynamoDB table: `fluidity_agent_ips`
  - Primary key: `server_arn` (partition key)
  - Attributes: `agent_public_ip`, `timestamp`
  - TTL: 1 hour (auto-cleanup of stale entries)
- [ ] Wake Lambda: Extract HTTP source IP
- [ ] Wake Lambda: Store to DynamoDB with server_arn as key
- [ ] Wake Lambda: Return agent_public_ip_as_seen to agent in response
- [ ] Add IAM permissions: DynamoDB write access for Wake Lambda
- [ ] Test DynamoDB write from Wake Lambda

---

### 3. Server ARN Discovery and Public IP Discovery (1 day)

**What:** Server discovers its own AWS ARN and public IP at startup, then retrieves agent IP from DynamoDB

**ARN Discovery - Three-tier fallback (in order):**

1. **ECS Fargate** - `os.Getenv("ECS_TASK_ARN")` (automatic, <1ms, 99.99%)
2. **CloudFormation Parameter** - `os.Getenv("SERVER_ARN")` (explicit, 0ms, 100%)
3. **EC2 Metadata** - Query metadata service (fallback, 500-1000ms, 99.9%)

**Public IP Discovery - Two-tier:**

1. **ECS Task Metadata** - Get public IP from ECS task metadata (if assigned)
2. **EC2 Metadata** - Query EC2 metadata service for public IP
   - Falls back if ECS metadata not available

**Agent IP Retrieval from DynamoDB:**

```
Server startup:
  1. Discover server_arn (above)
  2. Discover server_public_ip (above)
  3. Query DynamoDB table `fluidity_agent_ips`:
     └─ Key: server_arn
     └─ Get: agent_public_ip
     └─ If not found: error (agent must call Wake Lambda first)
  4. Now have: [server_arn, server_public_ip, agent_public_ip]
  5. Generate certificate with all three
```

**Implementation file:** `internal/shared/certs/arn_discovery.go` and `internal/core/server/ip_discovery.go`

**Tasks:**
- [ ] Implement ECS Fargate ARN detection
- [ ] Implement CloudFormation parameter ARN detection
- [ ] Implement EC2 metadata ARN fallback
- [ ] Implement ECS task metadata public IP detection
- [ ] Implement EC2 metadata public IP fallback
- [ ] Implement DynamoDB query for agent_public_ip
- [ ] Add fallback chain logic for both ARN and public IP
- [ ] Add error handling: fail gracefully if agent IP not in DynamoDB
- [ ] Add logging for all discoveries
- [ ] Add IAM permissions: DynamoDB read access for server

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
- Agent cert SAN contains agent's public IP for server to validate
- Server cert SAN contains both server and agent IPs for full authorization

**Implementation file:** `internal/core/agent/` files

**Tasks:**
- [ ] Extract server_arn from Wake Lambda response
- [ ] Extract server_public_ip from Wake Lambda response
- [ ] Extract agent_public_ip_as_seen from Wake Lambda response
- [ ] Pass all three to certificate manager
- [ ] Generate CSR with CN=<server_arn>, SAN=agent_public_ip_as_seen
- [ ] Submit to CA Lambda and cache
- [ ] Query Lambda call: extract server_arn and agent_public_ip from response
- [ ] Validate server certificate CN matches server ARN from Wake Lambda
- [ ] Validate server certificate SAN contains expected server IP
- [ ] Add logging for all IP and ARN details

---

### 5. Server: Discover Details and Generate Cert with Full SAN Validation (1 day)

**What:** Server discovers its ARN, public IP, and agent IP from DynamoDB; generates certificate with both server and agent IPs in SAN

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

3. Query DynamoDB table `fluidity_agent_ips`:
   - Key: server_arn
   - Retrieve: agent_public_ip (set by Wake Lambda)
   - Example: 203.45.67.89
   - If not found: wait/retry (agent must call Wake Lambda first)

4. Generate RSA key

5. Generate CSR with:
   CN = <server_arn>
   SAN = [server_public_ip, agent_public_ip]
   Example SAN: [54.123.45.67, 203.45.67.89]

6. Call CA Lambda → get signed server cert

7. Cache cert

8. Store agent_public_ip in memory for runtime validation:
   - Future connections: validate source IP == agent_public_ip

Later, when agent connects:
9. Agent presents cert:
   CN = <server_arn> ✓
   SAN = 203.45.67.89 ✓

10. Server validates:
    • CN == self_arn ✓
    • Connection source IP matches agent_public_ip in SAN ✓
    • Full mutual TLS established ✓
```

**Implementation file:** `internal/core/server/` files

**Tasks:**
- [ ] Call ARN discovery on server startup
- [ ] Call public IP discovery on server startup
- [ ] Query DynamoDB for agent_public_ip (with retries if not yet available)
- [ ] Generate CSR with CN=<server_arn>, SAN=[server_public_ip, agent_public_ip]
- [ ] Update CA Lambda to accept multiple IPs in SAN
- [ ] Submit to CA Lambda and cache
- [ ] Store agent_public_ip in memory for runtime validation
- [ ] Validate incoming agent certificate CN matches self ARN
- [ ] Validate connection source IP matches agent_public_ip from SAN
- [ ] Add logging for ARN, IPs, and validation details
- [ ] Handle case where agent IP not in DynamoDB: retry with backoff

---

### 6. CSR Generator and CA Lambda: Support ARN as CN with Multiple IPs in SAN (1 day)

**What:** Enhance CSR generator and CA Lambda to create certificates with server ARN as CN and support multiple IPs in SAN

**Agent CSR:**
```
GenerateCSRWithServerARN(privateKey, serverARN, agentPublicIP)
  CN = <serverARN>
  SAN = agentPublicIP
  Example: CN=arn:aws:ecs:.../task/server-xyz, SAN=203.45.67.89
```

**Server CSR:**
```
GenerateCSRWithServerARN(privateKey, serverARN, [serverPublicIP, agentPublicIP])
  CN = <serverARN>
  SAN = [serverPublicIP, agentPublicIP]
  Example: CN=arn:aws:ecs:.../task/server-xyz, SAN=[54.123.45.67, 203.45.67.89]
```

**Implementation files:** `internal/shared/certs/csr_generator.go` and CA Lambda

**Tasks:**
- [ ] Add `GenerateCSRWithARNAndSAN(privateKey, serverARN, sanIPs)` function
  - [ ] Accept single IP or list of IPs for SAN
  - [ ] Support both agent (single IP) and server (multiple IPs) modes
- [ ] Validate ARN format (arn:aws:...)
- [ ] Validate IP format (both IPv4)
- [ ] Create CSR with CN=<server_arn> and proper SAN entries
- [ ] Update CA Lambda: accept ARN-based CN patterns
- [ ] Update CA Lambda: accept multiple IPs in SAN
- [ ] Add CN validation in CA Lambda (must be valid AWS ARN format)
- [ ] Add SAN validation in CA Lambda (must be valid IP addresses)

---

### 7. Configuration (1 day)

**What:** Ensure server ARN discovery, IP discovery, and DynamoDB access are configured

**DynamoDB Setup:**
```
Table Name: fluidity_agent_ips
Primary Key: server_arn (string, partition key)
Attributes:
  - server_arn (PK)
  - agent_public_ip (string)
  - timestamp (number, for TTL)
TTL: 1 hour (auto-cleanup)
```

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
dynamodb_table: fluidity_agent_ips
dynamodb_region: us-east-1
# ARN auto-discovered from ECS_TASK_ARN / SERVER_ARN / EC2 metadata
# Public IP auto-discovered from ECS/EC2 metadata
# Agent IP retrieved from DynamoDB at startup
```

**IAM Permissions:**
```
Wake Lambda:
  - dynamodb:PutItem (fluidity_agent_ips table)
  - ec2:DescribeInstances (if needed for IP discovery)

Server:
  - dynamodb:GetItem (fluidity_agent_ips table)
  - ec2:DescribeNetworkInterfaces (for public IP discovery)
```

**Tasks:**
- [ ] Create DynamoDB table: fluidity_agent_ips with TTL
- [ ] Update Agent config: ca_service_url, cert_cache_dir
- [ ] Update Server config: add dynamodb_table, dynamodb_region
- [ ] Update Wake Lambda IAM: add DynamoDB write permissions
- [ ] Update Server IAM: add DynamoDB read permissions, EC2 describe permissions
- [ ] Document DynamoDB table structure and TTL setup
- [ ] Update deployment CloudFormation templates

---

### 8. Testing (3 days)

**Unit Tests:**
- [ ] Server ARN discovery: ECS Fargate, CloudFormation, EC2 metadata
- [ ] Server public IP discovery: ECS metadata, EC2 metadata
- [ ] ARN and IP discovery: fallback chain logic
- [ ] CSR generation: ARN as CN with single IP SAN (agent)
- [ ] CSR generation: ARN as CN with multiple IPs in SAN (server)
- [ ] Wake Lambda: extracts HTTP source IP correctly
- [ ] Wake Lambda: stores to DynamoDB correctly
- [ ] Agent config: parses server_arn, server_ip, agent_public_ip
- [ ] Server config: parses dynamodb_table, dynamodb_region

**Integration Tests:**
- [ ] Wake Lambda extracts agent IP from HTTP source
- [ ] Wake Lambda stores agent IP in DynamoDB
- [ ] Agent receives server_arn, server_ip, agent_public_ip from Wake Lambda
- [ ] Agent generates cert with CN=<server_arn>, SAN=agent_public_ip
- [ ] Server discovers its ARN, public IP
- [ ] Server queries DynamoDB and gets agent_public_ip
- [ ] Server generates cert with CN=<server_arn>, SAN=[server_ip, agent_ip]
- [ ] Query Lambda returns server_arn and agent_public_ip
- [ ] CA Lambda accepts ARN as CN
- [ ] CA Lambda accepts multiple IPs in SAN

**End-to-End Tests:**
- [ ] Full deployment: agent calls Wake Lambda → server startup → both have proper certs
- [ ] Agent connects to server: validates server SAN contains expected server IP ✓
- [ ] Server accepts agent: validates agent SAN contains expected agent IP ✓
- [ ] Server validates connection source IP matches agent SAN ✓
- [ ] Agent validates connection target IP matches server SAN ✓
- [ ] Multi-server scenario: each server has unique agent IP from DynamoDB
- [ ] Agent IP change: DynamoDB updated on next Wake Lambda call
- [ ] Error handling: DynamoDB write fails gracefully
- [ ] Error handling: Server startup waits for agent IP in DynamoDB
- [ ] Error handling: Query Lambda missing server_arn or agent_public_ip

---

## Implementation Sequence

1. **Query Lambda Enhancement** - return server_arn and agent_public_ip
2. **Wake Lambda Enhancement** - extract agent IP, store in DynamoDB, return to agent
3. **DynamoDB Setup** - create fluidity_agent_ips table with TTL
4. **Server ARN and Public IP Discovery** - implement both discovery methods
5. **Server DynamoDB Query** - read agent IP at startup
6. **CSR Generator and CA Lambda Enhancement** - support ARN as CN, multiple IPs in SAN
7. **Agent Certificate Generation** - use server_arn in CN, agent_public_ip in SAN
8. **Server Certificate Generation** - use server_arn in CN, [server_ip, agent_ip] in SAN
9. **Configuration and IAM** - setup DynamoDB table, permissions, configs
10. **Testing** - comprehensive validation of full flow
11. **Documentation** - deployment, troubleshooting, architecture

---

## Security Benefits

| Scenario | With ARN Identity + IP Validation |
|----------|---|
| Identity validation | CN contains server ARN (per-instance) |
| IP validation | Agent SAN validated by server against connection source IP |
| IP validation | Server SAN validated by agent against connection target IP |
| Comprehensive validation | Both CN (who) and SAN (where) validated |
| Attacker forges cert | Must use valid server ARN + valid IPs (checked by CA Lambda) |
| Agent cert stolen | Rejected if presented from wrong IP |
| Server IP spoofing | Agent validates server IP in SAN matches target |
| Agent IP spoofing | Server validates agent IP in SAN matches source |
| Audit trail | Both sides know exact server ARN, server IP, and agent IP |
| Mutual recognition | Full 3-way validation: ARN + both IPs |

---

## Success Criteria

- [ ] Wake Lambda returns: server_arn, server_public_ip, agent_public_ip_as_seen
- [ ] Wake Lambda stores agent IP in DynamoDB with server_arn key
- [ ] Query Lambda returns: server_ip, server_arn, agent_public_ip
- [ ] DynamoDB table created with TTL for auto-cleanup
- [ ] Server discovers its own ARN correctly (ECS/CloudFormation/EC2)
- [ ] Server discovers its own public IP correctly (ECS/EC2 metadata)
- [ ] Server queries DynamoDB and retrieves agent_public_ip
- [ ] Agent receives server_arn, server_public_ip, agent_public_ip from Wake Lambda
- [ ] Agent generates CSR with CN=<server_arn>, SAN=agent_public_ip
- [ ] Server generates CSR with CN=<server_arn>, SAN=[server_public_ip, agent_public_ip]
- [ ] CA Lambda accepts ARN as CN format
- [ ] CA Lambda accepts multiple IPs in SAN
- [ ] Agent cert SAN has single IP (agent's public IP)
- [ ] Server cert SAN has both IPs (server and agent)
- [ ] Agent validates server cert: CN == server_arn ✓
- [ ] Agent validates server cert: connection target IP in SAN ✓
- [ ] Server validates agent cert: CN == self_arn ✓
- [ ] Server validates agent cert: connection source IP in SAN ✓
- [ ] Mutual TLS succeeds with full validation
- [ ] Agent cert rejected by different server (different CN/different expected agent IP)
- [ ] Error handling: graceful if ARN discovery fails
- [ ] Error handling: graceful if public IP discovery fails
- [ ] Error handling: graceful if DynamoDB read fails (retry with backoff)
- [ ] Logging: clear debug output for all discoveries and validations
- [ ] All tests passing

