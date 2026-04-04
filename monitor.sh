#!/bin/bash
# Health monitor for Claude Code remote control sessions.
# Checks that each expected tmux session is running with a live claude process.
# Restarts dead sessions and sends macOS notifications.
# Designed to run every 5 minutes via LaunchAgent.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$SCRIPT_DIR/sessions.conf"
START_SCRIPT="$SCRIPT_DIR/start.sh"

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

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

issues_found=0

# --- Check caffeinate (keepawake session) ---
if ! "$TMUX" has-session -t keepawake 2>/dev/null; then
  log "WARN: 'keepawake' tmux session missing"
  issues_found=1
elif ! pgrep -f "caffeinate -s" > /dev/null 2>&1; then
  log "WARN: caffeinate process not running inside keepawake session"
  issues_found=1
fi

# --- Check each Claude session ---
for name in "${SESSIONS[@]}"; do
  if ! "$TMUX" has-session -t "$name" 2>/dev/null; then
    log "WARN: tmux session '$name' not found"
    issues_found=1
    continue
  fi

  # Check if a claude process is running inside this tmux session
  pane_pid=$("$TMUX" list-panes -t "$name" -F '#{pane_pid}' 2>/dev/null | head -1)
  if [ -z "$pane_pid" ]; then
    log "WARN: could not get pane PID for session '$name'"
    issues_found=1
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
      issues_found=1
    fi
  fi
done

# --- If issues found, restart everything ---
if [ "$issues_found" -eq 1 ]; then
  log "ACTION: issues detected, running start script to recover"
  notify "Restarting Claude sessions — issues detected"
  bash "$START_SCRIPT" >> "$LOG" 2>&1
  log "ACTION: start script completed"
else
  log "OK: all sessions healthy"
fi
