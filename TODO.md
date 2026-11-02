# TODO

## The VM

It runs: Debian guests under Tart (2 GB disk, 2 GB memory each) or on a server (`[vm] host`), any number at once (`APPRENTICE_VM`), driven from `Remote.swift` with the same commands as the Mac, uploads, downloads, `shot`, `ocr`, `show` and questions on the VM's screen included. Still open:

- VM `click --on` by OCR and `helper.py` skipping `apprentice-ask` on the accessibility bus are untested on a real VM.
- **Working with the Mac off.** Asked for 2026-11-01: keep the settings in a server VM, synced with the Mac when it is on, so a Claude task, command or MCP server can drive the web while the Mac is off. Today the brain (approvals, budgets, pacing, logs) is the Mac's Swift daemon, so this needs it on Linux: either a Linux build of the parts that are not AppKit (`Remote`, `SiteRules`, `State`, `Config`, the wire), or a small daemon in the guest that speaks the same wire. Approvals would go to the chat (exit 9), since nobody is at a window.
- **Linux app sessions are untested on a live VM** (openbox, wmctrl and xfce4-terminal were added to provision.sh).
- Characters with no key on the guest's US layout get a spare keycode, so their `code` is unusual. The Mac does the same for characters its layout lacks (code 0).
- Several VMs share one ssh key. Per-VM keys would let one be revoked alone.
- The VM's question window (`agent/vm/ask.py`) has no apprentice icon and does not notice when the caller stops waiting, unlike the Mac's (`Ask.waiting`).
- Only `ask` and `confirm` watch their caller. The other windows (start-up options, challenge and cooldown checks in `SiteRules`, the VM's "show me") stay open after the agent gives up; pass `caller:` to `Ask.show` there too.

## Code structure

From a `/simplify` pass on 2026-11-02; the small shared helpers landed, these were left because they change behaviour or reach across many files.

- **Each action command has a Mac body and a VM body** (`Commands.swift` open…hover against `Remote.swift`, and `Remote+More.swift`). They have drifted: VM `type` lacks the "still shows what it had before" check, `click --on` falls back to OCR only on the Mac, `menu` reads `a.pos.joined` on the Mac but `a.pos.first` in the VM. A `Surface` (prepare, resolve, act, settle, bounds, focused field) with a local and a Remote side would let each command be written once.
- **Command properties are scattered** across about ten sets and `cmd ==` checks (`Site.inspect`, `Fidget`, `approveStep`, `Commands.asides`, `Daemon.queue(for:)`, `Remote.commands`, `Playbooks.actions`, `Grow.Pace.actions`, `loggedHere`). One table keyed by command name (looks, sends, navigates, fidgets, queue, vm, budget kind). `Playbooks.actions` and `Grow.Pace.actions` already disagree on `download` and `do`.
- **Session binding and the banner are written three times** (`Commands.attach`/`session`, `Remote.session`, `Remote.appSession`).
- **"Chromium" is hard-coded as the VM's browser** in about six places (`State.swift` `isBrowser`, `Remote.inBrowser`, `Remote.session`, the `open` error); one `VM.browser` constant, and `session.isBrowser` instead of `inBrowser`.
- The VM challenge hint is added by matching `fail.message.contains("challenge")` (`Remote.swift`); `Challenge.start` has the session and could add it itself.
- A ⚠ proposal in the VM keeps no gate screenshot (`approveStep` skips it); one capture helper that picks `Capture.window` or `Remote.screen`.
- `choosePath` sleeps a flat 1.5 s after each paste; poll for the field's value instead.
- The Mac `settle` has no grace for a page that starts loading late, unlike `Remote.done(navigates:)`.

## Pacing

- Re-run the canary on this Mac after the per-pair typing rhythm, the drag correction and settle, and no repeated rest pixels (BOT_DETECTION P1 P7 P21 P22, marked 🔁): with and without `typing learn`, and add a check to `agent/canary.html` that per-pair gaps are consistent across runs and no two pointer rests share a pixel.
- Typing in the VM goes one character at a time (`Remote.typeChar`): send down and up times so the per-pair rhythm and overlap reach it too.
- Read the canary's Metrics section in a VM session (`apprentice do canary-full-test` there) and add the VM column to BOT_DETECTION.md; the Mac numbers are in.
- Tab between form fields where the next field is the obvious one, instead of a click per field (BOT_DETECTION P11).
- A real IME composition path for CJK locales: today a character no key types is pasted (P12).
- `open` to a new site could open a new tab now and then (cmd+t), so the tab set changes as a person's does (P17). Needs a cap so tabs do not pile up.
- A consent-wall step with its own dwell and a remembered choice per site (BOT_DETECTION S10); a playbook may do for the big sites.
- A smaller re-read after an action whose diff is small, instead of a full walk (BOT_DETECTION A5).
- Try `browse`, fidgets and the new path shapes live, on this Mac and in the VM, and tune the ranges in `Fidget.swift` and `Mouse.stroke` from what they look like (only `selftest` has run them so far).
- Log the active pace style and profile on each row, so FEATURES.md can tell whether `careful` sites see fewer soft blocks.
- Try `scroll left|right`, `scroll --at` and `drag --by` live on a web map, on this Mac and in the VM (only `selftest` has run them): check the sideways direction is right, and that `Mouse.drag`'s curved stroke pans smoothly.
- No pinch or trackpad zoom (gesture events). The wheel and `+`/`-` cover web maps, but some apps zoom only by pinch.

## UI

The window (`apprentice app`), schedules and away are built; FEATURES.md lists what they do.

- Terminal: split panes inside a tab (⌘D / ⇧⌘D); tab drag-reorder, pinning and torn-off windows; scrollback restored across a relaunch (`[app] keep_scrollback` is read but not yet used); clickable paths and URLs; find in scrollback (⌘F); copy on select; per-preset environment keys.
- Terminal fidelity: mouse reporting and bracketed paste are accepted and ignored; some rare DEC modes are not emulated. Verified against a shell and `claude`, not against every TUI.
- The new-site wizard should preview the TOML it will add; today it writes it and shows the result.
- `[agent] ask_in = "app"`: answering an `ask` in the tab's banner instead of the floating window.
- The window is for someone who is not technical (decided 2026-11-02): Terminal, Schedules, Playbooks, VMs, Settings and Updates only. Sites, Activity, an Approvals list, the phone set-up and the raw config form left it for the CLI; anything new goes in only if its label needs no explanation. A per-site note belongs in a playbook, not a Sites page.
- Help tab: needs Claude Code on the Mac; falls back to `apprentice --help`. Offer Codex or opencode when `claude` is missing, and a `[app] help_agent` key.
- Settings shows `Setting.shown` (`AppForms.swift`); `[run]` (the API key for `apprentice run`) is set in the file or `apprentice settings`, not in the window.
- LaunchAgent offer: the hint is in `schedule add`'s output and on the Schedules screen, not a modal when the first schedule is added.
- Away resume by the journal: `Away.decide` (proceed / redo / needs-you) is written and tested but nothing calls it, and there is no field undo, so a return always makes the task needs-you. An undo must check the focused field holds exactly the unit's text (its digest), in the unit's window, and press its keys through `gate()` and `Borrow.run`, never while the user is at the Mac.
- Schedules written by hand: the daemon runs whatever `schedules.toml` holds, so an agent with a shell can add one without the gate (as it could a crontab). A record of what the user approved (a keyed hash in the keychain) would let the daemon skip entries nobody approved.
- With an ad hoc signature, `Peer.isApp` trusts whatever code is in `~/.apprentice/Apprentice.app`, which a same-user process can replace; with a signing identity it checks the certificate (`kit.sh` already warns when it signs ad hoc).

## Install

- The DMG app's first launch sets up silently (CLI link, playbooks, agents); a first-run screen with the two grants and live check marks, and a "try it on Finder" button, would replace `doctor --fix` for app installs.
- A release install has no Linux VM set-up yet: `install.sh` installs Tart and provisions the VM; the app should offer the same from the VMs screen.
- `Release.install` swaps the app in place, which needs write access to the folder holding it (an admin user, for /Applications); a standard user gets an error and must drag the new DMG in by hand.
- The release install path (download, checksum, signature check, swap, relaunch) is tested only in parts (`selftest`); run it end to end against a real draft release once one exists.

## Updates

- A VM's own layer covers `prefs.json` and `config.toml`. `routes.toml` and `budgets.json` stay on the Mac (budgets are shared on purpose, since a site sees one account); layer `routes.toml` if VMs need their own routes.
- The VM's clone follows the Mac clone's current branch only when it is first made; if the Mac switches branch, `vm install` rebases the VM's checkout onto the new branch instead of switching to it.
- Fixes stay in each Mac's clone. To share them, point another Mac's `upstream` at this clone (any git URL works). If that turns out to be common, add `apprentice share`.

- **Scan more of what `pr` shares for personal details.** `Playbooks.leaks` guards only `playbooks/`. Field reports in `BUGS.md` (filed by `bug` with the last error) and commit messages outside playbook commits also reach upstream through `pr`; run them through the same check there. Name parts of the user's identity that are common words (Will, Mark) can trip the check; consider an allowlist in config if that happens.

## GitHub account

- **Install the `apprentice-cli` GitHub App on `robertsolves/apprentice`** before error reports ship: a user token reaches only repos the app is installed on. GitHub wants a private key generated before an app can be installed; the key is never used (device flow needs none), so delete it after installing. Settings sync would add Contents read and write, which every user then re-approves.
- **Error reports to the project's issues** (planned 2026-11-02): apprentice's own failures (a crash, exit 1, a failed update; exit 2 or 5 only when one fingerprint repeats) become a scrubbed fingerprint; an open issue with that fingerprint gets a 👍, else a new one is opened, labelled `auto-report`. `[report] errors = "ask" | "auto" | "off"`, asked once through `confirm` and in `tour`; checked by `Playbooks.leaks` before sending, since issues are public. Upstream, `triage.yml` closes duplicates and keeps a pinned queue, and the Claude Code GitHub Action fixes issues past a threshold as PRs for the owner to merge.
- **Settings in the user's own private repo** (planned): `prefs.json`, `voice.md`, `setups/`, typing timings, encrypted with a Keychain key; never secrets, budgets, logs or session state, and never the fork or a PR.
- `account status` reads only the login; once reports exist, show what was reported from this Mac.

## Tests

`apprentice selftest` covers TOML, args, pace limits, the wire format, VM routing, `diff`, the approval gate, shared site limits and the automatic update (against throwaway git repos), in a temporary home of its own. Still to add:

- The VM's helper (`agent/vm/helper.py`) has no tests of its own; it is checked against a live VM by hand.
- `Limits.beforeAction` at the per-minute cap waits (from /interview-code; a real wait, so it needs a clock it can stub).

## Releases

- The site and README name Devin and Grok, which work through their shells, but `agent/connect.py` doesn't install the apprentice rules for them yet. Add them once their global rules locations are confirmed.
- `release.yml` ships the binary and the DMG unsigned until the `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`, `APPLE_ID`, `APPLE_APP_PASSWORD` and `APPLE_TEAM_ID` secrets are set (a Developer ID account).
- Clone installs update from `main`; the DMG app updates from tagged releases. Decide whether clones should follow the latest release tag too, so users only get versions that passed the release run.

## Production readiness follow-ups

- The start-up options window still runs on the command queue, inside the first `session`; only `ask`, `confirm`, `show`, `log` and `pending` moved off it.
- `restartWhenIdle` sees a VM daemon's pending approval and recent activity, but not one long VM command still running after its one-minute quiet window.
- `bug --fixed` was not added: fixed reports are deleted from `BUGS.md` and the commit is the record, so `pr` cites the `F<n>` the commit subjects name.
- MCP does not expose `sessions`, `do --explain` or `log --session` yet.
- Flows gained `sh:` steps; `learn` still drafts only screen steps, so a shell flow is written by hand.

## Agent commands

- Site skills (`skills/apprentice-<site>`) were written from general knowledge, not from runs: the limits and messages they name (LinkedIn's weekly invitations and note allowance, X's duplicate rule, Reddit's "doing that too much", TikTok's puzzles) need confirming on real sessions, then the wording tightened. Add skills for other `Config.socialSites` (threads, pinterest, youtube, bsky) once they see use.
- The MCP apps (Claude desktop, Cursor) don't get skills as skills: they rely on `session`'s `skills ·` line and the `playbooks` tool with the skill's name. Check in `grow` whether they actually load them, and if not, expose the skills as MCP prompts or resources, or have `session` print a site skill's first section on the first visit.

## Site

- `robots.txt` is not served: Pages publishes `site/` under `/apprentice/`, and crawlers read only the domain root (`robertsolves.github.io/robots.txt`). Submit `https://robertsolves.github.io/apprentice/sitemap.xml` in Google Search Console and Bing Webmaster Tools instead, or move the site to its own domain and add one there.
- `sitemap.xml` has a hand-written `lastmod`; bump it when the page changes, or have the Pages workflow write it from the last commit date.
- No per-feature pages yet (approvals, Linux VM, site rules, supported agents): each would give search and answer engines a page that answers one question.
