# apprentice Spec

This is the one design document for apprentice. It covers what the tool is, how it reads and acts, how it paces input, the rules it keeps on each site, what a site could still notice, and what is left to build. It replaces the earlier `SITE_RULES.md`, `HUMAN_PACE.md`, `sneak.md` and `features.md`. Where this document and the code disagree, the code is the source of truth.

## Overview

apprentice is a macOS command-line tool that lets any coding agent (Claude Code, opencode, Kilo) or any hosted model (Claude, DeepSeek, OpenRouter) read and control desktop apps and websites on the user's own machine and accounts. It reads the screen as a short numbered text list and acts on elements by number, so a typical step costs tens of tokens, not an image.

It is sized for one person operating a handful of tools and accounts. The aim is to let a solo owner keep that work moving with the care of a larger team, without the headcount: one session window, one account, and the same pace and approval a person would use by hand. It is a way for one person to compete with better-funded teams on care and consistency, not on volume. It is not a bulk outreach, scraping or growth-automation tool.

Core principles:

- **One person, real accounts.** Every session belongs to the person at the keyboard, on accounts they already use. There is no multi-account mode and no bulk sending.
- **Limited by design.** Navigation gaps, rate caps, budgets and approval gates keep work at a person's pace instead of a script's.
- **Text, not pixels.** The macOS accessibility tree is the main source of truth. Screenshots and OCR are fallbacks.
- **Real input, like a person.** Every action is a real cursor move, click or keystroke with the window in front. Accessibility only reads the screen. The user's own keys or clicks stop an action.
- **Nothing added to the browser.** No extension, WebDriver, CDP or injected script. Sites see the user's normal browser with its normal cache, cookies and logins.
- **The calling agent is the brain.** apprentice is a toolset, not an agent. An optional built-in loop exists for running cheap models on their own.
- **APIs before screens.** GitHub and other services with a CLI or API go through that (for example `gh`). apprentice covers what has no API.
- **Approval before every change.** Every action that can change state is proposed first and runs only when the calling LLM approves it. The LLM decides, or asks the user; the chain is CLI ↔ LLM ↔ the user.
- **Every decision is in the config files.** apprentice never refuses a site on its own. Budgets come only from `budgets.json`; what a rate limit or a challenge does is `[sites] on_soft_block` and `on_challenge` (`stop`, `warn` or `off`); which steps only the user may approve is `[gate] user_only`. The defaults are careful: they stop on a rate limit or a challenge and keep caps well below shadow-ban levels, and payments, CAPTCHAs and passwords are always the user's to approve.

## Goals and non-goals

Goals:

- Control websites the user owns or uses: read, navigate, post, like, upload and download images, change account settings.
- Help a solo owner run several tools and services at once, so routine operations don't need a larger team.
- Keep normal per-person usage: budgets, gaps and approvals are part of the tool, not add-ons.
- Drive native macOS apps the same way.
- Be called as a plain CLI by Claude Code, opencode, Kilo or any script, with an optional MCP wrapper.
- Work with any hosted model behind an OpenAI-compatible API: Claude, DeepSeek, OpenRouter.
- Keep tokens minimal: text element lists, diffs after each action, no images unless asked.
- Be fast: most reads served from cache in milliseconds, most actions instant.
- Work in one window with the real cursor and keyboard, pausing whenever the user uses the computer.
- Pace input the way a person would: curved mouse paths with corrections, varied keystrokes, time on a page before acting on it.
- Never refresh pages rapidly. A limiter in the daemon enforces this.
- Log every step so a run can be replayed and debugged, and keep a longer per-site record so a restriction can be reviewed.

Non-goals:

- Bypassing CAPTCHAs, login walls, 2FA or other access controls, or continuing after a site signals a limit. apprentice may pace input and back off; it stops there.
- Spoofing fingerprints or browser state, or getting around a site's terms.
- Multi-account operation (several accounts on one site), bulk messaging, mass following, or scraping at volume.
- Sessions in parallel on this Mac's own screen. Parallel sessions run one per VM (`APPRENTICE_VM`), and every site's budgets and cooldowns count across all of them.
- Windows. Linux only inside apprentice's VM, driven from the Mac.
- Replacing APIs. GitHub work goes through `gh`, and any service with an API uses it first.
- Cloud hosting.
- Local models (Ollama, LM Studio, llama.cpp, vLLM). Not a target for now; the `run` loop only needs to work with hosted APIs.

## Architecture

apprentice is one signed Swift binary that runs as both a CLI and a background daemon. The first CLI call starts `apprentice serve`. After that, each call is a short request over a unix socket (`~/.apprentice/sock`), so callers pay no startup cost and macOS permissions are granted once, to the daemon.

```
Claude Code (SKILL.md)   opencode / Kilo (AGENTS.md)   run loop (any model)
          \                        |                        /   ── route check first ──▶  Faster routes (gh, APIs, connectors)
           ▼                       ▼                       ▼
                 apprentice CLI  (compact text out, exit codes)
                                   │ unix socket
                                   ▼
   apprentice daemon (one signed Swift binary)
   Reader · Actor · Pacer · Gate · Site rules · Vision · Routes · Log · Config
                                   │
                                   ▼
   macOS: Accessibility API, CGEvent, ScreenCaptureKit, Vision
                                   │ acts here only
                                   ▼
   Agent window (Safari or app)        Other windows: not touched
```

Callers check faster routes first; everything else goes through one CLI to the daemon, which acts only on the agent's window.

| Component | Code | Job |
| --- | --- | --- |
| CLI | `main.swift`, `Args` in `Commands.swift` | Parse a command, send it to the daemon, print compact text, set the exit code |
| Daemon | `Daemon.swift`, `Wire.swift` | Hold sessions, caches, limits and the approval gate; run one command at a time |
| Reader | `Reader.swift` | Walk the target window's accessibility tree and emit the numbered element list |
| Actor | `Input.swift` (`Keys`, `Mouse`, `Borrow`) | Real cursor moves, clicks, scrolls and keystrokes on the system input stream |
| Pacer | `Pace` in `Input.swift`, `Limits` in `State.swift` | Paths, timing, gaps, bursts, navigation and rate limits |
| Gate | `gate()` in `Commands.swift`, `Approvals` in `State.swift` | Propose → approve/deny for every state-changing action |
| Site rules | `SiteRules.swift` | Budgets, cooldowns, challenge stop, site policies, event history |
| Vision fallback | `Capture.swift` | Capture one window, OCR it, crop for `shot` |
| Ask | `Ask.swift` | A little window for the user: text, choices, point at it, confirm a step |
| Routes and playbooks | `Routes.swift`, `Playbooks.swift`, `Flows.swift` | Faster-route hints, playbooks, flows |
| Log | `State.swift` | One folder per session for replay |
| `run` loop | `AgentLoop.swift` | Drives apprentice with any model when no coding agent is involved |
| VM | `VM.swift` | Optional Linux (Debian) guest under Tart, so browser work has its own cursor and keyboard; a macOS guest is planned |

There is one executable target with no package dependencies: argument and TOML parsing are hand-written. Why Swift: it calls the accessibility, CGEvent and ScreenCaptureKit APIs directly, walks large web trees quickly, and ships as one binary that macOS permissions attach to.

Sessions: each caller opens a session tied to one app and one window ID (for example a dedicated Safari window). Commands act only on that window unless the caller switches it. That keeps the agent out of the user's own tabs and windows.

State lives in files in `~/.apprentice/`, re-read on each call: `session.json`, `snap.json`, `pending.json`, `limits.json`, `events.jsonl`, `config.toml`, `routes.toml`, `budgets.json`, `replays/` and `runs/`.

## Perception

`read` returns the session window as a numbered text list. Callers never see coordinates or images unless they ask.

```
snap 7 · Safari · github.com/settings/profile · 38 of 412 shown
12 link "Public profile"
14 textbox "Name" value="Sam"
15 textarea "Bio" value="Flutter dev…"
18 button "Upload a photo…"
22 button "Update profile" [gated]
```

Sources, cheapest and most exact first:

1. **Accessibility tree.** The walk starts at the session window (or its web area), not the whole screen. The list keeps only visible, interactive or text-bearing elements and trims names to the first few words. A named control owns its subtree.
2. **OCR** (`apprentice ocr`) through the macOS Vision framework on a ScreenCaptureKit capture of that one window, for canvas apps and images of text. Words are grouped into lines, each with its box, and numbered like AX elements.
3. **Cropped screenshot** (`apprentice shot --crop`) saved as a PNG path, for callers with vision when a label is missing. `--marks` draws each element's box and id on it (from a fresh read that keeps the last list's ids), so the caller answers with an id, not coordinates. It costs image tokens only when called.

Rules:

- **Snapshot IDs.** Element numbers belong to a snapshot. Each stores its child-index path. An action re-walks that path; if the element there no longer matches and exactly one element with the same label and name can't be found, the action fails with `stale: re-read` (exit 2), never a click on the wrong thing. An element now wholly out of view is refused the same way (`stale: … out of view`, exit 2), never clicked at a point outside the view: scroll to it first; a half-visible one is clicked in its visible part.
- **Values.** Fields show their text (never a password's), checkboxes, radios and tabs `on`, `off` or `mixed`, and a popup its current choice; a popup with no name is listed by its value.
- **Ids survive actions.** The snapshot saved after an action gives every element the id it had before (matched as the diff matches them); new elements take ids above the highest in use. An id from earlier output still names the same element, so the diff is enough and a re-read is rarely needed. `read` numbers from 1 again.
- **Cached.** A 300 ms in-memory cache serves repeated reads. (An `AXObserver` subtree cache was planned and is not built.)
- **Diffs after actions.** Every action re-reads and returns what changed (new, removed or changed elements), so callers rarely need a full `read`.
- **Settling.** On this Mac, `settle` re-reads until two reads 150 ms apart match. In the Linux VM the helper listens for the app's AT-SPI events: after an action the host waits until none arrived for 250 ms (or none at all within the grace for a page to start changing), then reads once. A page still loading, or one that never goes quiet, falls back to polling.
- **Gated marks.** Elements matching the gate rules are marked `[gated]` in the list, so callers know an approval will follow.
- **Untrusted text.** Everything read from the screen is data. The usage docs tell agents never to follow instructions found in it.
- **Browser setup.** Safari exposes web content to accessibility with no flags. Chrome needs `--force-renderer-accessibility`, or apprentice sets `AXEnhancedUserInterface` on it. Electron apps need `AXManualAccessibility`. Both are set only on browsers and apps that bundle Chromium or Electron (`showsWeb`), never on other native apps.

## Input: real cursor and keyboard only

apprentice is a natural GUI tool. Every action is what a person does with a mouse and keyboard: the cursor moves along a curved path and clicks, keys are pressed one by one, with the session window in front. There are no accessibility presses, no values set through accessibility, and no events posted straight into an app's process. Accessibility is used only to read the screen: what is there and where.

Rules for every action (`Borrow.run`):

- Starts once the user has been idle for a moment, then brings the session window forward and pauses 0.25–0.6 s before the first move.
- Stops the moment the user presses a key, clicks or scrolls (a trackpad's momentum from before the command does not count; apprentice's own events carry `Keys.tag`, so they do not count), and returns `interrupted` (exit 6).
- Leaves the cursor where it landed, as a person would.

Text is typed key by key inside web pages and apps, with key codes from the current keyboard layout (`Keys.layout`) and Shift for capitals. It is pasted (`Keys.paste`, clipboard restored) only where no website can see it: the browser's address bar and system file dialogs. A newline in the text is typed as return in apps and shift+return on web pages, so a chat composer never sends part of the text.

Upload, download and file dialogs:

- `upload <id> <path>` clicks the control that opens the picker, then `choose` does the rest.
- `choose <path>` clicks into the panel's file list, opens Go to Folder (cmd+shift+g, or "/"), enters the path, checks it, presses return, and clicks Open. For a new file it types the name into the name field.
- `download <id> <path>` right-clicks, picks the context-menu item named in `[agent] download_menu` (Save Image As, Download Linked File… by default), and uses the save panel the same way. The element's `AXURL` is logged so the run shows what was saved. A browser that saves straight to Downloads without a panel is followed there: the new file is moved to `<path>` once it has finished arriving.

## CLI reference

All output is compact plain text meant for an agent to read. `--json` gives the same data as JSON for scripts. `usage()` in `main.swift` is the full list; these are the core commands.

| Command | Does | Returns |
| --- | --- | --- |
| `session [--app Safari] [--new-window|--new-tab] [--allow a.com]` | Open or attach a session to one app window (a browser gets a tab, reusing a blank one, never another window); prints policy, playbooks and route hints | session id, window id |
| `open <url>` | Navigate the session window (rate-limited, policy-checked) | diff |
| `focus <app>` | Switch the session to another app or window | window id |
| `read [--max 80] [--filter text]` | Numbered element list; reports a challenge, or that one has cleared | snapshot |
| `click <id> [--double\|--right]` | Click an element with the real cursor | diff |
| `click --on "text"` / `--at x,y` | Click visible text (listed, or found by OCR) or a screen point; several matches are listed back to pick from, never guessed | diff |
| `type <id> "text" [--enter] [--pace fast]` | Type into a field, paced by default | diff |
| `key <combo>` / `menu "File > New"` | Send a shortcut or pick a menu item | diff |
| `scroll <up\|down\|left\|right> [n] [--in id \| --at x,y]` | Scroll the window, one element or a screen point (a map zooms on the point under the wheel) | diff |
| `hover <id>` / `drag <id> <id>` | Move onto an element, or drag one onto another | diff |
| `drag --by dx,dy [--in id \| --at x,y]` | Press, move by an offset and let go, to pan a map, canvas or timeline; the path stays in the window; gated like any drag | diff |
| `browse [seconds] [--in id]` | Read down a page or feed for 30 s (at most 120) at a reading pace; clicks nothing | diff |
| `upload <id> <path>` / `download <id> <path>` / `choose <path>` | File dialogs | diff or saved path |
| `wait-for "text" [--timeout 10]` | Wait for text, never by reloading | found or timeout |
| `ocr` / `shot [--crop id\|x,y,w,h] [--marks]` | OCR list or screenshot, ids drawn with `--marks` | snapshot or PNG path |
| `approve <token> [--text "…"]` / `deny <token>` / `pending` | Answer a proposal | diff |
| `ask` / `show` / `confirm <token>` | The little window for the user (exit 9 when they are away) | their reply |
| `policy [domain]` | Shell-command policy, or a site's automation policy | policy lines |
| `budget [domain]` | What is left of this hour's, day's and week's caps per site and kind | budget lines |
| `cool [--clear domain]` | Sites cooling down after a rate limit; clearing asks the user | cooldown lines |
| `activity <domain> [--days 7]` | Actions per day and kind, rate limits, challenges and flags | timeline |
| `flag <domain> "what you saw"` | Record when the user saw a warning or restriction | ok |
| `log [--tail n]` / `grow` | Recent steps; improvement digest | step lines |
| `route "task"` / `playbooks ["words"]` / `learn "task"` / `do <flow>` | Faster routes, playbooks, flows | lines |
| `run "task" --model <name>` / `replay <name>` / `mcp` | Built-in loop, replays, MCP server | summary |
| `account login [--start\|--wait\|--cancel]` / `status` / `logout` | Sign in to GitHub with a code entered at github.com/login/device | the login |
| `serve` / `stop` | Start or stop the daemon | status |

Example diff after `click 18`:

```
ok · snap 8 · +3 -0 ~1
+ 41 sheet "Open"
+ 42 textbox "Go to" value=""
+ 43 button "Open"
~ 18 button "Upload a photo…" focused
```

Exit codes (kept in sync with `usage()` and `agent/*.md`):

| Code | Meaning |
| --- | --- |
| 0 | ok |
| 2 | stale snapshot, or the page changed without apprentice (the user or another tool): re-read, then decide again. Reading commands take the new page in; actions are refused until then |
| 3 | The user denied the step in the little window (`confirm`) |
| 4 | blocked: allowlist, rate limit (`refresh limit`), budget (`budget:`), a site cooling down after it throttled the account (`soft block:`), or a check only the user may complete (`challenge:`) |
| 5 | element or text not found, or timeout |
| 6 | interrupted by the user during borrow mode, or by the kill switch (later steps are held until the user answers) |
| 7 | permission missing (Accessibility or Screen Recording) |
| 8 | approval needed: the action was proposed, nothing was done |
| 9 | ask the user in the chat: they are away (`away on`) or did not answer the little window in time. The output names a screenshot of the screen it is about, and `[agent] notify` pushes the question to the phone |
| 10 | yielded: in away mode the user is back at the Mac, so the acting command (or the flow's next step) did nothing. Do not retry; wait with `apprentice away wait` |

## Pacing

Pacing is built into the daemon. It keeps a session at the pace of the person doing the work, so the user's own account isn't restricted by mistake for input no person could produce. It is not a way around a site's limits: when a site signals one, the daemon backs off (see **Site rules**).

### Pointer

All randomness in pacing comes from `Rand` (`Rand.swift`): one xoshiro256** generator seeded from the system at start-up, a few nanoseconds a draw, behind a lock. Secrets (VM passwords, tokens) keep the system generator.

`Mouse.move` takes a Fitts' law duration, scaled by the hand and a ±12% log-normal draw, within `move_ms` (50–200 ms by default, 250–1000 ms in `careful`). Above the top of the range a move still grows, slowly (`Mouse.duration`, at most 2.5× the top), so long moves never pile up on one value.

- **Hand.** `Hand` draws a speed (0.85–1.2×), a favoured bend side, a key hold and rhythm, a click hold and a seed for each letter pair's lasting lean once, and keeps them in `~/.apprentice/hand.json`, shared by every VM's daemon, so restarts and updates do not change the person. Delete the file for a new hand.
- **Path.** Moves over 120 px run in two strokes: a reach that stops at 92–97% of the way, or (`overshoot`, a third of moves by default) passes the target by 1.5–5% of the distance, 3–40 px; then a 40–140 ms correction, which one time in four lands short first and nudges again. Each stroke draws its shape (a one-sided bow, an arc, an S-wave, a bow with a slow 1–3 cycle tremor of up to 2 px, or a nearly straight line) and its speed profile (skewed ease, minimum jerk, or a quick start), samples 100–135 times a second (drawn per stroke) with uneven timing and 0.3–0.8 px jitter, each sample carrying its movement delta as a mouse reports it, and a long stroke hesitates once on the way one time in sixteen.
- **Landing.** `Mouse.landing` draws a Gaussian point around the centre, never within 8% of an edge. No rest repeats a pixel: every landing, settle, `--at` aim and drop is checked against the last 256 rests (`Mouse.Rest`, in memory per daemon run), redrawn or nudged 1–6 px when it matches, so no two paths share both ends. An exact point (`click --at`, `scroll --at`, `drag --at`) is aimed within 1–2 px of it (`Mouse.aim`).
- **Settle.** `Mouse.settle` rests 40–120 ms over the target with small micro-moves before the press, so `mousedown` never lands on the frame of the last move.
- **Click.** The button is held log-normal around the hand's own median (70–120 ms); the double-click gap is 70–130 ms.
- **Reaction.** Before the hand moves, a log-normal 0.1–0.9 s look at the screen (median about 220 ms), except in `mode = "fast"`.
- **Drag.** The press is held 100–220 ms, then a nearly straight stroke with a drawn shape and speed profile, about 1.5× a move's time (from `move_ms` min up to 3× its max, at least 1 s). Over 120 px it reaches 95–98% of the way, or passes the drop by up to 2% (12 px at most), and corrects in 60–180 ms. It settles over the drop with micro-moves (still dragging) and rests 40–150 ms before release, so the drop pixel is never one it used before. `drag --by` lets go about 1% (1–5 px) off the planned offset (`Mouse.dropBy`).
- **Idle drift.** `Mouse.linger` drifts the pointer 5–20 px every 2–5 s during a dwell.
- **Scroll.** Up, down, left or right (the wheel's second axis). The pointer moves to the scroll point (within 1–2 px of it with `--at`) and rests 150–400 ms, then scrolls in flicks (`Wheel.scroll`): 3–9 lines per flick in notches of 1–3, quick in the middle of a flick and slower at either end, 120–450 ms between flicks.
- **Browse.** `browse` reads down a page or feed: each turn scrolls 4–15 lines, then reads for a log-normal pause around 3 s (at most 15) with the pointer drifting, and one turn in eight looks back up 2–6 lines. It clicks and types nothing. With `browse` set (a share of actions, at most 0.2), a profile also does this on its own: that share of commands on a web page ends with `browse_s` (10–40 s by default, at most 120) of reading down the feed from the middle of the window, then scrolls back up as far as it went, so the agent's screen ends about where its action left it. Off in every style but `careful`, which sets 0.08. Logged as `waits.browse`.
- **Fidget.** With `fidget` set, that share of actions is followed by a gesture that changes nothing (`Fidget.swift`): the pointer glances across the window, traces a few lines as if reading, rests with a drift, on a web page scrolls down a little and back, or on this Mac switches to the last app with cmd+tab for a few seconds and back, so the page sees a blur now and then. Never a click, and no key but that switch. It runs once per command, after every step of it and before the re-read (`finish`), inside `Borrow.run`, so the person's own input stops it, no later step aims at a point it scrolled away, and the diff shows the screen as it was left. Never after `hover`, and nothing scrolls after `type`, `key` or `drag` (suggestions would close, a map would zoom): no peek and no `browse` there. Its time is logged as `waits.fidget`.

### Keyboard

- **Gaps.** `Pace.keyGap` is log-normal with a 100 ms median (times the hand's rhythm) and sigma 0.4, 1.6× after a space or punctuation, 0.85× when the two letters fall to different hands and 1.15× on the same hand, clamped to 35–900 ms. A 0.5–1.8 s thinking pause comes every 20–40 characters at a word end.
- **Keys.** Real key codes from the current layout, each held log-normal around the hand's own hold (`Pace.keyHold`), shorter for the space bar and longer with Shift. Shift, cmd, option and ctrl are keys of their own: a `flagsChanged` press before the key and a release after it, with Shift held across a run of capitals. Each gap runs from one key going down to the next (`Typing.interval`), so when it is shorter than the last key's hold the two overlap, as fluent typing does; never on one key or one finger.
- **Typing rhythm.** Each letter pair keeps its own time. The main daemon learns it from the person's own typing on this Mac (`Typing.Sampler`): it listens 2–5 minutes at a time, every 15–35 min while it knows little, every 1–3 h after 3,000 keys and every 6–12 h after 20,000, never to apprentice's own keys, a key while it acts, a password field (secure input) or a scrubbed app; `[typing] learn = false` turns it off. `apprentice typing learn` records it now, the person copying a sample. Either way it keeps, per pair, the time from one key down to the next, per key its hold, and the pauses after words; never the text (`typing.json`, at most 40 samples a pair). A pair not recorded is interpolated from recorded pairs of its kind (same key, same finger, same hand, other hand, to or from space), weighted by how alike the keys sit (distance, fingers, rows). Without a recording the kind and the key distance set the gap around `key_ms_median` (now one key down to the next: 140 ms by default, 150 `steady`, 180 `careful`, 70 `fastest`), and each pair keeps a lasting ±14% lean from the hand's seed. Pauses after words come from the recording, else 0.4–1.4 s every 30–60 characters. `typing show` summarises it; `typing forget` removes it. The samples also give the person's slips: how often they correct, how many keys at a time (up to 4) and how long they take to notice. Where a profile allows slips (`key_error_rate` above 0), typing slips at that rate instead (at most 6%), sometimes a key or two late, and never in a password field.
- **Characters off the main layers.** Option-layer characters (ß, ©) use their option key; accents use the layout's dead key and then the letter (é is option+e, e on a US board), with the layout composing the text. A character no key on the layout types (an emoji, CJK without an input method) is pasted on its own, clipboard restored, rather than sent on a key that types something else.
- **Corrections.** At `key_error_rate` (off by default, 1.5% in the social profiles, at most 0.1), a neighbouring QWERTY key is typed, then deleted and retyped. At most 3 per field, never in password or secure fields, never with `--pace fast`.
- **Field entry.** `type` clicks the field and sends `cmd+a` only when the field already has text.
- `--pace fast` shortens the gaps between keys in native apps; on a web page it is ignored. Every key is still a real key. A 200-character post takes about 20–25 s at the normal pace.

### Cadence, bursts and dwell

- **Between actions.** `Limits.beforeAction` waits `between_actions_ms` (0 in native apps, 0.5–2.5 s on web pages, 3–12 s on the built-in social sites) and holds each host to `actions_per_min`: at the cap it waits (under a minute) until the oldest action leaves the window, rather than refuse the step.
- **Bursts.** With `burst` set, after that many quick actions the session rests `rest_s` (capped at 120 s).
- **Dwell.** With `dwell_s` set, an action that counts against a budget (like, follow, comment…) waits until the page has been open that long, drifting the pointer meanwhile. Acting on content before it could have been read is a strong tell.
- **A person's day.** With `quiet_hours` set (`careful`: 2–6 local time), no actions on the site in those hours. With `session_max_min` (`careful`: 50), a sitting on one site that runs that long starts a break of `break_min` minutes (15–40), shared by every VM's daemon; a pause as long as the shortest break starts a new sitting. With `actions_per_day` (`careful`: 400), no more actions on the site that day. Each refuses with exit 4 and logs a `pace` event; reading still works.
- **Navigation.** At least `nav_min_gap_s` (5 s) between page loads on the same domain, and at most 3 loads of the same URL in 120 s; the next fails with `refresh limit`. `wait-for` never polls by reloading.
- **Run loop.** `run` stops at 40 steps, 15 minutes (`[run] max_steps`, `max_minutes`), or 3 identical actions in a row.

### Styles

`style` sets every timing key at once, from fastest to least likely to be taken for a script. Keys listed next to it win.

- **`fastest`:** 30–90 ms moves, 45 ms key median, short key gaps, rare overshoot, no fidgets.
- **`fast`:** the built-in default for native apps: 50–200 ms moves, 100 ms key median, a third of moves overshoot.
- **`steady`:** the built-in default for web pages: 120–500 ms moves, 0.5–2.5 s between actions, 1–3 s dwell, rare corrected slips, a fidget after one action in ten, at most 15 actions a minute.
- **`careful`:** 250–1000 ms moves, 3–12 s between actions, 3–8 s dwell, a rest of 30–120 s after 3–6 quick actions, 1.5% corrected slips, a fidget after one action in four, at most 6 actions a minute, quiet from 2 to 6, a 15–40 min break after 50 min on one site, at most 400 actions a day. Built in for the social sites (`Config.socialSites`: Facebook, Instagram, Threads, TikTok, LinkedIn, X, Reddit, Pinterest, YouTube, Bluesky), and reads down the feed after one command in twelve (`browse = 0.08`).

A style never loosens the navigation gap, the reload cap or a budget. `[pace.styles]` assigns styles to sites and apps in one place and wins over the built-in ones (`fast = ["web"]` puts web pages back on `fast`); `web` and `native` are every browser and every other app.

### Config

All ranges live in `~/.apprentice/config.toml`. Each `[pace."<domain>"]` profile starts from its site's style (built in or from `[pace.styles]`), else `[pace.default]`, lists only what differs, and also covers the domain's subdomains (`www.linkedin.com` uses `linkedin.com`) and its old name (`twitter.com` uses `x.com`). `agent/config.example.toml` lists the social sites on the `careful` style and sets the newer keys (`quiet_hours`, `session_max_min`, `break_min`, `actions_per_day`). `[sites] soft_block_extra` and `challenge_extra` add phrases to the built-in lists, which cover the big sites' languages, and `[sites.kinds]` adds words per budgeted kind (`like = ["gostei"]`).

```toml
[pace.default]
move_ms = [50, 200]
key_ms_median = 140
key_ms_sigma = 0.4
between_actions_ms = [0, 0]
nav_min_gap_s = 5
reload_max = { count = 3, window_s = 120 }
actions_per_min = 30

[pace."linkedin.com"]
move_ms = [200, 900]
between_actions_ms = [3000, 12000]
dwell_s = [3, 8]          # least time on a page before a like, follow, comment…
burst = [4, 6]            # quick actions before a rest
rest_s = [20, 90]
actions_per_min = 6
key_error_rate = 0.015    # corrected slips; 0 turns them off

[pace.native]
mode = "fast"

[pace.styles]             # a style per site or app; a [pace."<site>"] section then lists what differs
careful = ["linkedin.com", "x.com"]
steady = ["reddit.com"]
fastest = ["native"]

[pace."github.com"]
style = "fast"
overshoot = 0.4           # share of long moves that pass the target first
fidget = 0.1              # share of actions followed by a fidget; at most 0.5

[pace."reddit.com"]
browse = 0.1              # one command in ten ends with a spell of reading down the feed and back
browse_s = [15, 45]
```

The default profile is fast on purpose (`78ff6d6`); the slow settings apply where a profile sets them. An existing `config.toml` needs the social profiles copied in. The click settle, path shapes, scroll flicks, browse turns, fidget kinds and thinking pauses have fixed ranges in `Input.swift` and `Fidget.swift`.

## Approval gate and safety

apprentice is driven by an LLM, and the LLM talks to the user: CLI ↔ LLM ↔ the user. Every action that can change state is proposed first, and the LLM approves it, denies it, or asks the user. The one direct channel to the user is the little window in `Ask.swift`.

Preferences are not decisions, and the user is never made to wait over them. `pref <key>` (`Voice.swift`) answers from `~/.apprentice/voice.md`: the scope's own answer (the session's site or app, or `--for`), else the user's answer everywhere, else the one most other scopes got. Without a real answer for the scope it puts an optional question (`OptionalAsk`): a small window that never takes focus, radio buttons or checkboxes, with the assumption shown. An answer that needs typing is critical by definition, so it is a real `ask --text` that waits, not an optional one; choices come first wherever they can carry the answer. It closes after `[agent] optional_wait_s` (60 s), and the command returns the answer or the assumption, exit 0 either way. Every answer is saved for its scope for future sessions; an unanswered one is saved as assumed and asked again later, at most three times and not twice in 12 hours. `ask --optional` is the same for a one-off question. When apprentice has been idle for 2 minutes and nothing waits on the user, it asks one built-in voice question (tone, length, emoji, casual style, what never to say, language) or a still-assumed site preference, at most every `optional_every_h` (4 h). None while the user is away; `[agent] optional_questions = false` turns them all off. The top of `voice.md` is the user's own words; `session` tells agents to read it before writing posts, comments, replies or messages, never for code or docs. It never goes into the repo or a playbook.

`apprentice tour [name]` sets everything up in eight steps, one window of choices each, every one skippable; the terminal asks when the window cannot show. What it sets is a named setup in `~/.apprentice/setups/` (the settings it wrote, and a copy of `voice.md`): `tour list`, `tour use <name>` puts one in place, `tour <name>` updates it starting from it, `tour show`, `tour rm`.

What needs approval: `open`, `click`, `type`, `key`, `menu`, `drag`, `upload`, `download`, `choose` and `do`. Reading (`read`, `ocr`, `shot`, `wait-for`) and moving the view (`scroll`, `browse`, `hover`) do not.

How it works:

1. The command checks the allowlist, cooldown and challenge state, resolves its element, works out the action kind and checks its budget, then saves the request to `~/.apprentice/pending.json` with a 4-character token and exits 8:
   ```
   approve? click 22 button "Update profile"
     Safari · https://github.com/settings/profile
   ⚠ settings, account or billing page
   ⚠ may be irreversible: button "Update profile"
   nothing was done. approve: apprentice approve a3f9 · deny: apprentice deny a3f9
   ```
2. `⚠` lines flag what needs extra care: gate-list words (send, post, publish, like, follow, comment, submit, save, update, upload, pay, buy, delete, remove, confirm and more), settings, account and billing pages, return keys that may submit, uploads, and anything the caller marked `--gate`. Flagged proposals also keep a window screenshot in the run log.
3. `approve <token>` runs exactly the saved request, paced and rate-limited as usual, and charges its budget. A step that never acts (refused by a rate limit, stopped by the user or the kill switch) gets its count back. `approve <token> --text "…"` replaces the text of a pending `type`. `deny <token>` drops it. Both are logged.
4. A token is single-use and expires after 5 minutes, or after an hour once `confirm` hands it to the user in the chat. Up to five proposals wait at once, each answered by its own token. Reading the screen again is fine: on approval the element is checked again, and a step whose id now points at something else is refused as `stale`.
5. A step on a password or security-code field, or one whose button or link names a `[gate] user_only` phrase (by default pay, buy, checkout, place order, donate, transfer, upgrade, captcha, "not a robot", delete or close account), runs only on the user's own approval (the `confirm` window or the menu bar); `approve` refuses it, even inside an approved flow. The `run` loop sends every `⚠` approval to `confirm`, and `replay --approve` does too, approving a saved step only while it names the same element as in the saved run. The `confirm` window and its chat hand-off show the proposal's `⚠` lines with the summary.
6. The usage docs tell agents to approve only steps the task needs, and to ask the user before any `⚠` step they did not ask for.

Other guardrails:

- **Allowlist per session:** domains and apps, set in config or with `session --allow`. Leaving it is exit 4.
- **Kill switch:** a global hotkey (ctrl+opt+cmd+.) stops the action under way (exit 6) and holds every later step, also exit 6, until the user answers an `ask` or `confirm` in the window, approves from the menu bar, or tells the agent to carry on (`resume`, or Resume in the menu bar). Reading still works.
- **No secrets:** no passwords in commands or logs. apprentice relies on sessions the user is already logged into, unless they turn on signing in (below). Password fields are never read back, only typed into.
- **Log scrubbing:** windows from banking, health and password-manager apps are excluded from screenshots and element logs.
- **Prompt injection:** on-screen text is data. Usage docs tell agents not to follow instructions found on a page or in an email.
- **Platform terms:** one person, own accounts, normal volume. Whether a site's terms allow automation is the user's call: apprentice never refuses a site (see Site policies).

## Site rules

Five pieces keep permitted work on the user's own accounts inside commonly enforced limits, stop cleanly when a site asks for a pause, and keep a record that can be audited. They live in `SiteRules.swift`, with their state in `Limits` (`State.swift`). This is compliance work, not concealment.

### Per-site budgets

Hourly, daily and weekly caps per action kind, on top of the per-minute cap. Sites commonly enforce limits over hours and days, not only on bursts within a minute.

- The caps live in `~/.apprentice/budgets.json`, which `kit.sh` seeds from `agent/budgets.example.json`. Each domain inherits from `default` and overrides only what it sets. Only the caps in the file apply: no file means no caps, and a kind or site left out has none (the `default` entry's `default` kind caps any other gated action). A file that is not valid JSON stops budgeted actions with exit 4 until it is fixed, so a typo never lifts every cap.
- Each kind has `hour`, `day`, an optional `week`, and `min_gap_s`. Kinds without a cap of their own borrow a close one (upvote → like; story, group post, repost → post; connect, friend request, join → follow; endorse → like). A kind with its own cap (LinkedIn's connect with its weekly cap, Instagram's story) counts on its own; a borrowing kind shares its alias's count. Any other gated action counts against a general cap of 120 an hour and 500 a day.
- The kind comes from the gated element's label, matched on whole words. Only a click, or a `type --enter`, has a kind. An upload is `upload`; a gated action on a settings page is `settings`.
- The budget is checked before the proposal and charged after approval. Over a cap is exit 4 `budget: 20 likes on x.com today`. A `min_gap_s` remainder of up to 30 s is waited out; a longer one is refused with the time it is allowed again. The agent stops; it does not retry.
- `apprentice budget [domain]` prints what is left, so an agent can plan before it starts.

Platform caps in the example file (per day, with the minimum gap):

| Action | Instagram | TikTok | LinkedIn | Facebook | Reddit | X |
| --- | --- | --- | --- | --- | --- | --- |
| Post | 3 · 30 min | 3 · 60 min | 2 · 60 min | 5 · 30 min | 3 · 30 min | 10 · 10 min |
| Story / group post | 10 stories · 5 min | — | — | 3 group posts · 60 min | — | — |
| Comment / reply | 20 · 2 min | 20 · 2 min | 15 · 3 min | 20 · 2 min | 20 · 2 min | 20 · 2 min |
| Like / upvote | 100 · 30 s | 100 · 20 s | 50 · 30 s | 100 · 20 s | 100 · 15 s | 100 · 15 s |
| Repost | — | — | — | — | — | 20 · 2 min |
| Follow | 20 · 3 min | 25 · 2.5 min | 20 · 3 min | 20 · 3 min | 10 · 5 min | 20 · 3 min |
| Unfollow | 20 · 3 min | 25 · 2.5 min | — | — | — | 20 · 3 min |
| Join subreddit | — | — | — | — | 10 · 5 min | — |
| Connect / friend request | — | — | 15 a day, 80 a week · 5 min | 10 · 5 min | — | — |
| Direct message | 20 · 3 min | 15 · 3 min | 20 · 3 min | 20 · 3 min | 10 · 5 min | 20 · 3 min |
| Endorse | — | — | 10 · 2 min | — | — | — |

The hourly caps come to roughly a quarter of the daily cap, so a day's budget can't go in one burst. No platform publishes exact limits; these are the project's own guesses, set well below the levels at which platforms are commonly reported to intervene. Treat them as ceilings, not targets. Reddit communities also set their own rules (account age, karma, self-promotion), which the daemon can't see, so the agent reads a subreddit's rules before posting. Reddit and X have official APIs; check `route` first.

Volume caps don't decide whether automation is allowed. Site policies do.

### Rate-limit detection and cooldown

When a site signals that it is throttling the account, work on that domain stops. Continuing past a rate limit can turn a temporary pause into a longer restriction.

- **Detect.** After each action, phrases such as "try again later", "you're doing that too much", "temporarily restricted", "temporarily limited", "over the daily limit", "unusual activity", "we limit how often" and "rate limit" are matched only in elements new since the last snapshot. Text fields, URL changes and scroll, browse, hover and open commands are skipped, so a page that merely mentions "rate limit" doesn't cool its site down. The list is `[sites] soft_block` in `config.toml`.
- **Cool down.** With `[sites] on_soft_block = "stop"` (the default) the domain is marked cooling in `limits.json` and every action on it is refused with exit 4 `soft block: x.com, cooling until 15:40`. The holds are `[sites] cooldown_hours` (1, 6, then 24 by default; the last repeats); a week with no block resets the count. `"warn"` records the cooldown but lets work go on, with a `⚠` line on the action's output and on every proposal there until it ends; `"off"` does not look.
- **Record.** The trigger phrase, the last 5 steps and a screenshot are logged to `events.jsonl`, and a macOS notification names the site.
- **Clear.** `apprentice cool --clear <domain>` asks the user in the little window. Agents cannot clear it.

### Handing challenges to the user

CAPTCHAs, 2FA prompts and identity checkpoints are out of scope. The daemon notices one rather than clicking around it.

1. **Detect.** On every read and after every action, match challenge URL paths (`/challenge`, `/checkpoint`, `/captcha` and similar), then the title and short element names against `[sites] challenge` ("captcha", "verify you are human", "confirm it's you", "enter the code", "press and hold", "your account has been locked"…).
2. **Pause.** With `[sites] on_challenge = "stop"` (the default), exit 4 with `challenge:` and the marker seen (8 already means "approval needed"). Every action on that site is refused until it clears; reading still works. `"warn"` reports it with a `⚠` line and lets other work go on; `"off"` does not look. In every mode the challenge itself is the user's: CAPTCHA controls are in `[gate] user_only`.
3. **Notify.** A macOS notification names the site, the first time.
4. **Resume.** The next `read` or action looks again; once the markers are gone, `read` says the challenge is gone. Nothing polls in the background, so a command never blocks for minutes. The user is the only one who completes the challenge.

The agent waits or ends the task; it never tries the challenge itself. `SKILL.md` and `AGENTS.md` say so.

### Signing back in

Off by default. With `[login] auto = true` (and, if it lists any, the site in `[login] sites`), a site that signed the account out is signed back into, so work keeps going (`Login.swift`):

- **Detect.** A page of such a site with a password field adds a `sign-in:` line to `read` and to every action's output, naming the field. A page asking for a texted, emailed or authenticator code (`Login.codeMarkers`) is a sign-in step there, not a challenge, even at a `/challenge` address. A CAPTCHA or identity check stays a challenge.
- **Type.** `type <id> --secret username|password` types the account or password saved for the page's site in the login Keychain, matched by server, so a look-alike domain finds nothing. A password goes only into a password field on an https page. `--secret code` asks the user for the code in the little window (Skip means they entered it on the page themselves), else hands off to the chat (exit 9) with a phone push; the agent then passes their answer as `--code`. Secrets are read only after approval and never reach the command line, the proposal or the logs. On such a site the credential step is the agent's to approve.
- **Save.** `login add <domain>` takes the account and password in the little window (a hidden field) and saves them to the login Keychain; `login remove`, `login status`.
- **Pace.** Sign-ins on one site are at least `[login] gap_min` (30) minutes apart and at most `[login] per_day` (3) a day (`logins.json`, shared by every VM). A sign-in page sooner than that means the last one failed or the site wants a person: exit 4, and the agent tells the user. Saving a new password with `login add` clears the count.

### Site policies

apprentice never refuses a site. A `[policy."<domain>"]` entry in `routes.toml` is the user's note on that site's terms, for reference only:

| Field | Values | Effect |
| --- | --- | --- |
| `terms_url` | URL | Printed by `apprentice policy <domain>` |
| `checked` | date | Warns under `session` and `open` when older than 6 months, since terms change |
| `api` | short text | The official API or export, if there is one |

There are no built-in entries, and an older `automation` field is ignored. Budgets, cooldowns and challenges follow their own settings on every site. `routes.example.toml` has commented examples.

### Reviewing a restriction

A restriction usually comes from activity across several sessions and days, often showing up weeks later.

- `~/.apprentice/events.jsonl` keeps rate limits, challenges, budget refusals and flags for 180 days, longer than the 30-day step logs.
- `apprentice activity <domain> [--days 7]` prints action counts per day and kind (from each step's `host` and `kind`), plus events, on one timeline across sessions.
- `apprentice flag <domain> "note"` records the time the user saw a warning or restriction, so the 48 hours before it can be compared with a normal week.

## What a site could notice

An audit, made on 2026-11-01 against `78ff6d6`, of what Instagram, Facebook, TikTok, LinkedIn and X could see when apprentice drives a browser. It drove the pacing and site-rule work above. The point is fewer accidental restrictions on work the account is allowed to do, not more actions in the same minute.

### What the research says sites measure

- **Mouse paths.** One trajectory is often enough. BeCAPTCHA-Mouse reports 93% accuracy against realistic synthetic trajectories ([arXiv 2005.00890](https://arxiv.org/abs/2005.00890)). Iliou et al. found that combining web logs with mouse biometrics catches bots built to evade either signal alone ([ACM DTRAP 2021](https://eprints.bournemouth.ac.uk/36055/1/3447815.pdf)).
- **Keystrokes.** Hold times and the gaps between keys, logged per key on a form ([Chu et al., Computer Networks 2013](https://www.eecis.udel.edu/~hnw/paper/comnet13.pdf); [Sharma & Chauhan](https://books.aijr.org/index.php/press/catalog/book/178/chapter/3401)).
- **Volume and velocity.** On social sites this is the main signal: actions per hour and day, follow and connect bursts, and read-before-act time.
- **Browser fingerprinting** (WebDriver flags, CDP, headless quirks) is the other big family. apprentice avoids it by design.

### Signals and their status

| # | Signal | Weight | Status |
| --- | --- | --- | --- |
| 1 | Velocity with no budget: only a per-minute cap | High | Fixed: per-kind budgets, cooldown and challenge stop |
| 2 | No gap between actions; cadence set by LLM latency | High | Fixed: `steady` on every web page and `careful` on the social sites by default; native apps stay fast |
| 3 | No time on content before acting | High | Fixed: `dwell_s` before any budgeted action |
| 4 | Fast pointer: every move 50–200 ms | High | Fixed in the social profiles (200–900 ms) |
| 5 | Same path shape: one symmetric Bézier, exact stop | Medium | Fixed: two strokes, overshoot or undershoot, five path shapes and three speed profiles drawn per stroke, a per-run hand, uneven samples |
| 6 | Click on arrival, fixed hold and double-click gap | Medium | Fixed: settle, varied hold and gap |
| 7 | Scroll as one large wheel event | Medium | Fixed: flicks of notches, quick in the middle; `browse` for reading a feed |
| 8 | Steady typing rhythm, short holds, no corrections | Medium | Fixed: thinking pauses, longer holds, optional corrections |
| 9 | `cmd+a` before every field, even empty ones | Medium | Fixed: only when the field has text |
| 10 | Pointer still between actions | Low | Fixed on the web: drift during a dwell, and `fidget` after actions in `steady` and `careful`; never while the person is using the cursor |
| 11 | Focus event immediately followed by motion | Low | Fixed: a varied pause after raising the window |
| 12 | Every page reached by typed URL | Low | Agent guidance, and `open` on the site the window is already on says to click links and go back with `key cmd+[` |
| 13 | Click points spread evenly | Low | Fixed: Gaussian landing |

### What it does not leak

- **No WebDriver or CDP.** `navigator.webdriver` is false, and the session is the user's real browser profile with its cookies, extensions and history.
- **Trusted events.** Every event goes through `cghidEventTap`, so the page sees `isTrusted = true` and the full `pointerover → pointermove → pointerdown → mousedown → pointerup → click` sequence.
- **Real keycodes.** Keys map from the current layout, with Shift and cmd pressed as keys of their own and dead keys for accents, so `code`, `key`, `shiftKey` and the modifier keydowns match a real keyboard.
- **Pasting stays out of pages.** Paste is used only in the address bar and system file dialogs, and for a character no key on the layout types.
- **Accessibility reads.** Chrome and Safari build an accessibility tree when an assistive client connects. Pages have no standard API to detect that.
- **Event tag.** `Keys.tag` stays in the OS event and isn't exposed to pages. It is drawn each time the daemon starts, so it is not one value shared by every install; a native app can still tell posted events from hardware ones (BOT_DETECTION A2).

### Per platform

| Platform | Most likely to trip | Notes |
| --- | --- | --- |
| Instagram / Facebook | Like and follow velocity, acting without dwelling, fast pointer | Terms forbid automated actions; not refused, so keep to the conservative budgets |
| TikTok | Watch time and feed scrolling, comment velocity | Not refused; keep to the conservative budgets |
| LinkedIn | Connect and profile-view velocity, time on a profile, deep links to profiles | Slowest profile; 3–8 s on a profile before any action; no policy entry yet |
| Reddit | Account age, karma, subreddit rules, upvote velocity | Read the community rules first; API first |
| X | Follow and repost velocity, posting cadence, reply typing | API first; no policy entry yet. twitter.com counts as x.com for budgets, cooldowns, pace and policy (`Site.renamed`) |

### Page and environment

- **One tab, one window,** one session per account: keep each account in one VM (or on this Mac), never two at once.
- **No fingerprint spoofing.** A real logged-in profile is the advantage. Don't inject JavaScript, touch canvas or audio, or fake WebDriver state.
- **Consistency.** Keep locale, time zone, VPN exit and device the same as the account's normal use. Switching all four for one session is a larger change than any pointer path.
- **Navigation.** Use `open` for the first entry, a bookmark or a deliberate redirect; click in-site links for the rest.

### The VM

A Debian guest (Tart on this Mac, or `[vm] host` for a server elsewhere) with its own screen, cursor and keyboard. With `vm on`, browser sessions run there; `session --app <name> --on linux` binds any Linux app; `apprentice vm shell` prints the plain ssh command for terminal work. Several VMs can run at once, one per agent session (`APPRENTICE_VM=<name>`, or `apprentice --vm <name> …` per command), each with its own daemon, session, snapshot, approval and pacing; budgets, cooldowns and challenges are per site and shared by all of them. Questions for a VM session open on the VM's screen, and the Mac shows a notification. A question whose answer is to open the VM (`show`, `vm call`) stays on this Mac, and so do the user-only approvals (`confirm`, clearing a challenge or a cooldown), which anything with ssh into the guest could otherwise click with faked input. `upload` copies the file into the guest and picks it in the app's own file dialog with real input; `download` brings the file back.

What still holds: no WebDriver, CDP or injected script; the page is read through AT-SPI, Linux's accessibility bus; input goes through XTest into the X server, so events are trusted, in the full pointer sequence, with the same pacing code; the time zone and language follow this Mac, and a local VM shares the Mac's IP. What changes: it is a second device, Linux with software WebGL and its own Chromium profile, so the first sign-in on each site looks like a new device, and a server elsewhere has an IP that is not the user's. Nothing is spoofed to hide that. Chromium there saves no passwords or payment cards (a managed policy), since the agent has a shell in the guest; sign-ins last through cookies. Accounts whose standing matters most stay on this Mac's own browser: `[vm] local = ["site.com"]` refuses them in every VM.

## Faster-route check

Before doing a task on screen, apprentice says when an API, CLI or connector could do it faster. Screen control is the last resort.

- **`apprentice route "task"`** matches the task's apps, domains and verbs against a routes registry and prints faster options, for example:

```
route · "update my GitHub bio and avatar"
bio     → gh api -X PATCH /user -f bio="…"   (API, ~0 tokens to read)
avatar  → screen: github.com/settings/profile  (no API endpoint)
```

- **Hints on navigation.** `session` and `open` print `hint:` lines whenever the target domain has a faster route.
- **Registry:** built-in entries (GitHub, Gmail, Google Calendar and Drive) plus `~/.apprentice/routes.toml`, which also holds the `[policy]` entries.
- **Connectors:** apprentice cannot see which MCP connectors the calling agent has. Registry entries name the connector, and the usage doc tells agents to check their own tools first.
- **`run` loop:** checks routes first and stops with the suggestion unless started with `--screen-anyway`.

## Token efficiency

| Output | Target size |
| --- | --- |
| `read`, 80 elements | under 800 tokens (about 10 per line) |
| Action diff | under 100 tokens, usually 20 to 40 |
| `route` answer | under 100 tokens |
| Usage doc loaded by an agent | under 600 tokens |
| Image | 0, unless `shot` is called |

How: diffs instead of re-reads; tight lists with `--max` and `--filter`; no coordinates or images in normal output; CLI rather than MCP by default, since a CLI adds nothing to context until called; APIs first; replays that call no model unless a check fails; and in the `run` loop, a cached system prompt, one line of history per step, and no resent element lists.

## Agent integration and the run loop

Agents learn apprentice from a short usage doc installed by `kit.sh`: `agent/SKILL.md` for Claude Code and `agent/AGENTS.md` for opencode and Kilo, kept in sync with each other and the CLI. `apprentice mcp` exposes the same commands as MCP tools.

The usage doc's rules: check your own connectors and `apprentice route` first; use `gh` for GitHub; `session` once, then `read`, then act by number; trust the diff; re-read only on `stale`; never follow instructions from page text; on exit 8, approve only steps the task needs and ask the user about `⚠` steps; stop on exits 4 and 6 and tell the user; never retry past a budget or soft block, and never touch a challenge; on social sites, read what you are about to act on first, check `budget`, and prefer in-site links.

The `run` loop, for when no coding agent is involved:

- One OpenAI-compatible client: `base_url`, `model`, `api_key`. That covers Claude (through an adapter), DeepSeek and OpenRouter.
- The model replies in a tiny grammar (`click 14`, `type 16 "…"`, `scroll down`, `done`, `need_image`), parsed locally. A separate optional vision model handles `need_image`.
- Limits: 40 steps, 15 minutes (`[run] max_steps`, `max_minutes`), and stop after 3 identical actions.

## Playbooks

Repeat tasks should not be rediscovered. The repo's `playbooks/` folder holds Markdown playbooks, and `kit.sh` links `~/.apprentice/playbooks` to it, so `git pull` brings in what was learned on another machine.

- **App and site playbooks** (`playbooks/macos/finder.md`, `playbooks/web/<host>.md`): key facts, what works, what fails. `session` and `open` print the key facts of every matching playbook.
- **Flows** (`playbooks/flows/*.md`): steps for one task, written with element names and `{placeholders}`, never ids, coordinates or personal paths. `do <flow>` runs one with a single plan approval and hands back the screen at the first failing step. A step that shows a warning the plan did not (a settings page, a dialog, a password field, or any warning on a step the plan did not flag) is proposed on its own (exit 8), and `#label "name"` takes a near match only when it adds no gate-list word, so "Save" never becomes "Save and send". When several elements fit, the step is not run and the flow stops listing them by id (exit 5). A kill-switch press stops the flow before its next step, shell steps included (exit 6). Between steps it pauses as a person would where the agent's thinking time used to be (`Pace.lookGap`): a log-normal look around 0.9 s, about 120 ms more for each new element on screen, and one step in eight a 2–5 s hesitation; pauses of 2 s or more drift the pointer. Every step still goes through the same pacing, paths, overshoot, budgets and site rules as a single command. Profiles with `mode = "fast"` skip the pause.
- `playbooks "words"` ranks playbooks. `learn "task"` drafts a flow from the session's approved steps; the LLM then generalizes it.
- Playbooks are trusted input to the LLM, so nothing read from a screen is written into them.
- Playbooks are shared with everyone through `pr` and updates, so they never hold personal information (real names, handles, emails, phone, account or order numbers, ids from URLs, profile URLs, personal file names or home paths, tokens); `{placeholders}` stand in, `commit` and `learn` refuse to commit a playbook that looks like it holds any, and `pr` refuses to offer commits that added one.

## Logging, permissions and platform notes

Logging: each session writes `~/.apprentice/runs/<date>-<session>/` with `steps.jsonl` (command, element label and name, flags, host, kind, diff, timing and waits, gate result, errors, questions asked; never typed text) and a PNG only for gated steps, `shot` calls and errors. `apprentice log` prints the tail. Step logs are pruned after 30 days; `events.jsonl` after 180.

Permissions:

- Accessibility and Screen Recording are granted to the signed `apprentice` binary once. Every agent and terminal that calls it inherits that, because the daemon does the work.
- Missing permission returns exit 7 with the settings pane to open.
- The binary is signed with a stable local identity, so rebuilds keep their permissions. An ad-hoc signed debug build loses them.

Platform notes:

- macOS 14 or later.
- AX frames are in points, the same as CGEvent coordinates. Only OCR and screenshot crops convert from pixels.
- 16 GB RAM: the daemon targets under 100 MB. Each VM takes 2 GB of memory and about 2 GB of disk, so a 16 GB Mac runs two or three beside the user's own work.

## GitHub account

`account login` signs the user in to GitHub through a GitHub App's device flow (`Account.swift`): apprentice asks GitHub for a short code, the user enters it at github.com/login/device, and apprentice polls until GitHub hands over a user token. There is no redirect server and no client secret, and the app's own permissions bound what the token can do, whatever the account could. `[account] client_id` (or `APPRENTICE_GITHUB_CLIENT_ID`) names the app; until one is registered, sign-in says so and does nothing.

- **Where it is kept.** The access and refresh tokens are generic passwords in the login Keychain, this device only. `account.json` keeps the login, the user id and the two expiry times, never a token. No command prints a token, so an agent never sees one.
- **Refresh.** A user token lasts 8 hours and its refresh token 6 months. `Account.token()` refreshes the token when it has less than 5 minutes left, and saves the new refresh token at once, since GitHub retires the old one. When the refresh token runs out, the user signs in again.
- **In two steps.** `login --start` prints the code and URL and saves the waiting sign-in (`account-pending.json`, 0600); `login --wait` polls it; `login --cancel` removes it, which ends the poll. Plain `login` does all three in the terminal, opening the browser and copying the code. The window's Settings ▸ GitHub account card runs the same commands, and the sidebar shows the login.
- **Checking.** `account status` asks GitHub whether the token still works (`--offline` does not); `doctor` prints the offline line. `logout` deletes the tokens and the profile; revoking the app on GitHub ends it everywhere.

What the account is for comes next: error reports sent to the project's issues, and the user's settings kept in a private repository of their own (`TODO.md`).

## Open work

Pacing:

- [ ] Re-pick the landing point when the last click was within 6 px (no rest repeats a pixel already); an occasional 1–3 px miss and retry on low-risk controls (never on a gated control).
- [ ] Median drift over a long field; word-boundary gaps of 80–400 ms and post-punctuation gaps of 200–600 ms.
- [ ] Modifier lead and overlap: press the modifier 20–60 ms before the key, hold 90–160 ms.
- [ ] A 1–3 s read before the next action after a scroll.
- [ ] Dwell by what changed: 0.3–0.8 s for a small diff, 0.8–2.5 s for a new page, also applied to `wait-for`.
- [ ] Gap distributions per action kind on top of `min_gap_s`: read 1–4 s, like 8–25 s, comment 30–120 s, follow or connect 45–180 s.
- [ ] Session shape: 20–45 minutes active, 10–30 away, no fixed start minute, quiet hours.
- [ ] Add dwell and burst pauses to `AgentLoop`, and stop when the same action keeps succeeding with no change on screen.
- [ ] Idle drift between commands, if it can be done without moving the user's cursor while they work.

Telemetry:

- [ ] `apprentice pace`: the active profile and a timing summary of the last 20 steps.
- [ ] Per-action fields in `steps.jsonl`: path length, peak speed, landing offset, hold and gap, correction count. Never content.
- [ ] `activity <domain> --pace`: gap histogram and click-offset spread, lined up with `flag` timestamps.
- [ ] Fixtures: 1,000 generated paths show a spread of curvature and overshoot; 500 typed characters land at 35–65 WPM with a gap CV near 0.5–0.9.

Site rules:

- [ ] "The same action failing twice with no change" as a soft-block trigger. Too many ordinary clicks change nothing in the list, so it needs a better signal first.
- [ ] Policy entries for LinkedIn and X, once the user has read their terms.

Ideas (from `features.md`):

- [ ] "should save loca…" (the note was cut off).

Other:

- [ ] `AXObserver` subtree cache in place of the 300 ms cache.
- [ ] Trim `agent/SKILL.md` and `agent/AGENTS.md` back toward 600 tokens.
- [ ] Approve from the push itself (an action button), as a second approval route. Today the push only says a question is waiting; the answer still goes through the chat.

## Build plan (historical)

The original plan was nine phases over 20–25 working days, with separate Swift modules, Swift ArgumentParser, accessibility presses as "tier 1", events posted to background apps as "tier 2", and a Python `run/` loop. The code took a different path: one target with hand-written parsing, real input only, and a Swift `run` loop. The phases, in order, were a spike on what works where; the daemon and CLI skeleton; the Reader; the Actor and pacer; macros and borrow mode; the gate, safety and logging; routes and agent integration; vision fallbacks; and the run loop, replays and MCP. All of them have landed in some form. Measure before tuning, and don't raise a cap to make up for slower pacing.
