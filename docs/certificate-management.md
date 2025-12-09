# Dynamic Certificate Management (Phase 3)

This document describes the dynamic certificate generation system for Fluidity, which eliminates the need to pre-generate certificates with hardcoded IP addresses.

## Overview

Both Agent and Server automatically generate their own certificates at startup by:
1. Detecting their local/public IP address
2. Creating a Certificate Signing Request (CSR) with the IP as Subject Alternative Name (SAN)
3. Submitting the CSR to the CA Lambda service for signing
4. Caching the signed certificate locally
5. Using the certificate for mTLS connections

## Architecture

### Components

#### 1. Static CA Certificate (One-Time Setup)
- Generated once during initial setup
- Stored in AWS Secrets Manager: `fluidity/ca-certificate`
- Contains:
  - CA certificate (public)
  - CA private key (secret)
- Used by CA Lambda to sign all CSRs
- Distributed to all agents and servers at deployment time

#### 2. CA Lambda Service (`cmd/lambdas/ca/main.go`)
- AWS Lambda function that handles certificate signing
- Receives Certificate Signing Requests (CSR) via API Gateway
- Validates CSR format and IP addresses
- Signs CSRs with the CA private key
- Returns signed certificates with 1-year validity

**Environment Variables:**
- `CA_SECRET_NAME`: Name of the secret in Secrets Manager containing CA cert/key

**API Endpoint:** `POST /sign`
**Request Format:**
```json
{
  "csr": "-----BEGIN CERTIFICATE REQUEST-----\n...\n-----END CERTIFICATE REQUEST-----"
}
```

**Response Format:**
```json
{
  "certificate": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----"
}
```

#### 3. Agent Certificate Manager (`internal/core/agent/cert_manager.go`)
- Detects local IP via network interfaces (prefers eth0/en0)
- Generates RSA 2048-bit key pair
- Creates CSR with:
  - CommonName: `fluidity-client`
  - SAN: detected local IP
- Calls CA Lambda to sign CSR
- Caches certificate and key in `cert_cache_dir`
- Validates cached certificates on subsequent startups
- Auto-renews certificates 30 days before expiration

#### 4. Server Certificate Manager (`internal/core/server/cert_manager.go`)
- Generates RSA 2048-bit key pair
- Creates CSR with:
  - CommonName: `fluidity-server`
  - SAN: (empty/not set) - **Option A Design**
- Calls CA Lambda to sign CSR
- Caches certificate and key in `cert_cache_dir`
- Validates cached certificates on subsequent startups
- Auto-renews certificates 30 days before expiration
- **Design Rationale:** Server doesn't know its public IP at startup (may be behind load balancer, CloudFront, or have dynamic IP). Server's IP is discovered by agents via Query Lambda (separate, authenticated source). Agent validates server cert CN and CA signature instead of IP SAN.

#### 5. Shared Certificate Utilities (`internal/shared/certs/`)
- **csr_generator.go**: CSR generation, key management, certificate encoding
- **ca_client.go**: HTTP client for communicating with CA Lambda
- **ip_detection.go**: IP detection from network interfaces and EC2 metadata

## Configuration

### Agent Configuration (`configs/agent.yaml`)

```yaml
# Dynamic certificate settings
use_dynamic_certs: true          # Enable dynamic certificate generation
ca_service_url: https://...      # CA Lambda API endpoint
cert_cache_dir: /var/lib/fluidity/certs  # Where to cache certificates

# Fallback to static certificates
cert_file: /etc/fluidity/agent.crt
key_file: /etc/fluidity/agent.key
ca_cert_file: /etc/fluidity/ca.crt
```

### Server Configuration (`configs/server.yaml`)

```yaml
# Dynamic certificate settings
use_dynamic_certs: true          # Enable dynamic certificate generation
ca_service_url: https://...      # CA Lambda API endpoint
cert_cache_dir: /var/lib/fluidity/certs  # Where to cache certificates

# Fallback to static/environment certificates
cert_file: /etc/fluidity/server.crt
key_file: /etc/fluidity/server.key
ca_cert_file: /etc/fluidity/ca.crt
```

## Certificate Lifecycle

### Initial Startup
1. Agent/Server starts
2. Checks if valid cached certificate exists
3. If no valid cache:
   - Detects IP address
   - Generates RSA key pair
   - Creates CSR with IP as SAN
   - Calls CA Lambda to sign CSR (~300-400ms)
   - Caches certificate and key locally
   - Loads certificate for mTLS

### Subsequent Startups
1. Agent/Server starts
2. Validates cached certificate:
   - Checks file existence
   - Checks expiration date
   - Checks 30-day renewal threshold
3. If valid: uses cached certificate (instant)
4. If invalid/expired: regenerates new certificate

### Certificate Renewal
- Automatically triggered when certificate will expire within 30 days
- Same process as initial generation
- No manual intervention required

## IP Detection

### Agent IP Detection (`DetectLocalIP()`)
1. Tries preferred interfaces: `eth0`, `en0`, `en1`
2. Falls back to first non-loopback, enabled interface
3. Returns first IPv4 address found
4. Used on Linux containers and macOS

### Server IP Detection (`DetectPublicIP()`)
1. Attempts EC2 metadata service (if available)
2. Falls back to local IP detection
3. Useful in EC2, ECS, or non-AWS environments

## CA Lambda Setup

### Prerequisites
1. CA certificate and key must be generated and stored in Secrets Manager
2. Create secret with name: `fluidity/ca-certificate`
3. Secret format:
```json
{
  "ca_cert": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----",
  "ca_key": "-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----"
}
```

### Deployment
1. Deploy CA Lambda using CloudFormation:
```bash
aws cloudformation deploy \
  --template-file deployments/cloudformation/ca-lambda.yaml \
  --stack-name fluidity-ca \
  --parameter-overrides \
    CASecretName=fluidity/ca-certificate \
  --capabilities CAPABILITY_IAM
```

2. Get the API endpoint from CloudFormation outputs:
```bash
aws cloudformation describe-stacks \
  --stack-name fluidity-ca \
  --query 'Stacks[0].Outputs[?OutputKey==`CAAPIEndpoint`].OutputValue' \
  --output text
```

3. Use the endpoint in Agent/Server configuration:
```yaml
ca_service_url: https://xxx.execute-api.region.amazonaws.com/prod/sign
```

## SSL/TLS Validation

### Trust Chain
```
Root CA (static)
    ↓
    ├─ Agent Certificate (dynamic, IP-based SAN)
    └─ Server Certificate (dynamic, IP-based SAN)
```

### Agent Connection Flow
1. Agent loads CA certificate
2. Agent uses its cached certificate (or generates new one)
3. Agent connects to server with its certificate
4. Server validates agent certificate against CA
5. Server loads server certificate (cached or generated)
6. Server presents certificate to agent
7. Agent validates server certificate against CA
8. Mutual TLS established ✓

### Certificate Validation
- **Agent certificate:** Verified to be signed by trusted CA, CN=fluidity-client, IP SAN matches agent's connection source
- **Server certificate:** Verified to be signed by trusted CA, CN=fluidity-server (no IP SAN per Option A design)
- Server's IP validated separately: Agent obtains IP from Query Lambda (authenticated AWS API call)
- Both verify the certificate hasn't expired
- This design eliminates overlap with Query Lambda and allows server deployment behind load balancers

## Performance Characteristics

### First Startup
- IP detection (agent only): ~50ms
- Key generation: ~50ms
- CSR generation: ~50ms
- CA Lambda signing: ~200ms (includes cold start)
- File caching: ~10ms
- **Total: ~300-400ms overhead**

### Subsequent Startups
- Cache validation: ~5-10ms (instant if valid)
- **Total: negligible overhead**

### Certificate Renewal
- Only triggered when < 30 days until expiration
- Happens once per year in normal operation
- No downtime - renewal happens during normal operation

## Error Handling

### Startup Scenarios

1. **CA Lambda unreachable:**
   - Error: `failed to sign CSR with CA`
   - Solution: Ensure CA Lambda is deployed and accessible
   - Ensure agent/server has network access to API Gateway
   - Check security groups and VPC routing

2. **Invalid IP detection:**
   - Error: `failed to detect local IP`
   - Solution: Ensure network interfaces are available
   - Check container/VM network configuration

3. **Invalid CA certificate:**
   - Error: `failed to parse secret`
   - Solution: Verify CA certificate is properly formatted in Secrets Manager
   - Ensure CA_SECRET_NAME environment variable is correct

4. **No cached certificate, no network:**
   - Error: `failed to sign CSR with CA`
   - Solution: Generate certificate first, then run offline (using cache)
   - This is why certificates are cached

## Migration from Static Certificates

### If Using Static Certificates Now

1. **Set `use_dynamic_certs: false`** in configurations (default)
2. Continue using existing static certificates
3. When ready to migrate:

### Migration Steps

1. Deploy CA Lambda:
```bash
aws cloudformation deploy \
  --template-file deployments/cloudformation/ca-lambda.yaml \
  --stack-name fluidity-ca \
  --capabilities CAPABILITY_IAM
```

2. Update Agent configuration:
```yaml
use_dynamic_certs: true
ca_service_url: <API Gateway endpoint>
cert_cache_dir: /var/lib/fluidity/certs
```

3. Update Server configuration:
```yaml
use_dynamic_certs: true
ca_service_url: <API Gateway endpoint>
cert_cache_dir: /var/lib/fluidity/certs
```

4. Restart agent and server - new certificates will be generated
5. Verify connections work with new certificates
6. Remove old static certificate references

## Troubleshooting

### Check Certificate Cache
```bash
# View cached agent certificate
openssl x509 -in /var/lib/fluidity/certs/agent.crt -text -noout

# View cached server certificate
openssl x509 -in /var/lib/fluidity/certs/server.crt -text -noout
```

### Verify CA Lambda
```bash
# Test CA Lambda endpoint
curl -X POST https://<api-endpoint>/sign \
  -H "Content-Type: application/json" \
  -d '{"csr": "..."}' \
  --aws-sigv4 "aws4_request/region/execute-api/aws4_request"
```

### Check Logs
- **Agent logs:** Look for "Requesting CA to sign CSR"
- **Server logs:** Look for "Requesting CA to sign CSR"
- **CA Lambda logs:** CloudWatch log group `/aws/lambda/fluidity-ca-signer`

### Common Issues

**Issue:** "failed to detect local IP"
- Solution: Verify network interface naming convention
- Linux: Check `ip addr` output for eth0/en0
- macOS: Check `ifconfig` for en0/en1

**Issue:** "CSR signature verification failed"
- Solution: Verify key pair is not corrupted
- Regenerate: Delete cache and restart

**Issue:** "certificate not valid yet" or "certificate expired"
- Solution: Check system time is synchronized
- Check CA certificate validity in Secrets Manager

## Security Considerations

### Certificate Pinning
- No pinning required - certificates change based on IP
- Trust via CA signature instead

### Key Storage
- Private keys stored locally in `cert_cache_dir`
- Recommended permissions: `0600` (read/write owner only)
- Ensure `cert_cache_dir` is on encrypted volume in production

### CA Key Rotation
- CA private key should be rotated annually
- Update secret in Secrets Manager
- New CSRs will use new CA key
- Old certificates remain valid for 1 year

### Audit Trail
- CA Lambda logs all signing requests
- Enable CloudWatch logging to track certificate generation
- Review logs for unusual signing patterns

## Testing

### Local Testing
```bash
# Generate CSR manually
openssl req -new -keyout test.key -out test.csr \
  -subj "/CN=fluidity-client" \
  -addext "subjectAltName=IP:127.0.0.1"

# Test CA Lambda locally
curl -X POST $CA_URL/sign \
  -H "Content-Type: application/json" \
  -d @- << EOF
{
  "csr": "$(cat test.csr | base64)"
}
EOF
```

### Integration Testing
1. Start server with dynamic certs enabled
2. Verify server certificate has correct IP in SAN
3. Start agent with dynamic certs enabled
4. Verify agent certificate has correct IP in SAN
5. Verify connection succeeds with mTLS
6. Check logs for "certificate signed" messages

## Future Enhancements

- [ ] Certificate auto-renewal before expiration (not just 30-day trigger)
- [ ] Multi-region CA Lambda deployment
- [ ] Certificate status dashboard in CloudWatch
- [ ] Metrics: CSR signing latency, certificate age distribution
- [ ] Batch CSR signing for multiple agents
- [ ] OCSP stapling for certificate revocation
- [ ] CA key rotation automation

## References

- [Go crypto/x509 package](https://pkg.go.dev/crypto/x509)
- [AWS Lambda Go Runtime](https://github.com/aws/aws-lambda-go)
- [AWS Secrets Manager Documentation](https://docs.aws.amazon.com/secretsmanager/)
- [mTLS Best Practices](https://www.cloudflare.com/learning/access-management/what-is-mutual-tls-mtls/)
