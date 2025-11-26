# Fluidity

**Secure HTTP/HTTPS tunneling solution with mTLS authentication**

![Status](https://img.shields.io/badge/status-Phase_2-blue)
![License](https://img.shields.io/badge/license-custom-lightgrey)

## Overview

Fluidity is a secure HTTP/HTTPS/WebSocket tunneling solution designed for environments with restrictive firewalls. It enables applications to access external services through a cloud-hosted tunnel server using mutual TLS authentication.

**Intended Use Case**: Deploy the server infrastructure first, then deploy agents that can dynamically discover and wake up servers as needed. The agent automatically manages server lifecycle - discovering IPs, waking idle servers, and maintaining connections.

_Predominantly vibe coded with mixture of claude and grok as a learning excercise._

**Stack**: Go, Docker, AWS ECS Fargate, Lambda
**Size**: ~44MB Alpine containers
**Security**: mTLS with private CA + AWS IAM authentication

## Intended Workflow

Fluidity follows a specific deployment and runtime workflow:

### Deployment Process
1. **Deploy Server & Lambdas First**: Deploy the tunnel server and lifecycle management Lambda functions to AWS
2. **Deploy Agent**: Use deployment details from step 1 to configure and deploy the agent
3. **Orchestration**: Use the deploy manager to coordinate deployments with appropriate configurations

### Runtime Behavior
- **Server Discovery**: Agent startup checks for server IP; if not configured, triggers wake Lambda to start server
- **Dynamic IP Resolution**: Agent polls query Lambda to discover the running server's IP address
- **Auto-Configuration**: Discovered IP is written to agent config for future use
- **Connection Management**: Agent maintains persistent tunnel connection; if lost, re-triggers discovery cycle
- **Lifecycle Management**: Server can auto-scale down when idle; agent wakes it up as needed

This design enables cost-effective, on-demand tunneling infrastructure that scales with usage.

## Prerequisites

**Required:**
- Go 1.21+
- Make
- OpenSSL
- Docker Desktop (for container deployments)
- AWS CLI v2 (for cloud deployments)
- Node.js 18+ and npm (for testing)

**For Windows users:**
- WSL (Windows Subsystem for Linux) is **required** - all bash scripts and make commands must be run in WSL
- Run the setup script in WSL: `bash scripts/setup-prereq-ubuntu.sh`

**For Linux users:**
- Ubuntu/Debian: `bash scripts/setup-prereq-ubuntu.sh`
- Arch Linux: `bash scripts/setup-prereq-arch.sh`

**For macOS users:**
- Run: `bash scripts/setup-prereq-mac.sh`

## Quick Start

For detailed setup, see the [Deployment Guide](docs/deployment.md).

**Local development:**
```bash
./scripts/generate-certs.sh             # Generate certificates
./scripts/build-core.sh                # Build server and agent
./build/fluidity-server -config configs/server.local.yaml  # Terminal 1
./build/fluidity-agent -config configs/agent.local.yaml    # Terminal 2
```

**Note:** These commands use bash syntax. On Windows, run with WSL: `wsl bash scripts/generate-certs.sh` etc.

## Architecture
**→ Full details:** [Architecture Documentation](docs/architecture.md)
Fluidity uses a **client-server architecture** with mTLS authentication for secure tunneling through restrictive firewalls.

**Key Components:**
- **Agent** (local proxy): Accepts HTTP/HTTPS requests on port 8080, forwards to server via WebSocket tunnel
- **Server** (cloud-based): Receives tunneled requests, performs HTTP calls, returns responses
- **Protocol**: Custom WebSocket-based with request/response IDs, connection pooling, auto-reconnection
- **Security**: Mutual TLS with private CA certificates, no plaintext credentials

## Deployment Options

See [Deployment Guide](docs/deployment.md) for complete setup:

- **Local**: Run server and agent on your machine
- **Docker**: Test containerized images locally  
- **AWS Fargate**: Production deployment with auto-scaling
- **Lambda Control Plane**: Optional cost optimization (idle shutdown)

## Documentation

- **[Deployment Guide](docs/deployment.md)** - Setup for all options
- **[Architecture](docs/architecture.md)** - System design
- **[Docker Guide](docs/docker.md)** - Container operations
- **[Infrastructure](docs/infrastructure.md)** - CloudFormation details
- **[Fargate](docs/fargate.md)** - ECS deployment
- **[Lambda](docs/lambda.md)** - Control plane
- **[Development](docs/development.md)** - Local setup
- **[Testing](docs/testing.md)** - Test strategy
- **[Certificates](docs/certificate.md)** - mTLS setup
- **[Runbook](docs/runbook.md)** - Operations
- **[Product](docs/product.md)** - Requirements
- **[Plan](docs/plan.md)** - Roadmap

## Disclaimer

⚠️ Users are responsible for compliance with organizational policies and local laws.

## License

Custom - See repository for details

