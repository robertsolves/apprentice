# deskkontrol — bug audit

New findings, separate from the 13 fixes already applied (allowlist enforcement on
every action, per-URL reload cap, `beforeAction` timestamp recording, live frames in
`resolve`, `--tier 1` click, `--enter` with fast typing, stuck detector, log
timestamp, socket path length, `routes.toml` comments, `pickWindow` nil window id).

Method: every source file read in full, plus runtime probes for the specific claims
marked **[verified]**. Items marked **[by inspection]** follow directly from the code
but were not exercised end to end, because that needs Accessibility + Screen
Recording grants and a live window.

Severity: **high** = wrong or lost work / daemon dies; **medium** = wrong result or
blocked workflow; **low** = edge case or polish.

Re-verified against the tree on 2026-11-01, after the sources changed mid-audit. Five
entries described code that had moved on and are rewritten above their old names: **B4**
(the `scroll` overflow is now clamped), **B8** (`open` types into the address bar instead of
writing `AXDocument`), **B13** (`download` uses the real cursor, so the frontmost claim was
wrong), **D1** (`stepLines` now returns `[]` only when the log is unreadable, though the dead
guard remains) and **D9** (negative counts are clamped; the silent fallback is not). The
other 38 matched the current code at their call sites.

---

## 1. Crashes that take down the daemon

All commands run inside `Daemon.queue.sync { handler(req) }`, so a Swift runtime trap
anywhere kills the whole daemon process. The caller sees `daemon closed the
connection` (exit 5), and the next command silently auto-starts a fresh daemon.

### B1 · `read --max <negative>` kills the daemon — high **[verified]**
`Commands.render` does `lines.prefix(max)` with `max` straight from `a.int("max", 80)`.
A negative prefix is a fatal precondition: `Can't take a prefix of negative length
from a collection` (SIGTRAP).

- Repro: `deskkontrol read --max -1`
- Same call path: `ocr --max -1`.
- Verified with a standalone probe: `[1,2,3].prefix(-1)` → `Fatal error: Can't take a
  prefix of negative length from a collection`, SIGTRAP (exit 133).
- Fix: clamp (`max(0, ...)`) or reject in `Args`/`read` with exit 5.

### B2 · `log --tail <negative>` kills the daemon — high **[by inspection]**
`Commands.log` takes `text.split(separator: "\n").suffix(tail)`. A negative suffix is
the same `Collection` precondition that B1's probe triggered for `prefix`, reached
from another command.

- Repro: `deskkontrol log --tail -1`
- Fix: clamp `tail` to `>= 0` (or default it).

### B3 · An inverted pacing range traps on every web action — high **[by inspection]**
`Limits.beforeAction` does `Double.random(in: cfg.betweenMin...cfg.betweenMax)`.
`Double.random(in: lower...upper)` precondition-fails when `lower > upper`, and
`PaceConfig` copies config values verbatim.

- Repro: `between_actions_ms = [2000, 500]` in `~/.deskkontrol/config.toml`, then any
  `click`/`type`/`open` on a page → daemon dies.
- Fix: normalise in `PaceConfig` (`min`/`max` of the pair), as `Pace.keyGap` already
  does for key gaps.

### B4 · `Pace.sleep` traps on absurd config values — low **[by inspection]**
`Pace.sleep` converts user-supplied seconds straight to `UInt32`:

- `Pace.sleep`: `UInt32(max(seconds, 0) * 1_000_000)` — `nav_min_gap_s = 5000` overflows
  `UInt32` → trap on the next `open`.

(The `scroll` half of this finding is fixed in the current tree: `count` is now clamped
with `min(max(n, 1), 50)` before `Int32(count * 3)`.)

- Fix: clamp before converting (`min(seconds, 4000)`), and reject out-of-range pace values
  when the config is read (see D3).
### B5 · The kill switch latches until the daemon restarts — high **[verified]**
`KillSwitch.tripped` is only ever assigned `true` (`Daemon.swift:11`); nothing resets
it. `Commands.run` rejects every command except `ping` once it is set:

```swift
if KillSwitch.tripped, req.cmd != "ping" { throw Fail(6, "...") }
```

So one accidental Ctrl+Opt+Cmd+P makes the tool permanently unusable (exit 6 on
`read`, `session`, everything) even though the person's intent was "stop *this*
action". `usage()` and SPEC treat exit 6 as "interrupted, retry later".

- Fix: reset at the start of each dispatched command (the press should abort the
  in-flight action only), or add `deskkontrol resume`. Keep the latch only while a
  command is running.

### B6 · A failed daemon start reports exit 7 = "permission missing" — medium **[by inspection]**
`Wire.startDaemon` ends with `throw Fail(7, "daemon did not start...")`. Per SPEC and
`usage()`, 7 means Accessibility/Screen Recording is not granted. An agent that gets
7 for a crashed or slow start retries the wrong remedy (opens System Settings).

- Fix: use exit 5 (or 4) for "did not start", and keep 7 for real permission failures.

### B7 · `Args.parse` lets a flag swallow the following positional — medium **[by inspection]**
Any `--flag value` pair where the value is really a positional is mis-parsed because
the parser cannot know which flags take values:

- `click --right 5` → `flags["right"] = "5"`, no positional → `exit 5 click <id>`
- `type --enter 3 "hi"` → same.
- Fix: a set of known boolean flags (`right`, `double`, `enter`, `front`,
  `new-window`, `json`, `gate`, `background`, `approve`, `screen-anyway`, ...) that
  never consume the next token.

### B8 · `open` never verifies the page actually changed — medium **[by inspection]**
`open` is browser-only now (it throws exit 5 for other apps, which removes the old silent
`AXDocument` write). It drives the address bar like a person:

```swift
try Keys.press("cmd+l")
try Keys.press("cmd+a")
Keys.type(raw)
...
try Keys.press("return")
```

then calls `finish` without reading `windowURL` again. If the address bar never took focus
(a page with a modal open, a window that is not frontmost) or the URL is refused and the
page stays put, the reply is still `ok · … → <url>` and the next command works from a stale
screen. The `notes` line even compares `hostname` against the *old* `target.url`.

- Fix: after the settle, read `windowURL` and throw exit 5 when the host did not change.
### B9 · `focus` launches a non-running app, contradicting its own error — low **[by inspection]**
`focus` calls `launch(named:)`, which runs `open -a <name>` when the app is not
running, then its own error path says *"app … is not running"* — which can only happen
if launching failed. So `focus Slack` starts Slack as a side effect.

- Fix: `focus` should use `runningApp(named:)` and never launch.

### B10 · Route keywords match as substrings, so `run` refuses unrelated tasks — medium **[verified]**
`Routes.match` uses `text.contains(keyword)` with no word boundaries. `"pr"` (GitHub)
occurs inside *improve*, *project*, *spreadsheet*, *approach*. `"event"`, `"sheet"`,
`"mail"`, `"post"` have the same problem.

- Verified: `deskkontrol route "improve performance of the build"` → `github → gh api …`,
  and `deskkontrol route "write a project plan"` → `github …`.
- Consequence: `deskkontrol run "<such a task>"` prints the route and returns without
  driving the screen (needs `--screen-anyway`).
- Fix: match tokens, not substrings (`text.split(whereSeparator: !isLetter)`) or
  require word boundaries; keep `domain` matching as a substring.

### B11 · An allowlisted domain can be blocked when the page URL is unreadable — low **[by inspection]**
`locate` returns `url: nil` when no `AXWebArea` is found (page still loading, or a
browser whose web accessibility tree is not built yet). `Session.allows(url:)` then
requires an *app-name* entry, so `--allow github.com` blocks a click on GitHub for a
moment.

- Fix: treat "browser session with unreadable URL" as allowed-by-session-app, or retry
  the web-area lookup before deciding.

### B12 · Sessions survive their app by PID only — low **[by inspection]**
`Session.current()` checks `NSRunningApplication(processIdentifier: s.pid) != nil`.
macOS recycles PIDs, so after the attached app quits, a different app that inherited
the PID keeps the session "valid" and receives the actions.

- Fix: also compare `bundleIdentifier` (or the app name) against `session.bundle`.

---

## 3. Wrong or misleading results

### B13 · `download` reports success when the file never appeared — medium **[by inspection]**
The right-click now goes through the real cursor inside `Borrow.run` and the step is gated,
so the old "needs a frontmost app" failure is gone. Two holes remain in the result:

```swift
saved = poll(timeout: 6) { FileManager.default.fileExists(atPath: path) ? true : nil } != nil
...
return finish("download", ..., extra: [(saved ? "saved " : "requested ") + path], ...)
```

`fileExists` is satisfied by an *old* file already sitting at that path, and when nothing was
saved at all the command still exits 0 with "requested <path>" — an agent cannot tell a
completed download from one that never happened.

- Fix: compare the file's mtime (or remove a pre-existing file first), and exit 5 when
  `saved` is false, or say plainly that the browser saved it somewhere else.
### B14 · Replay's `expect` check can never fire — low **[by inspection]**
`AgentLoop.save` writes only `{"cmd", "args"}` per step, while `Replay.run` reads
`item["expect"]`. No code ever writes an `expect` key, so the documented assertion
path is dead.

- Fix: let `--save` record an expected marker (e.g. the diff summary), or drop the
  branch.

### B15 · `settle` considers a value-only change "settled" — low **[by inspection]**
`settle` compares `elements.map(\.key)`, i.e. `label|name` sequences. A field whose
*value* is still changing (a spinner in a textbox, a counter) compares equal on the
first repeat, so the diff can be taken mid-update.

- Fix: include `value` in the compared key.

### B16 · Log timestamps are UTC while run folders are local — low **[verified]**
`Store.stamp` is a default `ISO8601DateFormatter` (UTC); `Store.day()` uses
`.current`. `deskkontrol log` prints `suffix(9).prefix(8)` of the UTC stamp, so on a
UTC+10 machine a 14:00 action shows as `04:00`, and rows written after local midnight
can land in the previous day's folder.

- Fix: one timezone for both, and include an offset or a `Z` marker in the printed
  output.

### B17 · Captures are always 2×, regardless of the display — low **[by inspection]**
`Capture.window` sets `config.width = Int(win.frame.width * 2)`. On a 1× external
display that upscales (blurrier OCR for no gain); nothing asks the display for its
scale factor.

- Fix: use the window's `backingScaleFactor` via `NSScreen`.

### B18 · Vision requests inline a full-resolution PNG — low **[by inspection]**
`AgentLoop.imageContent` base64s the whole shot. A 2× window capture is routinely
2–8 MB → 3–11 MB of JSON in one request; many providers cap the body or the image
size. No downscale, no recompression.

- Fix: cap the long edge (e.g. 1568 px as most vision APIs prefer) and re-encode as
  JPEG/PNG before base64.

---

## 4. Robustness and performance

### B19 · No read/write timeout on accepted connections — medium **[by inspection]**
`UnixServer.serve` blocks in `read` until a newline or EOF, with no `SO_RCVTIMEO`;
each accepted socket gets a thread from the global pool. A client that connects and
never sends (or dies mid-request) pins that thread indefinitely; a loop of such
connections exhausts the pool.

- Fix: set `SO_RCVTIMEO`/`SO_SNDTIMEO` (a few seconds), and close on timeout.

### B20 · A signal during the reply truncates it — low **[by inspection]**
`Wire.readAll` breaks on `n <= 0`, which includes `EINTR`, so an interrupted read
yields a partial JSON body → `bad reply from daemon` (exit 5). `Wire.ping()` also has
no timeout, so a hung daemon hangs `startDaemon`'s caller.

- Fix: retry on `errno == EINTR`; poll with a deadline.

### B21 · `findFirst` is O(n²) and re-walks the tree on every command — medium **[by inspection]**
`findFirst` pops with `queue.removeFirst()` (O(n) per pop) up to 4000 elements, and
`locate` calls it on *every* command to find the `AXWebArea`. On a large page that is
noticeable latency per action, with no caching between commands.

- Fix: index-based queue, and cache the web-area element per `wid`+snapshot.

### B22 · Removed lines come out in dictionary order — low **[by inspection]**
`diff` collects leftovers with `for (_, list) in buckets`, so `- ` lines are ordered by
hash. Two identical runs can print different diff orderings, which makes the output
harder to compare and (for B15-style keys) nondeterministic.

- Fix: keep the old snapshot's element order.

### B23 · `learn` can write `flows/.md` — low **[by inspection]**
`Notes.slugify` returns `""` for a task with no letters/digits, so the path becomes
`<notes>/flows/.md`.

- Fix: fall back to a fixed slug or fail with exit 5.

---

## 5. Contract drift

### B24 · MCP exposes 17 tools and none of its tiers — medium **[by inspection]**
`MCP.tools` has no `focus`, `drag`, `upload`, `download`, `log`, `pending`, `notes`,
`learn`, `run` or `replay`, and it forwards no `--tier`, `--front` or `--gate` (`--new-window`
exists only on `session`). `usage()` and `agent/SKILL.md` describe the full set, so an
MCP-driven agent cannot reach approval bookkeeping, file transfer or the tier-3 escape
hatch that the docs promise.

- Fix: add the missing tools (thin wrappers exist already via `MCP.map`).

### B25 · MCP answers `ping` with `-32601` — low **[verified]**
`MCP.run` handles only `initialize`, `tools/list` and `tools/call`, so a client's liveness
`ping` gets `-32601 method not found` and may conclude the server is broken.

Notifications are *not* affected: `guard let id = msg["id"] else { continue }` drops
`notifications/initialized` without a reply, as the protocol requires. A scripted
handshake confirmed both halves — no output for the notification, `-32601` for `ping`.

- Fix: reply `{}` to `ping`.

---

## Suggested order

1. B1, B2, B3 (daemon-fatal, trivial clamps).
2. B5 (kill switch latch) — the documented escape hatch currently bricks the tool.
3. B7, B8, B10 (agents get wrong results or wrong exit codes).
4. B6, B13, B19, B24.
5. The rest as cleanup.

---

## 6. Second pass: flows, notes and config

This pass covers `Notes.swift` and `Flows.swift` (the newest code) plus the config and
input paths the first pass treated lightly. The tree moved while I worked: `Flows.swift`
is new, `Replay` now lives in `AgentLoop.swift` rather than beside the commands, and
`Notes.swift` doubled in size. Anything in section 5 that cites `Replay` should be
re-read against its new home.

### D1 · `learn` writes a flow with no steps and reports success — medium **[verified]**
`Notes.stepLines` seeds its result with the session header:

```swift
var out = ["`session --app \"\(session.app)\"`"]
```

so it is empty only when `steps.jsonl` cannot be read at all (`guard let text = try? …
else { return [] }`) — a session with a log file but no action rows still returns one line,
and the caller's check is dead:

```swift
let steps = stepLines(session)
guard !steps.isEmpty else { throw Fail(5, "no actions in this session's log yet") }
```

- Repro: with a session whose `steps.jsonl` held only `session` and `read` rows, ran
  `DESKKONTROL_NOTES=/tmp/… deskkontrol learn "renew the library book"`. It wrote
  `flows/google-chrome-renew-the-library-book.md`, printed it, and exited 0 — the file's
  only step is the session line.
- Damage: junk drafts land in the shared `notes/flows/`, and `Notes.context` later offers
  them to `run` as a matching flow.
- Fix: return `[]` when no action rows matched, or count steps before adding the header.
### D2 · A trailing `#` comment corrupts `routes.toml` values — medium **[verified]**
`Routes.custom` skips whole comment lines but never strips trailing ones, unlike `Toml.load`:

```swift
if line.isEmpty || line.hasPrefix("#") { continue }
...
current[key] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
```

`Toml.unquote` then fails (the value no longer ends in `"`), so the comment stays in the value.

- Repro: wrote `label = "example"   # the trailing comment` to `~/.deskkontrol/routes.toml`
  and ran `deskkontrol route "make a widget"`:
  `"example"   # the trailing comment → curl https://example.com/api`
- Fix: reuse `Toml`'s comment stripper, which already respects quotes.

### D3 · `nan` or `inf` in config.toml kills the daemon on the next step — high **[verified]**
`PaceConfig` reads every number with `Double.init`, which accepts `"nan"` and `"inf"`, and
the clamps meant to make pace values safe pass NaN straight through (`max(nan, 0.04)` is
NaN). `Pace.sleep` then converts it:

```swift
static func sleep(_ seconds: Double) { usleep(UInt32(max(seconds, 0) * 1_000_000)) }
```

- Probed in isolation: `Double("nan")!` succeeds, `min(max(nan, 0.04), 0.9)` is `nan`, and
  `UInt32(nan)` dies with `Fatal error: Double value cannot be converted to UInt32 because
  it is either infinite or NaN` (SIGTRAP, exit 133) — inside `Daemon.queue.sync`, so the
  daemon goes with it.
- Triggers: `key_ms_median = nan` (every keystroke), `nav_min_gap_s = inf` (every
  navigation — that one has no upper clamp), `between_actions_ms = [nan, 2000]`.
- Fix: reject non-finite values when building `PaceConfig`, and clamp with `isFinite`
  before converting in `Pace.sleep` (same guard as B4).

### D4 · A variable value containing a space splits into two arguments — medium **[by inspection]**
`runFlow` fills placeholders first and tokenises second:

```swift
let steps = Notes.steps(note).map { fill($0, a.flags, &missing) }
...
var tokens = try tokenize(String(step.dropFirst().prefix { $0 != "`" }))
```

so a substituted value is never quoted. `do upload-file --file "/tmp/My File.pdf"` turns
`upload #button "{file}"` into the tokens `upload`, `<id>`, `/tmp/My`, `File.pdf`, and the
upload command receives a truncated path.

- Fix: quote substituted values before tokenising, or tokenise first and fill afterwards.

### D5 · `#label` swallows whatever token follows it — medium **[by inspection]**
`resolveRefs` assumes the next token is always the element name:

```swift
if t.hasPrefix("#"), t.count > 1, i + 1 < tokens.count {
    let label = String(t.dropFirst()), name = tokens[i + 1].lowercased()
```

- `click #button --double` searches for a button *named* `--double` and fails with
  `no button "--double" on screen`.
- A trailing `#button` with nothing after it falls through un-resolved and reaches the
  command as a literal id token, producing `click <id>` usage errors.
- Fix: treat a following token starting with `-` as a flag, and reject a dangling `#label`.

### D6 · `tokenize` strips backslashes inside quotes — low **[by inspection]**
The escape branch runs before the quote check, so backslashes are consumed everywhere:

```swift
if escape { cur.append(ch); escape = false; continue }
if ch == "\\" { escape = true; continue }
```

`upload #field "C:\Users\me\report.pdf"` reaches the command as `C:Usersmereport.pdf` — a
path that looks plausible and fails late.

- Fix: only treat `\` as an escape before `"` and `\`, and leave it alone inside quotes
  otherwise (POSIX shells behave this way inside double quotes).

### D7 · `key` accepts several keys and silently presses the last — low **[by inspection]**
`Keys.parse` overwrites instead of rejecting:

```swift
default:
    guard let code = codes[part] else { throw Fail(5, "unknown key \"\(part)\"") }
    key = code
```

`key "cmd+a+b"` presses ⌘B and reports success; `key "a+b"` presses an unmodified B. An
agent that concatenates two combos gets a different shortcut than it asked for, with no
error to notice.

- Fix: `throw` when a second key arrives.

### D8 · Interrupted typing reports success and can submit half-typed text — high **[by inspection]**
`Keys.type` stops silently:

```swift
for ch in text {
    if KillSwitch.tripped || Watch.stopped { return }
```

`Commands.type` then finishes normally — there is no `Borrow.checkpoint()` or length check
after `Keys.type(text, pid: …)`, so the reply is `ok` with the diff for a field that only
partly changed. `drag` throws exit 6 in the same situation, and the docs promise 6 means
"interrupted".

- Worse with `--enter`: the return key is pressed *after* the shortened text, so a
  half-typed message can be sent, in both the tier-3 and tier-2 paths.
- Fix: have `Keys.type` report whether it finished, and throw `Fail(6, …)` from
  `Commands.type` when it did not (before any `return` press).

### D9 · Bad numbers fall back silently instead of failing — low **[by inspection]**
`Args.int` returns the fallback for anything `Int` cannot parse, and `scroll` does the same
inline:

```swift
func int(_ key: String, _ fallback: Int) -> Int { flags[key].flatMap(Int.init) ?? fallback }
let count = min(max(a.pos.count > 1 ? Int(a.pos[1]) ?? 3 : 3, 1), 50)
```

- `scroll down ten` scrolls 3 lines instead of erroring; a negative count silently becomes
  one line in the same direction.
- `click 5 --tier 1.5` (or `--tier=3`, which `Args` does not read) quietly runs at the
  *default* tier instead of the one asked for — a tier the caller picked for safety is
  dropped without a word.
### D10 · `choose` and `do` are missing from SPEC.md and the agent docs — low **[verified]**
Both are implemented, dispatched (`case "choose"`, `case "do"`), listed in `usage()` and
exposed as MCP tools — but `SPEC.md` never mentions `choose` and never shows
`deskkontrol do …`. An agent that reads SPEC.md as the contract skips the file-dialog
helper and the one-approval flow runner entirely.

- Evidence: `grep -n choose SPEC.md` and `grep -n 'deskkontrol do ' SPEC.md` both return nothing.
- Fix: document both in `SPEC.md`, `agent/SKILL.md` and `agent/AGENTS.md`.

---

### Added to the order

6. D3 (config value kills the daemon), D8 (half-typed text can be submitted).
7. D4, D5, D1 (flows silently do the wrong thing).
8. D2, D6, D7, D9, D10.

---

## 7. Third pass: main, Wire and the MCP handshake

### E1 · `route` and `notes` fold flags into the query — medium **[verified]**
Both take the joined remainder verbatim, so every flag becomes part of the text:

```swift
case "route":  print(Routes.answer(rest.joined(separator: " ")))
case "notes":  print(Notes.search(rest.joined(separator: " ")))
```

`--json` is advertised in `usage()` as universal ("add --json for the raw reply"), but on
these two commands it is silently folded into the task, where it can change the answer.

- Repro: `deskkontrol route "make a widget" --json` printed
  `route · "make a widget --json"` — the task the router scored now ends in a flag.
- `notes "flows --json"` likewise searches for the literal `--json`.
- Fix: strip parsed flags from the query, and implement `--json` for both.

### E2 · `stop` can SIGTERM a process that is not the daemon — high **[by inspection]**
`UnixServer.stop()` does clean up (`unlink(path)`, removes `daemon.pid`, terminates), so an
orderly `stop` leaves nothing behind. The hole is the *unclean* case: after a crash, a
`SIGKILL` or a runtime trap inside a command, the pid file and socket can both survive. A
later `stop` falls through to:

```swift
if let raw = try? String(contentsOfFile: Store.pidPath, encoding: .utf8),
   let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
    kill(pid, SIGTERM)           // no check that the pid is deskkontrol
}
```

and signals whatever owns that number now — PID reuse is routine on macOS, so that can be
an unrelated app.

- Fix: confirm the identity (`proc_pidpath` ending in `deskkontrol`) before `kill`, and treat
  a stale pid file as a no-op after removing it.

Note: this entry previously claimed a *clean* stop left the pid file behind. It does not;
only the crashed-daemon path is exposed.
### E3 · `stop` reports success no matter what happened — low **[by inspection]**
`Wire.stopDaemon()` returns `Void`; `main` prints `stopped` and exits 0 even when no daemon
was listening, the `kill` failed, or a long-running command kept the daemon alive.

- Fix: return whether the daemon actually went away, and exit 5 when it did not.

### E4 · A bare `deskkontrol` exits 0 — low **[verified]**
With no arguments the CLI prints usage and exits 0:

```swift
guard let command = argv.first else {
    usage()
    exit(0)
}
```

An agent whose argv comes out empty (a failed interpolation, a dropped variable) sees exit
0 and treats "I printed help" as "the action succeeded". Reproduced:
`deskkontrol >/dev/null; echo $?` → `0`.

- Fix: exit 5 (usage error) when there is no command.

---

## 8. Fourth pass: the model loop

### G1 · `max_tokens: 120` truncates every reply, including typed text — high **[by inspection]**
`AgentLoop.chat` caps the completion at 120 tokens:

```swift
var body: [String: Any] = ["model": model, "messages": messages, "temperature": 0]
body["max_tokens"] = 120
```

Every action is a single short line *except* `type <id> "text"`, which carries the whole
string in the reply. Anything past roughly 90 words is cut off mid-sentence, and `parse`
takes the first line and types what arrived — so drafting an email or a paragraph, the main
reason to use `run` instead of click-by-click, produces truncated text with no error.

- Fix: raise the cap (or set it only for non-`type` turns), and reject a `type` action whose
  reply hit the ceiling rather than typing half of it.

### G2 · A model rate limit reports exit 5, and nothing retries — medium **[by inspection]**
Every non-2xx from the model becomes the same failure:

```swift
if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
    let text = data.map { String(data: $0, encoding: .utf8) ?? "" } ?? ""
    failure = Fail(5, "model HTTP \(http.statusCode): \(text.prefix(300))")
}
```

The documented contract reserves 4 for "blocked or rate limited", so a 429 arrives as
"not found or timeout" and an agent cannot tell it to back off. There is no retry and no
backoff, so one transient 429 or 503 ends a 40-step run and discards `used`.

- Fix: map 429/503 to exit 4, retry a bounded number of times with backoff, and keep the
  steps already completed.

### G3 · A stalled model request is never cancelled and is reported as "no message" — low **[by inspection]**
The request times out at 90 s but the caller waits 95 s, then falls through to the generic
guard:

```swift
req.timeoutInterval = 90
...
_ = sem.wait(timeout: .now() + 95)
if let failure { throw failure }
guard let data = output, ... else { throw Fail(5, "model returned no message") }
```

On a stall the agent is told the model "returned no message" rather than that it timed out,
and the `URLSession` task is still running: its completion later writes `output` and
`failure` after the caller has stopped reading them, which is a data race on two captured
vars, not merely a leak.

- Fix: keep a handle on the task, cancel it on timeout, and throw a distinct 5 with
  "model timed out" (or 4 if the rest of the contract treats timeouts as blocked).

### G4 · `click 4 --double --right` silently drops the double — low **[by inspection]**
`parse` rewrites the argument list when `--right` is present:

```swift
if args.contains("--right") { args = [args.first ?? ""] + ["--right"] }
```

so a model that asks for a double right-click (a common pattern for "open in new tab" on
some apps) gets a single right-click, with a success reply. `usage()` advertises
`[--double|--right]`, so nothing tells the model the combination is unsupported.

- Fix: keep both flags (`Commands.click` already accepts `right` and `double` together and
  passes both to `mouseClick`), or reject the combination explicitly.

---

## 9. Fifth pass: ask, the socket server and grow

### H1 · An `ask` or `show` window freezes every other command, including `stop` — high **[verified]**
`UnixServer.serve` runs each request through the one serial command queue:

```swift
let result = Daemon.queue.sync { handler(req) }
```

and `Ask.run` / `Ask.pointAt` sit in that queue inside `runModal` for up to `--timeout`
(default 600 s). The `stop` branch lives inside the same handler, so while a question or a
"show me" window is open, `read`, `click`, `pending`, `stop` and a fresh `serve` all block —
and `Wire.send` has no deadline, so the client waits forever instead of failing.

- Verified live: with `deskkontrol show "…"` open for 4 m 36 s, `deskkontrol pending` hung
  past a 6 s alarm (SIGALRM, exit 142) while `version` (client-side) returned instantly. An
  `upload` probe during the same window hung for 60 s and had to be killed.
- Same shape at start-up: `session` calls `startOptions`, another `DispatchQueue.main.sync`
  modal with a 120 s timeout, so the first session after a daemon start can block the queue
  for two minutes.
- Fix: serve `stop`/`ping` before taking the queue, and give `Wire.send` a deadline so a
  blocked daemon fails instead of hanging.
### H2 · `Mouse.move` derives its step count from config with no bound — low **[by inspection]**
```swift
let duration = min(max(0.12 + 0.11 * log2(dist / width + 1), p.moveMin), p.moveMax)
let steps = max(Int(duration * 120), 8)
```

`move_ms` passes through unchecked (`p.moveMin = a[0] / 1000`), so
`move_ms = [0.1, 1000000000]` yields a duration of 10^6 s — 1.2×10^8 mouse events for one
pointer move, which looks like a hung daemon. A `nan` in the same pair traps on `Int(nan)`
(see D3).

- Fix: clamp `moveMin`/`moveMax` when the config is read, and cap `steps`.

### H3 · `makeFrame` ignores whether the AXValue conversion succeeded — low **[by inspection]**
```swift
AXValueGetValue(p as! AXValue, .cgPoint, &point)
AXValueGetValue(s as! AXValue, .cgSize, &size)
```

The CFType is checked, but the *kind* inside each `AXValue` is not, and both results are
discarded. An app that stores a `.cgRect` (or hands a `.cgSize` under the position key)
returns `.zero` for both, so the element is recorded at (0,0) with a zero frame: it reads as
offscreen and a click on it lands in the top-left corner instead of on the control.

- Fix: check both return values and treat a failure as "no frame".

---

## 10. Sixth pass: approvals and gating

### I1 · Reading the screen invalidates the approval the docs tell you to use — medium **[by inspection]**
`Approvals.take` refuses a proposal whose snapshot counter moved, and it deletes the
proposal *before* deciding anything:

```swift
Store.remove("pending.json")
guard Date().timeIntervalSince1970 - p.at < ttl else { throw Fail(5, "approval ... expired") }
if p.snap != SnapStore.current?.snap {
    throw Fail(2, "stale: the screen was read again after the proposal, so its ids may differ. Run the command again")
}
```

Every `read` bumps the counter (`SnapStore.next()` → `counter + 1`), and both `usage()` and
SKILL tell an agent to `read` when unsure and to check the screen before approving. Doing
exactly that turns the proposal into exit 2 and burns the token, so the only workable
behaviour is to approve blind — the opposite of what the gate is for. `resolve` re-reads the
live frame on every action anyway, so the guard is stricter than the code needs.

- Fix: delete the pending only after the checks pass, and validate the element (as `resolve`
  does) instead of the global snapshot counter.

### I2 · The gate's word list misses most irreversible verbs — medium **[by inspection]**
`Gate.words` is a 21-word denylist and `matches` splits the label on non-letters:

```swift
static let words: Set<String> = [
    "send", "post", "publish", "like", "follow", "comment", "submit", "save", "update", "upload",
    "pay", "buy", "delete", "remove", "confirm", "create", "commit", "merge", "archive", "transfer",
]
```

Common irreversible controls are absent: `install`, `allow`, `accept`, `agree`, `enable`,
`subscribe`, `order`, `checkout`, `apply`, `invite`, `share`, `grant`, `donate`, `reset`, and
`sign` (for "Sign up"). So `click` on "Install", "Allow" (a permission prompt), "Accept all",
"Subscribe" or "Place order" is proposed without the ⚠ line that "Buy" and "Delete" get.

- Fix: add those verbs, and default to ⚠ inside dialogs (`AXDialog`) the way
  `sensitivePage` covers settings pages.

### I3 · Typing a password is proposed with no warning — medium **[by inspection]**
`classify` labels secure fields `password`, but `warnings` looks only at the name, the word
list and the page URL:

```swift
if sensitivePage(t.url) || sensitivePage(t.title) { out.append("settings, account or billing page") }
if let e = element, matches(e.name) || matches(e.label) { out.append("may be irreversible: \(e.label) \"\(e.name)\"") }
```

`"password"` is not in `Gate.words`, and `sensitivePage` inspects URLs only, so a `type` into
a login form's password field arrives as a plain proposal. The details can't compensate
either: the reader drops the value of password fields, so the approver sees
"replaces it with: …" with no indication of what kind of field it is. Credentials are the one
thing this gate should always stop on.

- Fix: warn when `e.label == "password"` or the name contains `password`, `passcode`, `2fa`
  or `one-time`, and say "a password field" in the details line.


---

## 11. Seventh pass: paths, environment and capture

### K1 · `upload` does not expand `~`, though `download` and `choose` do — medium **[by inspection]**
```swift
// upload
let path = a.pos.dropFirst().joined(separator: " ")
guard FileManager.default.fileExists(atPath: path) else { throw Fail(5, "file not found: \(path)") }
// download and choose
let path = (a.pos.dropFirst().joined(separator: " ") as NSString).expandingTildeInPath
```

`upload 3 "~/Documents/report.pdf"` fails with `file not found: ~/Documents/report.pdf` while
the file is sitting there — shells only expand `~` unquoted, and an agent quotes paths.
`expandingTildeInPath` appears at exactly two call sites, neither of them `upload`.

- Fix: expand in `upload` too, and reject a directory instead of handing it to the picker.

### K2 · Model settings resolve differently on different launches — medium **[by inspection]**
Two families of variables write the same fields inside one loop over an unordered dictionary:

```swift
for (k, v) in ProcessInfo.processInfo.environment {
    switch k {
    case "DESKKONTROL_MODEL": c.runModel = v
    case "OPENAI_MODEL": c.runModel = v
    case "OPENAI_BASE_URL": if c.runKey.isEmpty || c.runURL.contains("openai.com") { c.runURL = v }
    ...
```

With both `DESKKONTROL_MODEL` and `OPENAI_MODEL` set, the winner depends on dictionary order,
so the same environment can run a different model from one launch to the next. The
`OPENAI_BASE_URL` guard is worse: it consults `c.runKey`, which may or may not have been
assigned yet, so whether it overrides a configured base URL depends on whether an
`*_API_KEY` was seen first.

- Fix: read the variables explicitly in a documented order (`DESKKONTROL_*` winning over
  `OPENAI_*`) instead of iterating the environment.

### K3 · A timed-out capture leaves two racing writes — low **[by inspection]**
```swift
SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { c, _ in
    content = c
    sem.signal()
}
_ = sem.wait(timeout: .now() + 3)
return content
```

On timeout the function returns `nil` and falls back to the deprecated
`CGWindowListCreateImage`, while the completion handler is still writing `content` on another
thread — so callers read a variable that gets mutated after the read. `window(_:)` has the
same shape with `Task { image = … }` and a 4 s wait, except that task is never cancelled and
keeps running after the command has already fallen back.

- Fix: drop the timeout (the API is fast), or guard the shared state and cancel the task.
