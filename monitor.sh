#!/bin/bash
# Health monitor for Claude Code remote control sessions.
# Checks that each expected tmux session is running with a live claude process.
# Restarts only the dead sessions (not all) and sends macOS notifications.
# Designed to run every 5 minutes via LaunchAgent.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/sessions.local.conf" ]; then
  CONF="$SCRIPT_DIR/sessions.local.conf"
else
  CONF="$SCRIPT_DIR/sessions.conf"
fi

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# Unset env vars that interfere with remote control (see start.sh for details)
unset CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null
unset ANTHROPIC_API_KEY 2>/dev/null

LOG="$HOME/Library/Logs/claude-always-on.log"
MAX_LOG_LINES=1000

# Find tmux
if command -v tmux &>/dev/null; then
  TMUX="$(command -v tmux)"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: tmux not found" >> "$LOG"
  exit 1
fi

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

notify() {
  osascript -e "display notification \"$1\" with title \"Claude Always-On\"" 2>/dev/null
}

# Rotate log if it gets too long
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt "$MAX_LOG_LINES" ]; then
  tail -n 500 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
  log "Log rotated (exceeded $MAX_LOG_LINES lines)"
fi

# Read session names from config
SESSIONS=()
while IFS= read -r line; do
  [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
  SESSIONS+=("${line%%:*}")
done < "$CONF"

dead_sessions=()

# --- Check caffeinate (keepawake session) ---
keepawake_dead=0
if ! "$TMUX" has-session -t keepawake 2>/dev/null; then
  log "WARN: 'keepawake' tmux session missing"
  keepawake_dead=1
elif ! pgrep -f "caffeinate -s" > /dev/null 2>&1; then
  log "WARN: caffeinate process not running inside keepawake session"
  keepawake_dead=1
fi

# --- Check each Claude session ---
for name in "${SESSIONS[@]}"; do
  if ! "$TMUX" has-session -t "$name" 2>/dev/null; then
    log "WARN: tmux session '$name' not found"
    dead_sessions+=("$name")
    continue
  fi

  # Check if a claude process is running inside this tmux session
  pane_pid=$("$TMUX" list-panes -t "$name" -F '#{pane_pid}' 2>/dev/null | head -1)
  if [ -z "$pane_pid" ]; then
    log "WARN: could not get pane PID for session '$name'"
    dead_sessions+=("$name")
    continue
  fi

  # Look for claude processes that are descendants of this pane's shell
  if ! pgrep -P "$pane_pid" -f "claude" > /dev/null 2>&1; then
    # Also check grandchildren (the restart loop runs bash -> claude)
    child_pids=$(pgrep -P "$pane_pid" 2>/dev/null)
    found_claude=0
    for cpid in $child_pids; do
      if pgrep -P "$cpid" -f "claude" > /dev/null 2>&1; then
        found_claude=1
        break
      fi
    done
    if [ "$found_claude" -eq 0 ]; then
      log "WARN: no claude process found in session '$name' (pane_pid=$pane_pid)"
      dead_sessions+=("$name")
    fi
  fi
done

# --- Recover only what's broken ---
if [ "$keepawake_dead" -eq 1 ] || [ ${#dead_sessions[@]} -gt 0 ]; then
  if [ "$keepawake_dead" -eq 1 ]; then
    log "ACTION: recovering keepawake session"
    notify "Recovering keepawake session"
    # Re-create the keepawake session
    "$TMUX" kill-session -t keepawake 2>/dev/null || true
    "$TMUX" new-session -d -s keepawake
    "$TMUX" send-keys -t keepawake "caffeinate -s -d" Enter
    log "ACTION: keepawake session restarted"
  fi

  for name in "${dead_sessions[@]}"; do
    log "ACTION: recovering session '$name'"
    notify "Recovering Claude session: $name"
    # Kill the broken session if it exists but is unhealthy
    "$TMUX" kill-session -t "$name" 2>/dev/null || true
    # Find the path from config
    raw_path=$(grep "^${name}:" "$CONF" | head -1 | cut -d: -f2-)
    path=$(eval echo "$raw_path")
    if [ -z "$path" ] || [ ! -d "$path" ]; then
      log "ERROR: cannot recover '$name' — path '$path' not found in config or on disk"
      continue
    fi
    "$TMUX" new-session -d -s "$name" -c "$path"
    "$TMUX" send-keys -t "$name" \
      "delay=10; while true; do start_ts=\$(date +%s); claude remote-control --name \"$name\" --spawn same-dir; elapsed=\$(( \$(date +%s) - start_ts )); if [ \$elapsed -gt 60 ]; then delay=10; else delay=\$(( delay * 2 )); [ \$delay -gt 300 ] && delay=300; fi; echo \"Claude exited after \${elapsed}s, restarting in \${delay}s...\"; sleep \$delay; done" Enter
    log "ACTION: session '$name' restarted in $path"
  done
else
  log "OK: all sessions healthy"
fi
