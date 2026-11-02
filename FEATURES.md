# Features

Every feature apprentice has, with how to tell from the logs whether it earns its place. Review this list every few weeks: a feature nobody uses, or one that never changes an outcome, is a candidate to take out. A feature that can't be measured yet says so; adding the log field is the first step.

Scope: every command the CLI accepts (including `version` and `help`, which `usage()` does not print), every option those commands take, and every part of `Sources/apprentice` an agent or the user can reach. The coverage map and command index at the end are the check that nothing is missing: every file and every command appears in exactly one place.

Where the numbers come from:

- `~/.apprentice/runs/<date>-<session>/steps.jsonl`: one row per command, with `cmd`, `ms`, `waits` (`idle`, `gap`, `move`, `type`, `settle`), `diff`, `host`, `kind`, `vm`, `snap`, `flags`, `proposed`, `gate`, `approved`, `edited`, `ask`, `show`, `options`, `awake`, `notify`, `kill_switch`, gate results, errors and questions. `apprentice log` prints the tail.
- `~/.apprentice/events.jsonl`: rate limits, challenges, budget refusals, cooldowns and flags, kept 180 days. `apprentice activity <domain>` reads it.
- `sessions/*.jsonl` in the clone: the scrubbed copy of each finished run, committed by `Sessions.archive`.
- `apprentice grow`: the pace summary, repeated errors, questions asked and flows run over the last 14 days.
- `apprentice sessions`: app, sites, steps, errors, model and task per run.

Verdicts: **keep** (used and pays off), **watch** (too new or too little data), **cut?** (little use; look closer before removing).

## Sessions and windows

| Feature | Where | How to measure | Keep if | Verdict |
| --- | --- | --- | --- | --- |
| `session`: attach one window (`--app`, `--on mac\|linux`, `--new-window`, `--allow`, `--task`, `--no-options`) | `Commands.swift` `session`, `attach` | `session` rows per run, `app`, `task`; sessions with no action after them | Every run starts with one, and few sessions are abandoned | keep |
| `focus`: switch app or window, keeping the session id, allowlist and UI-only choice | `Commands.swift` `focus`, `attach(keep:)` | `focus` rows, and whether the allowlist survived | Used mid-task instead of a second `session` | watch |
| Web accessibility switched on for the attached browser | `Commands.swift` `attach` | Reads on Safari and Chrome returning elements rather than needing `ocr` | Web reads come from the tree, not OCR | keep |
| Session header with URL, title, policy and site playbooks | `Commands.swift` `session`, `playbookLines`, `Remote.swift` `session` | `url` and `app` on session rows; playbooks printed then followed | The agent uses the header instead of re-reading | keep |
| Start-up options window (UI only, keep awake, allowed sites, remember) | `Commands.swift` `startOptions`, `Ask.swift` | `options` rows: `ui_only`, `allow`, and how often `remember` is chosen | People change something there, or it gets skipped knowingly | watch |

## Reading the screen

| Feature | Where | How to measure | Keep if | Verdict |
| --- | --- | --- | --- | --- |
| `read`: numbered element list with kinds, field values and headings | `Reader.swift` `Walker`, `Element` | `read` rows per action (grow's re-read %), `ms`, `shown`/`total` | It stays the main source and the re-read rate falls | keep |
| Diffs after actions | `Reader.swift` `DiffResult` | Re-reads after actions (grow) | Agents act from the diff; re-reads under 30% | keep |
| Ids that survive actions | `Reader.swift` `keepIds` | Re-read % before and after 2026-11-01; exit-2 (`stale`) count | Re-reads drop without more `stale` errors | watch |
| Snapshot numbers and `stale` refusal (exit 2) | `Reader.swift` `SnapStore`, `Commands.swift` | `snap` on rows; `stale` errors | Agents re-read on `stale` and rarely act blind | keep |
| `--filter` / `--max` | `Commands.swift` `read` | `flags` on `read` rows | Agents use them to keep lists short | watch |
| `ocr` (merged OCR lines with ids) | `Capture.swift` `ocr` | `ocr` rows, and whether the next action used an OCR id | It unblocks pages the tree can't read | watch |
| `shot` / `shot --crop` | `Capture.swift` `window`, `crop` | `shot` rows | Used when a label is missing | watch |
| `shot --marks` (ids drawn on the image) | `Capture.swift` `mark` | `shot` rows with `marks: true`, then whether the next click used a marked id | It replaces `show` / `ask` questions about where something is | watch |
| `wait-for` | `Commands.swift` `waitFor` | `wait-for` rows, `found` vs timed out | It saves polling `read`s | watch |
| Snapshot cache (300 ms) | `Reader.swift` `SnapshotCache` | Not measured: add a hit count | Hits are common | cut? |

## Acting

| Feature | Where | How to measure | Keep if | Verdict |
| --- | --- | --- | --- | --- |
| `click` (id, `--on`, `--at`, `--double`, `--right`, `--gate`) | `Commands.swift` `click`, `realClick` | Rows by form; `stale` errors | Each form is used | keep |
| `type` (`--enter`, `--pace`, address bars pasted) | `Commands.swift` `type`, `typeInto`, `Input.swift` `Keys.paste` | `type` rows, `waits.type` | Typing is paced without slowing short fields | keep |
| `key` and `menu` | `Commands.swift` `key`, `menu` | Rows per command and per combo | Shortcuts and menu items both used | keep |
| `scroll` (`--in id`) | `Commands.swift` `scroll` | `scroll` rows | Used on page and on an element | keep |
| `hover`, `drag` | `Commands.swift` `hover`, `drag` | Rows per command | Each is used in real runs | keep |
| `browse` (read down a feed) | `Commands.swift` `browse`, `Fidget.swift` `Wheel.browse` | `browse` rows, `down`/`up` lines; soft blocks on the same host after one | Agents use it before acting on a feed, and no soft block follows it | watch |
| `open` (navigate at a polite pace): proposes like the other acting commands, so it exits 8 with a token and navigates once approved | `Commands.swift` `open`, `gate()` | `open` rows, `proposed` vs `approved`, navigation-limit errors | It is used instead of clicking through to a URL | keep |
| `upload`, `download`, `choose` (system dialogs; `[agent] download_menu`) | `Commands.swift` `upload`, `download`, `choose` | Rows and their errors (grow lists repeats) | Error rate keeps falling; a repeat is a fix, not a cut | keep |
| `do <flow>` on the VM (`choose` and dialog driving) | `Remote+More.swift` `confirmDialog` | `choose` rows with `vm: true` | File dialogs work the same on both screens | watch |

## Pacing and human input

| Feature | Where | How to measure | Keep if | Verdict |
| --- | --- | --- | --- | --- |
| Shared fast generator | `Rand.swift` | Not measured; `selftest` checks range, seeding and weights | Cheap; one place to change randomness | keep |
| Pointer paths: five shapes, three speed profiles, a hand drawn once per daemon, overshoot and two-step correction, settle, Gaussian landing | `Input.swift` `Mouse` | `waits.move`; challenges and soft blocks per site in `events.jsonl` | No challenges traced to pointer motion | keep |
| Scroll flicks | `Fidget.swift` `Wheel` | `scroll` rows; soft blocks after scrolls | No challenge traced to scrolling | watch |
| Fidgets after actions | `Fidget.swift` | `waits.fidget`; challenges per site before and after turning `fidget` on | Sites with fidgets on see fewer challenges for the seconds they cost | watch |
| Pace styles (`fastest` … `careful`) and `[pace.styles]` | `Config.swift` `PaceConfig.preset` | Which style each row ran under (add it to rows) | Each style is used; `careful` sites stay free of soft blocks | watch |
| Key rhythm, thinking pauses, corrections | `Input.swift` `Keys`, `Pace` | `waits.type` per character | Typing stays human-paced without slowing short fields | keep |
| Gaps, bursts, rests | `State.swift` `Limits` | `waits.gap` on social sites | Sites with profiles stay free of soft blocks | keep |
| Dwell before budgeted actions | `SiteRules.swift` `Site.dwell` | `waits.gap` on rows with a `kind` | Same | keep |
| Look pauses between flow steps | `Pace.lookGap`, `Flows.swift` | `waits.gap` on rows inside a `do` | Flows show uneven timing, no new challenges on flow runs | watch |
| Borrow mode: wait until the person has been idle, then act | `Input.swift` `Borrow.waitIdle`, `humanIdle` | `waits.idle`; exit 6 for "you were active for 30 s" | Actions start on an idle Mac, and the wait stays short | keep |
| Watching for the person: any real key or click stops the step (exit 6) | `Input.swift` `Borrow.run`, `Watch` | Exit-6 rows and their commands; `selftest` checks the tagging | Their typing never mixes with apprentice's | keep |
| Pointer drift (linger) | `Input.swift` `Mouse.linger` | Not measured on its own | Hard to show; keep while cheap | watch |
| Pacing profiles per domain | `Config.swift` | Which profiles were active (add the profile name to rows) | Each profile is used | watch |

## Safety

| Feature | Where | How to measure | Keep if | Verdict |
| --- | --- | --- | --- | --- |
| Approval gate, tokens, `approve` / `deny` / `pending`, `approve --text` | `State.swift` `Approvals`, `gate()` | `proposed` rows against `approved`/`denied`; grow's approval wait | Part of the product | keep |
| Token lifecycle: single use, 5 minutes, refused after a re-read | `State.swift` `Approvals` | Expired and stale-token errors | Tokens are never acted on twice | keep |
| `confirm` for ⚠ steps | `Ask.swift` `confirm` | Confirms, denies, time to answer | The user denies sometimes (it catches things) | keep |
| Gate words, ⚠ lines and `--gate` forcing a warning | `State.swift` `Gate`, `Commands.swift` | ⚠ proposals vs denied ones | Warnings line up with what the user cares about; words that never fire can be pruned | keep |
| Gate screenshots kept with the row | `Commands.swift` `gate`, `Sessions.capShots` | `shots/gate-*.png` counts | They get looked at when a step is questioned | watch |
| Shell policy (`[agent] ui_only`, `policy`) | `Commands.swift` `policy`, `AgentLoop.swift`, `Flows.swift` | Policy blocks, `sh:` steps refused | UI-only runs never touch the shell | keep |
| Per-site budgets (hour, day, week, `min_gap_s`, kind borrowing) | `SiteRules.swift` `Budgets` | Budget stops (grow lists them) | Part of the product | keep |
| Project budgets and counts (`.apprentice/` on top of the account) | `Project.swift`, `SiteRules.swift` `projectTable` | `project status` use; project-limit refusals | Projects that need tighter caps use it | watch |
| Cooldowns, soft-block detection | `SiteRules.swift` `Cooldown` | `events.jsonl` soft blocks; false alarms | Real blocks caught, few false ones | keep |
| Challenge hand-off | `SiteRules.swift` `Challenge` | `events.jsonl` challenges | Part of the product | keep |
| Site policy notes: user-set `terms_url`, `checked` date and `api` per domain, printed under `session`/`open`; nothing is refused since 6f958ba | `SiteRules.swift` `Policies`, `lines(for:)` | `policy <domain>` calls, and whether the six-month warning leads to a re-check | People add entries and act on the stale warning | watch |
| Allowlist per session | `allowCheck` | Allowlist refusals | Used in the start-up window | keep |
| Kill switch (ctrl+opt+cmd+.) stops every step and refuses new ones until the user answers; `resume` lifts it once they say to carry on | `Daemon.swift` `KillSwitch` (logs `kill_switch: true`), `Commands.swift` `resume`, `StatusItem.swift` | `kill_switch` rows in `steps.jsonl`, and whether a `resume` follows one | It gets used, or stays as insurance | keep |
| Privacy scrubbing | `State.swift` `Privacy` | Not measured | Required | keep |
| Rate limits, reload cap, nav gap | `State.swift` `Limits` | `rate limit` and `refresh limit` errors | They fire rarely and on real loops | keep |

## Talking to the user

| Feature | Where | How to measure | Keep if | Verdict |
| --- | --- | --- | --- | --- |
| `ask` (free text, `--choices`, `--multi`, `--text`, timeout) | `Ask.swift` `show` | `ask` rows; answers that lead to playbooks or fixes | Each answer leads to a playbook or fix, and the count falls | keep |
| Question routing and sound (`ask_in`, `ask_sound`, `ask_window_s`) | `Config.swift`, `Ask.swift` | Not measured | Quiet where the user works in a terminal | watch |
| `show` (the user points the cursor at it) | `Ask.swift` `pointAt` | `show` rows | It settles "where is it" without a screenshot | watch |
| Away mode, exit 9, and the screenshot of the screen it is about | `Ask.swift` `handOff`, `Notify.swift` `shot` | `away` rows, exit-9 count, `shots/ask-*.png` | Used when the user is remote | watch |
| Phone pushes: `phone on/off/test`, `--server`, random ntfy topic, QR code | `Notify.swift` | `notify` rows, push status, `phone` use | Questions reach the phone, and the user acts on them | watch |
| Menu-bar item: `α`, `α …`, `α ?`, `α !`, VM name, approve/deny, log, stop, resume, update notice | `StatusItem.swift` | Not measured: add a row when the menu approves, stops or resumes | The user drives approvals from the menu | watch |
| macOS notifications for cooldowns and challenges | `SiteRules.swift` `Site.notify` | Not measured | The user notices blocks without asking | watch |
| Keep-awake | `Awake.swift` | `awake` rows | Long runs finish without sleep | watch |

## The window, schedules and away

| Feature | Where | How to measure | Keep if | Verdict |
| --- | --- | --- | --- | --- |
| `app`: the window as its own process, opened from the Dock, Spotlight or the menu bar; every button sends the same request the CLI sends (`Request.user` marks the person's own click, so approvals and `user_only` steps work from it) | `AppUI.swift` `AppMain`, `AppBundle`, `AppModel` | `app` rows; approvals decided in the window versus the menu bar | The window is how the person works day to day | watch |
| Screens: Terminal, Schedules, Approvals (badge), Activity, Sites, Settings, Playbooks, VMs and Updates & health; ⌘1…9 and a ⌘K palette that runs any command and shows its output | `AppUI.swift` `RootView` and the screen views | Which section is opened; `grow` for the commands behind it | Every screen is used, and the palette replaces a terminal for quick commands | watch |
| Terminal tabs: a pty per tab (`$SHELL -l` in a folder, an optional start command), `[app.tabs]` presets, Claude Code / Codex / opencode / Kilo / a following `apprentice log`; `APPRENTICE_TAB`, `APPRENTICE_PROJECT`, `APPRENTICE_VM` set for the tab | `Terminal.swift` `Pty`, `TermSession`; `AppUI.swift` `TerminalWorkspace` | Log rows carrying `tab`; approvals answered in a tab | Agents run in tabs rather than the user's own terminal | watch |
| Terminal screen: alternate screen, 256 colours and truecolor, cursor addressing, erase, scroll regions, insert/delete, wide characters and scrollback; ⌘V paste | `Terminal.swift` `TermScreen`, `Renderer`, `TerminalTextView` | Not measured; a TUI that draws wrongly is a bug report | A coding agent's TUI draws correctly | watch |
| Inline ⚠ banner in the tab it came from, with Deny / Allow; the terminal ignores keys while it is open, so an agent cannot approve its own step | `AppUI.swift` `ApprovalBanner`; `State.swift` `Approvals.check` (`tab`) | `confirm` rows with `via` and `by`; steps approved from a banner | Banners become the usual way risky steps are approved | watch |
| `schedule`: prompts for an agent CLI, `run` tasks, flows and (unless `ui_only`) shell commands, later or again; once, every N minutes, daily, chosen weekdays or cron, ± jitter through `Rand`, quiet-hours shift, catch-up, overlap skip; adding or changing one from an agent is a `user_only` step | `Schedules.swift`; `Daemon.swift` `Schedules.install` | `schedule` rows (`started`, `result`, `skipped`); runs per schedule in `~/.apprentice/schedules/<id>/` | Scheduled work runs on time and is neither skipped nor doubled | watch |
| `schedule agent on`: a LaunchAgent starts `apprentice serve` at login, so schedules fire with nothing else open | `Schedules.swift` `installAgent`, `removeAgent` | The LaunchAgent is installed while schedules exist | Schedules fire after a restart or a reboot | watch |
| `away`: queued `do`/`run` work that runs only while the person is away and stops on their first input (exit 10); presence from idle time plus display-sleep assertions; the per-unit journal and the resume rule (proceed, undo and redo, or needs-you) | `Away.swift`; `Commands.swift` `run` (exit 10) and `type` (journal); `Daemon.swift` `Away.install` | `away` rows (`yielded`, `state`); `exit 10` in `sessions` | Away work finishes without colliding with the person | watch |
| `away wait`: blocks until the person leaves, so an agent pauses and resumes instead of retrying into an exit 10 | `Away.swift` `wait` | `away` rows from an agent's wait | Agents use it rather than retrying | watch |

## Learning and reuse

| Feature | Where | How to measure | Keep if | Verdict |
| --- | --- | --- | --- | --- |
| Playbooks | `Playbooks.swift`, `playbooks/` | Playbooks printed by `session` / `open`, then used | Questions about the same page stop | keep |
| Flows (`do`): one approval, `{vars}`, `#label` resolution, hand-back at the first failure | `Flows.swift` | Flows run, steps completed vs stopped (grow) | Most runs complete; they replace agent steps | keep |
| Per-model flow ranking: a flow's `model:` tag, other models' flows left out, `do --explain` prints the pick and score | `Playbooks.swift` `rank`, `explain` | Which model ran which flow; skips by other models | The model that learned a flow finds it first | keep |
| `sh:` steps inside flows | `Flows.swift` `shellCommand`, `runShell` | `cmd: sh` rows with the flow path | Tool flows run without the screen | watch |
| `do --explain` (which flow this model picks, and why) | `Playbooks.explain` | `--explain` calls | Agents check before running a flow blind | watch |
| Preferences (`remember`, `prefs`, `pref:` lines in `route`) | `Prefs.swift` | `remember` rows by `--from`; `ask` questions about the same thing before and after (grow) | Questions like "which gym?" stop coming back | watch |
| Per-device layers (a VM's own `~/.apprentice` and clone, inheriting from the Mac) | `Layers.swift`, `VM.seedClone` | Not measured: add the layer a pref or setting came from to `route` rows | VMs actually carry their own prefs or settings | watch |
| `learn` | `Playbooks.learn` | Flows drafted that later ran | Drafts turn into used flows | watch |
| Routes (`route`) and route hints on `session` / `open` | `Routes.swift` | `route` calls, hints followed | Agents take the route; no calls in the log means cut it | cut? |
| `run` loop (`--model`, `--base-url`, `--screen-anyway`, `--save`; stops at 40 steps, 15 minutes or 3 identical actions) | `AgentLoop.swift` | `run` sessions, steps, stops | Someone runs tasks without a coding agent; no uses means cut it | cut? |
| `replay <name> [--from n] [--approve]` | `AgentLoop.swift` `Replay` | `replay` runs, checks failed | Saved runs get replayed; none means cut it | cut? |
| Model and agent detection (`APPRENTICE_MODEL`, transcripts, configs, MCP) | `Agent.swift` | `model` on rows; `models` in grow | Flows are picked per model and it is the right model | keep |
| `grow`, `bug`, `commit` | `Grow.swift`, `Repo.swift` | Fixes made from grow items; commits that needed a rebuild | The tool keeps improving from use | keep |
| `pr`: local commits offered upstream from a fork, `--local`, session-copy disclosure | `PR.swift` | `pr` runs and PRs opened | Fixes reach upstream without force-pushing | watch |
| Skills: hand-written judgement in `skills/apprentice-*` (web, macos, linux, instagram, facebook, tiktok, linkedin, x, reddit), installed with apprentice in every agent's skills folder by `connect.py`, named by `session` / `open`, printed by `playbooks <skill>` and in the `run` loop's context. Skills say how a person behaves on a site or system; playbooks hold the mechanics (labels, steps, flows) | `skills/`, `Playbooks.swift` `skills`, `agent/connect.py` | Sessions on a skill's host vs soft blocks and challenges there (`activity`); `playbooks apprentice-*` calls | Fewer soft blocks and challenges on social sites; no extra questions | watch |

## Logs, sessions and review

| Feature | Where | How to measure | Keep if | Verdict |
| --- | --- | --- | --- | --- |
| `log --tail`, `log --session [<id>]` | `Commands.swift` `log`, `Sessions.story` | `log` calls | It replaces scrolling raw JSONL | keep |
| `sessions [--limit]` | `Sessions.swift` | `sessions` calls | Someone reviews runs | keep |
| `events.jsonl` (180 days), `activity`, `flag` | `SiteRules.swift` `Events` | `flag` rows; `activity` calls | Used after a warning | watch |
| Scrubbed session copies committed to the clone (`[storage] sessions = scrubbed / full / off`) | `Sessions.swift` `archive`, `scrub` | Which mode `doctor` reports; `pr`'s session line | Copies exist to learn from, without URLs or typed text | keep |
| Step-log pruning (30 days) and shot caps (50 per session) | `State.swift` `pruneLogs`, `Sessions.swift` `capShots` | Folder and file counts, age of the oldest run | `~/.apprentice/runs` and the clone stay small | keep |
| `--json` for every command | `Wire.swift`, `main.swift` | Requests with `json` | Scripts use it | watch |

## Platforms and integration

| Feature | Where | How to measure | Keep if | Verdict |
| --- | --- | --- | --- | --- |
| Linux VM (browser and apps) | `VM.swift`, `Remote*.swift`, `agent/vm/` | Share of rows with `vm: true`; VM errors | Most browser work moves there | keep |
| `vm setup`, `install`, `up`, `down`, `on`, `off`, `status`, `list` | `VM.swift` | `vm` rows by subcommand | The VM is installed once and kept current | keep |
| `vm call`, `vm look`, `vm shell` | `VM.swift` | Calls per challenge; `shell` use | The user passes checks through it, agents work by ssh first | watch |
| One VM per job (`APPRENTICE_VM`, `--vm <name>`) | `VM.swift`, `main.swift`, `Remote.swift` | `vm` names on rows; cross-VM budget counts | Agents run side by side without collisions | watch |
| Uploads and downloads across the Mac and the VM | `Remote+More.swift` `upload`, `download`, `push`, `pull` | Transfer rows and their errors | Transfers work without the shared folder | keep |
| Event-driven settle in the VM | `Remote.swift` `settled`, `helper.py` `quiet` | `waits.settle` on `vm` rows, before and after | Median settle near the helper's 250 ms quiet window (SPEC), and no rise in actions on a half-loaded page | watch |
| Polling settle on this Mac | `Reader.swift` `settle` | `waits.settle` on non-`vm` rows (no data yet) | Two reads 150 ms apart agree; if waits grow, add AXObserver events | watch |
| VM questions and `show` on the VM's screen | `Remote+More.swift` `askInVM`, `show` | Exit-9 and `show` rows with `vm: true` | Challenges get answered while the Mac stays free | watch |
| MCP server: 34 tools for reading and acting, including `approve`, `pending`, `resume` and `policy` (no `sessions`, `wait-for`, `grow`, `run`, `replay`, `vm`, `doctor`, `pr`, `project`, `serve`, `stop` or `uninstall`) | `MCP.swift` | Sessions started through `mcp` (add a field); tool calls by name | An agent without a shell uses it | watch |
| Daemon: `serve`, `stop`, auto-start, one queue per window, `ping` | `Daemon.swift`, `Wire.swift` | `stop` rows; daemon restarts in `doctor` | Commands never interleave on one window | keep |
| Wire protocol over a unix socket, 0700 state folder | `Wire.swift`, `State.swift` `Store` | `doctor`'s state check | Permissions hold; no TCP port | keep |
| Exit codes 0–9 and compact text output | `main.swift`, `Wire.swift` | `code` on rows; agent misuse from bad exit handling | Agents branch on codes, not prose | keep |
| CLI agent docs and installer wiring (`SKILL.md`, `AGENTS.md`, `connect.py`) | `agent/` | Agent errors from misuse (bad flags, wrong order) | Misuse errors fall | keep |
| `project init`, `project status`, `APPRENTICE_PROJECT` | `Project.swift` | `project` calls; project-limit hits | Used by projects that need tighter caps | watch |
| `settings [local]` | `Settings.swift` | `settings` calls | Old synced installs move back cleanly | watch |
| `install.sh` and `kit.sh`: release build, `selftest` gate, signing with a local `apprentice` identity, install to `~/.local/bin`, PATH, example configs, VM install, `doctor --fix` | `install.sh`, `kit.sh`, `Doctor.swift`, `agent/connect.py` | Install runs, failed builds, the ad-hoc signing warning `doctor` prints | People install once and keep their grants across rebuilds | keep |
| Self-update: fetch every `[update] check_hours` (6), rebase local commits, rebuild, self-test, roll back on failure, restart when idle, `https`/`ssh` upstream only | `Repo.swift`, `Build.swift` | Update rows, rollbacks, the update line `session` prints | Updates land without losing commits or permissions | watch |
| `install.json` and `version` (the installed commit); CI builds the universal binary and runs `selftest`, releases on `v*` tags | `Build.swift`, `.github/workflows/` | `version` calls; CI and release failures | `version` matches the tag and CI stays green | keep |
| `[vm] host` (a guest on another machine), `[vm] local` (sites kept on this Mac even with `vm on`), `[agent] notify`, `menu_bar`, `ask_on_start`, `keep_awake`, and the `APPRENTICE_*` overrides | `Config.swift`, `Remote+More.swift`, `VM.swift`, `Notify.swift` | Which keys and overrides a run used (add them to rows) | People configure a VM host or keep a site local, and it works | watch |
| `doctor [--fix]`, `uninstall [--all] [--yes]`, `selftest`, `repo`, `version` | `Doctor.swift`, `SelfTest.swift`, `Repo.swift`, `Build.swift` | `doctor` gaps reported; selftest failures; uninstall runs | First runs succeed and selftest stays green | keep |

## Coverage map

Every source file, and where its features are listed above. Nothing in `Sources/apprentice` is left out.

| File | Features |
| --- | --- |
| `AX.swift` | Accessibility reads, sets and actions; element info |
| `Agent.swift` | Model and agent detection |
| `AgentLoop.swift` | `run` loop, `replay` |
| `Ask.swift` | `ask`, `show`, `confirm`, away hand-off, start-up window |
| `Awake.swift` | Keep-awake |
| `Build.swift` | `version` |
| `Capture.swift` | `shot`, `shot --crop`, `shot --marks`, `ocr`, Screen Recording check |
| `Commands.swift` | `session`, `focus`, `open`, `read`, `click`, `type`, `key`, `menu`, `scroll`, `browse`, `hover`, `drag`, `upload`, `download`, `choose`, `wait-for`, `ocr`, `shot`, `log`, `pending`, gate proposals |
| `Config.swift` | Pace styles and profiles, `[session] allow`, `[agent]`, `[sites]`, `[run]`, env overrides, remember |
| `Daemon.swift` | `serve`, `stop`, per-window queues, kill switch |
| `Doctor.swift` | `doctor`, `doctor --fix`, `uninstall` |
| `Fidget.swift` | Scroll flicks, fidgets, `browse` scrolling |
| `Flows.swift` | `do`, `do --explain`, `sh:` steps, look pauses, hand-back |
| `Grow.swift` | `grow` digest and pace summary |
| `Input.swift` | Pointer paths, keys, borrow mode, watching for the person, paste |
| `MCP.swift` | MCP server and its tools |
| `Playbooks.swift` | Playbooks, skills, `learn`, `bug`, flow ranking, `context(task:)` |
| `Notify.swift` | `phone`, away-mode pushes, question screenshots |
| `PR.swift` | `pr`, `pr --local`, session-copy disclosure |
| `Project.swift` | `project init`, `project status`, project limits |
| `Rand.swift` | Shared random generator |
| `Reader.swift` | Numbered list, element kinds, diffs, stable ids, settle, snapshot cache, snapshot numbers |
| `Remote.swift` | VM routing and the VM half of every command, event-driven settle |
| `Remote+More.swift` | VM transfers, dialogs, `shot`/`ocr`/`wait-for`/`drag`/`show`/questions on the VM |
| `Repo.swift` | `repo`, `commit`, `update`, auto-update, restart when idle, update notice |
| `Routes.swift` | `route`, route hints, learned routes |
| `SelfTest.swift` | `selftest` |
| `Sessions.swift` | `sessions`, `log --session`, scrubbing, archiving, shot caps, storage mode |
| `Settings.swift` | `settings`, `settings local` |
| `SiteRules.swift` | Budgets, cooldowns, soft blocks, challenges, policy notes, dwell, `cool`, `budget`, `activity`, `flag`, notifications |
| `State.swift` | Store and locking, sessions, logging, privacy, rate and nav limits, gate, approvals |
| `StatusItem.swift` | Menu-bar item and its menu: approve, deny, log, stop, resume, update notice |
| `AppUI.swift` | `app` window: bundle, sidebar screens, tabs, banner approvals, command palette |
| `Away.swift` | `away` queue, presence, exit 10, the unit journal and the resume rule |
| `Schedules.swift` | `schedules.toml`, next-fire maths, jitter, quiet hours, catch-up, the daemon timer, `schedule`, the LaunchAgent |
| `Terminal.swift` | pty tabs, the xterm screen model and the terminal view |
| `VM.swift` | `vm` subcommands, ssh, screen viewer |
| `Wire.swift` | Wire protocol, daemon start/stop, `--json` |
| `main.swift` | `help`, usage, `--vm`, exit codes, command routing |

## Command index

Every command the CLI accepts, and the section that scopes it. `help` and `version` are accepted without being printed by `usage()`.

| Command | Section |
| --- | --- |
| `doctor [--fix]` | Platforms and integration |
| `session [--app] [--on] [--new-window] [--allow] [--task] [--no-options]` | Sessions and windows |
| `focus <app> [--on]` | Sessions and windows |
| `open <url>` | Acting |
| `read [--max] [--filter]` | Reading the screen |
| `click <id> \| --on \| --at [--double] [--right]` | Acting |
| `type <id\|focused> [--enter] [--pace]` | Acting |
| `key <combo>` / `menu "A > B"` | Acting |
| `scroll up\|down [n] [--in]` / `hover` / `drag` / `browse [s] [--in]` | Acting |
| `upload` / `download` / `choose` | Acting |
| `wait-for "text" [--timeout]` | Reading the screen |
| `ocr [--crop]` / `shot [--crop] [--marks]` | Reading the screen |
| `approve [--text]` / `deny` / `pending` / `resume` | Safety |
| `ask [--choices] [--multi] [--text]` / `show` / `confirm [--why]` | Talking to the user |
| `away on\|off\|status\|wait\|add\|list\|cancel\|run` / `phone [on\|off\|test]` | Talking to the user |
| `app` | The window |
| `schedule add\|list\|show\|pause\|resume\|rm\|now\|agent` | The window |
| `awake on\|off\|status` | Talking to the user |
| `do <flow> [--key value]` / `do --explain` | Learning and reuse |
| `playbooks ["words"]` / `learn "task" [--name] [--model] [--force]` / `route "task"` | Learning and reuse |
| `run "task" [--model] [--base-url] [--screen-anyway] [--save]` / `replay <name>` | Learning and reuse |
| `grow [--days]` / `bug "summary" [--repro] [--cause] [--fix]` / `commit "why"` / `pr [--title] [--draft] [--fork] [--local]` | Learning and reuse |
| `policy [domain]` (notes on a site's terms; the bare form sets whether shell commands are allowed) / `budget [domain]` / `cool [--clear domain]` | Safety |
| `activity <domain> [--days]` / `flag <domain> "note"` | Logs, sessions and review |
| `log [--tail] \| --session [<id>]` / `sessions [--limit]` | Logs, sessions and review |
| `settings [local]` / `repo` / `version` / `selftest` | Platforms and integration |
| `project [init\|status]` | Platforms and integration |
| `update [--check] [--build]` | Learning and reuse |
| `serve [--background]` / `stop` | Platforms and integration |
| `mcp` | Platforms and integration |
| `vm setup\|install\|up\|down\|on\|off\|look\|call\|shell\|list\|status` | Platforms and integration |
| `uninstall [--all] [--yes]` | Platforms and integration |
| `--vm <name> …` (before any command) | Platforms and integration |
| `--json` (on any command) | Logs, sessions and review |

## Gaps to close

These features can't be measured yet:

- The snapshot cache's hit rate.
- Which pace profile and style each row ran under.
- Whether a `resume` ever follows a kill-switch stop (`resume` logs nothing of its own).
- How a session started (CLI, MCP or `run`); `run` logs `via: run`, MCP logs nothing of its own.
- Menu-bar approvals, denials, log opens and stops.
- Phone pushes: whether they arrived, and whether the user answered from the phone.
- Detail beyond `cmd` and exit code for the client-side commands: `pr`, `project`, `policy`, `settings`, `doctor`, `update`, `replay`, `phone` and `vm` log only that row. `selftest`, `uninstall`, `mcp` and `serve` are not in `loggedHere`; `stop` logs its own row from the daemon.
- `sh:` flow steps against screen steps in the same flow.
- Unknown flags are accepted in silence: `Args` takes any `--x value` pair, so a typo like `--tier` (which no longer exists) is swallowed instead of refused.

Adding one log field each, and a grow line that totals them, makes the next review possible.
