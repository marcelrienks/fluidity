# Project Plan

Development roadmap by phase.

| Phase | Status | Key Features |
|-------|--------|-----------------|
| **1** | ✅ Complete | mTLS, HTTP/HTTPS/WebSocket tunneling, Circuit breaker, Retry logic, Docker (~44MB), Cross-platform, 75+ tests (~77% coverage) |
| **2** | 🚧 In Progress | Wake/Sleep/Kill Lambdas, CloudFormation (Fargate + Lambda), CloudWatch metrics, EventBridge schedulers, Function URLs |
| **3** | 🚧 In Progress | IAM Authentication (partial), SigV4 signing (implemented), Tunnel IAM auth (basic), Enhanced security (partial), Default credential chain (partial) |
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
- **Required Change**: Make server IP optional during deployment - enable dynamic discovery
- **Implementation**:
  - Allow empty `server_ip` in config file during deployment
  - Agent startup checks for server IP; if missing, triggers wake → query → IP discovery cycle
  - Store discovered IP in config for persistence across restarts
  - Update config file automatically after IP discovery
- **Intended Deployment Workflow**:
  1. **Deploy Server & Lambdas First**: `bash scripts/deploy-fluidity.sh server`
  2. **Deploy Agent**: `bash scripts/deploy-fluidity.sh agent` (uses Lambda endpoints, no server IP needed)
  3. **Runtime Discovery**: Agent automatically discovers server IP on first startup
  4. **Persistent Config**: Future agent runs use stored IP from config
  5. **Recovery**: If connection fails, agent repeats discovery cycle

#### 3. Deployment Script Updates
- **Server Deployment**: Remove verbose CloudFormation stack output, export only essential variables
- **Agent Deployment**: 
  - No blocking wait for Fargate task - allow agent to handle IP resolution

### Benefits
- Complete deployment without manual IP extraction
- IP obtained automatically from wake function when needed
- Cleaner output and better user experience
- Graceful handling of timing (task startup delays)
- Agent can store IP for future use, eliminating repeated lookup

## Phase 3 - IAM Authentication & Enhanced Security

### Current Status: 🚧 In Progress (Partial Implementation)

**Completed Components:**
- ✅ SigV4 signing implementation for lifecycle operations
- ✅ Basic tunnel IAM authentication handshake
- ✅ Protocol updates with IAM message types
- ✅ Test mode support for development/testing
- ✅ Configuration loading fixes for credential chain

**Remaining Work:**
- 🔄 CloudFormation IAM role/policy updates
- 🔄 Server-side IAM signature validation
- 🔄 Certificate management with IAM credentials
- 🔄 Complete removal of legacy API key authentication
- 🔄 Deploy script updates for IAM configuration

### Overview
Implement comprehensive IAM authentication for all agent communications and operations, replacing API key authentication with AWS SigV4 signed requests and IAM-based tunnel authentication.

### Required Changes

#### 1. CloudFormation Infrastructure Updates
- **File:** `deployments/cloudformation/lambda.yaml`
- **Status:** 📋 Not Started
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
- **Status:** ✅ Complete (SigV4 signing implemented)
- **Replace API key authentication with SigV4 signing:**
  - Remove `APIKey` field from `Config` struct
  - Update `callWakeAPI()` and `callKillAPI()` to use AWS SDK SigV4 signer
  - Use default AWS credential chain instead of explicit credentials

#### 3. Certificate Management Updates
- **File:** `cmd/core/agent/main.go`
- **Status:** 🔄 In Progress
- **Update TLS configuration loading:**
  - Modify `secretsmanager.LoadTLSConfigFromSecretsOrFallback()` calls
  - Use default credential chain for Secrets Manager access
  - Remove explicit credential passing

#### 4. Tunnel Authentication Enhancement
- **File:** `internal/core/agent/agent.go`
- **Status:** ✅ Complete (Basic implementation)
- **Add IAM-based tunnel authentication:**
  - Implement `authenticateWithIAM()` method
  - Add IAM authentication handshake after TLS connection
  - Send SigV4 signed authentication request to server

#### 5. Server Authentication Validation
- **File:** `internal/core/server/server.go`
- **Status:** 📋 Not Started
- **Add IAM authentication validation:**
  - Implement `handleIAMAuth()` method
  - Validate SigV4 signatures from connecting agents
  - Check IAM permissions for tunnel access

#### 6. Protocol Updates
- **File:** `internal/shared/protocol/protocol.go`
- **Status:** ✅ Complete
- **Add IAM authentication message types:**
  - `IAMAuthRequest` struct for authentication requests
  - `IAMAuthResponse` struct for authentication responses

#### 7. Configuration Updates
- **File:** `internal/core/agent/config.go`
- **Status:** 🔄 In Progress
- **Update configuration structure:**
  - Remove explicit AWS credential fields
  - Add `IAMRoleARN` and `AWSRegion` fields
  - Update config loading to use default credential chain

#### 8. Deploy Script Updates
- **File:** `scripts/deploy-server.sh`
- **Status:** 📋 Not Started
- **Collect IAM role ARN from CloudFormation outputs**
- **File:** `scripts/deploy-agent.sh`
- **Status:** 📋 Not Started
- **Configure agent with IAM role ARN instead of access keys**

### Security Benefits

1. **Unified Authentication**: Single IAM credential chain for all AWS operations
2. **Enhanced Security**: IAM authentication for control plane (Lambda) and data plane (tunnel)
3. **Standard AWS Patterns**: Uses AWS SDK default credential resolution
4. **Role-Based Access**: Support for IAM roles and temporary credentials
5. **Auditability**: All authentication events logged through AWS IAM

### Implementation Order

1. ✅ Implement SigV4 signing in lifecycle client
2. ✅ Add IAM authentication to tunnel protocol
3. 🔄 Update CloudFormation template with IAM resources
4. 📋 Update server to validate IAM authentication
5. 📋 Update certificate loading to use IAM
6. 📋 Remove legacy API key authentication
7. 📋 Update deploy scripts for IAM role configuration

### Testing Plan & Current Status

#### Test Coverage Analysis
**Current State:** 100+ tests with mixed coverage quality
- ✅ **Unit Tests**: 17+ tests, 100% coverage for shared components
- ✅ **Lambda Tests**: Comprehensive AWS mocking, good coverage
- ⚠️ **Integration Tests**: Basic functionality works, IAM auth gaps
- ⚠️ **E2E Tests**: Build system works, runtime issues with IAM

#### Critical Testing Gaps (Priority 1)
**IAM Authentication Testing:**
- Missing comprehensive IAM auth success/failure tests
- No SigV4 signature validation tests
- Integration tests timeout due to IAM credential issues
- Server-side IAM validation not tested

**Recommended New Tests:**
```go
// Agent IAM authentication tests
func TestAgentIAMAuthenticationSuccess(t *testing.T)
func TestAgentIAMAuthenticationFailure(t *testing.T)
func TestAgentIAMAuthTimeout(t *testing.T)

// Server IAM validation tests
func TestServerIAMAuthValidation(t *testing.T)
func TestServerIAMAuthRejection(t *testing.T)

// Integration tests with IAM
func TestTunnelWithIAMAuth(t *testing.T)
func TestLifecycleWithIAM(t *testing.T)
```

#### Test Infrastructure Improvements (Priority 2)
- **AWS Mocking**: Implement proper AWS SDK v2 mocking for all tests
- **Test Modes**: Support IAM and non-IAM test configurations
- **Credential Management**: Mock AWS credentials for consistent testing
- **Performance Tests**: Add load testing and performance benchmarks

#### Test Quality Metrics
- **Coverage Target**: 80%+ across all components
- **Reliability Target**: <5% flaky test rate
- **Speed Targets**: Unit <30s, Integration <5min, E2E <10min
- **IAM Coverage**: 100% of authentication paths tested

#### Testing Implementation Phases

**Phase 3A (Current - Week 1-2):**
- Fix IAM authentication test gaps
- Add proper AWS mocking to lifecycle tests
- Implement server-side IAM validation tests

**Phase 3B (Week 3-4):**
- Enhance error scenario coverage
- Add performance benchmarks
- Improve test infrastructure

**Phase 3C (Week 5-6):**
- Add comprehensive integration test scenarios
- Implement proper test data management
- Add CI/CD test reporting

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

---

## Comprehensive Testing Plan

### Test Architecture Overview

The Fluidity test suite follows a three-tier approach with comprehensive coverage across all system components:

```
┌─────────────┐    ┌──────────────┐    ┌────────────────┐
│   Unit      │    │ Integration  │    │     E2E        │
│   Tests     │    │   Tests      │    │    Tests       │
│  (17+ tests)│    │  (30+ tests) │    │  (6 scenarios) │
│ <1s runtime │    │ 3-10s each   │    │ 30-120s each   │
└─────────────┘    └──────────────┘    └────────────────┘
     ↑                   ↑                   ↑
  Component         Component          Full System
 Validation     Interaction Testing   Deployment Validation
```

### Test Categories & Coverage

#### 1. Unit Tests (`internal/shared/*/` & `internal/lambdas/*/`)

**Coverage Areas:**
- Circuit breaker state transitions and failure recovery
- Retry logic with exponential backoff
- Protocol message serialization/deserialization
- Configuration loading and validation
- Logging functionality and structured output
- Lambda function business logic (Wake/Sleep/Kill)

**Current Status:** ✅ Complete (17+ tests, 100% critical path coverage)

**Test Quality:** Excellent - comprehensive edge case coverage, proper mocking

#### 2. Integration Tests (`internal/tests/*/`)

**Coverage Areas:**
- Tunnel connection lifecycle (establish, maintain, reconnect)
- HTTP/HTTPS proxy functionality through tunnel
- WebSocket tunneling with concurrent connections
- Circuit breaker integration with tunnel failures
- Large payload handling (1MB+)
- Concurrent request processing (10+ simultaneous)

**Current Status:** ⚠️ Partial (30+ tests, basic functionality works, IAM gaps)

**Issues Identified:**
- IAM authentication timeouts in test environment
- Missing comprehensive error scenario testing
- Limited performance/load testing

#### 3. End-to-End Tests (`scripts/test-*.sh`)

**Test Scenarios:**
- HTTP tunneling through firewall restrictions
- HTTPS CONNECT proxy functionality
- WebSocket bidirectional communication
- Docker container deployment validation
- Cross-platform binary compatibility

**Current Status:** ⚠️ Build system works, runtime issues with IAM

**Issues Identified:**
- Agent startup failures due to IAM credential requirements
- Port binding conflicts in test environment
- Missing IAM-compatible test configurations

#### 4. Lambda Integration Tests

**Coverage Areas:**
- ECS service lifecycle management (start/stop/scale)
- CloudWatch metrics emission and tracking
- EventBridge scheduler configuration
- IAM policy validation for AWS service access

**Current Status:** ✅ Complete (comprehensive AWS mocking)

**Test Quality:** Excellent - proper AWS SDK mocking, realistic scenarios

### Critical Testing Gaps & Remediation

#### Priority 1: IAM Authentication Testing

**Current Gaps:**
- No comprehensive IAM authentication success/failure tests
- Missing SigV4 signature validation tests
- Integration tests fail due to IAM credential timeouts
- Server-side IAM validation completely untested

**Remediation Plan:**
```go
// New test additions needed
func TestAgentIAMAuthenticationSuccess(t *testing.T)
func TestAgentIAMAuthenticationFailure(t *testing.T)
func TestAgentIAMAuthTimeout(t *testing.T)
func TestServerIAMAuthValidation(t *testing.T)
func TestServerIAMAuthRejection(t *testing.T)
func TestTunnelWithIAMAuth(t *testing.T)
```

#### Priority 2: Enhanced Error Coverage

**Current Gaps:**
- Limited circuit breaker recovery testing
- Missing concurrent load testing
- Insufficient timeout and error handling tests
- No performance regression testing

**Remediation Plan:**
```go
func TestCircuitBreakerHalfOpenRecovery(t *testing.T)
func TestCircuitBreakerConcurrentRequests(t *testing.T)
func TestTunnelThroughput(t *testing.T)
func TestWebSocketConcurrentLoad(t *testing.T)
func TestMemoryUsageUnderLoad(t *testing.T)
```

#### Priority 3: Test Infrastructure Improvements

**Current Gaps:**
- Improper AWS credential mocking in some tests
- Missing test mode configurations
- Inconsistent test data management
- No CI/CD integration testing

**Remediation Plan:**
- Implement proper AWS SDK v2 mocking across all tests
- Add IAM/non-IAM test mode support
- Create centralized test utilities for AWS mocking
- Add GitHub Actions CI/CD test workflows

### Test Quality Metrics & Targets

#### Coverage Targets
- **Unit Tests**: 100% coverage for critical paths (current: ✅)
- **Integration Tests**: 80%+ coverage (current: ~60%)
- **E2E Tests**: Full system validation (current: ~40%)
- **IAM Authentication**: 100% of auth paths tested (current: ~20%)

#### Performance Targets
- **Unit Tests**: <30 seconds total runtime
- **Integration Tests**: <5 minutes total runtime
- **E2E Tests**: <10 minutes total runtime
- **Test Reliability**: <5% flaky test rate

#### Quality Standards
- **Test Isolation**: Each test independent, no shared state
- **Realistic Scenarios**: Tests reflect production usage patterns
- **Error Coverage**: All major error paths tested
- **Documentation**: Clear test intent and assertions

### Implementation Roadmap

#### Phase 3A Testing (Weeks 1-2)
- [ ] Fix IAM authentication test gaps
- [ ] Add proper AWS mocking to lifecycle tests
- [ ] Implement server-side IAM validation tests
- [ ] Update integration tests for IAM compatibility

#### Phase 3B Testing (Weeks 3-4)
- [ ] Enhance error scenario coverage
- [ ] Add performance benchmarks
- [ ] Improve test infrastructure and utilities
- [ ] Implement comprehensive concurrent testing

#### Phase 3C Testing (Weeks 5-6)
- [ ] Add comprehensive integration test scenarios
- [ ] Implement proper test data management
- [ ] Add CI/CD test reporting and dashboards
- [ ] Performance regression testing

### Test Maintenance Strategy

#### Regular Activities
- **Weekly**: Run full test suite, monitor for flakes
- **Bi-weekly**: Review test coverage reports, identify gaps
- **Monthly**: Performance benchmark comparisons
- **Quarterly**: Test architecture review and refactoring

#### Test Evolution
- **Add Tests**: For new features and bug fixes
- **Update Tests**: When implementation changes affect behavior
- **Remove Tests**: When functionality is deprecated or consolidated
- **Refactor Tests**: Improve readability and maintainability

#### Success Criteria
- All tests pass reliably in CI/CD pipeline
- Test coverage meets or exceeds targets
- Test runtime stays within performance budgets
- New features include comprehensive test coverage
- Zero critical security paths untested

This testing plan ensures the Fluidity system maintains high quality and reliability as IAM authentication and other advanced features are implemented.
