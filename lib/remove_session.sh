#!/usr/bin/env bash
# Action: remove a background session from Claude Code's own list
# (`claude rm`) — not just stop it. A merely stopped session is still
# listed and still gets picked up and respawned by the revive
# script/timer; `rm` is the documented way to make one stay gone. Warns
# first if it's the only session pointed at its project folder.

action_remove_session() {
  log_info "=== Remove session ==="

  if ! require_cmd claude || ! require_cmd jq; then
    log_err "claude or jq not available"
    return 1
  fi

  local agents_json count
  agents_json="$(claude agents --json --all 2>/dev/null || echo '[]')"
  count="$(printf '%s' "$agents_json" | jq 'length')"
  if [ "$count" -eq 0 ]; then
    log_info "(no sessions)"
    return 0
  fi

  printf '  %-10s %-9s %-7s %s\n' "ID" "STATE" "ALIVE" "PROJECT"
  printf '%s' "$agents_json" | jq -r '.[] | "\(.id)\t\(.state)\t\(.pid // "null")\t\(.cwd)"' \
  | while IFS=$'\t' read -r id state pid cwd; do
      local alive="dead"
      is_claude_pid_alive "$pid" && alive="alive"
      local proj="${cwd#"$PROJECTS_ROOT"/}"
      printf '  %-10s %-9s %-7s %s\n' "$id" "$state" "$alive" "$proj"
    done

  local id
  read -r -p "Session id to remove: " id
  if [ -z "$id" ]; then
    log_err "empty id — aborting"
    return 0
  fi

  local entry
  entry="$(printf '%s' "$agents_json" | jq -r --arg id "$id" '[.[] | select(.id == $id)] | .[0] // empty')"
  if [ -z "$entry" ]; then
    log_err "no session with id $id — aborting"
    return 0
  fi

  local cwd pid
  cwd="$(printf '%s' "$entry" | jq -r '.cwd')"
  pid="$(printf '%s' "$entry" | jq -r '.pid // empty')"

  local same_cwd_count
  same_cwd_count="$(printf '%s' "$agents_json" | jq --arg cwd "$cwd" '[.[] | select(.cwd == $cwd)] | length')"
  if [ "$same_cwd_count" -le 1 ]; then
    log_warn "this is the only session for $cwd — removing it leaves that project with no background session at all"
  fi

  local confirm
  read -r -p "Remove session $id? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log_skip "cancelled"
    return 0
  fi

  if [ -n "$pid" ] && is_claude_pid_alive "$pid"; then
    claude stop "$id" 2>/dev/null || true
  fi
  claude rm "$id"
  log_ok "removed $id"
}
