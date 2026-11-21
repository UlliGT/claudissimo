#!/usr/bin/env bash
# Monitoring check: one line, Nagios-style exit codes (0 OK, 1 WARNING,
# 2 CRITICAL). Read-only; makes no API request unless --probe is given.

action_check() {
  local probe=0
  [ "${1:-}" = "--probe" ] && probe=1

  local crit=() warn=()
  source "$LIB_DIR/auth.sh"
  source "$LIB_DIR/tasks.sh"

  # Sessions: alive means a running claude process behind the pid.
  local total=0 dead=0 dead_names="" agents_json id name pid started
  agents_json="$(claude agents --json --all 2>/dev/null || echo '[]')"
  while IFS=$'\t' read -r id name pid started; do
    [ -n "$id" ] || continue
    total=$((total + 1))
    if ! is_claude_pid_alive "$pid"; then
      # a session started in the last two minutes may not have its pid yet
      if [ -n "$started" ] && [ $(( $(date +%s) - started / 1000 )) -lt 120 ]; then
        continue
      fi
      dead=$((dead + 1)); dead_names="$dead_names $name"
    fi
  done < <(jq -r '.[] | [.id, .name, (.pid // 0), (.startedAt // 0)] | @tsv' <<< "$agents_json" 2>/dev/null)
  [ "$dead" -gt 0 ] && crit+=("$dead of $total sessions not running:$dead_names")

  # Keepalive machinery.
  systemctl --user is-active --quiet claude-agents.timer 2>/dev/null \
    || crit+=("revive timer (claude-agents.timer) is not active")

  # Authentication.
  auth_collect
  if [ "$A_RECENT_FAILS" -gt 0 ] 2>/dev/null; then
    crit+=("authentication failed in last run of task(s):$A_FAILING_TASKS")
  fi
  if [ "$A_DAEMON_TOKEN" = "yes" ]; then
    if [ -n "$A_TOKEN_AGE_DAYS" ] && [ "$A_TOKEN_AGE_DAYS" -ge 365 ]; then
      crit+=("token is $A_TOKEN_AGE_DAYS days old (valid 1 year)")
    elif [ -n "$A_TOKEN_AGE_DAYS" ] && [ "$A_TOKEN_AGE_DAYS" -ge 335 ]; then
      warn+=("token is $A_TOKEN_AGE_DAYS days old (valid 1 year)")
    fi
  else
    if [ "$A_LOGGED_IN" != true ]; then
      crit+=("not logged in")
    elif [ -n "$A_LOGIN_DAYS" ] && [ "$A_LOGIN_DAYS" -lt 0 ]; then
      crit+=("stored login expired")
    elif [ -n "$A_LOGIN_DAYS" ] && [ "$A_LOGIN_DAYS" -le "$AUTH_WARN_DAYS" ]; then
      warn+=("stored login expires in $A_LOGIN_DAYS day(s); sign in again (claude auth login) and run: claudissimo auth restart")
    fi
  fi
  if [ "$probe" = 1 ] && ! auth_probe; then
    crit+=("authentication probe failed")
  fi

  # Scheduled tasks: last run failed, or timer without a next run.
  local task timer_unit service_unit next
  while IFS= read -r task; do
    [ -n "$task" ] || continue
    service_unit="claudissimo-task-$task.service"
    timer_unit="claudissimo-task-$task.timer"
    if [ "$(systemctl --user show "$service_unit" -p Result --value 2>/dev/null)" = "exit-code" ]; then
      warn+=("task '$task': last run failed")
    fi
    next="$(systemctl --user list-timers "$timer_unit" --no-pager 2>/dev/null | awk 'NR==2 {print $1}')"
    if [ "$next" = "-" ] && ! systemctl --user is-active --quiet "$service_unit"; then
      warn+=("task '$task': timer has no next run (the revive timer fixes this within 15 min)")
    fi
  done < <(list_task_names)

  local perf="sessions=$total sessions_dead=$dead login_days=${A_LOGIN_DAYS:-U} token_age_days=${A_TOKEN_AGE_DAYS:-U} auth_failures=$A_RECENT_FAILS"
  local msg code label
  if [ "${#crit[@]}" -gt 0 ]; then
    code=2; label="CRITICAL"
    msg="$(IFS=';'; echo "${crit[*]}${warn[*]:+; ${warn[*]}}")"
  elif [ "${#warn[@]}" -gt 0 ]; then
    code=1; label="WARNING"
    msg="$(IFS=';'; echo "${warn[*]}")"
  else
    code=0; label="OK"
    local mode="stored login"
    [ "$A_DAEMON_TOKEN" = "yes" ] && mode="token"
    msg="$total sessions alive, auth via $mode"
  fi
  printf 'claudissimo %s - %s | %s\n' "$label" "$msg" "$perf"
  return "$code"
}
