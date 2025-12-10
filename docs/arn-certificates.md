# ARN-Based Certificate System - Complete Documentation

## Overview

The Fluidity project now implements a complete ARN-based certificate system with lazy generation, providing enhanced security and dynamic certificate management for agent-server connections.

## Architecture

### Certificate Identity Model

**Agent Certificate:**
- **CN (Common Name)**: Server ARN (e.g., `arn:aws:ecs:us-east-1:123456789012:task/cluster/server`)
- **SAN (Subject Alternative Names)**: Agent's public IP address
- **Purpose**: Identifies which server the agent is authorized to connect to

**Server Certificate:**
- **CN (Common Name)**: Server ARN (same as agent)
- **SAN (Subject Alternative Names)**: Server public IP + all agent IPs (accumulated)
- **Purpose**: Identifies the server and authorizes specific agent IPs

### Lazy Certificate Generation Flow

```
┌─────────────┐                    ┌──────────────┐                    ┌────────────┐
│   Agent     │                    │ Wake Lambda  │                    │   Server   │
└──────┬──────┘                    └───────┬──────┘                    └─────┬──────┘
       │                                   │                                  │
       │ 1. Call Wake Lambda               │                                  │
       ├──────────────────────────────────>│                                  │
       │                                   │                                  │
       │ 2. Extract agent source IP        │                                  │
       │    Discover server ARN/IP         │                                  │
       │<──────────────────────────────────┤                                  │
       │   {server_arn, server_ip,         │                                  │
       │    agent_public_ip}                │                                  │
       │                                   │ 3. Start ECS task                │
       │                                   ├─────────────────────────────────>│
       │                                   │                                  │
       │ 4. Generate agent cert            │                                  │ 4. Discover ARN/IP
       │    CN=server_arn                  │                                  │    Initialize key
       │    SAN=[agent_ip]                 │                                  │    (Wait for connection)
       │                                   │                                  │
       │ 5. Connect to server              │                                  │
       ├────────────────────────────────────────────────────────────────────>│
       │                                   │                                  │
       │                                   │                                  │ 6. TLS handshake
       │                                   │                                  │    Extract agent IP
       │                                   │                                  │    Generate cert:
       │                                   │                                  │    CN=server_arn
       │                                   │                                  │    SAN=[server_ip, agent_ip]
       │                                   │                                  │
       │                                   │ 7. Validate certificates         │
       │                                   │    Agent: CN==server_arn ✓       │
       │                                   │           IP in SAN ✓            │
       │                                   │    Server: CN==server_arn ✓      │
       │                                   │            source IP in SAN ✓    │
       │<────────────────────────────────────────────────────────────────────┤
       │   Connection established          │                                  │
       │                                   │                                  │
```

## Components

### 1. Discovery Functions

**ARN Discovery** (`internal/shared/certs/arn_discovery.go`)
- Three-tier fallback:
  1. `ECS_TASK_ARN` environment variable (automatic in ECS Fargate)
  2. `SERVER_ARN` environment variable (CloudFormation parameter)
  3. EC2 instance metadata service (fallback)
- Validates ARN format: `arn:(aws|aws-cn|aws-us-gov):service:region:account:resource`
- Helper: `DiscoverServerARN()`

**Public IP Discovery** (`internal/shared/certs/public_ip_discovery.go`)
- Two-tier fallback:
  1. ECS task metadata endpoint (for Fargate tasks)
  2. EC2 instance metadata service (for EC2 instances)
- Validates IPv4 format and ensures public IP (not private range)
- Helper: `DiscoverPublicIP()`

### 2. Certificate Generation

**CSR Generator** (`internal/shared/certs/csr_generator.go`)

Key functions:
- `GenerateCSRWithARNAndMultipleSANs(privKey, arn, ipAddresses)` - Create CSR with ARN as CN
- `AppendIPsToSAN(existing, new...)` - Deduplicate and merge IP lists
- `ValidateARN(arn)` - Validate ARN format
- `ValidateIPv4(ip)` - Validate IPv4 format

**CA Client** (`internal/shared/certs/ca_client.go`)
- `SignCSR(ctx, csrPEM)` - Send CSR to CA Lambda for signing
- Handles retries and timeouts
- Returns signed certificate in PEM format

### 3. Lambda Functions

**Wake Lambda** (`internal/lambdas/wake/wake.go`)
```go
type WakeResponse struct {
    Status              string
    InstanceID          string
    ServerARN           string  // Discovered server ARN
    ServerPublicIP      string  // Discovered server public IP
    AgentPublicIPAsSeen string  // Agent IP from HTTP source
    // ... other fields
}
```

**Query Lambda** (`internal/lambdas/query/query.go`)
```go
type QueryResponse struct {
    Status    string
    PublicIP  string
    ServerARN string  // Discovered server ARN
    // ... other fields
}
```

**CA Lambda** (`cmd/lambdas/ca/main.go`)
- Validates ARN format in CN
- Validates multiple IPv4 addresses in SAN
- Signs CSR with CA private key
- Returns PEM-encoded certificate

### 4. Agent Components

**Config** (`internal/core/agent/config.go`)
```go
type Config struct {
    // ... existing fields
    ServerARN      string  // From Wake Lambda
    ServerPublicIP string  // From Wake Lambda
    AgentPublicIP  string  // From Wake Lambda
}
```

**Certificate Manager** (`internal/core/agent/cert_manager.go`)
- `NewCertManagerWithARN(cacheDir, caURL, serverARN, agentPublicIP, logger)`
- Generates agent cert with:
  - CN = server ARN
  - SAN = [agent public IP]
- Caches certificate locally
- Auto-renews 30 days before expiration

**Tunnel Client** (`internal/core/agent/agent.go`)
- `SetServerARN(serverARN, serverPublicIP)` - Configure expected values
- `Connect()` - Establishes connection and validates server certificate:
  - Checks server cert CN matches expected server ARN
  - Checks connection target IP is in server cert SAN
  - Fails fast if validation fails

### 5. Server Components

**Config** (`internal/core/server/config.go`)
```go
type Config struct {
    // ... existing fields
    CertManager *CertManager  // For lazy generation
}
```

**Certificate Manager** (`internal/core/server/cert_manager.go`)
- `NewCertManagerWithLazyGen(cacheDir, caURL, serverARN, serverPublicIP, logger)`
- `InitializeKey()` - Generate and cache RSA private key at startup
- `EnsureCertificateForConnection(ctx, agentIP)` - Lazy generation:
  - Checks if certificate exists and contains agent IP
  - If not, generates new cert with: CN=serverARN, SAN=[serverIP, agentIP]
  - Appends new agent IPs to existing certificate
  - Caches certificate locally

**Server** (`internal/core/server/server.go`)
- `NewServerWithCertManager(tlsConfig, addr, maxConns, logLevel, certMgr, caCertFile)`
- `handleConnection(conn)` - Validates agent certificate:
  - Extracts agent IP from connection source
  - Calls `EnsureCertificateForConnection(ctx, agentIP)` for lazy generation
  - Validates agent cert CN matches server ARN
  - Validates connection source IP is in agent cert SAN
  - Rejects connection if validation fails

## Runtime Validation

### Agent-Side Validation

When connecting to server:
1. ✓ Server cert CN must match expected `server_arn` (from Wake Lambda)
2. ✓ Connection target IP must be in server cert SAN
3. ✓ Fails immediately if validation fails

### Server-Side Validation

When accepting agent connection:
1. ✓ Agent cert CN must match server's own ARN
2. ✓ Connection source IP must be in agent cert SAN
3. ✓ Rejects connection if validation fails

## Configuration

### Agent Configuration

```yaml
# Agent config (agent.yaml)
server_ip: "54.123.45.67"  # Will be discovered via Wake Lambda
server_port: 443
use_dynamic_certs: true
ca_service_url: "https://ca-lambda-url.execute-api.region.amazonaws.com/"
cert_cache_dir: "/var/lib/fluidity/certs"
wake_endpoint: "https://wake-lambda-url.lambda-url.region.on.aws/"
query_endpoint: "https://query-lambda-url.lambda-url.region.on.aws/"

# ARN fields populated by Wake Lambda at runtime
# server_arn: "arn:aws:ecs:region:account:task/cluster/server-id"
# server_public_ip: "54.123.45.67"
# agent_public_ip: "203.45.67.89"
```

### Server Configuration

```yaml
# Server config (server.yaml)
listen_addr: "0.0.0.0"
listen_port: 443
use_dynamic_certs: true
ca_service_url: "https://ca-lambda-url.execute-api.region.amazonaws.com/"
cert_cache_dir: "/var/lib/fluidity/certs"

# ARN and IP discovered automatically at startup from:
# - ECS_TASK_ARN environment variable
# - SERVER_ARN environment variable (CloudFormation)
# - EC2 metadata service
```

### CloudFormation Environment Variables

Add to ECS task definition:
```json
{
  "environment": [
    {
      "name": "SERVER_ARN",
      "value": "${AWS::StackId}/server-task"
    }
  ]
}
```

Or rely on automatic `ECS_TASK_ARN` (preferred).

## Deployment

### 1. Deploy CA Lambda

```bash
# CA Lambda stores CA cert/key in AWS Secrets Manager
cd deployments/cloudformation
aws cloudformation deploy \
  --template-file ca-lambda.yaml \
  --stack-name fluidity-ca \
  --capabilities CAPABILITY_IAM
```

### 2. Deploy Server

Server discovers ARN and public IP automatically:
- From `ECS_TASK_ARN` environment variable (automatic)
- Or from `SERVER_ARN` CloudFormation parameter
- Or from EC2 metadata service

```bash
./scripts/deploy-server.sh
```

### 3. Deploy Agent

Agent receives ARN fields from Wake Lambda:

```bash
./scripts/deploy-agent.sh
```

## Operational Behavior

### First Agent Connection
1. Server generates private key at startup (cached)
2. Agent calls Wake Lambda, receives server ARN + IPs
3. Agent generates certificate with server ARN as CN
4. Agent connects to server
5. Server detects new agent IP, generates certificate including it
6. Both sides validate certificates
7. Connection established (~500ms extra latency for first connection)

### Subsequent Connections (Same Agent)
1. Server checks cached certificate
2. Agent IP already in SAN → reuse cached cert (fast path)
3. No certificate regeneration needed (~0ms extra latency)

### Multiple Agents
1. Each agent connects from different IP
2. Server regenerates certificate, appending new IP to SAN
3. Server certificate SAN grows: `[server_ip, agent1_ip, agent2_ip, ...]`
4. All agents validated against their source IPs

### Certificate Renewal
- Certificates cached locally with 30-day renewal window
- Auto-renewal triggered when <30 days until expiration
- Seamless rotation without connection interruption

## Testing

### Unit Tests
```bash
# Test certificate generation and validation
go test ./internal/shared/certs/... -v

# Test Lambda responses
go test ./internal/lambdas/wake/... ./internal/lambdas/query/... -v
```

### Integration Tests
```bash
# Test complete ARN-based flow
go test ./internal/tests/... -v -run TestARN
```

Tests include:
- ✓ Agent certificate generation with ARN + IP
- ✓ Server certificate generation with ARN + multiple IPs
- ✓ IP deduplication in SAN lists
- ✓ ARN format validation
- ✓ IPv4 format validation
- ✓ Lazy certificate manager initialization
- ✓ Multi-agent scenario simulation

## Troubleshooting

### ARN Discovery Fails

**Symptom:** Logs show "Failed to discover server ARN"

**Solutions:**
1. Check `ECS_TASK_ARN` environment variable (automatic in Fargate)
2. Set `SERVER_ARN` explicitly in CloudFormation template
3. Verify EC2 metadata service is accessible (`curl http://169.254.169.254/latest/meta-data/instance-id`)
4. Falls back to legacy mode if ARN unavailable (warns but continues)

### Public IP Discovery Fails

**Symptom:** Logs show "Failed to discover server public IP"

**Solutions:**
1. Verify ECS task has public IP assigned (Fargate requires `assignPublicIp: ENABLED`)
2. Check EC2 instance has public IP
3. Verify security groups allow metadata service access
4. Falls back to legacy mode if IP unavailable (warns but continues)

### Certificate Validation Fails

**Symptom:** "Client certificate CN does not match server ARN"

**Solutions:**
1. Verify Wake Lambda returned correct server ARN to agent
2. Check agent config has `server_arn` field populated
3. Regenerate agent certificate with correct ARN
4. Check logs for ARN mismatch details

**Symptom:** "Client certificate SAN does not contain source IP"

**Solutions:**
1. Verify agent's public IP is correctly detected by Wake Lambda
2. Check NAT/proxy doesn't change source IP
3. Regenerate agent certificate with correct IP
4. Check logs for IP mismatch details

### Performance Issues

**Symptom:** First connection very slow

**Expected:** ~500ms extra latency for first connection (certificate generation)
**Solutions:**
1. This is normal for lazy generation
2. Subsequent connections from same agent are fast (cached)
3. Pre-generate certificates if latency critical (disable lazy mode)

**Symptom:** Certificate regeneration on every connection

**Possible causes:**
1. Agent IP changing between connections (dynamic IP)
2. Multiple agents connecting from different IPs
3. Certificate cache cleared/deleted

## Security Considerations

### Benefits
- ✓ Per-instance identity (ARN as CN)
- ✓ IP-based authorization (SAN validation)
- ✓ Mutual validation (both agent and server validate)
- ✓ Prevents certificate reuse across different IPs
- ✓ Audit trail via ARN logging

### Limitations
- Agent IP must be static or known in advance
- NAT/proxy can change source IPs (breaks validation)
- Certificate regeneration adds latency for new agents

### Best Practices
1. Use stable agent IPs (Elastic IPs, VPN endpoints)
2. Monitor certificate validation failures
3. Rotate CA certificate regularly
4. Enable debug logging for troubleshooting
5. Use CloudWatch for centralized log analysis

## Backward Compatibility

### Legacy Mode

If ARN discovery fails, system automatically falls back to legacy mode:
- Agent cert: CN=`fluidity-client`, SAN=agent local IP
- Server cert: CN=`fluidity-server`, SAN=server local IP
- No ARN validation
- Works without AWS metadata service
- Suitable for local development

### Migration Path

1. Deploy updated Lambda functions (Wake/Query return ARN fields)
2. Deploy updated server (discovers ARN at startup)
3. Deploy updated agent (receives ARN from Wake Lambda)
4. Monitor logs for "ARN-based certificate" messages
5. Verify validation succeeds
6. Fallback to legacy mode if issues occur

## Monitoring

### Key Metrics
- Certificate generation count (per agent)
- Certificate validation failures (agent/server)
- ARN discovery failures
- IP discovery failures
- Certificate renewal events

### Log Messages

**Success:**
```
INFO: Server ARN discovered from Wake Lambda: arn=arn:aws:ecs:...
INFO: ARN-based certificate validation successful: server_arn=..., agent_ip=...
INFO: Using ARN-based certificate generation: server_arn=...
```

**Warnings:**
```
WARN: Failed to discover server ARN, using legacy mode
WARN: Failed to discover server public IP, using legacy mode
```

**Errors:**
```
ERROR: Server certificate CN does not match expected ARN
ERROR: Client certificate SAN does not contain source IP
```

## API Reference

### Helper Functions

```go
// Discovery
func DiscoverServerARN() (string, error)
func DiscoverPublicIP() (string, error)

// CSR Generation
func GenerateCSRWithARNAndMultipleSANs(
    privKey *rsa.PrivateKey,
    serverARN string,
    ipAddresses []string,
) ([]byte, error)

// Validation
func ValidateARN(arn string) error
func ValidateIPv4(ip string) error

// Utilities
func AppendIPsToSAN(existingIPs []string, newIPs ...string) []string
```

### Certificate Manager (Server)

```go
func NewCertManagerWithLazyGen(
    cacheDir string,
    caServiceURL string,
    serverARN string,
    serverPublicIP string,
    log *logging.Logger,
) *CertManager

func (cm *CertManager) InitializeKey() error
func (cm *CertManager) EnsureCertificateForConnection(
    ctx context.Context,
    agentIP string,
) (string, string, error)
func (cm *CertManager) GetServerARN() string
```

### Certificate Manager (Agent)

```go
func NewCertManagerWithARN(
    cacheDir string,
    caServiceURL string,
    serverARN string,
    agentPublicIP string,
    log *logging.Logger,
) *CertManager

func (cm *CertManager) EnsureCertificate(
    ctx context.Context,
) (string, string, error)
func (cm *CertManager) GetServerARN() string
```

### Tunnel Client (Agent)

```go
func (c *Client) SetServerARN(serverARN string, serverPublicIP string)
func (c *Client) Connect() error
```
