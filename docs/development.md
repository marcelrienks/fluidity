# Development Guide

## Prerequisites

**See [Deployment Guide](deployment.md) for complete setup.**

Quick setup:
```bash
./scripts/setup-prereq-<platform>.sh  # Windows (WSL), Linux, macOS
```

Installs: Go 1.21+, Make, Docker, OpenSSL, Node.js 18+, npm

**Note for Windows Users:** All bash commands in this guide should be prefixed with `wsl bash` when running from PowerShell. For example: `wsl bash ./scripts/generate-certs.sh`

---

## Quick Setup

**1. Generate certificates:**
```bash
./scripts/generate-certs.sh
```

**2. Build:**
```bash
./scripts/build-core.sh                # Build both server and agent
# Or build individually:
./scripts/build-core.sh --server       # Build only server
./scripts/build-core.sh --agent        # Build only agent
# Or build for Linux (Docker/deployment):
./scripts/build-core.sh --linux
```

**3. Run:**
```bash
./build/fluidity-server -config configs/server.local.yaml  # Terminal 1
./build/fluidity-agent -config configs/agent.local.yaml    # Terminal 2
```

**4. Test:**
```bash
curl -x http://127.0.0.1:8080 http://example.com
```

## Project Structure

```
cmd/core/
├── agent/main.go          # Agent entry point
└── server/main.go         # Server entry point

internal/core/
├── agent/                 # Proxy + tunnel client
│   ├── proxy.go          # HTTP proxy server
│   └── lifecycle/        # Lifecycle management
└── server/               # mTLS server + HTTP forwarder
    ├── server.go
    └── metrics/          # CloudWatch metrics

internal/shared/
├── protocol/             # Message definitions
├── tls/                  # mTLS utilities
├── circuitbreaker/       # Failure protection
└── retry/                # Retry logic
```

## Protocol

JSON envelopes over TLS 1.3:

```go
type Envelope struct {
    Type    string
    Payload interface{}
}
```

**Flow:**
1. Browser → Agent proxy (`:8080`)
2. Agent creates envelope with Request ID
3. Agent sends over mTLS tunnel to server
4. Server forwards to target website
5. Server returns Response envelope
6. Agent returns to browser

## Build Types

**Native builds:**
- Best for debugging (VS Code breakpoints)
- Uses `configs/*.local.yaml`

**Docker images:**
- Alpine-based (~44MB)
- Uses `configs/*.docker.yaml`
- For production deployment

## Configuration

**Agent (`agent.yaml`):**
```yaml
server_ip: "3.24.56.78"
server_port: 8443
local_proxy_port: 8080
cert_file: "./certs/client.crt"
key_file: "./certs/client.key"
ca_cert_file: "./certs/ca.crt"
```

**Server (`server.yaml`):**
```yaml
listen_addr: "0.0.0.0"
listen_port: 8443
cert_file: "/root/certs/server.crt"
key_file: "/root/certs/server.key"
ca_cert_file: "/root/certs/ca.crt"
max_connections: 100
```

## Testing

**Unit tests:**
```bash
go test ./internal/shared/... -v
```

**Integration tests:**
```bash
go test ./internal/integration/... -v
```

**E2E tests:**
```bash
./scripts/test-local.sh               # All platforms (use WSL on Windows)
```

See [Testing Guide](testing.md) for details.

## Common Development Tasks

### Making Code Changes

**Modify agent proxy** (`internal/core/agent/proxy.go`):
- `handleHTTPRequest()` - HTTP handling
- `handleConnect()` - HTTPS CONNECT

**Modify tunnel logic** (`internal/core/agent/agent.go`, `internal/core/server/server.go`):
- Update both agent and server together
- Protocol changes require updating `internal/shared/protocol/protocol.go`

**Test changes:**
```bash
# Run tests
go test ./... -v

# Build and run locally
./scripts/build-core.sh
./build/fluidity-server -config configs/server.local.yaml
./build/fluidity-agent -config configs/agent.local.yaml
```

### Debugging

**Native binaries:**
- Use VS Code Go debugger
- Set breakpoints in `*.go` files
- Check `configs/*.local.yaml` for paths

**Docker containers:**
```bash
docker logs -f fluidity-server
docker logs -f fluidity-agent
docker exec -it fluidity-agent sh
```

**TLS issues:**
- Verify cert dates: `openssl x509 -in certs/server.crt -noout -dates`
- Check `ServerName` in client TLS config
- Enable TLS debug: `GODEBUG=tls13=1`

## Important Patterns

### Wire Protocol
```go
// Always use envelopes
env := protocol.Envelope{Type: "http_request", Payload: req}
encoder.Encode(env)
```

### Request Tracking
Every HTTP request gets unique ID for correlation across tunnel.

### Graceful Shutdown
Use context cancellation and wait groups for clean shutdown.

### Auto-Reconnection
Agent reconnects automatically on connection loss (5s intervals, 90s max).

## Dependencies

**External:**
- `github.com/spf13/cobra` - CLI framework
- `github.com/spf13/viper` - Configuration
- `github.com/sirupsen/logrus` - Logging

**Standard library:**
- `crypto/tls` - mTLS
- `net/http` - Proxy and client
- `encoding/json` - Protocol serialization

## Related Documentation

- [Testing Guide](testing.md) - Test strategy
- [Architecture](architecture.md) - System design
- [Certificate Management](certificate.md) - TLS setup
- [Deployment Guide](deployment.md) - Deployment options
