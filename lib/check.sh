#!/usr/bin/env bash
# Monitoring check: one line, Nagios-style exit codes (0 OK, 1 WARNING,
# 2 CRITICAL). Read-only; makes no API request unless --probe is given.

# Dead sessions are given this long to come back (revive timer ~6 min plus a
# push interval); a previous check older than the window means we can't tell.
CHECK_DEAD_GRACE=900
CHECK_CONTINUOUS_WINDOW=1800

action_check() {
  local probe=0 push=0 arg
  for arg in "$@"; do
    case "$arg" in
      --probe) probe=1 ;;
      --push)  push=1 ;;
      *) log_err "unknown option: $arg (expected: --probe, --push)"; return 3 ;;
    esac
  done

  local crit=() warn=()
  source "$LIB_DIR/auth.sh"
  source "$LIB_DIR/tasks.sh"

  # Sessions: alive means a running claude process behind the pid.
  # A session that is dead is normal for a while: the daemon retires sessions
  # that were idle for 8 hours, and the revive timer (every ~6 min) brings
  # them back. So a dead session only counts once it has stayed dead longer
  # than that. "Since when" comes from our own state, which is only
  # trustworthy if the previous check was recent (monitoring pushes every few
  # minutes); otherwise a dead session is reported at once.
  local state_dir="${CLAUDISSIMO_STATE_DIR:-$HOME/.local/state/claudissimo}"
  local now; now="$(date +%s)"
  local prev_check=0 continuous=0 sid first
  declare -A dead_since=() still_dead=()
  mkdir -p "$state_dir"
  [ -f "$state_dir/last_check" ] && read -r prev_check < "$state_dir/last_check" || true
  [ $((now - ${prev_check:-0})) -le "$CHECK_CONTINUOUS_WINDOW" ] && continuous=1
  if [ -f "$state_dir/dead_since" ]; then
    while read -r sid first; do [ -n "$sid" ] && dead_since[$sid]="$first"; done < "$state_dir/dead_since"
  fi

  local total=0 dead=0 restarting=0 dead_names="" restarting_names="" agents_json id name pid started
  if ! agents_json="$(claude agents --json --all 2>/dev/null)" || ! jq -e 'type == "array"' <<< "$agents_json" >/dev/null 2>&1; then
    warn+=("could not list sessions (claude agents failed)")
    agents_json='[]'
  fi
  while IFS=$'\t' read -r id name pid started; do
    [ -n "$id" ] || continue
    total=$((total + 1))
    if ! is_claude_pid_alive "$pid"; then
      # a session started in the last two minutes may not have its pid yet
      if [ -n "$started" ] && [ $((now - started / 1000)) -lt 120 ]; then
        continue
      fi
      if [ "$continuous" = 1 ]; then
        first="${dead_since[$id]:-$now}"
      else
        first=0

      fi
      still_dead[$id]="$first"
      if [ "$first" -gt 0 ] && [ $((now - first)) -lt "$CHECK_DEAD_GRACE" ]; then
        restarting=$((restarting + 1)); restarting_names="$restarting_names $name"
      else
        dead=$((dead + 1)); dead_names="$dead_names $name"
      fi
    fi
  done < <(jq -r '.[] | [.id, .name, (.pid // 0), (.startedAt // 0)] | @tsv' <<< "$agents_json" 2>/dev/null)
  : > "$state_dir/dead_since"
  for sid in "${!still_dead[@]}"; do printf '%s %s\n' "$sid" "${still_dead[$sid]}" >> "$state_dir/dead_since"; done
  printf '%s\n' "$now" > "$state_dir/last_check"
  [ "$dead" -gt 0 ] && crit+=("$dead of $total sessions not running:$dead_names")
  if [ "$total" -eq 0 ] && [ "${#warn[@]}" -eq 0 ]; then
    warn+=("no background sessions at all")
  fi

  # Keepalive machinery.
  systemctl --user is-active --quiet claude-agents.timer 2>/dev/null \
    || crit+=("revive timer (claude-agents.timer) is not active")

  # Authentication.
  auth_collect
  if [ "$A_RECENT_FAILS" -gt 0 ] 2>/dev/null; then
    crit+=("authentication failed in last run of task(s):$A_FAILING_TASKS")
  fi
  if [ "$A_LOGGED_IN" != true ]; then
    crit+=("not logged in")
  elif [ -n "$A_LOGIN_DAYS" ] && [ "$A_LOGIN_DAYS" -lt 0 ]; then
    crit+=("login expired")
  elif [ -n "$A_LOGIN_DAYS" ] && [ "$A_LOGIN_DAYS" -le "$AUTH_WARN_DAYS" ]; then
    warn+=("login expires in $A_LOGIN_DAYS day(s); sign in again (claudissimo auth login)")
  fi
  # The real request: always with --probe; with --push at most once an hour
  # (and again on every push while the last one failed), otherwise a push
  # every few minutes would cost a request each time.
  local state_file="$state_dir/probe" last_at=0 last_ok=0
  [ -f "$state_file" ] && read -r last_at last_ok < "$state_file" || true
  if [ "$probe" = 1 ] || { [ "$push" = 1 ] && { [ "$last_ok" != 1 ] || [ $((now - last_at)) -ge 3600 ]; }; }; then
    mkdir -p "$state_dir"
    if auth_probe; then last_ok=1; else last_ok=0; fi
    last_at="$now"
    printf '%s %s\n' "$last_at" "$last_ok" > "$state_file"
    probe=1
  fi
  if { [ "$probe" = 1 ] || [ "$push" = 1 ]; } && [ "$last_ok" != 1 ]; then
    crit+=("probe request failed (login, usage limit or network) at $(date -d "@$last_at" +%H:%M)")
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
    if [ "$next" = "-" ] && ! unit_is_running "$service_unit"; then
      warn+=("task '$task': timer has no next run (the revive timer fixes this within 5 min)")
    fi
  done < <(list_task_names)

  local perf="sessions=$total sessions_dead=$dead sessions_restarting=$restarting login_days=${A_LOGIN_DAYS:-U} auth_failures=$A_RECENT_FAILS"
  local msg code label
  if [ "${#crit[@]}" -gt 0 ]; then
    code=2; label="CRITICAL"
    msg="$(IFS=';'; echo "${crit[*]}${warn[*]:+; ${warn[*]}}")"
  elif [ "${#warn[@]}" -gt 0 ]; then
    code=1; label="WARNING"
    msg="$(IFS=';'; echo "${warn[*]}")"
  else
    code=0; label="OK"
    msg="$total sessions alive, login valid for ${A_LOGIN_DAYS:-?} days"
    [ "$restarting" -gt 0 ] && msg="$total sessions, $restarting restarting (idle-retired, the revive timer brings them back):$restarting_names; login valid for ${A_LOGIN_DAYS:-?} days"
  fi
  printf 'claudissimo %s - %s | %s\n' "$label" "$msg" "$perf"
  if [ "$push" = 1 ]; then
    source "$LIB_DIR/monitor.sh"
    monitor_push "$code" "$label" "$msg" "$perf"
  fi
  return "$code"
}
