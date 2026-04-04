# Claude Always-On

Persistent, self-healing Claude Code remote control sessions on macOS. GitHub repo: https://github.com/gpayne9/claude-always-on

## What This Is

A set of bash scripts that keep `claude remote-control` running 24/7 on a Mac (designed for a headless Mac Mini). Each repo gets a dedicated tmux session with an automatic restart loop. A health monitor checks every 5 minutes and recovers anything that died. LaunchAgents handle auto-start on login.

## Repo Structure

- `sessions.conf` — single source of truth for which repos to run. Format: `name:path` per line.
- `start.sh` — creates tmux sessions, restart loops, caffeinate, App Nap disable. Safe to re-run (skips existing sessions).
- `monitor.sh` — health check, restarts dead sessions, sends macOS notifications. Runs via LaunchAgent every 5 min.
- `test.sh` — diagnostic script. `--simulate` mode forces display sleep and re-checks sessions survived.
- `install.sh` — generates LaunchAgent plists with correct paths and loads them. No manual plist editing.
- `uninstall.sh` — removes LaunchAgents, kills all tmux sessions.

## Key Design Decisions

- All scripts read session config from `sessions.conf` — never duplicate the list.
- tmux is found dynamically via `command -v`, not hardcoded.
- `install.sh` generates plists at install time so paths are always correct.
- The restart loop (`while true; do claude remote-control ...; sleep 10; done`) is the core reliability mechanism.
- `caffeinate -s -d` runs in a `keepawake` tmux session to prevent system/disk sleep.
- App Nap is disabled globally to prevent macOS from throttling background Node processes.

## Companion Blog Post

There's a blog post about this at https://github.com/gpayne9/guydevops.com in `_posts/2026-04-03-always-on-claude-code-remote-control-mac-mini.md`. The blog post explains the why/how and links to this repo for the actual scripts. Keep them in sync if making changes.

## Guidelines

- Keep scripts POSIX-friendly bash. No Python, no Node, no extra dependencies beyond tmux.
- `sessions.conf` is the only file users should need to edit for basic setup.
- Scripts should be safe to re-run without side effects (idempotent).
- Test changes with `./test.sh` before committing.
