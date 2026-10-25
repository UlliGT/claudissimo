#!/usr/bin/env bash
# Action 4: create a new project directory, wire the no-worktree setting so
# background sessions edit the project folder directly, and start the first
# background session.

action_new_project() {
  log_info "=== New project ==="

  local name
  read -r -p "Project name (directory under $PROJECTS_ROOT): " name
  if [ -z "$name" ]; then
    log_err "empty name — aborting"
    return 0
  fi

  local target="$PROJECTS_ROOT/$name"
  if [ -e "$target" ]; then
    log_err "$target already exists — aborting"
    return 0
  fi

  local remote
  read -r -p "Git remote URL (leave empty for a local-only repo): " remote

  mkdir -p "$target"
  if [ -n "$remote" ]; then
    git clone "$remote" "$target"
  else
    git -C "$target" init
  fi

  mkdir -p "$target/.claude"
  local settings_file="$target/.claude/settings.local.json"
  if [ -f "$settings_file" ]; then
    if require_cmd jq; then
      jq '.worktree.bgIsolation = "none"' "$settings_file" > "$settings_file.tmp" && mv "$settings_file.tmp" "$settings_file"
    else
      log_warn "jq not available to merge existing $settings_file — add {\"worktree\":{\"bgIsolation\":\"none\"}} by hand"
    fi
  else
    printf '{ "worktree": { "bgIsolation": "none" } }\n' > "$settings_file"
  fi
  log_ok "wrote $settings_file"

  local exclude_file="$target/.git/info/exclude"
  if [ -f "$exclude_file" ] && grep -qx '.claude/settings.local.json' "$exclude_file"; then
    log_skip ".claude/settings.local.json already excluded from git"
  else
    printf '.claude/settings.local.json\n' >> "$exclude_file"
    log_ok "excluded .claude/settings.local.json from git"
  fi

  log_info ""
  log_info "First run needs an interactive trust confirmation."
  log_info "Starting 'claude' in $target — confirm the trust prompt, then type /exit."
  read -r -p "Press Enter to continue..." _ || true
  (cd "$target" && claude)

  local prompt
  read -r -p "Initial prompt for the background session [Get familiar with the project]: " prompt
  prompt="${prompt:-Get familiar with the project}"

  log_info "Starting background session..."
  (cd "$target" && claude --bg "$prompt")

  log_info ""
  log_info "=== git status in $target ==="
  git -C "$target" status
}
