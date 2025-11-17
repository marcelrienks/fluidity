# Testing Guide

Comprehensive testing strategy for the Fluidity secure tunnel system.

---

## Testing Strategy

Three-tier approach for complete system validation:

```
         ┌────────────┐
         │  E2E (6)   │  ← Full system, real binaries
         │  Slowest   │
         └────────────┘
       ┌───────────────┐
       │Integration(30)│  ← Component interaction
       │   Medium      │
       └───────────────┘
     ┌──────────────────────┐
     │   Unit Tests (17)    │  ← Individual functions
     │      Fastest         │
     └──────────────────────┘
```

**Total: 53+ tests** covering all system aspects  
**Coverage: ~77%** with focus on critical paths

---

## Quick Start

```bash
# All tests
go test ./internal/... -v -timeout 5m

# Unit tests (fastest, < 1s)
go test ./internal/shared/... -v

# Integration tests (~3-10s)
go test ./internal/integration/... -v -timeout 5m

# E2E tests (30-120s)
./scripts/test-local.sh
```

**Windows:**
```powershell
.\scripts\test-local.ps1
.\scripts\test-docker.ps1
```

---

## Unit Tests

**Location:** `internal/shared/*/` | **Count:** 17 | **Coverage:** 100% critical paths | **Speed:** <1s

**Coverage:** Circuit breaker state transitions, failure detection, retry backoff, exponential delays, context cancellation

### Running Unit Tests

```bash
# All unit tests
go test ./internal/shared/... -v

# Specific package
go test ./internal/shared/circuitbreaker -v
go test ./internal/shared/retry -v

# With coverage
go test ./internal/shared/... -cover

# HTML coverage report
go test ./internal/shared/... -coverprofile=coverage.out
go tool cover -html=coverage.out
```

**Expected output:**
```
--- PASS: TestCircuitBreakerStateTransitions (0.12s)
--- PASS: TestRetryExponentialBackoff (0.05s)
PASS
coverage: 100.0% of statements
```

---

## Integration Tests

**Location:** `internal/integration/` | **Count:** 30+ | **Coverage:** Full component interaction | **Speed:** ~3-10s

**Approach:** In-memory servers, real mTLS, mocked external calls, focus on component interactions

**vs E2E Tests:**
| Aspect | Integration | E2E |
|--------|-------------|-----|
| Scope | Components | Full system |
| Speed | <1s each | 10-30s |
| Dependencies | In-memory | Binaries/Docker |
| Purpose | Dev feedback | Deploy validation |
| When | Every commit | Before PR merge |

**Test Coverage:**
- Tunnel: Connection lifecycle, auto-reconnect, request forwarding, timeouts, concurrent requests (10+), large payloads (1MB)
- Proxy: HTTP/HTTPS CONNECT, error handling, concurrent clients (10+), large responses (1MB), custom headers
- Circuit Breaker: State transitions, failure recovery, cascade protection, metrics tracking
- WebSocket: Connection through tunnel, message exchange, keepalive, concurrent (5+), large messages (100KB)

### Running Integration Tests

```bash
# All integration tests
go test ./internal/integration/... -v -timeout 5m

# Specific test file
go test ./internal/integration -run TestTunnel -v
go test ./internal/integration -run TestProxy -v
go test ./internal/integration -run TestWebSocket -v

# With race detection
go test ./internal/integration/... -race -timeout 5m
```

**Expected output:**
```
--- PASS: TestTunnelConnection (0.45s)
--- PASS: TestProxyHTTPS (1.20s)
--- PASS: TestWebSocketMessages (0.89s)
PASS
```

---

## End-to-End (E2E) Tests

**Location:** `scripts/test-*.sh` | **Count:** 6 scenarios | **Coverage:** Full system | **Speed:** 30-120s

**Scenarios:** 3 protocols (HTTP/HTTPS/WebSocket) × 2 environments (Local/Docker)

### Running E2E Tests

**Local binaries:**
```bash
./scripts/test-local.sh              # All platforms (use WSL on Windows)
```

**Docker containers:**
```bash
./scripts/test-docker.sh             # All platforms (use WSL on Windows)
```

**Expected output:**
```
Starting server...
Starting agent...
Testing HTTP request... PASSED
Testing HTTPS request... PASSED
Testing WebSocket... PASSED
All tests passed!
```

---

## Lambda Control Plane Testing

### Unit Tests (Python)

**Location:** `tests/lambda/`  
**Framework:** pytest with moto (AWS mocking)

**Test scenarios:**
- Wake when task stopped
- Wake when already running (idempotent)
- Sleep when idle
- No sleep when active
- Kill immediate shutdown

**Run:**
```bash
# Install dependencies
pip install pytest moto boto3

# Run tests
pytest tests/lambda/ -v

# With coverage
pytest tests/lambda/ --cov=lambda_functions --cov-report=html
```

### Integration Tests

**Agent lifecycle:**
- Startup wakes server
- Shutdown kills server

**Server metrics:**
- Periodic CloudWatch emission
- Metrics update on activity

### E2E Tests

**Full lifecycle test:**
```bash
#!/bin/bash
# tests/e2e/lambda_lifecycle_test.sh

echo "[1/8] Deploying Lambda control plane..."
aws cloudformation deploy --template-file lambda.yaml --stack-name test

echo "[2/8] Verifying server stopped (DesiredCount=0)..."
# Check ECS service

echo "[3/8] Starting agent (triggers wake)..."
# Start agent with wake API configured

echo "[4/8] Waiting for wake and connection retry..."
sleep 30

echo "[5/8] Verifying server started (DesiredCount=1)..."
# Check ECS service

echo "[6/8] Testing HTTP request..."
curl -x http://localhost:8080 http://example.com

echo "[7/8] Stopping agent (triggers kill)..."
# Stop agent

echo "[8/8] Verifying server stopped (DesiredCount=0)..."
# Check ECS service

echo "✓ Full lifecycle test passed!"
```

**Idle detection test:**
- Send traffic to establish activity
- Wait for idle timeout (6 minutes)
- Manually invoke Sleep Lambda
- Verify server stopped

**EventBridge scheduler test:**
- Verify rules created (Sleep: every 5 min, Kill: daily 11 PM UTC)
- Manually trigger rules
- Check ECS service responds correctly

**Full details:** See **[Lambda Functions Guide](lambda.md)**

---

## Test Coverage

```bash
# Generate coverage for all packages
go test ./... -coverprofile=coverage.out

# View coverage by package
go tool cover -func=coverage.out

# HTML report
go tool cover -html=coverage.out
```

**Coverage targets:**
- Unit tests: 100% (critical paths)
- Integration tests: 80%+ (component interaction)
- E2E tests: Full system validation

---

## CI/CD Integration

### GitHub Actions Example

```yaml
name: CI

on: [push, pull_request]

jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: actions/setup-go@v4
        with:
          go-version: '1.21'
      - name: Run Unit Tests
        run: go test ./internal/shared/... -v -cover

  integration-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: actions/setup-go@v4
        with:
          go-version: '1.21'
      - name: Run Integration Tests
        run: go test ./internal/integration/... -v -timeout 5m

  e2e-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: actions/setup-go@v4
        with:
          go-version: '1.21'
      - uses: actions/setup-node@v3
        with:
          node-version: '18'
      - name: Run E2E Tests
        run: ./scripts/test-local.sh
```

### Pre-commit Hook

```bash
#!/bin/bash
# .git/hooks/pre-commit

echo "Running unit tests..."
go test ./internal/shared/... -v || exit 1

echo "Running integration tests..."
go test ./internal/integration/... -v -timeout 2m || exit 1

echo "All tests passed!"
```

```bash
chmod +x .git/hooks/pre-commit
```

---

## Troubleshooting

### Connection Refused Errors

**Cause:** Server not fully started

**Solution:**
- Increase initialization wait in E2E scripts
- Check port availability: `netstat -an | findstr :<port>`
- Verify certificates exist

### Timeout Errors

**Cause:** Tests taking longer than expected

**Solution:**
```bash
# Increase timeout
go test ./internal/integration/... -timeout 10m -v

# Run sequentially
go test ./internal/integration/... -parallel 1 -v
```

### Certificate Invalid Errors

**Cause:** Expired or improperly generated certificates

**Solution:**
```bash
# Integration tests auto-generate certificates
# For E2E tests, regenerate:
./scripts/generate-certs.sh             # All platforms (use WSL on Windows)
```

### Flaky Tests

**Cause:** Race conditions

**Solution:**
```bash
# Run with race detector
go test ./internal/integration/... -race -v

# Run test multiple times
go test ./internal/integration -run TestTunnelConnection -count 10 -v
```

### E2E Tests Hang on Cleanup

**Cause:** Processes not terminating

**Solution:**
```bash
# Check for orphaned processes
ps aux | grep fluidity

# Kill manually (Linux/macOS)
killall fluidity-server fluidity-agent

# Kill manually (WSL/Linux on Windows)
pkill -f fluidity
```

### Docker Tests Fail to Build

**Cause:** Docker daemon not running or insufficient resources

**Solution:**
- Start Docker Desktop
- Check: `docker ps`
- Increase memory allocation (Settings → Resources)
- Clean up: `docker system prune -a`

---

## Debug Mode

```bash
# Verbose output
go test ./internal/shared/... -v -test.v

# Check E2E logs
cat logs/server.log
cat logs/agent.log
```

---

## Performance Profiling

```bash
# CPU profiling
go test ./internal/integration/... -cpuprofile=cpu.out -v
go tool pprof cpu.out

# Memory profiling
go test ./internal/integration/... -memprofile=mem.out -v
go tool pprof mem.out

# Trace execution
go test ./internal/integration/... -trace=trace.out -v
go tool trace trace.out
```

---

## Best Practices

### Writing New Tests

1. **Descriptive names:** `TestFeature_Scenario_ExpectedOutcome`
2. **Use t.Parallel()** for independent tests
3. **Use t.Helper()** in utility functions
4. **Clean up resources:** `defer` or `t.Cleanup()`
5. **Clear assertions:** Include descriptive error messages
6. **Test error paths:** Don't just test happy path
7. **Table-driven tests:** For multiple scenarios

### Example Structure

```go
func TestMyFeature(t *testing.T) {
    t.Parallel()

    // Arrange
    certs := GenerateTestCerts(t)
    server := StartTestServer(t, certs)
    defer server.Stop()

    // Act
    result, err := server.DoSomething()

    // Assert
    AssertNoError(t, err, "operation should succeed")
    AssertEqual(t, expected, result)
}
```

### Maintenance

- Run tests before committing: `go test ./...`
- Keep tests fast (unit < 1s, integration < 10s)
- Update tests when changing functionality
- Monitor coverage: `go test ./... -cover`

---

## Summary

**Fluidity testing ensures:**
- ✅ Individual components work correctly (unit)
- ✅ Components interact properly (integration)
- ✅ Complete system functions as expected (E2E)
- ✅ Changes validated quickly and confidently
- ✅ Production deployments are reliable

**Run all tests regularly to maintain code quality!**

---

## Related Documentation

- **[Architecture](architecture.md)** - System design
- **[Lambda Functions](lambda.md)** - Control plane testing
- **[Deployment Guide](deployment.md)** - Deployment options
