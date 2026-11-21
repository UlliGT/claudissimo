#!/usr/bin/env bash
# Authentication: how long the login lasts and how to renew it. Shared by
# `status auth`, `check` and `auth`.
#
# Learned the hard way: the stored claude.ai login has a hard time limit
# (about 4 weeks) and cannot be renewed. When it runs out, sessions keep
# running but are useless, and a re-login does not reach processes that are
# already running — the revive script skips them because their pid is alive.
# They only recover after the daemon is restarted. A 1-year token
# (`claude setup-token`) was tried and dropped: while a stored login exists
# the daemon starts without it, and a token-only session did not show up
# under Remote Control.

AUTH_WARN_DAYS=7
AUTH_FAIL_WINDOW="2 days ago"

# Fills A_* globals. Read-only, no API calls.
auth_collect() {
  local js
  js="$(claude auth status 2>/dev/null || true)"
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

# Real end-to-end probe: one tiny request, the way a fresh service would
# authenticate. Costs a request, so only on demand.
auth_probe() {
  local out
  out="$(timeout 90 claude -p "Reply with exactly: ok" 2>&1 </dev/null || true)"
  [[ "$out" == *ok* ]] && [[ "$out" != *"Not logged in"* ]] && [[ "$out" != *"Failed to authenticate"* ]]
}

status_auth() {
  log_info "=== Authentication ==="
  auth_collect

  if [ "$A_LOGGED_IN" = true ] && [ -n "$A_LOGIN_DAYS" ]; then
    printf '  %-22s %s\n' "Login:" "expires ${A_LOGIN_EXPIRES%%T*} ($A_LOGIN_DAYS days)"
  elif [ "$A_LOGGED_IN" = true ]; then
    printf '  %-22s %s\n' "Login:" "logged in, no expiry reported"
  else
    printf '  %-22s %s\n' "Login:" "not logged in"
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
    log_warn "authentication is failing for task(s):$A_FAILING_TASKS. Sign in again (claudissimo auth login), then restart the sessions (claudissimo auth restart)."
  elif [ "$A_LOGGED_IN" != true ]; then
    log_warn "not logged in. Run: claudissimo auth login"
  elif [ -n "$A_LOGIN_DAYS" ] && [ "$A_LOGIN_DAYS" -le "$AUTH_WARN_DAYS" ]; then
    log_warn "the login runs out in $A_LOGIN_DAYS day(s) and cannot be renewed; after that sessions and scheduled tasks stop working. Sign in again: claudissimo auth login"
  fi
}

# Signs in again, then offers the restart the running sessions need.
auth_login() {
  log_info "=== Sign in again ==="
  claude auth login || { log_err "claude auth login failed"; return 1; }
  log_ok "signed in"
  log_info "Sessions that are already running keep their old, possibly expired credentials."
  local reply
  read -r -p "Restart the sessions now so they use the new login? [y/N] " reply
  if [[ "$reply" =~ ^[Yy]$ ]]; then
    auth_restart_sessions
  else
    log_info "Later: claudissimo auth restart"
  fi
}

# Stops the shared daemon (which ends all background sessions, their
# conversations are kept) and lets the revive script bring everything back
# with the current login. A plain `claude respawn` is not enough: the new
# process inherits the old daemon's state.
auth_restart_sessions() {
  log_info "=== Restart sessions with the current login ==="
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
    login)   auth_login ;;
    restart) auth_restart_sessions ;;
    "")
      status_auth
      while true; do
        printf '\nAuthentication\n'
        printf '  1) Sign in again (claude auth login)\n'
        printf '  2) Restart sessions with the current login\n'
        printf '  b) Back\n'
        local choice
        read -r -p 'Choose: ' choice
        case "$choice" in
          1) auth_login ;;
          2) auth_restart_sessions ;;
          b|B) break ;;
          *) log_warn "unknown choice: $choice" ;;
        esac
      done
      ;;
    *) log_err "unknown auth target: $1 (expected: login|restart)"; return 1 ;;
  esac
}
