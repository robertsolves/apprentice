# apprentice — bug audit

## Field reports

Filed by `apprentice bug` while working. Each has a suggested fix to review; none is applied.

### F50 · A `--sh` schedule with `--vm` runs its command on this Mac, though the approval, `list` and `show` all say it runs in the VM — 2026-11-02
- Severity: high
- Where: Sources/apprentice/Schedules.swift:497-519 (`command(_:)`), :546, :658 (`describe`), :774 (the approval line), :762 (`add` takes `--vm` for every kind)
- Cause: `command(_:)` prepends `--vm <name>` only for `.run` and `.flow`; the `.sh` arm returns `["/bin/zsh", "-lc", s.target]` and never reads `s.vm`. Setting `APPRENTICE_VM` in the child's environment does nothing to zsh, so the command runs on this Mac with the Mac's user, files and Keychain — the opposite of what the VM is for — while `describe` prints "VM <name>" and `add` asks the user to approve "in VM <name>".
- Suggested fix: run `.sh` inside the guest (`VM.shell`'s ssh command, `-lc <target>`, under the daemon's shared connection), or refuse `--vm` when the kind is `sh` and drop it from the usage line.

### F51 · Every save of `schedules.toml` adds a backslash to a prompt, name or target that holds `"` or `\`, and the prompt the agent gets is not the one the user wrote — 2026-11-02
- Severity: high
- Where: Sources/apprentice/Schedules.swift:122-128 (`q`), Sources/apprentice/Config.swift:41-47 (`Toml.unquote`)
- Cause: `q` writes TOML escapes (`\"`, `\\`), but `unquote` only strips the surrounding quotes and never unescapes, so each load returns a value that already carries the backslashes and the next `save` (`advance`, `tick`, `toggle`, `add`) escapes them again. Run with the real functions, `say "hi"` reads back as `say \"hi\"`, then `say \\\"hi\\\"`, then `say \\\\\\\"hi\\\\\\\"`; a `--sh 'printf "a\tb"'` doubles its `\t` on every run, so the file grows without bound and the escaping reaches the shell and the agent CLI as literal backslashes.
- Suggested fix: unescape `\\` and `\"` in `Toml.unquote` (and honour them in `stripComment`/`splitTop`), or stop escaping in `q` and refuse the characters instead.

### F52 · `schedule add --at <a past time>` is saved without an error and then never fires — 2026-11-02
- Severity: medium
- Where: Sources/apprentice/Schedules.swift:739-743 (`--at`), :766-767 (`next`/`base`), :217-218 (`baseNext`)
- Cause: `baseNext` returns `at` only when it is later than now, so `fireTime` is nil and the schedule is stored enabled with `next` and `base` both nil. `tick` recomputes the same nil every twenty seconds and `list` prints "next -": a typo such as `--at 2026-10-05T09:00:00` is accepted, approved by the user and then silently does nothing forever.
- Suggested fix: throw when `--at` is not in the future (saying the time has passed), or fire it once at once and keep the current behaviour for a real future time.

### F53 · FEATURES.md still says the MCP server has 34 tools; it registers 39 — 2026-11-02
- Severity: low
- Where: FEATURES.md:175, Sources/apprentice/MCP.swift:12-67
- Cause: the tool list grew after that row was written (`voice`, `pref`, `ask`, `confirm`, `schedule`, `drag`, `choose`, `budget`, `phone`); `grep -c 'tool("' Sources/apprentice/MCP.swift` is 39, and the row's "no …" list names twelve commands that are still absent, so the number is the only wrong part.
- Suggested fix: say 39, or drop the count and keep the list of what an agent cannot do.

### F54 · `away wait --timeout` accepts zero or a negative number and fails at once with a message that reads as nonsense — 2026-11-02
- Severity: low
- Where: Sources/apprentice/Away.swift:483-495
- Cause: `min(a.value("timeout").flatMap(Double.init) ?? 1200, 1440)` has no lower bound, so `--timeout -1` puts the deadline in the past and the first pass of the loop throws `away wait: you are still here after -1 s`; `--timeout 0` does the same. `wait-for` was clamped to 1…600 for exactly this reason.
- Suggested fix: clamp the value to 1…1440 (and say the cap in the message when it applies).

### F55 · A `type --secret password` step that fails after the approval is still counted as a sign-in, so the next attempt is refused as a repeat — 2026-11-02
- Severity: medium
- Where: Sources/apprentice/Login.swift:65-77 (`value`, `record` at :75), :115-124 (`paced`), called at Sources/apprentice/Commands.swift:885 and Sources/apprentice/Remote.swift:630
- Cause: `value` writes the attempt to `logins.json` before returning the password, and the typing happens afterwards (Commands.swift:892-897 onward). If the field goes away, the kill switch fires or the step is interrupted, the attempt is already recorded: the next try inside `[login] gap_min` is refused with "a sign-in page this soon means that one failed or the site wants a person" though nothing was typed, and it also uses up one of `[login] per_day`.
- Suggested fix: record the sign-in once the characters are in the field (return a token from `value` and record after the typing), or drop a provisional entry when the step throws.

### F56 · `Layers.cache` is written from several queues with no lock, so a VM session's daemon can corrupt it or crash — 2026-11-02
- Severity: medium
- Where: Sources/apprentice/Layers.swift:27 (`cache`), :35-41 (`read`), :58 (`write`); reached from Sources/apprentice/Config.swift:591 (`Config.load` → `Layers.config`) and Sources/apprentice/Prefs.swift:26
- Cause: `cache` is a plain static dictionary mutated in place. `Layers.read` is reached through `Config.load`, which runs on the command queue, on the schedule timer's queue (`Schedules.tick`), on the away queue and on the main thread (the `Overlay` and `StatusItem` timers, `Voice.install`), and `Prefs.load` calls it from the command queue as well. Two of those meeting in the `.vm` branch — one reading while another writes — is a simultaneous mutation of a Swift Dictionary, which is undefined behaviour (typically `EXC_BAD_ACCESS`), and a stale write also hands one command another command's config.
- Suggested fix: put `cache` behind an `OSAllocatedUnfairLock`, as `Rand.state` does, or wrap it in a small locked store; read before taking the lock and store after the ssh.

### F57 · `account status` says "GitHub refused the token" when the refresh could not be sent at all — 2026-11-02
- Severity: low
- Where: Sources/apprentice/Account.swift:263-268 (`verify`), :129-134 (`status`)
- Cause: `verify()` returns `false` whenever `token()` is nil, but `token()` is nil for three different reasons: no Keychain item, a refresh token that ran out, and a refresh POST that failed (offline, timeout, a GitHub 5xx). `status` prints the `false` case as "GitHub refused the token: `apprentice account login`", so an offline Mac tells the user their sign-in was rejected and to do it again, when nothing was checked.
- Suggested fix: have `verify()` return nil (not false) when `token()` failed on the refresh call rather than on a missing or expired credential, so `status` says "GitHub did not answer" as it already does for a failed request.

### F58 · One queued `--host` task stops every later away task once `[away] host` is turned off — 2026-11-02
- Severity: low
- Where: Sources/apprentice/Away.swift:287-303 (`tick`, the `:301` guard)
- Cause: `tick` looks only at the oldest queued task; if that one is a host task while `hostAllowed` is false it returns before claiming anything, and the next tick picks the same task again. Everything queued behind it never starts and nothing is logged or shown to say why. `add` refuses such a task while the setting is off, so this needs `[away] host` turned off after the task was queued.
- Suggested fix: skip the task instead of returning — continue to the next queued one, and mark this one `.needsYou` with a note that `[away] host` is off.
