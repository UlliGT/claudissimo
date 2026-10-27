#!/usr/bin/env bash
# Action: recurring one-shot Claude Code tasks ("add"/"list"/"remove"), on
# top of the same systemd timer + plain-oneshot-service pattern proven for
# the revive timer. Each task runs `claude -p` (non-interactive, prompt via
# stdin — no shell-quoting concerns) on a fixed interval in a chosen
# project directory. This is a SHORT-LIVED session each time: no
# connection to any other chat or conversation history, fresh context
# every run. It can read/write files, use git, and send mail (if msmtp is
# configured) — but it cannot post into, or know anything about, any
# currently running background session in that project.

TASKS_DIR="$HOME/.config/claudissimo/tasks"
TASKS_UNIT_DIR="$HOME/.config/systemd/user"
TASK_PROMPT_PREFIX="This is a short-lived, one-off Claude Code session — it has no connection to any other chat or conversation history, and nothing it does here is visible in any other session. It can read and write files in this project directory, use git, and send mail (msmtp is configured) if asked to — when composing a mail, always put a MIME-Version: 1.0 and Content-Type: text/plain; charset=UTF-8 header in it, otherwise umlauts get garbled on arrival. It cannot post into, or see, any currently running background session for this project. Task:"

task_runner_content() {
  local project_dir="$1" prompt_file="$2"
  cat <<EOF
#!/bin/bash
export PATH=\$HOME/.local/bin:/usr/bin:/bin
cd "$project_dir" || exit 1
printf '%s %s' "$TASK_PROMPT_PREFIX" "\$(cat "$prompt_file")" | claude -p --permission-mode auto
EOF
}

task_service_content() {
  local name="$1" project_dir="$2" runner="$3"
  cat <<EOF
[Unit]
Description=Claudissimo scheduled task "$name" ($project_dir)

[Service]
Type=oneshot
ExecStart=$runner
EOF
}

task_timer_content() {
  local name="$1" hours="$2"
  cat <<EOF
[Unit]
Description=Timer for claudissimo scheduled task "$name"

[Timer]
OnUnitActiveSec=${hours}h
Unit=claudissimo-task-$name.service

[Install]
WantedBy=timers.target
EOF
}

list_task_names() {
  local f
  for f in "$TASKS_UNIT_DIR"/claudissimo-task-*.timer; do
    [ -f "$f" ] || continue
    local base
    base="$(basename "$f" .timer)"
    echo "${base#claudissimo-task-}"
  done
}

action_task_add() {
  log_info "=== Add scheduled task ==="

  if [ -d "$PROJECTS_ROOT" ]; then
    log_info "Existing projects under $PROJECTS_ROOT:"
    for dir in "$PROJECTS_ROOT"/*/; do
      [ -d "$dir" ] || continue
      printf '  %s\n' "$(basename "${dir%/}")"
    done
  fi

  local project
  read -r -p "Project name (empty to cancel/back): " project
  if [ -z "$project" ]; then
    log_skip "cancelled"
    return 0
  fi
  local project_dir="$PROJECTS_ROOT/$project"
  if [ ! -d "$project_dir" ]; then
    log_err "$project_dir does not exist"
    return 0
  fi
  project_dir="$(cd "$project_dir" && pwd -P)"

  local name
  read -r -p "Task name (used to identify it later, e.g. 'morning-overview'): " name
  if [ -z "$name" ]; then
    log_err "empty name — aborting"
    return 0
  fi
  if ! [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
    log_err "only letters, digits, - and _ allowed — aborting"
    return 0
  fi
  if [ -f "$TASKS_UNIT_DIR/claudissimo-task-$name.timer" ]; then
    log_err "a task named '$name' already exists — remove it first or pick another name"
    return 0
  fi

  local hours
  read -r -p "Run every how many hours? (e.g. 24 for daily, 1 for hourly): " hours
  if ! [[ "$hours" =~ ^[0-9]+$ ]] || [ "$hours" -lt 1 ]; then
    log_err "needs to be a positive whole number of hours — aborting"
    return 0
  fi

  log_info ""
  log_info "This will be a SHORT-LIVED session each run — no connection to any"
  log_info "other chat, fresh context every time. It can read/write files, use"
  log_info "git, and send mail (if msmtp is configured); it cannot see or post"
  log_info "into any currently running background session for this project."
  local prompt
  read -e -r -p "Prompt: " prompt
  if [ -z "$prompt" ]; then
    log_err "empty prompt — aborting"
    return 0
  fi

  mkdir -p "$TASKS_DIR"
  local prompt_file="$TASKS_DIR/$name.prompt"
  local runner="$TASKS_DIR/$name.sh"
  printf '%s\n' "$prompt" > "$prompt_file"

  printf '%s\n' "$(task_runner_content "$project_dir" "$prompt_file")" > "$runner"
  chmod 755 "$runner"

  printf '%s\n' "$(task_service_content "$name" "$project_dir" "$runner")" \
    > "$TASKS_UNIT_DIR/claudissimo-task-$name.service"
  printf '%s\n' "$(task_timer_content "$name" "$hours")" \
    > "$TASKS_UNIT_DIR/claudissimo-task-$name.timer"

  systemctl --user daemon-reload
  systemctl --user enable --now "claudissimo-task-$name.timer"
  systemctl --user start --no-block "claudissimo-task-$name.service"

  log_ok "task '$name' created: runs every ${hours}h in $project_dir"
  log_info "starting it once now, in the background, to give OnUnitActiveSec a reference point"
}

action_task_list() {
  log_info "=== Scheduled tasks ==="
  local names
  names="$(list_task_names)"
  if [ -z "$names" ]; then
    log_info "(none)"
    return 0
  fi
  printf '  %-20s %-16s %-10s %s\n' "NAME" "PROJECT" "ACTIVE" "NEXT RUN"
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    local active="no"
    systemctl --user is-active "claudissimo-task-$name.timer" >/dev/null 2>&1 && active="yes"
    local next_line next
    next_line="$(systemctl --user list-timers "claudissimo-task-$name.timer" --no-pager 2>/dev/null | awk 'NR==2')"
    if [ "$(awk '{print $1}' <<< "$next_line")" = "-" ]; then
      next="- (task currently running)"
    else
      next="$(awk '{print $1, $2, $3, $4}' <<< "$next_line")"
    fi
    local project_dir project
    project_dir="$(sed -nE 's/^Description=.*\((.*)\)$/\1/p' "$TASKS_UNIT_DIR/claudissimo-task-$name.service" 2>/dev/null)"
    project="$(basename "${project_dir:-?}")"
    printf '  %-20s %-16s %-10s %s\n' "$name" "$project" "$active" "${next:-?}"
  done <<< "$names"
}

action_task_edit() {
  log_info "=== Edit scheduled task ==="
  action_task_list
  local name
  read -r -p "Task name to edit (empty to cancel/back): " name
  if [ -z "$name" ]; then
    log_skip "cancelled"
    return 0
  fi
  local timer_file="$TASKS_UNIT_DIR/claudissimo-task-$name.timer"
  local prompt_file="$TASKS_DIR/$name.prompt"
  if [ ! -f "$timer_file" ]; then
    log_err "no task named '$name'"
    return 0
  fi

  local current_hours
  current_hours="$(sed -nE 's/^OnUnitActiveSec=([0-9]+)h$/\1/p' "$timer_file")"
  log_info "Current interval: every ${current_hours:-?}h"
  local hours
  read -r -p "New interval in hours (empty to keep current): " hours
  if [ -n "$hours" ]; then
    if ! [[ "$hours" =~ ^[0-9]+$ ]] || [ "$hours" -lt 1 ]; then
      log_warn "needs to be a positive whole number of hours — interval not changed"
    else
      current_hours="$hours"
    fi
  fi

  log_info "Current prompt:"
  log_info "  $(cat "$prompt_file" 2>/dev/null)"
  local prompt
  read -e -r -p "New prompt (empty to keep current): " prompt
  if [ -n "$prompt" ]; then
    printf '%s\n' "$prompt" > "$prompt_file"
    log_ok "prompt updated"
  fi

  printf '%s\n' "$(task_timer_content "$name" "$current_hours")" > "$timer_file"
  systemctl --user daemon-reload
  systemctl --user restart "claudissimo-task-$name.timer"
  log_ok "task '$name' updated: runs every ${current_hours}h"
}

action_task_remove() {
  log_info "=== Remove scheduled task ==="
  action_task_list
  local name
  read -r -p "Task name to remove (empty to cancel/back): " name
  if [ -z "$name" ]; then
    log_skip "cancelled"
    return 0
  fi
  if [ ! -f "$TASKS_UNIT_DIR/claudissimo-task-$name.timer" ]; then
    log_err "no task named '$name'"
    return 0
  fi

  local confirm
  read -r -p "Remove task '$name'? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log_skip "cancelled"
    return 0
  fi

  systemctl --user disable --now "claudissimo-task-$name.timer" 2>/dev/null || true
  rm -f "$TASKS_UNIT_DIR/claudissimo-task-$name.timer" \
        "$TASKS_UNIT_DIR/claudissimo-task-$name.service" \
        "$TASKS_DIR/$name.sh" \
        "$TASKS_DIR/$name.prompt"
  systemctl --user daemon-reload
  log_ok "removed task '$name'"
}
