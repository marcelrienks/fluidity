# Deployment Guide

Complete deployment guide for all Fluidity deployment options.

---

## Prerequisites

Before deploying, ensure you have:

- **Go 1.21+** (for local builds)
- **Docker Desktop** (for containers)
- **OpenSSL** (for certificate generation)
- **AWS CLI v2** (for cloud deployment)
- **jq** (for JSON parsing in scripts)
- **Node.js 18+ and npm** (for testing)

**Platform-Specific Setup:**

**Windows (WSL Required):**
- Install WSL if not already installed: `wsl --install`
- Run setup script in WSL: `wsl bash scripts/setup-prereq-ubuntu.sh`
- All bash scripts and make commands must be run in WSL

**Linux:**
- Ubuntu/Debian: `bash scripts/setup-prereq-ubuntu.sh`
- Arch Linux: `bash scripts/setup-prereq-arch.sh`

**macOS:**
- Run: `bash scripts/setup-prereq-mac.sh`

---

## Certificate Generation (Required First Step)

**All deployment options require certificates to be generated first.**

```bash
./scripts/manage-certs.sh              # All platforms (use WSL on Windows)
```

This creates certificates in `./certs/`:
- `ca.crt`, `ca.key` - Certificate Authority
- `server.crt`, `server.key` - Server certificate  
- `client.crt`, `client.key` - Client certificate

**Important:** Keep these files secure. The agent uses client certificates, and cloud deployments read server certificates for upload to AWS.

---

## Deployment Options

### Option A: Local Development (Recommended for Development)

Run server and agent binaries directly on your machine.

**1. Generate certificates** (if not done already):
```bash
./scripts/manage-certs.sh
```

**2. Build binaries:**
```bash
./scripts/build-core.sh                # Build both server and agent
```

**3. Start server** (Terminal 1):
```bash
./build/fluidity-server -config configs/server.local.yaml
```

**4. Start agent** (Terminal 2):
```bash
./build/fluidity-agent -config configs/agent.local.yaml
```

**5. Configure browser proxy:** `127.0.0.1:8080`

**6. Test:
```bash
curl -x http://127.0.0.1:8080 http://example.com -I
curl -x http://127.0.0.1:8080 https://example.com -I
```

**Why use this option:**
- Fastest iteration cycle
- No container overhead
- Easy debugging
- Best for development

**Cost:** Free

---

### Option B: Docker (Local Containers)

Test containerized deployment locally before cloud deployment.

**1. Generate certificates** (if not done already):
```bash
./scripts/manage-certs.sh
```

**2. Build Linux binaries:**
```bash
./scripts/build-core.sh --linux        # Build static Linux binaries
```

**3. Build Docker images:**
```bash
docker build -f deployments/server/Dockerfile -t fluidity-server .
docker build -f deployments/agent/Dockerfile -t fluidity-agent .
```

**4. Run server:**
```bash
docker run --rm \
  -v "$(pwd)/certs:/root/certs:ro" \
  -v "$(pwd)/configs/server.docker.yaml:/root/config/server.yaml:ro" \
  -p 8443:8443 \
  fluidity-server
```

**5. Run agent** (new terminal):
```bash
docker run --rm \
  -v "$(pwd)/certs:/root/certs:ro" \
  -v "$(pwd)/configs/agent.docker.yaml:/root/config/agent.yaml:ro" \
  -p 8080:8080 \
  fluidity-agent
```

**6. Test** (same as Option A)

**Why use this option:**
- Verify containers work before cloud deployment
- Test Docker configurations locally
- Validate image builds

**Cost:** Free

**See also:** [Docker Guide](docker.md) for detailed container documentation

---

### Option C: AWS Fargate with CloudFormation (Recommended for Production)

Deploy server to AWS using a single automated deployment script with intelligent parameter detection and infrastructure as code.

#### Quick Start (30 seconds)

```bash
./scripts/deploy-fluidity.sh deploy
```

The script will:
- ✓ Auto-detect AWS region, VPC, subnets, and your IP
- ✓ Generate certificates (if needed)
- ✓ Build Lambda and Docker images
- ✓ Deploy CloudFormation stacks
- ✓ Output API credentials

#### Full Deployment Steps

**Step 1: Run the deployment script**

```bash
cd Fluidity
bash scripts/deploy-fluidity.sh deploy
```

**With explicit parameters** (no prompts):
```bash
bash scripts/deploy-fluidity.sh deploy \
  --region us-east-1 \
  --vpc-id vpc-12345678 \
  --public-subnets subnet-11111111,subnet-22222222 \
  --allowed-cidr 203.0.113.45/32
```

**Get parameter values:**
```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="us-east-1"
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID --query 'Subnets[*].SubnetId' --output text | tr '\t' ',')
MY_IP=$(curl -s ifconfig.me)/32
```

**On Windows** (via WSL):
```bash
wsl bash -c "cd /mnt/c/Users/marcelr/Tech/github/Fluidity && bash scripts/deploy-fluidity.sh deploy"
```

**Step 2: Verify deployment**

```bash
./scripts/deploy-fluidity.sh status
```

**Step 3: View API credentials**

```bash
./scripts/deploy-fluidity.sh outputs
```

The output includes:
- API Endpoint (Kill API)
- API Key ID
- Instructions for agent configuration

#### Deployment Script Features

| Feature | Command | Notes |
|---------|---------|-------|
| **Deploy** | `./deploy-fluidity.sh deploy` | Auto-detects all parameters |
| **Debug** | `./deploy-fluidity.sh deploy --debug` | Verbose output for troubleshooting |
| **Force Recreate** | `./deploy-fluidity.sh deploy --force` | Delete and recreate from scratch |
| **Status** | `./deploy-fluidity.sh status` | Show CloudFormation stack status |
| **Outputs** | `./deploy-fluidity.sh outputs` | Display API credentials |
| **Delete** | `./deploy-fluidity.sh delete` | Remove all infrastructure |
| **Help** | `./deploy-fluidity.sh --help` | Show all options and examples |

#### What the Script Does

The deployment script automates all infrastructure setup:

1. **Validates** Prerequisites
   - AWS CLI, Docker, jq installed
   - AWS credentials configured

2. **Detects** Parameters
   - AWS Region (from config or prompt)
   - VPC ID (default or prompt)
   - Public Subnets (auto or prompt)
   - Your Public IP (auto-fetch or prompt)

3. **Prepares** Infrastructure
   - Generates certificates (if needed)
   - Stores in AWS Secrets Manager

4. **Builds** Components
   - Lambda functions
   - Docker server image
   - Pushes to ECR

5. **Deploys** CloudFormation
   - Fargate infrastructure stack
   - Lambda control plane stack
   - Creates or updates automatically

6. **Outputs** Credentials
   - API Endpoint and Key ID
   - Configuration instructions

#### Configuration (Agent Setup)

After deployment, configure your agent with the API credentials from step 3:

```yaml
server_host: "<SERVER_PUBLIC_IP>"
server_port: 8443
kill_api_endpoint: "https://xxxxx.execute-api.us-east-1.amazonaws.com/prod/kill"
api_key: "<API_KEY_VALUE>"
cert_file: "./certs/client.crt"
key_file: "./certs/client.key"
ca_file: "./certs/ca.crt"
```

To get the API key value:
```bash
aws apigateway get-api-key --api-key <API_KEY_ID> --include-value --region <REGION>
```

#### Advanced: Force Clean Slate

To delete and recreate all infrastructure:

```bash
./scripts/deploy-fluidity.sh deploy --force
```

This deletes existing stacks and creates fresh ones.

#### Troubleshooting

**View deployment logs:**
```bash
./scripts/deploy-fluidity.sh deploy --debug
```

**Check stack status:**
```bash
aws cloudformation describe-stacks --stack-name fluidity-fargate --query 'Stacks[0].StackStatus'
```

**View CloudWatch logs:**
```bash
aws logs tail /ecs/fluidity/server --follow
```

**Rollback:**
```bash
./scripts/deploy-fluidity.sh delete
./scripts/deploy-fluidity.sh deploy --force
```

**Why use this option:**
- Infrastructure as Code (repeatable, version-controlled)
- Single command deployment
- Intelligent auto-detection with fallback
- Secrets Manager integration
- Certificates managed securely
- Clean stack lifecycle

**See also:** [Infrastructure Guide](infrastructure.md) for CloudFormation templates

---

### Option D: Lambda Control Plane (Cost Optimization Add-on)

Add automated lifecycle management to Option C for 90% cost reduction.

**Prerequisites:**
- Option C already deployed
- Server metrics enabled

#### Quick Setup

```bash
# Enable metrics in server config
# Edit configs/server.yaml: emit_metrics: true

# Deploy Lambda control plane
./scripts/deploy-fluidity.sh deploy --force

# Configure agent with API endpoints
# See outputs from deployment script
```

#### What It Does

- **Wake API:** Starts server on agent connection (~60s startup)
- **Kill API:** Stops server on agent disconnect (saves ~$8.88/month)
- **Sleep API:** Auto-stops idle server after 15 minutes
- **Scheduled Kill:** Optional daily shutdown at specified time

#### Configuration

After deploying Lambda stack, update agent config:

```yaml
server_host: "<SERVER_PUBLIC_IP>"
server_port: 8443
wake_api_endpoint: "https://xxxxx.execute-api.us-east-1.amazonaws.com/prod/wake"
kill_api_endpoint: "https://xxxxx.execute-api.us-east-1.amazonaws.com/prod/kill"
connection_timeout: "90s"
connection_retry_interval: "5s"
```

---

## Certificate Rotation

To rotate certificates (recommended every 6-12 months):

```bash
# Generate new certificates
./scripts/manage-certs.sh

# Redeploy with new certificates
./scripts/deploy-fluidity.sh deploy --force
```

The script will:
- Read new certificates from `./certs/`
- Update CloudFormation stack
- Update Secrets Manager secret
- Fargate service pulls new certificates on next deployment

---

## Troubleshooting

### Prerequisites Issues

**"AWS CLI not found"**
```bash
# macOS
brew install awscli

# Linux
sudo apt-get install awscli

# Windows (WSL)
wsl sudo apt-get install awscli
```

**"Docker not found"**
- Install Docker Desktop: https://www.docker.com/products/docker-desktop

**"jq not found"**
```bash
# macOS
brew install jq

# Linux
sudo apt-get install jq
```

### Deployment Script Issues

**"Certificates not found"**
```bash
./scripts/manage-certs.sh
```

**"Failed to get AWS parameters"**
```bash
# Configure AWS credentials
aws configure

# Or verify existing credentials
aws sts get-caller-identity
```

**"Stack creation failed"**
```bash
# Check CloudFormation events
aws cloudformation describe-stack-events --stack-name fluidity-fargate

# Check with debug output
./scripts/deploy-fluidity.sh deploy --debug

# View detailed logs
aws logs tail /ecs/fluidity/server --follow
```

**"Docker push failed"**
```bash
# Login to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin $(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com
```

### Runtime Issues

**Agent cannot connect to server**
- Check server is running: `./scripts/deploy-fluidity.sh status`
- Verify security group allows your IP
- Check certificates match (same CA)
- Enable debug: `./scripts/deploy-fluidity.sh deploy --debug`

**Stack stuck in UPDATE_ROLLBACK_FAILED**
```bash
# Option 1: Try deployment again
./scripts/deploy-fluidity.sh deploy --force

# Option 2: Manual rollback
aws cloudformation continue-update-rollback --stack-name fluidity-fargate

# Option 3: Delete and recreate
./scripts/deploy-fluidity.sh delete
./scripts/deploy-fluidity.sh deploy
```

**High AWS costs**
- Implement Option D (Lambda control plane) for 98% cost reduction
- Or manually stop server: `aws ecs update-service --cluster fluidity --service fluidity-server --desired-count 0`

---

## Security Best Practices

1. **Restrict ingress:** Use your IP `/32` in `AllowedIngressCidr`
2. **Protect certificate files:** `.gitignore` already excludes `certs/*.key`
3. **Enable CloudWatch Logs retention:** Set 7-30 days
4. **Rotate certificates:** At least annually
5. **Use stack policies:** Prevent accidental deletions (included in deploy script)

---

## Related Documentation

- **[Certificate Guide](certificate.md)** - Certificate generation and management
- **[Docker Guide](docker.md)** - Container build and networking
- **[Fargate Guide](fargate.md)** - Detailed AWS ECS deployment
- **[Lambda Functions](lambda.md)** - Control plane architecture
- **[Infrastructure Guide](infrastructure.md)** - CloudFormation templates
- **[Architecture](architecture.md)** - System design overview

---

## Post-Deployment Steps

After running the deployment script:

**Step 1: View credentials**
```bash
./scripts/deploy-fluidity.sh outputs
```

This displays:
- API Endpoint (Kill API URL)
- API Key ID

**Step 2: Get API key value**
```bash
aws apigateway get-api-key --api-key <API_KEY_ID> --include-value --region <REGION>
```

**Step 3: Configure agent**

Update `configs/agent.yaml` with the credentials from Steps 1-2:
```yaml
server_host: "<SERVER_PUBLIC_IP>"
server_port: 8443
kill_api_endpoint: "<Kill API Endpoint>"
api_key: "<API Key Value>"
cert_file: "./certs/client.crt"
key_file: "./certs/client.key"
ca_file: "./certs/ca.crt"
```

**Step 4: Deploy agent**
```bash
./scripts/build-core.sh --agent
./build/fluidity-agent -config configs/agent.yaml
```

---

## Deployment Script Reference

### Actions

| Action | Purpose | Example |
|--------|---------|---------|
| `deploy` | Create or update infrastructure | `./deploy-fluidity.sh deploy` |
| `status` | Show CloudFormation stack status | `./deploy-fluidity.sh status` |
| `outputs` | Display API credentials | `./deploy-fluidity.sh outputs` |
| `delete` | Remove all infrastructure | `./deploy-fluidity.sh delete` |

### Options

| Option | Purpose | Example |
|--------|---------|---------|
| `--region` | AWS region | `--region us-west-2` |
| `--vpc-id` | VPC ID | `--vpc-id vpc-12345678` |
| `--public-subnets` | Subnets (comma-separated) | `--public-subnets subnet-1,subnet-2` |
| `--allowed-cidr` | Ingress CIDR | `--allowed-cidr 203.0.113.45/32` |
| `--debug` | Verbose logging | `--debug` |
| `--force` | Delete and recreate | `--force` |
| `--help` | Show help | `--help` |

### Examples

**Basic deployment (auto-detects everything)**
```bash
./scripts/deploy-fluidity.sh deploy
```

**With debug output**
```bash
./scripts/deploy-fluidity.sh deploy --debug
```

**Explicit parameters (no prompts)**
```bash
./scripts/deploy-fluidity.sh deploy \
  --region us-east-1 \
  --vpc-id vpc-12345678 \
  --public-subnets subnet-111,subnet-222 \
  --allowed-cidr 203.0.113.45/32
```

**Force clean slate (delete + recreate)**
```bash
./scripts/deploy-fluidity.sh deploy --force
```

**Check status**
```bash
./scripts/deploy-fluidity.sh status
```

**View API credentials**
```bash
./scripts/deploy-fluidity.sh outputs
```

**Delete all infrastructure**
```bash
./scripts/deploy-fluidity.sh delete
```

---

## Script Help

For comprehensive help:

```bash
./scripts/deploy-fluidity.sh --help
```

This shows:
- All available actions
- All command-line options
- Usage examples
- Feature descriptions

---
