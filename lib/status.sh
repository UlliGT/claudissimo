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
  local revive_path="$HOME/.local/bin/claude-agents-revive.sh"
  local unit_path="$HOME/.config/systemd/user/claude-agents.service"
  if [ -f "$revive_path" ]; then
    if [ "$(cat "$revive_path")" = "$(revive_script_content)" ]; then
      log_skip "$revive_path matches"
    else
      log_warn "$revive_path differs — run 'update' to refresh"
    fi
  else
    log_warn "$revive_path not deployed yet — run 'setup'"
  fi
  if [ -f "$unit_path" ]; then
    if [ "$(cat "$unit_path")" = "$(systemd_unit_content)" ]; then
      log_skip "$unit_path matches"
    else
      log_warn "$unit_path differs — run 'update' to refresh"
    fi
  else
    log_warn "$unit_path not deployed yet — run 'setup'"
  fi

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
    service)  status_service ;;
    versions) status_versions ;;
    all)      status_projects; log_info ""; status_agents; log_info ""; status_service; log_info ""; status_versions ;;
    *)        log_err "unknown status target: $1 (expected: projects|agents|service|versions|all)"; return 1 ;;
  esac
}
