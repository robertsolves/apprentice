# TODO

## The VM

It runs: Debian guests under Tart (2 GB disk, 2 GB memory each) or on a server (`[vm] host`), any number at once (`APPRENTICE_VM`), driven from `Remote.swift` with the same commands as the Mac, uploads, downloads, `shot`, `ocr`, `show` and questions on the VM's screen included. Still open:

- **Working with the Mac off.** Asked for 2026-11-01: keep the settings in a server VM, synced with the Mac when it is on, so a Claude task, command or MCP server can drive the web while the Mac is off. Today the brain (approvals, budgets, pacing, logs) is the Mac's Swift daemon, so this needs it on Linux: either a Linux build of the parts that are not AppKit (`Remote`, `SiteRules`, `State`, `Config`, the wire), or a small daemon in the guest that speaks the same wire. Approvals would go to the chat (exit 9), since nobody is at a window.
- **Linux app sessions are untested on a live VM** (openbox, wmctrl and xfce4-terminal were added to provision.sh).
- A budgeted step is counted when it is approved, so an upload that then fails still uses up the site's budget (seen in testing: three failed tries reached the hourly cap). Count it once the step went through.
- Characters with no key on the guest's US layout get a spare keycode, so their `code` is unusual. The Mac does the same for characters its layout lacks (code 0).
- Several VMs share one ssh key. Per-VM keys would let one be revoked alone.

## Install

- CI publishes a universal binary on `v*` tags; notarize it and have `install.sh` prefer it (falling back to building), so most users need no Swift toolchain. Today `install.sh` builds from source and needs the Xcode command-line tools.
- A first-run window (what apprentice is, the two grants with live check marks, a "try it on Finder" button) needs an app bundle. Until then `doctor --fix` is the interactive terminal checklist.

## Updates

- Fixes stay in each Mac's clone. To share them, point another Mac's `upstream` at this clone (any git URL works). If that turns out to be common, add `apprentice share`.

## Tests

`apprentice selftest` covers TOML, args, pace limits, the wire format, VM routing, `diff`, the approval gate, shared site limits and the automatic update (against throwaway git repos), in a temporary home of its own. Still to add: the VM's helper (`agent/vm/helper.py`) has no tests of its own; it is checked against a live VM by hand.

## Releases

- The site and README name Devin and Grok, which work through their shells, but `agent/connect.py` doesn't install the apprentice rules for them yet. Add them once their global rules locations are confirmed.
- `release.yml` ships the binary unsigned until the `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`, `APPLE_ID`, `APPLE_APP_PASSWORD` and `APPLE_TEAM_ID` secrets are set (a Developer ID account).
- Installs update from `main`, not from tagged releases. Decide whether `install.sh` and `[update]` should follow the latest release tag instead, so users only get versions that passed the release run.

## Production readiness follow-ups

- The start-up options window still runs on the command queue, inside the first `session`; only `ask`, `confirm`, `show`, `log` and `pending` moved off it.
- `restartWhenIdle` does not see a VM daemon's pending approval or a VM call in flight beyond the one-minute quiet window.
- `bug --fixed` was not added: fixed reports are deleted from `BUGS.md` and the commit is the record, so `pr` cites the `F<n>` the commit subjects name.
- MCP does not expose `sessions`, `do --explain` or `log --session` yet.
- Flows gained `sh:` steps; `learn` still drafts only screen steps, so a shell flow is written by hand.
