#!/usr/bin/env bash
# Action 6: manually revive dead background sessions right now, without
# waiting for a reboot. Just runs the already-deployed revive script —
# same logic the systemd service uses at boot, same liveness check (pid,
# not pgrep; see lib/common.sh).

action_revive() {
  log_info "=== Revive dead sessions ==="
  local revive_script="$HOME/.local/bin/claude-agents-revive.sh"
  if [ ! -x "$revive_script" ]; then
    log_err "$revive_script not found or not executable — run 'setup' first"
    return 1
  fi
  bash "$revive_script"
}
