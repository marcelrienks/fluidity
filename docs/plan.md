# Outstanding Work

Priority items required to complete implementation.

## 1. Agent: IAM Authentication (Required)

**Current Status**: Agent connects successfully but IAM auth hangs.

**Issue**: Agent sends IAM auth request via `json.Encoder` on WebSocket connection, which is not the correct protocol.

**Required Changes**:

### Agent Side (cmd/core/agent/agent.go):
1. Fix `authenticateWithIAM()` to properly encode IAM request using WebSocket protocol, not raw JSON:
   - Use proper WebSocket frame encoding
   - Ensure `Envelope` type with `"iam_auth_request"` is marshaled correctly
   - Add timeout for IAM auth response (default: 30 seconds)

2. Implement IAM auth request structure:
   ```go
   type IAMAuthRequest struct {
       ID            string    // Unique request ID
       Timestamp     time.Time // Request timestamp
       Service       string    // "tunnel"
       Region        string    // AWS region
       AccessKeyID   string    // AWS access key
       Signature     string    // SigV4 authorization header
       SignedHeaders string    // Signed header names
   }
   ```

3. Sign requests using AWS SigV4:
   - Use `aws-sdk-go-v2/aws/signer/v4` to generate signatures
   - Sign POST request to `https://fluidity-server.<region>.amazonaws.com/auth`
   - Include timestamp in signed request

4. Handle IAM auth response:
   - Success: Proceed to ready state and log "Agent ready for receiving proxy requests"
   - Failure: Close connection and exit
   - Timeout: Exit with clear error message

### Server Side (internal/core/server/server.go):
1. Fix IAM auth request handler to properly parse WebSocket frames:
   - Decode incoming `Envelope` with type `"iam_auth_request"`
   - Extract IAM auth request payload

2. Validate IAM signature:
   - Reconstruct the signed request from components
   - Verify SigV4 signature using AWS SDK
   - Check timestamp is within 5-minute window (prevent replay attacks)
   - Verify AccessKeyID matches authorized agent user

3. Send IAM auth response back to agent:
   ```go
   type IAMAuthResponse struct {
       ID        string // Echo request ID
       Approved  bool   // true/false
       Error     string // Error message if denied
       ExpiresAt time.Time // Credential expiration time
   }
   ```

4. On success: Mark connection as authenticated and ready for proxy traffic
   - Log "IAM authentication approved" 
   - Begin accepting HTTP requests from agent

5. On failure: Close connection cleanly with error

## 2. Agent Connection State Machine

**Current Flow**:
1. Connect (TLS handshake) ✅
2. Send IAM auth request ❌ (fails - protocol issue)
3. Wait for response (hangs) ❌

**Required Flow**:
1. Connect (TLS handshake) ✅
2. Start response handler goroutine ✅
3. Send IAM auth request (properly encoded) ← **FIX NEEDED**
4. Wait for IAM auth response (with timeout) ← **IMPLEMENT**
5. On success: Mark ready and return ← **IMPLEMENT**
6. On failure: Close and return error ← **PARTIALLY DONE**

## 3. WebSocket Protocol Fixes

**Issue**: Current code treats WebSocket as raw stream with `json.Encoder`

**Required**:
1. Verify `gorilla/websocket` is used for all WebSocket operations
2. Ensure all `Envelope` messages use proper WebSocket frame encoding:
   - `conn.WriteJSON(envelope)` for sending (automatic marshaling)
   - Message handler loop uses `ReadJSON()` for receiving

3. Add message type validation to `handleResponses()`:
   - Only accept known message types: `"iam_auth_response"`, `"http_response"`, etc.
   - Reject unknown types with error

## 4. Error Handling & Logging

**Agent**:
- Add detailed error messages for:
  - IAM auth request encode failures
  - IAM auth response timeout
  - IAM auth response decode failures
  - Authentication denied errors

**Server**:
- Add detailed error messages for:
  - Invalid envelope format
  - Missing IAM auth request fields
  - SigV4 signature validation failures
  - Timestamp validation failures

## 5. Configuration

**Agent** (`agent.yaml`):
- Already has: `aws_profile`, `iam_role_arn`, AWS credential fields
- No changes needed (already configured via deploy script)

**Server**:
- Already loads AWS config for SigV4 validation
- No changes needed

## 6. Testing

1. Unit tests for IAM auth request generation
2. Unit tests for SigV4 signature validation
3. Integration test: agent connects and completes IAM auth
4. Integration test: IAM auth timeout handling
5. Integration test: Invalid signature rejection

## 7. Security Notes

- SigV4 signature includes request body, preventing tampering
- 5-minute timestamp window prevents replay attacks
- AccessKeyID must be in authorized agent list
- Consider rate limiting failed auth attempts per client

## 8. Future Enhancements (Not Required)

- Certificate-based authentication (already implemented as fallback)
- Advanced monitoring and alerting
- Performance optimization and load testing
- Production certificate issuance (CA integration)
- Multi-region deployment

---

See [Deployment](deployment.md) for current operations
