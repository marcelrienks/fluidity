# Architecture

Secure client-server tunnel using ARN-based mTLS for HTTP/HTTPS/WebSocket tunneling through restrictive firewalls.

## System Overview

```
Local: Browser → Agent (8080) → Server (8443) → Target Website
Cloud: Lambda (Wake/Query/CA) → ECS Fargate (Server)
```

## ARN-Based mTLS Flow

**Target Architecture** (Currently Under Development):
1. AGENT STARTUP
   Agent ──> Wake Lambda ──> Returns: server_arn, server_ip, agent_ip
         └──> Generate cert: CN=server_arn, SAN=[agent_ip]
              └──> CA Lambda signs ✓

2. SERVER STARTUP (Lazy)
   Server ──> Discover ARN & IP ──> Generate RSA key (NO CERT YET)

3. FIRST CONNECTION
   Agent ──> Server
             └──> Extract agent IP
             └──> Generate cert: CN=server_arn, SAN=[server_ip, agent_ip]
             └──> CA Lambda signs ✓

   Mutual Validation:
   • Agent: Server CN == ARN ✓, IP in SAN ✓
   • Server: Client CN == ARN ✓, IP in SAN ✓

4. SUBSEQUENT CONNECTIONS
   Known agent: Cached cert (fast)
   New agent: Regenerate cert + updated SAN
```

**Current Status**: Core functions exist but integration is incomplete. See [TODO.md](../TODO.md) Section 1 for integration tasks.

### Agent (Local)
- HTTP proxy on port 8080
- ARN-based mTLS client
- Calls Wake Lambda on startup
- Validates server ARN + IP

Config:
```yaml
wake_lambda_url: "https://..."
ca_lambda_url: "https://..."
cache_dir: "/tmp/fluidity"
local_proxy_port: 8080
```

### Server (Cloud - ECS Fargate)
- ARN-based mTLS server on port 8443
- Lazy certificate generation
- Discovers own ARN from ECS metadata
- Validates client ARN + IP

Config:
```yaml
listen_port: 8443
ca_lambda_url: "https://..."
cache_dir: "/tmp/fluidity"
max_connections: 100
```

### Lambda Functions
- **Wake**: Start server, return `server_arn`, `server_ip`, `agent_ip`
- **Query**: Return server status + `server_arn`
- **CA**: Sign CSRs (accepts ARN CN + multi-IP SAN)
- **Sleep**: Auto-scale down if idle >15min
- **Kill**: Stop server (ECS DesiredCount=0)

## Runtime Flow

1. Agent starts → Wake Lambda → get server ARN/IP
2. Agent generates cert (CN=server_arn)
3. Agent polls Query Lambda → wait for server ready
4. Agent connects via mTLS (validates ARN + IP)
5. Server generates cert on first connection (lazy)
6. Server validates client cert (ARN + IP)
7. Agent proxies HTTP/HTTPS/WebSocket requests
8. Server idles → Sleep Lambda scales down
9. Agent shutdown → Kill Lambda

## Communication Protocol

JSON envelopes over TLS 1.3:
```go
type Envelope struct {
    Type    string      // "request", "response", etc.
    Payload interface{}
}
```

Message types:
- **HTTP**: Request/Response with method, URL, headers, body
- **HTTPS CONNECT**: ConnectRequest, ConnectAck, ConnectData  
- **WebSocket**: WebSocketOpen, WebSocketMessage, WebSocketClose

## Security

- mTLS with private CA (TLS 1.3 minimum)
- Mutual certificate validation
- No plaintext transmission
- CloudWatch Logs for audit

## Deployment

**Local**: Binaries on machine  
**Docker**: ~44MB Alpine images  
**AWS**: ECS Fargate (0.25 vCPU, 512MB) + Lambda control plane

## Project Structure

```
cmd/core/
├── agent/main.go
└── server/main.go

internal/core/
├── agent/              # Proxy + tunnel client
├── server/             # mTLS + HTTP forward
└── lambdas/            # Lambda functions

internal/shared/
├── protocol/           # Message types
├── tls/                # mTLS utilities
├── config/             # YAML loading
└── circuitbreaker/     # Failure protection
```

---

See [Deployment](deployment.md) for setup | [Development](development.md) for local development
