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
