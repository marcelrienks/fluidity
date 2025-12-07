# Critical Issue: IAM Authentication Deadlock

**Status**: BLOCKING - Prevents agent-server communication  
**Severity**: CRITICAL  
**Date Identified**: 2025-12-07  
**Last Updated**: 2025-12-07T17:05:59Z

## Summary

The Fluidity agent successfully establishes a TLS connection to the server and initiates IAM authentication, but becomes deadlocked while attempting to set up the IAM authentication response channel. The connection remains open but no data is exchanged, causing the server to eventually timeout with EOF after ~105 seconds.

## Current Flow Analysis

### Agent Side (Working)
```
✓ 17:04:27 - ECS service wake initiated
✓ 17:04:38 - Server IP discovered: 54.74.210.235
✓ 17:04:38 - TLS certificates loaded
✓ 17:04:38 - Proxy server started on :8080
✓ 17:04:38 - TCP dial to 54.74.210.235:8443
✓ 17:04:39 - TLS handshake completed (TLS 1.3, cipher suite 4865)
✓ 17:04:39 - Connected to tunnel server
✓ 17:04:39 - Performing IAM authentication
✓ 17:04:39 - Created IAM auth signing request
✓ 17:04:39 - Signed request with AWS SigV4
✓ 17:04:39 - "Setting up IAM auth response channel" (log entry)
✓ 17:04:39 - "IAM auth envelope prepared, storing response channel" (log entry)
✗ STUCK - Next log entry never appears
```

### Agent Code Location (internal/core/agent/agent.go:719)
```go
// Line 717: c.logger.Debug("IAM auth envelope prepared, storing response channel")
// Line 719: c.mu.Lock()  <-- DEADLOCK OCCURS HERE
c.iamAuthResponseCh = respChan
c.iamAuthRequestID = authReqID
c.mu.Unlock()
// Line 724: c.logger.Debug("Response channel stored, checking connection state")  <-- NEVER LOGGED
```

**Expected log after line 719**:
```json
{"t":"2025-12-07T17:04:39.233Z","l":"debug","c":"tunnel-client","m":"Response channel stored, checking connection state"}
```

**Actual**: Timeout after 26 seconds (17:05:05), agent shuts down.

### Server Side (Waiting)
```
✓ 14:59:01 - Server started listening on 0.0.0.0:8443
✓ 14:59:04 - New connection accepted from agent (169.0.116.240:59118)
✓ 14:59:04 - TLS connection accepted
✓ 14:59:04 - Agent connected (TLS 1.3, cipher suite 4865)
✓ 14:59:04 - "Waiting for IAM authentication request" (log entry)
✗ 14:59:04 to 15:00:49 - No data received on connection
✗ 15:00:49 - "Failed to read IAM auth request envelope" - EOF
```

### Timeline
- **t+0s**: Agent initiates TLS connection
- **t+0.4s**: TLS handshake completes successfully
- **t+0.4s**: Agent begins IAM authentication setup
- **t+0.4s**: Agent logs "IAM auth envelope prepared" → DEADLOCK
- **t+26s**: Agent times out waiting (lifecycle timeout or signal)
- **t+105s** (server): Server times out reading envelope, closes connection

## Root Cause Analysis

### Hypothesis 1: Mutex Deadlock (Most Likely)
The `c.mu.Lock()` call at line 719 is blocking indefinitely. This suggests:

1. **Another goroutine is holding the lock and never releasing it**
   - Suspect: `handleResponses()` goroutine
   - Evidence: Multiple reads from connection in a loop with potential blocking operations

2. **Circular wait condition**
   - Main thread: Trying to acquire `c.mu` to set response channel
   - `handleResponses()`: Holding `c.mu` while... (needs investigation)

### Hypothesis 2: Connection Blocked/Closed
The connection `c.conn` might be blocked or closed before the lock is even acquired, but this would show in earlier debug logs.

### Hypothesis 3: Log Buffering
Output is being buffered and never flushed due to deadlock before flush point. (Less likely - logs appeared up to the deadlock point)

## Investigation Steps Completed

1. ✓ Added comprehensive debug logging at each step of IAM auth setup
2. ✓ Refactored mutex operations to minimize lock hold time
3. ✓ Moved envelope creation outside of lock
4. ✓ Separated lock operations into distinct phases
5. ✓ Rebuilt binary from source - issue persists
6. ✓ Verified server successfully accepts connection
7. ✓ Confirmed TLS handshake works correctly
8. ✓ Validated AWS credentials are loaded

## Code Flow to Investigate

### in `authenticateWithIAM()` - agent.go:700-763

**Problematic section**:
```go
// Line 705: Channel created outside lock (good)
respChan := make(chan *protocol.IAMAuthResponse, 1)

// Line 709-712: Envelope prepared outside lock (good)  
envelope := protocol.Envelope{
    Type:    "iam_auth_request",
    Payload: authReq,
}

// Line 717-724: DEADLOCK POINT
c.mu.Lock()
c.iamAuthResponseCh = respChan      // Store channel for handleResponses
c.iamAuthRequestID = authReqID
c.mu.Unlock()
c.logger.Debug("Response channel stored...")  // NEVER LOGGED
```

### in `handleResponses()` - agent.go:243-450

**Potential lock holders**:
- Line ~378-405: Processes all envelope types in a loop
- May call logger.mu operations (external lock contention)
- May block on channel operations while holding lock

## Symptoms

1. **Silent Deadlock**: No panic, no error message, just stops logging
2. **Reproducible**: Happens on every deployment attempt
3. **Connection State**: TLS connection remains open for 105+ seconds before timeout
4. **No Partial Writes**: Server sees zero IAM auth data on the wire
5. **Network OK**: TCP/TLS layer working perfectly

## Impact

- ❌ Agent cannot authenticate with server
- ❌ No HTTP/HTTPS tunneling possible
- ❌ Full deployment pipeline broken
- ❌ All integration testing blocked

## Next Steps for Investigation

### Priority 1: Determine Lock Holder
1. Check if `handleResponses()` is holding `c.mu` during a blocking operation
2. Examine all code paths that acquire `c.mu`
3. Look for circular dependencies or nested lock attempts
4. Add timeout to mutex acquisition with panic on timeout:
   ```go
   done := make(chan bool, 1)
   go func() {
       c.mu.Lock()
       done <- true
   }()
   select {
   case <-done:
       // OK
   case <-time.After(1 * time.Second):
       panic("DEADLOCK: Failed to acquire c.mu")
   }
   ```

### Priority 2: Decouple Response Channel
Instead of setting channel in mutex-protected struct:
- Use separate atomic channel pointer
- OR use send-only channel from goroutine context
- OR redesign to avoid shared mutable state during auth

### Priority 3: Add Goroutine Inspection
Add runtime debugging:
```go
import "runtime"

// Before attempting lock
fmt.Printf("Active goroutines: %d\n", runtime.NumGoroutine())
// Print stack traces of all goroutines
buf := make([]byte, 1<<20)
stackSize := runtime.Stack(buf, true)
fmt.Printf("%s\n", buf[:stackSize])
```

### Priority 4: Simplify IAM Auth Flow
Consider redesign:
- Authenticate immediately after TLS handshake (before other operations)
- Use simpler channel mechanism (not storing in Client struct)
- Return auth result directly instead of using goroutines

## Commit History

- `a014fca` - Attempted deadlock fix (refactored mutex usage) - **INEFFECTIVE**
- `baf9838` - Added debug logging infrastructure - **LOGS SHOW DEADLOCK**

## Server Logs (Raw)

Latest connection attempt (task: 00b32b3d560d44248e974c2ef83b680f):
```
14:59:04.340Z INFO  "Waiting for IAM authentication request"
15:00:49.827Z ERROR "Failed to read IAM auth request envelope" - EOF
```

## Files Modified

- `internal/core/agent/agent.go` - authenticateWithIAM() function and handleResponses()
- `cmd/core/agent/main.go` - Connection setup logging
- `scripts/*.sh` - Debug logging support

## Configuration

**Deployment**: Full stack (server + agent) with `--log-level debug`  
**Server**: AWS ECS Fargate (Docker, TLS 1.3)  
**Agent**: Local binary (Go 1.25.3, TLS 1.3)  
**Network**: AWS VPC (working correctly based on TLS completion)  

## References

- Agent Connect: `internal/core/agent/agent.go:102-164`
- IAM Auth: `internal/core/agent/agent.go:647-763`
- Response Handling: `internal/core/agent/agent.go:243-450`
- Server Accept: `internal/core/server/server.go:234-293`
