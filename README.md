# Fluidity

**Secure HTTP/HTTPS/WebSocket tunneling for restrictive firewall environments**

![Status](https://img.shields.io/badge/status-Phase_2-blue)
![License](https://img.shields.io/badge/license-custom-lightgrey)

Fluidity is a secure tunneling solution using mTLS authentication to enable applications behind restrictive firewalls to access external services. Agent runs locally, server runs on-demand in AWS.

**Key Features:**
- Secure tunnel: HTTP/HTTPS/WebSocket over mTLS (TLS 1.3)
- On-demand lifecycle: Server auto-starts on agent startup, scales down when idle
- Cost-efficient: Pay only for server runtime (one per agent)
- Easy deployment: Local, Docker, or AWS (Fargate + Lambda)

**Stack**: Go 1.23+ | Docker (~44MB Alpine) | AWS ECS Fargate & Lambda

---

## Quick Start

### Local Development (5 minutes)

```bash
./scripts/generate-certs.sh
./scripts/build-core.sh
./build/fluidity-server -config configs/server.local.yaml  # Terminal 1
./build/fluidity-agent -config configs/agent.local.yaml    # Terminal 2
curl -x http://127.0.0.1:8080 http://example.com
```

→ **[Development Guide](docs/development.md)**

### Docker (10 minutes)

```bash
./scripts/build-core.sh --linux
docker build -f deployments/server/Dockerfile -t fluidity-server .
docker build -f deployments/agent/Dockerfile -t fluidity-agent .
# Run containers with config mounts...
```

→ **[Deployment Guide](docs/deployment.md)**

### AWS Production (10 minutes)

```bash
./scripts/deploy-fluidity.sh deploy
fluidity
```

Deploys ECS Fargate server + Lambda control plane + configures agent.

→ **[Deployment Guide](docs/deployment.md) | [Infrastructure](docs/infrastructure.md)**

### Run Agent & Browser

```bash
brave-fluidity          # WSL alias (auto-detects IP, launches Brave)
fluidity --log-level debug
fluidity --proxy-port 9090
```

→ **[Launch Guide](docs/launch.md)**

## Architecture

**System Overview:**
```
Local:  Browser → Agent (8080) → Server (8443) → Target
Cloud:  Lambda (Wake/Query/Sleep/Kill) ↔ ECS Fargate (Server)
```

**Runtime Flow:**
1. Agent starts → calls Wake Lambda (starts server)
2. Agent calls Query Lambda (gets server IP)
3. Agent connects via mTLS to server
4. Agent proxies HTTP requests through WebSocket tunnel
5. Server idles 15min → Sleep Lambda scales down
6. Agent shutdown → calls Kill Lambda

**Components:**
- **Agent**: Local HTTP proxy on port 8080, mTLS client, lifecycle management
- **Server**: Cloud mTLS endpoint on port 8443, forwards requests, emits metrics
- **Lambda**: Wake (start), Query (get IP), Sleep (auto-scale), Kill (stop)

→ **[Full Architecture](docs/architecture.md)**

## Security

Fluidity uses **mutual TLS (mTLS)** with a private CA for all communications.

**Generate Certificates:**
```bash
./scripts/generate-certs.sh              # Local files
./scripts/generate-certs.sh --save-to-secrets  # AWS Secrets Manager
```

**Practices:**
- Self-signed certs for development (2-year validity)
- Production: Use trusted CA certificates
- Keys never committed (`.gitignore`)
- AWS KMS encryption for Secrets Manager in production

→ **[Certificate Guide](docs/certificate.md)**

## Development

### Setup

```bash
bash scripts/setup-prereq-<platform>.sh  # ubuntu, arch, or mac
./scripts/generate-certs.sh
./scripts/build-core.sh
```

### Testing

```bash
go test ./internal/shared/...  # Unit tests
go test ./internal/core/...    # Component tests
./scripts/test-local.sh         # End-to-end test
```

### Code Style

- Follow Go conventions (gofmt, golangci-lint)
- Check and handle errors explicitly
- Use logrus for structured logging
- Comment only complex logic, not obvious code

→ **[Development Guide](docs/development.md)**

## Troubleshooting

**Certificate errors** → `./scripts/generate-certs.sh`  
**Connection refused** → Verify server IP in agent config  
**TLS handshake failure** → Ensure certificates match (ca.crt, client.crt, server.crt)  
**Agent won't start** → Check logs with `log_level: debug` in config  

AWS debugging:
```bash
aws cloudformation describe-stack-events --stack-name fluidity-fargate
aws logs tail /ecs/fluidity/server --follow
aws logs tail /aws/lambda/fluidity-wake --follow
```

→ **[Full Troubleshooting](docs/deployment.md)**

## Features & Capabilities

✅ HTTP/HTTPS tunneling (all methods, headers, body, large payloads)  
✅ WebSocket support (bidirectional, concurrent, keepalive)  
✅ Security: mTLS (TLS 1.3), private CA, no plaintext  
✅ Reliability: Auto-reconnect, circuit breaker, exponential backoff  
✅ Deployment: Local, Docker, AWS Fargate + Lambda  
✅ Lifecycle: Agent auto-starts server, auto-scales down when idle  
✅ Cost-efficient: One server per agent, pay-per-use  

→ **[Product Details](docs/product.md)**

## Roadmap

**Phase 2 (Current):**
- IAM authentication (SigV4 signing)
- Enhanced monitoring and alerting
- Performance optimization

**Phase 3 (Future):**
- Production certificate issuance (CA integration)
- Advanced failure recovery
- Multi-region deployment

→ **[Full Roadmap](docs/plan.md)**

## Documentation

| Guide | Purpose |
|-------|---------|
| [Architecture](docs/architecture.md) | System design, components, protocol |
| [Deployment](docs/deployment.md) | Setup instructions (local, Docker, AWS) |
| [Development](docs/development.md) | Local dev setup, testing, code style |
| [Launch](docs/launch.md) | Running agent and browser |
| [Certificates](docs/certificate.md) | mTLS certificate management |
| [Infrastructure](docs/infrastructure.md) | CloudFormation stack details |
| [Product](docs/product.md) | Features, use cases, metrics |
| [Plan](docs/plan.md) | Roadmap and outstanding work |
