#!/usr/bin/env bash
# Action 2: read-only status report. Changes nothing.

check_project_dir() {
  local dir="$1" name
  name="$(basename "$dir")"
  if [ ! -d "$dir/.git" ]; then
    printf '  %-34s not a git repo\n' "$name"
    return
  fi

  local git_status git_label
  git_status="$(git -C "$dir" status --porcelain 2>/dev/null)"
  if [ -z "$git_status" ]; then
    git_label="clean"
  else
    git_label="dirty($(printf '%s\n' "$git_status" | grep -c .))"
  fi

  local flags=""
  if ! { [ -f "$dir/.claude/settings.local.json" ] \
       && grep -q '"bgIsolation"[[:space:]]*:[[:space:]]*"none"' "$dir/.claude/settings.local.json"; }; then
    flags="$flags [bgIsolation not set — background sessions may use a worktree]"
  fi
  if [ -f "$dir/.claude/settings.local.json" ] \
     && ! git -C "$dir" check-ignore -q .claude/settings.local.json 2>/dev/null; then
    flags="$flags [settings.local.json not excluded from git]"
  fi

  printf '  %-34s git: %-10s%s\n' "$name" "$git_label" "$flags"
}

status_projects() {
  log_info "=== Projects under $PROJECTS_ROOT ==="
  if [ -d "$PROJECTS_ROOT" ]; then
    local found=0
    for dir in "$PROJECTS_ROOT"/*/; do
      [ -d "$dir" ] || continue
      [ "$found" -eq 0 ] && printf '  %-34s %s\n' "NAME" "STATUS"
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
      printf '  %-10s %-9s %-7s %s\n' "ID" "STATE" "ALIVE" "PROJECT"
      printf '%s' "$agents_json" | jq -r '.[] | "\(.id)\t\(.state)\t\(.pid // "null")\t\(.cwd)"' \
      | while IFS=$'\t' read -r id state pid cwd; do
          local alive="dead"
          is_claude_pid_alive "$pid" && alive="alive"
          local proj="$cwd" flags=""
          case "$cwd" in
            "$PROJECTS_ROOT"/*) proj="${cwd#"$PROJECTS_ROOT"/}" ;;
            *) flags="$flags [cwd outside $PROJECTS_ROOT — possible worktree]" ;;
          esac
          [ "$pid" = "null" ] && flags="$flags [pid null]"
          printf '  %-10s %-9s %-7s %s%s\n' "$id" "$state" "$alive" "$proj" "$flags"
        done
    fi
  else
    log_warn "claude or jq not available"
  fi
}

status_revive_service() {
  log_info "=== systemd revive service (runs at boot) ==="
  if systemctl --user is-enabled claude-agents >/dev/null 2>&1; then
    log_ok "claude-agents service is enabled"
  else
    log_warn "claude-agents service is not enabled — run initial setup"
  fi
  systemctl --user status claude-agents --no-pager 2>&1 | sed 's/^/  /' || true

  log_info ""
  local linger
  linger="$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo unknown)"
  log_info "linger for $USER: $linger (lets claude-agents.service start at boot without logging in)"
}

status_revive_timer() {
  log_info "=== periodic revive timer (catches idle-stopped sessions, not just reboots) ==="
  if systemctl --user is-active claude-agents.timer >/dev/null 2>&1; then
    log_ok "claude-agents.timer is active"
  else
    log_warn "claude-agents.timer is not active — run initial setup"
  fi
  systemctl --user list-timers claude-agents.timer --no-pager 2>&1 | sed 's/^/  /' || true

  log_info ""
  log_info "--- last actual run of the triggered service ---"
  systemctl --user show claude-agents-revive.service -p ExecMainExitTimestamp 2>&1 | sed 's/^/  /'
}

status_memory() {
  log_info "=== Memory ==="

  local mem_total mem_used mem_pct bar_width=30 filled empty
  read -r mem_total mem_used < <(free -b 2>/dev/null | awk '/^Mem:/ {print $2, $3}')
  if [ -n "$mem_total" ] && [ "$mem_total" -gt 0 ]; then
    mem_pct=$(( mem_used * 100 / mem_total ))
    filled=$(( mem_pct * bar_width / 100 ))
    [ "$filled" -gt "$bar_width" ] && filled="$bar_width"
    empty=$(( bar_width - filled ))
    printf '  ['
    [ "$filled" -gt 0 ] && printf '%0.s█' $(seq 1 "$filled")
    [ "$empty" -gt 0 ] && printf '%0.s░' $(seq 1 "$empty")
    printf '] %d%%\n' "$mem_pct"
  fi

  free -h 2>/dev/null | sed 's/^/  /'
  local claude_mb
  claude_mb="$(ps -eo rss,cmd 2>/dev/null | grep -i claude | grep -v grep | awk '{sum+=$1} END {printf "%.0f", sum/1024+0}')"
  log_info "claude processes total: ${claude_mb:-0} MB (RSS, overlaps due to shared libraries — not purely additive)"
  log_info "Claude Code's own supervisor stops idle sessions sooner when memory runs low (code.claude.com/docs/en/agent-view.md) — that's what the revive timer is for."
}

status_versions() {
  log_info "=== Versions (what 'update' can refresh) ==="

  if require_cmd claude; then
    log_info "claude: $(claude --version 2>/dev/null || echo "unknown")"
  else
    log_warn "claude not installed"
  fi
  log_info "  (checking for a newer claude version means running 'update' — it installs immediately if one exists, there's no check-only mode)"

  log_info ""
  log_info "--- jq / git / curl ---"
  local pkg installed
  for pkg in jq git curl; do
    if require_cmd "$pkg"; then
      installed="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo unknown)"
      log_info "$pkg: $installed"
    else
      log_warn "$pkg not installed"
    fi
  done
  local upgradable
  upgradable="$(apt list --upgradable 2>/dev/null | grep -E '^(jq|git|curl)/' || true)"
  if [ -n "$upgradable" ]; then
    log_warn "upgrade available (run 'update' to apply):"
    printf '%s\n' "$upgradable" | sed 's/^/  /'
  else
    log_skip "no upgrade pending for jq/git/curl (based on the current apt cache — 'update' refreshes that cache first)"
  fi

  log_info ""
  log_info "--- deployed files vs this tool's current version ---"
  source "$LIB_DIR/setup.sh"
  local check_path
  for check_path in \
    "$HOME/.local/bin/claude-agents-revive.sh:$(revive_script_content)" \
    "$HOME/.config/systemd/user/claude-agents.service:$(systemd_unit_content)" \
    "$HOME/.config/systemd/user/claude-agents-revive.service:$(timer_service_content)" \
    "$HOME/.config/systemd/user/claude-agents.timer:$(timer_unit_content)"
  do
    local p="${check_path%%:*}" desired="${check_path#*:}"
    if [ -f "$p" ]; then
      if [ "$(cat "$p")" = "$desired" ]; then
        log_skip "$p matches"
      else
        log_warn "$p differs — run 'update' to refresh"
      fi
    else
      log_warn "$p not deployed yet — run 'setup'"
    fi
  done

  log_info ""
  log_info "--- this checkout ($REPO_ROOT) vs its remote ---"
  if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_skip "not a git checkout — can't check for a newer claudissimo (re-download to get one)"
  elif ! git -C "$REPO_ROOT" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    log_skip "no upstream configured for this checkout — can't check for a newer claudissimo"
  else
    local upstream behind
    upstream="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref '@{u}')"
    if git -C "$REPO_ROOT" fetch --quiet 2>/dev/null; then
      behind="$(git -C "$REPO_ROOT" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)"
      if [ "$behind" -gt 0 ]; then
        log_warn "$behind commit(s) behind $upstream — run 'git pull' here, then 'update' to apply"
      else
        log_skip "up to date with $upstream"
      fi
    else
      log_warn "couldn't reach $upstream to check for updates (offline?)"
    fi
  fi
}

action_status() {
  case "${1:-all}" in
    projects) status_projects ;;
    agents)   status_agents ;;
    service)  status_revive_service ;;
    timer)    status_revive_timer ;;
    memory)   status_memory ;;
    versions) status_versions ;;
    all)
      status_projects; log_info ""
      status_agents; log_info ""
      status_revive_service; log_info ""
      status_revive_timer; log_info ""
      status_memory; log_info ""
      status_versions
      ;;
    *)
      log_err "unknown status target: $1 (expected: projects|agents|service|timer|memory|versions|all)"
      return 1
      ;;
  esac
}
