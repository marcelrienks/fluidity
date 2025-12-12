# Deployment

## Prerequisites

- Go 1.21+ (local builds)
- Docker Desktop (container builds)
- OpenSSL (certificate generation)
- AWS CLI v2 (cloud deployment)
- AWS credentials configured
- jq (JSON parsing, for CA secret creation)

**Platform Setup:**
- Windows: Use WSL for bash scripts
- Linux (Ubuntu/Debian): `bash scripts/setup-prereq-ubuntu.sh`
- macOS: `bash scripts/setup-prereq-mac.sh`

## CA Certificate Setup (AWS Deployment Only)

Before deploying to AWS, generate and store the CA certificate:

```bash
# Generate CA certificate and upload to AWS Secrets Manager
./scripts/generate-ca-certs.sh --save-to-secrets

# Or just generate locally (for backup)
./scripts/generate-ca-certs.sh
# Then manually upload: aws secretsmanager create-secret --name fluidity/ca-certificate --secret-string '...'
```

This CA certificate is used by the CA Lambda to sign all agent and server certificates at runtime. It should be generated **once per AWS account** before deploying the server.

## Certificates

Certificates are generated automatically at runtime by the server and agent using the CA Lambda:

- **Server**: Generates RSA key at startup, certificate on first agent connection (lazy generation)
- **Agent**: Generates certificate at startup using server ARN from Wake Lambda
- **CA Lambda**: Must be deployed first with CA certificate and key in AWS Secrets Manager (`fluidity/ca-certificate`)

No pre-deployment certificate generation is needed for agent/server certificates.

## Local Development

Build and run on your machine:

```bash
./scripts/build-core.sh
./build/fluidity-server -config configs/server.local.yaml  # Terminal 1
./build/fluidity-agent -config configs/agent.local.yaml    # Terminal 2
curl -x http://127.0.0.1:8080 http://example.com
```

Certificates are generated automatically at runtime by the applications.

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
  -v "$(pwd)/configs/server.docker.yaml:/root/config/server.yaml:ro" \
  -p 8443:8443 \
  fluidity-server

# Agent (separate terminal)
docker run --rm \
  -v "$(pwd)/configs/agent.docker.yaml:/root/config/agent.yaml:ro" \
  -p 8080:8080 \
  fluidity-agent
```

Test: `curl -x http://127.0.0.1:8080 http://example.com`

Certificates are generated automatically at runtime.

## AWS Deployment

Deploy server to ECS Fargate + Lambda control plane + agent locally:

```bash
# Step 1: Generate CA certificate (one-time setup per AWS account)
./scripts/generate-ca-certs.sh --save-to-secrets

# Step 2: Deploy everything (server, Lambda, agent)
./scripts/deploy-fluidity.sh deploy
```

This deploys:
1. Validates CA certificate exists in AWS Secrets Manager
2. Builds server/agent binaries
3. Creates ECR repository and pushes server image
4. Deploys CloudFormation stacks (Fargate + Lambda)
5. Configures and deploys agent locally

**Deployment time**: ~10 minutes

### Verify Deployment

```bash
aws cloudformation describe-stack-events --stack-name fluidity-fargate
aws logs tail /ecs/fluidity/server --follow
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

Run the agent using: `fluidity` (or see [Launch Guide](launch.md) for detailed options)

The agent automatically loads configuration from `agent.yaml` and starts the tunnel. For overrides:
```bash
fluidity --proxy-port 9090              # Override listening port
fluidity --log-level debug              # Enable debug logging
fluidity -c /path/to/config.yaml        # Use custom config file
```

## Configuration

**Agent** (`agent.yaml`):
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

**Server** (`server.yaml`):
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
