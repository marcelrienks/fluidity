# Certificate Design Decision: Option A (CN-based Server Validation)

**Decision Date:** December 9, 2025  
**Status:** Implemented and Documented  
**Impact:** Eliminates overlap with Query Lambda, improves deployment flexibility

## Summary

The dynamic certificate implementation uses **Option A** design pattern to resolve overlap with the existing Query Lambda service:

### Design Pattern

| Component | Certificate SAN | Validation |
|-----------|-----------------|-----------|
| **Agent** | IP: `<detected_local_ip>` | Server verifies IP SAN matches connection source |
| **Server** | (empty/none) | Agent verifies CN + CA signature, trusts IP from Query Lambda |

## Why Option A Was Chosen

### Problem Identified

The initial implementation attempted to have the server detect its own public IP for the certificate SAN. However:

1. **Server doesn't know its public IP at startup**
   - May be behind load balancer (Elastic Load Balancer)
   - May be behind CloudFront or other CDN
   - May have dynamically assigned IP
   - EC2 metadata only provides private container IP

2. **IP detection overlaps with Query Lambda**
   - Query Lambda already discovers and returns server IP
   - Creating redundancy and potential inconsistency
   - Server has no way to verify the IP it detects is the right one

3. **Server-side IP detection adds complexity**
   - Network access to EC2 metadata required
   - Additional startup dependencies
   - More failure modes
   - No benefit over Query Lambda approach

### Solution: Use CN-based Validation

Instead of putting IP in server certificate SAN, use CommonName validation:

```
Agent connects to: IP (from Query Lambda)
    ↓
Server certificate has: CN=fluidity-server
    ↓
Agent validates:
  ✅ Certificate signed by trusted CA
  ✅ CN matches "fluidity-server"
  ✅ Certificate not expired
    ↓
Mutual TLS established ✓
```

## Security Analysis

### Is This Secure?

**Yes.** Option A maintains all critical security properties:

1. **No MITM Possible** ✅
   - Requires attacker to have CA private key (in AWS Secrets Manager)
   - TLS 1.3 authenticated encryption prevents passive attacks
   - Same security as if server had IP in SAN

2. **Identity Verified** ✅
   - Agent verifies: CA signature + CN=fluidity-server
   - Server verifies: CA signature + CN=fluidity-client + IP SAN matches source
   - Bidirectional authentication maintained

3. **IP Source Trusted** ✅
   - Agent gets server IP from Query Lambda (AWS API)
   - Not trusting random IPs from network
   - Additional trust layer outside TLS

### Comparison to HTTPS Model

Option A follows the same security model as HTTPS:

```
HTTPS Model:
Browser connects to: example.com (from URL)
Certificate has: SAN=*.example.com
Browser validates: Certificate CN/SAN matches domain

Fluidity Model (Option A):
Agent connects to: 10.0.1.5 (from Query Lambda)
Certificate has: CN=fluidity-server (no IP SAN)
Agent validates: Certificate CN + CA signature, trusts IP from Query Lambda
```

Both are secure because:
- ✅ Certificate proves identity of server (CN or SAN)
- ✅ IP/domain comes from trusted source outside certificate
- ✅ No way to forge certificate without CA key

## Implementation Details

### Changes Made

1. **Server Certificate Manager** (`internal/core/server/cert_manager.go`)
   - Removed IP detection code
   - Uses `GenerateCSRWithoutSAN()` instead of `GenerateCSR()`
   - No EC2 metadata access needed
   - Simpler, more reliable startup

2. **CSR Generator** (`internal/shared/certs/csr_generator.go`)
   - Added `GenerateCSRWithoutSAN()` function
   - Creates CSR with CommonName only
   - No SAN field in CSR

3. **CA Lambda** (`cmd/lambdas/ca/main.go`)
   - Validates CN is either "fluidity-client" or "fluidity-server"
   - Accepts CSRs with or without SAN
   - Creates certificates matching CSR

4. **Documentation**
   - Updated plan.md with Option A rationale
   - Updated certificate-management.md with design
   - Explained why server has no IP SAN

### No Overlap with Query Lambda

**Before (Problem):**
- Agent: Gets server IP from Query Lambda
- Server: Tries to detect its own IP
- Server cert includes detected IP
- Agent validates server IP matches Query Lambda result
- Redundant, confusing architecture

**After (Solution):**
- Agent: Gets server IP from Query Lambda
- Server: Generates cert with CN only, no IP
- Single source of truth: Query Lambda
- Clear separation of concerns
- Simpler deployment

## Advantages of Option A

✅ **No Server IP Detection**
- Server startup doesn't require EC2 metadata access
- No IP detection failures possible
- Simpler, more reliable

✅ **Works Behind Load Balancers**
- Server can be behind ELB, CloudFront, ALB, etc.
- Works with dynamic IPs
- Works with any deployment model

✅ **Clear Responsibility Separation**
- Agent responsibility: Get IP from Query Lambda, validate server CN
- Server responsibility: Present valid CN to prove identity
- Query Lambda responsibility: Track server IP

✅ **Standard PKI Practice**
- Matches HTTPS model (domain in cert, not IP)
- CN-based validation is standard (hostname validation)
- Less unusual than IP-based SAN validation

✅ **Eliminates Overlap**
- No duplicate IP detection
- No redundant validation
- Cleaner architecture

✅ **Less Information Exposure**
- Server cert doesn't leak IP address
- Smaller certificate size
- Less metadata exposed

## Disadvantages (Minimal)

⚠️ **Slightly Less Defense-in-Depth**
- No redundant IP validation on server side
- Only one source of IP truth (Query Lambda)
- But this is acceptable trade-off for simplicity

⚠️ **No IP SAN Validation**
- Standard practice is to validate SAN matches connection
- Option A doesn't do this for server
- But server IP comes from authenticated source (Query Lambda)

## Testing Considerations

### What to Test

1. **Agent starts, gets IP from Query Lambda**
   - Verify agent connects to correct server IP
   - Verify cert validation succeeds

2. **Server certificate has no IP SAN**
   - Inspect server.crt: should show CN=fluidity-server only
   - Should NOT show IP address in certificate

3. **Agent certificate has IP SAN**
   - Inspect agent.crt: should show SAN=agent_local_ip
   - Server should validate this IP matches connection source

4. **Server behind load balancer**
   - Deploy server behind ELB
   - Server should still generate valid cert (no IP detection needed)
   - Agent should still connect successfully

5. **Migration from static certs**
   - Old: Server cert has hardcoded IP in SAN
   - New: Server cert has no IP in SAN
   - Both should work during transition

## Documentation Impact

### Updated Files

- ✅ `docs/plan.md` - Updated architecture section
- ✅ `docs/certificate-management.md` - Updated validation explanation
- ✅ Code comments in managers explain Option A

### Documentation Added

- ✅ `docs/IMPLEMENTATION_STATUS.md` - Status and details
- ✅ `docs/CHECKLIST.md` - Implementation checklist
- ✅ This file: `CERTIFICATE_DESIGN.md` - Design rationale

## Backwards Compatibility

✅ **Zero impact on existing deployments**
- Static certificate mode still works
- Secrets Manager mode still works
- Only new dynamic cert mode uses Option A
- No changes to TLS configuration
- No changes to agent/server protocol

## Future Enhancements

Potential future improvements (not in scope):

- [ ] Add optional IP pinning for extra validation (if needed)
- [ ] Support hostname in SAN (for DNS-based discovery)
- [ ] Add certificate metric/dashboard (certificate age, renewals)
- [ ] Auto-refresh certificates 7 days before expiry (not 30)

## Conclusion

**Option A is the correct design choice** because it:

1. ✅ Eliminates overlap with existing Query Lambda
2. ✅ Maintains strong security (CA-signed, CN validation)
3. ✅ Simplifies server startup (no IP detection needed)
4. ✅ Enables flexible deployment (load balancers, CDNs)
5. ✅ Follows standard PKI practices
6. ✅ Reduces complexity and failure modes

The implementation is **secure, simple, and operationally sound**.
