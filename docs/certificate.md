# Certificates

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
# Output: fluidity/certificates secret with cert_pem, key_pem, ca_pem
```

Options:
```
--save-to-secrets       Push to AWS Secrets Manager
--secret-name NAME      Secret name (default: fluidity/certificates)
--certs-dir DIR         Certificate directory (default: ./certs)
```

## Output

**Local** (`./certs/`):
- `ca.crt`, `ca.key` - Certificate Authority
- `server.crt`, `server.key` - Server certificate
- `client.crt`, `client.key` - Client certificate

**AWS Secrets Manager**:
```json
{
  "cert_pem": "base64-encoded server cert",
  "key_pem": "base64-encoded server key",
  "ca_pem": "base64-encoded CA cert"
}
```

## Configuration

Enable Secrets Manager in configs:

```yaml
use_secrets_manager: true
secrets_manager_name: "fluidity/certificates"
```

## IAM Permissions

To read certificates:
```json
{
  "Effect": "Allow",
  "Action": ["secretsmanager:GetSecretValue"],
  "Resource": "arn:aws:secretsmanager:*:*:secret:fluidity/certificates*"
}
```

To create/update certificates:
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

- Self-signed certificates (development only)
- Never commit `*.key` files to version control
- Use AWS KMS encryption for Secrets Manager in production
- Rotate regularly (default: 2 year validity)
- Production: Use certificates from trusted CA

## Troubleshooting

| Issue | Solution |
|-------|----------|
| OpenSSL not found | Linux/macOS: package manager; Windows: use WSL |
| AWS credentials missing | Run: `aws configure` |
| Certs already exist | Delete: `rm ./certs/*` then re-run |

---

See [Deployment](deployment.md) for using certificates
