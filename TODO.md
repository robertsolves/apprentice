# TODO

## The VM

It runs: Debian guests under Tart (2 GB disk, 2 GB memory each) or on a server (`[vm] host`), any number at once (`APPRENTICE_VM`), driven from `Remote.swift` with the same commands as the Mac, uploads, downloads, `shot`, `ocr`, `show` and questions on the VM's screen included. Still open:

- **Working with the Mac off.** Asked for 2026-11-01: keep the settings in a server VM, synced with the Mac when it is on, so a Claude task, command or MCP server can drive the web while the Mac is off. Today the brain (approvals, budgets, pacing, logs) is the Mac's Swift daemon, so this needs it on Linux: either a Linux build of the parts that are not AppKit (`Remote`, `SiteRules`, `State`, `Config`, the wire), or a small daemon in the guest that speaks the same wire. Approvals would go to the chat (exit 9), since nobody is at a window.
- **Linux app sessions are untested on a live VM** (openbox, wmctrl and xfce4-terminal were added to provision.sh).
- A budgeted step is counted when it is approved, so an upload that then fails still uses up the site's budget (seen in testing: three failed tries reached the hourly cap). Count it once the step went through.
- Characters with no key on the guest's US layout get a spare keycode, so their `code` is unusual. The Mac does the same for characters its layout lacks (code 0).
- Several VMs share one ssh key. Per-VM keys would let one be revoked alone.

## Updates

- Fixes stay in each Mac's clone. To share them, point another Mac's `upstream` at this clone (any git URL works). If that turns out to be common, add `apprentice share`.

## Tests

`apprentice selftest` covers TOML, args, pace limits, the wire format, VM routing, `diff`, the approval gate, shared site limits and the automatic update (against throwaway git repos), in a temporary home of its own. Still to add: the VM's helper (`agent/vm/helper.py`) has no tests of its own; it is checked against a live VM by hand.

## Releases

- `release.yml` ships the binary unsigned until the `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`, `APPLE_ID`, `APPLE_APP_PASSWORD` and `APPLE_TEAM_ID` secrets are set (a Developer ID account).
- Installs update from `main`, not from tagged releases. Decide whether `install.sh` and `[update]` should follow the latest release tag instead, so users only get versions that passed the release run.
