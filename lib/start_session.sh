#!/usr/bin/env bash
# Action: start a background session in an already-existing project
# directory — for when the last session pointed at a project got removed
# (or died and was cleaned up) and there's nothing left to attach to.
# Unlike `new`, does not touch git, settings.local.json, or the trust
# prompt; the project already went through that once.

action_start_session() {
  log_info "=== Start session ==="

  if [ -d "$PROJECTS_ROOT" ]; then
    log_info "Existing projects under $PROJECTS_ROOT:"
    for dir in "$PROJECTS_ROOT"/*/; do
      [ -d "$dir" ] || continue
      printf '  %s\n' "$(basename "${dir%/}")"
    done
  fi

  local name
  read -r -p "Project name (empty to cancel/back): " name
  if [ -z "$name" ]; then
    log_skip "cancelled"
    return 0
  fi

  local target="$PROJECTS_ROOT/$name"
  if [ ! -d "$target" ]; then
    log_err "$target does not exist — use 'new' to create a project first"
    return 0
  fi

  local real_target
  real_target="$(cd "$target" && pwd -P)"

  if require_cmd claude && require_cmd jq; then
    local existing
    existing="$(claude agents --json --all 2>/dev/null \
      | jq -r --arg cwd "$real_target" '.[] | select(.cwd == $cwd) | "\(.id) (\(.state))"')"
    if [ -n "$existing" ]; then
      log_warn "This project already has a running session — starting a second one is risky:"
      printf '%s\n' "$existing" | sed 's/^/  /'
      log_warn "bgIsolation is \"none\": both sessions edit the exact same files"
      log_warn "directly, no worktree isolation. Claude Code's own docs don't"
      log_warn "protect against two sessions editing the same file at the same"
      log_warn "time — you can lose work this way."
      local confirm
      read -r -p "Start a second session anyway? [y/N] " confirm
      if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_skip "cancelled"
        return 0
      fi
    fi
  fi

  log_info "Starting background session..."
  (cd "$target" && claude --bg --name "$name" "This session is always remote-controlled from another device. Show the hostname, working directory, and git remote (if any), so the user immediately knows where this session's home is.")

  log_info ""
  log_info "=== sessions for $target ==="
  if require_cmd claude && require_cmd jq; then
    claude agents --json --all 2>/dev/null \
      | jq -r --arg cwd "$real_target" '.[] | select(.cwd == $cwd) | "\(.id)  \(.state)"'
  fi
}
