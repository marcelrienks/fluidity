# Docker Build and Deployment Guide

Docker-specific build process, networking, and troubleshooting for Fluidity.

---

## Build Process

Build process compiles Go binaries locally and copies them into Alpine containers (~44MB total).

**Build commands:**
```bash
./scripts/build-core.sh --linux          # Build Linux binaries
docker build -f deployments/server/Dockerfile -t fluidity-server .
docker build -f deployments/agent/Dockerfile -t fluidity-agent .
```

## Dockerfile Structure

```dockerfile
FROM alpine/curl:latest        # ~8MB base with curl

WORKDIR /app

COPY build/fluidity-server .   # Pre-built binary (~35MB)

RUN mkdir -p ./config ./certs  # Volume mount directories

COPY configs/server.yaml ./config/

EXPOSE 8443

CMD ["./fluidity-server", "--config", "./config/server.yaml"]
```

**Image sizes:** Server ~44MB, Agent ~44MB

---

## Building Images

### All Platforms

```bash
# Build Linux binaries
./scripts/build-core.sh --linux

# Build Docker images
docker build -f deployments/server/Dockerfile -t fluidity-server .
docker build -f deployments/agent/Dockerfile -t fluidity-agent .
```

**Windows users:** All commands must be run in WSL.

---

## Docker Desktop Networking

**Challenge:** Containers need to communicate with each other on the same machine.

**Solution:** Use `host.docker.internal` in configs (automatically included in certificate SANs).

**Agent config (`agent.docker.yaml`):**
```yaml
server_ip: "host.docker.internal"  # For Docker Desktop
```

**Verify certificates:**
```powershell
# Windows
openssl x509 -in .\certs\server.crt -noout -text | Select-String -Pattern "DNS:"

# macOS/Linux
openssl x509 -in ./certs/server.crt -noout -text | grep DNS:
```

**Expected output:**
```
DNS.1 = fluidity-server
DNS.2 = localhost
DNS.3 = host.docker.internal  ✅ (Docker Desktop support)
IP.1 = 127.0.0.1
IP.2 = ::1
```

---

## Running Containers Locally

**Windows:**
```powershell
# Server
docker run --rm `
  -v ${PWD}\certs:/root/certs:ro `
  -v ${PWD}\configs\server.docker.yaml:/root/config/server.yaml:ro `
  -p 8443:8443 `
  fluidity-server

# Agent
docker run --rm `
  -v ${PWD}\certs:/root/certs:ro `
  -v ${PWD}\configs\agent.docker.yaml:/root/config/agent.yaml:ro `
  -p 8080:8080 `
  fluidity-agent
```

**macOS/Linux:**
```bash
# Server
docker run --rm \
  -v "$(pwd)/certs:/root/certs:ro" \
  -v "$(pwd)/configs/server.docker.yaml:/root/config/server.yaml:ro" \
  -p 8443:8443 \
  fluidity-server

# Agent
docker run --rm \
  -v "$(pwd)/certs:/root/certs:ro" \
  -v "$(pwd)/configs/agent.docker.yaml:/root/config/agent.yaml:ro" \
  -p 8080:8080 \
  fluidity-agent
```

**Config files:**
- `server.docker.yaml`: Binds to `0.0.0.0` (all interfaces)
- `agent.docker.yaml`: Connects to `host.docker.internal`

---

## Testing Containers

```bash
# macOS/Linux
curl -x http://127.0.0.1:8080 http://example.com -I
curl -x http://127.0.0.1:8080 https://example.com -I
```

```powershell
# Windows
curl.exe -x http://127.0.0.1:8080 http://example.com -I
curl.exe -x http://127.0.0.1:8080 https://example.com -I --ssl-no-revoke
```

**Expected:** `HTTP/1.1 200 OK`

**Check logs:**
```powershell
docker logs <container-id>
```

### Recommended Testing Approach

**For development:** Use local binaries (faster, simpler):
```bash
./scripts/build-core.sh
./build/fluidity-server -config configs/server.local.yaml  # Terminal 1
./build/fluidity-agent -config configs/agent.local.yaml    # Terminal 2
```

**For Docker verification:** Use containers with `host.docker.internal` configs (pre-deployment check).

---

## Networking Modes

**Default (bridge):** Isolated network with port forwarding. Uses `host.docker.internal` for container-to-container communication (pre-configured in Docker configs).

**Custom network** (optional): `docker network create fluidity-net`, then use `--network fluidity-net`. Containers communicate by name (included in certificate SAN).

**Host network** (Linux only): `docker run --network host` uses host's network stack directly.

---

## AWS Fargate/ECS

In cloud environments, Docker networking is straightforward:

**Why it works:**
- Containers use AWS VPC networking with private IPs
- ECS service discovery provides DNS names
- Certificates include ECS service names in SAN list
- No `host.docker.internal` needed

**Example:**
```yaml
ServerDNS: fluidity-server.local
Certificate SAN: fluidity-server.local
Agent connects to: fluidity-server.local:8443 ✅
```

**Full setup:** See **[Fargate Guide](fargate.md)**

---

## CloudWatch Metrics

### Server Configuration

```yaml
# configs/server.yaml
emit_metrics: true
metrics_interval: "60s"
```

**Environment variables:**
```bash
FLUIDITY_METRICS_ENABLED=true
FLUIDITY_METRICS_INTERVAL=60s
FLUIDITY_NAMESPACE=Fluidity
FLUIDITY_SERVICE_NAME=fluidity-server
```

### Metrics Emitted

- `ActiveConnections`: Current agent count
- `LastActivityEpochSeconds`: Unix timestamp of last activity

### IAM Permissions

```json
{
  "Effect": "Allow",
  "Action": "cloudwatch:PutMetricData",
  "Resource": "*",
  "Condition": {
    "StringEquals": {
      "cloudwatch:namespace": "Fluidity"
    }
  }
}
```

### View Metrics

```bash
aws cloudwatch get-metric-statistics \
  --namespace Fluidity \
  --metric-name ActiveConnections \
  --dimensions Name=ServiceName,Value=fluidity-server \
  --statistics Maximum \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300
```

Used by Lambda control plane for automated lifecycle management. See **[Lambda Functions](lambda.md)**.

---

## Troubleshooting

### 403 Forbidden during Docker build

**Error:**
```
ERROR: failed to solve: failed to create LLB definition: 403 Forbidden
```

**Cause:** Corporate firewall blocking Docker Hub

**Solution:** Use simplified build (already implemented):
```bash
./scripts/build-core.sh --linux
docker build -f deployments/server/Dockerfile -t fluidity-server .
```

### TLS certificate verification failed

**Error:**
```
tls: failed to verify certificate: x509: certificate is valid for fluidity-server, localhost, not host.docker.internal
```

**Cause:** Certificates generated before `host.docker.internal` was added to default SAN list

**Solution:** Regenerate certificates:
```powershell
# Windows
.\scripts\generate-certs.sh

# macOS/Linux
./scripts/generate-certs.sh
```

**Verify:**
```powershell
openssl x509 -in ./certs/server.crt -noout -text | grep DNS:
# Should show: DNS:fluidity-server, DNS:localhost, DNS:host.docker.internal
```

### Container starts but immediately exits

**Debug:**
```powershell
# Check logs
docker logs <container-id>

# Run with interactive shell
docker run -it --entrypoint /bin/sh fluidity-server

# Inside container
ls -la                        # Check binary exists
./fluidity-server --help      # Test binary
cat ./config/server.yaml      # Check config
```

### Permission denied on binary

**Error:**
```
/bin/sh: ./fluidity-server: Permission denied
```

**Solution:** Add to Dockerfile after COPY:
```dockerfile
RUN chmod +x ./fluidity-server
```

### Volume mount issues (Windows)

**Error:**
```
Error: bind source path does not exist
```

**Solution:** Use `${PWD}` with forward slashes:
```powershell
docker run -v "${PWD}/certs:/app/certs:ro" fluidity-server
```

**Port conflicts:**
```powershell
netstat -ano | findstr :8443
netstat -ano | findstr :8080
```

### Cannot pull base image

**Cause:** Corporate firewall blocking Docker Hub

**Solution:** 
- Build locally first with `./scripts/build-core.sh --linux`
- Or use cached Alpine image

---

## Production Best Practices

1. **Secrets Management:** Use AWS Secrets Manager or SSM Parameter Store for certificates/keys (not baked into image)
2. **Health Checks:** ECS can use curl to check server health
3. **Logging:** CloudWatch Logs integration (in CloudFormation template)
4. **Security Groups:** Restrict port 8443 to specific IP ranges
5. **Lifecycle Management:** Use Lambda control plane for automated shutdown
6. **Metrics:** Enable CloudWatch metrics for monitoring

**CloudFormation template:** See `deployments/cloudformation/fargate.yaml`

---

## Summary

**Development:**
Use local binaries for faster iteration and debugging.

**Deployment:**
Docker images (~44MB) are production-ready and deploy seamlessly with AWS Fargate/ECS via CloudFormation.

---

## Related Documentation

- [Deployment Guide](deployment.md) - All deployment options
- [Certificate Management](certificate.md) - TLS setup
- [Fargate Guide](fargate.md) - AWS deployment
