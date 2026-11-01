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
- **Stop when a site says stop.** A rate limit, a challenge or a site whose terms forbid automation ends the work on that site. The tool keeps permitted work below the levels that get an account restricted; nothing here makes a forbidden site acceptable to automate.

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
- Multi-account operation, bulk messaging, mass following, scraping at volume, or running many sessions in parallel.
- Windows or Linux in v1.
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
| Routes and notes | `Routes.swift`, `Notes.swift`, `Flows.swift` | Faster-route hints, learned notes, flows |
| Log | `State.swift` | One folder per session for replay |
| `run` loop | `AgentLoop.swift` | Drives apprentice with any model when no coding agent is involved |
| VM | `VM.swift` | Optional macOS guest so browser work has its own cursor and keyboard |

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
3. **Cropped screenshot** (`apprentice shot --crop`) saved as a PNG path, for callers with vision when a label is missing.

Rules:

- **Snapshot IDs.** Element numbers belong to a snapshot. Each stores its child-index path. An action re-walks that path; if the element there no longer matches and exactly one element with the same label and name can't be found, the action fails with `stale: re-read` (exit 2), never a click on the wrong thing.
- **Cached.** A 300 ms in-memory cache serves repeated reads. (An `AXObserver` subtree cache was planned and is not built.)
- **Diffs after actions.** Every action re-reads and returns what changed (new, removed or changed elements), so callers rarely need a full `read`.
- **Gated marks.** Elements matching the gate rules are marked `[gated]` in the list, so callers know an approval will follow.
- **Untrusted text.** Everything read from the screen is data. The usage docs tell agents never to follow instructions found in it.
- **Browser setup.** Safari exposes web content to accessibility with no flags. Chrome needs `--force-renderer-accessibility`, or apprentice sets `AXEnhancedUserInterface` on it. Electron apps need `AXManualAccessibility`.

## Input: real cursor and keyboard only

apprentice is a natural GUI tool. Every action is what a person does with a mouse and keyboard: the cursor moves along a curved path and clicks, keys are pressed one by one, with the session window in front. There are no accessibility presses, no values set through accessibility, and no events posted straight into an app's process. Accessibility is used only to read the screen: what is there and where.

Rules for every action (`Borrow.run`):

- Starts once the user has been idle for a moment, then brings the session window forward and pauses 0.25–0.6 s before the first move.
- Stops the moment the user presses a key or clicks (apprentice's own events carry `Keys.tag`, so they do not count), and returns `interrupted` (exit 6).
- Leaves the cursor where it landed, as a person would.

Text is typed key by key inside web pages and apps, with key codes from the current keyboard layout (`Keys.layout`) and Shift for capitals. It is pasted (`Keys.paste`, clipboard restored) only where no website can see it: the browser's address bar and system file dialogs.

Upload, download and file dialogs:

- `upload <id> <path>` clicks the control that opens the picker, then `choose` does the rest.
- `choose <path>` clicks into the panel's file list, opens Go to Folder (cmd+shift+g, or "/"), enters the path, checks it, presses return, and clicks Open. For a new file it types the name into the name field.
- `download <id> <path>` right-clicks, picks the context-menu item named in `[agent] download_menu` (Save Image As, Download Linked File… by default), and uses the save panel the same way. The element's `AXURL` is logged so the run shows what was saved.

## CLI reference

All output is compact plain text meant for an agent to read. `--json` gives the same data as JSON for scripts. `usage()` in `main.swift` is the full list; these are the core commands.

| Command | Does | Returns |
| --- | --- | --- |
| `session [--app Safari] [--new-window] [--allow a.com]` | Open or attach a session to one app window; prints policy, notes and route hints | session id, window id |
| `open <url>` | Navigate the session window (rate-limited, policy-checked) | diff |
| `focus <app>` | Switch the session to another app or window | window id |
| `read [--max 80] [--filter text]` | Numbered element list; reports a challenge, or that one has cleared | snapshot |
| `click <id> [--double\|--right]` | Click an element with the real cursor | diff |
| `click --on "text"` / `--at x,y` | Click visible text (listed, or found by OCR) or a screen point | diff |
| `type <id> "text" [--enter] [--pace fast]` | Type into a field, paced by default | diff |
| `key <combo>` / `menu "File > New"` | Send a shortcut or pick a menu item | diff |
| `scroll <up\|down> [n] [--in id]` | Scroll the window or one element | diff |
| `hover <id>` / `drag <id> <id>` | Move onto an element, or drag one onto another | diff |
| `upload <id> <path>` / `download <id> <path>` / `choose <path>` | File dialogs | diff or saved path |
| `wait-for "text" [--timeout 10]` | Wait for text, never by reloading | found or timeout |
| `ocr` / `shot [--crop id\|x,y,w,h]` | OCR list or screenshot | snapshot or PNG path |
| `approve <token> [--text "…"]` / `deny <token>` / `pending` | Answer a proposal | diff |
| `ask` / `show` / `confirm <token>` | The little window for the user (exit 9 when they are away) | their reply |
| `policy [domain]` | Shell-command policy, or a site's automation policy | policy lines |
| `budget [domain]` | What is left of this hour's, day's and week's caps per site and kind | budget lines |
| `cool [--clear domain]` | Sites cooling down after a rate limit; clearing asks the user | cooldown lines |
| `activity <domain> [--days 7]` | Actions per day and kind, rate limits, challenges and flags | timeline |
| `flag <domain> "what you saw"` | Record when the user saw a warning or restriction | ok |
| `log [--tail n]` / `grow` | Recent steps; improvement digest | step lines |
| `route "task"` / `notes ["words"]` / `learn "task"` / `do <flow>` | Faster routes, notes, flows | lines |
| `run "task" --model <name>` / `replay <name>` / `mcp` | Built-in loop, replays, MCP server | summary |
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
| 2 | stale snapshot: re-read |
| 3 | The user denied the step in the little window (`confirm`) |
| 4 | blocked: allowlist, site policy (`policy:`), rate limit (`refresh limit`, `rate limit`), budget (`budget:`), a site cooling down after it throttled the account (`soft block:`), or a check only the user may complete (`challenge:`) |
| 5 | element or text not found, or timeout |
| 6 | interrupted by the user during borrow mode |
| 7 | permission missing (Accessibility or Screen Recording) |
| 8 | approval needed: the action was proposed, nothing was done |
| 9 | ask the user in the chat: they are away (`away on`) or did not answer the little window in time |

## Pacing

Pacing is built into the daemon. It keeps a session at the pace of the person doing the work, so the user's own account isn't restricted by mistake for input no person could produce. It is not a way around a site's limits: when a site signals one, the daemon backs off (see **Site rules**).

### Pointer

`Mouse.move` takes a Fitts' law duration clamped to `move_ms` (50–200 ms by default, 200–900 ms in the social profiles).

- **Path.** Moves over 120 px run in two strokes: a reach that stops at 92–97% of the way, or on one move in three overshoots by 2–8 px, then a 40–140 ms correction. Each stroke is a cubic Bézier with control points offset to one side, a speed peak before the middle, about 120 samples a second with uneven timing, and ±0.6 px jitter.
- **Landing.** `Mouse.landing` draws a Gaussian point around the centre, never within 8% of an edge.
- **Settle.** `Mouse.settle` rests 40–120 ms over the target with small micro-moves before the press, so `mousedown` never lands on the frame of the last move.
- **Click.** The button is held 60–140 ms; the double-click gap is 70–130 ms.
- **Idle drift.** `Mouse.linger` drifts the pointer 5–20 px every 2–5 s during a dwell.
- **Scroll.** The pointer moves to the scroll point and rests 150–400 ms, then scrolls one notch of 1–3 lines at a time, 30–90 ms apart with an occasional pause.

### Keyboard

- **Gaps.** `Pace.keyGap` is log-normal with a 100 ms median and sigma 0.4, 1.6× after a space or punctuation, clamped to 40–900 ms. A 0.5–1.8 s thinking pause comes every 20–40 characters at a word end.
- **Keys.** Real key codes from the current layout, Shift for capitals, each held 50–110 ms.
- **Corrections.** At `key_error_rate` (off by default, 1.5% in the social profiles, at most 0.1), a neighbouring QWERTY key is typed, then deleted and retyped. At most 3 per field, never in password or secure fields, never with `--pace fast`.
- **Field entry.** `type` clicks the field and sends `cmd+a` only when the field already has text.
- `--pace fast` shortens the gaps between keys; every key is still a real key. A 200-character post takes about 20–25 s at the normal pace.

### Cadence, bursts and dwell

- **Between actions.** `Limits.beforeAction` waits `between_actions_ms` (0 by default; a few seconds in the social profiles) and allows `actions_per_min` per host.
- **Bursts.** With `burst` set, after that many quick actions the session rests `rest_s` (capped at 120 s).
- **Dwell.** With `dwell_s` set, an action that counts against a budget (like, follow, comment…) waits until the page has been open that long, drifting the pointer meanwhile. Acting on content before it could have been read is a strong tell.
- **Navigation.** At least `nav_min_gap_s` (5 s) between page loads on the same domain, and at most 3 loads of the same URL in 120 s; the next fails with `refresh limit`. `wait-for` never polls by reloading.
- **Run loop.** `run` stops at 40 steps, 15 minutes, or 3 identical actions in a row.

### Config

All ranges live in `~/.apprentice/config.toml`. Each `[pace."<domain>"]` profile starts from `[pace.default]`, lists only what differs, and also covers the domain's subdomains (`www.linkedin.com` uses `linkedin.com`). `agent/config.example.toml` ships slow profiles for linkedin.com, x.com and reddit.com.

```toml
[pace.default]
move_ms = [50, 200]
key_ms_median = 100
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
```

The default profile is fast on purpose (`78ff6d6`); the slow settings apply where a profile sets them. An existing `config.toml` needs the social profiles copied in. The click settle, scroll notches and thinking pauses have fixed ranges in `Input.swift`.

## Approval gate and safety

apprentice is driven by an LLM, and the LLM talks to the user: CLI ↔ LLM ↔ the user. Every action that can change state is proposed first, and the LLM approves it, denies it, or asks the user. The one direct channel to the user is the little window in `Ask.swift`.

What needs approval: `open`, `click`, `type`, `key`, `menu`, `drag`, `upload`, `download`, `choose` and `do`. Reading (`read`, `ocr`, `shot`, `wait-for`) and moving the view (`scroll`, `hover`) do not.

How it works:

1. The command checks the allowlist, site policy, cooldown and challenge state, resolves its element, works out the action kind and checks its budget, then saves the request to `~/.apprentice/pending.json` with a 4-character token and exits 8:
   ```
   approve? click 22 button "Update profile"
     Safari · https://github.com/settings/profile
   ⚠ settings, account or billing page
   ⚠ may be irreversible: button "Update profile"
   nothing was done. approve: apprentice approve a3f9 · deny: apprentice deny a3f9
   ```
2. `⚠` lines flag what needs extra care: gate-list words (send, post, publish, like, follow, comment, submit, save, update, upload, pay, buy, delete, remove, confirm and more), settings, account and billing pages, return keys that may submit, uploads, and anything the caller marked `--gate`. Flagged proposals also keep a window screenshot in the run log.
3. `approve <token>` runs exactly the saved request, paced and rate-limited as usual, and charges its budget. `approve <token> --text "…"` replaces the text of a pending `type`. `deny <token>` drops it. Both are logged.
4. A token is single-use, expires after 5 minutes, and is refused if the screen was read again after the proposal, because element ids may have changed.
5. The usage docs tell agents to approve only steps the task needs, and to ask the user before any `⚠` step they did not ask for.

Other guardrails:

- **Allowlist per session:** domains and apps, set in config or with `session --allow`. Leaving it is exit 4.
- **Kill switch:** a global hotkey (ctrl+opt+cmd+.) stops all sessions immediately.
- **No secrets:** no passwords in commands or logs. apprentice relies on sessions the user is already logged into. Password fields are never read back, only typed into.
- **Log scrubbing:** windows from banking, health and password-manager apps are excluded from screenshots and element logs.
- **Prompt injection:** on-screen text is data. Usage docs tell agents not to follow instructions found on a page or in an email.
- **Platform terms:** one person, own accounts, normal volume. Sites whose terms forbid automated actions are refused by policy (see below); their APIs are used instead.

## Site rules

Five pieces keep permitted work on the user's own accounts inside commonly enforced limits, stop cleanly when a site asks for a pause, and keep a record that can be audited. They live in `SiteRules.swift`, with their state in `Limits` (`State.swift`). This is compliance work, not concealment.

### Per-site budgets

Hourly, daily and weekly caps per action kind, on top of the per-minute cap. Sites commonly enforce limits over hours and days, not only on bursts within a minute.

- The caps live in `~/.apprentice/budgets.json`, which `kit.sh` seeds from `agent/budgets.example.json`. Each domain inherits from `default` and overrides only what it sets. A missing or unreadable file falls back to built-in caps, never to no limits.
- Each kind has `hour`, `day`, an optional `week`, and `min_gap_s`. Kinds without a cap of their own borrow a close one (upvote → like; story, group post, repost → post; connect, friend request, join → follow; endorse → like). Any other gated action counts against a general cap of 120 an hour and 500 a day.
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

- **Detect.** After each action, phrases such as "try again later", "you're doing that too much", "temporarily restricted", "unusual activity", "we limit how often" and "rate limit" are matched only in elements new since the last snapshot. Text fields, URL changes and scroll, hover and open commands are skipped, so a page that merely mentions "rate limit" doesn't cool its site down. The list is `[sites] soft_block` in `config.toml`.
- **Cool down.** The domain is marked cooling in `limits.json` and every action on it is refused with exit 4 `soft block: x.com, cooling until 15:40`. The hold is 1 hour the first time, 6 hours the second, then 24 hours; a week with no block resets the count.
- **Record.** The trigger phrase, the last 5 steps and a screenshot are logged to `events.jsonl`, and a macOS notification names the site.
- **Clear.** `apprentice cool --clear <domain>` asks the user in the little window. Agents cannot clear it.

### Handing challenges to the user

CAPTCHAs, 2FA prompts and identity checkpoints are out of scope. The daemon notices one rather than clicking around it.

1. **Detect.** On every read and after every action, match challenge URL paths (`/challenge`, `/checkpoint`, `/captcha` and similar), then the title and short element names against `[sites] challenge` ("captcha", "verify you are human", "confirm it's you", "enter the code", "press and hold"…).
2. **Pause.** Exit 4 with `challenge:` and the marker seen (8 already means "approval needed"). Every action on that site is refused until it clears; reading still works.
3. **Notify.** A macOS notification names the site, the first time.
4. **Resume.** The next `read` or action looks again; once the markers are gone, `read` says the challenge is gone. Nothing polls in the background, so a command never blocks for minutes. The user is the only one who completes the challenge.

The agent waits or ends the task; it never tries the challenge itself. `SKILL.md` and `AGENTS.md` say so.

### Site policies

A `[policy."<domain>"]` entry in `routes.toml` makes "keep sites that forbid automation out" data the daemon enforces:

| Field | Values | Effect |
| --- | --- | --- |
| `automation` | `allowed`, `read-only`, `forbidden` | `forbidden` refuses everything, even if the domain is allowlisted. `read-only` allows reading plus `session`, `focus`, `open` and `scroll` |
| `terms_url` | URL | Printed in the refusal so the reason can be checked |
| `checked` | date | Warns when older than 6 months, since terms change |
| `api` | short text | Shown next to the refusal, for example the official API or export |

Instagram, Facebook, Messenger and TikTok are built in as `forbidden` (terms checked 2026-11-01); a `routes.toml` entry replaces a built-in one. `apprentice policy <domain>` prints the entry. A domain with no entry prints `no policy on file` once per daemon run, so the gap gets noticed. The user fills each entry after reading the site's terms; the tool does not guess them. LinkedIn and X restrict automation too, but have no built-in entry: `routes.example.toml` has commented ones ready to fill in.

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
| 2 | No gap between actions; cadence set by LLM latency | High | Fixed in the social profiles (`between_actions_ms`, `burst`, `rest_s`); the default stays fast |
| 3 | No time on content before acting | High | Fixed: `dwell_s` before any budgeted action |
| 4 | Fast pointer: every move 50–200 ms | High | Fixed in the social profiles (200–900 ms) |
| 5 | Same path shape: one symmetric Bézier, exact stop | Medium | Fixed: two strokes, overshoot or undershoot, skewed speed, uneven samples |
| 6 | Click on arrival, fixed hold and double-click gap | Medium | Fixed: settle, varied hold and gap |
| 7 | Scroll as one large wheel event | Medium | Fixed: one notch at a time; momentum phases open |
| 8 | Steady typing rhythm, short holds, no corrections | Medium | Fixed: thinking pauses, longer holds, optional corrections |
| 9 | `cmd+a` before every field, even empty ones | Medium | Fixed: only when the field has text |
| 10 | Pointer still between actions | Low | Partly: drift during a dwell only, so the user's own cursor isn't moved while they work |
| 11 | Focus event immediately followed by motion | Low | Fixed: a varied pause after raising the window |
| 12 | Every page reached by typed URL | Low | Agent guidance only: prefer in-site links within a site |
| 13 | Click points spread evenly | Low | Fixed: Gaussian landing |

### What it does not leak

- **No WebDriver or CDP.** `navigator.webdriver` is false, and the session is the user's real browser profile with its cookies, extensions and history.
- **Trusted events.** Every event goes through `cghidEventTap`, so the page sees `isTrusted = true` and the full `pointerover → pointermove → pointerdown → mousedown → pointerup → click` sequence.
- **Real keycodes.** Keys map from the current layout with Shift for capitals, so `code`, `key` and `shiftKey` match a real keyboard.
- **Pasting stays out of pages.** Paste is used only in the address bar and system file dialogs.
- **Accessibility reads.** Chrome and Safari build an accessibility tree when an assistive client connects. Pages have no standard API to detect that.
- **Event tag.** `Keys.tag` stays in the OS event and isn't exposed to pages.

### Per platform

| Platform | Most likely to trip | Notes |
| --- | --- | --- |
| Instagram / Facebook | Like and follow velocity, acting without dwelling, fast pointer | Terms forbid automated actions; refused by built-in policy |
| TikTok | Watch time and feed scrolling, comment velocity | Refused by built-in policy |
| LinkedIn | Connect and profile-view velocity, time on a profile, deep links to profiles | Slowest profile; 3–8 s on a profile before any action; no policy entry yet |
| Reddit | Account age, karma, subreddit rules, upvote velocity | Read the community rules first; API first |
| X | Follow and repost velocity, posting cadence, reply typing | API first; no policy entry yet |

### Page and environment

- **One tab, one window,** no parallel sessions on the same account.
- **No fingerprint spoofing.** A real logged-in profile is the advantage. Don't inject JavaScript, touch canvas or audio, or fake WebDriver state.
- **Consistency.** Keep locale, time zone, VPN exit and device the same as the account's normal use. Switching all four for one session is a larger change than any pointer path.
- **Navigation.** Use `open` for the first entry, a bookmark or a deliberate redirect; click in-site links for the rest.

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
- Limits: 40 steps, 15 minutes, and stop after 3 identical actions.

## Learned notes

Repeat tasks should not be rediscovered. The repo's `notes/` folder holds Markdown notes, and `kit.sh` links `~/.apprentice/notes` to it, so `git pull` brings in what was learned on another machine.

- **App and site notes** (`notes/macos/finder.md`, `notes/web/<host>.md`): key facts, what works, what fails. `session` and `open` print the key facts of every matching note.
- **Flows** (`notes/flows/*.md`): steps for one task, written with element names and `{placeholders}`, never ids, coordinates or personal paths. `do <flow>` runs one with a single plan approval and hands back the screen at the first failing step.
- `notes "words"` ranks notes. `learn "task"` drafts a flow from the session's approved steps; the LLM then generalizes it.
- Notes are trusted input to the LLM, so nothing read from a screen is written into them.

## Logging, permissions and platform notes

Logging: each session writes `~/.apprentice/runs/<date>-<session>/` with `steps.jsonl` (command, element label and name, flags, host, kind, diff, timing and waits, gate result, errors, questions asked; never typed text) and a PNG only for gated steps, `shot` calls and errors. `apprentice log` prints the tail. Step logs are pruned after 30 days; `events.jsonl` after 180.

Permissions:

- Accessibility and Screen Recording are granted to the signed `apprentice` binary once. Every agent and terminal that calls it inherits that, because the daemon does the work.
- Missing permission returns exit 7 with the settings pane to open.
- The binary is signed with a stable local identity, so rebuilds keep their permissions. An ad-hoc signed debug build loses them.

Platform notes:

- macOS 14 or later.
- AX frames are in points, the same as CGEvent coordinates. Only OCR and screenshot crops convert from pixels.
- 16 GB RAM: the daemon targets under 100 MB. The VM is optional because it needs 4 GB or more.

## Open work

Pacing:

- [ ] Re-pick the landing point when the last click was within 6 px; an occasional 1–3 px miss and retry on low-risk controls (never on a gated control).
- [ ] Median drift over a long field; word-boundary gaps of 80–400 ms and post-punctuation gaps of 200–600 ms.
- [ ] Modifier lead and overlap: press the modifier 20–60 ms before the key, hold 90–160 ms.
- [ ] Scroll momentum phases, and a 1–3 s read before the next action after a scroll.
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

- [ ] Ping the user remotely through Claude with a screenshot and the question, so apprentice can be steered from a phone.
- [ ] "should save loca…" (the note was cut off).

Other:

- [ ] `AXObserver` subtree cache in place of the 300 ms cache.
- [ ] Trim `agent/SKILL.md` and `agent/AGENTS.md` back toward 600 tokens.
- [ ] Phone approval (push notification) as a second approval route.

## Build plan (historical)

The original plan was nine phases over 20–25 working days, with separate Swift modules, Swift ArgumentParser, accessibility presses as "tier 1", events posted to background apps as "tier 2", and a Python `run/` loop. The code took a different path: one target with hand-written parsing, real input only, and a Swift `run` loop. The phases, in order, were a spike on what works where; the daemon and CLI skeleton; the Reader; the Actor and pacer; macros and borrow mode; the gate, safety and logging; routes and agent integration; vision fallbacks; and the run loop, replays and MCP. All of them have landed in some form. Measure before tuning, and don't raise a cap to make up for slower pacing.
