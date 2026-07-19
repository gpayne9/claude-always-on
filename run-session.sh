#!/bin/bash
# Restart loop for one claude remote-control session. Runs as the tmux pane
# command (started by lib.sh:start_session).
#
# Usage: run-session.sh <name> <path>
#
# Backoff: 10s, doubling on fast exits (<=60s uptime), capped at 300s; a run
# lasting >60s resets to 10s and clears any auth-failed state.
# Auth failures (401 / "/login" in claude's stderr) pin the delay at 300s and
# record a state file so monitor.sh notifies instead of restart-churning.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

NAME="$1"
REPO_PATH="$2"
# Display name (Remote Control dropdown) = optional conf prefix + name.
read_sessions
DISPLAY_NAME="$NAME"
[ -n "$DISPLAY_PREFIX" ] && DISPLAY_NAME="$DISPLAY_PREFIX $NAME"
SESSION_LOG="$LOG_DIR/$NAME.log"
AUTH_STATE="$STATE_DIR/$NAME.auth-failed"
NOTIFY_MARKER="$STATE_DIR/$NAME.notified"

mkdir -p "$LOG_DIR" "$STATE_DIR"
cd "$REPO_PATH" || exit 1

delay=10
while true; do
  rotate_log "$SESSION_LOG"
  mark_line=0
  [ -f "$SESSION_LOG" ] && mark_line=$(wc -l < "$SESSION_LOG")
  start_ts=$(date +%s)
  # Clear failure state 60s INTO the run, not just after it — a healthy
  # server can run for days without exiting, and a stale auth flag would
  # keep the monitor sending false "re-login needed" notifications.
  ( sleep 60 && rm -f "$AUTH_STATE" "$NOTIFY_MARKER" ) &
  watchdog=$!
  "$CLAUDE_BIN" remote-control --name "$DISPLAY_NAME" --spawn same-dir 2>>"$SESSION_LOG"
  elapsed=$(( $(date +%s) - start_ts ))
  kill "$watchdog" 2>/dev/null

  if [ "$elapsed" -gt 60 ]; then
    # Healthy run: reset backoff, clear auth state and the monitor's
    # notification marker (a future auth failure should notify immediately).
    rm -f "$AUTH_STATE" "$NOTIFY_MARKER"
    delay=10
  else
    # Fast exit: inspect stderr written during this run for auth failures.
    new_output=$(tail -n +"$((mark_line + 1))" "$SESSION_LOG" 2>/dev/null | tail -50)
    if echo "$new_output" | grep -qiE 'authentication failed|401|invalid authentication|/login'; then
      touch "$AUTH_STATE"
      delay=300
      echo "Auth failure detected — re-login needed (run 'claude', then /login)."
    else
      delay=$(( delay * 2 ))
      [ "$delay" -gt 300 ] && delay=300
    fi
  fi
  echo "Claude exited after ${elapsed}s, restarting in ${delay}s..."
  sleep "$delay"
done
