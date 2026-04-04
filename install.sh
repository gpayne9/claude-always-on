#!/bin/bash
# Install Claude Always-On LaunchAgents for auto-start and health monitoring.
# Run this once after cloning the repo and editing sessions.conf.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"

mkdir -p "$LAUNCH_AGENTS_DIR"

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
  <string>/tmp/claude-always-on-start.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/claude-always-on-start.log</string>
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
  <string>/tmp/claude-always-on-monitor.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/claude-always-on-monitor.log</string>
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
