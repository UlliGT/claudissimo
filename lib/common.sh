#!/usr/bin/env bash
# Shared helpers for claudissimo. Sourced by bin/claudissimo and
# the lib/*.sh action scripts — do not execute directly.

PROJECTS_ROOT="${CLAUDE_PROJECTS_ROOT:-$HOME/claude-projects}"

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_CYAN_BOLD=$'\033[1;36m'
else
  C_RESET=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN_BOLD=""
fi

log_info() { printf '%s\n' "$*"; }
log_ok()   { printf '%s[ok]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
log_err()  { printf '%s[error]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
log_skip() { printf '[skip] %s\n' "$*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# Liveness check for a Claude Code background session's pid. `pgrep` is not
# reliable here: `claude respawn` takes over a pre-started spare process
# ("bg-spare") whose command line doesn't contain the session id, so matching
# by id fails; checking /proc/<pid>/cmdline for "claude" is what the revive
# script relies on and is reused here for the status report.
is_claude_pid_alive() {
  local pid="$1"
  [ -n "$pid" ] && [ "$pid" != "null" ] || return 1
  [ "$pid" -gt 0 ] 2>/dev/null || return 1
  grep -qa claude "/proc/$pid/cmdline" 2>/dev/null
}
