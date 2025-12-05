# Product

Fluidity is a secure HTTP/HTTPS/WebSocket tunnel for restrictive firewall environments using mTLS authentication.

## Overview

Enable applications behind restrictive firewalls to access external services through a secure, on-demand tunnel infrastructure.

## Use Cases

- Developers behind corporate firewalls accessing blocked services
- Remote workers needing secure outbound access
- Applications requiring tunneled HTTP/HTTPS/WebSocket traffic

## Core Features

- **HTTP/HTTPS Tunneling**: All methods, headers, body, large payloads
- **WebSocket Support**: Bidirectional, concurrent connections, keepalive
- **Security**: mTLS (TLS 1.3), private CA, no plaintext
- **Reliability**: Auto-reconnect, circuit breaker, exponential backoff
- **Deployment**: Local, Docker (~44MB), AWS Fargate
- **Lifecycle**: Agent auto-starts server on startup, auto-scales down when idle
- **Cost Efficient**: Pay only for server runtime

## Technical Stack

- **Language**: Go 1.23+
- **Container**: Alpine Docker (~44MB)
- **Cloud**: AWS (ECS Fargate, Lambda, CloudWatch)
- **Security**: mTLS with private CA

## Constraints

- Cross-platform: Windows (WSL), macOS, Linux
- Server lifecycle: Ephemeral, one per agent
- Discovery: Dynamic via Lambda endpoints
- Failure semantics: Agent exits on connection failure
- Deployment order: Server/Lambda first, then agent

## Success Metrics

- Successfully tunnel HTTP/HTTPS/WebSocket traffic
- <500ms latency overhead
- 99%+ uptime (cloud deployment)
- <10 minutes setup time
- Server discovery within 30 seconds
- Cost-effective idle scaling

---

See [Architecture](architecture.md) for technical design | [Deployment](deployment.md) for setup
