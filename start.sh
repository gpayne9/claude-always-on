#!/bin/bash
# Start Claude Code remote control servers in tmux for each repo.
# These show up in the Claude app under "Remote control".
# Run manually or via LaunchAgent on login.
#
# Each tmux session runs run-session.sh, which restarts claude with
# exponential backoff and detects auth failures (see run-session.sh).
# If a session already exists, it's skipped (safe to re-run).
#
# Usage: ./start.sh            # start all sessions
#        ./start.sh --status   # show session health:
#          ✓ running   ↻ backoff (retrying)   ⚠ auth failed   ✗ dead
#
# Also starts a caffeinate process to prevent system sleep and
# disables App Nap so macOS doesn't throttle background sessions.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

find_tmux || exit 1

if [ ! -f "$CONF" ]; then
  echo "ERROR: $CONF not found."
  exit 1
fi
read_sessions

# --- Status check mode ---
if [ "${1:-}" = "--status" ]; then
  if "$TMUX_BIN" has-session -t keepawake 2>/dev/null && pgrep -f "caffeinate -s" > /dev/null 2>&1; then
    echo "  ✓ keepawake"
  else
    echo "  ✗ keepawake"
  fi

  for i in "${!SESSION_NAMES[@]}"; do
    name="${SESSION_NAMES[$i]}"
    if ! "$TMUX_BIN" has-session -t "$name" 2>/dev/null; then
      echo "  ✗ $name (no tmux session)"
    elif ! session_alive "$name"; then
      echo "  ✗ $name (restart loop dead)"
    elif [ -f "$STATE_DIR/$name.auth-failed" ]; then
      echo "  ⚠ $name (auth failed — run 'claude', then /login)"
    elif claude_running "$name"; then
      echo "  ✓ $name"
    else
      echo "  ↻ $name (backoff — waiting to retry)"
    fi
  done
  exit 0
fi

# --- Prevent system sleep via caffeinate ---
if ! "$TMUX_BIN" has-session -t keepawake 2>/dev/null; then
  # caffeinate runs as the pane command; if it dies, the session dies and
  # the monitor recreates it.  -s = no system sleep, -d = no display sleep
  "$TMUX_BIN" new-session -d -s keepawake "caffeinate -s -d"
  echo "Started 'keepawake' session (caffeinate -s -d)"
else
  echo "Session 'keepawake' already running, skipping."
fi

# --- Disable App Nap globally ---
# Prevents macOS from throttling background Node/claude processes.
current_appnap=$(defaults read NSGlobalDomain NSAppNapEnabled 2>/dev/null)
if [ "$current_appnap" != "0" ]; then
  defaults write NSGlobalDomain NSAppNapEnabled -bool false
  echo "Disabled App Nap (NSAppNapEnabled=false). Logout/login to take full effect."
else
  echo "App Nap already disabled."
fi

# --- Start Claude remote control sessions ---
for i in "${!SESSION_NAMES[@]}"; do
  name="${SESSION_NAMES[$i]}"
  path="${SESSION_PATHS[$i]}"

  if "$TMUX_BIN" has-session -t "$name" 2>/dev/null; then
    echo "Session '$name' already running, skipping."
    continue
  fi
  if [ ! -d "$path" ]; then
    echo "Warning: $path does not exist, skipping '$name'."
    continue
  fi
  start_session "$name" "$path"
  echo "Started session '$name' in $path"
done
