# apprentice — bug audit

## Field reports

Filed by `apprentice bug` while working. Each has a suggested fix to review; none is applied.
### F2 · `VM.run` can deadlock when a caller passes a large stdin — 2026-11-01
- Cause: `VM.run` writes the whole `input` to the child's stdin before it starts reading stdout, so a child that both reads more than a pipe buffer and writes more than one to stdout blocks while the writer blocks too. Today's callers (`vm install`'s tar, `wire`'s one line) stay under the limit, so this is latent, not live.
- Suggested fix: write stdin from a background queue in the same `DispatchGroup` as the stderr drain, so stdout is read while the child is still consuming its input.

### F3 · A mixed-case pacing profile is silently ignored — 2026-11-01
- Cause: `Config.load` keys `profiles` by the section as written, while `profileKey` lowercases the host before looking it up, and `profiles[session.app]` matches only exactly. `[pace."LinkedIn.com"]` therefore does nothing, and `[pace."Safari"]` works only because the app name happens to be spelled that way.
- Suggested fix: lowercase the key in `load()` and lowercase `session.app` at the app lookup, so every spelling matches.

### F4 · MCP answers `budget`, `policy` and `activity` from the host while the browser runs in the VM — 2026-11-01
- Cause: `MCP.runLocally` and `MCP.map` call `Budgets.report` / `Policies.describe` / the daemon directly. Only the CLI forwards these to the guest (`VM.forward` in `main.swift`), so with `vm on` an MCP client sees the host's budgets, events and policies, which are for a machine taking no actions.
- Suggested fix: forward the same three commands through `VM.forward` when the VM is on, as `main.swift` does, and answer from the guest.




### F9 · `replay <name> --from n` past the end reports success with 0 steps — 2026-11-02
- Severity: high (a caller resuming a replay is told it finished, so the work silently never happens).
- Where: `AgentLoop.swift:385-404`.
- Cause: `for item in list.dropFirst(first - 1)` yields nothing when `first > list.count`, the loop never runs and the function prints `replay · 0 steps · ok`, exit 0. The same happens for `--from 1` on a saved run that contains no `cmd` rows.
- Suggested fix: `guard first <= list.count else { throw Fail(5, "replay \"\(name)\" has \(list.count) steps; --from \(first) is past the end") }`, and fail when `used.isEmpty` in `AgentLoop.save`.

### F10 · The VM's file-dialog box has the wrong sign, so `upload`/`download` cannot find the Open/Save button — 2026-11-02
- Severity: high for anything that moves files through a GTK dialog in the VM.
- Where: `agent/vm/helper.py:545-546`.
- Cause: `w.translate_coords(root, 0, 0)` already returns the window origin **in root coordinates**, so the box is then negated into `[-at.x, -at.y, …]` — a window at (300, 200) is reported at (-300, -200). `Remote.confirmDialog` (`Remote+More.swift:74-86`) filters OCR hits with `box.contains(point)`, which can never match a negative-origin rectangle, so the button is never clicked and it falls through to `Keys.press("return")` — which `pick`'s own comment (`Remote+More.swift:70-72`) says "closes the dialog without passing the file on" in GTK. The `frame` is the only consumer, so nothing else notices.
- Suggested fix: `box = [at.x, at.y, g.width, g.height]` (or keep the negation but call `root.translate_coords(w, 0, 0)`). Worth a comment saying which direction the API goes, since this is the classic sign trap.


### F14 · `Toml.array` and `Toml.table` split on every comma, including ones inside quotes — 2026-11-02
- Severity: medium (a config value containing a comma is silently cut in two, and the halves reach the allowlist, budgets and download menus).
- Where: `Config.swift:46-64`.
- Cause: `s.dropFirst().dropLast().split(separator: ",")` has no notion of string context, so `browsers = ["Acme, Inc"]` becomes `["Acme", "Inc"]` and `[agent] download_menu = ["save as, really"]` becomes two phrases. `table(_:)` has the same split, so `{ count = 1, window_s = 60 }` only survives because its values happen to be bare numbers while `{ note = "a, b" }` would not.
- Suggested fix: split on top-level commas only — track quotes the way `stripComment` already does — and reuse one splitter for `array` and `table`. `Toml.unquote` already handles the quoting.

### F15 · A `[vm] password` containing a quote breaks the first-boot key install and the VNC password — 2026-11-02
- Severity: medium (silent: `vm setup` reports success with no VNC password set, so `vm look` asks for one nobody knows).
- Where: `agent/vm/provision.sh:38` (`su "$user" -c "x11vnc -storepasswd '$password' …"`), `VM.swift:401` (the password is in the `provision.sh` argv), `VM.swift:373` (the guest-side password change, `echo '\(user):\(fresh)' | … chpasswd`), `VM.swift:352` (written into a `#!/bin/sh` askpass script as `echo '\(password)'`).
- Cause: the password goes into a shell string single-quoted by hand at three layers. A `password` from `[vm]` with `'`, `$` or a backtick either breaks the command or runs part of it; in provision.sh the failure is swallowed (`>/dev/null 2>&1`), so the VNC password is simply never written.
- Suggested fix: pass the password as an argument over stdin rather than interpolating it — `printf '%s' "$2" | x11vnc -storepasswd - …` in the guest, and `VM.quoted()` (already present in `Remote+More.swift:153`) for the host-side command strings. Note in `config.example.toml` that the alphabet should stay simple.

### F16 · A project's `min_gap_s` shorter than 30 s is never waited out — 2026-11-02
- Severity: medium (the project cap is enforced for counts but not for spacing, so two actions can go out back to back).
- Where: `SiteRules.swift:175-181`.
- Cause: the recording project pass is `_ = try? Project.update(project) { try count(…, record: true, …) }`, which throws away the returned wait; only the account-wide `Limits.update` result is slept on (`if wait > 0 { … }`). `count` only *throws* for a gap over 30 s, so a 10 s project gap is computed and dropped.
- Suggested fix: keep the project wait (`let projectWait = try Project.update { … }`) and sleep on `max(wait, projectWait)`. `try?` also hides a throw from `Project.update` itself, which would silently skip the project check entirely.

### F17 · `Awake`'s assertion list and `lastEnd` are touched from three queues without a lock — 2026-11-02
- Severity: low–medium (a data race on an `Array` and a `Date`; `assertions = []` while another thread appends is undefined behaviour, and a lost release leaves the Mac awake).
- Where: `Awake.swift:12-13,17-48`.
- Cause: `hold()`/`release()` run on `Daemon.queue` (inside `busy`), `set()` runs on whatever queue the `awake` handler is on, and the deferred release hops through `DispatchQueue.main.asyncAfter` then `Daemon.queue.async` — three contexts sharing two statics with no synchronisation. `Rand` uses `OSAllocatedUnfairLock` for exactly this reason; `Awake` does not.
- Suggested fix: put the state behind `OSAllocatedUnfairLock` like `Rand.state`, and have the deferred release read `lastEnd` inside the same lock.

### F18 · `helper.py`'s browser bounds mix `min(width)` with `max(x)`, so an inset page looks offscreen — 2026-11-02
- Severity: low (Chromium's document box normally matches the window, so it works today; a sidebar or inset viewport makes every element read as `(off)`).
- Where: `agent/vm/helper.py:348`.
- Cause: the intent is the intersection of the document and window boxes, but the width/height are `min(dframe[2], wframe[2])` while the origin is `max(dframe[0], wframe[0])`. With an inset document (x=0 vs x=180) that gives `x = 180, width = min(w, w-180)` — a box that is both shifted and too wide, so `intersects` accepts text that is not on the page and `Remote.bounds` centres scrolling in the wrong place.
- Suggested fix: compute the edges — `left = max(x1,x2); right = min(x1+w1, x2+w2); box = [left, top, max(right-left,0), max(bottom-top,0)]`.

### F19 · `--json` is promised for every command but only three paths honour it — 2026-11-02
- Severity: low (an agent scripting the output gets plain text back instead of JSON, with no error).
- Where: `main.swift:81` ("add --json for the raw reply") versus `main.swift:138-143` and `:203-204`.
- Cause: only `route`/`playbooks` and the default socket branch look at `a.has("json")`; every command in `loggedHere` (`budget`, `policy`, `grow`, `sessions`, `doctor`, `vm`, `pr`, …) prints whatever the command returned. `Commands.finish` even strips `--json` from the logged flags as if it were handled.
- Suggested fix: wrap the client-side commands so `--json` prints `Response(code:out:)`, or drop the blanket promise from `usage()` and name the commands that support it.
### F21 · `AgentLoop` writes a saved replay twice and its last retry branch is unreachable — 2026-11-02
- Severity: low (cosmetic: a duplicate write, and a misleading error message on a provider that stays busy).
- Where: `AgentLoop.swift:62,97` and `AgentLoop.swift:288-301`.
- Cause: `defer { if !used.isEmpty { save(a, used) } }` already saves, and the `.done` branch calls `save(a, used)` a second time. In `chat`, the loop's `catch` covers `attempt < 4`, so on attempt 4 a `Fail(4, …)` propagates with the provider's text and `throw Fail(4, "model still busy after 4 tries")` can never run.
- Suggested fix: drop the explicit `save` in the `.done` branch, and either catch the last failure to produce the "still busy" message or delete the dead throw.

### F22 · `Remote.openViewer` ignores whether its ssh tunnel came up — 2026-11-02
- Severity: low (the user gets a Screen Sharing window that cannot connect, instead of being told the port is taken).
- Where: `VM.swift:98-104`.
- Cause: `run("/usr/bin/ssh", ["-f", "-N", "-o", "ExitOnForwardFailure=yes", …])` returns a status that is discarded, then the VNC URL is opened regardless. With a tunnel from an earlier `vm look` still holding the port, `ExitOnForwardFailure` makes this ssh exit non-zero and the URL points at nothing.
- Suggested fix: keep the result and, on a non-zero exit, either reuse the existing tunnel (the usual case) or `throw Fail(5, …)` naming the port; only open the URL once a connection to `127.0.0.1:<port>` succeeds.

### F23 · Two small leftovers: unused switches, and a spare keycode that can be reused for a second character — 2026-11-02
- Severity: low (dead config, and a rare wrong character when two unmapped characters are typed close together).
- Where: `Commands.swift:14` (`"front"`, `"real"` in `Args.switches`, neither read anywhere); `agent/vm/helper.py:397-408` (`keycode_for`).
- Cause: the two switches are parsed as booleans for flags that no command has. In `keycode_for`, a spare keycode is popped, remapped to the new character, then pushed back onto `spare`, so the same physical key can be remapped again for a different character later in the same string.
- Suggested fix: delete `front`/`real`. In the helper, keep remapped keycodes out of `spare` (or cache `char → keycode`) so a mapping is never stolen from a character that may still be typed.

### F24 · `Project.update` silently drops the project's counts when its folder is gone — 2026-11-02
- Severity: low (a deleted `.apprentice/` turns project caps into no-ops with no warning, while the account-wide caps still apply).
- Where: `Project.swift:39-48`.
- Cause: `open(dir.appendingPathComponent("limits.json.lock"), …)` fails with `fd < 0` when the folder no longer exists, the body still runs unlocked, and the final `try? data.write(…)` fails silently. `Budgets.check` cannot tell that from a successful check.
- Suggested fix: `try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)` before opening the lock, and surface a failure as exit 5 (or a note) rather than `try?`.

### F25 · The key-layout cache is keyed on the input source alone, so another keyboard keeps the old key codes — 2026-11-02
- Severity: medium (`key cmd+a` and `type` press the wrong physical key after a keyboard change, until the input source is switched).
- Where: `Input.swift:52-56` (the `layoutID`/`layoutMap` cache), `Input.swift:67-72` (`UCKeyTranslate(…, LMGetKbdType(), …)`).
- Cause: the cache is rebuilt only when `kTISPropertyInputSourceID` changes. `LMGetKbdType()` — the *hardware* keyboard type, 0x28 ANSI / 0x29 ISO / 0x2A JIS — is read at build time and is not part of the key, so moving from a built-in ANSI keyboard to a JIS one, or a keyboard whose type macOS records differently, leaves a map translated for the old layout. Apple's own guidance keys such a cache on both the source and the keyboard type. The two statics are also written and read from more than one queue (`type` on the command queue, `menu`/`choose` on the questions queue) with no lock, so a `Dictionary` can be mutated while another thread reads it.
- Suggested fix: cache on `"\(id)|\(LMGetKbdType())"`, and hold `layoutID`/`layoutMap` behind `OSAllocatedUnfairLock` the way `Rand.state` is.

### F26 · A window on a second display is captured at the wrong scale — 2026-11-02
- Severity: medium (blurry OCR text and misplaced `shot --on` crops on any Mac with a display that is not level with the built-in one, which is how most external monitors are arranged).
- Where: `Capture.swift:47-54`.
- Cause: the flip from CG's top-left origin to NSScreen's bottom-left origin uses `main = NSScreen.screens.first?.frame.height`, i.e. the *primary* screen's height, as if every display shared its top edge. A display placed above the primary one has negative y; one that is taller or shorter shifts the flipped rect by the difference. The rect then matches no screen (or the wrong one), `max(by: intersection.area)` picks whatever screen sorting leaves last, and `config.width`/`height` are scaled by the wrong `backingScaleFactor` — a 1× monitor captured at 2×, or a Retina window captured at 1× and then OCR'd from a thumbnail.
- Suggested fix: flip against the union of all screens — `let all = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }`, then `y: all.maxY - frame.maxY` — and fall back to the main screen's `backingScaleFactor` when no screen intersects at all.

### F27 · A failed internal `deny` overwrites the user's answer, changing exit 3 into exit 5 — 2026-11-02
- Severity: medium (an agent branching on exit 3 "the user denied" instead sees 5 "not found" and may retry the step the user just refused).
- Where: `Ask.swift:414-427`.
- Cause: the refusal path is `if reply != nil { _ = try Daemon.command(Request(cmd: "deny", args: [token])) }` followed by `throw Fail(3, "The user denied: …")`. If the proposal expired between the click and the deny — another agent ran `deny`, the daemon restarted, or the pending file was pruned — that `try` throws first and its message and code replace the intended one. Every other cleanup call in this file uses `try?`; this one does not.
- Suggested fix: `_ = try? Daemon.command(…)`, so the denial is always what the caller is told, and log a failed deny instead of raising it.

### F28 · `settings local` deletes the live config before it moves the new one in — 2026-11-02
- Severity: medium-low (`~/.apprentice` can be left with no `config.toml` at all, so every later command runs on defaults until the file is restored by hand).
- Where: `Settings.swift:30-34`.
- Cause: for each file, `try? fm.removeItem(at: Store.dir/file)` runs first and `try fm.moveItem(...)` second. Any failure of the move — a full disk, a permission change, or `settings` on another volume where `moveItem` must copy-then-delete — throws out of the loop with the destination already removed, the source still in the old clone, and `synced` still true, so the next attempt repeats exactly the same thing.
- Suggested fix: move to a temporary name in `Store.dir` and then `replaceItemAt`, or copy, verify the byte count, and only then remove the source. Report a partial move rather than throwing out of the loop.

### F29 · OCR splits a long line in two when its words drift from the first word's baseline — 2026-11-02
- Severity: low (`read`, `click --text` and `ocr` see half a line, so a phrase that is on screen reads as not found).
- Where: `Capture.swift:160-168`.
- Cause: words are sorted by `midY` and merged when `abs(first.box.midY - w.box.midY) < 0.012`, where `first` is the row's *first* word. Vision's baselines drift across a long line (a link, bold text, a taller first glyph, or a slightly rotated window), so a word 0.013 of the image height away from the first word starts a new row even though it sits on the same line as its immediate neighbour. The text is then joined into two half-lines.
- Suggested fix: compare against the running row's mean (or last word's) `midY`, and keep a running union box, so the row follows the line as it drifts.

### F30 · `type --paste` can empty the clipboard instead of putting it back — 2026-11-02
- Severity: low (the user's clipboard is lost, not just redirected; Finder copies, Mail attachments and "Paste from iPhone" entries are the ones affected).
- Where: `Input.swift:206-226`.
- Cause: `saved` is built with `item.types.reduce(into:) { $0[$1] = item.data(forType: $1) }`, which stores nil for any type whose data is provided lazily (`NSPasteboard` promises, file promises, and items still being fetched over Continuity). Those items come back as empty `NSPasteboardItem`s, so after `clearContents()` and the paste the board is restored with blank entries. The restore also has no `defer`, so anything thrown between the clear and the write leaves the clipboard empty for good.
- Suggested fix: skip types whose `data(forType:)` is nil and put back only items that still have at least one type (`if !types.isEmpty`), and wrap the clear/paste/restore in `defer { restore() }`.

### F31 · `uninstall --yes` reports the state folder removed even when files are left behind — 2026-11-02
- Severity: low (a user told apprentice is uninstalled still has `~/.apprentice` with the API key and logs in it, and no hint that it stayed).
- Where: `Doctor.swift:173-181`.
- Cause: the per-item loop is `try? fm.removeItem(atPath: path)`, and the closing `done.append("removed \(Store.dir.path)…")` is unconditional, as is the final `try? fm.removeItem(atPath: Store.dir.path)`. Anything that cannot be removed — a file held open by a running daemon, a `vms/` mount still attached, a folder another user owns — leaves the folder in place while the output says it is gone.
- Suggested fix: keep a `failed: [String]` list, add to it when `removeItem` throws, and print those paths with the reason at the end (exit non-zero if any remain) instead of the blanket "removed".

### F32 · `pr` titles the pull request after an auto-written session commit — 2026-11-02
- Severity: medium (a PR opened without `--title` is called "Session 2026-11-02-ab12cd: 9 steps on example.com", and its list of changes is mostly session copies).
- Where: `PR.swift:12` (archive first), `PR.swift:22` (the commit range), `PR.swift:44` (`title = a.value("title") ?? subjects[0]`), `PR.swift:70-80`; `Sessions.swift:80`.
- Cause: `PR.run` calls `Sessions.archiveCurrent()` before it looks at the log, and `Sessions.archive` writes `sessions/<run>.jsonl` and commits it itself with `Repo.commit("Session …: N steps on …", paths:)`. `Repo.commit` uses that message verbatim, so those auto-written commits sit inside `remote/<base>..HEAD` and are part of `subjects`. `title` defaults to `subjects.first` — the *oldest* local commit, which is usually one of them — and `body()` lists every subject under `## Changes`, so the reviewer's summary of a fix is mostly "Session …" lines.
- Suggested fix: keep the session commits in the range (they are meant to be published) but filter `hasPrefix("Session ")` when choosing the title and when writing `## Changes`; fall back to the newest non-session subject, then to the branch name.

### F33 · `wait-for` cannot be interrupted and holds the command queue for its whole timeout — 2026-11-02
- Severity: medium (`wait-for text --timeout 600` wedges the daemon for ten minutes: every other command queues behind it, and the kill switch does nothing until it returns).
- Where: `Commands.swift:1255-1276`.
- Cause: it polls with `poll(timeout:interval:)`, which only sleeps and re-reads the snapshot. It never calls `Borrow.checkpoint()`, never reads `KillSwitch.tripped` and never begins `Watch`, while `Daemon` runs commands one at a time from a single queue — so a press during a long wait is not seen until the poll ends, and a second command cannot start. `--timeout` is also read as `a.value("timeout").flatMap(Double.init) ?? 10`, so `--timeout 6oo` silently becomes 10 s instead of being an error the way `a.count` is.
- Suggested fix: read the timeout with `try a.count("timeout", 10, min: 1)` and cap it; check the kill switch and `Borrow.interrupted` inside the loop (throwing exit 6) so a press stops the wait.

### F34 · A command interrupted after a page-change note prepends that note to the next command — 2026-11-02
- Severity: low (unrelated output such as `read` or `click` opens with "note: the page changed to …" for a page it has nothing to do with).
- Where: `Commands.swift:298` (the static), `Commands.swift:158` (where it is set), `Commands.swift:332-333`.
- Cause: `notice` is cleared only by `defer { notice = nil }`, registered *after* the two interrupt checks (`Watch.end()` and the kill switch). A command that sets the note in `prepare()` and is then interrupted throws exit 6 with `notice` still set, and the daemon keeps the static for the next request.
- Suggested fix: clear `notice` with the other per-command state at the top of `run`, beside `charged = nil`.

### F35 · The cached VM address is never re-checked, so a new DHCP lease breaks every VM command — 2026-11-02
- Severity: medium (screen, `upload`, `download` and `vm call` stop working against a VM that is running, and the error blames the wrong thing).
- Where: `VM.swift:138-146`; the session path at `Remote.swift:92` calls `VM.address()` without `fresh: true`, which only `vm up`/`vm status` pass (`VM.swift:301`, `:315`).
- Cause: `address(fresh: false)` returns `state.ip` from `state.json` without any check, and only `vm down` clears it. The guest's address is a DHCP lease: after a Mac reboot, a lease change, or the VM being started or restarted outside apprentice, the cached IP stays wrong for good — `tart list` reports the VM as running while every ssh to the stale address fails, and `address()`'s own failure says "the VM is not running: start it with `apprentice vm up`".
- Suggested fix: confirm a cached address before using it (`answers(ip)` or `ssh(ip, "true").code == 0`), fall back to `tart ip … --wait` and store the result; say "not running" only when `running` is false, and "running but not reachable at <ip>" otherwise.

### F36 · Two `shot` commands in the same second overwrite each other — 2026-11-02
- Severity: low (the path the first command printed, and logged, ends up showing the second picture).
- Where: `Commands.swift:1305-1306`.
- Cause: the file is `shots/shot-<HHmmss>.png`, and `Capture.save` overwrites an existing file without complaint. Two captures inside one second — the usual before/after pair, since a `shot` of a small window is fast — get the same name, so the pair an agent compares is two copies of the later image.
- Suggested fix: put the snapshot number in the name (`shot-\(snap)-…`) or a millisecond/random suffix, so a path is never reused.

### F37 · `[vm] local` is documented as the way to keep a site off the VM, but no code reads it — 2026-11-02
- Severity: medium (a safety control the docs tell the user to rely on does nothing: with `vm on`, a site they listed as kept on this Mac still goes to the guest).
- Where: `SPEC.md:456`, `FEATURES.md:156`; the settings reader `VM.swift:24-44`; the routing in `Remote.swift`.
- Cause: `VM.settings` merges `[vm]` and `[vm.<name>]` and `VM.swift:28` reserves only `name`, `host` and `port` as per-VM keys; `host` is read at `VM.swift:43`. Nothing reads a `local` list, and `Remote.wants` never consults one. Both docs state it as shipped: "Accounts whose standing matters most stay on this Mac's own browser: `[vm] local = [\"site.com\"]` refuses them in every VM."
- Suggested fix: read `[vm] local` into a list of domains (matched with `Site.domain`, so renames count), and refuse in `Remote.wants` with `Fail(4, "vm: <site> is kept on this Mac ([vm] local)")`. If it is not going to be built, move it to `TODO.md` and delete the two doc claims.

### F39 · SPEC's architecture table calls the VM a macOS guest — 2026-11-02
- Severity: low (someone planning from the component table believes a macOS VM exists; the README says it is only planned).
- Where: `SPEC.md:88`.
- Cause: everything else says Linux or Debian — `SPEC.md:449-453` ("A Debian guest (Tart …)"), `README.md:72` and `:96` ("There is no macOS VM yet"), `TODO.md:5`, `site/llms.txt:8`, and `agent/vm/provision.sh` installs Debian. Only the table row says "Optional macOS guest so browser work has its own cursor and keyboard".
- Suggested fix: make the row read "Optional Linux (Debian) guest under Tart, so browser work has its own cursor and keyboard; a macOS guest is planned".

### F40 · `vm list` is implemented and told to agents, but `usage()` and the README leave it out — 2026-11-02
- Severity: low (an agent that reads only `apprentice help` or the README never learns it exists, and SPEC calls `usage()` "the full list").
- Where: `VM.swift:252`; the `vm` line of `usage()` in `main.swift`; `README.md:136`; `agent/AGENTS.md:39`; `agent/SKILL.md:45`.
- Cause: `case "list": return list()` is handled, and both agent docs say "`vm list` shows them", but the usage line lists `setup | install | up | down | on | off | look | call "what" | shell | status` with no `list`, and the README row copies it. `SPEC.md:146` calls `usage()` the full list; `FEATURES.md:237` does include it.
- Suggested fix: add `| list` to the `vm` usage line and to the README's `vm` row.

### F41 · The README's command table is missing eight commands — 2026-11-02
- Severity: low (the README is the page agents are pointed at, and it has no row for `budget` or `focus`, both of which `agent/SKILL.md` and `agent/AGENTS.md` tell agents to run).
- Where: `README.md:112-137`.
- Cause: the table covers the rest of `usage()` but skips `focus` (`main.swift` usage:9), `budget` (38), `cool` (40), `activity` (41), `flag` (42), `serve` and `stop` (57), and `replay` (54). `FEATURES.md`'s command index lists all of them, and both agent docs use `focus` and `budget` in their loops.
- Suggested fix: add a `focus <app> [--on mac|linux]` row, a `budget`/`cool`/`activity`/`flag` row, and `serve`/`stop` and `replay` rows.

### F42 · `scroll --in` and `browse --in` silently scroll the window when the value is not a number — 2026-11-02
- Severity: low (a mistyped or label-valued target scrolls the page instead of the list, and the command reports success).
- Where: `Commands.swift:906` (`scroll`), `Commands.swift:933` (`browse`).
- Cause: both read the flag as `if let raw = a.value("in"), let id = Int(raw) { rect = try resolve(id, target).1.rect }`, so a value like `--in footer` makes the condition fail and execution falls through to the window-centre rect. The command then succeeds (`ok · snap …`) having scrolled the wrong thing; a numeric id that is stale or absent does throw, so only the non-numeric case is silent, and the log row records no `in`, so it cannot be told from the logs either.
- Suggested fix: `if let raw = a.value("in") { guard let id = Int(raw) else { throw Fail(5, "--in takes an element id, not \"\(raw)\"") }; rect = try resolve(id, target).1.rect }`.

### F43 · The `run` loop gives a VM session the Mac's playbooks and hides the VM's own — 2026-11-02
- Severity: medium (the loop that benefits most from playbooks gets the wrong set: it is told macOS input facts while acting in Debian, and never sees `playbooks/linux/general.md`).
- Where: `Playbooks.swift:132` (`context`), called from `AgentLoop.swift:58`.
- Cause: `context` builds its hints with `hintLines(app:bundle:host:)` and leaves the `system:` argument at its `"macos"` default, while `session` passes it explicitly (`Commands.swift:514`: `s.vm == true ? "linux" : "macos"`). `matching` filters on `meta["system"] == system`, so in a VM session `playbooks/macos/general.md` (`system: macos`) still matches and `playbooks/linux/general.md` (`system: linux`) is filtered out. `open` has the same gap at `Commands.swift:579`, where the playbook hint for a newly opened host is built without `system:` even on a VM.
- Suggested fix: pass `system: session?.vm == true ? "linux" : "macos"` from `context`, and add a selftest case with a VM session.

### F44 · Two system playbooks with a blank `match:` are never shown by `session`, `open` or `run` — 2026-11-02
- Severity: low (their Key facts exist to head off the most common confusion — save panels and web forms — and are never printed; only `playbooks "words"` finds them).
- Where: `playbooks/macos/save-panel.md` (`scope: system`, `match:` empty), `playbooks/web/general.md` (same); the filter in `Playbooks.swift:82-86`.
- Cause: `matching` keeps a playbook only if one of its `match` entries is `*`, an app or bundle id, or a host. Both files leave `match:` empty, so `Playbook.match` is `[]` and the playbook can never match, while the sibling system playbooks (`playbooks/macos/general.md`, `playbooks/linux/general.md`) use `match: *`. Nothing in `playbooks/README.md` says a blank `match` means "never", and the format example at line 23 presents `*` as the way to match every session.
- Suggested fix: give both playbooks `match: *` (a save panel is in every app; a web form is the point of `web/general.md`), or make `matching` treat an empty `match` on a `scope: system` playbook as `*` and say so in `playbooks/README.md`.

### F47 · The repo's own AGENTS.md still documents a workflow tree that is no longer there — 2026-11-02
- Severity: low (an agent following AGENTS.md opens `.agents/commands/<name>.md`, `.agents/rules/command-naming.md` or `.claude/commands`, finds nothing, and has to guess the routine it was told to run).
- Where: `AGENTS.md:119-127`; `TODO.md:72`.
- Cause: the tree now has no `.agents/` and no `.claude/` (43 tracked paths are deleted: the eight `commands/*.md`, `project-facts.md`, `rules/command-naming.md` and the skills). `AGENTS.md` still says each workflow lives in `.agents/commands/<name>.md`, lists the eight `/…` commands, sends command authors to `.agents/rules/command-naming.md` and the `command-authoring` skill, and says Claude Code sees them through `.claude/commands` and `.claude/rules` symlinks. `TODO.md:64` wants planted tasks in `.agents/skills/improve-prompts/scripts/agent_runs/` before `/improve-prompts` can measure anything, and that harness is gone with the rest.
- Suggested fix: restore the tree (that same paragraph says it comes from `install.sh`, so re-running it is the cheap repair), or cut the Workflows section down to what remains and drop the `TODO.md` item.

### F48 · FEATURES.md counts 33 MCP tools; `MCP.swift` defines 34 — 2026-11-02
- Severity: low (the count is the one number in the review table that would show an unmeasured tool had been added, and it is one behind).
- Where: `FEATURES.md:147`; `Sources/apprentice/MCP.swift:12-48`.
- Cause: `grep -c '^        tool("' Sources/apprentice/MCP.swift` is 34 — session, read, click, type, key, menu, scroll, browse, hover, open, wait_for, shot, ocr, route, focus, drag, upload, download, log, pending, resume, playbooks, learn, show, away, phone, policy, budget, choose, do, ask, confirm, approve, deny — while the MCP row says "33 tools". The row was updated for `approve`/`pending`/`resume`/`policy` but the number was not recounted.
- Suggested fix: say 34, or drop the number and let the tool list in `MCP.swift` be the record.

### F49 · README's exit-code table disagrees with SPEC and `usage()` on exits 2, 4 and 6 — 2026-11-02
- Severity: low (an agent reads whichever table it finds: exit 4 from a budget or a challenge looks like an allowlist refusal, and exit 6 from a kill switch looks like borrow mode, so the recovery it picks is the wrong one).
- Where: `README.md:147`, `:149`, `:151`; `SPEC.md:188-194`; `main.swift:84-86`.
- Cause: `SPEC.md:188` says the table is "kept in sync with `usage()` and `agent/*.md`", but the three copies differ. README's 2 is only "stale: the screen changed"; SPEC's 2 adds a page that changed without apprentice, where reading takes the new page in and actions are refused. README's 4 is "blocked by the allowlist or a rate limit"; SPEC's 4 and `usage()` also name a budget (`budget:`), a site cooling down (`soft block:`) and a challenge. README's 6 says "interrupted by the user or the kill switch"; SPEC's 6 says "interrupted by the user during borrow mode", though a kill-switch press now holds every later step with exit 6 (`Daemon.swift:5-10`, and `usage()`'s "6 interrupted" is silent on it).
- Suggested fix: make README's rows match SPEC, and add the kill switch to SPEC's exit-6 row, so the three tables say the same thing.

