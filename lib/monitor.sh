#!/usr/bin/env bash
# Monitoring: pushes the result of `claudissimo check` to Uptime Kuma (push
# monitor) and/or any webhook receiver (JSON POST, e.g. Home Assistant), on a
# systemd timer, configured
# from the menu. A push model on purpose: if the host or the timer dies, the
# pushes stop and Uptime Kuma alarms by itself — a pull over SSH can't say
# anything about a host that is down.
#
# The push URLs contain a secret (Kuma's token, HA's webhook id), so they
# live in a file only the user can read and never appear on a command line
# (curl reads its URL from stdin).

MONITOR_CONF="${CLAUDISSIMO_MONITOR_CONF:-$HOME/.config/claudissimo/monitoring.conf}"
MONITOR_UNIT_DIR="$HOME/.config/systemd/user"
MONITOR_TIMER="claudissimo-monitor.timer"
MONITOR_SERVICE="claudissimo-monitor.service"

monitor_conf_get() {
  [ -f "$MONITOR_CONF" ] || return 0
  sed -n "s/^$1=//p" "$MONITOR_CONF" | head -1
}

monitor_conf_set() {
  local key="$1" value="$2" tmp
  mkdir -p "$(dirname "$MONITOR_CONF")"
  tmp="$(umask 077; mktemp "$MONITOR_CONF.XXXXXX")"
  [ -f "$MONITOR_CONF" ] && grep -v "^$key=" "$MONITOR_CONF" > "$tmp" || true
  [ -n "$value" ] && printf '%s=%s\n' "$key" "$value" >> "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$MONITOR_CONF"
}

monitor_host_of() { sed -E 's#^[a-zA-Z]+://([^/:?]+).*#\1#' <<< "$1"; }

# Sends a request with the URL taken from stdin, so it stays off the
# process list. Prints the HTTP status code, or 000 if unreachable.
monitor_curl() {
  local url="$1"; shift
  printf 'url = "%s"\n' "$url" | curl -sS -m 15 -o /dev/null -w '%{http_code}' -K - "$@" 2>/dev/null || true
}

# monitor_push <exit code> <label> <message> <perfdata>
monitor_push() {
  local code="$1" label="$2" msg="$3" perf="$4" url http status payload
  local kuma ha
  kuma="$(monitor_conf_get KUMA_PUSH_URL)"
  ha="$(monitor_conf_get WEBHOOK_URL)"
  if [ -z "$kuma" ] && [ -z "$ha" ]; then
    log_skip "no monitoring target set up (menu: Setup & maintenance > Monitoring)"
    return 0
  fi

  if [ -n "$kuma" ]; then
    # Kuma only knows up/down: a warning counts as down, so it alarms too.
    status=up; [ "$code" -gt 0 ] && status=down
    url="$kuma?status=$status&msg=$(jq -rn --arg s "${label} - ${msg}" '$s[0:200] | @uri')"
    http="$(monitor_curl "$url")"
    if [ "$http" = "200" ]; then log_ok "Uptime Kuma: pushed $status"; else log_warn "Uptime Kuma: push failed (HTTP $http)"; fi
  fi

  if [ -n "$ha" ]; then
    payload="$(jq -n --argjson code "$code" --arg label "$label" --arg message "$msg" --arg perf "$perf" \
      '{code:$code, status:($label|ascii_downcase), message:$message, perfdata:$perf, source:"claudissimo"}')"
    http="$(monitor_curl "$ha" -X POST -H 'Content-Type: application/json' --data-binary "$payload")"
    if [[ "$http" =~ ^2 ]]; then log_ok "Webhook: sent"; else log_warn "Webhook: failed (HTTP $http)"; fi
  fi
}

monitor_timer_state() {
  if systemctl --user is-active --quiet "$MONITOR_TIMER" 2>/dev/null; then
    echo "active, every $(monitor_conf_get INTERVAL_MINUTES) min"
  elif [ -f "$MONITOR_UNIT_DIR/$MONITOR_TIMER" ]; then
    echo "installed but not active"
  else
    echo "not installed"
  fi
}

monitor_service_content() {
  cat <<EOF
[Unit]
Description=Push claudissimo check result to the monitoring targets

[Service]
Type=oneshot
SuccessExitStatus=1 2
ExecStart=$REPO_ROOT/bin/claudissimo check --push
EOF
}

# OnBootSec gives the timer a reference after every reboot (OnUnitActiveSec
# alone is lost with the systemd instance); no OnActiveSec, which would fire
# again on every daemon-reload.
monitor_timer_content() {
  cat <<EOF
[Unit]
Description=Periodic claudissimo monitoring push

[Timer]
OnBootSec=2min
OnUnitActiveSec=$1min
Unit=$MONITOR_SERVICE

[Install]
WantedBy=timers.target
EOF
}

monitor_ask_url() {
  local key="$1" label="$2" hint="$3" url
  log_info "$hint"
  read -r -p "$label (empty to cancel, '-' to remove): " url
  [ -n "$url" ] || { log_skip "cancelled"; return 0; }
  if [ "$url" = "-" ]; then
    monitor_conf_set "$key" ""
    log_ok "removed"
    return 0
  fi
  if ! [[ "$url" =~ ^https?://[^[:space:]]+$ ]]; then
    log_err "that doesn't look like an http(s) URL"
    return 1
  fi
  [ "$key" = KUMA_PUSH_URL ] && url="${url%%\?*}"
  monitor_conf_set "$key" "$url"
  log_ok "saved for $(monitor_host_of "$url") (the full URL is kept in $MONITOR_CONF, readable by you only)"
}

monitor_enable_timer() {
  local current interval
  current="$(monitor_conf_get INTERVAL_MINUTES)"; current="${current:-5}"
  read -r -p "Push every how many minutes? [$current] " interval
  interval="${interval:-$current}"
  if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 1 ] || [ "$interval" -gt 60 ]; then
    log_err "needs to be a whole number between 1 and 60"
    return 1
  fi
  monitor_conf_set INTERVAL_MINUTES "$interval"
  printf '%s\n' "$(monitor_service_content)" > "$MONITOR_UNIT_DIR/$MONITOR_SERVICE"
  printf '%s\n' "$(monitor_timer_content "$interval")" > "$MONITOR_UNIT_DIR/$MONITOR_TIMER"
  systemctl --user daemon-reload
  systemctl --user enable "$MONITOR_TIMER" >/dev/null 2>&1
  systemctl --user restart "$MONITOR_TIMER"
  log_ok "timer active: pushes every $interval min, first one 2 min after boot"
  log_info "In Uptime Kuma set the push monitor's heartbeat interval to at least $((interval * 2 + 1)) min."
}

monitor_disable_timer() {
  systemctl --user disable --now "$MONITOR_TIMER" 2>/dev/null || true
  rm -f "$MONITOR_UNIT_DIR/$MONITOR_TIMER" "$MONITOR_UNIT_DIR/$MONITOR_SERVICE"
  systemctl --user daemon-reload
  log_ok "timer removed"
}

monitor_status() {
  local kuma ha kuma_txt="not set" ha_txt="not set"
  kuma="$(monitor_conf_get KUMA_PUSH_URL)"; ha="$(monitor_conf_get WEBHOOK_URL)"
  [ -n "$kuma" ] && kuma_txt="set ($(monitor_host_of "$kuma"))"
  [ -n "$ha" ] && ha_txt="set ($(monitor_host_of "$ha"))"
  printf '  %-26s %s\n' "Uptime Kuma push URL:" "$kuma_txt"
  printf '  %-26s %s\n' "Webhook (JSON):" "$ha_txt"
  printf '  %-26s %s\n' "Timer:" "$(monitor_timer_state)"
}

action_monitoring() {
  log_info "=== Monitoring ==="
  while true; do
    monitor_status
    printf '\nMonitoring\n'
    printf '  1) Set Uptime Kuma push URL\n'
    printf '  2) Set webhook URL (JSON POST)\n'
    printf '  3) Send a test push now\n'
    printf '  4) Turn on / change the timer\n'
    printf '  5) Turn off the timer\n'
    printf '  b) Back\n'
    local choice
    read -r -p 'Choose: ' choice
    case "$choice" in
      1) monitor_ask_url KUMA_PUSH_URL "Push URL" "In Uptime Kuma: Add New Monitor > type 'Push', then paste the Push URL it shows (the part after ? is dropped)." ;;
      2) monitor_ask_url WEBHOOK_URL "Webhook URL" "Any service that accepts a JSON POST works. Home Assistant: create an automation with a webhook trigger and paste its URL, e.g. http://homeassistant.local:8123/api/webhook/<id>." ;;
      3) "$REPO_ROOT/bin/claudissimo" check --push || true ;;
      4) monitor_enable_timer ;;
      5) monitor_disable_timer ;;
      b|B) break ;;
      *) log_warn "unknown choice: $choice" ;;
    esac
    log_info ""
  done
}
