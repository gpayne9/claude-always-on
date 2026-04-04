#!/bin/bash
# Uninstall Claude Always-On LaunchAgents and stop all sessions.

set -euo pipefail

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"

echo "Stopping LaunchAgents..."
launchctl bootout gui/$(id -u) "$LAUNCH_AGENTS_DIR/com.claude.always-on.start.plist" 2>/dev/null || true
launchctl bootout gui/$(id -u) "$LAUNCH_AGENTS_DIR/com.claude.always-on.monitor.plist" 2>/dev/null || true

echo "Removing plist files..."
rm -f "$LAUNCH_AGENTS_DIR/com.claude.always-on.start.plist"
rm -f "$LAUNCH_AGENTS_DIR/com.claude.always-on.monitor.plist"

echo "Killing all tmux sessions (including keepawake)..."
tmux kill-server 2>/dev/null || true

echo ""
echo "Done. All Claude Always-On sessions and LaunchAgents removed."
echo "App Nap and pmset settings were not reverted — change them manually if needed."
