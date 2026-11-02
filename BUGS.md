# apprentice — bug audit

## Field reports

Filed by `apprentice bug` while working. Each has a suggested fix to review; none is applied.

### F50 · A `--sh` schedule with `--vm` runs its command on this Mac, though the approval, `list` and `show` all say it runs in the VM — 2026-11-02
- Severity: high
- Where: Sources/apprentice/Schedules.swift:512-526 (`command(_:)`; the `.sh` arm at :524-525 returns `["/bin/zsh", "-lc", s.target]` and never reads `s.vm`), :666 (`describe` prints "VM <name>"), :772 (`add` stores `--vm` for every kind), :784 (the approval line, "in VM <name>")
- Cause: `command(_:)` prepends `--vm <name>` only for `.run` and `.flow`; the `.sh` arm returns `["/bin/zsh", "-lc", s.target]` and never reads `s.vm`. Setting `APPRENTICE_VM` in the child's environment does nothing to zsh, so the command runs on this Mac with the Mac's user, files and Keychain — the opposite of what the VM is for — while `describe` prints "VM <name>" and `add` asks the user to approve "in VM <name>".
- Suggested fix: run `.sh` inside the guest (`VM.shell`'s ssh command, `-lc <target>`, under the daemon's shared connection), or refuse `--vm` when the kind is `sh` and drop it from the usage line.

### F51 · Every save of `schedules.toml` adds a backslash to a prompt, name or target that holds `"` or `\`, and the prompt the agent gets is not the one the user wrote — 2026-11-02
- Severity: high
- Where: Sources/apprentice/Schedules.swift:123-129 (`q`), Sources/apprentice/Config.swift:41-47 (`Toml.unquote`)
- Cause: `q` writes TOML escapes (`\"`, `\\`), but `unquote` only strips the surrounding quotes and never unescapes, so each load returns a value that already carries the backslashes and the next `save` (`advance`, `tick`, `toggle`, `add`) escapes them again. Run with the real functions, `say "hi"` reads back as `say \"hi\"`, then `say \\\"hi\\\"`, then `say \\\\\\\"hi\\\\\\\"`; a `--sh 'printf "a\tb"'` doubles its `\t` on every run, so the file grows without bound and the escaping reaches the shell and the agent CLI as literal backslashes.
- Suggested fix: unescape `\\` and `\"` in `Toml.unquote` (and honour them in `stripComment`/`splitTop`), or stop escaping in `q` and refuse the characters instead.

### F52 · `schedule add --at <a past time>` is saved without an error and then never fires — 2026-11-02
- Severity: medium
- Where: Sources/apprentice/Schedules.swift:749-753 (`--at`), :776-777 (`next`/`base`), :218-219 (`baseNext`)
- Cause: `baseNext` returns `at` only when it is later than now, so `fireTime` is nil and the schedule is stored enabled with `next` and `base` both nil. `tick` recomputes the same nil every twenty seconds and `list` prints "next -": a typo such as `--at 2026-10-05T09:00:00` is accepted, approved by the user and then silently does nothing forever.
- Suggested fix: throw when `--at` is not in the future (saying the time has passed), or fire it once at once and keep the current behaviour for a real future time.

### F53 · FEATURES.md still says the MCP server has 34 tools; it registers 40 — 2026-11-02
- Severity: low
- Where: FEATURES.md:178, Sources/apprentice/MCP.swift (the tool list)
- Cause: the tool list grew after that row was written (`voice`, `pref`, `ask`, `confirm`, `schedule`, `drag`, `choose`, `budget`, `phone`); `grep -c 'tool("' Sources/apprentice/MCP.swift` is 40, and the row's "no …" list names twelve commands that are still absent, so the number is the only wrong part.
- Suggested fix: say 39, or drop the count and keep the list of what an agent cannot do.

### F54 · `away wait --timeout` accepts zero or a negative number and fails at once with a message that reads as nonsense — 2026-11-02
- Severity: low
- Where: Sources/apprentice/Away.swift:485-489
- Cause: `min(a.value("timeout").flatMap(Double.init) ?? 1200, 1440)` has no lower bound, so `--timeout -1` puts the deadline in the past and the first pass of the loop throws `away wait: you are still here after -1 s`; `--timeout 0` does the same. `wait-for` was clamped to 1…600 for exactly this reason.
- Suggested fix: clamp the value to 1…1440 (and say the cap in the message when it applies).

### F55 · A `type --secret password` step that fails after the approval is still counted as a sign-in, so the next attempt is refused as a repeat — 2026-11-02
- Severity: medium
- Where: Sources/apprentice/Login.swift:65-77 (`value`, `record` at :75), called at Sources/apprentice/Commands.swift:887 and Sources/apprentice/Remote.swift:630
- Cause: `value` writes the attempt to `logins.json` before returning the password, and the typing happens afterwards (Commands.swift:892-897 onward). If the field goes away, the kill switch fires or the step is interrupted, the attempt is already recorded: the next try inside `[login] gap_min` is refused with "a sign-in page this soon means that one failed or the site wants a person" though nothing was typed, and it also uses up one of `[login] per_day`.
- Suggested fix: record the sign-in once the characters are in the field (return a token from `value` and record after the typing), or drop a provisional entry when the step throws.

### F56 · `Layers.cache` is written from several queues with no lock, so a VM session's daemon can corrupt it or crash — 2026-11-02
- Severity: medium
- Where: Sources/apprentice/Layers.swift:27 (`cache`), :35-41 (`read`), :58 (`write`), reached from `Config.load` and `Prefs.load` on the command, schedule, away and main queues
- Cause: `cache` is a plain static dictionary mutated in place. `Layers.read` is reached through `Config.load`, which runs on the command queue, on the schedule timer's queue (`Schedules.tick`), on the away queue and on the main thread (the `Overlay` and `StatusItem` timers, `Voice.install`), and `Prefs.load` calls it from the command queue as well. Two of those meeting in the `.vm` branch — one reading while another writes — is a simultaneous mutation of a Swift Dictionary, which is undefined behaviour (typically `EXC_BAD_ACCESS`), and a stale write also hands one command another command's config.
- Suggested fix: put `cache` behind an `OSAllocatedUnfairLock`, as `Rand.state` does, or wrap it in a small locked store; read before taking the lock and store after the ssh.
### F58 · One queued `--host` task stops every later away task once `[away] host` is turned off — 2026-11-02
- Severity: low
- Where: Sources/apprentice/Away.swift:301-303 (`tick`)
- Cause: `tick` looks only at the oldest queued task; if that one is a host task while `hostAllowed` is false it returns before claiming anything, and the next tick picks the same task again. Everything queued behind it never starts and nothing is logged or shown to say why. `add` refuses such a task while the setting is off, so this needs `[away] host` turned off after the task was queued.
- Suggested fix: skip the task instead of returning — continue to the next queued one, and mark this one `.needsYou` with a note that `[away] host` is off.

### F59 · With login off, an ordinary "enter the code" page is recorded as a CAPTCHA and then refuses every action on that site — 2026-11-02
- Severity: medium
- Where: Sources/apprentice/SiteRules.swift:426-438 (`Challenge.find`, the fallback at :437), :440-452 (`start`), :472-474 (`stillThere`)
- Cause: `find` deliberately skips markers that are sign-in code prompts (`!Login.isCodePrompt(m)` at :429), and only treats one as a step of signing in when `Login.allowed` (:431-434). The fallback at :437 then searches `challengeMarkers` again without either filter, and it can only ever return the markers :429 rejected. `challengeMarkers` and `Login.codeMarkers` both hold "enter the code", so a page that merely says "Enter the code" returns that marker. With `[login] auto = false`, the default, `start` does not take its sign-in branch: it records a challenge for the domain and throws exit 4, and `stillThere` then refuses every later action there with "still shows a check only the user may complete" until the user runs `apprentice cool --clear`.
- Suggested fix: delete the :437 fallback (it is unreachable with a new answer), or apply the same `!Login.isCodePrompt` filter to it; a code prompt with login off should come back as a plain hint, and no challenge should be recorded.

### F60 · `wait-for` in the VM takes any timeout, while the same command on this Mac clamps it to 600 s — 2026-11-02
- Severity: low
- Where: Sources/apprentice/Remote+More.swift:244-250 (`waitFor`), against Sources/apprentice/Commands.swift:1370-1385 (the Mac's, clamped to 1...600) and Commands.swift:87-94 (`poll`)
- Cause: the VM's copy passes `a.value("timeout").flatMap(Double.init) ?? 10` straight into `poll(timeout:)`. In a VM session `wait-for "x" --timeout 5000` holds the daemon's command queue for over an hour, so every other command waits behind it, and `--timeout -1` answers "timeout: … not found in -1 s" after the single check `poll` makes when its deadline is already past. It is also unstoppable: the Mac's loop calls `Borrow.checkpoint()` every round (Commands.swift:1382), so the person can take the mouse or trip the kill switch, while the VM's runs through `poll`, which checks neither. The same flag behaves differently depending on which machine the session is on, and only the Mac's path is bounded.
- Suggested fix: share one parse — `min(max(timeout, 1), 600)` in both — and give `poll` a `Borrow.checkpoint()` each round, so the flag means the same thing on either machine and a long wait can still be stopped.

### F61 · A screen command with no arguments yields "the user is back" instead of its usage error — 2026-11-02
- Severity: low
- Where: Sources/apprentice/Commands.swift:360 (the gate at the top of the daemon's dispatch), Sources/apprentice/Away.swift:343-345 (`yieldIfPresent`), Sources/apprentice/Commands.swift:431 (`hover`, whose own guard is never reached)
- Cause: with away mode on and the person at the Mac, `apprentice hover`, `do`, `download`, `browse` and `session` with no arguments at all each exit 10 with "yielded: the user is back at the Mac. Nothing was done; do not retry. Wait with `apprentice away wait`", while `replay`, `run`, `bug` and `confirm` with no arguments answer their usage line and exit 5. The gate throws at the top of dispatch, before the command is called at all, so a missing argument — which `hover` would report as `Fail(5, "hover <id>")` — is dressed up as "the user is back, do not retry", and an agent follows that advice: it waits for the user to leave instead of fixing its own command. Reproduced from the built binary, away mode on and the user present.
- Suggested fix: parse first, yield last — let each command run its argument checks and call `yieldIfPresent`/`prepare()` only when it is about to touch the screen, as `hover` already does one line later.

### F62 · A `sh:` flow step whose child keeps stdout open outlives `sh_timeout_s` and wedges the daemon — 2026-11-02
- Severity: medium
- Where: Sources/apprentice/Flows.swift:139-155 (`runShell`), the timeout at :149-150 and the blocking read at :151
- Cause: the `[flow] sh_timeout_s` cap only calls `proc.terminate()` on `/bin/zsh`, and the pipe is read to EOF before `waitUntilExit()`. Any step whose shell starts a child that inherits stdout (`sh: yes`, or a tool left running in the background) keeps the write end open after the shell itself dies, so `readDataToEndOfFile()` never returns and no timeout can fire: verified in isolation, the shell exited with rc -15 while its child kept running and the pipe still delivered bytes. Nothing in `runFlow` checks `KillSwitch` or `Borrow` inside a shell step either, and `dispatch` runs on the daemon's command queue, so every later command queues behind that step until the daemon is restarted.
- Suggested fix: put the child in its own process group, signal the whole group at the timeout, and bound the read (a deadline, or read only after `waitUntilExit` with the pipe drained on a thread), so a child that outlives the shell cannot hold `runShell` open.

### F64 · Unvalidated numeric config keys silently break features: `ask_window_s` closes every question window, `[login] per_day = 0` refuses every sign-in — 2026-11-02
- Severity: low
- Where: Sources/apprentice/Config.swift:645-649, Sources/apprentice/Ask.swift:21-23 (`windowTime`) and :158 (the timer), Sources/apprentice/Login.swift:115-124 (`paced`)
- Cause: the key is read with `Double(...)` and stored with no validation at all, unlike the keys around it (`[app] font_size` takes only 8…32, `[flow] sh_timeout_s` only 1…3600, `[run] max_minutes` only above 0). `Ask.windowTime` then returns `min(requested, askWindowSeconds)`, so `ask_window_s = 0` or `-5` arms `Timer(timeInterval: timeout)` with zero or a negative interval: every `ask`, `show` and `confirm` window aborts before it is drawn and the caller is told the user did not answer, while the config gives no hint that the value is nonsense. `--timeout` is clamped only by that same value, so the caller cannot recover. `[login] gap_min` and `per_day` are stored the same unchecked way: `per_day = 0` makes `Login.paced` refuse every sign-in at once (`tries.count >= 0` is always true, reported as "signed into 0 times today"), and a negative `gap_min` removes the wait that keeps two sign-ins on one site minutes apart, which is the pacing that guards the account. Both neighbours in `PaceConfig` are clamped instead (`sanitized()` orders every pair and falls back to the default), so the fix is the same shape.
- Suggested fix: validate all three like their neighbours: `ask_window_s` finite and above 0 (keeping the 60 s default otherwise), `per_day` at least 1 and `gap_min` at least 0, so a typo cannot silently switch questions off or drop the wait between sign-ins.

### F65 · `uninstall --keep-vms` keeps the VMs' ssh key but deletes the only record of where they are — 2026-11-02
- Severity: medium
- Where: Sources/apprentice/Doctor.swift:173-180 (the plan and `kept`) and :206-213 (the per-item loop and the `Store.dir` removal), Sources/apprentice/VM.swift:19-21 (the shared `vm/` folder holds only the key and known hosts), :25-29 (`settings`), :46 (`host`), :288-296 (the inventory)
- Cause: `--keep-vms` exempts `vm/` and `vms/` from the removal loop and skips removing `Store.dir` itself, and the plan it prints says "vm/ and vms/ (the VMs stay)", as if a new install picks them up again. But a VM's place is not kept there: `VM.settings` reads `host`, `port`, `user` and `password` from the `[vm]` and `[vm.<name>]` tables of `config.toml` (the file the same loop deletes), and `vm/` holds only `id_ed25519` and `known_hosts`. After this uninstall a VM in the cloud is unreachable — `VM.host` returns nil, so it is taken for a local Tart machine named `apprentice-browser` and ssh goes to the wrong place — and `vm list` no longer shows its name at all, because that list is Tart's VMs plus the `vm.*` sections that were just removed. The kept key survives with nothing left to connect to, so the one case where keeping the VMs matters is the case that breaks.
- Suggested fix: before deleting, copy the `[vm]` and `[vm.*]` tables into `vm/config.toml` (or exempt `config.toml` and strip its other sections), and let `VM.settings` fall back to that copy, so a kept VM keeps its host, port and user.

### F66 · Two VM names that share a tunnel port make `vm look` show the other VM's screen — 2026-11-02
- Severity: low
- Where: Sources/apprentice/VM.swift:99-110 (`openViewer`, the port at :102)
- Cause: the tunnel port is `5959 + hash(name) % 40`, and when ssh refuses the forward (`ExitOnForwardFailure=yes`) the code accepts any listener on that port as "the tunnel from an earlier `look`" and opens `vnc://…:127.0.0.1:port` anyway. Forty buckets collide easily: the default VM's name hashes to 5963 and `vm38` hashes to the same one, so `vm look vm38` opens Screen Sharing onto the default VM's screen while the caller is told it is looking at `vm38` — the very mix-up the comment on line 101 says cannot happen. Whichever VM started its tunnel first keeps the port until it is closed.
- Suggested fix: prove the listener is this VM's before reusing it (record the tunnel's pid per VM, or clear a stale tunnel and retry the forward on the next free port), and treat "port busy" as an error rather than as success.

### F67 · The Settings screen writes a font size its own file rejects, and the terminal ignores it silently — 2026-11-02
- Severity: low
- Where: Sources/apprentice/AppForms.swift:52 (the `font_size` setting), :66-72 (`literal`), :76-95 (`IntField`), Sources/apprentice/AppUI.swift:1719 (`SettingsView`), Sources/apprentice/Config.swift:652
- Cause: `font_size` is declared `kind: .number(8...32)`, but only the `Stepper` is limited to that range; the `TextField` bound to the same `Int` takes any whole number, and `literal` writes it unclamped (`String(Int(shown) ?? …)`). `Config` then keeps the default because the value is outside 8…32, so typing `100` leaves the window showing `100`, the file holding `100`, and the terminal at 12, with no warning — the screen reports a setting that does nothing, and reopening it keeps reporting it because the file is read back as written.
- Suggested fix: clamp to the declared range wherever a `.number` value is written (in `literal` or in `write`), so the field cannot hold or save a value the config will throw away.

### F68 · Turning the Dock icon off or on does nothing until the daemon restarts — 2026-11-02
- Severity: low
- Where: Sources/apprentice/StatusItem.swift:141-155 (`watch` calls `apply`; `apply` returns early when the setting is off), Sources/apprentice/AppUI.swift:1719 (`SettingsView`, whose save never calls it)
- Cause: the activation policy is chosen once when the daemon starts, and after that `DockIcon.apply()` runs only when a window's app launches or terminates. Saving `[agent] dock_icon` from the Settings screen writes the file and reloads the config, but nothing calls `apply()`, and `apply()` itself begins with `guard Config.current.dockIcon else { return }`. So turning the icon on shows nothing until a window is opened or closed, and turning it off leaves the daemon at `.regular` and the icon in the Dock until the daemon restarts — the toggle reports a change the running app never makes.
- Suggested fix: call `DockIcon.apply()` from the config reload (or observe config.toml) and let `apply()` set the policy from the current setting in both directions instead of returning early when it is off.

### F69 · One signal during a reply truncates it, so a command that ran reports "bad reply from daemon" — 2026-11-02
- Severity: low
- Where: Sources/apprentice/Wire.swift:109-118 (`Wire.writeAll`), against :95-107 (`Wire.readAll`)
- Cause: `readAll` retries when `read` returns -1 with `EINTR` (the comment cites B20), but `writeAll` leaves its loop on any `n <= 0`, `EINTR` included. A reply is written in socket-sized chunks and the daemon runs child processes constantly, so a `SIGCHLD` delivered mid-write returns -1 and the rest of the JSON is never sent; the caller decodes a truncated reply and fails with "bad reply from daemon" (exit 5). For a state-changing command the work has already happened, so the caller is told it failed when it did not.
- Suggested fix: continue the loop when `n < 0 && errno == EINTR`, as `readAll` already does, and break only on other errors or zero.

### F70 · Two VM daemons appending to one `steps.jsonl` overwrite each other's rows — 2026-11-02
- Severity: low
- Where: Sources/apprentice/State.swift:129-141 (`appendLine`), with the sharing note at :35-37
- Cause: `log` serialises writers with an in-process `NSLock`, but `steps.jsonl` is not in `Store.perSession`, so the Mac's daemon and each `vms/<name>` daemon open the same file (the comment says logs are shared by all of them). `appendLine` opens it without `O_APPEND`, seeks to the end and writes, so two processes that seek before either writes land on the same offset and the later write replaces the earlier process's rows; `readLines` then drops the damaged line without a word. `grow`, `bug` and the run's own history lose rows whenever two VMs are worked at once, and `Store.locked` — used for `limits.json` for exactly this reason — is not used here.
- Suggested fix: append with `O_APPEND` so each row lands at the current end atomically, or wrap the append in `Store.locked`.

### F71 · A malformed `--at` is accepted and clicks a point the caller never gave — 2026-11-02
- Severity: low
- Where: Sources/apprentice/Commands.swift:1066-1070 (`screenPoint`)
- Cause: `raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }` drops every component that is not a number, and the guard only counts what survived. `--at "100,,200"` and `--at "100,oops,200"` each leave two parts and are read as `(100, 200)`, so a typo or a missing coordinate moves the click to a point the caller never named instead of failing with the usage error. The `parts.count == 2` guard looks like it validates both coordinates, but a dropped part never reaches it.
- Suggested fix: split and require exactly two parts that each parse — map to `Double?` and throw the usage error on any nil — instead of `compactMap`, which hides the bad component.

### F72 · `project save` commits a bigger repo's unrelated changes — 2026-11-02
- Severity: medium
- Where: Sources/apprentice/Projects.swift:212-225 (`Projects.save`: `git add -A` at :219, the commit at :223)
- Cause: `save` only checks that the folder is inside *some* work tree (`rev-parse --is-inside-work-tree`) and never that it is that tree's root. Since Git 2.0, `git add -A` without a path stages the whole working tree rather than the current directory, so saving a project that lives in `~/dev/monorepo/apps/thing` stages every change in the monorepo and commits them all with "Save <name> · <stamp>" — including work in progress staged for something else. Nothing in the output says other folders were swept in.
- Suggested fix: stage with a pathspec limited to the project (`git add -A -- .`) and commit that, or refuse when `rev-parse --show-toplevel` is not the project folder and tell the user which repo it would commit into.

### F73 · `project new --from` overwrites the cloned project's own settings — 2026-11-02
- Severity: medium
- Where: Sources/apprentice/Projects.swift:91-99 (`scaffold` writes `.apprentice/project.toml` with no existence check), reached from :192-201 (`new` with `--from`), against the promise at :6
- Cause: `scaffold` creates the folders and then writes `[project]` `name`, `agent` and `vm` over `settingsFile` every time, while the `.apprentice/.gitignore`, `AGENTS.md` and `CLAUDE.md` it writes a few lines later are each kept when present. Cloning a project that was saved with `project save --push` therefore replaces its name with the new one, resets its agent to the `--agent` default (`claude`), and drops `vm = …` entirely when no `--vm` is passed — so the folder the type comment says can be cloned back on another Mac comes back as a Mac project with the wrong agent.
- Suggested fix: write the settings file only when it is missing, as the other scaffolded files do, or merge just the missing keys into the existing `[project]` table instead of replacing it.

### F74 · Re-adding a schedule under the same name drops its VM, folder, model and site — 2026-11-02
- Severity: medium
- Where: Sources/apprentice/Schedules.swift:746-777 (`add`, which also serves `set`), the resets at :769-774
- Cause: `add` looks the schedule up by its slugified name and starts from the stored one (`s = old`, keeping `created` and `lastRun`, so the call is plainly an update), then assigns `agent`, `jitter`, `site`, `dir`, `vm` and `model` from the flags unconditionally. A re-add that repeats only the trigger and the kind therefore writes `dir = nil`, `vm = nil`, `model = nil` and `site = nil` back and resets `jitter` to 15 — `schedule set "Nightly" --daily 10:00 --sh "./x.sh"` turns a schedule that ran in VM `shop` inside `~/x` into one that runs on the Mac, in the daemon's working directory, and the "added …" line says nothing about the other changes.
- Suggested fix: for an existing schedule keep the stored value unless that flag is given (`a.value("dir") ?? s.dir`, and `old.jitter` as the `jitter` default), so a `set` changes only what it names.

### F75 · A pipeline whose file name is not already a slug gets a ref that no command accepts — 2026-11-02
- Severity: low
- Where: Sources/apprentice/Pipelines.swift:49-54 (`slug`/`ref` take the raw file stem) against :158-165 (`find`)
- Cause: `slug` is `url.deletingPathExtension().lastPathComponent` verbatim, so a hand-written `pipelines/Morning round.md` — the case the header says is allowed, a pipeline being one Markdown file a person can edit anywhere — has the ref `shop/Morning round`. `find` compares its input lowercased against `ref`, against `slug(ref)` (which is slugified) and against the front-matter name, and the capital in the stem matches none of them, so `pipeline run shop/Morning round`, copied verbatim from `pipeline list`, exits 5 with "no pipeline". When the file's front-matter `name` also differs from its stem, nothing matches at all, so that pipeline cannot be run, added to or removed by any argument, though `list` and `show` keep listing it.
- Suggested fix: compare both sides through `Playbooks.slugify`, or build `ref` from the slugified stem so the ref that is printed is the ref `find` resolves.

### F76 · The Sites screen's percentage slider keeps the value it was built with, so Reset leaves the old number on screen and the next drag saves it again — 2026-11-02
- Severity: medium
- Where: Sources/apprentice/AppSites.swift:401-403 (the `percent` control), :462-486 (`PercentSlider`), the Reset button at :303
- Cause: `PercentSlider` copies the value it is given into `@State private var shown` once, in `init` (`:466-473`), and `SiteDetail` rebuilds the same `SiteFieldRow` in the same position, so SwiftUI keeps that state. After Reset writes nil and `load()` reads the usual value back, the slider and its percentage still show the site's old number, and the next drag commits that number as the site's own again.
- Suggested fix: Give the control an identity that changes with the value (`.id(value)` on the slider, or the literal in the row's id), or pass a `Binding` in and update `shown` in `.onChange(of: value)`.

### F77 · A run that ends with `done` on a website leaves two learned flows for the same work — 2026-11-02
- Severity: low
- Where: Sources/apprentice/AgentLoop.swift:100-104 (`run` learns on done), Sources/apprentice/Skills.swift:168-176 (`learnFromEnded`), :192-213 (`draftFlow`), Sources/apprentice/Sessions.swift:178-181
- Cause: Two paths learn from one session and name it differently: `run` calls `Playbooks.learn` (`:404`), which slugs the flow from the app and the task ("Safari buy the socks"), and when the session is archived `Skills.learnFromEnded` drafts the same steps again (`:199-200`), slugged from the host ("example.com buy the socks"). `draftFlow` only refuses when its own file already exists (`:204`), so for a web session, where the host and the app differ, both drafts are written and the Skills screen shows the work twice.
- Suggested fix: Have `draftFlow` skip a session that already holds a `learn` row, or that has a learned flow with the same task, and name its draft the way `learn` does (`session.app`, not the host).

### F78 · A website typed with a path is accepted and then never applies to the site it names — 2026-11-02
- Severity: low
- Where: Sources/apprentice/SiteSettings.swift:266-274 (`add`, guard at :268), Sources/apprentice/Config.swift:734-737 (`PaceStyles.key`), agent/site-settings.toml:60 (the field asks for `example.com`)
- Cause: The guard only refuses a name with no dot or with a space, so `example.com/settings`, pasted from a browser's address bar, passes. `PaceStyles.key` looks for a scheme to take a host from, finds none, and keeps the raw string, so `[pace."example.com/settings"]` and a `budgets.json` key of the same shape are written. `Site.matches` compares whole host labels, so neither ever matches the `example.com` the commands see: the entry sits in the Sites list with a globe and the site keeps its built-in pace and caps.
- Suggested fix: Take the host of whatever is typed: reject a name holding `/`, `#` or `?`, or run it through `URL(string: "https://" + raw)` and keep the host, refusing when there is none.

### F79 · Learning one fact about a site throws away everything else in that site's learned skill — 2026-11-02
- Severity: medium
- Where: Sources/apprentice/Skills.swift:101-131 (`addFact`: the template at :113-127, the write at :128-129), :134-137 (`existingFacts`), Sources/apprentice/AppSkills.swift:207-220 (the window saves the whole text a person edited)
- Cause: `addFact` keeps only `existingFacts(url)` — the bullets under `## Key facts` — and writes a new document over the file: front matter rebuilt from `scope`, `match`, `status` and `updated`, a `# match` title, then the facts. Every other section and every other front-matter key goes with it. The Skills screen invites editing a learned skill ("Tidy it, or forget it"), so a person who tidies one, or an agent that adds `system:` or `tags:` by hand, loses all of it the next time any agent runs `learn --fact "…" --for <that site>`.
- Suggested fix: Edit in place instead: replace the `## Key facts` block inside the existing text (as `Voice.setting` does for its own section) and leave the front matter's other keys and every other section as they are.

### F80 · Making your own copy of a judgement skill writes a file nothing reads, and the list then shows the skill twice — 2026-11-02
- Severity: low
- Where: Sources/apprentice/AppSkills.swift:222-232 (`copy`), :16-25 (`SkillItem.load` marks every judgement skill `builtIn`), :201 (the promise the editor makes), Sources/apprentice/Skills.swift:48 (`roots`), Sources/apprentice/Playbooks.swift:130-146 (`skillsDir` and `skills()`)
- Cause: Judgement skills are read from the clone's `skills/<name>/SKILL.md` (`Playbooks.skillsDir`), and that folder is not one of `Skills.roots` — the roots are `~/.apprentice/skills/{yours,learned}` and the playbooks folder. So the copy `copy()` writes to `~/.apprentice/skills/yours/<name>/SKILL.md` is never consulted by `skills(host:system:)`, `hintLines` or `search`: agents still get the built-in one, though the editor says "your copy is used instead of this one". The window also lists the copy as a separate `yours` playbook beside the built-in it came from, since `SkillItem.load` tags every file from `skillsDir` as built-in by path, so the same skill appears twice.
- Suggested fix: Read judgement skills from `yours`, then `learned`, then the clone's `skills/`, so a copy shadows the built-in as a flow's does, and list each skill once, from wherever it won.

