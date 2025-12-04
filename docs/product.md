# Product Requirements

## Overview

Fluidity is an HTTP/HTTPS/WebSocket tunnel that bypasses restrictive corporate firewalls using mTLS authentication between a local agent and cloud-hosted server.

**Primary Use Case**: Enable applications behind restrictive firewalls to access external HTTP/HTTPS/WebSocket services through a secure, dynamically-managed tunnel infrastructure. The system is designed for on-demand usage where servers can be started/stopped based on agent needs, enabling cost-effective tunneling.

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

5. **Deployment & Orchestration**
   - Cross-platform (Windows/macOS/Linux)
   - Docker containers (~44MB)
   - AWS Fargate deployment
   - **Orchestrated deployment workflow**: Server/Lambda deployment first, then agent with discovered endpoints
   - Deploy manager for coordinating multi-component deployments

6. **Dynamic Lifecycle Management**
   - **Server Startup**: On every agent start the agent calls lifecycle Wake → Query to start a dedicated server instance and obtain its IP.
   - **Ephemeral Server**: The agent does not persist discovered server IPs to disk; servers are ephemeral and owned by the agent runtime.
   - **Connection Lifecycle**: The agent attempts an mTLS connection to the started server and exits on unrecoverable connection failure.
   - **Shutdown**: On clean exit or unrecoverable error the agent calls lifecycle Kill to terminate the server instance it started.
   - **Cost Optimization**: Server auto-scales down when idle; agent ensures termination of its server instance on shutdown.

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



## Deployment Workflow

### Intended Usage Pattern

1. **Infrastructure Deployment**
   - Deploy tunnel server and Lambda functions (wake/query/kill) to AWS first
   - Lambda functions provide lifecycle management endpoints

2. **Agent Deployment**
   - Deploy agent with Lambda endpoint configurations
   - Agent discovers server IP dynamically on startup

3. **Runtime Operation**
   - Agent checks for configured server IP
   - If no IP: triggers wake Lambda → polls query Lambda → writes IP to config
   - If IP exists but connection fails: attempts reconnection with backoff
   - **After 3 consecutive failures**: automatically re-triggers full wake/query discovery cycle
   - Server can scale down when idle; agent wakes it up as needed
   - **Self-Healing**: Agent automatically recovers from server restarts, IP changes, and infrastructure updates

### Key Design Principles

- **Separation of Concerns**: Server and agent can be deployed independently
- **Dynamic Discovery**: No hardcoded IPs - everything discovered via Lambda APIs
- **Cost Efficiency**: Infrastructure scales with actual usage
- **Resilience**: Automatic recovery from connection failures

## Success Metrics

- Successfully tunnel HTTP/HTTPS/WebSocket traffic
- <500ms average latency overhead
- 99%+ uptime for cloud deployment
- <10 minutes setup time
- **Dynamic server discovery and wake-up within 30 seconds**
- **Automatic recovery from infrastructure changes within 2 minutes**
- **Zero-touch operation after initial deployment**

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
