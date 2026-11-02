# UI design

The window is built: `apprentice app`. This file keeps what is still open; the rest is described in
`SPEC.md` (behaviour) and the source (`AppUI.swift`, `Terminal.swift`, `Schedules.swift`, `Away.swift`).

## Built

- **The app is a client.** `apprentice app` opens `~/.apprentice/Apprentice.app` as its own process; every
  button sends the same request the CLI sends (`Wire.send`, `Request.user` marks the user's own clicks, so
  approvals and `[gate] user_only` steps work from the app exactly as from `confirm` and the menu bar).
  Files stay the source of truth: schedules, settings, sites and the queue are read back from
  `~/.apprentice/` on each refresh, so a hand edit and a button never fight.
- **Window**: sidebar with Terminal, Schedules, Approvals (badge), Activity, Sites, Settings, Playbooks,
  VMs and Updates & health; title-bar state, Pause, the kill-switch hint, ⌘1…9 for sections and ⌘K for a
  command palette that runs any apprentice command and shows its output.
- **Terminal**: pty tabs running `$SHELL -l` in a folder, optionally with a start command; presets from
  `[app.tabs]`; Claude Code, Codex, opencode, Kilo and a following `apprentice log` in the new-tab menu;
  `APPRENTICE_TAB`, `APPRENTICE_PROJECT`, `APPRENTICE_VM` set for the tab; a small xterm screen (alternate
  screen, 256 colours and truecolor, cursor addressing, erase, scroll regions, insert/delete) with
  scrollback; ⌘V paste; a ⚠ banner with Deny / Allow in the tab it came from, and the terminal ignores keys
  while that banner is open.
- **Schedules**: `schedules.toml`, once/every/daily/weekly/cron, jitter through `Rand`, quiet-hours shift,
  catch-up (`catch_up_min`), overlap skip, the daemon's timer, `schedule agent on` (a LaunchAgent), the
  CLI, the MCP tool and the screen (list, detail, next five runs, run history). Adding or changing one
  from an agent is a `user_only` step.
- **Away**: `away on|off|status|wait|add|list|cancel|run`; the queue in `~/.apprentice/away/`; presence
  from `Borrow.humanIdle` plus display-sleep assertions; exit 10 and the immediate yield for acting
  commands while the user is present; the per-unit journal for `type`; `decide` (proceed / redo / needs-you)
  and the field undo, only when the field still holds exactly apprentice's text.
- **Also**: Approvals, Activity (now, `grow`, sessions, events), Sites (pace, quiet hours, usage, policy
  notes, cooldowns), Settings (form generated from `agent/config.example.toml` with help text, raw TOML
  with validation, `.bak` before a write), comment-preserving `Toml.set`/`remove`, Playbooks, VMs, and
  Updates & health (version, doctor, update, share).
- **Security**: the app's own windows are never a session target (`Commands.refuseOwnWindow`), `Privacy`
  scrubs them, a banner's Allow takes a click, and adding schedules from agents is user-only.

## Still open

- **Split panes** inside a tab (⌘D / ⇧⌘D); tab drag-reorder, pinning and torn-off windows; scrollback
  restored across a relaunch (`[app] keep_scrollback` is read but not yet used); clickable paths and URLs;
  find in scrollback (⌘F); copy on select; per-preset environment keys.
- **Terminal fidelity**: mouse reporting and bracketed paste are accepted and ignored; some rare DEC modes
  are not emulated. Verified against a shell and `claude`, not against every TUI.
- **First run**: the window's grant check marks on first launch (the bundle and `doctor` exist), and
  `UNUserNotificationCenter` notifications through the bundle.
- **New-site wizard** previews the TOML it will add; today it writes it and shows the result.
- **`[agent] ask_in = "app"`**: answering an `ask` in the tab's banner instead of the floating window.
- **Phone page**: `phone` runs from the palette and shows its text; no QR page yet.
- **LaunchAgent offer**: the hint appears in `schedule add`'s output and on the Schedules screen, not as a
  modal when the first schedule is added.

## Open questions, answered

- Terminal: a small in-repo xterm screen (`Terminal.swift`) rather than a vendored SwiftTerm; no package
  dependencies, and it is enough for a shell and a coding agent's TUI.
- The menu-bar item stays; its menu gains "Open apprentice…".
- A schedule may run while the user is away with approvals on the phone: budgets and the gate still apply,
  and a `user_only` step waits.
