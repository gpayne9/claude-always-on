#!/bin/bash
# Test script for Claude Code remote control session reliability.
# Verifies all prerequisites are met and sessions are healthy.
#
# Usage:
#   ./test.sh              # Quick health check
#   ./test.sh --simulate   # Full test: dims display, waits, re-checks
#
# NOTE: Do NOT run with sudo. The script will call sudo internally
# only for the pmset commands that require it (during --simulate).

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

# Read session names from config
SESSIONS=()
while IFS= read -r line; do
  [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
  SESSIONS+=("${line%%:*}")
done < "$CONF"

# Refuse to run as root — user-specific checks (tmux, defaults, launchctl)
# break under sudo because they operate on root's context, not the user's.
if [ "$(id -u)" = "0" ]; then
  echo "ERROR: Do not run this script with sudo."
  echo "Run it as your normal user — it will call sudo internally for pmset."
  echo ""
  echo "  ./test.sh --simulate"
  exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass=0
fail=0
warn=0

check_pass() { echo -e "  ${GREEN}✓${NC} $1"; ((pass++)); }
check_fail() { echo -e "  ${RED}✗${NC} $1"; ((fail++)); }
check_warn() { echo -e "  ${YELLOW}!${NC} $1"; ((warn++)); }

echo "═══════════════════════════════════════════"
echo " Claude Always-On Health Check"
echo " $(date)"
echo "═══════════════════════════════════════════"
echo ""

# --- 1. Power Management Settings ---
echo "Power Management"
echo "─────────────────────────────────────────"

sleep_val=$(pmset -g custom | grep -w "sleep" | head -1 | awk '{print $2}')
if [ "$sleep_val" = "0" ]; then
  check_pass "System sleep disabled (sleep=$sleep_val)"
else
  check_fail "System sleep is set to $sleep_val minutes (should be 0)"
fi

disksleep_val=$(pmset -g custom | grep "disksleep" | awk '{print $2}')
if [ "$disksleep_val" = "0" ]; then
  check_pass "Disk sleep disabled (disksleep=$disksleep_val)"
else
  check_warn "Disk sleep is set to $disksleep_val (recommend 0)"
fi

tcpkeep=$(pmset -g custom | grep "tcpkeepalive" | awk '{print $2}')
if [ "$tcpkeep" = "1" ]; then
  check_pass "TCP keepalive enabled"
else
  check_fail "TCP keepalive disabled (HTTPS connections will drop)"
fi

womp=$(pmset -g custom | grep "womp" | awk '{print $2}')
if [ "$womp" = "1" ]; then
  check_pass "Wake on LAN enabled"
else
  check_warn "Wake on LAN disabled (nice to have as fallback)"
fi

autorestart=$(pmset -g custom | grep "autorestart" | awk '{print $2}')
if [ "$autorestart" = "1" ]; then
  check_pass "Auto-restart after power failure enabled"
else
  check_warn "Auto-restart after power failure disabled"
fi

standby=$(pmset -g custom | grep -w "standby" | awk '{print $2}')
if [ "$standby" = "0" ]; then
  check_pass "Standby disabled"
else
  check_fail "Standby is enabled (can cause deep sleep disconnections)"
fi

echo ""

# --- 2. App Nap ---
echo "App Nap"
echo "─────────────────────────────────────────"

appnap=$(defaults read NSGlobalDomain NSAppNapEnabled 2>/dev/null || echo "not set")
if [ "$appnap" = "0" ]; then
  check_pass "App Nap disabled globally"
else
  check_fail "App Nap is enabled or not set ($appnap) — background processes may be throttled"
fi

echo ""

# --- 3. Caffeinate ---
echo "Caffeinate"
echo "─────────────────────────────────────────"

if "$TMUX" has-session -t keepawake 2>/dev/null; then
  check_pass "keepawake tmux session exists"
else
  check_fail "keepawake tmux session not found"
fi

if pgrep -f "caffeinate -s" > /dev/null 2>&1; then
  check_pass "caffeinate process running"
  caff_pid=$(pgrep -f "caffeinate -s" | head -1)
  echo -e "       PID: $caff_pid"
else
  check_fail "caffeinate process not running (system may sleep when idle)"
fi

echo ""

# --- 4. Claude Sessions ---
echo "Claude Sessions"
echo "─────────────────────────────────────────"

for name in "${SESSIONS[@]}"; do
  if ! "$TMUX" has-session -t "$name" 2>/dev/null; then
    check_fail "tmux session '$name' not found"
    continue
  fi
  check_pass "tmux session '$name' exists"

  # Check for claude process
  pane_pid=$("$TMUX" list-panes -t "$name" -F '#{pane_pid}' 2>/dev/null | head -1)
  if [ -z "$pane_pid" ]; then
    check_fail "  could not get pane PID for '$name'"
    continue
  fi

  # Search for claude in children and grandchildren
  found_claude=0
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

  if [ "$found_claude" -eq 1 ]; then
    check_pass "  claude process running in '$name'"
  else
    check_fail "  no claude process found in '$name'"
  fi
done

echo ""

# --- 5. Monitor LaunchAgent ---
echo "Monitor LaunchAgent"
echo "─────────────────────────────────────────"

if launchctl list 2>/dev/null | grep -q "com.claude.always-on.monitor"; then
  check_pass "com.claude.always-on.monitor LaunchAgent loaded"
else
  check_warn "com.claude.always-on.monitor LaunchAgent not loaded"
  echo -e "       Install with: ./install.sh"
fi

echo ""

# --- 6. Power Assertions ---
echo "Active Power Assertions"
echo "─────────────────────────────────────────"

assertion_count=$(pmset -g assertions 2>/dev/null | grep -c "PreventUserIdleSystemSleep\|NoIdleSleepAssertion\|PreventSystemSleep" || true)
if [ "$assertion_count" -gt 0 ]; then
  check_pass "$assertion_count sleep-prevention assertion(s) active"
  pmset -g assertions 2>/dev/null | grep -E "PreventUserIdleSystemSleep|NoIdleSleepAssertion|PreventSystemSleep" | sed 's/^/       /'
else
  check_fail "No sleep-prevention assertions active"
fi

echo ""

# --- Summary ---
echo "═══════════════════════════════════════════"
total=$((pass + fail + warn))
echo -e " Results: ${GREEN}$pass passed${NC}, ${RED}$fail failed${NC}, ${YELLOW}$warn warnings${NC} (of $total checks)"

if [ "$fail" -gt 0 ]; then
  echo -e " ${RED}ISSUES FOUND${NC} — fix the failures above for reliable remote sessions"
  echo "═══════════════════════════════════════════"
  [ "${1:-}" != "--simulate" ] && exit 1
else
  echo -e " ${GREEN}ALL CHECKS PASSED${NC}"
  echo "═══════════════════════════════════════════"
fi

# --- Simulate Mode ---
if [ "${1:-}" = "--simulate" ]; then
  echo ""
  echo "═══════════════════════════════════════════"
  echo " SIMULATION: Testing inactive display state"
  echo "═══════════════════════════════════════════"
  echo ""

  orig_displaysleep=$(pmset -g custom | grep "displaysleep" | awk '{print $2}')
  echo "Current displaysleep: ${orig_displaysleep} minutes"
  echo "Temporarily setting displaysleep to 1 minute..."
  echo "(You may be prompted for your password)"
  echo ""

  sudo pmset -c displaysleep 1

  echo "Waiting 90 seconds for display to turn off..."
  echo "(Don't move your mouse/keyboard until the countdown finishes)"
  echo ""

  for i in $(seq 90 -1 1); do
    printf "\r  %d seconds remaining... " "$i"
    sleep 1
  done
  echo ""
  echo ""

  echo "Display should be off now. Re-checking sessions..."
  echo ""

  recheck_fail=0

  for name in "${SESSIONS[@]}"; do
    if ! "$TMUX" has-session -t "$name" 2>/dev/null; then
      check_fail "[POST-SLEEP] tmux session '$name' not found"
      recheck_fail=1
      continue
    fi
    check_pass "[POST-SLEEP] tmux session '$name' exists"

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
      check_pass "[POST-SLEEP] claude process alive in '$name'"
    else
      check_fail "[POST-SLEEP] claude process MISSING in '$name'"
      recheck_fail=1
    fi
  done

  if pgrep -f "caffeinate -s" > /dev/null 2>&1; then
    check_pass "[POST-SLEEP] caffeinate still running"
  else
    check_fail "[POST-SLEEP] caffeinate died during display sleep"
    recheck_fail=1
  fi

  echo ""
  echo "Restoring displaysleep to $orig_displaysleep minutes..."
  sudo pmset -c displaysleep "$orig_displaysleep"
  check_pass "displaysleep restored to $orig_displaysleep"

  echo ""
  echo "═══════════════════════════════════════════"
  if [ "$recheck_fail" -eq 0 ]; then
    echo -e " ${GREEN}SIMULATION PASSED${NC} — sessions survived display sleep"
  else
    echo -e " ${RED}SIMULATION FAILED${NC} — some sessions died during display sleep"
  fi
  echo "═══════════════════════════════════════════"

  [ "$recheck_fail" -gt 0 ] && exit 1
fi
