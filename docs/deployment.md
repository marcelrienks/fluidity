# Deployment Guide

Complete guide to deploying Fluidity with automated scripts and configuration management.

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
./scripts/generate-certs.sh             # All platforms (use WSL on Windows)
```

This creates certificates in `./certs/`:
- `ca.crt`, `ca.key` - Certificate Authority
- `server.crt`, `server.key` - Server certificate  
- `client.crt`, `client.key` - Client certificate

**Important:** Keep these files secure. The agent uses client certificates, and cloud deployments read server certificates for upload to AWS.

---

## Deployment

### Local Development

Run server and agent binaries directly on your machine.

**Setup:**
```bash
./scripts/generate-certs.sh               # Generate certificates
./scripts/build-core.sh                   # Build both server and agent
./build/fluidity-server -config configs/server.local.yaml  # Terminal 1
./build/fluidity-agent -config configs/agent.local.yaml    # Terminal 2
```

**Test:**
```bash
curl -x http://127.0.0.1:8080 http://example.com
```

---

### Docker

Test containerized deployment locally before cloud deployment.

**Setup:**
```bash
./scripts/generate-certs.sh               # Generate certificates
./scripts/build-core.sh --linux           # Build static Linux binaries
docker build -f deployments/server/Dockerfile -t fluidity-server .
docker build -f deployments/agent/Dockerfile -t fluidity-agent .
```

**Run server** (Terminal 1):
```bash
docker run --rm -v "$(pwd)/certs:/root/certs:ro" \
  -v "$(pwd)/configs/server.docker.yaml:/root/config/server.yaml:ro" \
  -p 8443:8443 fluidity-server
```

**Run agent** (Terminal 2):
```bash
docker run --rm -v "$(pwd)/certs:/root/certs:ro" \
  -v "$(pwd)/configs/agent.docker.yaml:/root/config/agent.yaml:ro" \
  -p 8080:8080 fluidity-agent
```

**Test:**
```bash
curl -x http://127.0.0.1:8080 http://example.com
```

---

### AWS Fargate with CloudFormation

Deploy server to AWS with automated scripts. Full details in [Infrastructure Guide](infrastructure.md).

**Windows (PowerShell):**
```powershell
wsl bash scripts/deploy-fluidity.sh deploy
```

**macOS/Linux (Bash):**
```bash
sudo -E bash scripts/deploy-fluidity.sh deploy
```

**Important (for sudo users):** Use `sudo -E` to preserve environment variables (including AWS credentials). Without the `-E` flag, AWS credentials won't be passed to the script and deployment will fail.

This automatically:
- Detects AWS region, VPC, subnets, and your IP
- Generates certificates (if needed)
- Builds and uploads Docker image to ECR
- Deploys CloudFormation stacks  
- Deploys and configures agent with endpoints

**With explicit parameters (Windows PowerShell):**
```powershell
wsl bash scripts/deploy-fluidity.sh deploy `
  --region us-east-1 `
  --vpc-id vpc-12345678 `
  --public-subnets subnet-11111111,subnet-22222222 `
  --allowed-cidr 203.0.113.45/32 `
  --server-ip 203.0.113.50 `
  --local-proxy-port 8080
```

**With explicit parameters (macOS/Linux):**
```bash
sudo -E bash scripts/deploy-fluidity.sh deploy \
  --region us-east-1 \
  --vpc-id vpc-12345678 \
  --public-subnets subnet-11111111,subnet-22222222 \
  --allowed-cidr 203.0.113.45/32 \
  --server-ip 203.0.113.50 \
  --local-proxy-port 8080
```

**Check status (Windows PowerShell):**
```powershell
wsl bash scripts/deploy-fluidity.sh status
```

**Check status (macOS/Linux):**
```bash
sudo -E bash scripts/deploy-fluidity.sh status
```

**Delete infrastructure (Windows PowerShell):**
```powershell
wsl bash scripts/deploy-fluidity.sh delete
```

**Delete infrastructure (macOS/Linux):**
```bash
sudo -E bash scripts/deploy-fluidity.sh delete
```

---

## Deployment Automation Scripts

**Cross-Platform Compatibility:**
The deployment automation system provides three modular bash scripts that work together. While these scripts can be run from any OS (Windows/macOS/Linux), they are **primarily intended for Windows users running PowerShell with WSL prefix**. The examples in this guide default to Windows PowerShell syntax, with alternative commands provided for macOS/Linux where relevant.

**Windows PowerShell:** Use `wsl bash` prefix to run scripts in WSL  
**macOS/Linux:** Run scripts directly without prefix

### Architecture Overview

```
User runs: deploy-fluidity.sh deploy

    ┌─────────────────────────────────────────┐
    │   deploy-fluidity.sh (Orchestrator)     │
    │   - OS Detection                        │
    │   - Detects defaults (paths, ports)     │
    │   - Routes actions to scripts            │
    └─────────────┬─────────────────┬─────────┘
                  │                 │
        ┌─────────▼──────────┐  ┌──▼──────────────┐
        │ deploy-server.sh   │  │ deploy-agent.sh │
        │ - AWS CloudFormation   │ - Config Mgmt   │
        │ - ECS Fargate          │ - Build Binary  │
        │ - Lambda Functions     │ - Install PATH  │
        │ - Outputs Endpoints    │ - Create Config │
        └──────────┬──────────┘  └──┬─────────────┘
                   │                 │
              Exports Endpoints       Consumes Endpoints
         (wake, kill URLs)
```

### Three-Script Architecture

### Script Reference

### deploy-fluidity.sh (Orchestrator)

**Location:** `scripts/deploy-fluidity.sh`

**Actions:**
- `deploy` - Deploy both server and agent (default)
- `deploy-server` - Deploy only AWS infrastructure
- `deploy-agent` - Deploy only agent to local system
- `delete` - Delete AWS infrastructure
- `status` - Show deployment status for both

**Common Parameters:**
```
--region <region>           # AWS region (auto-detected)
--vpc-id <vpc-id>          # VPC ID (auto-detected)
--public-subnets <subnets> # Comma-separated subnet IDs (auto-detected)
--allowed-cidr <cidr>      # Ingress CIDR (auto-detected from your IP)
--server-ip <ip>           # Server IP for agent configuration
--local-proxy-port <port>  # Agent port (default: 8080)
--skip-build                # Use existing agent binary
--debug                     # Enable debug logging
```

**Examples (Windows PowerShell):**
```powershell
wsl bash scripts/deploy-fluidity.sh deploy                    # Full deployment
wsl bash scripts/deploy-fluidity.sh deploy --region us-west-2 # Specific region
wsl bash scripts/deploy-fluidity.sh deploy --debug             # With debug output
wsl bash scripts/deploy-fluidity.sh status                     # Check status
wsl bash scripts/deploy-fluidity.sh delete                     # Delete infrastructure
```

**Examples (macOS/Linux):**
```bash
sudo -E bash scripts/deploy-fluidity.sh deploy                    # Full deployment
sudo -E bash scripts/deploy-fluidity.sh deploy --region us-west-2 # Specific region
sudo -E bash scripts/deploy-fluidity.sh deploy --debug             # With debug output
sudo -E bash scripts/deploy-fluidity.sh status                     # Check status
sudo -E bash scripts/deploy-fluidity.sh delete                     # Delete infrastructure
```

---

## Configuration Management

### Configuration Flow

1. **User runs deployment:**
   ```bash
   ./scripts/deploy-fluidity.sh deploy
   ```

2. **Server deployed to AWS:**
   - CloudFormation creates Fargate + Lambda infrastructure
   - Collects Lambda Function URLs (wake, kill, etc.)

3. **Endpoints passed to agent:**
   - Orchestrator script captures endpoints
   - Passes to deploy-agent.sh via command-line parameters

4. **Agent configuration created/updated:**
   - Loads existing `agent.yaml` if present
   - Applies command-line parameter overrides
   - Creates new config if missing
   - Updates with server/Lambda details

5. **Configuration validated:**
   - Checks required fields (server_ip)
   - Requests missing values interactively if needed
   - Deployment fails cleanly if config incomplete

6. **Deployment completes:**
   - Both server and agent ready
   - All configuration persisted
   - Can re-run deployment to update config

### Configuration Precedence

1. **Config File Values** (lowest priority)
2. **Command-line Arguments** (override config)
3. **Required Validation** (fails if missing)

### Creating/Updating Configuration

**Automatic (Recommended):**
```bash
./scripts/deploy-fluidity.sh deploy
# Automatically configures agent with server endpoints
```

**Manual Update:**
```bash
./scripts/deploy-agent.sh deploy --server-ip 192.168.1.100 --local-proxy-port 9000
# Updates agent.yaml with new values, preserves others
```

**Interactive Input:**
```bash
./scripts/deploy-agent.sh deploy
# Prompts for required server_ip if not in config
```

### Viewing Configuration

**Windows:**
```powershell
type $APPDATA\fluidity\agent.yaml
```

**macOS/Linux:**
```bash
cat ~/.config/fluidity/agent.yaml
```

---

## Script Features & Reference

### Deployment Script Actions

| Script | Action | Purpose | Example |
|--------|--------|---------|---------|
| deploy-fluidity.sh | deploy | Deploy server + agent | `./deploy-fluidity.sh deploy` |
| deploy-fluidity.sh | deploy-server | Deploy AWS only | `./deploy-fluidity.sh deploy-server` |
| deploy-fluidity.sh | deploy-agent | Deploy agent only | `./deploy-fluidity.sh deploy-agent` |
| deploy-fluidity.sh | status | Check both | `./deploy-fluidity.sh status` |
| deploy-fluidity.sh | delete | Remove AWS | `./deploy-fluidity.sh delete` |
| deploy-server.sh | deploy | Deploy AWS | `./deploy-server.sh deploy` |
| deploy-server.sh | status | Check stack | `./deploy-server.sh status` |
| deploy-server.sh | outputs | Show endpoints | `./deploy-server.sh outputs` |
| deploy-server.sh | delete | Remove stack | `./deploy-server.sh delete` |
| deploy-agent.sh | deploy | Build + install | `./deploy-agent.sh deploy --server-ip X` |
| deploy-agent.sh | status | Check install | `./deploy-agent.sh status` |
| deploy-agent.sh | uninstall | Remove agent | `./deploy-agent.sh uninstall` |

### Deployment Script Options

| Option | Usage | Purpose |
|--------|-------|---------|
| `--region` | `--region us-west-2` | Specify AWS region |
| `--vpc-id` | `--vpc-id vpc-123` | Specify VPC ID |
| `--public-subnets` | `--public-subnets sub-1,sub-2` | Specify subnets |
| `--allowed-cidr` | `--allowed-cidr 203.0.113.45/32` | Specify ingress CIDR |
| `--server-ip` | `--server-ip 192.168.1.100` | Specify server IP |
| `--local-proxy-port` | `--local-proxy-port 9000` | Specify proxy port |
| `--cert-path` | `--cert-path ./certs/client.crt` | Specify certificate |
| `--key-path` | `--key-path ./certs/client.key` | Specify key |
| `--ca-cert-path` | `--ca-cert-path ./certs/ca.crt` | Specify CA cert |
| `--install-path` | `--install-path /custom/path` | Custom install path |
| `--skip-build` | `--skip-build` | Use existing binary |
| `--debug` | `--debug` | Enable debug logging |
| `--force` | `--force` | Recreate resources |
| `--help` | `--help` | Show help |

---

## Usage Examples

### Single Command Deployment (Recommended)

Deploys everything with automatic defaults:

**Windows PowerShell:**
```powershell
wsl bash scripts/deploy-fluidity.sh deploy
```

**macOS/Linux:**
```bash
sudo -E bash scripts/deploy-fluidity.sh deploy
```

Output:
- AWS infrastructure deployed to auto-detected region/VPC
- Lambda endpoints collected automatically
- Agent deployed with server endpoints
- Configuration created and validated

### Step-by-Step Deployment

**Windows PowerShell:**

**Step 1: Deploy server to AWS**
```powershell
wsl bash scripts/deploy-fluidity.sh deploy-server --region us-west-2
```

**Step 2: Get server IP**
```powershell
# Wait for Fargate task to start, then get its public IP
$SERVER_IP = "203.0.113.42"
```

**Step 3: Deploy agent with server**
```powershell
wsl bash scripts/deploy-fluidity.sh deploy-agent --server-ip $SERVER_IP
```

**macOS/Linux:**

**Step 1: Deploy server to AWS**
```bash
sudo -E bash scripts/deploy-fluidity.sh deploy-server --region us-west-2
```

**Step 2: Get server IP**
```bash
# Wait for Fargate task to start, then get its public IP
SERVER_IP=203.0.113.42
```

**Step 3: Deploy agent with server**
```bash
sudo -E bash scripts/deploy-fluidity.sh deploy-agent --server-ip $SERVER_IP
```

### Manual Server IP Deployment

If server IP changes or Fargate task restarts:

**Windows PowerShell:**
```powershell
wsl bash scripts/deploy-fluidity.sh deploy-agent --server-ip 198.51.100.99
```

**macOS/Linux:**
```bash
sudo -E bash scripts/deploy-fluidity.sh deploy-agent --server-ip 198.51.100.99
```

Configuration updates automatically.

### Custom Installation Path

**Windows PowerShell:**
```powershell
wsl bash scripts/deploy-fluidity.sh deploy --install-path /opt/custom/fluidity
```

**macOS/Linux:**
```bash
sudo -E bash scripts/deploy-fluidity.sh deploy --install-path /opt/custom/fluidity
```

### With Debug Logging

**Windows PowerShell:**
```powershell
wsl bash scripts/deploy-fluidity.sh deploy --debug
```

**macOS/Linux:**
```bash
sudo -E bash scripts/deploy-fluidity.sh deploy --debug
```

### Deploy to Specific AWS Region

**Windows PowerShell:**
```powershell
wsl bash scripts/deploy-fluidity.sh deploy --region eu-west-1
```

**macOS/Linux:**
```bash
sudo -E bash scripts/deploy-fluidity.sh deploy --region eu-west-1
```

### Skip Agent Build (Use Existing Binary)

**Windows PowerShell:**
```powershell
wsl bash scripts/deploy-fluidity.sh deploy --skip-build
```

**macOS/Linux:**
```bash
sudo -E bash scripts/deploy-fluidity.sh deploy --skip-build
```

### Check Deployment Status

**Windows PowerShell:**
```powershell
wsl bash scripts/deploy-fluidity.sh status
```

**macOS/Linux:**
```bash
sudo -E bash scripts/deploy-fluidity.sh status
```

Shows:
- AWS CloudFormation stack status
- Agent installation status
- Agent configuration status
- Agent running processes

### Delete AWS Infrastructure

**Windows PowerShell:**
```powershell
wsl bash scripts/deploy-fluidity.sh delete
```

**macOS/Linux:**
```bash
sudo -E bash scripts/deploy-fluidity.sh delete
```

Interactive confirmation required. Note: Agent files remain on system.

### Get Lambda Endpoint URLs

**Windows PowerShell:**
```powershell
wsl bash scripts/deploy-server.sh outputs
```

**macOS/Linux:**
```bash
sudo -E bash scripts/deploy-server.sh outputs
```

Or after deployment completes, endpoints are displayed automatically.

---

## Troubleshooting

### Prerequisites Issues

**"AWS CLI not found"**

Windows (PowerShell with WSL):
```powershell
wsl sudo apt-get install awscli
```

macOS:
```bash
brew install awscli
```

Linux:
```bash
sudo apt-get install awscli
```

**"Docker not found"**
- Install Docker Desktop: https://www.docker.com/products/docker-desktop

**"jq not found"**

Windows (PowerShell with WSL):
```powershell
wsl sudo apt-get install jq
```

macOS:
```bash
brew install jq
```

Linux:
```bash
sudo apt-get install jq
```

### Deployment Script Issues

**"Certificates not found"**

Windows (PowerShell with WSL):
```powershell
wsl bash scripts/generate-certs.sh
```

macOS/Linux:
```bash
./scripts/generate-certs.sh
```

**"Required configuration missing: server_ip"**

Windows (PowerShell with WSL):
```powershell
wsl bash scripts/deploy-agent.sh deploy --server-ip 192.168.1.100
# Or if using orchestrator:
wsl bash scripts/deploy-fluidity.sh deploy --server-ip 192.168.1.100
```

macOS/Linux:
```bash
sudo -E bash scripts/deploy-agent.sh deploy --server-ip 192.168.1.100
# Or if using orchestrator:
sudo -E bash scripts/deploy-fluidity.sh deploy --server-ip 192.168.1.100
```

**"Failed to get AWS parameters"**
```bash
# Configure AWS credentials
aws configure

# Or verify existing credentials
aws sts get-caller-identity
```

**"Region could not be auto-detected"**

Windows (PowerShell with WSL):
```powershell
wsl bash -c "aws configure set region us-east-1"
# Or provide explicitly:
wsl bash scripts/deploy-fluidity.sh deploy --region us-east-1
```

macOS/Linux:
```bash
aws configure set region us-east-1
# Or provide explicitly:
sudo -E bash scripts/deploy-fluidity.sh deploy --region us-east-1
```

**"Stack creation failed"**

Windows (PowerShell with WSL):
```powershell
# Check CloudFormation events
wsl aws cloudformation describe-stack-events --stack-name fluidity-fargate
# Check with debug output
wsl bash scripts/deploy-fluidity.sh deploy --debug
# View detailed logs
wsl aws logs tail /ecs/fluidity/server --follow
```

macOS/Linux:
```bash
# Check CloudFormation events
aws cloudformation describe-stack-events --stack-name fluidity-fargate
# Check with debug output
sudo -E bash scripts/deploy-fluidity.sh deploy --debug
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

**Server not responding**
- Manually stop server: `aws ecs update-service --cluster fluidity --service fluidity-server --desired-count 0`

### View Detailed Logs

```bash
./scripts/deploy-fluidity.sh deploy --debug
```

Shows:
- Configuration parameter values
- Script execution details
- Endpoint collection process
- Agent configuration updates

### Check Agent Status

```bash
./scripts/deploy-agent.sh status
```

Shows:
- Installation path
- Configuration file location and content
- Running processes
- PATH environment status

### Check Server Status

```bash
./scripts/deploy-server.sh status
```

Shows CloudFormation stack status.

### Verify Endpoints

```bash
./scripts/deploy-server.sh outputs
```

Shows all CloudFormation outputs including Lambda endpoints.

---

## Security Best Practices

1. **Restrict ingress:** Use your IP `/32` in `--allowed-cidr`
   ```bash
   ./scripts/deploy-fluidity.sh deploy --allowed-cidr 203.0.113.45/32
   ```

2. **Protect certificate files:** `.gitignore` already excludes `certs/*.key`

3. **Enable CloudWatch Logs retention:** Set 7-30 days in CloudFormation

4. **Rotate certificates:** At least annually
   ```bash
   ./scripts/generate-certs.sh
   ./scripts/deploy-fluidity.sh deploy --force
   ```

5. **Use stack policies:** Prevent accidental deletions (included in deploy script)

6. **Store configuration securely:** 
   - Don't commit `agent.yaml` with sensitive data
   - Use AWS Secrets Manager for production credentials

---

## Post-Deployment Steps

After running deployment:

**Step 1: Verify Agent Configuration**
```bash
./scripts/deploy-agent.sh status
```

**Step 2: Start Agent** (if not auto-started)
```bash
# Windows
C:\Program Files\fluidity\fluidity-agent.exe

# macOS/Linux
/opt/fluidity/fluidity-agent
```

**Step 3: Start Fargate Task** (if not auto-started)
```bash
aws ecs update-service \
  --cluster fluidity \
  --service fluidity-server \
  --desired-count 1 \
  --region us-east-1
```

**Step 4: Test Connection**
```bash
curl -x http://127.0.0.1:8080 http://example.com -I
```

---

## Related Documentation

- **[Certificate Guide](certificate.md)** - Certificate generation and management
- **[Docker Guide](docker.md)** - Container build and networking
- **[Fargate Guide](fargate.md)** - Detailed AWS ECS deployment
- **[Lambda Functions](lambda.md)** - Control plane architecture
- **[Infrastructure Guide](infrastructure.md)** - CloudFormation templates
- **[Architecture](architecture.md)** - System design overview

---
