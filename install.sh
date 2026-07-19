#!/bin/bash
# Install Claude Always-On LaunchAgents for auto-start and health monitoring.
# Run this once after cloning the repo and editing sessions.conf.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"

mkdir -p "$LAUNCH_AGENTS_DIR"

# State and log directories used by run-session.sh / monitor.sh
mkdir -p "$HOME/.local/state/claude-always-on" "$HOME/Library/Logs/claude-always-on"

# Warn (don't fail) if the claude CLI predates server-mode auto-reconnect.
version_lt() {
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<< "$1"
  IFS=. read -r b1 b2 b3 <<< "$2"
  if [ "$a1" != "$b1" ]; then [ "$a1" -lt "$b1" ]; return; fi
  if [ "$a2" != "$b2" ]; then [ "$a2" -lt "$b2" ]; return; fi
  [ "$a3" -lt "$b3" ]
}
claude_ver="$(claude --version 2>/dev/null | awk '{print $1}' || true)"  # || true: don't let set -e/pipefail abort install when claude is absent
if [ -n "$claude_ver" ] && version_lt "$claude_ver" "2.1.207"; then
  echo "WARNING: claude CLI $claude_ver is older than 2.1.207 (auto-reconnect)."
  echo "         Run: claude update"
fi

# --- Generate and install the start-on-login LaunchAgent ---
cat > "$LAUNCH_AGENTS_DIR/com.claude.always-on.start.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.claude.always-on.start</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${SCRIPT_DIR}/start.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${HOME}/Library/Logs/claude-always-on-start.log</string>
  <key>StandardErrorPath</key>
  <string>${HOME}/Library/Logs/claude-always-on-start.log</string>
</dict>
</plist>
EOF

echo "Created $LAUNCH_AGENTS_DIR/com.claude.always-on.start.plist"

# --- Generate and install the monitor LaunchAgent ---
cat > "$LAUNCH_AGENTS_DIR/com.claude.always-on.monitor.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.claude.always-on.monitor</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${SCRIPT_DIR}/monitor.sh</string>
  </array>
  <key>StartInterval</key>
  <integer>300</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${HOME}/Library/Logs/claude-always-on-monitor.log</string>
  <key>StandardErrorPath</key>
  <string>${HOME}/Library/Logs/claude-always-on-monitor.log</string>
  <key>ProcessType</key>
  <string>Background</string>
</dict>
</plist>
EOF

echo "Created $LAUNCH_AGENTS_DIR/com.claude.always-on.monitor.plist"

# --- Load the LaunchAgents ---
launchctl bootout gui/$(id -u) "$LAUNCH_AGENTS_DIR/com.claude.always-on.start.plist" 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$LAUNCH_AGENTS_DIR/com.claude.always-on.start.plist"
echo "Loaded com.claude.always-on.start"

launchctl bootout gui/$(id -u) "$LAUNCH_AGENTS_DIR/com.claude.always-on.monitor.plist" 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$LAUNCH_AGENTS_DIR/com.claude.always-on.monitor.plist"
echo "Loaded com.claude.always-on.monitor"

echo ""
echo "Done. Claude sessions will start on login and be monitored every 5 minutes."
echo "Run ./test.sh to verify everything is working."
