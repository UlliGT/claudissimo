#!/usr/bin/env bash
# Authentication: what the background sessions run on, how long it lasts,
# and how to renew it. Shared by `status auth`, `check` and `auth`.
#
# Two ways a session can be authenticated, learned the hard way:
#  - the stored claude.ai login (~/.claude/.credentials.json): hard time
#    limit (about 4 weeks), cannot be renewed, sessions then keep running
#    but are useless, and a re-login does not reach processes already running
#  - a 1-year token (`claude setup-token`) in CLAUDE_CODE_OAUTH_TOKEN: only
#    effective for processes that have it in their environment. The shared
#    daemon hands its environment to every session it starts, so what counts
#    is whether the *daemon* was started with it.

AUTH_ENV_FILE="$HOME/.config/environment.d/claude.conf"
AUTH_WARN_DAYS=7
AUTH_FAIL_WINDOW="2 days ago"

# Fills A_* globals. Read-only, no API calls.
auth_collect() {
  A_TOKEN_FILE=0; A_TOKEN_AGE_DAYS=""
  if [ -f "$AUTH_ENV_FILE" ] && grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$AUTH_ENV_FILE" 2>/dev/null; then
    A_TOKEN_FILE=1
    A_TOKEN_AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$AUTH_ENV_FILE") ) / 86400 ))
  fi

  A_DAEMON_PID="$(claude daemon status 2>/dev/null | awk '/^pid:/ {print $2}')"
  A_DAEMON_TOKEN="unknown"   # yes | no | unknown (daemon not running)
  if [ -n "$A_DAEMON_PID" ] && [ -r "/proc/$A_DAEMON_PID/environ" ]; then
    if tr '\0' '\n' < "/proc/$A_DAEMON_PID/environ" | grep -q '^CLAUDE_CODE_OAUTH_TOKEN='; then
      A_DAEMON_TOKEN="yes"
    else
      A_DAEMON_TOKEN="no"
    fi
  fi

  # Stored login, looked at without the token so its own expiry shows.
  local js
  js="$(env -u CLAUDE_CODE_OAUTH_TOKEN claude auth status 2>/dev/null || true)"
  A_LOGGED_IN="$(jq -r '.loggedIn // false' <<< "$js" 2>/dev/null || echo false)"
  A_LOGIN_EXPIRES="$(jq -r '.loginExpiresAt // empty' <<< "$js" 2>/dev/null || true)"
  A_LOGIN_DAYS=""
  if [ -n "$A_LOGIN_EXPIRES" ]; then
    A_LOGIN_DAYS=$(( ( $(date -d "$A_LOGIN_EXPIRES" +%s) - $(date +%s) ) / 86400 ))
  fi

  # Tasks whose *last* run failed to authenticate; clears by itself once the
  # task has run successfully again (`claudissimo task run NAME` to force it).
  source "$LIB_DIR/tasks.sh"
  A_FAILING_TASKS=""; A_RECENT_FAILS=0
  local task service
  while IFS= read -r task; do
    [ -n "$task" ] || continue
    service="claudissimo-task-$task.service"
    [ "$(systemctl --user show "$service" -p Result --value 2>/dev/null)" = "exit-code" ] || continue
    if journalctl --user -u "$service" --since "$AUTH_FAIL_WINDOW" --no-pager -o cat 2>/dev/null \
         | grep -q 'Failed to authenticate'; then
      A_FAILING_TASKS="$A_FAILING_TASKS $task"
      A_RECENT_FAILS=$((A_RECENT_FAILS + 1))
    fi
  done < <(list_task_names)
}

# Real end-to-end probe: one tiny request with the credentials the sessions
# actually use (token if the daemon has it, otherwise the stored login),
# whatever this shell's own environment looks like. Costs a request, so only
# on demand. The token goes into a subshell's environment, never an argv.
auth_probe() {
  local out line
  out="$(
    if [ "$A_DAEMON_TOKEN" = "yes" ] && line="$(grep -m1 '^CLAUDE_CODE_OAUTH_TOKEN=' "$AUTH_ENV_FILE" 2>/dev/null)"; then
      export "$line"
    else
      unset CLAUDE_CODE_OAUTH_TOKEN
    fi
    timeout 90 claude -p "Reply with exactly: ok" 2>&1 </dev/null || true
  )"
  [[ "$out" == *ok* ]] && [[ "$out" != *"Not logged in"* ]] && [[ "$out" != *"Failed to authenticate"* ]]
}

status_auth() {
  log_info "=== Authentication ==="
  auth_collect

  local runs_on
  case "$A_DAEMON_TOKEN" in
    yes) runs_on="1-year token" ;;
    no)  runs_on="stored claude.ai login" ;;
    *)   runs_on="unknown (daemon not running)" ;;
  esac
  printf '  %-22s %s\n' "Sessions run on:" "$runs_on"

  if [ "$A_TOKEN_FILE" = 1 ]; then
    printf '  %-22s %s\n' "Token file:" "present, $A_TOKEN_AGE_DAYS days old (valid 1 year)"
  else
    printf '  %-22s %s\n' "Token file:" "not set up"
  fi

  if [ "$A_LOGGED_IN" = true ] && [ -n "$A_LOGIN_DAYS" ]; then
    printf '  %-22s %s\n' "Stored login:" "expires ${A_LOGIN_EXPIRES%%T*} ($A_LOGIN_DAYS days)"
  elif [ "$A_LOGGED_IN" = true ]; then
    printf '  %-22s %s\n' "Stored login:" "logged in, no expiry reported"
  else
    printf '  %-22s %s\n' "Stored login:" "not logged in"
  fi

  if [ "$A_RECENT_FAILS" -gt 0 ] 2>/dev/null; then
    printf '  %-22s %s\n' "Task auth failures:" "last run failed to authenticate:$A_FAILING_TASKS"
  else
    printf '  %-22s %s\n' "Task auth failures:" "none"
  fi

  auth_hints
}

auth_hints() {
  if [ "$A_RECENT_FAILS" -gt 0 ] 2>/dev/null; then
    log_warn "authentication is failing for task(s):$A_FAILING_TASKS. Renew it (claudissimo auth), then restart the sessions (claudissimo auth restart) — a renewed login does not reach sessions that are already running."
  fi
  if [ "$A_TOKEN_FILE" = 1 ] && [ "$A_DAEMON_TOKEN" = "no" ]; then
    log_warn "a token is set up, but the running daemon was started without it, so the sessions still use the stored login. Run: claudissimo auth restart"
  fi
  if [ "$A_DAEMON_TOKEN" != "yes" ]; then
    if [ "$A_LOGGED_IN" != true ]; then
      log_warn "not logged in at all. Run: claudissimo auth"
    elif [ -n "$A_LOGIN_DAYS" ] && [ "$A_LOGIN_DAYS" -le "$AUTH_WARN_DAYS" ]; then
      log_warn "the stored login runs out in $A_LOGIN_DAYS day(s) and cannot be renewed; after that sessions and tasks stop working. Run: claudissimo auth (sets up a 1-year token)"
    fi
  fi
  if [ "$A_DAEMON_TOKEN" = "yes" ] && [ -n "$A_TOKEN_AGE_DAYS" ] && [ "$A_TOKEN_AGE_DAYS" -ge 335 ]; then
    log_warn "the token is $A_TOKEN_AGE_DAYS days old and valid for 1 year. Renew it: claudissimo auth"
  fi
}

# Sets up (or replaces) the 1-year token. The token is typed in by the user,
# checked with a real request against an empty config dir, and written to a
# file only the user can read. It is never echoed, logged or put on a command line.
auth_set_token() {
  log_info "=== Set up a 1-year token ==="
  log_info "Sessions and scheduled tasks then no longer depend on the stored login,"
  log_info "which has a hard time limit (about 4 weeks) and cannot be renewed."
  log_info ""
  local reply
  read -r -p "Run 'claude setup-token' now? It opens a sign-in and prints the token once. [Y/n] " reply
  if [[ ! "$reply" =~ ^[Nn]$ ]]; then
    claude setup-token || { log_err "claude setup-token failed"; return 1; }
  fi

  local token
  read -rs -p "Paste the token (starts with sk-ant-oat01-, input is hidden, empty to cancel): " token
  printf '\n'
  token="${token//[[:space:]]/}"
  if [ -z "$token" ]; then
    log_skip "cancelled"
    return 0
  fi
  if ! [[ "$token" =~ ^sk-ant-oat01-[A-Za-z0-9_-]{40,}$ ]]; then
    log_err "that doesn't look like a token (expected sk-ant-oat01-…, about 108 characters). Note the code from the sign-in page is not the token — the token is printed afterwards."
    return 1
  fi

  log_info "checking the token with a real request…"
  local tmp out
  tmp="$(mktemp -d)"
  out="$(CLAUDE_CONFIG_DIR="$tmp" CLAUDE_CODE_OAUTH_TOKEN="$token" timeout 90 claude -p "Reply with exactly: ok" 2>&1 </dev/null || true)"
  rm -rf "$tmp"
  if [[ "$out" != *ok* ]] || [[ "$out" == *"Not logged in"* ]]; then
    log_err "the token was rejected — nothing was written."
    return 1
  fi

  mkdir -p "$(dirname "$AUTH_ENV_FILE")"
  ( umask 077; printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$token" > "$AUTH_ENV_FILE.new" )
  chmod 600 "$AUTH_ENV_FILE.new"
  mv "$AUTH_ENV_FILE.new" "$AUTH_ENV_FILE"
  token=""
  log_ok "token works and is stored in $AUTH_ENV_FILE (readable by you only)"
  log_info "It reaches new systemd services after the next reboot; the revive script also"
  log_info "loads it itself, so sessions started by it get it right away."
  log_info ""
  read -r -p "Restart the sessions now so they use it? [y/N] " reply
  if [[ "$reply" =~ ^[Yy]$ ]]; then
    auth_restart_sessions
  else
    log_info "Later: claudissimo auth restart"
  fi
}

# Stops the shared daemon (which ends all background sessions, their
# conversations are kept) and lets the revive script bring everything back
# with the current credentials. A plain `claude respawn` is not enough: the
# new process inherits the old daemon's environment.
auth_restart_sessions() {
  log_info "=== Restart sessions with current credentials ==="
  if [ -n "${CLAUDE_JOB_DIR:-}" ]; then
    log_err "this is running inside a Claude background session — restarting would end this very session. Run it from a normal SSH terminal."
    return 1
  fi
  local revive_script="$HOME/.local/bin/claude-agents-revive.sh"
  if [ ! -x "$revive_script" ]; then
    log_err "$revive_script not found — run 'setup' first"
    return 1
  fi
  log_warn "every running session is stopped and restarted; an answer being written right now is aborted (the conversation stays)."
  local reply
  read -r -p "Continue? [y/N] " reply
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    log_skip "cancelled"
    return 0
  fi
  claude daemon stop --any || true
  sleep 2
  bash "$revive_script"
  log_info ""
  status_auth
}

action_auth() {
  case "${1:-}" in
    token)   auth_set_token ;;
    restart) auth_restart_sessions ;;
    "")
      status_auth
      while true; do
        printf '\nAuthentication\n'
        printf '  1) Set up or replace the 1-year token\n'
        printf '  2) Restart sessions with the current credentials\n'
        printf '  b) Back\n'
        local choice
        read -r -p 'Choose: ' choice
        case "$choice" in
          1) auth_set_token ;;
          2) auth_restart_sessions ;;
          b|B) break ;;
          *) log_warn "unknown choice: $choice" ;;
        esac
      done
      ;;
    *) log_err "unknown auth target: $1 (expected: token|restart)"; return 1 ;;
  esac
}
