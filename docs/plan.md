# Project Plan

Development roadmap by phase.

| Phase | Status | Key Features |
|-------|--------|-----------------|
| **1** | ✅ Complete | mTLS, HTTP/HTTPS/WebSocket tunneling, Circuit breaker, Retry logic, Docker (~44MB), Cross-platform, 75+ tests (~77% coverage) |
| **2** | 🚧 In Progress | Wake/Sleep/Kill Lambdas, CloudFormation (Fargate + Lambda), CloudWatch metrics, EventBridge schedulers, Function URLs |
| **3** | 📋 Planned | IAM Authentication, SigV4 signing, Enhanced security, Default credential chain, Tunnel IAM auth |
| **4** | 📋 Planned | CI/CD (GitHub Actions), Production certificates (trusted CA), Enhanced error handling, Performance optimization, Load testing |

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

## Phase 3 - IAM Authentication & Enhanced Security

### Overview
Implement comprehensive IAM authentication for all agent communications and operations, replacing API key authentication with AWS SigV4 signed requests and IAM-based tunnel authentication.

### Required Changes

#### 1. CloudFormation Infrastructure Updates
- **File:** `deployments/cloudformation/lambda.yaml`
- **Add IAM user/role with enhanced permissions:**
  ```yaml
  Resources:
    AgentIAMRole:
      Type: AWS::IAM::Role
      Properties:
        RoleName: !Sub fluidity-agent-role-${AWS::StackName}
        AssumeRolePolicyDocument:
          Version: "2012-10-17"
          Statement:
            - Effect: Allow
              Principal:
                Service: ec2.amazonaws.com  # For EC2 instances, adjust as needed
              Action: sts:AssumeRole
        ManagedPolicyArns:
          - !Ref AgentIAMPolicy

    AgentIAMPolicy:
      Type: AWS::IAM::ManagedPolicy
      Properties:
        PolicyDocument:
          Version: "2012-10-17"
          Statement:
            - Effect: Allow
              Action: lambda:InvokeFunctionUrl
              Resource:
                - !GetAtt WakeLambda.Arn
                - !GetAtt KillLambda.Arn
            - Effect: Allow
              Action:
                - secretsmanager:GetSecretValue
                - secretsmanager:DescribeSecret
              Resource: !Sub arn:aws:secretsmanager:*:*:secret:fluidity-certificates-*

    AgentIAMUser:
      Type: AWS::IAM::User
      Properties:
        UserName: !Sub fluidity-agent-user-${AWS::StackName}

    AgentAccessKey:
      Type: AWS::IAM::AccessKey
      Properties:
        UserName: !Ref AgentIAMUser

    AgentUserPolicyAttachment:
      Type: AWS::IAM::UserPolicyAttachment
      Properties:
        UserName: !Ref AgentIAMUser
        PolicyArn: !Ref AgentIAMPolicy
  ```

#### 2. Agent Lifecycle Client Updates
- **File:** `internal/core/agent/lifecycle/lifecycle.go`
- **Replace API key authentication with SigV4 signing:**
  - Remove `APIKey` field from `Config` struct
  - Update `callWakeAPI()` and `callKillAPI()` to use AWS SDK SigV4 signer
  - Use default AWS credential chain instead of explicit credentials

#### 3. Certificate Management Updates
- **File:** `cmd/core/agent/main.go`
- **Update TLS configuration loading:**
  - Modify `secretsmanager.LoadTLSConfigFromSecretsOrFallback()` calls
  - Use default credential chain for Secrets Manager access
  - Remove explicit credential passing

#### 4. Tunnel Authentication Enhancement
- **File:** `internal/core/agent/agent.go`
- **Add IAM-based tunnel authentication:**
  - Implement `authenticateWithIAM()` method
  - Add IAM authentication handshake after TLS connection
  - Send SigV4 signed authentication request to server

#### 5. Server Authentication Validation
- **File:** `internal/core/server/server.go`
- **Add IAM authentication validation:**
  - Implement `handleIAMAuth()` method
  - Validate SigV4 signatures from connecting agents
  - Check IAM permissions for tunnel access

#### 6. Protocol Updates
- **File:** `internal/shared/protocol/protocol.go`
- **Add IAM authentication message types:**
  - `IAMAuthRequest` struct for authentication requests
  - `IAMAuthResponse` struct for authentication responses

#### 7. Configuration Updates
- **File:** `internal/core/agent/config.go`
- **Update configuration structure:**
  - Remove explicit AWS credential fields
  - Add `IAMRoleARN` and `AWSRegion` fields
  - Update config loading to use default credential chain

#### 8. Deploy Script Updates
- **File:** `scripts/deploy-server.sh`
- **Collect IAM role ARN from CloudFormation outputs**
- **File:** `scripts/deploy-agent.sh`
- **Configure agent with IAM role ARN instead of access keys**

### Security Benefits

1. **Unified Authentication**: Single IAM credential chain for all AWS operations
2. **Enhanced Security**: IAM authentication for control plane (Lambda) and data plane (tunnel)
3. **Standard AWS Patterns**: Uses AWS SDK default credential resolution
4. **Role-Based Access**: Support for IAM roles and temporary credentials
5. **Auditability**: All authentication events logged through AWS IAM

### Implementation Order

1. Update CloudFormation template with IAM resources
2. Implement SigV4 signing in lifecycle client
3. Add IAM authentication to tunnel protocol
4. Update server to validate IAM authentication
5. Update certificate loading to use IAM
6. Remove legacy API key authentication
7. Update deploy scripts for IAM role configuration

### Testing Requirements

- Test SigV4 signing with various credential sources (env vars, shared credentials, IAM roles)
- Test IAM policy permissions for Lambda and Secrets Manager access
- Test tunnel authentication with IAM validation
- Integration tests with actual AWS resources
- Test credential rotation scenarios

### Migration Strategy

1. Deploy Phase 3 alongside existing Phase 2 infrastructure
2. Update agents to use new IAM authentication
3. Gradually phase out API key authentication
4. Clean up legacy authentication code

## Phase 4 - Production Hardening (Future)

- Certificate authority integration
- Advanced monitoring and alerting
- Performance optimization
- Load testing and scaling validation
