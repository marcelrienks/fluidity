# Fluidity

**Secure HTTP/HTTPS/WebSocket tunneling solution with mTLS authentication**

![Status](https://img.shields.io/badge/status-Phase_2-blue)
![License](https://img.shields.io/badge/license-custom-lightgrey)

## What is Fluidity?

Fluidity is a secure HTTP/HTTPS/WebSocket tunneling solution designed for environments with restrictive firewalls. It enables applications to access external services through a cloud-hosted tunnel server using mutual TLS (mTLS) authentication.

**Key Use Cases:**
- Developers behind corporate firewalls accessing blocked services
- Remote workers needing secure outbound access
- Applications requiring tunneled HTTP/HTTPS/WebSocket traffic

_Predominantly vibe coded with Claude and Grok as a learning exercise._

**Stack**: Go 1.23+, Docker (~44MB Alpine), AWS ECS Fargate & Lambda
**Security**: mTLS (TLS 1.3) with private CA certificates

## How It Works

Fluidity operates as a **client-server tunnel system** with on-demand lifecycle management:

```
┌─────────────────────────────────────────────────────────────────┐
│ Deployment Model (One Server Per Agent)                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│ Local:            Cloud:                                        │
│ Browser           Lambda (Wake/Query) ─┐                       │
│    ↓              ├─→ ECS Fargate (Server)                      │
│ Agent (8080) ──→  └─→ Target Services                           │
│ (mTLS tunnel)                                                   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Runtime Workflow

1. **Server Startup**: Agent calls Wake Lambda to start a dedicated server instance
2. **Discovery**: Agent calls Query Lambda to obtain server IP address
3. **Connection**: Agent connects via mTLS to server (TLS 1.3)
4. **Tunneling**: Agent proxies HTTP requests through WebSocket tunnel
5. **Auto-Scale**: Server idles → Sleep Lambda scales down after 15 minutes
6. **Cleanup**: On shutdown, agent calls Kill Lambda to terminate server

This model provides:
- **Predictable lifecycle**: One server per agent, ephemeral (not persisted)
- **Cost efficiency**: Server only runs when needed
- **Simple failure semantics**: Agent exits on connection failure for orchestration retry

## Prerequisites

**Required:**
- Go 1.23+
- Make
- OpenSSL
- Docker Desktop (for container deployments)
- AWS CLI v2 (for cloud deployments)
- Node.js 18+ and npm (for testing)

**Platform Setup:**
- **Windows**: WSL (Windows Subsystem for Linux) required; run `bash scripts/setup-prereq-ubuntu.sh` in WSL
- **Linux**: Ubuntu/Debian (`bash scripts/setup-prereq-ubuntu.sh`) or Arch (`bash scripts/setup-prereq-arch.sh`)
- **macOS**: `bash scripts/setup-prereq-mac.sh`

## Quick Start

### Local Development (5 minutes)

Get Fluidity running on your machine:

```bash
# 1. Generate mTLS certificates
./scripts/generate-certs.sh

# 2. Build server and agent
./scripts/build-core.sh

# 3. Start server (Terminal 1)
./build/fluidity-server -config configs/server.local.yaml

# 4. Start agent (Terminal 2)
./build/fluidity-agent -config configs/agent.local.yaml

# 5. Test with curl
curl -x http://127.0.0.1:8080 http://example.com
```

**→ Full setup guide:** [Development](docs/development.md)

### Docker Deployment (10 minutes)

Test containerized images locally:

```bash
# Build images
./scripts/build-core.sh --linux
docker build -f deployments/server/Dockerfile -t fluidity-server .
docker build -f deployments/agent/Dockerfile -t fluidity-agent .

# Run server
docker run --rm \
  -v "$(pwd)/certs:/root/certs:ro" \
  -v "$(pwd)/configs/server.docker.yaml:/root/config/server.yaml:ro" \
  -p 8443:8443 \
  fluidity-server

# Run agent (separate terminal)
docker run --rm \
  -v "$(pwd)/certs:/root/certs:ro" \
  -v "$(pwd)/configs/agent.docker.yaml:/root/config/agent.yaml:ro" \
  -p 8080:8080 \
  fluidity-agent
```

**→ Full guide:** [Deployment](docs/deployment.md)

### AWS Deployment (10 minutes)

Deploy to production with ECS Fargate and Lambda control plane:

```bash
# 1. Generate certificates and push to AWS Secrets Manager
./scripts/generate-certs.sh --save-to-secrets

# 2. Deploy all infrastructure automatically
./scripts/deploy-fluidity.sh deploy
```

This deploys:
- ECS Fargate cluster with server task
- Lambda functions (Wake, Query, Sleep, Kill)
- CloudFormation stacks for infrastructure
- Local agent configuration

**Start the agent:**
```bash
fluidity
```

The agent automatically loads configuration and starts the tunnel. For additional options, use:
```bash
fluidity --help
```

**→ Full guide:** [Deployment](docs/deployment.md) | [Infrastructure](docs/infrastructure.md)

### Running Agent & Browser (3 minutes)

Launch Fluidity agent and Brave browser with proxy configured in one command:

```bash
# From WSL - automatically detects IP and launches Brave
brave-fluidity

# Or explicitly
/home/marcelr/apps/fluidity/launch-brave
```

The agent is automatically available on port 8080 and all browser traffic routes through the secure tunnel.

**Supported launch methods:**
- WSL: `brave-fluidity` (alias) or `/home/marcelr/apps/fluidity/launch-brave` (script)
- PowerShell: `$wslIp = wsl hostname -I | % {$_.Trim().Split()[0]}; brave.exe --proxy-server="http://$wslIp:8080"`
- CMD: `wsl bash -c "brave-fluidity"`

**→ Full guide:** [Launch Guide](docs/LAUNCH.md)

## Architecture & System Design

### Components

**Agent (Local)** - HTTP proxy on port 8080
- Accepts local HTTP/HTTPS requests
- Establishes mTLS tunnel to server
- Calls lifecycle Lambdas (Wake on startup, Kill on shutdown)
- Auto-reconnects on failure with exponential backoff
- Exits on unrecoverable connection failure

**Server (Cloud)** - mTLS tunnel endpoint on port 8443
- Receives tunneled requests via WebSocket
- Forwards to target websites
- Emits CloudWatch metrics for monitoring
- Health check endpoint on port 8080

**Control Plane** - AWS Lambda functions
- **Wake**: Scale ECS DesiredCount=1 to start server
- **Query**: Return server public IP for agent connection
- **Sleep**: Auto-scale down if idle >15 minutes (EventBridge scheduled)
- **Kill**: Scale ECS DesiredCount=0 to terminate server

### Communication Protocol

JSON envelopes over TLS 1.3 WebSocket:

```go
type Envelope struct {
    Type    string      // "request", "response", etc.
    Payload interface{}
}
```

Message types:
- **HTTP**: Standard HTTP requests/responses (all methods, headers, body)
- **HTTPS CONNECT**: CONNECT tunneling for HTTPS (SSL proxying)
- **WebSocket**: Bidirectional WebSocket connections with keepalive

### Configuration

**Agent** (`agent.yaml`):
```yaml
server_ip: "3.24.56.78"          # ECS Fargate public IP
server_port: 8443
local_proxy_port: 8080
cert_file: "./certs/client.crt"  # mTLS client cert
key_file: "./certs/client.key"
ca_cert_file: "./certs/ca.crt"
wake_endpoint: "https://lambda-url/wake"
kill_endpoint: "https://lambda-url/kill"
log_level: "info"
```

**Server** (`server.yaml`):
```yaml
listen_addr: "0.0.0.0"
listen_port: 8443
cert_file: "/root/certs/server.crt"  # mTLS server cert
key_file: "/root/certs/server.key"
ca_cert_file: "/root/certs/ca.crt"
max_connections: 100
emit_metrics: true
log_level: "info"
```

**→ Full details:** [Architecture](docs/architecture.md)

## Security & Certificates

Fluidity uses **mutual TLS (mTLS)** with a private Certificate Authority for all communications:

### Setup

Generate certificates for local development:
```bash
./scripts/generate-certs.sh
# Output: ./certs/{ca,server,client}.{crt,key}
```

Generate and store in AWS Secrets Manager:
```bash
./scripts/generate-certs.sh --save-to-secrets
# Output: fluidity/certificates secret (base64-encoded PEM format)
```

### Security Practices

- Self-signed certificates for development (2-year validity)
- Production deployments should use trusted CA certificates
- Certificates never committed to version control (`.key` files in `.gitignore`)
- AWS KMS encryption for Secrets Manager in production
- Regular rotation recommended (re-run generation script)

**→ Full guide:** [Certificates](docs/certificate.md)

## Deployment Options Summary

| Option | Best For | Setup Time | Cost |
|--------|----------|-----------|------|
| **Local** | Development & testing | 5 min | Free (local only) |
| **Docker** | Pre-production testing | 10 min | Free (local only) |
| **AWS Fargate** | Production | 10 min | ~$10/month idle |
| **+ Lambda Control** | Cost optimization | 15 min | Pay-per-use + $5/month |

**Deployment Workflow:**
1. Deploy server infrastructure & Lambdas first
2. Deploy agent with server details
3. Use deploy manager for coordination

**→ Complete guide:** [Deployment](docs/deployment.md)

## Project Structure

```
/cmd/core/
├── agent/main.go              # Agent entry point
└── server/main.go             # Server entry point

/internal/core/
├── agent/                      # Proxy, tunnel client, lifecycle
├── server/                     # mTLS, HTTP forwarding, metrics
└── lambdas/                    # Lambda function implementations

/internal/shared/
├── protocol/                   # Message types and serialization
├── tls/                        # mTLS utilities and certificate handling
├── config/                     # YAML configuration loading (viper/cobra)
├── logging/                    # Structured logging (logrus)
├── circuitbreaker/             # Failure protection and retry logic
└── retry/                      # Exponential backoff utilities

/deployments/cloudformation/
├── fargate.yaml                # ECS infrastructure
├── lambda.yaml                 # Lambda control plane
└── params.json                 # CloudFormation parameters

/scripts/
├── generate-certs.sh           # Certificate generation
├── build-core.sh               # Build server and agent
├── deploy-fluidity.sh          # AWS deployment orchestration
└── setup-prereq-*.sh           # Platform prerequisites

/docs/
├── architecture.md             # System design and components
├── deployment.md               # Setup for all environments
├── development.md              # Local development guide
├── certificate.md              # mTLS certificate management
├── infrastructure.md           # CloudFormation details
├── product.md                  # Features and use cases
└── plan.md                     # Roadmap and TODO items
```

## Development & Contributing

### Local Setup

```bash
# Prerequisites
bash scripts/setup-prereq-<platform>.sh  # ubuntu, arch, or mac

# Development environment
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

- Follow standard Go conventions (gofmt, golangci-lint)
- Error handling: Always check and handle errors explicitly
- Logging: Use logrus for structured logging at appropriate levels
- Comments: Only clarify complex logic, not obvious code

**→ Full guide:** [Development](docs/development.md)

## Operations & Troubleshooting

### Monitoring

CloudWatch metrics emitted by server:
- Active connections
- Request/response latency
- Error rates

### Common Issues

| Issue | Solution |
|-------|----------|
| Certificate errors | Regenerate: `./scripts/generate-certs.sh` |
| Connection refused | Verify server IP: check Lambda query response |
| TLS handshake failure | Verify certificates match (ca.crt, client.crt, server.crt) |
| Agent won't start | Check logs with `log_level: debug` in config |

### AWS Troubleshooting

```bash
# Check CloudFormation stack status
aws cloudformation describe-stack-events --stack-name fluidity-fargate

# View server logs
aws logs tail /ecs/fluidity/server --follow

# Check Lambda logs
aws logs tail /aws/lambda/fluidity-wake --follow

# Verify ECS task is running
aws ecs describe-tasks --cluster fluidity --tasks <task-arn>
```

## Roadmap & Future Work

**Near-term (Phase 2):**
- IAM authentication for server connections (SigV4 signing)
- Enhanced monitoring and alerting
- Performance optimization and load testing

**Long-term (Phase 3):**
- Production certificate issuance (CA integration)
- Advanced failure recovery scenarios
- Multi-region deployment

**→ Full details:** [Plan](docs/plan.md)

## Feature Summary

✅ **HTTP/HTTPS Tunneling** - All methods, headers, body, large payloads
✅ **WebSocket Support** - Bidirectional, concurrent, keepalive
✅ **Security** - mTLS (TLS 1.3), private CA, no plaintext
✅ **Reliability** - Auto-reconnect, circuit breaker, exponential backoff
✅ **Deployment** - Local, Docker, AWS Fargate with Lambda control plane
✅ **Lifecycle** - Agent auto-starts server, auto-scales down when idle
✅ **Efficient** - One server per agent, pay only for runtime

**Success Metrics:**
- Tunnel HTTP/HTTPS/WebSocket traffic successfully
- <500ms latency overhead
- 99%+ uptime (cloud deployment)
- <10 minutes setup time
- Server discovery within 30 seconds
- Cost-effective idle scaling

**→ Details:** [Product](docs/product.md)

## Disclaimer

⚠️ Users are responsible for compliance with organizational policies and local laws.

## License

Custom - See repository for details
