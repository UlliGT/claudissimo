#!/usr/bin/env bash
# Action 5: completely remove a project — its directory under
# $PROJECTS_ROOT, its Claude Code metadata under ~/.claude/projects/
# (session history, memory), and any background session still pointing
# at it. Irreversible, so it asks you to re-type the project name.

action_delete_project() {
  log_info "=== Delete project ==="

  if [ -d "$PROJECTS_ROOT" ]; then
    log_info "Projects under $PROJECTS_ROOT:"
    for dir in "$PROJECTS_ROOT"/*/; do
      [ -d "$dir" ] || continue
      printf '  %s\n' "$(basename "${dir%/}")"
    done
  fi

  local name
  read -r -p "Project name to delete: " name
  if [ -z "$name" ]; then
    log_err "empty name — aborting"
    return 0
  fi

  local target="$PROJECTS_ROOT/$name"
  if [ ! -d "$target" ]; then
    log_err "$target does not exist — aborting"
    return 0
  fi

  local real_target claude_meta_dir
  real_target="$(cd "$target" && pwd -P)"
  claude_meta_dir="$HOME/.claude/projects/$(printf '%s' "$real_target" | tr '/' '-')"

  local sessions=""
  if require_cmd claude && require_cmd jq; then
    sessions="$(claude agents --json --all 2>/dev/null \
      | jq -r --arg cwd "$real_target" '.[] | select(.cwd == $cwd) | .id')"
  fi

  log_warn "This will permanently delete:"
  log_warn "  - $target (the whole project directory)"
  if [ -d "$claude_meta_dir" ]; then
    log_warn "  - $claude_meta_dir (session history and memory for this project)"
  fi
  if [ -n "$sessions" ]; then
    log_warn "  - stop and remove background session(s): $(printf '%s' "$sessions" | tr '\n' ' ')"
  fi
  log_warn "This cannot be undone."

  if [ -d "$target/.git" ]; then
    local dirty
    dirty="$(git -C "$target" status --porcelain 2>/dev/null)"
    if [ -n "$dirty" ]; then
      log_warn "uncommitted changes here would be lost — not pushed anywhere:"
      printf '%s\n' "$dirty" | sed 's/^/    /'
    fi
    if git -C "$target" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
      local upstream ahead
      upstream="$(git -C "$target" rev-parse --abbrev-ref '@{u}')"
      ahead="$(git -C "$target" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
      if [ "$ahead" -gt 0 ]; then
        log_warn "$ahead commit(s) not pushed to $upstream — would be lost"
      fi
    else
      log_warn "no upstream branch configured — can't check for unpushed commits"
    fi
  fi

  local confirm_name
  read -r -p "Type the project name again to confirm: " confirm_name
  if [ "$confirm_name" != "$name" ]; then
    log_skip "name didn't match — aborting, nothing deleted"
    return 0
  fi

  if [ -n "$sessions" ]; then
    local id
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      claude stop "$id" 2>/dev/null || true
      claude rm "$id" 2>/dev/null || true
      log_ok "stopped and removed session $id"
    done <<< "$sessions"
  fi

  rm -rf "$target"
  log_ok "deleted $target"

  if [ -d "$claude_meta_dir" ]; then
    rm -rf "$claude_meta_dir"
    log_ok "deleted $claude_meta_dir"
  else
    log_skip "no Claude metadata directory found for this project"
  fi
}
