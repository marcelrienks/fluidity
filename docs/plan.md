# Project Plan — Outstanding Items

Outstanding features and work items (as of 2025-12-04T06:32:59.047Z)

This document lists only the remaining work to be completed; completed items have been removed.

1. CloudFormation & Deployment
   - Update CloudFormation templates to add IAM roles/policies for agents (deployments/cloudformation/lambda.yaml)
   - Remove verbose CFN output and export essential variables only
   - Update deploy scripts to support IAM role ARNs and remove reliance on AWS_PROFILE

2. Agent: Lifecycle, Configuration & TLS
   - Agent must always start a server instance on startup via lifecycle (wake → query → connect)
   - Agent MUST NOT persist discovered server IPs to disk; server instances are ephemeral and owned by the agent runtime
   - Remove CLI options that allow persisting or forcing discovery (no --save, no --force-wake, no --server-ip override)
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
- Agent must attempt to Kill the server it started when exiting cleanly or on unrecoverable errors so external orchestrators get a clean slate.

Last updated: 2025-12-04T06:32:59.047Z
