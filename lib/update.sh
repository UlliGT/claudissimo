#!/usr/bin/env bash
# Action 3: update what this host needs to keep running background
# sessions — Claude Code itself, the jq/git/curl packages, this tool's
# own repo (if it's a git checkout with an upstream), and the four files
# setup deploys (revive script, boot service, timer-triggered revive
# service, timer). Does not touch any *managed project* repos (trace,
# ngtrng, ...) — those stay plain `git pull`, by hand, per project.

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

update_own_repo() {
  log_info "=== This tool's own repo ($REPO_ROOT) ==="
  if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_skip "not a git checkout — can't self-update (re-download to get a newer version)"
    return 0
  fi
  if ! git -C "$REPO_ROOT" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    log_skip "no upstream configured for this checkout — can't self-update"
    return 0
  fi
  if [ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]; then
    log_warn "this checkout has uncommitted changes — skipped (commit or stash first)"
    return 0
  fi
  local before after
  before="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)"
  if git -C "$REPO_ROOT" pull --ff-only --quiet; then
    after="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)"
    if [ "$before" = "$after" ]; then
      log_skip "already up to date"
    else
      log_ok "updated ${before:0:8} -> ${after:0:8}"
    fi
  else
    log_warn "pull failed (diverged history?) — left untouched"
  fi
}

action_update() {
  log_info "=== Claude Code ==="
  if require_cmd claude; then
    claude update || log_warn "claude update failed, or this install method updates itself another way"
  else
    log_warn "claude not installed"
  fi

  log_info ""
  log_info "=== Host packages (jq, git, curl) ==="
  local manual_cmd="sudo apt-get update && sudo apt-get install --only-upgrade -y jq git curl"
  log_info "This runs: $manual_cmd"
  log_info "You'll be asked for your password right after confirming below —"
  log_info "that's the normal system sudo prompt, not this script; it's never"
  log_info "stored anywhere."
  read -r -p "Proceed? [y/N] " reply
  if [[ "$reply" =~ ^[Yy]$ ]]; then
    sudo apt-get update
    sudo apt-get install --only-upgrade -y jq git curl
  else
    log_skip "skipped — run this yourself when ready:"
    log_info "  $manual_cmd"
  fi

  log_info ""
  update_own_repo

  log_info ""
  log_info "=== Deployed scripts ==="
  source "$LIB_DIR/setup.sh"
  update_deployed_file "$HOME/.local/bin/claude-agents-revive.sh" "$(revive_script_content)"
  update_deployed_file "$HOME/.config/systemd/user/claude-agents.service" "$(systemd_unit_content)"
  update_deployed_file "$HOME/.config/systemd/user/claude-agents-revive.service" "$(timer_service_content)"
  update_deployed_file "$HOME/.config/systemd/user/claude-agents.timer" "$(timer_unit_content)"
  systemctl --user daemon-reload
}
