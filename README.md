# claudissimo

The idea: Claude Code background agents ("Agent view", `claude --bg`) run on
this machine permanently. Set it up once, and sessions survive reboots on
their own — you never need an open SSH connection to use them, you control
them remotely instead, from the Claude app on another device (phone, laptop,
...).

This tool offers four actions, either as subcommands or through a one-line
interactive menu — no curses UI, output stays in your normal scrollback:

1. **Initial setup** — installs the pieces needed to run background sessions
   and survive a reboot: a revive script plus a systemd user service, enables
   linger so the service runs without an active login, and turns on
   `remoteControlAtStartup` in `~/.claude/settings.json` so new sessions can
   be controlled remotely from the start. From the interactive menu, it
   explains itself and asks for confirmation before changing anything.
2. **Status** — reports, for every project directory and every background
   session: whether it's actually alive (checked via `pid`, not `pgrep` —
   see below), whether it ended up in an unwanted git worktree, and whether
   the revive service is enabled.
3. **Update** — pulls clean project repos, runs `claude update`, and offers
   to refresh the two deployed files (revive script, systemd unit) if this
   tool's version of them has changed. Dirty repos are skipped, never force-
   pulled; deployed files are never overwritten without asking.
4. **New project** — clones or initializes a project directory, sets the
   `bgIsolation: none` setting so background sessions edit the project
   folder directly instead of a worktree copy, and starts the first
   background session.

## After setup

Background sessions should show up automatically in the Claude app (or
claude.ai) on any other device signed into the same account — no extra step
needed. If one doesn't show up:

- check it's actually running here first: `bin/claudissimo status` (a dead
  session can't show up anywhere)
- make sure this machine has internet access (setup needs it to register
  sessions with claude.ai)
- make sure you're signed into the same Claude account on both this machine
  and the other device
- a session started before `remoteControlAtStartup` was enabled may not
  have picked it up — try `claude respawn <id>` on it, or just create a new
  one (unverified, worth testing)
- if it's alive here but shows as unreachable in the app, restart the
  Claude app on the other device completely

## Why `pid`, not `pgrep`

A dead background session can still show state `done` after a reboot, and
`claude respawn` hands a session to a pre-started spare process whose command
line doesn't contain the session id — so matching by name with `pgrep` gives
false positives. The only reliable check is reading the `pid` from
`claude agents --json --all` and confirming `/proc/<pid>/cmdline` still
belongs to a `claude` process. Both the revive script and the status action
use this check.

## Requirements

- Tested on **Ubuntu/Debian**. `setup` installs missing packages via
  `apt-get` — that's the one Debian-specific step. Everything else (systemd
  user services, `loginctl` linger, bash, jq, git, curl, claude) works on any
  systemd-based Linux; on other distros, install `jq`/`git`/`curl` yourself
  before running `setup`.
- Claude Code (`claude`) already installed. **Not automated by this tool**:
  `setup` only checks for it and points at the install docs.

## Usage

    bin/claudissimo setup                        # action 1
    bin/claudissimo status [projects|agents|service]  # action 2, defaults to all three
    bin/claudissimo update                       # action 3
    bin/claudissimo new                          # action 4
    bin/claudissimo info                         # prints the "What this tool does" text above

Without an argument, `bin/claudissimo` shows a numbered menu that
dispatches to the same four actions plus `i) Info`, in the same terminal;
status opens a submenu so you can look at projects, background sessions, or
the systemd service on their own instead of one long dump.

Projects live under `~/claude-projects` by default; override with
`CLAUDE_PROJECTS_ROOT=/some/other/path bin/claudissimo ...`.

## Status of this tool

Exercised on one machine so far. Action 1 (initial setup) in particular has
not yet been run end-to-end on a genuinely fresh VM — treat it as unverified
until tried.
