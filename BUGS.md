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
