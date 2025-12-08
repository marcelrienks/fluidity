# Architecture

Secure client-server tunnel using mTLS for HTTP/HTTPS/WebSocket tunneling through restrictive firewalls.

## System Overview

```
Local: Browser → Agent (8080) → Server (8443) → Target Website
Cloud: Lambda (Wake/Kill/Query) → ECS Fargate (Server)
```

## Components

### Agent (Local)
- HTTP proxy on port 8080
- mTLS client to server
- Calls Wake Lambda on startup to discover server IP
- Calls Kill Lambda on shutdown

Config:
```yaml
server_ip: ""                    # Auto-discovered
server_port: 8443
local_proxy_port: 8080
cert_file: "./certs/client.crt"
key_file: "./certs/client.key"
ca_cert_file: "./certs/ca.crt"
wake_endpoint: "https://..."     # Lambda endpoint
kill_endpoint: "https://..."
```

### Server (Cloud)
- mTLS server on port 8443
- Forwards requests to target websites
- Emits CloudWatch metrics
- Health check on port 8080

Config:
```yaml
listen_addr: "0.0.0.0"
listen_port: 8443
cert_file: "/root/certs/server.crt"
key_file: "/root/certs/server.key"
ca_cert_file: "/root/certs/ca.crt"
max_connections: 100
emit_metrics: true
metrics_interval: "60s"
```

### Lambda Functions
- **Wake**: Start server (ECS DesiredCount=1)
- **Query**: Get server IP
- **Sleep**: Auto-scale down if idle >15min (EventBridge, 5min check)
- **Kill**: Stop server (ECS DesiredCount=0)

## Runtime Flow

1. Agent starts → calls Wake Lambda
2. Agent calls Query Lambda → gets server IP
3. Agent connects via mTLS to server
4. Agent proxies HTTP requests through tunnel
5. Server idles → Sleep Lambda scales down
6. Agent shutdown → calls Kill Lambda

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
