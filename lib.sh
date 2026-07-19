#!/bin/bash
# Shared helpers for Claude Always-On scripts. Source this file, don't run it:
#   source "$(dirname "$0")/lib.sh"
# Provides PATH setup, env hygiene, config resolution, tmux discovery,
# session parsing, health checks, and the single code path for creating
# sessions (start_session).

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# These env vars break remote control's interactive OAuth (token lacks the
# required scopes / API key confuses the auth flow).
unset CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null
unset ANTHROPIC_API_KEY 2>/dev/null

CAO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${CAO_STATE_DIR:-$HOME/.local/state/claude-always-on}"
LOG_DIR="${CAO_LOG_DIR:-$HOME/Library/Logs/claude-always-on}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"   # overridable so tests can stub claude
MAX_LOG_LINES=1000

# sessions.local.conf (gitignored, your real repos) wins over the
# checked-in example config.
if [ -f "$CAO_DIR/sessions.local.conf" ]; then
  CONF="$CAO_DIR/sessions.local.conf"
else
  CONF="$CAO_DIR/sessions.conf"
fi

# Sets TMUX_BIN or fails. (Not named TMUX — tmux itself uses that env var.)
find_tmux() {
  TMUX_BIN="$(command -v tmux)" && return 0
  echo "ERROR: tmux not found. Install with: brew install tmux" >&2
  return 1
}

# Populates SESSION_NAMES/SESSION_PATHS (and DISPLAY_PREFIX) from $CONF.
# Skips comments/blanks. A "prefix=<text>" line sets a display-name prefix
# shown in the Remote Control dropdown (tmux session names stay unprefixed).
read_sessions() {
  SESSION_NAMES=()
  SESSION_PATHS=()
  DISPLAY_PREFIX=""
  local line name raw_path
  while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    if [[ "$line" == prefix=* ]]; then
      DISPLAY_PREFIX="${line#prefix=}"
      continue
    fi
    [[ "$line" != *:* ]] && continue  # not a name:path line
    name="${line%%:*}"
    raw_path="${line#*:}"
    SESSION_NAMES+=("$name")
    SESSION_PATHS+=("$(eval echo "$raw_path")")
  done < "$CONF"
}

# The ONLY place a claude session is created (used by start.sh and
# monitor.sh). The pane runs run-session.sh directly: if the loop dies, the
# tmux session dies with it, and the monitor recreates the whole thing.
start_session() {
  local name="$1" path="$2" cmd
  mkdir -p "$STATE_DIR" "$LOG_DIR"
  cmd="$(printf '%q %q %q' "$CAO_DIR/run-session.sh" "$name" "$path")"
  "$TMUX_BIN" new-session -d -s "$name" -c "$path" "$cmd"
}

# Alive: tmux session exists and its pane is running run-session.sh.
# (The pane command line contains "run-session.sh" whether the shell
# exec'd the script or wraps it via sh -c.)
session_alive() {
  local name="$1" pane_pid
  "$TMUX_BIN" has-session -t "$name" 2>/dev/null || return 1
  pane_pid=$("$TMUX_BIN" list-panes -t "$name" -F '#{pane_pid}' 2>/dev/null | head -1)
  [ -n "$pane_pid" ] || return 1
  ps -o command= -p "$pane_pid" 2>/dev/null | grep -q "run-session.sh"
}

# A claude process is running under the session's pane (children or
# grandchildren — the pane may be run-session.sh itself or a shell wrapper).
claude_running() {
  local name="$1" pane_pid cpid
  pane_pid=$("$TMUX_BIN" list-panes -t "$name" -F '#{pane_pid}' 2>/dev/null | head -1)
  [ -n "$pane_pid" ] || return 1
  # Match "claude remote-control", not bare "claude" — the repo path itself
  # contains "claude" and would false-match run-session.sh.
  if pgrep -P "$pane_pid" -f "claude remote-control" > /dev/null 2>&1; then
    return 0
  fi
  for cpid in $(pgrep -P "$pane_pid" 2>/dev/null); do
    pgrep -P "$cpid" -f "claude remote-control" > /dev/null 2>&1 && return 0
  done
  return 1
}

# Trim a log file in place once it exceeds MAX_LOG_LINES.
rotate_log() {
  local file="$1"
  [ -f "$file" ] || return 0
  if [ "$(wc -l < "$file")" -gt "$MAX_LOG_LINES" ]; then
    tail -n 500 "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  fi
}
