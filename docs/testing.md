# Testing Guide# Testing Guide



Three-tier testing strategy: Unit, Integration, and E2E tests.Comprehensive testing strategy for the Fluidity secure tunnel system.



## Quick Start---



```bash## Testing Strategy

# All tests

go test ./internal/... -vThree-tier approach for complete system validation:

./scripts/test-local.sh              # Linux/macOS

.\scripts\test-local.ps1             # Windows```

```         ┌────────────┐

         │  E2E (6)   │  ← Full system, real binaries

## Test Layers         │  Slowest   │

         └────────────┘

```       ┌───────────────┐

E2E Tests (6)          ← Full system, real binaries       │Integration(30)│  ← Component interaction

├── HTTP/HTTPS/WebSocket       │   Medium      │

├── Local + Docker environments       └───────────────┘

└── ~30-120s execution   ┌──────────────────────┐

   │   Unit Tests (17)    │  ← Individual functions

Integration Tests (30+) ← Component interaction   │      Fastest         │

├── In-memory servers   └──────────────────────┘

├── Real TLS```

└── ~3-10s execution

**Total: 53+ tests** covering all system aspects

Unit Tests (17)        ← Individual functions

├── Circuit breaker---

├── Retry logic

└── <1s execution## Quick Start

```

```bash

**Total: 53+ tests, ~77% coverage**# All tests

go test ./internal/... -v -timeout 5m

## Unit Tests./scripts/test-local.sh

./scripts/test-docker.sh

**Location:** `internal/shared/*/`  ```

**Coverage:** Circuit breaker, retry logic

```powershell

```bash# Windows

# Rungo test ./internal/... -v -timeout 5m

go test ./internal/shared/... -v.\scripts\test-local.ps1

.\scripts\test-docker.ps1

# With coverage```

go test ./internal/shared/... -cover -coverprofile=coverage.out

go tool cover -html=coverage.out**Or run specific types:**

```

```bash

## Integration Tests# Unit tests (fastest, < 1s)

go test ./internal/shared/... -v

**Location:** `internal/integration/`  

**Tests:** Tunnel, proxy, WebSocket, circuit breaker# Integration tests (~3-10s)

go test ./internal/integration/... -v -timeout 5m

```bash

# Run all# E2E tests (30-120s)

go test ./internal/integration/... -v -timeout 5m./scripts/test-local.sh

```

# Specific test

go test ./internal/integration -run TestTunnelConnection -v---



# With race detection## Unit Tests

go test ./internal/integration/... -race -v

```**Location:** `internal/shared/*/`  

**Count:** 17 tests  

**Structure:****Coverage:** 100% for circuit breaker and retry logic  

- `testutil.go` - Shared test utilities**Execution:** < 1 second

- `tunnel_test.go` - Tunnel connection tests

- `http_proxy_test.go` - Proxy functionality### What They Test

- `websocket_test.go` - WebSocket support

- `circuitbreaker_integration_test.go` - Circuit breaker**Circuit Breaker:**

- State transitions (Closed → Open → Half-Open → Closed)

## E2E Tests- Failure threshold detection

- Automatic recovery

**Location:** `scripts/test-*.sh`, `scripts/test-*.ps1`- Concurrent request handling



**Local binaries:****Retry Mechanism:**

```bash- Successful operations

./scripts/test-local.sh- Transient failure retry

.\scripts\test-local.ps1             # Windows- Maximum attempts limit

```- Exponential backoff timing

- Context cancellation

**Docker containers:**

```bash### Running Unit Tests

./scripts/test-docker.sh

.\scripts\test-docker.ps1            # Windows```bash

```# All unit tests

go test ./internal/shared/... -v

**Tests:**

- HTTP tunneling# Specific package

- HTTPS CONNECTgo test ./internal/shared/circuitbreaker -v

- WebSocketgo test ./internal/shared/retry -v



## Coverage# With coverage

go test ./internal/shared/... -cover

```bash

# All packages# HTML coverage report

go test ./... -coverprofile=coverage.outgo test ./internal/shared/... -coverprofile=coverage.out

go tool cover -html=coverage.out

# View by package```

go tool cover -func=coverage.out

**Expected output:**

# HTML report```

go tool cover -html=coverage.out--- PASS: TestCircuitBreakerStateTransitions (0.12s)

```--- PASS: TestRetryExponentialBackoff (0.05s)

PASS

**Targets:**coverage: 100.0% of statements

- Unit: 100% (critical paths)```

- Integration: 80%+

- E2E: Full system validation---



## CI/CD Example## Integration Tests



```yaml**Location:** `internal/integration/`  

# .github/workflows/test.yml**Count:** 30+ tests  

name: Tests**Coverage:** Full component interaction  

**Execution:** ~3-10 seconds (parallel)

on: [push, pull_request]

### Test Organization

jobs:

  test:```

    runs-on: ubuntu-latestinternal/integration/

    steps:├── README.md                          # Test documentation

      - uses: actions/checkout@v3├── testutil.go                        # Shared test utilities and helpers

      - uses: actions/setup-go@v4├── tunnel_test.go                     # Agent <-> Server tunnel integration

        with:├── http_proxy_test.go                 # HTTP proxy functionality

          go-version: '1.21'├── connect_test.go                    # HTTPS CONNECT tunneling

      ├── websocket_test.go                  # WebSocket tunneling

      - name: Unit Tests└── circuitbreaker_integration_test.go # Circuit breaker integration

        run: go test ./internal/shared/... -v -cover```

      

      - name: Integration Tests### Integration Test Approach

        run: go test ./internal/integration/... -v -timeout 5m

      1. **Start in-memory servers**: No external processes needed

      - name: E2E Tests2. **Use real TLS certificates**: Tests with actual mTLS

        run: ./scripts/test-local.sh3. **Mock external HTTP calls**: Fast and reliable

```4. **Test component interactions**: Focus on integration points

5. **Clean up resources**: Proper teardown in defer statements

## Troubleshooting

### Key Differences from E2E Tests

**Connection refused:**

- Increase wait time in E2E scripts| Aspect | Integration Tests | E2E Tests (scripts) |

- Check port availability|--------|------------------|---------------------|

| **Scope** | Component interactions | Full system deployment |

**Timeout:**| **Speed** | Fast (< 1s per test) | Slow (10-30s) |

```bash| **Dependencies** | In-memory only | Requires binaries/Docker |

go test ./internal/integration/... -timeout 10m -v| **Network** | Mocked/local only | Real external services |

```| **Purpose** | Development feedback | Deployment validation |

| **When to run** | Every commit | Before deploy/PR merge |

**Certificate errors:**

```bash### What They Test

# Integration tests auto-generate

# For E2E, regenerate:**Tunnel Tests:**

./scripts/manage-certs.sh- Connection establishment/disconnection

```- Automatic reconnection after failure

- HTTP request forwarding

**Flaky tests:**- Request timeout handling

```bash- Concurrent requests (10 simultaneous)

# Run with race detector- Multiple HTTP methods (GET, POST, PUT, DELETE, PATCH)

go test ./internal/integration/... -race -v- Large payload transfer (1MB)

- Disconnect during active request

# Run multiple times

go test ./internal/integration -run TestName -count 10 -v**Proxy Tests:**

```- HTTP proxy functionality

- HTTPS CONNECT tunneling

## Performance Profiling- Invalid target error handling

- Concurrent client connections (10 simultaneous)

```bash- Large response handling (1MB)

# CPU profiling- Custom header forwarding

go test ./internal/integration/... -cpuprofile=cpu.out -v

go tool pprof cpu.out**Circuit Breaker Integration:**

- Circuit trips after consecutive failures

# Memory profiling- Automatic recovery after timeout

go test ./internal/integration/... -memprofile=mem.out -v- Protection from cascading failures

go tool pprof mem.out- Metrics collection and tracking

```- Complete state transition verification



## Related Documentation**WebSocket Tests:**

- WebSocket connection through tunnel

- [Development Guide](development.md) - Local setup- Multiple message exchange (text/binary)

- [Architecture](architecture.md) - System design- Ping/pong keepalive

- Concurrent connections (5 simultaneous)
- Large message handling (100KB)
- Proper connection cleanup

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

**Location:** `scripts/test-*.sh`  
**Count:** 6 scenarios (3 protocols × 2 environments)  
**Coverage:** Full system validation  
**Execution:** 30-120 seconds

### Test Scenarios

**Local Environment:**
- HTTP tunneling
- HTTPS CONNECT tunneling
- WebSocket tunneling

**Docker Environment:**
- HTTP tunneling
- HTTPS CONNECT tunneling
- WebSocket tunneling

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
./scripts/manage-certs.sh              # All platforms (use WSL on Windows)
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
