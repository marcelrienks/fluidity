# Project Plan — Outstanding Items

Outstanding features and work items (as of 2025-12-04T06:19:24.228Z)

This document lists only the remaining work to be completed; completed items have been removed.

1. CloudFormation & Deployment
   - Update CloudFormation templates to add IAM roles/policies for agents (deployments/cloudformation/lambda.yaml)
   - Remove verbose CFN output and export essential variables only
   - Update deploy scripts to support IAM role ARNs and remove reliance on AWS_PROFILE

2. Agent: Lifecycle, Configuration & TLS
   - Agent should support dynamic discovery when server IP is absent (wake → query → update config)
   - Persist discovered server IP to agent config when --save is used
   - Implement --force-wake CLI flag to force lifecycle wake/query and overwrite configured IP
   - Update TLS loading to support Secrets Manager via default credential chain and remove explicit credentials
   - Add CLI documentation and behavior guarantees around fatal connect-on-failure semantics

3. Server & IAM Authentication
   - Implement server-side IAM authentication validation for tunnel connections (internal/core/server/server.go)
   - Ensure tunnel protocol validates SigV4-signed agent authentication messages

4. Lifecycle Client & IAM Signing
   - Finalize SigV4 signing usage for lifecycle Wake/Kill/Query calls (internal/core/agent/lifecycle)
   - Use default AWS credential chain and support IAMRoleARN/AWSRegion config fields

5. Deploy Scripts & UX
   - scripts/deploy-server.sh: collect IAM role ARN and update deployment workflow
   - scripts/deploy-agent.sh: support agent deployment without pre-specified server IP and remove AWS_PROFILE dependency
   - Consider adding spinners/progress indicators for long-running deploy/agent operations (UX improvement)

6. Testing & CI
   - Fix IAM authentication test gaps and add SigV4 validation tests
   - Add AWS SDK v2 mocking utilities and test modes for IAM/non-IAM
   - Implement server-side IAM validation tests and integration tests for lifecycle discovery
   - Add performance, concurrency, and circuit-breaker recovery tests
   - Add CI workflows to run and report integration/E2E tests and test coverage

7. Production Hardening / Future Work
   - Certificate Authority integration and production certificate issuance
   - Advanced monitoring, alerting and metrics dashboards
   - Performance optimization and load-testing validation

Notes
- Failure to connect after either using configured IP or after discovery is treated as fatal: agent should log an error and exit so external orchestrators can retry.
- The --force-wake flag must be documented and implemented to overwrite any configured IP and perform lifecycle discovery unconditionally.

Last updated: 2025-12-04T06:19:24.228Z
