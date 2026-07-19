# Claude Always-On v2 — Design

**Date:** 2026-07-18
**Status:** Approved by user (design conversation)

## Background

The repo keeps `claude remote-control` sessions running 24/7 on a headless Mac
Mini via tmux sessions, restart loops, and launchd. Two things prompted this
redesign:

1. **A real outage.** The system silently failed for an unknown period because
   claude.ai credentials expired: every session looped on
   `Authentication failed (401) ... Please use /login` every 10 seconds with no
   alert telling the owner to re-login. Separately, the machine was still
   running an older pre-publication copy of these scripts (from
   `home-lab-pi/mac-mini/`) whose LaunchAgent pointed at a moved file (exit 127).
2. **The CLI evolved.** As of Claude Code v2.1+, `claude remote-control` is a
   persistent multi-session server (`--spawn same-dir|worktree`, default
   capacity 32) that no longer exits when an individual session ends, and newer
   builds auto-reconnect after network drops. There is still **no official
   daemon/headless mode** (open feature request), and cloud sessions cannot
   access local files — so the tmux + launchd architecture remains necessary;
   only the reliability logic needs modernizing.

## Goals

- One copy of the restart-loop logic (it is currently duplicated in `start.sh`
  and `monitor.sh` and has already drifted from what runs in production).
- Auth failures are **detected, alerted, and retried slowly** instead of
  churning silently every 10s.
- The monitor never kills a healthy session that is merely sleeping in its
  backoff window.
- Recovery is automatic once the owner re-logs in; no manual restart needed.
- Same UX: `sessions.local.conf` (or example `sessions.conf`) is the only file
  users edit; scripts stay idempotent, POSIX-friendly bash, tmux-only
  dependency.

## Non-Goals (YAGNI)

- No daemon-mode replacement (doesn't exist yet; revisit when it ships).
- No per-repo worktree spawn-mode config (the server's runtime `w` toggle
  covers it).
- No Routines/cloud offload in this change.
- No new languages or dependencies (no Python, no Node).

## Components

### `lib.sh` (new, sourced — not executed)

Shared helpers used by `start.sh`, `monitor.sh`, `run-session.sh`, `test.sh`:

- PATH setup (`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`).
- Unset `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY` (they break remote
  control's interactive OAuth).
- `find_tmux` — resolve tmux via `command -v` or fail with install hint.
- Config resolution: `sessions.local.conf` if present, else `sessions.conf`.
- `read_sessions` — parse `name:path` lines, skipping comments/blanks.
- `start_session <name> <path>` — create the tmux session running
  `run-session.sh`. **The only place a session is ever created**, used by both
  `start.sh` and `monitor.sh`.
- Constants: state dir `~/.local/state/claude-always-on/`, log dir
  `~/Library/Logs/claude-always-on/`.

### `run-session.sh` (new, runs inside each tmux session)

`run-session.sh <name> <path>` — the restart loop as a file:

- `cd <path>`, then loop: run
  `claude remote-control --name <name> --spawn same-dir` with stderr
  appended to `~/Library/Logs/claude-always-on/<name>.log` (stdout stays on
  the TTY so the server's interactive UI is unaffected).
- Exponential backoff exactly as v1: start 10s, double on fast exit (≤60s
  uptime), cap 300s, reset to 10s after a run lasting >60s.
- **Auth detection:** after each claude exit, scan the last ~50 log lines
  written during that run for auth-failure patterns
  (`Authentication failed`, `401`, `/login`, `Invalid authentication`,
  case-insensitive). On match: touch state file
  `<state-dir>/<name>.auth-failed` and pin delay at 300s. On any run lasting
  >60s: remove the state file and the monitor's notify-marker for this
  session (recovered — a future auth failure should notify immediately, not
  be suppressed by a stale 6-hour window).
  - *Implementation caveat:* if the 401 error turns out to be written to
    stdout rather than stderr, fall back to `tmux capture-pane -t <name>`
    for pattern detection. Verify empirically during implementation.
- Per-session log rotated when it exceeds ~1000 lines (same policy as the
  monitor log).

### `start.sh` (refactored)

- Same responsibilities and idempotency: keepawake (`caffeinate -s -d` in its
  own tmux session), App Nap disable, then one tmux session per config line
  via `start_session`, skipping ones that already exist.
- `--status` reports per session:
  - `✓ name` — run-session.sh alive and a claude process running.
  - `↻ name (backoff)` — run-session.sh alive, no claude process (waiting to
    retry). Healthy-degraded, not an error.
  - `⚠ name (auth failed — run claude /login)` — auth state file present.
  - `✗ name (...)` — tmux session or run-session.sh missing.

### `monitor.sh` (refactored)

Runs every 5 minutes via LaunchAgent:

- **Health =** tmux session exists **and** a `run-session.sh` process for that
  session is alive. The presence of a `claude` process is *not* required
  (fixes the false-kill of sessions in their backoff window).
- **Aliveness wins over auth state:** a dead session is killed and recreated
  via `start_session` regardless of any auth state file. The state file only
  suppresses restarts of sessions that are *alive* but auth-failed.
- Alive auth-failed sessions (state file present): do **not** kill/restart.
  Send a macOS notification — "Re-login needed: open Terminal on this Mac,
  run `claude`, then `/login`" — at most once per 6 hours, deduped via the
  mtime of a notify-marker file in the state dir.
- Genuinely dead sessions: kill the tmux session and recreate via
  `start_session`. Notify as today.
- keepawake check unchanged. The monitor log moves to
  `~/Library/Logs/claude-always-on/monitor.log` (inside the new log dir);
  rotation policy unchanged.

### `install.sh` (minor changes)

- Unchanged plist generation/loading (labels `com.claude.always-on.*`).
- Create the state and log directories.
- Warn (not fail) if `claude --version` is older than 2.1.207, the build that
  added server-mode auto-reconnect.

### `test.sh` (updated)

- Updated to the new health semantics (`run-session.sh` process = alive;
  backoff and auth-failed are distinct reported states).
- `--simulate` display-sleep test retained.

### `uninstall.sh` (unchanged)

### Docs

- `README.md` updated: new files, new status states, auth-failure behavior,
  note on CLI server mode.
- Companion blog post in `gpayne9/guydevops.com`
  (`_posts/2026-04-03-always-on-claude-code-remote-control-mac-mini.md`)
  updated to match, per CLAUDE.md.

## Data Flow

1. Login / install → LaunchAgent runs `start.sh` → `start_session` per repo →
   tmux runs `run-session.sh` → `claude remote-control` server registers with
   claude.ai.
2. Claude exits → `run-session.sh` scans stderr log → normal crash: backoff
   retry; auth failure: state file + 300s retry.
3. Every 5 min `monitor.sh` → dead sessions recreated; auth-failed sessions
   left running + deduped notification; all else logged `OK`.
4. Owner re-logs in → next retry succeeds → >60s uptime clears state file →
   status returns to `✓`.

## Error Handling

| Failure | Behavior |
|---|---|
| 401 / auth expired | Slow retry (300s), state file, deduped notification; auto-recovery after `/login` |
| claude crash | Exponential backoff restart in-place |
| run-session.sh / tmux session dies | Monitor recreates within 5 min |
| Repo path missing | Logged + notified, session skipped |
| tmux not installed | Hard error with `brew install tmux` hint |
| Log growth | Rotation at ~1000 lines (monitor log and per-session logs) |

## Migration (one-time, on this machine)

1. Update the claude CLI.
2. Write `sessions.local.conf` (gitignored):
   `guydevops:$HOME/repos/guydevops.com`, `runlocal:$HOME/repos/runlocal`,
   `home-lab-pi:$HOME/repos/home-lab-pi`.
3. `launchctl bootout` + delete old `com.guy.claude-sessions` /
   `com.guy.claude-monitor` plists (old scripts stay on disk in `home-lab-pi`,
   just never run again).
4. Kill existing old-style tmux sessions.
5. `./install.sh`, then `./test.sh`.
6. Owner runs `claude` → `/login` on the Mini. Sessions recover automatically
   within one retry cycle.

## Testing

- `shellcheck` clean on all scripts.
- `./test.sh` passes.
- Manual: kill a claude process → verify in-place restart; fake an auth-failed
  state file → verify monitor notifies without killing; verify `--status`
  states render correctly.
- Live: after re-login, sessions appear in the Remote Control list.
