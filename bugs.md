# apprentice — bug audit

59 findings from the 2026-11-01 audit of `apprentice` (CLI + daemon), all fixed on
2026-11-01, plus section 13 (the self-update and settings code added later that day, also
fixed) and the field reports at the end. The audit came after 13 earlier fixes: allowlist
enforcement on every action, per-URL reload cap, `beforeAction` timestamp recording, live
frames in `resolve`, `--tier 1` click, `--enter` with fast typing, stuck detector, log
timestamp, socket path length, `routes.toml` comments and `pickWindow` nil window id.

**Severity.** 9 **high** (wrong or lost work, or the daemon dies),
19 **medium** (wrong result or blocked workflow), 25 **low**
(edge case or polish).

**Evidence.** Every entry carries a tag, and section 12 repeats the verdict with the probe
behind it:

- **[verified]** — reproduced on 2026-11-01 by running the built binary, or by compiling and
  running the exact expression. 14 entries.
- **[by inspection]** — the claim follows from the cited code, re-read at its call site in
  the same pass. Every Accessibility-dependent finding is in this group: clicks, typing,
  dialogs, downloads and approval round-trips need a live session and a live AX tree.

Citations name `File.swift` → function and quote the code instead of giving line numbers,
because the tree changes underneath this audit.

**Layout.** Sections 1–5 are the first pass — crash paths, lifecycle, wrong results,
robustness, contract drift. Sections 6–11 add flows and config, the CLI and socket, the model
loop, ask/grow, approvals, and capture. Section 12 is the verification matrix, and the
suggested order at the end covers all 53.


## Status, 2026-11-01

Every entry below is fixed in the tree (commit after `522654c`). Most fixes carry their ID in a code comment (for example `(B7)`), so `grep -rn "(B7)" Sources` finds them. Points that changed shape on the way:

- B5: a kill-switch press stops the action under way and is then cleared; one pressed between commands stops the next command once.
- B8: `open` pastes the address (the address bar is not part of any site), then checks that the window reached the host, or fails with exit 5.
- B11: the reader waits up to 1.5 s for a browser's web area before reading the window as a plain one.
- B13: `download` fails with exit 5 when nothing new appears at the path (checked by modification time).
- B14: `replay`'s `expect` branch was removed; nothing wrote it.
- H1: `ping` and `stop` are answered on the socket thread, never behind a command; `stop` closes an open question window; clients give up after 25 minutes.
- I1: a proposal remembers its element; approving after a fresh `read` works, and only an id that now points elsewhere is stale.
- L1: field reports go to the repo's `bugs.md` only when the notes are the repo's own; otherwise beside the notes.
- F1: `click --on "text"` clicks listed text, or finds it by OCR (needs Screen Recording).
- F4: after typing, a field that reports its value and is still empty fails with "the keys did not arrive".
- F6: before clicking, the element is found again if the page replaced it, and its frame is read until it holds still.

---

## 1. Crashes that take down the daemon

All commands run inside `Daemon.queue.sync { handler(req) }`, so a Swift runtime trap
anywhere kills the whole daemon process. The caller sees `daemon closed the
connection` (exit 5), and the next command silently auto-starts a fresh daemon.

### B1 · `read --max <negative>` kills the daemon — high **[verified]** · **fixed 2026-11-01**
`Commands.render` does `lines.prefix(max)` with `max` straight from `a.int("max", 80)`.
A negative prefix is a fatal precondition: `Can't take a prefix of negative length
from a collection` (SIGTRAP).

- Repro: `apprentice read --max -1`
- Same call path: `ocr --max -1`.
- Verified with a standalone probe: `[1,2,3].prefix(-1)` → `Fatal error: Can't take a
  prefix of negative length from a collection`, SIGTRAP (exit 133).
- Fix: clamp (`max(0, ...)`) or reject in `Args`/`read` with exit 5.

### B2 · `log --tail <negative>` kills the daemon — high **[verified]** · **fixed 2026-11-01**
`Commands.log` takes `text.split(separator: "\n").suffix(tail)`. A negative suffix is
the same `Collection` precondition that B1's probe triggered for `prefix`, reached
from another command.

- Repro: `apprentice log --tail -1`
- Fix: clamp `tail` to `>= 0` (or default it).

### B3 · An inverted pacing range traps on every web action — high **[verified]** · **fixed 2026-11-01**
`Limits.beforeAction` does `Double.random(in: cfg.betweenMin...cfg.betweenMax)`.
`Double.random(in: lower...upper)` precondition-fails when `lower > upper`, and
`PaceConfig` copies config values verbatim.

- Repro: `between_actions_ms = [2000, 500]` in `~/.apprentice/config.toml`, then any
  `click`/`type`/`open` on a page → daemon dies.
- Fix: normalise in `PaceConfig` (`min`/`max` of the pair), as `Pace.keyGap` already
  does for key gaps.

### B4 · `Pace.sleep` traps on absurd config values — low **[verified]** · **fixed 2026-11-01**
`Pace.sleep` converts user-supplied seconds straight to `UInt32`:

- `Pace.sleep`: `UInt32(max(seconds, 0) * 1_000_000)` — `nav_min_gap_s = 5000` overflows
  `UInt32` → trap on the next `open`.

(The `scroll` half of this finding is fixed in the current tree: `count` is now clamped
with `min(max(n, 1), 50)` before `Int32(count * 3)`.)

- Fix: clamp before converting (`min(seconds, 4000)`), and reject out-of-range pace values
  when the config is read (see D3).
## 2. Lifecycle, arguments and sessions

### B5 · The kill switch latches until the daemon restarts — high **[by inspection]** · **fixed 2026-11-01**
`KillSwitch.tripped` is only ever assigned `true` (`Daemon.swift:11`); nothing resets
it. `Commands.run` rejects every command except `ping` once it is set:

```swift
if KillSwitch.tripped, req.cmd != "ping" { throw Fail(6, "...") }
```

So one accidental Ctrl+Opt+Cmd+P makes the tool permanently unusable (exit 6 on
`read`, `session`, everything) even though the person's intent was "stop *this*
action". `usage()` and SPEC treat exit 6 as "interrupted, retry later".

- Fix: reset at the start of each dispatched command (the press should abort the
  in-flight action only), or add `apprentice resume`. Keep the latch only while a
  command is running.

### B6 · A failed daemon start reports exit 7 = "permission missing" — medium **[by inspection]** · **fixed 2026-11-01**
`Wire.startDaemon` ends with `throw Fail(7, "daemon did not start...")`. Per SPEC and
`usage()`, 7 means Accessibility/Screen Recording is not granted. An agent that gets
7 for a crashed or slow start retries the wrong remedy (opens System Settings).

- Re-checked 2026-11-01: there are two sites, and they disagree. `startDaemon` ends with
  `throw Fail(7, "daemon did not start\(hint)")`, while an earlier guard in the same file
  throws `Fail(5, "daemon did not start: run apprentice serve …")`. The same failure
  therefore reports 5 or 7 depending on which check noticed it — worse than either code alone.
- Fix: use exit 5 (or 4) for "did not start" at both sites, and keep 7 for real permission
  failures.

### B7 · `Args.parse` lets a flag swallow the following positional — medium **[by inspection]** · **fixed 2026-11-01**
Any `--flag value` pair where the value is really a positional is mis-parsed because
the parser cannot know which flags take values:

- `click --right 5` → `flags["right"] = "5"`, no positional → `exit 5 click <id>`
- `type --enter 3 "hi"` → same.
- Fix: a set of known boolean flags (`right`, `double`, `enter`, `front`,
  `new-window`, `json`, `gate`, `background`, `approve`, `screen-anyway`, ...) that
  never consume the next token.

### B8 · `open` never verifies the page actually changed — medium **[by inspection]** · **fixed 2026-11-01**
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

### B9 · `focus` launches a non-running app, contradicting its own error — low **[by inspection]** · **fixed 2026-11-01**
`focus` calls `launch(named:)`, which runs `open -a <name>` when the app is not
running, then its own error path says *"app … is not running"* — which can only happen
if launching failed. So `focus Slack` starts Slack as a side effect.

- Fix: `focus` should use `runningApp(named:)` and never launch.

### B10 · Route keywords match as substrings, so `run` refuses unrelated tasks — medium **[verified]** · **fixed 2026-11-01**
`Routes.match` uses `text.contains(keyword)` with no word boundaries. `"pr"` (GitHub)
occurs inside *improve*, *project*, *spreadsheet*, *approach*. `"event"`, `"sheet"`,
`"mail"`, `"post"` have the same problem.

- Verified: `apprentice route "improve performance of the build"` → `github → gh api …`,
  and `apprentice route "write a project plan"` → `github …`.
- Consequence: `apprentice run "<such a task>"` prints the route and returns without
  driving the screen (needs `--screen-anyway`).
- Fix: match tokens, not substrings (`text.split(whereSeparator: !isLetter)`) or
  require word boundaries; keep `domain` matching as a substring.

### B11 · An allowlisted domain can be blocked when the page URL is unreadable — low **[by inspection]** · **fixed 2026-11-01**
`locate` returns `url: nil` when no `AXWebArea` is found (page still loading, or a
browser whose web accessibility tree is not built yet). `Session.allows(url:)` then
requires an *app-name* entry, so `--allow github.com` blocks a click on GitHub for a
moment.

- Fix: treat "browser session with unreadable URL" as allowed-by-session-app, or retry
  the web-area lookup before deciding.

### B12 · Sessions survive their app by PID only — low **[by inspection]** · **fixed 2026-11-01**
`Session.current()` checks `NSRunningApplication(processIdentifier: s.pid) != nil`.
macOS recycles PIDs, so after the attached app quits, a different app that inherited
the PID keeps the session "valid" and receives the actions.

- Fix: also compare `bundleIdentifier` (or the app name) against `session.bundle`.

---

## 3. Wrong or misleading results

### B13 · `download` reports success when the file never appeared — medium **[by inspection]** · **fixed 2026-11-01**
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

### B14 · Replay's `expect` check can never fire — low **[by inspection]** · **fixed 2026-11-01**
`AgentLoop.save` writes only `{"cmd", "args"}` per step, while `Replay.run` reads
`item["expect"]`. No code ever writes an `expect` key, so the documented assertion
path is dead.

- Fix: let `--save` record an expected marker (e.g. the diff summary), or drop the
  branch.

### B15 · `settle` considers a value-only change "settled" — low **[verified]** · **fixed 2026-11-01**
`settle` compares `elements.map(\.key)`, i.e. `label|name` sequences. A field whose
*value* is still changing (a spinner in a textbox, a counter) compares equal on the
first repeat, so the diff can be taken mid-update.

- Fix: include `value` in the compared key.

### B16 · Log timestamps are UTC while run folders are local — low **[by inspection]** · **fixed 2026-11-01**
`Store.stamp` is a default `ISO8601DateFormatter` (UTC); `Store.day()` uses
`.current`. `apprentice log` prints `suffix(9).prefix(8)` of the UTC stamp, so on a
UTC+10 machine a 14:00 action shows as `04:00`, and rows written after local midnight
can land in the previous day's folder.

- Fix: one timezone for both, and include an offset or a `Z` marker in the printed
  output.

### B17 · Captures are always 2×, regardless of the display — low **[by inspection]** · **fixed 2026-11-01**
`Capture.window` sets `config.width = Int(win.frame.width * 2)`. On a 1× external
display that upscales (blurrier OCR for no gain); nothing asks the display for its
scale factor.

- Fix: use the window's `backingScaleFactor` via `NSScreen`.

### B18 · Vision requests inline a full-resolution PNG — low **[by inspection]** · **fixed 2026-11-01**
`AgentLoop.imageContent` base64s the whole shot. A 2× window capture is routinely
2–8 MB → 3–11 MB of JSON in one request; many providers cap the body or the image
size. No downscale, no recompression.

- Fix: cap the long edge (e.g. 1568 px as most vision APIs prefer) and re-encode as
  JPEG/PNG before base64.

---

## 4. Robustness and performance

### B19 · No read/write timeout on accepted connections — medium **[by inspection]** · **fixed 2026-11-01**
`UnixServer.serve` blocks in `read` until a newline or EOF, with no `SO_RCVTIMEO`;
each accepted socket gets a thread from the global pool. A client that connects and
never sends (or dies mid-request) pins that thread indefinitely; a loop of such
connections exhausts the pool.

- Fix: set `SO_RCVTIMEO`/`SO_SNDTIMEO` (a few seconds), and close on timeout.

### B20 · A signal during the reply truncates it — low **[by inspection]** · **fixed 2026-11-01**
`Wire.readAll` breaks on `n <= 0`, which includes `EINTR`, so an interrupted read
yields a partial JSON body → `bad reply from daemon` (exit 5). `Wire.ping()` also has
no timeout, so a hung daemon hangs `startDaemon`'s caller.

- Fix: retry on `errno == EINTR`; poll with a deadline.

### B21 · `findFirst` is O(n²) and re-walks the tree on every command — medium **[by inspection]** · **fixed 2026-11-01**
`findFirst` pops with `queue.removeFirst()` (O(n) per pop) up to 4000 elements, and
`locate` calls it on *every* command to find the `AXWebArea`. On a large page that is
noticeable latency per action, with no caching between commands.

- Fix: index-based queue, and cache the web-area element per `wid`+snapshot.

### B22 · Removed lines come out in dictionary order — low **[by inspection]** · **fixed 2026-11-01**
`diff` collects leftovers with `for (_, list) in buckets`, so `- ` lines are ordered by
hash. Two identical runs can print different diff orderings, which makes the output
harder to compare and (for B15-style keys) nondeterministic.

- Fix: keep the old snapshot's element order.

### B23 · `learn` can write `flows/.md` — low **[by inspection]** · **fixed 2026-11-01**
`Notes.slugify` returns `""` for a task with no letters/digits, so the path becomes
`<notes>/flows/.md`.

- Fix: fall back to a fixed slug or fail with exit 5.

---

## 5. Contract drift

### B24 · MCP omits ten commands and every tier flag — medium **[by inspection]** · **fixed 2026-11-01**
`MCP.tools` is built from eighteen `cmd:` entries: `session`, `read`, `click`, `type`, `key`,
`menu`, `scroll`, `hover`, `open`, `wait_for`, `shot`, `ocr`, `route`, `choose` and four more.
None of `focus`, `drag`, `upload`, `download`, `log`, `pending`, `notes`, `learn`, `run` or
`replay` appears anywhere in the file, and it forwards no `--tier`, `--front` or `--gate`
(`--new-window` exists only on `session`). `usage()` and `agent/SKILL.md` describe the full
set, so an MCP-driven agent cannot reach approval bookkeeping, file transfer or the tier-3
escape hatch that the docs promise.

- Fix: add the missing tools (thin wrappers exist already via `MCP.map`).

### B25 · MCP answers `ping` with `-32601` — low **[verified]** · **fixed 2026-11-01**
`MCP.run` handles only `initialize`, `tools/list` and `tools/call`, so a client's liveness
`ping` gets `-32601 method not found` and may conclude the server is broken.

Notifications are *not* affected: `guard let id = msg["id"] else { continue }` drops
`notifications/initialized` without a reply, as the protocol requires. A scripted
handshake confirmed both halves — no output for the notification, `-32601` for `ping`.

- Fix: reply `{}` to `ping`.

---

## 6. Flows, notes and config

`Notes.swift` and `Flows.swift` are the newest code, and the paths the first pass treated
lightly. `Replay` now lives in `AgentLoop.swift` rather than beside the commands, so early
citations to it point at that home.

### D1 · `learn` writes a flow with no steps and reports success — medium **[by inspection]** · **fixed 2026-11-01**
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
  `APPRENTICE_NOTES=/tmp/… apprentice learn "renew the library book"`. It wrote
  `flows/google-chrome-renew-the-library-book.md`, printed it, and exited 0 — the file's
  only step is the session line.
- Damage: junk drafts land in the shared `notes/flows/`, and `Notes.context` later offers
  them to `run` as a matching flow.
- Fix: return `[]` when no action rows matched, or count steps before adding the header.

### D2 · A trailing `#` comment corrupts `routes.toml` values — medium **[by inspection]** · **fixed 2026-11-01**
`Routes.custom` skips whole comment lines but never strips trailing ones, unlike `Toml.load`:

```swift
if line.isEmpty || line.hasPrefix("#") { continue }
...
current[key] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
```

`Toml.unquote` then fails (the value no longer ends in `"`), so the comment stays in the value.

- Repro: wrote `label = "example"   # the trailing comment` to `~/.apprentice/routes.toml`
  and ran `apprentice route "make a widget"`:
  `"example"   # the trailing comment → curl https://example.com/api`
- Fix: reuse `Toml`'s comment stripper, which already respects quotes.

### D3 · `nan` or `inf` in config.toml kills the daemon on the next step — high **[verified]** · **fixed 2026-11-01**
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

### D4 · A variable value containing a space splits into two arguments — medium **[by inspection]** · **fixed 2026-11-01**
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

### D5 · `#label` swallows whatever token follows it — medium **[by inspection]** · **fixed 2026-11-01**
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

### D6 · `tokenize` strips backslashes inside quotes — low **[by inspection]** · **fixed 2026-11-01**
The escape branch runs before the quote check, so backslashes are consumed everywhere:

```swift
if escape { cur.append(ch); escape = false; continue }
if ch == "\\" { escape = true; continue }
```

`upload #field "C:\Users\me\report.pdf"` reaches the command as `C:Usersmereport.pdf` — a
path that looks plausible and fails late.

- Fix: only treat `\` as an escape before `"` and `\`, and leave it alone inside quotes
  otherwise (POSIX shells behave this way inside double quotes).

### D7 · `key` accepts several keys and silently presses the last — low **[by inspection]** · **fixed 2026-11-01**
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

### D8 · Interrupted typing reports success and can submit half-typed text — high **[by inspection]** · **fixed 2026-11-01**
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

### D9 · Bad numbers fall back silently instead of failing — low **[by inspection]** · **fixed 2026-11-01**
`Args.int` returns the fallback for anything `Int` cannot parse, and `scroll` does the same
inline:

```swift
func int(_ key: String, _ fallback: Int) -> Int { flags[key].flatMap(Int.init) ?? fallback }
let count = min(max(a.pos.count > 1 ? Int(a.pos[1]) ?? 3 : 3, 1), 50)
```

- `scroll down ten` scrolls 3 lines instead of erroring; a negative count silently becomes
  one line in the same direction.
- `click 5 --tier 1.5` quietly runs at the *default* tier instead of the one asked for — a
  tier the caller picked for safety, dropped without a word.

### D10 · `do` is missing from SPEC.md — low **[verified]** · **fixed 2026-11-01**
`choose` and `do` are both implemented, dispatched (`case "choose"`, `case "do"`), listed in
`usage()` and exposed as MCP tools. Both agent docs show the flow runner
(`apprentice do <flow> --key value`) and `choose` *is* in the SPEC — two hits, including the
line that explains it clicks into the panel's file list. `do` alone is missing from the file
the contract points at:

- `grep -c 'apprentice do ' SPEC.md` → `0`. The only matches for `apprentice do` in SPEC.md
  are `apprentice download`, so an agent reading SPEC.md as the contract never learns that
  one approval can run a whole flow.
- Fix: add a `do` row to the SPEC command table, next to `notes`.

---

## 7. The CLI, the socket and MCP

### E1 · `route` and `notes` fold flags into the query — medium **[verified]** · **fixed 2026-11-01**
Both take the joined remainder verbatim, so every flag becomes part of the text:

```swift
case "route":  print(Routes.answer(rest.joined(separator: " ")))
case "notes":  print(Notes.search(rest.joined(separator: " ")))
```

`--json` is advertised in `usage()` as universal ("add --json for the raw reply"), but on
these two commands it is silently folded into the task, where it can change the answer.

- Repro: `apprentice route "make a widget" --json` printed
  `route · "make a widget --json"` — the task the router scored now ends in a flag.
- `notes "flows --json"` likewise searches for the literal `--json`.
- Fix: strip parsed flags from the query, and implement `--json` for both.

### E2 · `stop` can SIGTERM a process that is not the daemon — high **[by inspection]** · **fixed 2026-11-01**
`UnixServer.stop()` does clean up (`unlink(path)`, removes `daemon.pid`, terminates), so an
orderly `stop` leaves nothing behind. The hole is the *unclean* case: after a crash, a
`SIGKILL` or a runtime trap inside a command, the pid file and socket can both survive. A
later `stop` falls through to:

```swift
if let raw = try? String(contentsOfFile: Store.pidPath, encoding: .utf8),
   let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
    kill(pid, SIGTERM)           // no check that the pid is apprentice
}
```

and signals whatever owns that number now — PID reuse is routine on macOS, so that can be
an unrelated app.

- Fix: confirm the identity (`proc_pidpath` ending in `apprentice`) before `kill`, and treat
  a stale pid file as a no-op after removing it.

Note: this entry previously claimed a *clean* stop left the pid file behind. It does not;
only the crashed-daemon path is exposed.

### E3 · `stop` reports success no matter what happened — low **[by inspection]** · **fixed 2026-11-01**
`Wire.stopDaemon()` returns `Void`; `main` prints `stopped` and exits 0 even when no daemon
was listening, the `kill` failed, or a long-running command kept the daemon alive.

- Fix: return whether the daemon actually went away, and exit 5 when it did not.

### E4 · A bare `apprentice` exits 0 — low **[verified]** · **fixed 2026-11-01**
With no arguments the CLI prints usage and exits 0:

```swift
guard let command = argv.first else {
    usage()
    exit(0)
}
```

An agent whose argv comes out empty (a failed interpolation, a dropped variable) sees exit
0 and treats "I printed help" as "the action succeeded". Reproduced:
`apprentice >/dev/null; echo $?` → `0`.

- Fix: exit 5 (usage error) when there is no command.

---

## 8. The model loop

### G1 · `max_tokens: 120` truncates every reply, including typed text — high **[by inspection]** · **fixed 2026-11-01**
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

### G2 · A model rate limit reports exit 5, and nothing retries — medium **[by inspection]** · **fixed 2026-11-01**
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

### G3 · A stalled model request is never cancelled and is reported as "no message" — low **[by inspection]** · **fixed 2026-11-01**
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

### G4 · `click 4 --double --right` silently drops the double — low **[verified]** · **fixed 2026-11-01**
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

## 9. Ask, the socket server and grow

### H1 · An `ask` or `show` window freezes every other command, including `stop` — high **[verified]** · **fixed 2026-11-01**
`UnixServer.serve` runs each request through the one serial command queue:

```swift
let result = Daemon.queue.sync { handler(req) }
```

and `Ask.run` / `Ask.pointAt` sit in that queue inside `runModal` for up to `--timeout`
(default 600 s). The `stop` branch lives inside the same handler, so while a question or a
"show me" window is open, `read`, `click`, `pending`, `stop` and a fresh `serve` all block —
and `Wire.send` has no deadline, so the client waits forever instead of failing.

- Verified live: with `apprentice show "…"` open for 4 m 36 s, `apprentice pending` hung
  past a 6 s alarm (SIGALRM, exit 142) while `version` (client-side) returned instantly. An
  `upload` probe during the same window hung for 60 s and had to be killed.
- Same shape at start-up: `session` calls `startOptions`, another `DispatchQueue.main.sync`
  modal with a 120 s timeout, so the first session after a daemon start can block the queue
  for two minutes.
- Fix: serve `stop`/`ping` before taking the queue, and give `Wire.send` a deadline so a
  blocked daemon fails instead of hanging.

### H2 · `Mouse.move` derives its step count from config with no bound — low **[by inspection]** · **fixed 2026-11-01**
```swift
let duration = min(max(0.12 + 0.11 * log2(dist / width + 1), p.moveMin), p.moveMax)
let steps = max(Int(duration * 120), 8)
```

`move_ms` passes through unchecked (`p.moveMin = a[0] / 1000`), so
`move_ms = [0.1, 1000000000]` yields a duration of 10^6 s — 1.2×10^8 mouse events for one
pointer move, which looks like a hung daemon. A `nan` in the same pair traps on `Int(nan)`
(see D3).

- Fix: clamp `moveMin`/`moveMax` when the config is read, and cap `steps`.

### H3 · `makeFrame` ignores whether the AXValue conversion succeeded — low **[by inspection]** · **fixed 2026-11-01**
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

## 10. Approvals and gating

### I1 · Reading the screen invalidates the approval the docs tell you to use — medium **[by inspection]** · **fixed 2026-11-01**
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

### I2 · The gate's word list misses most irreversible verbs — medium **[by inspection]** · **fixed 2026-11-01**
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

### I3 · Typing a password is proposed with no warning — medium **[by inspection]** · **fixed 2026-11-01**
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

## 11. Paths, environment and capture

### K1 · `upload` does not expand `~`, though `download` and `choose` do — medium **[by inspection]** · **fixed 2026-11-01**
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

### K2 · Model settings resolve differently on different launches — medium **[by inspection]** · **fixed 2026-11-01**
Two families of variables write the same fields inside one loop over an unordered dictionary:

```swift
for (k, v) in ProcessInfo.processInfo.environment {
    switch k {
    case "APPRENTICE_MODEL": c.runModel = v
    case "OPENAI_MODEL": c.runModel = v
    case "OPENAI_BASE_URL": if c.runKey.isEmpty || c.runURL.contains("openai.com") { c.runURL = v }
    ...
```

With both `APPRENTICE_MODEL` and `OPENAI_MODEL` set, the winner depends on dictionary order,
so the same environment can run a different model from one launch to the next. The
`OPENAI_BASE_URL` guard is worse: it consults `c.runKey`, which may or may not have been
assigned yet, so whether it overrides a configured base URL depends on whether an
`*_API_KEY` was seen first.

- Fix: read the variables explicitly in a documented order (`APPRENTICE_*` winning over
  `OPENAI_*`) instead of iterating the environment.

### K3 · A timed-out capture leaves two racing writes — low **[by inspection]** · **fixed 2026-11-01**
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

### L1 · `bug` writes to the repo root, not the notes tree — low **[verified]** · **fixed 2026-11-01**
`Notes.fileBug` resolves its target as `let file = repo.appendingPathComponent("bugs.md")`,
where `repo` is the project root rather than the notes directory. Probed with a redirected
tree: `APPRENTICE_NOTES=/tmp/dknotes apprentice bug "!!!"` printed `filed F1 in
/tmp/bugs.md`, and `/tmp/dknotes` stayed empty — the report escaped the directory it was
pointed at.

On this tree `repo` is the project root, so a field report filed while dogfooding appends a
`## Field reports` section to the project's own `bugs.md` — that is, to this audit document,
which it also uses as its seed text. Two ways to lose work: a `bug` run can bury the audit
under field notes, and the redirected-notes case above writes into an unrelated directory.

- Fix: file reports under `<notes>/bugs/<date>.md`, or require an explicit `--file`.

---

## 12. Verification matrix

One row per entry. **reproduced** matches the **[verified]** tag on the entry: driven through
the built binary, or the exact expression compiled and run, on 2026-11-01. **code** matches
**[by inspection]**: the claim was re-read at the cited call site in the same pass. The
Accessibility-dependent claims (clicks, typing, dialogs, downloads, approvals round-trips)
are all `code`: the daemon was wedged behind an open `show` window for the whole pass, and a
live AX tree would be needed anyway.

| # | verdict | evidence |
|---|---|---|
| B1 | reproduced | `[1,2,3].prefix(-1)` → SIGTRAP 133; `lines.prefix(max)` still at Commands.swift:921 |
| B2 | reproduced | `[1,2,3].suffix(-1)` → “Can't take a suffix of negative length”, 133; `suffix(tail)` unclamped |
| B3 | reproduced | `Double.random(in: 2000...500)` → “Range requires lowerBound <= upperBound”, 133; call site intact |
| B4 | reproduced | `UInt32(5000 * 1_000_000)` → overflow trap, 133; `Pace.sleep` unchanged |
| B5 | code | no assignment to `tripped` other than the `= false` declaration |
| B6 | code | both sites re-read: `Fail(7, …)` and `Fail(5, …)` for the same message |
| B7 | code | `Args.parse` consumes the next token for any `--flag` not followed by `--` |
| B8 | code | `windowURL` is used only in `attach`; `open` never re-reads it |
| B9 | code | `focus` calls `launch(named:)`, then reports “is not running” on failure |
| B10 | reproduced | `route "improve performance of the build"` and `route "write a project plan"` → both `github` |
| B11 | code | `allows(url:)`: nil host falls back to an app-name entry |
| B12 | code | `Session.current` checks `NSRunningApplication(processIdentifier:)` only |
| B13 | code | `saved = poll(timeout: 6) { fileExists(atPath: path) }`, then “requested” |
| B14 | code | `expect` has one reader and no writer |
| B15 | reproduced | struct probe: same keys, different values → `map(\.key)` equality true |
| B16 | code | `day()` uses `.current`; `stamp` is a default `ISO8601DateFormatter` (UTC) |
| B17 | code | `Int(win.frame.width * 2)` |
| B18 | code | no resize/downscale/JPEG path in `AgentLoop`; raw PNG base64 |
| B19 | code | `accept` loop sets only `SO_NOSIGPIPE`; no `SO_RCVTIMEO` anywhere |
| B20 | code | `readAll`: `if n <= 0 { break }`, no `EINTR` retry |
| B21 | code | `queue.removeFirst()` in `findFirst` |
| B22 | code | `buckets` is `[String: [Element]]`; leftovers iterated by hash order |
| B23 | code | `slugify` returns `parts.prefix(8).joined(...)`, which is `""` with no parts |
| B24 | code | eighteen `cmd:` entries re-read; none of the ten names present |
| B25 | reproduced | `ping` → `-32601`; `notifications/initialized` → no reply |
| D1 | code | `stepLines` seeds the header before scanning, so the caller's check is dead |
| D2 | code | `Routes.custom` skips whole comment lines only |
| D3 | reproduced | `Double("nan")` → `UInt32(nan)` trap, 133; no `isFinite` in the tree |
| D4 | code | `fill` runs before `tokenize`, so a substituted path splits |
| D5 | code | `resolveRefs`: `name = tokens[i + 1]` with no flag check |
| D6 | code | `if ch == "\\" { escape = true }` runs before any quote check |
| D7 | code | `Keys.parse` assigns `key = code` per part, last wins |
| D8 | code | `Keys.type` returns early on interrupt; no checkpoint in `Commands.type` |
| D9 | code | `flatMap(Int.init) ?? fallback`; `Int("ten")` is nil |
| D10 | reproduced | `grep -c 'apprentice do ' SPEC.md` → 0; `choose` → 2 hits |
| E1 | reproduced | `route … --json` → task ends in ` --json`; `notes "--json"` → no match |
| E2 | code | fallback `kill(pid, SIGTERM)` with no identity check |
| E3 | code | `stopDaemon()` returns `Void`; caller prints `stopped` unconditionally |
| E4 | reproduced | bare invocation → usage, exit 0 |
| G1 | code | `body["max_tokens"] = 120` |
| G2 | code | non-2xx → `Fail(5, "model HTTP …")`, no retry |
| G3 | code | `timeoutInterval = 90` vs `sem.wait(… + 95)`; task handle discarded |
| G4 | reproduced | `args = [args.first ?? ""] + ["--right"]`; probe of the same expression drops `--double` |
| H1 | reproduced | `pending` and `upload` both hung past 60 s while a `show` window was open |
| H2 | code | `max(Int(duration * 120), 8)` with `move_ms` copied unchecked |
| H3 | code | both `AXValueGetValue` results discarded |
| I1 | code | `Approvals.take` removes `pending.json` before the ttl and snapshot checks |
| I2 | code | `Gate.words` holds 20 verbs, none of the listed omissions |
| I3 | code | `warnings` consults name, label and URL only — no password check |
| K1 | code | `expandingTildeInPath` at exactly two sites (861/780), neither `upload` |
| K2 | code | one loop over `ProcessInfo.processInfo.environment`, duplicate cases |
| K3 | code | `sem.wait(timeout: .now() + 3)` returns `content` while the handler still writes |
| L1 | reproduced | `bug "!!!"` with `APPRENTICE_NOTES=/tmp/dknotes` → `filed F1 in /tmp/bugs.md` |

Totals: 14 reproduced, 39 code-confirmed, 53 entries.

---

## Suggested order

**1. Daemon-fatal traps** (a config value or a flag takes the process down): B1, B2, B3, B4,
D3, H2. Each is a clamp or an `isFinite`/range check, and each currently costs a restart and
the run's log.

**2. Wedge and unrecoverable state:** H1 (a modal blocks every command, including `stop`),
B5 (the kill switch latches until restart), E2 (`stop` can signal a stranger after a crash),
E3 (`stop` claims success regardless).

**3. Silent wrong results an agent acts on:** D8 (half-typed text can be submitted), G1
(truncated `type` text), G4 (a dropped `--double`), G2 (a 429 reported as exit 5, no retry),
B8 (`open` never checks the page changed), B13 (`download` reports success for a file that
never appeared), B10 (substring routing sends unrelated tasks to `gh`), D1 (empty flows),
D4 (a path with a space splits), D5 (`#label` eats a flag), D9 (bad numbers fall back
silently).

**4. The approval gate:** I1 (following the docs invalidates the approval), I2 (the verb list
misses install/allow/accept/order/sign), I3 (typing a password gets no warning).

**5. Contract and exit codes:** B6 (two codes for "did not start"), B7 (flags swallow
positionals), B24 (MCP omits ten commands), B25 (`ping` → `-32601`), D10 (`do` absent from
SPEC), E1 (`--json` folded into the query), E4 (bare invocation exits 0).

**6. Robustness and performance:** B19 (no socket read timeout), B20 (`EINTR` truncates a
reply), B21 (O(n²) walk per command), B22 (diff order follows a hash), G3 (a stalled model
request is never cancelled), K3 (a timed-out capture races its handler).

**7. Polish and portability:** B9, B11, B12, B14, B15, B16, B17, B18, B23, D2, D6, D7, H3,
K1, K2, L1.

## 13. Self-update and settings

Found on 2026-11-01 by reading `Repo.swift`, `Settings.swift` and `install.sh` right after
they were written, and by running them against scratch clones and bare repos standing in for
GitHub. Nothing here was run against GitHub itself: `pr`, the fork in `install.sh` and
`settings github` still need a live pass.

### M1 · `bug` and `learn` commit whatever else is staged — medium **[verified]** · **fixed 2026-11-01**
`Repo.commit(message, paths:)` staged the named file, then ran a plain `git commit`, which
takes the whole index.
- Repro: stage an edit to `Package.swift`, run `apprentice bug "probe"`: the commit
  "Field report F7: probe" held both `bugs.md` and `Package.swift`.
- Fix: with named paths, check and commit only those paths (`git commit -- <paths>`).

### M2 · A second `pr` fails instead of updating the open pull request — medium **[by inspection]** · **fixed 2026-11-01**
`pr` looked for the open pull request with `gh pr view owner:branch --repo upstream`.
`gh pr view` takes a number, URL or branch, so from a fork the lookup missed it, and
`gh pr create` then failed because a pull request for that branch already existed.
- Fix: `gh pr list --repo <upstream> --head <branch> --state open`; the owner:branch form is
  kept for `create` only.

### M3 · A conflicting re-install leaves the clone mid-rebase — low **[by inspection]** · **fixed 2026-11-01**
Re-running `install.sh` on an existing clone ran `git rebase` under `set -e`. A conflict
stopped the script with the rebase still in progress, and the next `apprentice` command found
a clone in that state.
- Fix: abort the rebase and say how to resolve it by hand.

### M4 · A half-made settings folder blocks `settings github` for good — low **[by inspection]** · **fixed 2026-11-01**
`settings github` cloned into `~/.apprentice/settings`. If an earlier clone failed and left
the folder, every later try failed with "already exists".
- Fix: remove the folder when it is empty; otherwise say what to move before trying again.

### M5 · Switching to GitHub a second time can fail on the `.local` copy — low **[by inspection]** · **fixed 2026-11-01**
When the repo already had a file, the local copy moved to `~/.apprentice/<file>.local`. The
code cleared an old `.local` from the settings repo instead of from `~/.apprentice`, so after
`settings local` and then `settings github` again, the move failed.
- Fix: clear `~/.apprentice/<file>.local` before the move.

### M6 · Background git can prompt for a login in Robert's terminal — medium **[by inspection]** · **fixed 2026-11-01**
The daily `git fetch` and the settings sync run from the daemon, which can share the terminal
that started it. With no stored login, git would ask for a username there: it would hang and
catch his keys.
- Fix: every git and gh call apprentice makes runs with `GIT_TERMINAL_PROMPT=0` and
  `GH_PROMPT_DISABLED=1` (`Repo.quiet`), so it fails instead of asking.

### M7 · `commit` in any clone reinstalls apprentice from that clone — high **[verified]** · **fixed 2026-11-01**
A source change made `commit` run that clone's `kit.sh`. With `APPRENTICE_NOTES` pointing at
a test clone, that replaced `~/.local/bin/apprentice`, relinked `~/.apprentice/notes` into
the test clone, rewrote the AI assistants' rules files and stopped the daemon.
- Repro: it happened during the M1 probe. A scratch clone with a staged `Package.swift`
  reinstalled the tool and relinked the notes. Running `./kit.sh` in the real repo put it back.
- Fix: rebuild only when the clone is the installed one (the one `~/.apprentice/notes`
  links into); otherwise commit and say it was not rebuilt.

### M8 · `bug` never adds the Field reports heading here — low **[verified]** · **fixed 2026-11-01**
`fileBug` added `## Field reports` only when the file did not contain that text anywhere.
This file quotes it in L1, so F1–F6 landed under "Suggested order" with no heading.
- Fix: look for the heading on a line of its own. This file now has the heading.

## Field reports

Filed by `apprentice bug` while working. Each has a suggested fix to review; none is applied.

### F1 · Dropdowns drawn outside the accessibility tree cannot be read or clicked by name — 2026-11-01 · **fixed 2026-11-01**
- Repro: Instagram composer: type into Add location; the place suggestions show on screen, but read lists nothing and an AX hit-test at the suggestion returns the field underneath (Add collaborators)
- Cause: Reader.swift locate/Walker: everything comes from the AX tree, so any overlay the page does not expose to accessibility is invisible to read, show and resolve
- Suggested fix: Add 'click --text "Melbourne"': when no listed element matches, OCR the session window (Capture.ocr, needs Screen Recording) and click the matching line's frame with the real cursor; let read --ocr-fill merge OCR lines that fall where no AX element is. Then flows can say click --text {place} instead of asking Robert.

### F2 · type's focus check gave up before Chrome reported the new focus — 2026-11-01 · **fixed 2026-11-01**
- Repro: click into a web field, then check AXFocusedUIElement after 0.2 s: still the previous field
- Cause: Commands.typeInto checked focus once, 0.2 s after the click
- Suggested fix: Applied: poll the focus for up to 1 s. Keep it as a regression note.

### F3 · Fields that re-render on focus failed type's focus check — 2026-11-01 · **fixed 2026-11-01**
- Repro: Instagram post page: type into Add a comment; focus moves to a fresh AXTextArea with the same name, not the element read listed
- Last error: `approve → exit 5: the click did not reach 23 textarea "Add a comment…": something may cover it, such as a suggestion list. Nothing was typed`
- Cause: Commands.typeInto compared the focused element with CFEqual and ancestry only
- Suggested fix: Applied: also accept a focused element of the same role with the same name, or one overlapping the clicked rect.

### F4 · Another tool driving the same window went unnoticed — 2026-11-01 · **fixed 2026-11-01**
- Repro: Instagram in Chrome while a Claude in Chrome session also used the tab: the page moved to /explore/ and the window lost key focus; apprentice's keys landed nowhere and type still said ok
- Last error: `approve → exit 5: the click did not reach 23 textarea "Add a comment…": something may cover it, such as a suggestion list. Nothing was typed`
- Cause: Nothing compared the page with the one apprentice last led to; Keys.type cannot tell whether keys arrived
- Suggested fix: Applied: prepare notes a page change apprentice did not make and adds it to the output. Next: after type, compare the field's value with the text when AX exposes it, and report 'keys did not arrive' instead of ok.

### F5 · Typed letters arrived as shortcuts after cmd+a — 2026-11-01 · **fixed 2026-11-01**
- Repro: type into a field: cmd+a, then the text; nothing appeared (Instagram search), though a lone key press worked
- Cause: Input.swift typeChar left flags unset only when shift was off, so events could pick up the cmd still reported from the cmd+a just before
- Suggested fix: Applied: typeChar always sets flags (shift or none).

### F6 · Clicking a field that slides in lands on its old position — 2026-11-01 · **fixed 2026-11-01**
- Repro: Instagram: click Search, then type into the search field at once; the panel animates and the field moves (new element), so the click hits where it was
- Cause: resolve returns the snapshot's frame when the element was replaced
- Suggested fix: In typeInto and realClick, when the element is gone or its frame changed since the snapshot, re-read and re-resolve by label and name before clicking; wait until the frame is stable for 200 ms.
