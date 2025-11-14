# Project Plan

Development roadmap by phase.

| Phase | Status | Key Features |
|-------|--------|-----------------|
| **1** | ✅ Complete | mTLS, HTTP/HTTPS/WebSocket tunneling, Circuit breaker, Retry logic, Docker (~44MB), Cross-platform, 75+ tests (~77% coverage) |
| **2** | 🚧 In Progress | Wake/Sleep/Kill Lambdas, CloudFormation (Fargate + Lambda), CloudWatch metrics, EventBridge schedulers, Function URLs |
| **3** | 📋 Planned | CI/CD (GitHub Actions), Production certificates (trusted CA), Enhanced error handling, Performance optimization, Load testing |

## Phase 2 - Deployment & Lambda Updates

### Required Changes

#### 1. Wake Lambda Function Enhancement
- **Current State**: Wake function only returns ECS service status (running, starting, stopped)
- **Required Change**: Enhance to return the Fargate task's public IP address
- **Implementation**:
  - Query ECS service for task details
  - Extract network interface ID from task attachments
  - Call EC2 API to get public IP from network interface
  - Include `public_ip` field in `WakeResponse`
- **Agent Impact**: Agent will receive IP from wake response and store in config for future connections

#### 2. Agent Configuration Management
- **Current State**: Agent requires server IP at deployment time
- **Required Change**: Make server IP optional during deployment
- **Implementation**:
  - Allow empty `server_ip` in config file during deployment
  - Agent can call wake function to get server IP on first run
  - Store returned IP in config for future use
  - Update config file after receiving IP from wake function
- **Deployment Flow**:
  1. User runs: `sudo bash scripts/deploy-fluidity.sh deploy`
  2. Deploys server infrastructure and agent (without server IP if unavailable)
  3. Agent prompts for server IP (optional - can be skipped)
  4. Agent user calls wake function which returns IP
  5. Agent updates config with IP from wake response
  6. Future agent runs use stored IP from config

#### 3. Deployment Script Updates
- **Server Deployment**: Remove verbose CloudFormation stack output, export only essential variables
- **Agent Deployment**: 
  - Make sudo check explicit at startup
  - Skip interactive IP prompt if server IP can be obtained later
  - Pass endpoints from server deployment to agent
  - No blocking wait for Fargate task - allow agent to handle IP resolution
- **Sudo Requirements**: Both scripts check for sudo/root privilege at startup and exit with clear message if not running as root

### Benefits
- Complete deployment without manual IP extraction
- IP obtained automatically from wake function when needed
- Cleaner output and better user experience
- Graceful handling of timing (task startup delays)
- Agent can store IP for future use, eliminating repeated lookup
