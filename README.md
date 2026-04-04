# Claude Always-On

Persistent, self-healing [Claude Code](https://docs.anthropic.com/en/docs/claude-code) remote control sessions on a Mac. Accessible from any device — claude.ai, desktop app, or mobile app — 24/7.

Each repo gets a dedicated `claude remote-control` server running inside a tmux session with an automatic restart loop. A health monitor checks every 5 minutes and recovers anything that died. LaunchAgents start everything on login so it survives reboots.

## How Remote Control Works

Claude Code's remote control connects a local CLI session to the claude.ai web interface and Claude mobile apps. Your machine runs the session with full filesystem and tool access — the remote device is just a window into it.

The protocol is **outbound-only HTTPS** through Anthropic's relay at `api.anthropic.com`. No ports are opened on your machine. The CLI polls for new messages and streams responses back via Server-Sent Events (SSE).

```
┌─────────────┐       HTTPS/TLS (port 443)       ┌──────────────────┐
│  Your Mac   │──────── outbound only ──────────▶│ api.anthropic.com │
│  (claude    │◀─────── SSE responses ───────────│   (relay)         │
│   remote-   │                                   └────────┬─────────┘
│   control)  │                                            │
└─────────────┘                                   ┌────────┴─────────┐
                                                  │  claude.ai/code  │
                                                  │  Desktop app     │
                                                  │  Mobile app      │
                                                  └──────────────────┘
```

**Key details:**
- Not a tunnel — only structured application messages pass through the relay, not raw TCP
- Authentication is account-level — the remote device must be signed into the same claude.ai account
- ~10 minute network timeout — if your machine loses connectivity for that long, the session drops (the restart loop handles this)

## Quick Start

### Prerequisites

- macOS with [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated (`claude login`)
- tmux (`brew install tmux`)
- Claude Pro, Max, Team, or Enterprise plan
- Claude Code v2.1.51+

### Setup

```bash
# 1. Clone the repo
git clone https://github.com/gpayne9/claude-always-on.git
cd claude-always-on

# 2. Edit sessions.conf — add your repos
nano sessions.conf

# 3. Configure power management (prevents sleep on a headless Mac)
sudo pmset -a sleep 0 standby 0 tcpkeepalive 1 disksleep 0

# 4. Start the sessions
chmod +x start.sh monitor.sh test.sh install.sh uninstall.sh
./start.sh

# 5. Verify everything works
./test.sh

# 6. Install LaunchAgents (auto-start on login + health monitoring)
./install.sh
```

### Connect from Any Device

1. Open claude.ai/code, the Claude desktop app, or the Claude mobile app
2. Click the session picker dropdown
3. Under **Remote control**, select the repo you want
4. Start coding — Claude runs on your Mac with full local access

## File Overview

| File | Purpose |
|------|---------|
| `sessions.conf` | Your repos — one `name:path` per line |
| `start.sh` | Creates tmux sessions, starts remote control servers, caffeinate, disables App Nap |
| `monitor.sh` | Health check — verifies sessions every 5 min, restarts dead ones, sends macOS notifications |
| `test.sh` | Diagnostic — verifies all settings and session health |
| `install.sh` | Installs LaunchAgents for auto-start on login and monitoring |
| `uninstall.sh` | Removes LaunchAgents and kills all sessions |

## Configuration

### sessions.conf

Add one repo per line in `name:path` format. Lines starting with `#` are ignored.

```
my-project:$HOME/repos/my-project
my-api:$HOME/repos/my-api
my-site:$HOME/repos/my-site
```

The session name is what appears in the **Remote control** dropdown in the Claude app.

After editing, restart:

```bash
# Start only new sessions (safe to re-run)
./start.sh

# Or restart everything
tmux kill-server && ./start.sh
```

## Keeping the Mac Awake

A headless Mac will aggressively sleep, throttle background processes, and spin down disks. Three things prevent this:

| Setting | What It Does | Handled By |
|---------|-------------|------------|
| **caffeinate** | Prevents system and disk sleep via a persistent power assertion | `start.sh` (runs in `keepawake` tmux session) |
| **App Nap disabled** | Stops macOS from throttling background Node/claude processes when display is off | `start.sh` (`NSAppNapEnabled=false`) |
| **pmset** | System-level power management | You (one-time setup, see below) |

### pmset Settings

```bash
sudo pmset -a sleep 0          # never sleep
sudo pmset -a standby 0        # no deep sleep
sudo pmset -a tcpkeepalive 1   # keep HTTPS connections alive
sudo pmset -a disksleep 0      # no disk sleep
```

Verify with `pmset -g custom`.

## Health Monitoring

The monitor script (`monitor.sh`) runs every 5 minutes via LaunchAgent and checks:

- `keepawake` tmux session exists with a live `caffeinate` process
- Each session in `sessions.conf` has a running tmux session with a live `claude` process

If anything is missing, it runs `start.sh` to recover and sends a macOS notification.

View the log:

```bash
tail -f ~/Library/Logs/claude-always-on.log
```

## Testing

```bash
# Quick health check — verifies all settings and session status
./test.sh

# Full simulation — sets display sleep to 1 min, waits, re-checks sessions
# Do NOT use sudo — the script calls sudo internally for pmset only
./test.sh --simulate
```

The test checks:
- Power management settings (sleep, standby, tcpkeepalive, etc.)
- App Nap disabled
- caffeinate running
- All tmux sessions alive with claude processes
- Monitor LaunchAgent loaded
- Active power assertions

The `--simulate` flag temporarily sets `displaysleep 1`, waits 90 seconds for the display to turn off, then re-checks everything to confirm sessions survived.

## Managing Sessions

```bash
# List running sessions
tmux list-sessions

# Attach to a session (see server output, QR code, etc.)
tmux attach -t my-project
# Detach without stopping: Ctrl+B, D

# Stop a single session
tmux kill-session -t my-project

# Stop all sessions
tmux kill-server

# Restart everything
tmux kill-server && ./start.sh
```

When attached to a tmux session, the remote control server shows:
- Connection status (connected/disconnected)
- Session capacity (default: 32 concurrent)
- Spawn mode (same-dir or worktree)
- A URL and QR code (press space to toggle) for direct access

## Security Considerations

Remote control is outbound-only HTTPS through Anthropic's relay. No ports are opened on your machine. A few things to be aware of:

- **Session URL is a bearer token** — anyone with the URL (or who photographs the QR code) can operate the session. Keep your terminal private when the QR code is visible.
- **Sandbox is off by default** — remote sessions have full filesystem and tool access. Pass `--sandbox` to the `claude remote-control` command in `start.sh` if you want to restrict this.
- **MCP servers are accessible** — any MCP servers configured in your Claude Code settings are available through remote sessions.
- **Authentication is account-level** — the only gate is being logged into the same claude.ai account.

In practice, the risk is low. The relay is TLS-encrypted, sessions require your Anthropic account credentials, and there's no inbound attack surface.

## Resource Usage

| Metric | Expected |
|--------|----------|
| **RAM** | ~50–100 MB total for 3 sessions |
| **CPU** | Negligible when idle |
| **Network** | Minimal polling traffic (~few KB every 2–5s per session) |

## Troubleshooting

### Sessions not showing in Remote Control dropdown

```bash
tmux list-sessions           # are they running?
tmux attach -t my-project    # check for errors
```

If the server shows disconnected, it likely lost network for longer than ~10 minutes. The restart loop will pick it back up within 10 seconds.

### Sessions died after reboot

```bash
launchctl list | grep claude  # is the LaunchAgent loaded?
```

If not listed, re-run `./install.sh`.

### Mac is sleeping despite pmset settings

```bash
pgrep -f "caffeinate -s"     # is caffeinate running?
pmset -g assertions           # any sleep-prevention assertions?
```

You should see a `PreventUserIdleSystemSleep` assertion from caffeinate.

### tmux not found after reboot

The start script sets `PATH` explicitly, but if tmux is installed somewhere non-standard:

```bash
which tmux                    # find it
```

Update the fallback PATH in `start.sh` to include that directory.

## Uninstalling

```bash
./uninstall.sh
```

This removes the LaunchAgents and kills all tmux sessions. It does not revert pmset or App Nap settings.

## License

MIT
