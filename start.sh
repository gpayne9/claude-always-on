#!/bin/bash
# Start Claude Code remote control servers in tmux for each repo.
# These show up in the Claude app under "Remote control".
# Run manually or via LaunchAgent on login.
#
# If a session is already running, it's skipped (safe to re-run).
# Each session runs a restart loop with exponential backoff: if claude
# exits quickly (<60s), delay doubles (10s->20s->40s->...->300s max).
# Successful runs (>60s) reset the delay back to 10s.
#
# Usage: ./start.sh           # start all sessions
#        ./start.sh --status   # show session health
#
# Also starts a caffeinate process to prevent system sleep and
# disables App Nap so macOS doesn't throttle background sessions.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Use sessions.local.conf if it exists (gitignored, your real repos),
# otherwise fall back to sessions.conf (example config checked into repo).
if [ -f "$SCRIPT_DIR/sessions.local.conf" ]; then
  CONF="$SCRIPT_DIR/sessions.local.conf"
else
  CONF="$SCRIPT_DIR/sessions.conf"
fi

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# Unset env vars that interfere with remote control.
# CLAUDE_CODE_OAUTH_TOKEN causes "Remote Control is not yet enabled" because
# the token lacks required scopes. Remote control needs interactive OAuth auth.
# ANTHROPIC_API_KEY (if set) can also confuse the auth flow.
unset CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null
unset ANTHROPIC_API_KEY 2>/dev/null

# Find tmux
if command -v tmux &>/dev/null; then
  TMUX="$(command -v tmux)"
else
  echo "ERROR: tmux not found. Install with: brew install tmux"
  exit 1
fi

# --- Status check mode ---
if [ "${1:-}" = "--status" ]; then
  if [ ! -f "$CONF" ]; then
    echo "ERROR: $CONF not found."
    exit 1
  fi

  # Check keepawake
  if "$TMUX" has-session -t keepawake 2>/dev/null && pgrep -f "caffeinate -s" > /dev/null 2>&1; then
    echo "  ✓ keepawake"
  else
    echo "  ✗ keepawake"
  fi

  # Check each session
  while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    name="${line%%:*}"

    if ! "$TMUX" has-session -t "$name" 2>/dev/null; then
      echo "  ✗ $name (no tmux session)"
      continue
    fi

    pane_pid=$("$TMUX" list-panes -t "$name" -F '#{pane_pid}' 2>/dev/null | head -1)
    found_claude=0
    if [ -n "$pane_pid" ]; then
      if pgrep -P "$pane_pid" -f "claude" > /dev/null 2>&1; then
        found_claude=1
      else
        for cpid in $(pgrep -P "$pane_pid" 2>/dev/null); do
          if pgrep -P "$cpid" -f "claude" > /dev/null 2>&1; then
            found_claude=1
            break
          fi
        done
      fi
    fi

    if [ "$found_claude" -eq 1 ]; then
      echo "  ✓ $name"
    else
      echo "  ✗ $name (no claude process)"
    fi
  done < "$CONF"
  exit 0
fi

# --- Prevent system sleep via caffeinate ---
# Run in a dedicated tmux session so it persists and is easy to inspect.
if ! "$TMUX" has-session -t keepawake 2>/dev/null; then
  "$TMUX" new-session -d -s keepawake
  # -s = prevent system sleep, -d = prevent disk sleep
  "$TMUX" send-keys -t keepawake "caffeinate -s -d" Enter
  echo "Started 'keepawake' session (caffeinate -s -d)"
else
  echo "Session 'keepawake' already running, skipping."
fi

# --- Disable App Nap globally ---
# Prevents macOS from throttling background Node/claude processes.
# Only writes if not already set to false.
current_appnap=$(defaults read NSGlobalDomain NSAppNapEnabled 2>/dev/null)
if [ "$current_appnap" != "0" ]; then
  defaults write NSGlobalDomain NSAppNapEnabled -bool false
  echo "Disabled App Nap (NSAppNapEnabled=false). Logout/login to take full effect."
else
  echo "App Nap already disabled."
fi

# --- Read session config ---
if [ ! -f "$CONF" ]; then
  echo "ERROR: $CONF not found. Copy sessions.conf.example and edit it."
  exit 1
fi

# --- Start Claude remote control sessions ---
while IFS= read -r line; do
  # Skip comments and blank lines
  [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue

  name="${line%%:*}"
  raw_path="${line#*:}"
  path=$(eval echo "$raw_path")  # expand $HOME

  if "$TMUX" has-session -t "$name" 2>/dev/null; then
    echo "Session '$name' already running, skipping."
    continue
  fi

  if [ ! -d "$path" ]; then
    echo "Warning: $path does not exist, skipping '$name'."
    continue
  fi

  "$TMUX" new-session -d -s "$name" -c "$path"
  # Restart loop with exponential backoff: 10s -> 20s -> 40s -> 80s -> max 300s
  # Resets to 10s after a successful run (>60s uptime means it connected OK)
  "$TMUX" send-keys -t "$name" \
    "delay=10; while true; do start_ts=\$(date +%s); claude remote-control --name \"$name\" --spawn same-dir; elapsed=\$(( \$(date +%s) - start_ts )); if [ \$elapsed -gt 60 ]; then delay=10; else delay=\$(( delay * 2 )); [ \$delay -gt 300 ] && delay=300; fi; echo \"Claude exited after \${elapsed}s, restarting in \${delay}s...\"; sleep \$delay; done" Enter
  echo "Started session '$name' in $path"
done < "$CONF"
