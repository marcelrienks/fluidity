# Docker Build and Deployment Guide

Docker-specific build process, networking, and troubleshooting for Fluidity.

---

## Build Process

### Simplified Single-Stage Build

Fluidity compiles Go binaries **locally** and copies them into Alpine containers.

```
Host Machine (Any OS)         Docker Container (Linux)
─────────────────────         ────────────────────────
Go source + modules      →    Pre-built static binary
Static Linux binary      →    Alpine Linux (~5MB)
                              curl utility (~3MB)
                              Total: ~44MB
```

### Build Commands

```bash
# Build Linux binaries
./scripts/build-core.sh --linux

# Build Docker images
docker build -f deployments/server/Dockerfile -t fluidity-server .
docker build -f deployments/agent/Dockerfile -t fluidity-agent .
```

**Build flags:**

```bash
GOOS=linux GOARCH=amd64 CGO_ENABLED=0  # Static Linux binary
```

**Image sizes:** ~44MB each (21MB Alpine + 23MB binary)

### Why This Approach?

**1. Corporate Firewall Bypass**

Multi-stage builds fail in corporate environments:
- Docker Hub blocked (403 Forbidden)
- HTTPS traffic intercepted
- Go module proxies unreachable

Solution: Build locally before Docker starts (no network calls during build).

**2. Faster Builds**
- Multi-stage: ~10+ seconds (download modules, compile)
- Single-stage: ~2 seconds (copy pre-built binary)

**3. Platform Independence**

Works identically on Windows, macOS, and Linux via cross-compilation.

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

## Docker Desktop Networking

**For agent-server communication on same machine:**

Use `host.docker.internal` in configs (automatically included in certificate SANs).

**Agent config (`agent.docker.yaml`):**

```yaml
server_ip: "host.docker.internal"  # For Docker Desktop
```

## Running Containers

### Server

```bash
docker run --rm \
  -v "$(pwd)/certs:/root/certs:ro" \
  -v "$(pwd)/configs/server.docker.yaml:/root/config/server.yaml:ro" \
  -p 8443:8443 \
  fluidity-server

``````



### Agent### Dockerfile Structure

```bash

docker run --rm \```dockerfile

  -v "$(pwd)/certs:/root/certs:ro" \FROM alpine/curl:latest        # ~8MB base with curl

  -v "$(pwd)/configs/agent.docker.yaml:/root/config/agent.yaml:ro" \

  -p 8080:8080 \WORKDIR /app

  fluidity-agent

```COPY build/fluidity-server .   # Pre-built binary (~35MB)



**Windows:** Use `${PWD}` instead of `$(pwd)` and backticks for line continuation.RUN mkdir -p ./config ./certs  # Volume mount directories



## TestingCOPY configs/server.yaml ./config/



```bashEXPOSE 8443

./scripts/test-docker.sh               # Linux/macOS

.\scripts\test-docker.ps1              # WindowsCMD ["./fluidity-server", "--config", "./config/server.yaml"]

``````



## Troubleshooting**Image sizes:** Server ~44MB, Agent ~44MB



**Port conflicts:**---

```bash

netstat -ano | findstr :8443## Local Testing

netstat -ano | findstr :8080

```### Docker Desktop Networking



**Certificate mismatch:****Challenge:** Containers need to communicate with each other on the same machine.

- Ensure certificates include `host.docker.internal` in SANs

- Regenerate with `./scripts/manage-certs.sh`

**Cannot pull base image:**
- Build locally first with `./scripts/build-core.sh --linux`
- Or use cached Alpine image

DNS.2 = localhost

**Container exits immediately:**DNS.3 = host.docker.internal  ✅ (Docker Desktop support)

```bashIP.1 = 127.0.0.1

docker logs fluidity-serverIP.2 = ::1

docker logs fluidity-agent```

```

**Verify certificates:**

**Volume mount issues (Windows):**```powershell

- Use absolute paths: `C:\Users\...\certs`# Windows

- Enable file sharing in Docker Desktop settingsopenssl x509 -in .\certs\server.crt -noout -text | Select-String -Pattern "DNS:"



## AWS ECR Push# macOS/Linux

openssl x509 -in ./certs/server.crt -noout -text | grep DNS:

```bash```

# Create repository

aws ecr create-repository --repository-name fluidity-server### Run Containers Locally



# Login**Windows:**

aws ecr get-login-password --region us-east-1 | \```powershell

  docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-east-1.amazonaws.com# Server

docker run --rm `

# Tag  -v ${PWD}\certs:/root/certs:ro `

docker tag fluidity-server:latest <account-id>.dkr.ecr.us-east-1.amazonaws.com/fluidity-server:latest  -v ${PWD}\configs\server.docker.yaml:/root/config/server.yaml:ro `

  -p 8443:8443 `

# Push  fluidity-server

docker push <account-id>.dkr.ecr.us-east-1.amazonaws.com/fluidity-server:latest

```# Agent

docker run --rm `

## Related Documentation  -v ${PWD}\certs:/root/certs:ro `

  -v ${PWD}\configs\agent.docker.yaml:/root/config/agent.yaml:ro `

- [Deployment Guide](deployment.md) - All deployment options  -p 8080:8080 `

- [Certificate Management](certificate-management.md) - TLS setup  fluidity-agent

- [Fargate Guide](fargate.md) - AWS deployment```


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

### Test Containers

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

### Bridge (Default)

```powershell
docker run -p 8443:8443 fluidity-server
```

Isolated network with port forwarding. Requires `host.docker.internal` for container-to-container communication.

### Custom Bridge Network

```powershell
# Create network
docker network create fluidity-net

# Run server (named "fluidity-server")
docker run --rm --name fluidity-server --network fluidity-net \
  -v "$(pwd)/certs:/root/certs:ro" \
  -v "$(pwd)/configs/server.yaml:/root/config/server.yaml:ro" \
  -p 8443:8443 \
  fluidity-server

# Run agent (connects to "fluidity-server")
docker run --rm --network fluidity-net \
  -v "$(pwd)/certs:/root/certs:ro" \
  -v "$(pwd)/configs/agent.yaml:/root/config/agent.yaml:ro" \
  -p 8080:8080 \
  fluidity-agent
```

Containers communicate by name with automatic DNS. Works because certificate includes `fluidity-server` in SAN.

### Host Network (Linux only)

```bash
docker run --network host fluidity-server
```

Server uses host's network stack (no port mapping needed). Not available on Windows/macOS Docker Desktop.

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

## CloudWatch Metrics (AWS Only)

### Server Configuration

```yaml
# configs/server.yaml
emit_metrics: true
metrics_interval: "60s"
```

**Environment variables (alternative):**
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

**Use case:** Lambda control plane for automated lifecycle management. See **[Lambda Functions](lambda.md)**.

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
.\scripts\generate-certs.ps1

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

---

## Production Best Practices

1. **Secrets Management:** Use AWS Secrets Manager or SSM Parameter Store for certificates/keys (not baked into image)
2. **Health Checks:** ECS can use curl to check server health
3. **Logging:** CloudWatch Logs integration (in CloudFormation template)
4. **Security Groups:** Restrict port 8443 to specific IP ranges
5. **Cost Optimization:** Use Lambda control plane for automatic idle shutdown
6. **Metrics:** Enable CloudWatch metrics for monitoring

**CloudFormation template:** See `deployments/cloudformation/fargate.yaml`

---

## Summary

**Local Development:**
- Use local binaries (faster iteration)
- Docker for pre-deployment verification

**Cloud Deployment:**
- Docker images are production-ready (~44MB)
- Build process bypasses corporate firewalls
- Works seamlessly with AWS Fargate/ECS
- Use CloudFormation for infrastructure-as-code

**Key Insight:** Docker's power is in production portability, not local development convenience.
