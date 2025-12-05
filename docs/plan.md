# Plan

Outstanding work items.

## 1. CloudFormation & Deployment

- Add IAM roles/policies for agent authentication (lambda.yaml)
- Update deploy scripts to support IAM role ARNs
- Simplify CloudFormation outputs (export only essentials)

## 2. Agent: Configuration & Lifecycle

- Ensure agent always starts server via lifecycle (wake → query)
- Verify server instances are ephemeral (never persisted)
- Support TLS loading from Secrets Manager via default credential chain

## 3. Server: IAM Authentication

- Implement server-side IAM validation for tunnel connections
- Validate SigV4-signed authentication messages

## 4. Lifecycle: IAM Signing

- Finalize SigV4 signing for Wake/Kill/Query calls
- Use AWS default credential chain and support IAMRoleARN config

## 5. Deploy Scripts

- Collect IAM role ARN during deployment
- Support agent deployment without pre-specified server IP
- Remove AWS_PROFILE dependency

## 6. Testing & CI

- Add IAM authentication tests with SigV4 validation
- Add AWS SDK v2 mocking utilities
- Add integration tests for lifecycle discovery
- Add performance and concurrency tests
- Set up CI workflows for test reporting

## 7. Production Hardening

- Production certificate issuance (CA integration)
- Advanced monitoring and alerting
- Performance optimization and load testing

---

See [Deployment](deployment.md) for current operations
