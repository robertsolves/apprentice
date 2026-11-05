# apprentice — bug audit

## Field reports

Filed by `apprentice bug` while working. Each has a suggested fix to review; none is applied.

### F17 · The window asks for the login keychain password to read the GitHub sign-in on launch (suspected) — 2026-11-04
Seen after `kit.sh` on the merged build. It came back after the next rebuild even though it had been answered, so each install asks again (whether "Always Allow" lasts across a rebuild is still untested). The CLI and the app have the same designated requirement (`com.apprentice.app`, the same certificate), so a changed signature is not the obvious cause.
Cause: not confirmed. The item's access list may predate this signature or name one binary only.
Suggested fix: see whether "Always Allow" holds across a rebuild; if it does not, read the token only in the daemon, or recreate the item with an access list for the signing identity.

### F18 · One session is archived and committed again by each later `session` call (suspected) — 2026-11-04
Seen as three identical commits, "Session 2026-11-04-ec6f31: 57 steps on System Settings", after two `session` calls refused because the VM was off, then one that worked.
Cause: not confirmed. `Sessions.archiveCurrent` may run before the new session is known to have started, and commit again each time.
Suggested fix: archive only once a new session has really begun, or skip the commit when the copy has not changed.

### F19 · Typing an emoji from a clipboard of promises recurses until the daemon crashes — 2026-11-05
Confirmed by reading the code: `Keys.paste` (`Input.swift`) returns `type(text, fast: true)` when the clipboard holds items but none can be read (file promises, a Continuity item), and `Keys.typeChar` pastes any character the layout cannot type (an emoji, CJK) by calling `Keys.paste` again with the same clipboard. Each call starts the other, so the stack overflows: the daemon dies, and the command that was typing never returns.
Cause: the fallback in `paste` is not a fallback the way `type` needs it; `type` sends untypeable characters back to `paste`.
Suggested fix: give `paste` a `pasting: Bool`/`force` flag (or a private `pasteNow`) so the type path can clear the clipboard, put the character in, paste it and restore nothing; type a character it still cannot place fails with exit 5 instead of recursing. Add a selftest with a stub pasteboard.

### F20 · Approving a proposal drops the project it came from, so the project's caps are skipped — 2026-11-05
Confirmed by reading the code: `Approvals.Pending` (`State.swift`) keeps `cmd`, `args` and `tab`, not the project, and `Commands.approve` re-dispatches `Request(cmd: p.cmd, args: p.args)`. The daemon takes `Project.dir` from that request, which is the approver's folder. Approving from the window or the menu bar (the app runs with no project folder) therefore runs the step with `Project.dir = nil`, so `Budgets.check` (`SiteRules.swift`) applies neither the project's `budgets.json` caps nor its `limits.json` counts. A step the project's tighter cap would refuse is let through, and the project's activity is not recorded.
Cause: the pending proposal does not carry the context it was made in; only the re-dispatched arguments survive.
Suggested fix: store `project` (and `model` and `step`, for the log row and screen ownership) in `Pending` when `Approvals.check` saves it, and set them on the request `Commands.approve` dispatches. Add a selftest: propose a budgeted step inside a project whose cap is 1, approve it from outside the project, and the second action is refused.

### F21 · `selftest` is flaky: two checks failed once and passed on the next run (suspected) — 2026-11-05
Seen on one run: `2 of 849 checks failed`, `SelfTestPipelines.swift:938` ("use: shell runs only the step's own line", got exit 9 — a first-shell question — although `NamedAgents.approveShell` had just saved the approval) and `SelfTestPipelines.swift:812` ("install in a VM: a VM that is down says so, and it does not run here instead", got exit 0, so the install may have run on this Mac). The same binary then passed all 849 checks, so neither is a deterministic code path.
Cause: not confirmed. The shell-approval key is built from the project path, and the test's project lives under `NSTemporaryDirectory()` (which can resolve a path two ways); the VM-down check may consult live host state rather than the configured VM's own.
Suggested fix: reproduce by running the two checks in a loop and printing the run's home and `approvals.json`; canonicalize the folder in `NamedAgents.shellKey` and make `Projects.inVM`'s "not running" decision rest on the VM's own state. `kit.sh` runs this suite before installing, so a flake there either blocks an install or hides a real failure.

### F22 · `Mouse.fresh` can spin forever once its ring reaches 6 (suspected) — 2026-11-05
`Mouse.fresh` (`Input.swift`) redraws a point while it is one a recent rest used, but only grows `ring` half the time; with `ring == 6` it stays 6 and loops. On a small control clicked over and over (a pagination arrow), enough of its nearby pixels can be in `Rest` that every draw is a hit, and the command never gets to click.
Cause: `while Rest.seen(at), ring <= 6` has no attempt bound, and `ring` is not guaranteed to advance.
Suggested fix: try a fixed number of rings (1...6) and, if all are taken, return the original point (or widen the ring) after a bounded number of draws; never loop on the predicate alone.
