# Fluidity Copilot Instructions

## Project Overview
Fluidity is a secure HTTP/HTTPS/WebSocket tunneling solution designed for restrictive firewall environments. It uses mTLS authentication and AWS infrastructure for cost-effective, on-demand tunneling.

## Core Architecture
- **Agent**: Local proxy (port 8080) that forwards HTTP/HTTPS requests via WebSocket tunnel
- **Server**: Cloud-based component that receives tunneled requests and performs actual HTTP calls
- **Protocol**: Custom WebSocket-based with request/response IDs, connection pooling, auto-reconnection
- **Security**: Mutual TLS with private CA certificates

## Technology Stack
- **Language**: Go 1.23+
- **Container**: Docker with Alpine (~44MB images)
- **Cloud**: AWS (ECS Fargate, Lambda, EC2, CloudWatch)
- **Key Dependencies**:
  - gorilla/websocket: WebSocket communication
  - aws-sdk-go-v2: AWS service integration
  - cobra/viper: CLI and configuration management
  - logrus: Structured logging
  - AWS Lambda Go runtime

## Project Structure
```
/cmd
  /core/server       - Main server binary
  /core/agent        - Main agent binary
  /lambdas           - AWS Lambda functions (wake, sleep, query, kill)
/internal
  /core/server       - Server implementation (config, metrics, websocket handling)
  /core/agent        - Agent implementation (config, discovery, tunnel management)
  /lambdas           - Lambda function implementations
  /shared            - Shared utilities and types
  /tests             - Integration tests
/docs               - Comprehensive documentation
/scripts            - Setup and build scripts
/certs              - mTLS certificates (git-ignored)
/configs            - Configuration files for local development
```

## Key Workflows

### Deployment Workflow
1. Deploy server & Lambda functions first
2. Deploy agent with server details
3. Use deploy manager for coordination

### Runtime Workflow
1. **Server Discovery**: Agent checks for server IP; if missing, triggers wake Lambda
2. **Dynamic IP Resolution**: Agent polls query Lambda to discover server IP
3. **Connection Management**: Agent maintains persistent tunnel; reconnects on failure
4. **Resilient Recovery**: After 3 consecutive failures, re-triggers discovery
5. **Lifecycle**: Server auto-scales down when idle; agent wakes it as needed

## Development Guidelines

### Code Style
- Go: Follow standard Go conventions (gofmt, golangci-lint)
- Comments: Only add when clarifying complex logic
- Error handling: Always check and handle errors explicitly
- Logging: Use logrus for structured logging at appropriate levels

### Configuration
- Use YAML format for configuration (viper/cobra)
- Support both file-based and environment variable overrides
- Keep sensitive data in AWS Secrets Manager, not in code

### Testing
- Write tests for business logic and edge cases
- Use table-driven tests for multiple scenarios
- Run tests locally before committing: `go test ./...`
- Integration tests in `/internal/tests`

### Security
- Never commit secrets or credentials
- Use mTLS for all communications
- Rotate certificates regularly
- Validate all input from untrusted sources
- Use AWS IAM for authentication where possible

### Logging
- Use appropriate log levels (Debug, Info, Warn, Error)
- Log connection state changes, reconnects, and errors
- Avoid logging sensitive data (certificates, credentials, tokens)
- Include context (request ID, IP, etc.) in logs

## Build & Deployment

### Local Development
```bash
./scripts/generate-certs.sh          # Generate certificates
./scripts/build-core.sh              # Build server and agent
./build/fluidity-server -config configs/server.local.yaml
./build/fluidity-agent -config configs/agent.local.yaml
```

### Docker
- Run containerized tests locally before cloud deployment
- Alpine images keep size at ~44MB

### AWS Deployment
- Deploy via CloudFormation templates in `/deployments`
- Use ECS Fargate for server, Lambda for control plane
- Configure VPC, security groups, and IAM roles appropriately

## Common Tasks

### Adding a New Feature
1. Create feature branch
2. Add/modify code in appropriate `/internal` subdirectory
3. Add tests for new functionality
4. Update relevant documentation in `/docs`
5. Test locally, then with Docker

### Debugging Connection Issues
1. Check logs with appropriate log level (increase verbosity if needed)
2. Verify mTLS certificates are valid and current
3. Test WebSocket connectivity: check server/agent logs for handshake failures
4. Verify network configuration (VPC, security groups, routing)
5. Check AWS CloudWatch metrics for server/Lambda status

### Modifying Configuration
- Server config: `configs/server.local.yaml`
- Agent config: `configs/agent.local.yaml`
- Lambda config: Environment variables via CloudFormation
- Use viper to read configs at startup

## Documentation
Reference these docs for detailed information:
- **deployment.md**: All setup options
- **architecture.md**: System design and components
- **docker.md**: Container operations
- **infrastructure.md**: CloudFormation details
- **testing.md**: Test strategy and approach
- **runbook.md**: Operations and troubleshooting

## Important Notes
- Windows users: Use WSL for bash scripts and make commands
- All timestamps in UTC
- Project uses "vibe coding" approach with AI assistance—code may evolve
- Custom license applies—check repository for terms
