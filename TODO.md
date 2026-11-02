# TODO

## The VM

It runs: Debian guests under Tart (2 GB disk, 2 GB memory each) or on a server (`[vm] host`), any number at once (`APPRENTICE_VM`), driven from `Remote.swift` with the same commands as the Mac, uploads, downloads, `shot`, `ocr`, `show` and questions on the VM's screen included. Still open:

- **Working with the Mac off.** Asked for 2026-11-01: keep the settings in a server VM, synced with the Mac when it is on, so a Claude task, command or MCP server can drive the web while the Mac is off. Today the brain (approvals, budgets, pacing, logs) is the Mac's Swift daemon, so this needs it on Linux: either a Linux build of the parts that are not AppKit (`Remote`, `SiteRules`, `State`, `Config`, the wire), or a small daemon in the guest that speaks the same wire. Approvals would go to the chat (exit 9), since nobody is at a window.
- **Linux app sessions are untested on a live VM** (openbox, wmctrl and xfce4-terminal were added to provision.sh).
- A budgeted step is counted when it is approved, so an upload that then fails still uses up the site's budget (seen in testing: three failed tries reached the hourly cap). Count it once the step went through.
- Characters with no key on the guest's US layout get a spare keycode, so their `code` is unusual. The Mac does the same for characters its layout lacks (code 0).
- Several VMs share one ssh key. Per-VM keys would let one be revoked alone.
- The VM's question window (`agent/vm/ask.py`) has no apprentice icon and does not notice when the caller stops waiting, unlike the Mac's (`Ask.waiting`).
- Only `ask` and `confirm` watch their caller. The other windows (start-up options, challenge and cooldown checks in `SiteRules`, the VM's "show me") stay open after the agent gives up; pass `caller:` to `Ask.show` there too.

## Code structure

From a `/simplify` pass on 2026-11-02; the small shared helpers landed, these were left because they change behaviour or reach across many files:

- **Each action command has a Mac body and a VM body** (`Commands.swift` open…hover against `Remote.swift`, and `Remote+More.swift`). They have drifted: VM `type` lacks the "still shows what it had before" check, `click --on` falls back to OCR only on the Mac, `menu` reads `a.pos.joined` on the Mac but `a.pos.first` in the VM. A `Surface` (prepare, resolve, act, settle, bounds, focused field) with a local and a Remote side would let each command be written once.
- **Command properties are scattered** across about ten sets and `cmd ==` checks (`Site.inspect`, `Fidget`, `approveStep`, `Commands.asides`, `Daemon.queue(for:)`, `Remote.commands`, `Notes.actions`, `Grow.Pace.actions`, `loggedHere`). One table keyed by command name (looks, sends, navigates, fidgets, queue, vm, budget kind). `Notes.actions` and `Grow.Pace.actions` already disagree on `download` and `do`.
- **Session binding and the banner are written three times** (`Commands.attach`/`session`, `Remote.session`, `Remote.appSession`).
- **"Chromium" is hard-coded as the VM's browser** in about six places (`State.swift` `isBrowser`, `Remote.inBrowser`, `Remote.session`, the `open` error); one `VM.browser` constant, and `session.isBrowser` instead of `inBrowser`.
- The VM challenge hint is added by matching `fail.message.contains("challenge")` (`Remote.swift`); `Challenge.start` has the session and could add it itself.
- A ⚠ proposal in the VM keeps no gate screenshot (`approveStep` skips it); one capture helper that picks `Capture.window` or `Remote.screen`.
- `choosePath` sleeps a flat 1.5 s after each paste; poll for the field's value instead.
- The Mac `settle` has no grace for a page that starts loading late, unlike `Remote.done(navigates:)`.
- Daemon start-up prunes logs and events before the socket listens; run them after `server.start()`.

## Pacing

- Try `browse`, fidgets and the new path shapes live, on this Mac and in the VM, and tune the ranges in `Fidget.swift` and `Mouse.stroke` from what they look like (only `selftest` has run them so far).
- Log the active pace style and profile on each row, so FEATURES.md can tell whether `careful` sites see fewer soft blocks.
- `run`'s tiny grammar has no `browse` yet.
- Try `scroll left|right`, `scroll --at` and `drag --by` live on a web map, on this Mac and in the VM (only `selftest` has run them): check the sideways direction is right, and that `Mouse.drag`'s straight 12 ms steps pan smoothly. It may need the curved `Mouse.stroke` path and a short hold before the move.
- No pinch or trackpad zoom (gesture events). The wheel and `+`/`-` cover web maps, but some apps zoom only by pinch.

## Install

- CI publishes a universal binary on `v*` tags; notarize it and have `install.sh` prefer it (falling back to building), so most users need no Swift toolchain. Today `install.sh` builds from source and needs the Xcode command-line tools.
- A first-run window (what apprentice is, the two grants with live check marks, a "try it on Finder" button) needs an app bundle. Until then `doctor --fix` is the interactive terminal checklist.

## Updates

- Fixes stay in each Mac's clone. To share them, point another Mac's `upstream` at this clone (any git URL works). If that turns out to be common, add `apprentice share`.

## Tests

`apprentice selftest` covers TOML, args, pace limits, the wire format, VM routing, `diff`, the approval gate, shared site limits and the automatic update (against throwaway git repos), in a temporary home of its own. Still to add: the VM's helper (`agent/vm/helper.py`) has no tests of its own; it is checked against a live VM by hand.

## Releases

- The site and README name Devin and Grok, which work through their shells, but `agent/connect.py` doesn't install the apprentice rules for them yet. Add them once their global rules locations are confirmed.
- `release.yml` ships the binary unsigned until the `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`, `APPLE_ID`, `APPLE_APP_PASSWORD` and `APPLE_TEAM_ID` secrets are set (a Developer ID account).
- Installs update from `main`, not from tagged releases. Decide whether `install.sh` and `[update]` should follow the latest release tag instead, so users only get versions that passed the release run.

## Production readiness follow-ups

- The start-up options window still runs on the command queue, inside the first `session`; only `ask`, `confirm`, `show`, `log` and `pending` moved off it.
- `restartWhenIdle` does not see a VM daemon's pending approval or a VM call in flight beyond the one-minute quiet window.
- `bug --fixed` was not added: fixed reports are deleted from `BUGS.md` and the commit is the record, so `pr` cites the `F<n>` the commit subjects name.
- MCP does not expose `sessions`, `do --explain` or `log --session` yet.
- Flows gained `sh:` steps; `learn` still drafts only screen steps, so a shell flow is written by hand.

## Agent commands

- The weak-agent trial harness (`.agents/skills/improve-prompts/scripts/agent_runs/`) has no planted tasks: the three that came over from compledo were Dart-specific and were dropped. Add a few for apprentice (for example a stale exit code in `agent/SKILL.md` for `/update-docs`) before `/improve-prompts` can measure anything.
- `/improve-prompts` has no tool for the app's own prompt (the `run` loop's system prompt in `AgentLoop.swift`); a replay set and a scorer would let it tune that too.

## Site

- `robots.txt` is not served: Pages publishes `site/` under `/apprentice/`, and crawlers read only the domain root (`robertsolves.github.io/robots.txt`). Submit `https://robertsolves.github.io/apprentice/sitemap.xml` in Google Search Console and Bing Webmaster Tools instead, or move the site to its own domain and add one there.
- `sitemap.xml` has a hand-written `lastmod`; bump it when the page changes, or have the Pages workflow write it from the last commit date.
- No per-feature pages yet (approvals, Linux VM, site rules, supported agents): each would give search and answer engines a page that answers one question.
