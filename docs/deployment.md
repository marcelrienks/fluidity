# Deployment

## Prerequisites

- Go 1.21+ (local builds)
- Docker Desktop (container builds)
- OpenSSL (certificate generation)
- AWS CLI v2 (cloud deployment)
- AWS credentials configured

**Platform Setup:**
- Windows: Use WSL for all bash scripts
- Linux (Ubuntu/Debian): `bash scripts/setup-prereq-ubuntu.sh`
- macOS: `bash scripts/setup-prereq-mac.sh`

## Certificate Generation

Required for all deployments:

```bash
./scripts/generate-certs.sh              # Local files in ./certs/
./scripts/generate-certs.sh --save-to-secrets  # Push to AWS Secrets Manager
```

Output:
- `ca.crt`, `ca.key` - Certificate Authority
- `server.crt`, `server.key` - Server certificate
- `client.crt`, `client.key` - Client certificate

## Local Development

Build and run on your machine:

```bash
./scripts/generate-certs.sh
./scripts/build-core.sh
./build/fluidity-server -config configs/server.local.yaml  # Terminal 1
./build/fluidity-agent -config configs/agent.local.yaml    # Terminal 2
curl -x http://127.0.0.1:8080 http://example.com
```

## Docker

Build containers locally:

```bash
./scripts/build-core.sh --linux
docker build -f deployments/server/Dockerfile -t fluidity-server .
docker build -f deployments/agent/Dockerfile -t fluidity-agent .
```

Run:

```bash
# Server
docker run --rm \
  -v "$(pwd)/certs:/root/certs:ro" \
  -v "$(pwd)/configs/server.docker.yaml:/root/config/server.yaml:ro" \
  -p 8443:8443 \
  fluidity-server

# Agent (separate terminal)
docker run --rm \
  -v "$(pwd)/certs:/root/certs:ro" \
  -v "$(pwd)/configs/agent.docker.yaml:/root/config/agent.yaml:ro" \
  -p 8080:8080 \
  fluidity-agent
```

Test: `curl -x http://127.0.0.1:8080 http://example.com`

## AWS Deployment

Deploy server to ECS Fargate + Lambda control plane + agent locally:

```bash
./scripts/generate-certs.sh
./scripts/deploy-fluidity.sh deploy
```

This:
1. Builds server/agent binaries
2. Creates ECR repository and pushes server image
3. Deploys CloudFormation stacks (Fargate + Lambda)
4. Configures and deploys agent locally

**Deployment time**: ~10 minutes

### Running the Agent

After deployment, start the agent using the symlink (recommended):

```bash
fluidity
```

The agent automatically:
- Loads configuration from `agent.yaml` in its installation directory
- Calls Wake Lambda to start the ECS Fargate server
- Discovers the server IP via Query Lambda
- Establishes mTLS tunnel connection
- Listens on local proxy port 8080 for incoming HTTP requests

**For advanced options:**
```bash
fluidity --help
```

**Configuration via command-line flags:**
```bash
fluidity --config /path/to/config.yaml        # Explicit config file path
fluidity --proxy-port 9090                    # Override proxy port
fluidity --log-level debug                    # Set log level
fluidity --cert /path/to/cert.crt            # Override certificate paths
```

**Configuration via environment variables (optional):**
```bash
export FLUIDITY_LOG_LEVEL=debug
export FLUIDITY_LOCAL_PROXY_PORT=9090
fluidity
```

### Manual Steps

**1. Build and Push Server Image**
```bash
aws ecr create-repository --repository-name fluidity-server
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <account>.dkr.ecr.us-east-1.amazonaws.com
./scripts/build-core.sh --linux
docker build -f deployments/server/Dockerfile -t fluidity-server .
docker tag fluidity-server:latest <account>.dkr.ecr.us-east-1.amazonaws.com/fluidity-server:latest
docker push <account>.dkr.ecr.us-east-1.amazonaws.com/fluidity-server:latest
```

**2. Deploy CloudFormation Stacks**
```bash
aws cloudformation deploy \
  --template-file deployments/cloudformation/fargate.yaml \
  --stack-name fluidity-fargate \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1
```

**3. Get Server Public IP**
```bash
aws ecs describe-tasks \
  --cluster fluidity \
  --tasks $(aws ecs list-tasks --cluster fluidity --query 'taskArns[0]' --output text) \
  --query 'tasks[0].attachments[0].details[1].value' \
  --output text
```

**4. Configure Agent**
Update `configs/agent.yaml` with server IP, then deploy:
```bash
./build/fluidity-agent -config configs/agent.yaml
```

## Agent Usage

After deployment, run the agent using the symlink (recommended):

```bash
fluidity
```

The agent automatically loads configuration from `agent.yaml` and starts the tunnel. For options:

```bash
fluidity --help
```

Common overrides:
```bash
fluidity --proxy-port 9090              # Override listening port
fluidity --log-level debug              # Enable debug logging
fluidity -c /path/to/config.yaml        # Use custom config file
```

Environment variables (optional): `FLUIDITY_LOG_LEVEL`, `FLUIDITY_LOCAL_PROXY_PORT`, etc.

**Configuration precedence:** CLI flags > Environment variables > Config file > Defaults

## Configuration

**Agent (`agent.yaml`):**
```yaml
server_ip: "FARGATE_PUBLIC_IP"
server_port: 8443
local_proxy_port: 8080
cert_file: "./certs/client.crt"
key_file: "./certs/client.key"
ca_cert_file: "./certs/ca.crt"
wake_endpoint: "https://lambda-url/wake"
kill_endpoint: "https://lambda-url/kill"
```

**Server (`server.yaml`):**
```yaml
listen_addr: "0.0.0.0"
listen_port: 8443
cert_file: "/root/certs/server.crt"
key_file: "/root/certs/server.key"
ca_cert_file: "/root/certs/ca.crt"
max_connections: 100
emit_metrics: true
metrics_interval: "60s"
```

## Cleanup

Remove AWS resources:
```bash
aws cloudformation delete-stack --stack-name fluidity-fargate
aws cloudformation delete-stack --stack-name fluidity-lambda
aws ecr delete-repository --repository-name fluidity-server --force
```

---

See [Architecture](architecture.md) for design | [Development](development.md) for code setup
