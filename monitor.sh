#!/bin/bash
# Health monitor for Claude Always-On. Runs every 5 minutes via LaunchAgent.
#
# Health = tmux session exists AND run-session.sh is alive in its pane.
# A missing claude process is NOT unhealthy by itself (the loop may be in
# its backoff window).  Aliveness wins over auth state: dead sessions are
# recreated even if flagged auth-failed.  Alive-but-auth-failed sessions are
# left alone and produce a deduped (max once/6h) re-login notification.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

LOG="$LOG_DIR/monitor.log"
NOTIFY_INTERVAL_MIN=360   # dedupe window for auth notifications (minutes)

mkdir -p "$LOG_DIR" "$STATE_DIR"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }
notify() { osascript -e "display notification \"$1\" with title \"Claude Always-On\"" 2>/dev/null; }

find_tmux || { log "ERROR: tmux not found"; exit 1; }
rotate_log "$LOG"

if [ ! -f "$CONF" ]; then
  log "ERROR: $CONF not found"
  exit 1
fi
read_sessions

issues=0

# --- keepawake ---
if ! "$TMUX_BIN" has-session -t keepawake 2>/dev/null || ! pgrep -f "caffeinate -s" > /dev/null 2>&1; then
  log "WARN: keepawake unhealthy — recreating"
  notify "Recovering keepawake session"
  "$TMUX_BIN" kill-session -t keepawake 2>/dev/null || true
  "$TMUX_BIN" new-session -d -s keepawake "caffeinate -s -d"
  log "ACTION: keepawake restarted"
  issues=1
fi

# --- Claude sessions ---
for i in "${!SESSION_NAMES[@]}"; do
  name="${SESSION_NAMES[$i]}"
  path="${SESSION_PATHS[$i]}"

  if ! session_alive "$name"; then
    # Aliveness wins over auth state: dead is dead — recreate it.
    issues=1
    log "WARN: session '$name' dead — recreating"
    notify "Recovering Claude session: $name"
    "$TMUX_BIN" kill-session -t "$name" 2>/dev/null || true
    if [ ! -d "$path" ]; then
      log "ERROR: cannot recover '$name' — path '$path' not found"
      continue
    fi
    start_session "$name" "$path"
    log "ACTION: session '$name' restarted in $path"
    continue
  fi

  if [ -f "$STATE_DIR/$name.auth-failed" ]; then
    marker="$STATE_DIR/$name.notified"
    if [ ! -f "$marker" ] || [ -n "$(find "$marker" -mmin +"$NOTIFY_INTERVAL_MIN" 2>/dev/null)" ]; then
      log "WARN: session '$name' auth-failed — re-login needed"
      notify "Re-login needed: open Terminal, run 'claude', then /login"
      touch "$marker"
    fi
    issues=1
  fi
done

if [ "$issues" -eq 0 ]; then
  log "OK: all sessions healthy"
fi
exit 0
