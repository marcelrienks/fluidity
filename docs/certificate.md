# Certificates

## ARN-Based mTLS System

Fluidity uses AWS Resource Names (ARNs) as certificate identity with lazy generation for optimal performance.

### Architecture

```
1. AGENT STARTUP
   Agent ──> Wake Lambda ──> Returns: server_arn, server_ip, agent_ip
         └──> Generate cert: CN=server_arn, SAN=[agent_ip]
              └──> CA Lambda signs ✓

2. SERVER STARTUP (Lazy)
   Server ──> Discover ARN & IP
          └──> Generate RSA key (NO CERT YET)

3. FIRST CONNECTION
   Agent ──> Server
             └──> Extract agent source IP
             └──> Generate cert: CN=server_arn, SAN=[server_ip, agent_ip]
             └──> CA Lambda signs ✓

   TLS Handshake:
   • Agent validates: Server CN == ARN ✓ + IP in SAN ✓
   • Server validates: Client CN == ARN ✓ + IP in SAN ✓

4. SUBSEQUENT CONNECTIONS
   - Known agent: Use cached cert (fast)
   - New agent: Regenerate cert with updated SAN
```

### Components

**Discovery** (`internal/shared/certs`):
- `DiscoverServerARN()`: ECS metadata → CloudFormation → EC2
- `DiscoverPublicIP()`: ECS metadata → EC2

**CSR Generation** (`internal/shared/certs`):
- Legacy: `GenerateCSR(cn, ip, key)` - Single IP
- ARN: `GenerateCSRWithARNAndMultipleSANs(key, arn, ips)` - Multi-IP

**CA Lambda** (`cmd/lambdas/ca`):
- Accepts: Legacy CN (`fluidity-client/server`) or ARN format
- Validates: ARN format, IPv4 addresses, multiple IPs in SAN

**Wake/Query Lambdas**:
- Wake: Returns `server_arn`, `server_ip`, `agent_ip_as_seen`
- Query: Returns `server_arn` in all responses

**Agent Cert Manager** (`internal/core/agent`):
- ARN mode: `NewCertManagerWithARN(dir, url, serverARN, agentIP, log)`
- Stores server ARN for connection validation

**Server Cert Manager** (`internal/core/server`):
- Lazy mode: `NewCertManagerWithLazyGen(dir, url, serverARN, serverIP, log)`
- `InitializeKey()`: Generate key at startup
- `EnsureCertificateForConnection(ctx, agentIP)`: Generate cert on first connection

**Validation** (`internal/shared/tls`):
- `ValidateServerCertificateARN(cert, expectedARN)`: Agent validates server
- `ValidateServerCertificateIP(cert, targetIP)`: Agent validates IP
- `ValidateClientCertificateARN(cert, serverARN)`: Server validates client
- `ValidateClientCertificateIP(cert, sourceIP)`: Server validates IP

### Performance

- Agent startup: +2-3s (Wake + cert gen)
- Server startup: +1s (discover + key gen)
- First connection: +500ms (cert gen)
- Known agents: ~0ms (cached)
- New agents: +500ms (cert regen)

### Security

- Identity: ARN (unforgeable AWS resource)
- Authorization: IP whitelist in SAN
- Validation: Bidirectional ARN + IP checks
- Certificate pinning: Agent validates exact server ARN

---

## Legacy Certificate Generation (Deprecated)

Generate mTLS certificates for local development or AWS deployment.

## Generate

Local files:
```bash
./scripts/generate-certs.sh
# Output: ./certs/{ca,server,client}.{crt,key}
```

AWS Secrets Manager:
```bash
./scripts/generate-certs.sh --save-to-secrets
# Output: fluidity/certificates secret
```

Options:
```
--save-to-secrets       Push to AWS Secrets Manager
--secret-name NAME      Secret name (default: fluidity/certificates)
--certs-dir DIR         Certificate directory (default: ./certs)
```

## Output

Local files: `./certs/ca.{crt,key}`, `server.{crt,key}`, `client.{crt,key}`

AWS Secrets Manager: Secret contains cert_pem, key_pem, ca_pem (base64-encoded)

## Configuration

Enable Secrets Manager:
```yaml
use_secrets_manager: true
secrets_manager_name: "fluidity/certificates"
```

## IAM Permissions

Read:
```json
{
  "Effect": "Allow",
  "Action": ["secretsmanager:GetSecretValue"],
  "Resource": "arn:aws:secretsmanager:*:*:secret:fluidity/certificates*"
}
```

Create/update:
```json
{
  "Effect": "Allow",
  "Action": ["secretsmanager:CreateSecret", "secretsmanager:UpdateSecret"],
  "Resource": "arn:aws:secretsmanager:*:*:secret:fluidity/certificates*"
}
```

## Rotation

Regenerate and update:
```bash
./scripts/generate-certs.sh --save-to-secrets
```

## Security

- Self-signed (development only)
- Never commit `*.key` files
- Use AWS KMS encryption in production
- Rotate regularly (default: 2 year validity)
- Production: Use trusted CA

## Troubleshooting

| Issue | Solution |
|-------|----------|
| OpenSSL not found | Linux/macOS: package manager; Windows: WSL |
| AWS credentials missing | Run `aws configure` |
| Certs already exist | Delete with `rm ./certs/*` |

---

See [Deployment](deployment.md) for using certificates
