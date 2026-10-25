#!/usr/bin/env bash
# Action 3: update what this host needs to keep running background
# sessions — Claude Code itself, the jq/git/curl packages, and the two
# files setup deploys (revive script + systemd unit). Does not touch any
# project repos (including this tool's own) — that stays plain
# `git pull`.

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
  log_info "=== Deployed scripts ==="
  source "$LIB_DIR/setup.sh"
  update_deployed_file "$HOME/.local/bin/claude-agents-revive.sh" "$(revive_script_content)"
  update_deployed_file "$HOME/.config/systemd/user/claude-agents.service" "$(systemd_unit_content)"
}
