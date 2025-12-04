Agent Startup Behavior

Summary

This document describes the Fluidity agent startup sequence and the lifecycle wake/query use case.

Startup sequence

1. Read configuration
   - On startup the agent reads the configuration file (agent.yaml or the path supplied with --config).

2. If Server IP is specified in the config (or via --server-ip)
   - Agent attempts to connect to the server using the configured IP.
   - If the connection attempt fails, the agent logs an error and exits.

3. If Server IP is not specified
   - The agent will use lifecycle management to call the Wake API and then Query for the server IP.
   - Once an IP is received, the agent updates the effective configuration (and will persist it if --save is used) before attempting to connect.
   - If the connection attempt fails after discovery, the agent logs an error and exits.

4. Force wake behavior (--force-wake)
   - When supplied, the agent will call lifecycle Wake and Query even if a Server IP is already present in the configuration.
   - The discovered IP will overwrite the configured IP (and may be saved back to disk if --save is used).
   - If the connection attempt fails after forcing wake and query, the agent logs an error and exits.

CLI flags (relevant)

- --config, -c <path>   : Path to agent configuration file (defaults to agent.yaml in executable directory)
- --server-ip <ip>      : Explicit server IP to use (skips discovery unless --force-wake is used)
- --save                : Persist discovered/merged configuration back to agent.yaml (in the binary directory)
- --force-wake          : Force lifecycle wake & query regardless of an existing server IP (overwrites the IP)

Notes

- The agent logs lifecycle and connection events to aid debugging. Failure to connect is treated as fatal and will cause the agent to quit so the caller can take corrective action or retry externally.
- If using AWS Secrets Manager for TLS assets, the agent will load certs from the secret before connecting.

Last updated: 2025-12-04T06:12:56.889Z
