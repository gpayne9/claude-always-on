#!/bin/bash
# Start Claude Code remote control servers in tmux for each repo.
# These show up in the Claude app under "Remote control".
# Run manually or via LaunchAgent on login.
#
# If a session is already running, it's skipped (safe to re-run).
# Each session runs a restart loop: if claude exits for any reason
# (crash, auth timeout, network blip), it waits 10s and restarts.
#
# Also starts a caffeinate process to prevent system sleep and
# disables App Nap so macOS doesn't throttle background sessions.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$SCRIPT_DIR/sessions.conf"

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# Find tmux
if command -v tmux &>/dev/null; then
  TMUX="$(command -v tmux)"
else
  echo "ERROR: tmux not found. Install with: brew install tmux"
  exit 1
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
  # Restart loop: if claude exits for any reason, wait 10s and restart
  "$TMUX" send-keys -t "$name" \
    "while true; do claude remote-control --name \"$name\" --spawn same-dir; echo 'Claude exited, restarting in 10s...'; sleep 10; done" Enter
  echo "Started session '$name' in $path"
done < "$CONF"
