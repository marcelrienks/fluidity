Agent Startup Behavior

Summary

This document describes the Fluidity agent startup sequence for the one-server-per-agent model.

Startup sequence

1. Read configuration
   - On startup the agent reads the configuration file (agent.yaml or the path supplied with --config). The config provides TLS assets, lifecycle endpoints, IAM role/region and local proxy port.

2. Always start server via lifecycle
   - On every agent start the agent will use lifecycle management to call the Wake API and then Query to obtain the server IP for this agent.
   - The agent does not read or persist the server IP to disk; the server instance is ephemeral and owned by the agent runtime.

3. Connect to the server
   - Once an IP is received from lifecycle, the agent uses it to connect the tunnel and start proxying traffic.
   - If the connection fails, the agent will attempt to start a new server instance via lifecycle and retry connecting.

4. Shutdown behavior
   - Anytime the agent exits cleanly or encounters an unrecoverable error it will attempt to call the lifecycle Kill API to terminate the server instance it started.

CLI flags (relevant)

- --config, -c <path>   : Path to agent configuration file (defaults to agent.yaml in executable directory)
- --server-port <port>  : Tunnel server port used when connecting to the started server
- --proxy-port <port>   : Local proxy port
- --log-level <level>   : Log level (debug, info, warn, error)

Notes

- The agent never persists discovered server IPs; server lifecycle is managed dynamically and scoped to the agent process lifetime.
- If using AWS Secrets Manager for TLS assets, the agent will load certs from the secret before connecting.

Last updated: 2025-12-04T06:32:59.047Z
