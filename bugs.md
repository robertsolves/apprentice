# apprentice — bug audit

## Field reports

Filed by `apprentice bug` while working. Each has a suggested fix to review; none is applied.

### F1 · `vm install` leaks the host's `[vm]` keys into the previous section of the guest config — 2026-11-01
- Cause: `VM.install` filters the host's config with `!$0.hasPrefix("[vm]")`, which drops the header but keeps its keys, so `name`, `home`, `image` and `password` end up under whatever section came before them.
- Suggested fix: track the current section while filtering and drop the `[vm]` section with its body, instead of only the header line.

### F2 · `VM.run` can deadlock when a caller passes a large stdin — 2026-11-01
- Cause: `VM.run` writes the whole `input` to the child's stdin before it starts reading stdout, so a child that both reads more than a pipe buffer and writes more than one to stdout blocks while the writer blocks too. Today's callers (`vm install`'s tar, `wire`'s one line) stay under the limit, so this is latent, not live.
- Suggested fix: write stdin from a background queue in the same `DispatchGroup` as the stderr drain, so stdout is read while the child is still consuming its input.

### F3 · A mixed-case pacing profile is silently ignored — 2026-11-01
- Cause: `Config.load` keys `profiles` by the section as written, while `profileKey` lowercases the host before looking it up, and `profiles[session.app]` matches only exactly. `[pace."LinkedIn.com"]` therefore does nothing, and `[pace."Safari"]` works only because the app name happens to be spelled that way.
- Suggested fix: lowercase the key in `load()` and lowercase `session.app` at the app lookup, so every spelling matches.

### F4 · MCP answers `budget`, `policy` and `activity` from the host while the browser runs in the VM — 2026-11-01
- Cause: `MCP.runLocally` and `MCP.map` call `Budgets.report` / `Policies.describe` / the daemon directly. Only the CLI forwards these to the guest (`VM.forward` in `main.swift`), so with `vm on` an MCP client sees the host's budgets, events and policies, which are for a machine taking no actions.
- Suggested fix: forward the same three commands through `VM.forward` when the VM is on, as `main.swift` does, and answer from the guest.

### F5 · `do <flow>` echoes filled step text, so a value passed as a var reaches the chat and the log — 2026-11-01
- Cause: `Commands.runFlow` prints the step after `fill`, so `type #textbox "..." "{password}" --enter` appears in its ✓ and ✗ lines with the value substituted, unlike `type`, whose log rows never carry typed text.
- Suggested fix: print the unresolved step (`{password}`) and mask values whose key contains `password`, `token` or `secret`.

## Audit · every file read on 2026-11-02

Findings from reading all of `Sources/apprentice`, `agent/`, the shell entry points, the workflows, the notes and the docs. Nothing here is applied. Severity is the order they appear in. `swift build` and `apprentice selftest` still pass, so none of these is a compile error.

### F6 · `selftest` behind `--vm` deletes the real `~/.apprentice` — 2026-11-02
- Severity: critical (data loss: settings, API key, session, logs, notes link).
- Where: `main.swift:7`, `SelfTest.swift:34`, `SelfTest.swift:219-220`, `SelfTest.swift:242-243`.
- Cause: the throwaway home is only set when `CommandLine.arguments[1] == "selftest"`. `apprentice --vm foo selftest` has `--vm` in slot 1, so `APPRENTICE_HOME` is never set: `Store.dir` stays `~/.apprentice`. `SelfTest.run()` then ends with `try? FileManager.default.removeItem(at: Store.dir)`, and two checks write over real files first and delete them on the way out: `budgets()` writes `Budgets.path` then `defer` removes it, `policies()` does the same to `Routes.customPath`. So that one command wipes `config.toml` (the API key), `routes.toml`, `budgets.json`, `session.json`, `runs/` and the notes link. `--vm` is also the documented way to reach a named VM, so this is reachable by following the usage text.
- Suggested fix: set the throwaway home from the parsed command instead of slot 1 — move the check after the `--vm` strip and test `argvRaw[1] == "selftest"` there. Better, make `SelfTest.run()` refuse to run unless `APPRENTICE_HOME` is set and outside the home folder, and point `Budgets.path`, `Routes.customPath` and `Store.dir` at a temp dir the test owns rather than borrowing the live ones. Add a check to `selftest` that its state dir is under `NSTemporaryDirectory()`.

### F7 · `do` rewrites `{…}` inside `sh:` steps, so shell commands with braces break — 2026-11-02
- Severity: high (a whole class of shell flows cannot run: `${HOME}`, `awk '{print $1}'`, brace expansion).
- Where: `Flows.swift:18` (`steps = raw.map { fill($0, a.flags, &missing) }`) versus `Flows.swift:85-88` (`shellCommand`).
- Cause: every raw step is placeholder-filled before the code asks whether it is a `sh:` step. `fill` treats any `{…}` as a variable, so `` `sh: echo ${HOME}` `` asks for `--home`, and `` `sh: echo {a,b}` `` for `--a,b`; a missing one becomes `‹home›` and the flow stops with "needs --home` before the shell ever sees it.
- Suggested fix: split `sh:` steps off before filling and fill only screen steps, or make `fill` substitute only keys the caller actually passed (`vars[key]`) and leave untouched braces alone instead of marking them missing. A `$`-prefixed brace should never be a placeholder.

### F8 · `--tier` is documented in four places and read by nothing — 2026-11-02
- Severity: high (the usage text and `agent/*.md` promise a behaviour the binary does not have; an agent passing it changes nothing and gets no warning).
- Where: `main.swift:32,33,34,39`; `Commands.swift:12-15` (`Args.switches`); no `value("tier")` or `has("tier")` anywhere in `Sources/`.
- Cause: `tier` is neither a switch nor handled as a key, so `--tier 3` is parsed into `flags["tier"]` and never read. `Store.log` only ever writes a `tier` field if one already exists (`Commands.swift:1193`), which nothing does.
- Suggested fix: either implement it (band the pacing: tier 1 fastest … tier 3 slowest) or delete it from `usage()` and from the agent docs. Leaving a documented flag that silently does nothing is worse than not having it.

### F9 · `replay <name> --from n` past the end reports success with 0 steps — 2026-11-02
- Severity: high (a caller resuming a replay is told it finished, so the work silently never happens).
- Where: `AgentLoop.swift:385-404`.
- Cause: `for item in list.dropFirst(first - 1)` yields nothing when `first > list.count`, the loop never runs and the function prints `replay · 0 steps · ok`, exit 0. The same happens for `--from 1` on a saved run that contains no `cmd` rows.
- Suggested fix: `guard first <= list.count else { throw Fail(5, "replay \"\(name)\" has \(list.count) steps; --from \(first) is past the end") }`, and fail when `used.isEmpty` in `AgentLoop.save`.

### F10 · The VM's file-dialog box has the wrong sign, so `upload`/`download` cannot find the Open/Save button — 2026-11-02
- Severity: high for anything that moves files through a GTK dialog in the VM.
- Where: `agent/vm/helper.py:537-538`.
- Cause: `w.translate_coords(root, 0, 0)` already returns the window origin **in root coordinates**, so the box is then negated into `[-at.x, -at.y, …]` — a window at (300, 200) is reported at (-300, -200). `Remote.confirmDialog` (`Remote+More.swift:74-86`) filters OCR hits with `box.contains(point)`, which can never match a negative-origin rectangle, so the button is never clicked and it falls through to `Keys.press("return")` — which `pick`'s own comment (`Remote+More.swift:70-72`) says "closes the dialog without passing the file on" in GTK. The `frame` is the only consumer, so nothing else notices.
- Suggested fix: `box = [at.x, at.y, g.width, g.height]` (or keep the negation but call `root.translate_coords(w, 0, 0)`). Worth a comment saying which direction the API goes, since this is the classic sign trap.

### F11 · `apprentice bug` writes `bugs.md` while the repo's file is `BUGS.md` — 2026-11-02
- Severity: medium (silent second file on any case-sensitive checkout — Linux CI, a case-sensitive volume, a GitHub tarball on ext4 — so reports land where `grow` and `pr` do not look).
- Where: `Notes.swift:206-209`; contrast `PR.swift:21` which lists both spellings.
- Cause: `bugFile` hardcodes `repo.appendingPathComponent("bugs.md")`. On this Mac's case-insensitive APFS it resolves to `BUGS.md`, so it works here and breaks elsewhere.
- Suggested fix: pick the existing name — return `BUGS.md` when it exists, else create it with that name — so one file holds every report. `PR.swift`'s `records` set can then drop the lower-case spelling.

### F12 · `F1` is still listed as open although the code it describes is gone — 2026-11-02
- Severity: medium (the file is the record `grow` and `pr` read; a stale entry sends the next agent to fix something that was already fixed).
- Where: `BUGS.md:7-9` versus `VM.swift:25-30`.
- Cause: F1 says `VM.install` filters the host config with `!$0.hasPrefix("[vm]")`. No such filter exists: `VM.settings` now reads `all["vm"]` and drops only `name`/`host`/`port` for a named VM, which is correct. `grep -rn 'hasPrefix("\[vm\]")' Sources/` returns nothing.
- Suggested fix: delete F1 on the next commit that touches `VM.settings`, per the rule in `AGENTS.md` ("when you fix a bug, delete its entry in the same commit").

### F13 · CI never syntax-checks the guest shell scripts or the Python that runs in the VM — 2026-11-02
- Severity: medium (the two files that boot the whole VM — `provision.sh`, `session.sh` — and the helper every VM command depends on are the only ones not checked).
- Where: `.github/workflows/ci.yml:45-46`.
- Cause: `git ls-files 'agent/*.sh'` and `'agent/*.py'` match only `agent/connect.py`, because a git pathspec `*` does not cross `/`. `agent/vm/{get-tart,provision,session}.sh` and `agent/vm/{ask,helper}.py` are outside the pattern, so `bash -n` and `py_compile` never see them. Verified with `git ls-files 'agent/*.sh'`: no output.
- Suggested fix: `git ls-files 'agent/*.sh' 'agent/vm/*.sh'` (and the same for `*.py`), or `git ls-files -z '*.sh' '*.py' | xargs -0 …`. Drop the `argv[1]` shape of `main.swift:7` too (F6) or CI inheritance hides it.

### F14 · `Toml.array` and `Toml.table` split on every comma, including ones inside quotes — 2026-11-02
- Severity: medium (a config value containing a comma is silently cut in two, and the halves reach the allowlist, budgets and download menus).
- Where: `Config.swift:45-62`.
- Cause: `s.dropFirst().dropLast().split(separator: ",")` has no notion of string context, so `browsers = ["Acme, Inc"]` becomes `["Acme", "Inc"]` and `[agent] download_menu = ["save as, really"]` becomes two phrases. `table(_:)` has the same split, so `{ count = 1, window_s = 60 }` only survives because its values happen to be bare numbers while `{ note = "a, b" }` would not.
- Suggested fix: split on top-level commas only — track quotes the way `stripComment` already does — and reuse one splitter for `array` and `table`. `Toml.unquote` already handles the quoting.

### F15 · A `[vm] password` containing a quote breaks the first-boot key install and the VNC password — 2026-11-02
- Severity: medium (silent: `vm setup` reports success with no VNC password set, so `vm look` asks for one nobody knows).
- Where: `agent/vm/provision.sh:33` (`su "$user" -c "x11vnc -storepasswd '$password' …"`), `VM.swift:400` (password interpolated into the remote shell command), `VM.swift:351` (written into a `#!/bin/sh` askpass script as `echo '\(password)'`).
- Cause: the password goes into a shell string single-quoted by hand at three layers. A `password` from `[vm]` with `'`, `$` or a backtick either breaks the command or runs part of it; in provision.sh the failure is swallowed (`>/dev/null 2>&1`), so the VNC password is simply never written.
- Suggested fix: pass the password as an argument over stdin rather than interpolating it — `printf '%s' "$2" | x11vnc -storepasswd - …` in the guest, and `VM.quoted()` (already present in `Remote+More.swift:153`) for the host-side command strings. Note in `config.example.toml` that the alphabet should stay simple.

### F16 · A project's `min_gap_s` shorter than 30 s is never waited out — 2026-11-02
- Severity: medium (the project cap is enforced for counts but not for spacing, so two actions can go out back to back).
- Where: `SiteRules.swift:175-181`.
- Cause: the recording project pass is `_ = try? Project.update(project) { try count(…, record: true, …) }`, which throws away the returned wait; only the account-wide `Limits.update` result is slept on (`if wait > 0 { … }`). `count` only *throws* for a gap over 30 s, so a 10 s project gap is computed and dropped.
- Suggested fix: keep the project wait (`let projectWait = try Project.update { … }`) and sleep on `max(wait, projectWait)`. `try?` also hides a throw from `Project.update` itself, which would silently skip the project check entirely.

### F17 · `Awake`'s assertion list and `lastEnd` are touched from three queues without a lock — 2026-11-02
- Severity: low–medium (a data race on an `Array` and a `Date`; `assertions = []` while another thread appends is undefined behaviour, and a lost release leaves the Mac awake).
- Where: `Awake.swift:12-13,16-49`.
- Cause: `hold()`/`release()` run on `Daemon.queue` (inside `busy`), `set()` runs on whatever queue the `awake` handler is on, and the deferred release hops through `DispatchQueue.main.asyncAfter` then `Daemon.queue.async` — three contexts sharing two statics with no synchronisation. `Rand` uses `OSAllocatedUnfairLock` for exactly this reason; `Awake` does not.
- Suggested fix: put the state behind `OSAllocatedUnfairLock` like `Rand.state`, and have the deferred release read `lastEnd` inside the same lock.

### F18 · `helper.py`'s browser bounds mix `min(width)` with `max(x)`, so an inset page looks offscreen — 2026-11-02
- Severity: low (Chromium's document box normally matches the window, so it works today; a sidebar or inset viewport makes every element read as `(off)`).
- Where: `agent/vm/helper.py:344`.
- Cause: the intent is the intersection of the document and window boxes, but the width/height are `min(dframe[2], wframe[2])` while the origin is `max(dframe[0], wframe[0])`. With an inset document (x=0 vs x=180) that gives `x = 180, width = min(w, w-180)` — a box that is both shifted and too wide, so `intersects` accepts text that is not on the page and `Remote.bounds` centres scrolling in the wrong place.
- Suggested fix: compute the edges — `left = max(x1,x2); right = min(x1+w1, x2+w2); box = [left, top, max(right-left,0), max(bottom-top,0)]`.

### F19 · `--json` is promised for every command but only three paths honour it — 2026-11-02
- Severity: low (an agent scripting the output gets plain text back instead of JSON, with no error).
- Where: `main.swift:78` ("add --json for the raw reply") versus `main.swift:134-143` and `194-201`.
- Cause: only `route`/`notes` and the default socket branch look at `a.has("json")`; every command in `loggedHere` (`budget`, `policy`, `grow`, `sessions`, `doctor`, `vm`, `pr`, …) prints whatever the command returned. `Commands.finish` even strips `--json` from the logged flags as if it were handled.
- Suggested fix: wrap the client-side commands so `--json` prints `Response(code:out:)`, or drop the blanket promise from `usage()` and name the commands that support it.

### F20 · `upload`/`choose` nest `Borrow.run`, which clears `active` while the outer borrow is still acting — 2026-11-02
- Severity: low (the interruption check and `Mouse.landing`'s `Remote.active` routing are briefly wrong; no known break today).
- Where: `Commands.swift:965-1019` (`choosePath` opens its own `Borrow.run`) called from `Commands.swift:957` and `Commands.swift:1059`, both already inside one.
- Cause: the inner `Borrow.run` does `defer { active = false }`, so on return the outer body continues with `Borrow.active == false` even though it is still inside the outer `run`. The inner also runs `waitIdle` a second time and installs a second event monitor.
- Suggested fix: make `Borrow.run` re-entrant — skip the monitor/`active` bookkeeping when `active` is already true and only reset it in the outermost call.

### F21 · `AgentLoop` writes a saved replay twice and its last retry branch is unreachable — 2026-11-02
- Severity: low (cosmetic: a duplicate write, and a misleading error message on a provider that stays busy).
- Where: `AgentLoop.swift:62,98` and `AgentLoop.swift:274-286`.
- Cause: `defer { if !used.isEmpty { save(a, used) } }` already saves, and the `.done` branch calls `save(a, used)` a second time. In `chat`, the loop's `catch` covers `attempt < 4`, so on attempt 4 a `Fail(4, …)` propagates with the provider's text and `throw Fail(4, "model still busy after 4 tries")` can never run.
- Suggested fix: drop the explicit `save` in the `.done` branch, and either catch the last failure to produce the "still busy" message or delete the dead throw.

### F22 · `Remote.openViewer` ignores whether its ssh tunnel came up — 2026-11-02
- Severity: low (the user gets a Screen Sharing window that cannot connect, instead of being told the port is taken).
- Where: `VM.swift:96-106`.
- Cause: `run("/usr/bin/ssh", ["-f", "-N", "-o", "ExitOnForwardFailure=yes", …])` returns a status that is discarded, then the VNC URL is opened regardless. With a tunnel from an earlier `vm look` still holding the port, `ExitOnForwardFailure` makes this ssh exit non-zero and the URL points at nothing.
- Suggested fix: keep the result and, on a non-zero exit, either reuse the existing tunnel (the usual case) or `throw Fail(5, …)` naming the port; only open the URL once a connection to `127.0.0.1:<port>` succeeds.

### F23 · Two small leftovers: unused switches, and a spare keycode that can be reused for a second character — 2026-11-02
- Severity: low (dead config, and a rare wrong character when two unmapped characters are typed close together).
- Where: `Commands.swift:12-15` (`"front"`, `"real"` in `Args.switches`, neither read anywhere); `agent/vm/helper.py:388-404` (`keycode_for`).
- Cause: the two switches are parsed as booleans for flags that no command has. In `keycode_for`, a spare keycode is popped, remapped to the new character, then pushed back onto `spare`, so the same physical key can be remapped again for a different character later in the same string.
- Suggested fix: delete `front`/`real`. In the helper, keep remapped keycodes out of `spare` (or cache `char → keycode`) so a mapping is never stolen from a character that may still be typed.

### F24 · `Project.update` silently drops the project's counts when its folder is gone — 2026-11-02
- Severity: low (a deleted `.apprentice/` turns project caps into no-ops with no warning, while the account-wide caps still apply).
- Where: `Project.swift:37-46`.
- Cause: `open(dir.appendingPathComponent("limits.json.lock"), …)` fails with `fd < 0` when the folder no longer exists, the body still runs unlocked, and the final `try? data.write(…)` fails silently. `Budgets.check` cannot tell that from a successful check.
- Suggested fix: `try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)` before opening the lock, and surface a failure as exit 5 (or a note) rather than `try?`.

### F25 · The key-layout cache is keyed on the input source alone, so another keyboard keeps the old key codes — 2026-11-02
- Severity: medium (`key cmd+a` and `type` press the wrong physical key after a keyboard change, until the input source is switched).
- Where: `Input.swift:47-54` (the `layoutID`/`layoutMap` cache), `Input.swift:66-71` (`UCKeyTranslate(…, LMGetKbdType(), …)`).
- Cause: the cache is rebuilt only when `kTISPropertyInputSourceID` changes. `LMGetKbdType()` — the *hardware* keyboard type, 0x28 ANSI / 0x29 ISO / 0x2A JIS — is read at build time and is not part of the key, so moving from a built-in ANSI keyboard to a JIS one, or a keyboard whose type macOS records differently, leaves a map translated for the old layout. Apple's own guidance keys such a cache on both the source and the keyboard type. The two statics are also written and read from more than one queue (`type` on the command queue, `menu`/`choose` on the questions queue) with no lock, so a `Dictionary` can be mutated while another thread reads it.
- Suggested fix: cache on `"\(id)|\(LMGetKbdType())"`, and hold `layoutID`/`layoutMap` behind `OSAllocatedUnfairLock` the way `Rand.state` is.

### F26 · A window on a second display is captured at the wrong scale — 2026-11-02
- Severity: medium (blurry OCR text and misplaced `shot --on` crops on any Mac with a display that is not level with the built-in one, which is how most external monitors are arranged).
- Where: `Capture.swift:46-53`.
- Cause: the flip from CG's top-left origin to NSScreen's bottom-left origin uses `main = NSScreen.screens.first?.frame.height`, i.e. the *primary* screen's height, as if every display shared its top edge. A display placed above the primary one has negative y; one that is taller or shorter shifts the flipped rect by the difference. The rect then matches no screen (or the wrong one), `max(by: intersection.area)` picks whatever screen sorting leaves last, and `config.width`/`height` are scaled by the wrong `backingScaleFactor` — a 1× monitor captured at 2×, or a Retina window captured at 1× and then OCR'd from a thumbnail.
- Suggested fix: flip against the union of all screens — `let all = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }`, then `y: all.maxY - frame.maxY` — and fall back to the main screen's `backingScaleFactor` when no screen intersects at all.

### F27 · A failed internal `deny` overwrites the user's answer, changing exit 3 into exit 5 — 2026-11-02
- Severity: medium (an agent branching on exit 3 "the user denied" instead sees 5 "not found" and may retry the step the user just refused).
- Where: `Ask.swift:411-413`.
- Cause: the refusal path is `if reply != nil { _ = try Daemon.command(Request(cmd: "deny", args: [token])) }` followed by `throw Fail(3, "The user denied: …")`. If the proposal expired between the click and the deny — another agent ran `deny`, the daemon restarted, or the pending file was pruned — that `try` throws first and its message and code replace the intended one. Every other cleanup call in this file uses `try?`; this one does not.
- Suggested fix: `_ = try? Daemon.command(…)`, so the denial is always what the caller is told, and log a failed deny instead of raising it.

### F28 · `settings local` deletes the live config before it moves the new one in — 2026-11-02
- Severity: medium-low (`~/.apprentice` can be left with no `config.toml` at all, so every later command runs on defaults until the file is restored by hand).
- Where: `Settings.swift:31-35`.
- Cause: for each file, `try? fm.removeItem(at: Store.dir/file)` runs first and `try fm.moveItem(...)` second. Any failure of the move — a full disk, a permission change, or `settings` on another volume where `moveItem` must copy-then-delete — throws out of the loop with the destination already removed, the source still in the old clone, and `synced` still true, so the next attempt repeats exactly the same thing.
- Suggested fix: move to a temporary name in `Store.dir` and then `replaceItemAt`, or copy, verify the byte count, and only then remove the source. Report a partial move rather than throwing out of the loop.

### F29 · OCR splits a long line in two when its words drift from the first word's baseline — 2026-11-02
- Severity: low (`read`, `click --text` and `ocr` see half a line, so a phrase that is on screen reads as not found).
- Where: `Capture.swift:159-166`.
- Cause: words are sorted by `midY` and merged when `abs(first.box.midY - w.box.midY) < 0.012`, where `first` is the row's *first* word. Vision's baselines drift across a long line (a link, bold text, a taller first glyph, or a slightly rotated window), so a word 0.013 of the image height away from the first word starts a new row even though it sits on the same line as its immediate neighbour. The text is then joined into two half-lines.
- Suggested fix: compare against the running row's mean (or last word's) `midY`, and keep a running union box, so the row follows the line as it drifts.

### F30 · `type --paste` can empty the clipboard instead of putting it back — 2026-11-02
- Severity: low (the user's clipboard is lost, not just redirected; Finder copies, Mail attachments and "Paste from iPhone" entries are the ones affected).
- Where: `Input.swift:202-221`.
- Cause: `saved` is built with `item.types.reduce(into:) { $0[$1] = item.data(forType: $1) }`, which stores nil for any type whose data is provided lazily (`NSPasteboard` promises, file promises, and items still being fetched over Continuity). Those items come back as empty `NSPasteboardItem`s, so after `clearContents()` and the paste the board is restored with blank entries. The restore also has no `defer`, so anything thrown between the clear and the write leaves the clipboard empty for good.
- Suggested fix: skip types whose `data(forType:)` is nil and put back only items that still have at least one type (`if !types.isEmpty`), and wrap the clear/paste/restore in `defer { restore() }`.

### F31 · `uninstall --yes` reports the state folder removed even when files are left behind — 2026-11-02
- Severity: low (a user told apprentice is uninstalled still has `~/.apprentice` with the API key and logs in it, and no hint that it stayed).
- Where: `Doctor.swift:173-181`.
- Cause: the per-item loop is `try? fm.removeItem(atPath: path)`, and the closing `done.append("removed \(Store.dir.path)…")` is unconditional, as is the final `try? fm.removeItem(atPath: Store.dir.path)`. Anything that cannot be removed — a file held open by a running daemon, a `vms/` mount still attached, a folder another user owns — leaves the folder in place while the output says it is gone.
- Suggested fix: keep a `failed: [String]` list, add to it when `removeItem` throws, and print those paths with the reason at the end (exit non-zero if any remain) instead of the blanket "removed".
