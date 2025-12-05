# Development

## Setup

Prerequisites:
```bash
./scripts/setup-prereq-<platform>.sh  # ubuntu, arch (Linux), or mac
# Installs: Go 1.21+, Make, Docker, OpenSSL, Node.js, npm
```

## Quick Start

```bash
./scripts/generate-certs.sh
./scripts/build-core.sh
./build/fluidity-server -config configs/server.local.yaml  # Terminal 1
./build/fluidity-agent -config configs/agent.local.yaml    # Terminal 2
curl -x http://127.0.0.1:8080 http://example.com
```

## Project Structure

```
cmd/core/
├── agent/main.go       # Agent entry point
└── server/main.go      # Server entry point

internal/core/
├── agent/              # Proxy + tunnel client + lifecycle
├── server/             # mTLS + HTTP forward + metrics
└── lambdas/            # Lambda functions

internal/shared/
├── protocol/           # Message types (Request, Response, etc.)
├── tls/                # mTLS utilities
├── config/             # YAML configuration
├── logging/            # Structured logging
├── circuitbreaker/     # Failure protection
└── retry/              # Retry logic
```

## Build

```bash
./scripts/build-core.sh              # Native build (macOS, Linux)
./scripts/build-core.sh --linux      # Linux binary (for Docker)
./scripts/build-core.sh --server     # Server only
./scripts/build-core.sh --agent      # Agent only
```

Binaries: `build/fluidity-server`, `build/fluidity-agent`

## Configuration

**Agent** (`configs/agent.local.yaml`):
```yaml
server_ip: "127.0.0.1"
server_port: 8443
local_proxy_port: 8080
cert_file: "./certs/client.crt"
key_file: "./certs/client.key"
ca_cert_file: "./certs/ca.crt"
log_level: "debug"
```

**Server** (`configs/server.local.yaml`):
```yaml
listen_addr: "127.0.0.1"
listen_port: 8443
cert_file: "./certs/server.crt"
key_file: "./certs/server.key"
ca_cert_file: "./certs/ca.crt"
max_connections: 100
log_level: "debug"
```

## Testing

```bash
go test ./internal/shared/... -v        # Unit tests
go test ./internal/core/... -v          # Component tests
./scripts/test-local.sh                 # E2E test
```

## Protocol

JSON envelopes over TLS 1.3:

```go
type Envelope struct {
    Type    string      // "request", "response", etc.
    Payload interface{}
}
```

Flow:
1. Browser → Agent proxy (`:8080`)
2. Agent creates Envelope with Request ID
3. Agent sends over mTLS to server
4. Server forwards HTTP request to target
5. Server returns Response envelope
6. Agent returns to browser

## Common Tasks

**Modify agent proxy logic**:
- Edit: `internal/core/agent/` (proxy.go, agent.go)
- Test: `go test ./internal/core/agent/...`

**Modify server logic**:
- Edit: `internal/core/server/server.go`
- Test: `go test ./internal/core/server/...`

**Modify protocol**:
- Edit: `internal/shared/protocol/`
- Update both agent and server implementations

**Debug locally**:
- VS Code: Set breakpoints in Go files
- Container: `docker logs -f <container>`
- TLS issues: `openssl x509 -in certs/server.crt -noout -text`

## Dependencies

**External:**
- `github.com/spf13/cobra` - CLI
- `github.com/spf13/viper` - Config
- `github.com/sirupsen/logrus` - Logging
- `github.com/gorilla/websocket` - WebSocket support
- `github.com/aws/aws-sdk-go-v2` - AWS SDK

**Standard Library:**
- `crypto/tls` - mTLS
- `net/http` - HTTP proxy
- `encoding/json` - Serialization

## Code Style

- Follow Go conventions (gofmt, golangci-lint)
- Error handling: Always check and handle errors
- Logging: Use logrus for structured logging at appropriate levels
- Comments: Only clarify complex logic, not obvious code

---

See [Architecture](architecture.md) for design | [Deployment](deployment.md) for deployment
