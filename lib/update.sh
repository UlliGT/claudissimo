#!/usr/bin/env bash
# Action 3: update project git repos, Claude Code itself, and the files this
# tool deploys (revive script + systemd unit). Never discards local changes.

update_project_repo() {
  local dir="$1" name
  name="$(basename "$dir")"
  [ -d "$dir/.git" ] || return 0
  if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
    log_warn "$name: dirty working tree — skipped (commit or stash first)"
    return 0
  fi
  local before after
  before="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
  if git -C "$dir" pull --ff-only; then
    after="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
    if [ "$before" = "$after" ]; then
      log_skip "$name: already up to date"
    else
      log_ok "$name: updated ${before:0:8} -> ${after:0:8}"
    fi
  else
    log_warn "$name: pull failed (diverged history?) — left untouched"
  fi
}

update_deployed_file() {
  local path="$1" desired="$2"
  if [ ! -f "$path" ]; then
    log_warn "$path does not exist yet — run initial setup"
    return 0
  fi
  local current
  current="$(cat "$path")"
  if [ "$current" = "$desired" ]; then
    log_skip "$path already matches"
    return 0
  fi
  log_warn "$path differs from this tool's version:"
  diff <(printf '%s\n' "$current") <(printf '%s\n' "$desired") || true
  read -r -p "Overwrite $path with the tool's version? [y/N] " reply
  if [[ "$reply" =~ ^[Yy]$ ]]; then
    printf '%s\n' "$desired" > "$path"
    log_ok "updated $path"
  else
    log_skip "left $path unchanged"
  fi
}

action_update() {
  log_info "=== Updating project repos under $PROJECTS_ROOT ==="
  if [ -d "$PROJECTS_ROOT" ]; then
    for dir in "$PROJECTS_ROOT"/*/; do
      [ -d "$dir" ] || continue
      update_project_repo "${dir%/}"
    done
  fi

  log_info ""
  log_info "=== This tool's own repo ==="
  if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
     && git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1; then
    update_project_repo "$REPO_ROOT"
  else
    log_skip "no remote configured for $REPO_ROOT yet"
  fi

  log_info ""
  log_info "=== Claude Code ==="
  if require_cmd claude; then
    claude update || log_warn "claude update failed, or this install method updates itself another way"
  else
    log_warn "claude not installed"
  fi

  log_info ""
  log_info "=== Deployed scripts ==="
  source "$LIB_DIR/setup.sh"
  update_deployed_file "$HOME/.local/bin/claude-agents-revive.sh" "$(revive_script_content)"
  update_deployed_file "$HOME/.config/systemd/user/claude-agents.service" "$(systemd_unit_content)"
}
