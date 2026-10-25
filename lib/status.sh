#!/usr/bin/env bash
# Action 2: read-only status report. Changes nothing.

check_project_dir() {
  local dir="$1"
  printf '%s\n' "$(basename "$dir")"
  if [ ! -d "$dir/.git" ]; then
    printf '  not a git repo\n'
    return
  fi
  local bg_ok="no"
  if [ -f "$dir/.claude/settings.local.json" ] \
     && grep -q '"bgIsolation"[[:space:]]*:[[:space:]]*"none"' "$dir/.claude/settings.local.json"; then
    bg_ok="yes"
  fi
  printf '  bgIsolation none set: %s\n' "$bg_ok"
  local excluded="no"
  if [ -f "$dir/.git/info/exclude" ] && grep -qx '.claude/settings.local.json' "$dir/.git/info/exclude"; then
    excluded="yes"
  fi
  printf '  settings.local.json excluded from git: %s\n' "$excluded"
  local git_status
  git_status="$(git -C "$dir" status --porcelain 2>/dev/null)"
  if [ -z "$git_status" ]; then
    printf '  git status: clean\n'
  else
    printf '  git status: dirty (%s changed file(s))\n' "$(printf '%s\n' "$git_status" | grep -c .)"
  fi
}

status_projects() {
  log_info "=== Projects under $PROJECTS_ROOT ==="
  if [ -d "$PROJECTS_ROOT" ]; then
    local found=0
    for dir in "$PROJECTS_ROOT"/*/; do
      [ -d "$dir" ] || continue
      check_project_dir "${dir%/}"
      found=1
    done
    [ "$found" -eq 1 ] || log_info "(none found)"
  else
    log_warn "$PROJECTS_ROOT does not exist yet — run initial setup / create a project"
  fi
}

status_agents() {
  log_info "=== Claude Code background sessions ==="
  if require_cmd claude && require_cmd jq; then
    local agents_json count
    agents_json="$(claude agents --json --all 2>/dev/null || echo '[]')"
    count="$(printf '%s' "$agents_json" | jq 'length')"
    if [ "$count" -eq 0 ]; then
      log_info "(no sessions)"
    else
      printf '%s' "$agents_json" | jq -r '.[] | "\(.id)\t\(.state)\t\(.pid // "null")\t\(.cwd)"' \
      | while IFS=$'\t' read -r id state pid cwd; do
          local alive="dead"
          is_claude_pid_alive "$pid" && alive="alive"
          local flags=""
          [ "$pid" = "null" ] && flags="$flags [pid null]"
          case "$cwd" in
            "$PROJECTS_ROOT"/*) ;;
            *) flags="$flags [cwd outside $PROJECTS_ROOT — possible worktree]" ;;
          esac
          printf '  %s  state=%s  pid=%s  process=%s%s\n    cwd=%s\n' "$id" "$state" "$pid" "$alive" "$flags" "$cwd"
        done
    fi
  else
    log_warn "claude or jq not available"
  fi
}

status_service() {
  log_info "=== systemd revive service ==="
  if systemctl --user is-enabled claude-agents >/dev/null 2>&1; then
    log_ok "claude-agents service is enabled"
  else
    log_warn "claude-agents service is not enabled — run initial setup"
  fi
  systemctl --user status claude-agents --no-pager 2>&1 | sed 's/^/  /' || true

  log_info ""
  local linger
  linger="$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo unknown)"
  log_info "linger for $USER: $linger"
}

action_status() {
  case "${1:-all}" in
    projects) status_projects ;;
    agents)   status_agents ;;
    service)  status_service ;;
    all)      status_projects; log_info ""; status_agents; log_info ""; status_service ;;
    *)        log_err "unknown status target: $1 (expected: projects|agents|service|all)"; return 1 ;;
  esac
}
