# UI design (TODO)

A window for apprentice: schedule prompts and tasks, read and change settings, create site rules and project configs, update, check health, and work in a terminal with tabs where Claude Code (or any agent) runs with apprentice already wired in. Nothing here is built yet. This file is the design; items move to `TODO.md` or get deleted as they land.

## Principles

- **The UI is a client, like the CLI.** Every button calls the same code path as a command (`schedule add`, `budget`, `update`, `doctor`, `approve`). No logic lives only in the UI, and nothing the UI can do is missing from the CLI, so agents and scripts keep full parity. Screens hold layout; the work stays in the existing enums (`Config`, `Budgets`, `Repo`, `Doctor`, `Approvals`).
- **Files stay the source of truth.** The UI edits `config.toml`, `routes.toml`, `budgets.json` and a new `schedules.toml` in `~/.apprentice/`, and commands keep re-reading them on each call. Hand edits and UI edits never fight: the UI reloads a file when it changes on disk.
- **The safety model does not move.** Budgets, cooldowns, challenges, the gate and `user_only` steps apply to everything the UI starts, scheduled or not. The UI is a user channel (like the menu bar and `confirm`), so it must be one an agent cannot drive (see Security).
- **Calm.** One window, quiet by default, the same look as the existing dialogs and overlay (`Ask.swift`, `Overlay.swift`).

## Process and packaging

- Same binary, new client-side command: `apprentice app` opens the window (add it to the client list in `main.swift`). It runs in its own process, not inside the daemon, so a stuck terminal or a crashed view never takes the daemon (and a pending approval) down with it. It talks to the daemon over the socket like any other client and starts it on demand (`Wire.send`).
- Grow the generated `~/.apprentice/Apprentice.app` (today only for notifications, `Notify.swift`) into the real app bundle, launched from the Dock, Spotlight or the menu-bar item ("Open apprentice…"). This also unblocks two `TODO.md` items: `UNUserNotificationCenter` notifications and the first-run window with live grant check marks.
- SwiftUI for the screens (macOS 14+), AppKit where SwiftUI is weak (the terminal view, key handling). No package dependencies, per the repo rule; see the terminal question under Open questions.
- `kit.sh` signs the bundle with the same identity, so the grants stay with the binary.

## Window layout

```
┌──────────────────────────────────────────────────────────────────────────┐
│ ● ● ●   apprentice                     ◉ working · 1 approval waiting  ⏸ │
├───────────────┬──────────────────────────────────────────────────────────┤
│ ▸ Terminal    │ [claude · shop ●] [codex · blog] [vm:linux1 ⚠] [+]       │
│   Schedules   │ ┌──────────────────────────────────────────────────────┐ │
│   Approvals 1 │ │ $ claude                                             │ │
│   Activity    │ │ > post this week's update on the shop site           │ │
│   Sites       │ │ …                                                    │ │
│   Settings    │ ├──────────────────────────────────────────────────────┤ │
│   Playbooks   │ │ ⚠ needs approval: click #4 "Publish"   [Deny] [Allow]│ │
│   VMs         │ └──────────────────────────────────────────────────────┘ │
│   Updates     │  ~/work/shop · project shop · model claude-opus · VM —   │
└───────────────┴──────────────────────────────────────────────────────────┘
```

- **Sidebar**: Terminal, Schedules, Approvals (badge with the count), Activity, Sites, Settings, Playbooks, VMs, Updates & health.
- **Title bar**: the same state as the menu-bar item (idle, working, waiting for you, needs approval), the Pause button (`Pause` in `Overlay.swift`) and the kill switch hint.
- Keyboard first: cmd+1…9 for sidebar sections, cmd+t / cmd+w / cmd+shift+[ ] for tabs, cmd+k for a command palette that runs any `apprentice` command and shows its output.

## Terminal

The heart of the app: a real terminal where you run `claude`, `codex`, `opencode` or a plain shell, and apprentice is already set up for whatever runs there.

**Tabs**
- Each tab is a pty running the user's login shell (`$SHELL -l`) in a chosen folder, optionally followed by a start command.
- New-tab menu (cmd+t opens the default, the `+` menu lists the rest): Shell, Claude Code, Codex, opencode, Kilo, VM shell (ssh through `VM.sshConfig` over the daemon's shared connection), Log (`apprentice log` following new rows), and user presets.
- Presets live in `[app.tabs]` in `config.toml`: name, folder, command, env, VM. Example: `shop = { dir = "~/work/shop", cmd = "claude", vm = "linux1" }`.
- Tab title: preset or command, then the project name. A dot shows state from the daemon (working, waiting for an answer, ⚠ needs approval, exited with a code). Tabs can be renamed, dragged to reorder, pinned, and torn off into their own window.
- Split panes inside a tab (cmd+d side by side, cmd+shift+d stacked), so an agent and `apprentice log` sit next to each other.
- Restore on relaunch: tabs, folders, start commands and splits come back; scrollback does not (it may hold secrets), unless `[app] keep_scrollback = true`.
- Find in scrollback (cmd+f), copy on select optional, clickable paths and URLs, font and theme from `[app]`, bell flashes the tab.

**What a tab sets up for the agent**
- `APPRENTICE_PROJECT` from the tab's folder (nearest `.apprentice/`), `APPRENTICE_VM` when the tab is bound to a VM, `APPRENTICE_MODEL` when the preset names one. So parallel work is one tab per VM, each with its own daemon, exactly as today.
- A tab id (`APPRENTICE_TAB`) that `Request` carries alongside `model` and `project`, so log rows, pending approvals and questions are tied to the tab that caused them. That lets the app put an approval banner in the right tab and jump to it from a notification.
- If the agent is not connected yet (`agent/connect.py`), the first Claude Code / Codex tab offers to run it once.

**Inline approvals and questions**
- A pending ⚠ step from a tab's agent shows as a banner at the bottom of that tab: what, where, the gate screenshot on hover, Deny / Allow. It is the same as `confirm` and the menu bar's approve/deny: it calls `Approvals`, and `Gate.forUser` steps are allowed because the user clicked it.
- An `ask` from a tab's agent can be answered in that banner too, instead of the floating window, when the app is frontmost. `[agent] ask_in` gets a new value `"app"`.

## Schedules

Run prompts and tasks later or on a repeat, with the same care as a person doing it by hand.

**What can be scheduled**
- A prompt for an agent CLI: `claude -p "<prompt>"`, `codex exec "<prompt>"`, or any preset's command with the prompt passed in. Runs in a hidden terminal tab you can open while it runs or read after.
- `apprentice run "<task>"` (the built-in loop, with its model and endpoint).
- `apprentice do <flow>` with the flow's plan.
- A shell command (refused under `ui_only`).

**When**
- Once at a date and time; every N minutes or hours; daily or on chosen weekdays at a time; a cron line for the rest.
- **Jitter by default** (`jitter_min`, e.g. ±15 min), drawn through `Rand`, so a daily post never lands at 09:00:00 every day. This answers to the same bot-detection audit as pacing.
- `quiet_hours`, `session_max_min` breaks and `actions_per_day` still apply; a run that would start in quiet hours moves to the end of them, and the next-run time shown says so.

**How it runs**
- Stored in `~/.apprentice/schedules.toml` (shared state, edited only under the same file lock as `Limits.update`), one entry per schedule: id, name, kind, target, schedule, jitter, folder, project, VM, model, enabled, last run, last result.
- The daemon owns the timer (as `Repo.scheduleChecks` does for updates). For schedules to fire without anyone running a command first, the daemon needs to be up: when the first schedule is added, offer a LaunchAgent that starts `apprentice serve` at login; removing the last schedule offers to remove it.
- Overlap: a run is skipped (and logged) while the previous run of the same schedule is still going. Runs on different VMs run in parallel; two runs on the same VM queue.
- Missed runs (Mac asleep or off): on wake, a run missed by less than `catch_up_min` (default 60) runs once; older ones are skipped and logged. Never a burst of catch-ups.
- Nobody at the Mac: approvals and questions go out the way `away on` sends them (exit 9 to the agent, ntfy push with `[agent] notify`). A step that needs the user waits for them; the run stops at `wait_max_min` and records "waited for you".
- Every run gets a row in the step log with `schedule = <id>`, so `sessions`, `log --session`, `grow` and `activity` see it.

**CLI** (parity with the screen; add to `usage()`, `MCP.swift`, `agent/SKILL.md`, `agent/AGENTS.md`)
- `apprentice schedule add <name> --at|--every|--daily|--cron … (--prompt "…" [--agent claude] | --run "…" | --do <flow> | --sh "…") [--dir] [--vm] [--jitter]`
- `apprentice schedule list | show <id> | pause <id> | resume <id> | rm <id> | now <id>`
- Adding or changing a schedule from an agent is a `Gate.forUser` step: only the user approves something that will act again and again without them. `now` and `list` are not gated.

**Screen**: a list (name, next run, last result, enabled toggle), a detail pane with the form above, a "next 5 runs" preview after jitter and quiet hours, and run history with each run's transcript.

## Approvals

Everything waiting on the user in one list: pending ⚠ steps from every daemon (the Mac's and each VM's), open questions, and challenges or cooldowns waiting for a check. Each row has the tab or schedule it came from, the screenshot, and Deny / Allow (or the answer field). Same calls as `approve`, `confirm` and the menu bar.

## Activity

- **Now**: what each daemon is doing, the bound window per session, the current command and its waits.
- **Grow**: the `apprentice grow` report rendered (where time went, repeated errors, repeated questions, flows that ran, open field reports in `BUGS.md`), each with "open a tab and work on this", which starts a Claude Code tab in the clone with the item as the first prompt.
- **Sessions and log**: `sessions` and `log --session` with filters (site, model, project, schedule, exit code).
- **Events**: `activity` (soft blocks, challenges, cooldowns) on a timeline per site.

## Sites

The site rules from `SPEC.md` as forms, one page per site:
- Pace style (`[pace."<domain>"]`, the `[pace.styles]` presets), quiet hours, session length, actions per day.
- Budgets with live usage bars from `budgets.json` and the events log, account-wide and per project (project caps only tighten; the form refuses a project cap above the account one).
- Policy notes (`[policy."<domain>"]` in `routes.toml`), shown, never used to refuse a site.
- Cooldown and challenge state, with the "I checked it" action.
- **New site** wizard: domain → suggested style (`careful` for `Config.socialSites`, else `steady`) → budgets → quiet hours → policy note → preview the TOML it will add.

## Settings

- **Form view**, generated from `agent/config.example.toml`: one group per section (`[agent]`, `[run]`, `[sites]`, `[gate]`, `[session]`, `[update]`, `[storage]`, `[pace.*]`, `[app]`), each key with its comment from the example as help text, the right control for its type, and the default shown greyed.
- **Raw view** of the TOML with the same validation.
- Saving: parse with `Toml`, load with `Config.load`, show the diff, write a `.bak`, then swap the file in (same copy-beside-then-swap as `Settings.local`). An invalid file is never written.
- Needs a comment-preserving edit in `Toml` (change a key's value in place, add a key at the end of its section), so hand-written comments survive UI edits. Add selftest checks for it.
- **Projects**: the known project folders (from log rows), `project init` for a new one, its `limits.json` and `budgets.json`.
- **Routes**: `routes.toml` and the learned routes per model, read-only for learned ones except delete.
- **Phone**: the `phone` setup (topic, test push, QR code) as a page.

## Playbooks

Browse `playbooks/` by app and site, see which flows ran and how often, run `playbooks --check`, open a flow with `do --explain`. Editing opens the file in the user's editor; the app does not write playbooks (they are shared upstream and must stay free of personal details, and `commit`/`learn` already guard that).

## VMs

List of VMs (`vm` command): state, browser session, last command, disk and memory. Start, stop, create, open a VM shell tab, open the VNC view, and bind a terminal tab or schedule to a VM.

## Updates & health

- Installed commit (`version`), upstream status, local commits ahead, last check and its result (`Repo.updateLine`), `[update] auto` and `check_hours`.
- "Update now" (same as `apprentice update`, with the restart-when-idle rule shown), the upstream changes since the installed commit, and "Share my fixes" (`pr`, or `pr --local` for the compare URL).
- `doctor` as a checklist with live check marks (Accessibility, Screen Recording, signature, PATH, clone, smoke test) and a Fix button per row; `selftest` with its output.
- `BUGS.md` and `TODO.md` counts with a link to open them.

## Security

- **The app's window is never a session target.** `session`, `open` and `attach` refuse apprentice's own windows (the app, the overlay, `ask`/`confirm`), and the walker skips them, the way `helper.py` skips `apprentice-ask`. Otherwise an agent in a tab could bind to the app and click its own Allow button. Add a selftest check.
- `Privacy.blocked` covers the app, so its contents (terminal text, settings) never reach logs or session copies.
- An agent running in a tab could type into another tab through apprentice's keyboard; with the window refused as a target that path is closed, but the terminal also ignores input while a ⚠ banner for that tab is open, and Allow takes a click, not a key.
- Schedules from agents are user-only (above). The scrubbed `sessions/` copies never carry schedule prompts, only the schedule id and kind.

## Phases

1. **App shell**: `apprentice app`, the bundle, sidebar, Updates & health, Settings in read-only form view. Done when the window opens from the Dock, the grants survive a `kit.sh` rebuild, and every value matches `config.toml`.
2. **Editing**: comment-preserving `Toml` writes, Settings and Sites forms, new-site wizard, projects. Done when a hand-commented config round-trips through the form unchanged except for the edited key.
3. **Terminal**: tabs, presets, splits, restore, env wiring, tab id on `Request`, inline approvals and questions, the session-target refusal. Done when Claude Code in a tab drives a browser session and its ⚠ step is approved from the banner.
4. **Schedules**: `schedules.toml`, the daemon timer, jitter, quiet hours, catch-up, overlap, LaunchAgent, the CLI and MCP tool, the screen. Selftest: next-fire computation, jitter bounds, quiet-hours shift, catch-up rule.
5. **Activity, Approvals list, Playbooks, VMs.**

## Open questions

- **Terminal emulator, with no package dependencies.** Writing a VT100/xterm emulator that runs Claude Code's TUI well (alternate screen, 256 colours and truecolor, mouse reporting, bracketed paste, wide characters) is a large job. Recommendation: vendor SwiftTerm's source (MIT) into its own folder in the repo, pinned to a commit, rather than a package dependency, and keep a note of the upstream commit for updates. The alternative is to open tabs in the user's own terminal app and keep only the agent wiring and state in apprentice's window, which drops the in-window terminal.
- Does the app replace the menu-bar item or sit beside it? Recommendation: keep the menu-bar item (it is the quickest approve/deny) and add "Open apprentice…" to it.
- Should a schedule be allowed to run while the user is away with approvals only on the phone, or should it wait until they are back at the Mac? Recommendation: allow it with `away on`'s behaviour, since budgets and the gate still apply; a `user_only` step still waits.
