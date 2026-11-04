# apprentice — bug audit

## Field reports

Filed by `apprentice bug` while working. Each has a suggested fix to review; none is applied.

### F17 · The window asks for the login keychain password to read the GitHub sign-in on launch (suspected) — 2026-11-04
Seen after `kit.sh` on the merged build, on every launch until answered. The CLI and the app have the same designated requirement (`com.apprentice.app`, the same certificate), so a changed signature is not the obvious cause.
Cause: not confirmed. The item's access list may predate this signature or name one binary only.
Suggested fix: see whether "Always Allow" holds across a rebuild; if it does not, read the token only in the daemon, or recreate the item with an access list for the signing identity.
