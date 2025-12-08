# Running Fluidity Agent and Brave Browser

**Last Updated**: 2025-12-08T06:20:31Z

## Overview

This guide covers all methods to run the Fluidity agent and launch Brave Browser with the Fluidity proxy enabled.

---

## Running the Fluidity Agent

### Option 1: WSL Bash (Recommended)

```bash
fluidity
```

**How it works**:
- Starts agent in foreground
- Connects to tunnel server
- Listens on `127.0.0.1:8080` (WSL only) and `0.0.0.0:8080` (all interfaces)
- Press `Ctrl+C` to stop

**Full output example**:
```json
{"t":"2025-12-08T07:30:04.667Z","l":"info","c":"agent","m":"Starting server via lifecycle wake/query"}
{"t":"2025-12-08T07:30:28.676Z","l":"info","c":"agent","m":"Agent ready for receiving proxy requests","listen_addr":"http://127.0.0.1:8080"}
```

### Option 2: WSL Background (Detached)

```bash
fluidity &
```

**How it works**:
- Starts agent in background
- Returns shell control immediately
- Continue using bash while agent runs
- Find PID: `pgrep -f fluidity-agent`
- Stop: `kill <PID>`

### Option 3: WSL with Custom Config

```bash
fluidity --config /path/to/custom-config.yaml
```

**How it works**:
- Loads configuration from specified file instead of default
- Default config location: `/home/marcelr/apps/fluidity/agent.yaml`

### Option 4: WSL with Log Level

```bash
fluidity --log-level debug
```

**Valid levels**: `debug`, `info`, `warn`, `error`

### Option 5: Windows PowerShell (Runs in WSL)

```powershell
wsl fluidity
```

**How it works**:
- Launches agent from Windows command line
- Runs in WSL but controlled from PowerShell
- Close the window or press `Ctrl+C` to stop

---

## Launching Brave Browser with Fluidity Proxy

### Option 1: WSL Alias (Easiest)

```bash
brave-fluidity
```

**How it works**:
- Automatically detects WSL IP address
- Launches Windows Brave with proxy configured
- Routes all browser traffic through Fluidity agent
- Defined in: `~/.bashrc`

**Full command under the hood**:
```bash
/home/marcelr/apps/fluidity/launch-brave
```

### Option 2: WSL Script Directly

```bash
/home/marcelr/apps/fluidity/launch-brave
```

**Same as alias**, but explicit path instead of alias name.

### Option 3: Windows PowerShell (Manual)

First, get WSL IP:
```powershell
$wslIp = wsl hostname -I | ForEach-Object { $_.Trim().Split(' ')[0] }
```

Then launch Brave:
```powershell
brave.exe --proxy-server="http://$wslIp:8080"
```

**How it works**:
- Detects WSL IP from PowerShell
- Passes IP to Brave as HTTP proxy
- Works from any PowerShell window

**Or as one-liner**:
```powershell
$wslIp = wsl hostname -I | ForEach-Object { $_.Trim().Split(' ')[0] }; brave.exe --proxy-server="http://$wslIp:8080"
```

### Option 4: Windows PowerShell Script (Pre-made)

```powershell
C:\Users\marcelr\launch-brave-with-proxy.ps1
```

**How it works**:
- Script automatically gets WSL IP
- Launches Brave with proxy
- No manual IP configuration needed

**Run with:**
```powershell
.\launch-brave-with-proxy.ps1
```

Or:
```powershell
Invoke-Expression "C:\Users\marcelr\launch-brave-with-proxy.ps1"
```

### Option 5: Windows Command Line (CMD)

```cmd
wsl bash -c "brave-fluidity"
```

**How it works**:
- Runs WSL bash command from CMD
- Executes the `brave-fluidity` alias
- Launches Brave through WSL

---

## Combined: Run Agent + Browser

### Method 1: Two Terminals (Recommended)

**Terminal 1 (WSL)**:
```bash
fluidity
```

**Terminal 2 (WSL)**:
```bash
brave-fluidity
```

Keeps logs separate and easy to monitor.

### Method 2: Background Agent + Foreground Browser

**Terminal 1 (WSL)**:
```bash
fluidity &
brave-fluidity
```

Runs agent in background, launches browser in foreground.

### Method 3: All from PowerShell

**Terminal 1 (PowerShell)**:
```powershell
wsl fluidity
```

**Terminal 2 (PowerShell)**:
```powershell
$wslIp = wsl hostname -I | ForEach-Object { $_.Trim().Split(' ')[0] }; brave.exe --proxy-server="http://$wslIp:8080"
```

---

## Configuration

### Agent Configuration File

Location: `/home/marcelr/apps/fluidity/agent.yaml`

**Key options**:
```yaml
# Proxy settings
local_proxy_port: 8080           # Port agent listens on

# Server settings
server_ip: ""                    # Server IP (auto-discovered)
server_port: 8443                # Server TLS port

# AWS Lambda endpoints (lifecycle management)
wake_endpoint: "https://..."     # Wake ECS service
query_endpoint: "https://..."    # Query server IP
kill_endpoint: "https://..."     # Kill server

# Logging
log_level: "info"                # debug, info, warn, error

# AWS settings
aws_profile: "default"           # AWS profile name
aws_region: "eu-west-1"          # AWS region
```

### How to Update Configuration

**Preserve existing config (recommended for redeployment)**:
```bash
./scripts/deploy-agent.sh deploy --preserve-config
```

**Replace config entirely**:
```bash
./scripts/deploy-agent.sh deploy --server-port 8443 --aws-region eu-west-1
```

---

## Networking Details

### WSL IP Address

Get your WSL IP:
```bash
hostname -I
```

Example output: `172.23.223.98`

### Access Proxy From

**Within WSL**:
```bash
curl -x http://127.0.0.1:8080 https://example.com
```

**From Windows**:
```powershell
curl.exe -x http://172.23.223.98:8080 https://example.com
```

**From Windows (using WSL IP)**:
```powershell
$wslIp = wsl hostname -I | ForEach-Object { $_.Trim().Split(' ')[0] }
curl.exe -x http://$wslIp:8080 https://example.com
```

### Firewall Notes

- WSL firewall usually allows Windows → WSL traffic on default IPs
- If blocked, check Windows Defender Firewall settings
- May need to allow port 8080 inbound on WSL interface

---

## Troubleshooting

### Agent won't start

**Check AWS credentials**:
```bash
aws sts get-caller-identity
```

**Check configuration**:
```bash
cat /home/marcelr/apps/fluidity/agent.yaml
```

**Check logs**:
```bash
tail -100 ~/.local/share/fluidity/logs/agent.log
```

### Brave won't connect to proxy

**Verify agent is running**:
```bash
pgrep -f fluidity-agent
```

**Test proxy with curl**:
```bash
curl -v -x http://127.0.0.1:8080 https://example.com
```

**Get WSL IP and verify connectivity**:
```bash
hostname -I
# Then from Windows:
ping <WSL_IP>
```

**Check port is listening**:
```bash
netstat -tuln | grep 8080
```

### Brave launches but no proxy

**Verify WSL IP is correct**:
```bash
wsl hostname -I
```

**Manually launch with correct IP**:
```powershell
brave.exe --proxy-server="http://172.23.223.98:8080"
```

**Check if script is detecting IP correctly**:
```bash
hostname -I | awk '{print $1}'
```

---

## Quick Reference

| Task | Command |
|------|---------|
| Start agent (WSL) | `fluidity` |
| Start agent (background) | `fluidity &` |
| Start agent (PowerShell) | `wsl fluidity` |
| Launch Brave with proxy | `brave-fluidity` |
| Launch Brave (script) | `/home/marcelr/apps/fluidity/launch-brave` |
| Launch Brave (PowerShell) | `brave.exe --proxy-server="http://172.23.223.98:8080"` |
| Get WSL IP | `hostname -I` |
| Check agent running | `pgrep -f fluidity-agent` |
| Test proxy | `curl -x http://127.0.0.1:8080 https://example.com` |
| Deploy agent | `./scripts/deploy-agent.sh deploy --preserve-config` |
| View config | `cat /home/marcelr/apps/fluidity/agent.yaml` |

---

## Environment Setup

### Bash Alias

The `brave-fluidity` alias is defined in `~/.bashrc`:

```bash
alias brave-fluidity="/home/marcelr/apps/fluidity/launch-brave"
```

To add/update:
```bash
echo 'alias brave-fluidity="/home/marcelr/apps/fluidity/launch-brave"' >> ~/.bashrc
source ~/.bashrc
```

### Installation Paths

- **Agent binary**: `/home/marcelr/apps/fluidity/fluidity-agent.exe`
- **Config file**: `/home/marcelr/apps/fluidity/agent.yaml`
- **Launch script**: `/home/marcelr/apps/fluidity/launch-brave`
- **Source code**: `/home/marcelr/code/Fluidity`
- **Logs**: `~/.local/share/fluidity/logs/`

---

## Environment Variables

**Optional overrides** (set before running agent):

```bash
export FLUIDITY_SERVER_PORT=8443
export FLUIDITY_PROXY_PORT=8080
export FLUIDITY_AWS_PROFILE=default
export FLUIDITY_AWS_REGION=eu-west-1
export FLUIDITY_LOG_LEVEL=info

fluidity
```

---

## Testing Connectivity

### Test 1: Local Proxy (WSL to Agent)

```bash
curl -v -x http://127.0.0.1:8080 https://www.example.com
```

### Test 2: Remote Proxy (Windows to Agent)

```powershell
$wslIp = wsl hostname -I | ForEach-Object { $_.Trim().Split(' ')[0] }
curl.exe -v -x "http://$wslIp:8080" https://www.example.com
```

### Test 3: Modern HTTPS/HTTP2 (Google Services)

```bash
curl -x http://127.0.0.1:8080 https://gemini.google.com/
```

### Test 4: Browser Test

1. Run `brave-fluidity`
2. Navigate to https://www.whatismyip.com/
3. Verify IP shows Fluidity tunnel server IP (not your local IP)

---
