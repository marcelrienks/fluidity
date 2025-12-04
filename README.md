# Fluidity

**Secure HTTP/HTTPS tunneling solution with mTLS authentication**

![Status](https://img.shields.io/badge/status-Phase_2-blue)
![License](https://img.shields.io/badge/license-custom-lightgrey)

## Overview

Fluidity is a secure HTTP/HTTPS/WebSocket tunneling solution designed for environments with restrictive firewalls. It enables applications to access external services through a cloud-hosted tunnel server using mutual TLS authentication.

**Intended Use Case**: Deploy the server infrastructure (lifecycle Lambdas) first; agents always start a dedicated server instance on startup via lifecycle Wake/Query and manage that server for the lifetime of the agent process. Agents do not persist discovered server IPs to disk.

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
- **Server startup**: On every agent start the agent calls lifecycle Wake/Query to start a server instance and obtain its IP address.
- **Ephemeral server**: The agent does not persist the discovered server IP; the server instance is ephemeral and scoped to the agent process.
- **Connection management**: The agent attempts an mTLS connection to the started server; if the connection fails the agent logs the error and exits so external orchestrators can retry.
- **Shutdown**: On clean exit or unrecoverable error the agent will call lifecycle Kill to terminate the server instance it started.

This model provides predictable one-server-per-agent lifecycle management and simplifies failure semantics for orchestration systems.

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

