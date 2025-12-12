# Certificates

## ARN-Based mTLS System (Target Architecture - In Development)

Fluidity is designed to use AWS Resource Names (ARNs) as certificate identity with lazy generation for optimal performance.

**Status**: Dynamic ARN-based certificate generation is the target architecture. Core infrastructure exists but integration with connection handlers is incomplete. See [TODO.md](../TODO.md) Section 1 for integration tasks.

### How It Works (Planned)

**Certificate Structure:**
- **Agent Cert**: CN = server ARN, SAN = [agent public IP]
- **Server Cert**: CN = server ARN, SAN = [server IP, agent IPs...]

**Flow:**
1. Agent calls Wake Lambda → receives server ARN, server IP, agent IP
2. Agent generates certificate with server ARN as CN
3. Server discovers ARN/IP at startup, generates key only (lazy)
4. On first connection: Server extracts agent IP, generates cert with agent IP in SAN
5. Both validate: CN matches ARN ✓ + source IP in SAN ✓
6. Subsequent connections: Use cached cert (fast)

### Components

**Discovery** (`internal/shared/certs`):
- `DiscoverServerARN()`: Tries ECS → CloudFormation → EC2 metadata
- `DiscoverPublicIP()`: Tries ECS → EC2 metadata

**Certificate Generation** (`internal/shared/certs`):
- `GenerateCSRWithARNAndMultipleSANs(key, arn, ips)`: Create CSR with ARN as CN
- Supports multiple IP addresses in SAN for multi-agent scenarios

**Managers** (`internal/core`):
- **Agent**: `NewCertManagerWithARN()` - Generates cert at startup
- **Server**: `NewCertManagerWithLazyGen()` - Generates cert on first connection
  - `InitializeKey()`: Generate key at startup
  - `EnsureCertificateForConnection(ctx, agentIP)`: Generate cert on demand

**CA Lambda** (`cmd/lambdas/ca`):
- Validates ARN format and IPv4 addresses
- Signs CSR with CA private key
- Caches signatures

**Validation** (`internal/shared/tls`):
- Agent validates: Server CN == expected ARN ✓ + target IP in SAN ✓
- Server validates: Client CN == server ARN ✓ + source IP in SAN ✓

### Performance & Security (Target Metrics)

**Performance:**
- Agent startup: +2-3s (Wake Lambda + cert generation)
- Server startup: +1s (discovery + key generation)
- First connection: +500ms (certificate generation)
- Subsequent connections: ~0ms (cached)

**Security:**
- Identity: ARN (unforgeable AWS resource)
- Authorization: IP whitelist in SAN (prevents IP spoofing)
- Validation: Bidirectional ARN + IP checks
- Multi-agent: Each agent IP added to server SAN list

### Configuration (Target - Not Yet Implemented)

**Agent:**
```yaml
server_port: 443
ca_service_url: "https://ca-lambda-url.execute-api.region.amazonaws.com/"
cert_cache_dir: "/var/lib/fluidity/certs"
wake_endpoint: "https://wake-lambda-url.lambda-url.region.on.aws/"
# server_arn, server_public_ip, agent_public_ip populated by Wake Lambda
```

**Server:**
```yaml
listen_port: 443
ca_service_url: "https://ca-lambda-url.execute-api.region.amazonaws.com/"
cert_cache_dir: "/var/lib/fluidity/certs"
ca_cert_file: "./certs/ca.crt"  # CA cert for client verification
# ARN and IP auto-discovered from ECS_TASK_ARN env var or EC2 metadata
```

### Deployment (Target - Not Yet Implemented)

1. Deploy CA Lambda with CA cert/key in AWS Secrets Manager
2. Deploy server (discovers ARN/IP automatically)
3. Deploy agent (receives ARN from Wake Lambda)

### Troubleshooting (Target Implementation)

**ARN discovery fails:**
- Check `ECS_TASK_ARN` environment variable in Fargate
- Set `SERVER_ARN` in CloudFormation if needed
- Falls back to legacy mode if unavailable

**Public IP discovery fails:**
- Verify ECS task has public IP enabled
- Check EC2 instance has public IP
- Verify security groups allow metadata service

**Certificate validation fails:**
- Verify Wake Lambda returned correct server ARN (target implementation)
- Check agent config has `server_arn` field (target implementation)
- For current static certs: Regenerate certificates if cert/key mismatch

---

## Static Certificate Generation (Current - Local Development Only)

Generate static mTLS certificates for local development and testing.

**Note**: This is the current approach for local testing. Production will transition to dynamic ARN-based certificates.

### Generate

```bash
./scripts/generate-certs.sh
# Output: ./certs/{ca,server,client}.{crt,key}

./scripts/generate-certs.sh --save-to-secrets
# Output: fluidity/certificates secret
```

### Options

- `--save-to-secrets`: Push to AWS Secrets Manager
- `--secret-name NAME`: Override secret name (default: fluidity/certificates)
- `--certs-dir DIR`: Override cert directory (default: ./certs)

### Configuration (Static Certificates)

**Local files:**
```yaml
# Agent and Server both support static certificates for local testing
cert_file: "./certs/client.crt"      # Agent: client cert
key_file: "./certs/client.key"       # Agent: client private key
ca_cert_file: "./certs/ca.crt"       # Agent and Server: CA cert for verification
```

**AWS Secrets Manager (Deprecated):**
```yaml
# This approach is deprecated and will be removed
use_secrets_manager: true
secrets_manager_name: "fluidity/certificates"
```

### IAM Permissions

**Read:**
```json
{
  "Effect": "Allow",
  "Action": ["secretsmanager:GetSecretValue"],
  "Resource": "arn:aws:secretsmanager:*:*:secret:fluidity/certificates*"
}
```

**Create/Update:**
```json
{
  "Effect": "Allow",
  "Action": ["secretsmanager:CreateSecret", "secretsmanager:UpdateSecret"],
  "Resource": "arn:aws:secretsmanager:*:*:secret:fluidity/certificates*"
}
```

### Security (Static Certificates - Development Only)

- Self-signed (development only, not for production)
- Never commit `*.key` files
- Use AWS KMS encryption in Secrets Manager (deprecated approach)
- Rotate regularly (default: 2 year validity)
- Regenerate with: `./scripts/generate-certs.sh --save-to-secrets`

**Note**: When dynamic ARN-based certificates are fully implemented, static certificates will be removed.

---

## Development Status

**Current**: Static file-based certificates (local development only)
**Target**: Dynamic ARN-based certificates with CA Lambda (in development)
**Roadmap**: See [TODO.md](../TODO.md) for integration plan and progress

See [Deployment](deployment.md) for setup | [Architecture](architecture.md) for design
