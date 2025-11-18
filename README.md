# Fluidity

**Secure HTTP/HTTPS tunneling solution with mTLS authentication**

![Status](https://img.shields.io/badge/status-Phase_2-blue)
![License](https://img.shields.io/badge/license-custom-lightgrey)

## Overview

Fluidity tunnels HTTP/HTTPS/WebSocket traffic through restrictive firewalls using mutual TLS authentication between a local agent and cloud-hosted server.

_Predominantly vibe coded with mixture of claude and grok as a learning excercise._

**Stack**: Go, Docker, AWS ECS Fargate, Lambda  
**Size**: ~44MB Alpine containers  
**Security**: mTLS with private CA

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

