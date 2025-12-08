# Phase 2.1: Unit Test Expansion Plan

**Status:** Documented Plan (Ready for Implementation)  
**Date:** December 8, 2025  
**Priority:** HIGH  
**Estimated Effort:** 10-15 hours  
**Expected Coverage Gain:** 28.6% → 45-50%

---

## Executive Summary

This document outlines the comprehensive Phase 2.1 unit test expansion for Fluidity, focusing on increasing code coverage from 28.6% to 45-50% by adding unit tests for critical components that are currently only tested via integration tests.

**Key Metrics:**
- Current Coverage: 28.6%
- Target Coverage: 45-50%
- Tests to Add: 40-50 new tests
- Effort: 10-15 hours
- ROI: EXCELLENT (better regression detection, faster feedback)

---

## Phase 2.1 Objectives

1. **Agent Core Logic Unit Tests** (20-25 tests)
   - Cover connection management, authentication, request handling
   - Expected coverage gain: 0% → 40-50%
   - Impact: HIGH - Agent is critical user-facing component

2. **Server Core Logic Unit Tests** (20-25 tests)
   - Cover request forwarding, tunnel management, connection handling
   - Expected coverage gain: 0% → 40-50%
   - Impact: HIGH - Server is critical for reliability

3. **TLS Module Unit Tests** (10-15 tests)
   - Cover certificate loading, validation, expiry checking
   - Expected coverage gain: 0% → 30%
   - Impact: MEDIUM - Security-critical functionality

---

## Detailed Test Plan

### 1. Agent Core Logic Tests (20-25 tests)

#### 1.1 Connection Management (8-10 tests)

```go
TestAgentConnect_Success
  // Connect to valid server
  // Verify: Connection established, state = connected
  // Setup: TestServer running
  // Cleanup: Disconnect

TestAgentConnect_InvalidAddress
  // Connect to non-existent server
  // Verify: Error returned, state = disconnected
  // Expected: "failed to connect"

TestAgentConnect_TLSHandshakeFailure
  // Connect with invalid TLS config
  // Verify: TLS error returned
  // Setup: Valid server, invalid client cert

TestAgentDisconnect_CleanShutdown
  // Disconnect after connecting
  // Verify: Connection closed, state = disconnected
  // Verify: Goroutines cleaned up

TestAgentDisconnect_AlreadyDisconnected
  // Disconnect when already disconnected
  // Verify: No error, idempotent

TestAgentReconnect_AfterDisconnect
  // Connect → Disconnect → Connect
  // Verify: Second connect succeeds

TestAgentUpdateServerAddress
  // Update address while disconnected
  // Verify: New address used on next connect

TestAgentIsConnected
  // Test connection state query
  // Verify: Returns false initially, true after connect, false after disconnect
```

#### 1.2 Request Handling (6-8 tests)

```go
TestAgentSendRequest_Success
  // Send valid HTTP request through tunnel
  // Verify: Request forwarded, response received
  // Expected: Status 200, correct body

TestAgentSendRequest_NotConnected
  // Send request when not connected
  // Verify: Error returned "not connected"

TestAgentSendRequest_VariousHTTPMethods
  // Test GET, POST, PUT, DELETE, PATCH
  // For each method:
  //   • Send request
  //   • Verify: Correct method forwarded
  //   • Verify: Response received

TestAgentSendRequest_WithRequestBody
  // Send POST with body
  // Verify: Body forwarded correctly

TestAgentSendRequest_LargeResponse
  // Send request expecting 1MB response
  // Verify: Entire response received
  // Verify: No truncation

TestAgentSendRequest_Timeout
  // Send request to slow server
  // Verify: Request times out after deadline
  // Expected: ~30 second timeout

TestAgentSendRequest_TargetUnreachable
  // Send request to non-existent target
  // Verify: Error returned from server
```

#### 1.3 Concurrent Request Handling (3-4 tests)

```go
TestAgentConcurrentRequests_100Parallel
  // Send 100 requests simultaneously
  // Verify: All complete successfully
  // Verify: No data corruption or reordering
  // Performance: < 5 seconds total

TestAgentConcurrentRequests_MixedMethods
  // Send concurrent GET/POST/PUT/DELETE
  // Verify: All methods handled correctly
  // Verify: No interference between requests

TestAgentConcurrentConnect_RaceCondition
  // Call Connect() from 2 goroutines simultaneously
  // Verify: No race conditions, idempotent
  // Verify: Both can proceed or second gets "already connected"
```

#### 1.4 Authentication Tests (3-4 tests)

```go
TestAgentIAMAuth_Success
  // Connect with valid AWS credentials
  // Verify: Authentication succeeds
  // Verify: Can send requests after auth

TestAgentIAMAuth_InvalidCredentials
  // Connect with invalid access key
  // Verify: Authentication denied
  // Verify: Cannot send requests

TestAgentIAMAuth_Timeout
  // Server doesn't respond to auth
  // Verify: 30 second timeout
  // Verify: Connection fails cleanly

TestAgentIAMAuth_NoAWSConfig
  // Connect in test mode without AWS credentials
  // Verify: Skips IAM auth gracefully
  // Verify: Can still send requests
```

### 2. Server Core Logic Tests (20-25 tests)

#### 2.1 Connection Acceptance (6-8 tests)

```go
TestServerAcceptConnection_ValidTLS
  // Client connects with valid cert
  // Verify: Connection accepted
  // Verify: TLS handshake succeeds
  // Verify: Connection state tracked

TestServerAcceptConnection_InvalidCert
  // Client connects with invalid cert
  // Verify: TLS handshake fails
  // Verify: Connection rejected

TestServerAcceptConnection_NoCertificate
  // Client connects without client cert
  // Verify: TLS handshake fails
  // Verify: Connection rejected

TestServerAcceptConnection_MaxConnectionsReached
  // Create max connections, try one more
  // Verify: New connection rejected
  // Verify: Clear error message

TestServerAcceptConnection_ConcurrentConnections
  // 5 clients connect simultaneously
  // Verify: All accepted
  // Verify: No connection interference

TestServerAcceptConnection_ClientDisconnect
  // Client connects then immediately disconnects
  // Verify: Server handles gracefully
  // Verify: Resources cleaned up

TestServerAcceptConnection_TLSVersionMismatch
  // Client with TLS 1.2, server requires 1.3
  // Verify: Connection rejected
```

#### 2.2 Request Forwarding (6-8 tests)

```go
TestServerProcessRequest_ValidHTTP
  // Server receives HTTP request
  // Verify: Forwarded to target
  // Verify: Response returned to client

TestServerProcessRequest_InvalidURL
  // Request with invalid/malformed URL
  // Verify: Error returned
  // Expected: Clear error message

TestServerProcessRequest_TargetUnreachable
  // Target server not available
  // Verify: Connection error returned
  // Verify: Error message includes host

TestServerProcessRequest_TargetTimeout
  // Target server responds slowly
  // Verify: Request times out
  // Expected: ~30 second timeout
  // Verify: Clean error handling

TestServerProcessRequest_AllHTTPMethods
  // Test GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS
  // For each:
  //   • Forward request with method
  //   • Verify: Correct method used
  //   • Verify: Response received

TestServerProcessRequest_LargeRequestBody
  // Send POST with 10MB body
  // Verify: Entire body forwarded
  // Verify: No truncation

TestServerProcessRequest_LargeResponseBody
  // Response is 10MB
  // Verify: Entire response returned
  // Verify: No memory exhaustion

TestServerProcessRequest_VariousStatusCodes
  // Target returns 200, 201, 204, 400, 401, 403, 404, 500
  // For each:
  //   • Verify: Status code passed through
  //   • Verify: Headers preserved
  //   • Verify: Body preserved
```

#### 2.3 Tunnel Management (4-5 tests)

```go
TestServerConnectTunnel_Success
  // Open CONNECT tunnel to target
  // Verify: Tunnel established
  // Verify: Data forwarding works

TestServerConnectTunnel_TargetUnreachable
  // Open CONNECT tunnel to non-existent target
  // Verify: Connection error
  // Verify: Clean error handling

TestServerWebSocketTunnel_Success
  // Open WebSocket tunnel to target
  // Verify: Tunnel established
  // Verify: Message forwarding works

TestServerWebSocketTunnel_LargeMessage
  // Send 10MB message through WebSocket tunnel
  // Verify: Entire message transferred
  // Verify: No corruption
```

#### 2.4 Concurrent Operations (2-3 tests)

```go
TestServerConcurrentRequests_100Parallel
  // 5 agents each sending 20 requests
  // Verify: All complete successfully
  // Verify: No interference between agents
  // Verify: No data corruption

TestServerConcurrentConnections_MultipleAgents
  // 10 agents connect simultaneously
  // Verify: All connected
  // Verify: Can all send requests
```

### 3. TLS Module Tests (10-15 tests)

#### 3.1 Certificate Loading (4-5 tests)

```go
TestLoadClientTLSConfig_Success
  // Load client TLS config from files
  // Verify: Config created successfully
  // Verify: Certificates loaded
  // Verify: RootCAs configured

TestLoadClientTLSConfig_MissingCertFile
  // Certificate file doesn't exist
  // Verify: Error returned
  // Expected: "no such file"

TestLoadClientTLSConfig_MissingKeyFile
  // Key file doesn't exist
  // Verify: Error returned
  // Expected: "no such file"

TestLoadClientTLSConfig_InvalidFormat
  // Certificate file has invalid PEM format
  // Verify: Error returned
  // Expected: "parse certificate"

TestLoadServerTLSConfig_Success
  // Load server TLS config from files
  // Verify: Config created successfully
  // Verify: Certificates loaded
```

#### 3.2 Certificate Validation (3-4 tests)

```go
TestCertificateChainValidation_Valid
  // Certificate signed by valid CA
  // Verify: Chain validates successfully
  // Verify: Can use for TLS

TestCertificateChainValidation_Invalid
  // Certificate not signed by CA
  // Verify: Validation fails
  // Expected: "certificate verify failed"

TestCertificateExpiry_Valid
  // Certificate not expired
  // Verify: Is still valid
  // Verify: Not yet expired

TestCertificateExpiry_Expired
  // Certificate has expired
  // Verify: Detected as expired
```

#### 3.3 Certificate Features (2-3 tests)

```go
TestCertificateSubjectAltNames
  // Certificate has SANs for localhost, IPs
  // Verify: SANs correctly set
  // Verify: Can verify against SANs

TestCertificateKeySize
  // Certificate has RSA 4096 key
  // Verify: Key size is adequate

TestCertificateExtensions
  // Verify certificate extensions
  // Expected: serverAuth, clientAuth, basicConstraints
```

---

## Implementation Strategy

### Phase 2.1a: Foundation (Days 1-2)
1. Create helper functions in testutil.go
   - `setupTestPair()` - Start agent + server
   - `createMockTarget()` - Mock HTTP server
   - `verifyRequestMatches()` - Assertion helper

2. Implement Agent tests (12-15 tests)
   - Connection management
   - Basic request handling
   - HTTP method coverage

3. Verify all tests pass

### Phase 2.1b: Core Logic (Days 3-4)
1. Implement remaining Agent tests (10-12 tests)
   - Concurrent requests
   - Authentication
   - Edge cases

2. Implement Server tests (15-18 tests)
   - Connection acceptance
   - Request forwarding
   - Basic tunnel management

3. Verify all tests pass

### Phase 2.1c: TLS & Validation (Days 5)
1. Implement TLS module tests (10-12 tests)
   - Certificate loading
   - Validation
   - Features

2. Run full test suite
3. Verify coverage improvement to 45-50%
4. Document gaps for Phase 2.2

---

## Success Criteria

- ✅ All 40-50 new unit tests passing
- ✅ Code coverage improved to 45-50%
- ✅ No regression in existing tests
- ✅ Test execution time < 70 seconds
- ✅ All critical paths covered
- ✅ Clear, understandable test names
- ✅ Proper setup/teardown in all tests
- ✅ No test-specific code in main source files

---

## Test Execution Estimate

```
Phase 2.1 Tests:        40-50 tests
Estimated Execution:    70 seconds
Current Tests:          25+ tests (54s)
Increase:               ~10-15% execution time

Total Suite:            65-75 tests
Total Runtime:          ~70 seconds (acceptable)
```

---

## Risk Assessment

### Low Risk
- Agent connection tests (clear happy path)
- HTTP method tests (isolated)
- Status code tests (no side effects)

### Medium Risk
- Concurrent tests (timing-dependent)
- Timeout tests (may be flaky)
- TLS validation (OS-dependent)

### Mitigation
- Use short timeouts in tests (100-500ms vs production 30s)
- Retry flaky tests once before failing
- Mock slow operations instead of actually waiting

---

## Tools & Dependencies

Required:
- `testing` package (Go stdlib)
- `net`, `crypto/tls` (Go stdlib)
- `http` (Go stdlib)
- Existing testutil helpers

Optional:
- `github.com/stretchr/testify/assert` (for cleaner assertions)
- `github.com/stretchr/testify/require` (for test-skipping assertions)

---

## Next Steps After Phase 2.1

### Phase 2.2 (Optional, 8-12 hours)
- Enhance circuit breaker tests
- Add configuration edge case tests
- Improve retry logic coverage
- Expected gain: 45-50% → 55-60%

### Phase 3 (Optional, 20-30 hours)
- Add load/stress tests
- Add performance benchmarks
- Add property-based testing
- Add fuzz testing
- Expected gain: 55-60% → 70-80%

---

## Conclusion

Phase 2.1 represents a significant quality improvement for Fluidity by adding comprehensive unit test coverage for critical components. The estimated 10-15 hour effort yields excellent ROI through:

- **Better regression detection** - Catch bugs before integration testing
- **Faster feedback loop** - Unit tests run in 70 seconds vs full suite
- **Easier debugging** - Unit tests isolate failures better
- **Production confidence** - Higher coverage → higher quality
- **Maintenance ease** - Tests serve as documentation

This is a **recommended next step** for ensuring long-term code quality and maintainability.

---

**Document Status:** Ready for Implementation  
**Last Updated:** December 8, 2025  
**Next Review:** Upon Phase 2.1 Completion
