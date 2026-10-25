#!/usr/bin/env bash
# Action 1: initial setup on a fresh Ubuntu machine. Every step checks
# current state first and only changes what isn't already in place.

REVIVE_SCRIPT="$HOME/.local/bin/claude-agents-revive.sh"
SYSTEMD_UNIT="$HOME/.config/systemd/user/claude-agents.service"

revive_script_content() {
  cat <<'EOF'
#!/bin/bash
sleep 20
export PATH=$HOME/.local/bin:/usr/bin:/bin
claude agents --json --all | jq -r '.[] | "\(.id) \(.pid // 0)"' | while read -r id pid; do
  if [ "$pid" -gt 0 ] && grep -qa claude "/proc/$pid/cmdline" 2>/dev/null; then
    echo "$id already running (pid $pid)"
  else
    echo "$id being revived"
    claude respawn "$id" </dev/null
  fi
done
EOF
}

systemd_unit_content() {
  cat <<EOF
[Unit]
Description=Bring back Claude Code background sessions after boot

[Service]
Type=oneshot
RemainAfterExit=yes
KillMode=process
ExecStart=$REVIVE_SCRIPT

[Install]
WantedBy=default.target
EOF
}

ensure_file() {
  local path="$1" desired="$2" mode="$3"
  local current=""
  [ -f "$path" ] && current="$(cat "$path")"
  if [ "$current" = "$desired" ]; then
    log_skip "$path already up to date"
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$desired" > "$path"
  chmod "$mode" "$path"
  log_ok "wrote $path"
}

action_setup() {
  log_info "=== Initial setup ==="

  log_info "--- Required packages ---"
  local missing=()
  for pkg in jq git curl; do
    require_cmd "$pkg" || missing+=("$pkg")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    log_skip "jq, git, curl already installed"
  else
    log_warn "missing: ${missing[*]} — installing (will ask for sudo)"
    sudo apt-get update
    sudo apt-get install -y "${missing[@]}"
  fi

  log_info "--- Claude Code ---"
  if require_cmd claude; then
    log_skip "claude already installed ($(claude --version 2>/dev/null || echo "version unknown"))"
  else
    log_warn "claude not found."
    log_warn "UNVERIFIED by this tool — install Claude Code yourself first (see https://docs.anthropic.com/claude-code), then re-run this setup."
  fi

  log_info "--- Remote Control for new sessions (global Claude Code setting) ---"
  local claude_settings="$HOME/.claude/settings.json"
  if [ -f "$claude_settings" ] && require_cmd jq; then
    if jq -e '.remoteControlAtStartup == true' "$claude_settings" >/dev/null 2>&1; then
      log_skip "remoteControlAtStartup already enabled in $claude_settings"
    else
      jq '.remoteControlAtStartup = true' "$claude_settings" > "$claude_settings.tmp" \
        && mv "$claude_settings.tmp" "$claude_settings"
      log_ok "enabled remoteControlAtStartup in $claude_settings"
    fi
  elif [ -f "$claude_settings" ]; then
    log_warn "jq not available to edit $claude_settings — add \"remoteControlAtStartup\": true by hand"
  else
    mkdir -p "$(dirname "$claude_settings")"
    printf '{ "remoteControlAtStartup": true }\n' > "$claude_settings"
    log_ok "created $claude_settings with remoteControlAtStartup enabled"
  fi

  log_info "--- Revive script ---"
  ensure_file "$REVIVE_SCRIPT" "$(revive_script_content)" 755

  log_info "--- systemd user service ---"
  ensure_file "$SYSTEMD_UNIT" "$(systemd_unit_content)" 644
  systemctl --user daemon-reload
  if systemctl --user is-enabled claude-agents >/dev/null 2>&1; then
    log_skip "claude-agents service already enabled"
  else
    systemctl --user enable claude-agents
    log_ok "enabled claude-agents service"
  fi

  log_info "--- Linger (keep user services running without an active login) ---"
  if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = "yes" ]; then
    log_skip "linger already enabled for $USER"
  else
    sudo loginctl enable-linger "$USER"
    log_ok "enabled linger for $USER"
  fi

  log_info "--- Projects directory ---"
  if [ -d "$PROJECTS_ROOT" ]; then
    log_skip "$PROJECTS_ROOT already exists"
  else
    mkdir -p "$PROJECTS_ROOT"
    log_ok "created $PROJECTS_ROOT"
  fi

  log_info "--- GitHub SSH connectivity (check only, keys are yours to manage) ---"
  local ssh_check
  ssh_check="$(ssh -T git@github.com 2>&1)" || true
  if printf '%s' "$ssh_check" | grep -q "successfully authenticated"; then
    log_ok "GitHub SSH is connected"
  else
    log_warn "GitHub SSH not confirmed — set up your own SSH key with GitHub if you need git over SSH"
  fi

  log_info "=== Setup finished ==="
}
