# Running Fluidity Agent and Browser

Quick reference for launching the Fluidity agent and browser with proxy configuration.

## Quick Start

**One-command launch** (recommended):
```bash
launch-fluidity     # WSL
```
```powershell
launch-fluidity     # PowerShell
```

**Two-terminal approach** (for monitoring):
```bash
fluidity            # Terminal 1: Start agent
brave-fluidity      # Terminal 2: Launch browser with proxy
```

---

## Running the Agent

| Scenario | Command |
|----------|---------|
| Deployed (easiest) | `fluidity` |
| From source | `./build/fluidity-agent -config configs/agent.local.yaml` |
| Background | `fluidity &` |
| Custom config | `fluidity --config /path/to/config.yaml` |
| Debug logging | `fluidity --log-level debug` |
| From PowerShell | `wsl fluidity` |

---

## Launching Browser

**Prerequisites**: Agent must be running first.

| Scenario | Command |
|----------|---------|
| Using alias (easiest) | `brave-fluidity` |
| Get WSL IP first | `hostname -I` (then use IP below) |
| Manual from WSL | `brave.exe --proxy-server="http://127.0.0.1:8080"` |
| Manual from Windows | `brave.exe --proxy-server="http://<WSL_IP>:8080"` |
| PowerShell auto-detect | `$ip = wsl hostname -I \| % { $_.Trim().Split(' ')[0] }; brave.exe --proxy-server="http://$ip:8080"` |

**WSL ↔ Windows IP mapping**: WSL has different IP than Windows. Use `hostname -I` from WSL to get the address Windows needs.

---

## Configuration

**Agent config**: `/home/marcelr/apps/fluidity/agent.yaml`

Key settings:
```yaml
local_proxy_port: 8080           # Port agent listens on
server_ip: ""                    # Auto-discovered
server_port: 8443
log_level: "info"
```

Update with: `./scripts/deploy-agent.sh deploy --preserve-config`

---

## Testing

```bash
# Test from WSL
curl -x http://127.0.0.1:8080 https://example.com

# Test from Windows
curl.exe -x http://<WSL_IP>:8080 https://example.com
```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Agent won't start | Check AWS credentials: `aws sts get-caller-identity` |
| Agent not listening | Check if running: `pgrep -f fluidity-agent` |
| Browser can't reach proxy | Verify WSL IP: `hostname -I` |
| Proxy not working | Test with curl first, verify IP/port match |

---

## Setup (One-Time)

Add aliases to WSL `~/.bashrc`:
```bash
alias fluidity="/home/marcelr/apps/fluidity/fluidity-agent -config /home/marcelr/apps/fluidity/agent.yaml"
alias launch-fluidity="/home/marcelr/apps/fluidity/launch-fluidity.sh"
alias brave-fluidity="/home/marcelr/apps/fluidity/launch-brave"
```

Add functions to PowerShell `$PROFILE`:
```powershell
function launch-fluidity {
    powershell -ExecutionPolicy Bypass -File "C:\Users\marcelr\launch-fluidity.ps1"
}
function fluidity { wsl fluidity }
```

See [Deployment](deployment.md) for full setup | [Development](development.md) for code setup
