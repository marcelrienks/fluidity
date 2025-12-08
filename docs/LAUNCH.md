# Running Fluidity Agent and Brave Browser

**Last Updated**: 2025-12-08T07:41:54Z

## Overview

This guide covers all methods to run the Fluidity agent and launch Brave Browser with proxy configured. Methods range from manual setup (understanding networking and IP mapping) to automated scripts that handle everything.

---

## Running the Fluidity Agent

### Option 1: Manual Launch from Build Directory (WSL)

For understanding the full setup or when agent isn't in PATH:

```bash
cd /mnt/c/Users/marcelr/code/Fluidity
./build/fluidity-agent -config configs/agent.local.yaml
```

**How it works**:
- Runs agent binary directly from repository
- Uses local config file from `configs/`
- Listens on `0.0.0.0:8080` (all interfaces on WSL)
- Press `Ctrl+C` to stop

**Full output example**:
```json
{"t":"2025-12-08T07:30:04.667Z","l":"info","c":"agent","m":"Starting server via lifecycle wake/query"}
{"t":"2025-12-08T07:30:28.676Z","l":"info","c":"agent","m":"Agent ready for receiving proxy requests","listen_addr":"http://0.0.0.0:8080"}
```

### Option 2: Manual Launch from Deploy Directory (WSL)

If agent is deployed to `/home/marcelr/apps/fluidity/`:

```bash
cd /home/marcelr/apps/fluidity
./fluidity-agent -config agent.yaml
```

Or using symlink/alias:

```bash
fluidity
```

**How it works**:
- Runs deployed agent binary
- Uses deployed config file
- Same behavior as Option 1 but with deployed binaries

### Option 3: WSL Background (Detached)

```bash
fluidity &
```

**How it works**:
- Starts agent in background
- Returns shell control immediately
- Continue using bash while agent runs
- Find PID: `pgrep -f fluidity-agent`
- Stop: `kill <PID>`

### Option 4: WSL with Custom Config

```bash
fluidity --config /path/to/custom-config.yaml
```

**How it works**:
- Loads configuration from specified file instead of default
- Default config location: `/home/marcelr/apps/fluidity/agent.yaml`

### Option 5: WSL with Log Level

```bash
fluidity --log-level debug
```

**Valid levels**: `debug`, `info`, `warn`, `error`

### Option 6: Windows PowerShell (Runs in WSL)

```powershell
wsl fluidity
```

**How it works**:
- Launches agent from Windows command line
- Runs in WSL but controlled from PowerShell
- Close the window or press `Ctrl+C` to stop

---

## Launching Brave Browser with Fluidity Proxy

### Understanding IP Mapping (Windows ↔ WSL)

**Critical for manual configuration:**

- **From WSL**: Agent listens on `127.0.0.1:8080` (localhost)
- **From Windows**: WSL has a separate IP (e.g., `172.23.223.98:8080`)

Get WSL IP:
```bash
hostname -I        # In WSL
wsl hostname -I    # From PowerShell
```

### Option 1: Manual Browser Configuration

**Start agent first** (in WSL or PowerShell):
```bash
fluidity
```

**Get WSL IP** (in WSL):
```bash
hostname -I
# Output: 172.23.223.98 (example)
```

**Launch Brave manually from Windows**, pointing to WSL IP:
```cmd
brave.exe --proxy-server="http://172.23.223.98:8080"
```

**Or from PowerShell**:
```powershell
brave.exe --proxy-server="http://172.23.223.98:8080"
```

**How it works**:
- Manual approach for understanding the full flow
- You control the IP discovery and browser launch
- Useful for debugging or custom setups

### Option 2: WSL Alias (Easiest)

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

### Option 3: WSL Script Directly

```bash
/home/marcelr/apps/fluidity/launch-brave
```

**Same as alias**, but explicit path instead of alias name.

### Option 4: PowerShell Script (Recommended for Windows)

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\marcelr\launch-fluidity.ps1"
```

Or if in Windows profile:
```powershell
launch-fluidity
```

**How it works**:
- PowerShell script detects WSL IP automatically
- Launches agent in WSL background
- Waits 5 seconds for agent to start
- Launches Brave with correct proxy configuration
- All from one command

**Script features**:
- Auto-detects WSL IP (Windows/WSL mapping)
- Starts agent in background via WSL
- Validates agent is running before launching Brave
- Shows WSL IP for manual verification

### Option 5: WSL Script (Integrated)

```bash
/home/marcelr/apps/fluidity/launch-fluidity.sh
```

Or with alias:
```bash
launch-fluidity
```

**How it works**:
- Bash script for WSL users
- Detects WSL IP
- Launches agent in background
- Launches Brave with proxy
- All from one command

### Option 6: Windows PowerShell (Manual)

If agent is already running, launch Brave manually:

```powershell
$wslIp = wsl hostname -I | ForEach-Object { $_.Trim().Split(' ')[0] }
brave.exe --proxy-server="http://$wslIp:8080"
```

**Or as one-liner**:
```powershell
$wslIp = wsl hostname -I | ForEach-Object { $_.Trim().Split(' ')[0] }; brave.exe --proxy-server="http://$wslIp:8080"
```

**How it works**:
- Detects WSL IP from PowerShell
- Passes IP to Brave as HTTP proxy
- Works from any PowerShell window
- Useful when agent already running elsewhere

### Option 7: Windows Command Line (CMD)

```cmd
wsl bash -c "brave-fluidity"
```

**How it works**:
- Runs WSL bash command from CMD
- Executes the `brave-fluidity` alias
- Launches Brave through WSL

---

---

## Combined: Run Agent + Browser (One Command)

### Method 1: WSL One-Command Launch

```bash
launch-fluidity
```

**How it works**:
- Bash alias that runs `/home/marcelr/apps/fluidity/launch-fluidity.sh`
- Automatically:
  - Detects WSL IP
  - Starts agent in background
  - Waits for agent to be ready
  - Launches Brave with correct proxy
- All from single command

### Method 2: PowerShell One-Command Launch

```powershell
launch-fluidity
```

Or if not aliased:
```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\marcelr\launch-fluidity.ps1"
```

**How it works**:
- PowerShell script that:
  - Detects WSL IP
  - Starts agent in WSL background
  - Waits 5 seconds for agent startup
  - Validates agent is listening
  - Launches Brave with proxy
- Single command from Windows

### Method 3: Two Terminals (Best for Monitoring)

**Terminal 1 (WSL)**:
```bash
fluidity
```

**Terminal 2 (WSL)**:
```bash
brave-fluidity
```

**Advantages**:
- See agent logs in real-time (Terminal 1)
- See browser activity (Terminal 2)
- Easy to diagnose issues
- Can restart either independently

### Method 4: Background Agent + Foreground Browser

**Terminal 1 (WSL)**:
```bash
fluidity &
sleep 2
brave-fluidity
```

**How it works**:
- Starts agent in background
- Waits 2 seconds for startup
- Launches Brave with proxy
- All from one terminal (but separate processes)

### Method 5: All from PowerShell (Two Terminals)

**Terminal 1 (PowerShell)**:
```powershell
wsl fluidity
```

**Terminal 2 (PowerShell)**:
```powershell
$wslIp = wsl hostname -I | ForEach-Object { $_.Trim().Split(' ')[0] }; brave.exe --proxy-server="http://$wslIp:8080"
```

**How it works**:
- Launch agent from Windows command line
- Get WSL IP and launch Brave
- Useful when you need to control both from PowerShell

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
| **Start agent (manual, from build)** | `cd /mnt/c/Users/marcelr/code/Fluidity && ./build/fluidity-agent -config configs/agent.local.yaml` |
| **Start agent (deployed, WSL)** | `fluidity` |
| **Start agent (background)** | `fluidity &` |
| **Start agent (PowerShell)** | `wsl fluidity` |
| **Launch agent + browser (one command, WSL)** | `launch-fluidity` |
| **Launch agent + browser (one command, PowerShell)** | `launch-fluidity` |
| **Launch browser with proxy (agent already running)** | `brave-fluidity` |
| **Get WSL IP** | `hostname -I` |
| **Check agent running** | `pgrep -f fluidity-agent` |
| **Test proxy (from WSL)** | `curl -x http://127.0.0.1:8080 https://example.com` |
| **Test proxy (from Windows)** | `curl.exe -x http://172.23.223.98:8080 https://example.com` (replace with actual WSL IP) |

---

## Aliases & Scripts Setup

### WSL Aliases (in ~/.bashrc)

Add these to your `~/.bashrc`:

```bash
# Fluidity aliases
alias fluidity="/home/marcelr/apps/fluidity/fluidity-agent -config /home/marcelr/apps/fluidity/agent.yaml"
alias launch-fluidity="/home/marcelr/apps/fluidity/launch-fluidity.sh"
alias brave-fluidity="/home/marcelr/apps/fluidity/launch-brave"
```

To apply immediately:
```bash
source ~/.bashrc
```

### PowerShell Aliases (in $PROFILE)

Add to your PowerShell profile (`$PROFILE`):

```powershell
# Fluidity aliases
function launch-fluidity {
    powershell -ExecutionPolicy Bypass -File "C:\Users\marcelr\launch-fluidity.ps1"
}

function fluidity {
    wsl fluidity
}
```

To edit profile:
```powershell
notepad $PROFILE
```

To apply immediately:
```powershell
. $PROFILE
```

### Install Scripts

#### 1. WSL Script: `launch-fluidity.sh`

Location: `/home/marcelr/apps/fluidity/launch-fluidity.sh`

```bash
#!/bin/bash

# Detect WSL IP
WSL_IP=$(hostname -I | awk '{print $1}')

if [ -z "$WSL_IP" ]; then
    echo "Error: Could not detect WSL IP"
    exit 1
fi

echo "WSL IP: $WSL_IP"
echo "Starting Fluidity agent..."

# Start agent in background
/home/marcelr/apps/fluidity/fluidity-agent -config /home/marcelr/apps/fluidity/agent.yaml &
AGENT_PID=$!

# Wait for agent to start
echo "Waiting for agent to start (5 seconds)..."
sleep 5

# Verify agent is running
if ! kill -0 $AGENT_PID 2>/dev/null; then
    echo "Error: Agent failed to start"
    exit 1
fi

echo "Agent is running (PID: $AGENT_PID)"
echo "Launching Brave with proxy: http://$WSL_IP:8080"

# Launch Brave with proxy
brave.exe --proxy-server="http://$WSL_IP:8080" &

echo "Brave launched. Press Ctrl+C to stop agent."
wait $AGENT_PID
```

#### 2. PowerShell Script: `launch-fluidity.ps1`

Location: `C:\Users\marcelr\launch-fluidity.ps1`

```powershell
# Detect WSL IP
$wslIp = wsl hostname -I | ForEach-Object { $_.Trim().Split(' ')[0] }

if ([string]::IsNullOrEmpty($wslIp)) {
    Write-Host "Error: Could not detect WSL IP" -ForegroundColor Red
    exit 1
}

Write-Host "WSL IP: $wslIp" -ForegroundColor Cyan
Write-Host "Starting Fluidity agent..." -ForegroundColor Cyan

# Start agent in WSL background
$agentProcess = Start-Process -FilePath wsl `
    -ArgumentList "bash -c '/home/marcelr/apps/fluidity/fluidity-agent -config /home/marcelr/apps/fluidity/agent.yaml'" `
    -PassThru

Write-Host "Waiting for agent to start (5 seconds)..." -ForegroundColor Yellow
Start-Sleep -Seconds 5

# Verify agent is listening
$agentListening = $false
for ($i = 0; $i -lt 3; $i++) {
    try {
        $null = New-Object System.Net.Sockets.TcpClient($wslIp, 8080)
        $agentListening = $true
        break
    } catch {
        Write-Host "Waiting for agent... (attempt $($i+1)/3)" -ForegroundColor Yellow
        Start-Sleep -Seconds 2
    }
}

if (-not $agentListening) {
    Write-Host "Warning: Agent may not be listening, but attempting launch anyway" -ForegroundColor Yellow
}

Write-Host "Launching Brave with proxy: http://$wslIp:8080" -ForegroundColor Cyan
Start-Process -FilePath brave.exe -ArgumentList "--proxy-server=`"http://$wslIp:8080`""

Write-Host "Brave launched. Agent PID: $($agentProcess.Id)" -ForegroundColor Green
Write-Host "To stop agent: wsl kill $($agentProcess.Id)" -ForegroundColor Gray
```

#### 3. WSL Script: `launch-brave`

Location: `/home/marcelr/apps/fluidity/launch-brave`

```bash
#!/bin/bash

# Simple script to launch Brave with Fluidity proxy
# (Agent must already be running)

WSL_IP=$(hostname -I | awk '{print $1}')

if [ -z "$WSL_IP" ]; then
    echo "Error: Could not detect WSL IP"
    exit 1
fi

echo "Launching Brave with proxy: http://$WSL_IP:8080"
brave.exe --proxy-server="http://$WSL_IP:8080"
```

---

## Installation Paths

- **Agent binary (deployed)**: `/home/marcelr/apps/fluidity/fluidity-agent`
- **Config file (deployed)**: `/home/marcelr/apps/fluidity/agent.yaml`
- **Agent binary (source)**: `/mnt/c/Users/marcelr/code/Fluidity/build/fluidity-agent`
- **Config file (source)**: `/mnt/c/Users/marcelr/code/Fluidity/configs/agent.local.yaml`
- **Launch scripts**: `/home/marcelr/apps/fluidity/launch-*.sh`
- **Source code**: `/mnt/c/Users/marcelr/code/Fluidity`
- **Logs**: `~/.local/share/fluidity/logs/`

---

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

## Setup & Script Summary

### What We Created

**Enhanced Documentation (`docs/LAUNCH.md`):**
- ✅ Manual agent launch options (from build/ and deploy/ directories)
- ✅ Windows ↔ WSL IP mapping explanation
- ✅ 7 browser launch options (manual to automated)
- ✅ 5 combined agent+browser methods
- ✅ Complete script code and explanations
- ✅ Alias setup instructions for WSL and PowerShell

**Scripts Created:**

1. **PowerShell Script** (`C:\Users\marcelr\launch-fluidity.ps1`)
   - Detects WSL IP automatically
   - Starts agent in WSL background
   - Validates agent is listening
   - Launches Brave with proxy
   - Colorized status output

2. **WSL All-in-One Script** (`/home/marcelr/apps/fluidity/launch-fluidity.sh`)
   - Detects WSL IP
   - Starts agent in background
   - Validates port is listening
   - Launches Brave with proxy
   - Colorized output

3. **WSL Browser Launcher** (`/home/marcelr/apps/fluidity/launch-brave`)
   - Simple script to launch just Brave
   - For when agent already running
   - Colorized output

---

## Alias Setup (Required)

### WSL Bash Aliases (~/.bashrc)

Add these lines:

```bash
alias fluidity="/home/marcelr/apps/fluidity/fluidity-agent -config /home/marcelr/apps/fluidity/agent.yaml"
alias launch-fluidity="/home/marcelr/apps/fluidity/launch-fluidity.sh"
alias brave-fluidity="/home/marcelr/apps/fluidity/launch-brave"
```

Apply:
```bash
source ~/.bashrc
```

### PowerShell Functions ($PROFILE)

Add these lines to your PowerShell profile:

```powershell
function launch-fluidity {
    powershell -ExecutionPolicy Bypass -File "C:\Users\marcelr\launch-fluidity.ps1"
}

function fluidity {
    wsl fluidity
}
```

Edit profile:
```powershell
notepad $PROFILE
```

Apply:
```powershell
. $PROFILE
```

---

## Quick Start: Three Ways

### Way 1: WSL One-Command

```bash
$ launch-fluidity
```

Automatically detects IP, starts agent, launches Brave.

### Way 2: PowerShell One-Command

```powershell
PS> launch-fluidity
```

Same as WSL, but from Windows PowerShell.

### Way 3: Two Terminals (Monitoring)

**Terminal 1:**
```bash
$ fluidity
# Agent logs visible
```

**Terminal 2:**
```bash
$ brave-fluidity
# Launches Brave
```

---

## Script Details

### PowerShell Script Features

```powershell
# Location: C:\Users\marcelr\launch-fluidity.ps1
# Usage: powershell -ExecutionPolicy Bypass -File "C:\Users\marcelr\launch-fluidity.ps1"
#        or: launch-fluidity (with alias)

# What it does:
# 1. Detects WSL IP
# 2. Starts agent in WSL background
# 3. Waits 5 seconds for startup
# 4. Validates port 8080 is listening
# 5. Launches Brave with proxy
# 6. Shows completion status

# Output:
# WSL IP: 172.23.223.98
# Agent started (PID: 1234)
# Launching Brave with proxy: http://172.23.223.98:8080
# Brave launched successfully
```

### WSL All-in-One Script Features

```bash
# Location: /home/marcelr/apps/fluidity/launch-fluidity.sh
# Usage: bash /home/marcelr/apps/fluidity/launch-fluidity.sh
#        or: launch-fluidity (with alias)

# What it does:
# 1. Detects WSL IP
# 2. Starts agent in background
# 3. Waits 5 seconds for startup
# 4. Validates port 8080 is listening
# 5. Launches Brave with proxy
# 6. Shows completion status with color
# 7. Waits for agent process (Ctrl+C stops both)

# Output:
# WSL IP: 172.23.223.98
# Agent started (PID: 1234)
# Launching Brave with proxy: http://172.23.223.98:8080
# Fluidity is ready!
```

### WSL Browser Launcher Features

```bash
# Location: /home/marcelr/apps/fluidity/launch-brave
# Usage: bash /home/marcelr/apps/fluidity/launch-brave
#        or: brave-fluidity (with alias)

# What it does:
# 1. Detects WSL IP
# 2. Launches Brave with proxy
# 3. (Agent must already be running)

# Useful when:
# - Agent is running in another terminal
# - You just want to launch a new browser window
# - You need quick browser restarts
```

---

## File Locations Summary

| Item | Path |
|------|------|
| **Documentation** | `docs/LAUNCH.md` |
| **PowerShell script** | `C:\Users\marcelr\launch-fluidity.ps1` |
| **WSL all-in-one** | `/home/marcelr/apps/fluidity/launch-fluidity.sh` |
| **WSL browser launcher** | `/home/marcelr/apps/fluidity/launch-brave` |
| **Agent binary (deployed)** | `/home/marcelr/apps/fluidity/fluidity-agent` |
| **Agent config (deployed)** | `/home/marcelr/apps/fluidity/agent.yaml` |
| **Agent binary (source)** | `/mnt/c/Users/marcelr/code/Fluidity/build/fluidity-agent` |
| **Config (source)** | `/mnt/c/Users/marcelr/code/Fluidity/configs/agent.local.yaml` |
| **Source code** | `/mnt/c/Users/marcelr/code/Fluidity` |
| **Logs** | `~/.local/share/fluidity/logs/` |

---

## Troubleshooting

### PowerShell Execution Policy Error

If script won't run, use:
```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\marcelr\launch-fluidity.ps1"
```

Or set permanently:
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### WSL IP Not Detected

Scripts use `hostname -I`. If that fails:
```bash
# Manual detection
hostname -I | awk '{print $1}'

# Manual launch
brave.exe --proxy-server="http://YOUR_WSL_IP:8080"
```

### Agent Won't Start

Check binary exists:
```bash
ls -la /home/marcelr/apps/fluidity/fluidity-agent
```

Check config exists:
```bash
cat /home/marcelr/apps/fluidity/agent.yaml
```

Check AWS credentials:
```bash
aws sts get-caller-identity
```

### Brave Won't Launch

Ensure Brave is in PATH:
```powershell
where.exe brave
```

Or use full path:
```powershell
& "C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe" --proxy-server="http://172.23.223.98:8080"
```

---
