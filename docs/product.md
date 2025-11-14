# Product Requirements

## Overview

Fluidity is an HTTP/HTTPS/WebSocket tunnel that bypasses restrictive corporate firewalls using mTLS authentication between a local agent and cloud-hosted server.

## Target Users

- Developers behind restrictive corporate firewalls
- Remote workers accessing blocked services
- Users needing secure outbound access

## Core Requirements

### Functional

1. **HTTP/HTTPS Tunneling**
   - Support all HTTP methods (GET, POST, PUT, DELETE, etc.)
   - Handle HTTPS via CONNECT method
   - Preserve headers and body
   - Support large payloads

2. **WebSocket Support**
   - Bidirectional communication
   - Multiple concurrent connections
   - Ping/pong keepalive

3. **Security**
   - mTLS authentication (TLS 1.3)
   - Private CA for certificate management
   - No plaintext transmission
   - Client certificate validation

4. **Reliability**
   - Auto-reconnection on connection loss
   - Circuit breaker for target failures
   - Retry logic with exponential backoff
   - Graceful shutdown

5. **Deployment**
   - Cross-platform (Windows/macOS/Linux)
   - Docker containers (~44MB)
   - AWS Fargate deployment

6. **Lifecycle Management** (Phase 2)
   - Auto-start server on agent startup
   - Auto-scale down when idle
   - Scheduled shutdown

### Non-Functional

1. **Performance**
   - Minimal latency overhead
   - Support 100+ concurrent connections
   - Resource-efficient (<100MB memory)

2. **Usability**
   - Simple configuration (YAML)
   - Easy certificate generation
   - Automated testing scripts
   - Clear documentation



## Success Metrics

- Successfully tunnel HTTP/HTTPS/WebSocket traffic
- <500ms average latency overhead
- 99%+ uptime for cloud deployment
- <10 minutes setup time

## Out of Scope

- GUI/Desktop application
- Browser extension
- Mobile clients
- Multi-tenant support
- Commercial support

## Related Documentation

- [Architecture](architecture.md) - System design
- [Plan](plan.md) - Development roadmap
- [Deployment Guide](deployment.md) - Setup
