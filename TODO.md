# TODO

## Browser VM

- **Run it for real.** It has never been through `vm setup`. This Mac has 23 GB free and the VM needs about 35 GB (or set `[vm] home` to an external disk). Things to check: the ssh key install through `SSH_ASKPASS`, the guest LaunchAgent coming up in the login session, Screen Sharing for `vm look`, `systemsetup` setting the time zone, and the host-signed binary keeping its grants in the guest.
- Tart's Homebrew tap formula fails on current Homebrew (`depends_on macos:` outside `on_macos`). `vm setup` falls back to the release app in `~/Applications`.
- A VM session skips the start-up options window. Show it on the host, then pass the choices to the guest.
- The guest keeps the image's `admin`/`admin` password. `vm setup` could change it once the ssh key is in.
- `vm install` restarts the guest daemon, so a command in flight from the host fails with "daemon closed the connection". Wait for the guest to be idle first.

## Updates

- Fixes stay in each Mac's clone. To share them, point another Mac's `upstream` at this clone (any git URL works). If that turns out to be common, add `apprentice share`.

## Tests

`apprentice selftest` covers TOML, args, pace limits, the wire format, VM routing and `diff`. Still to add:

- Approvals: propose → exit 8 → approve re-dispatches once; a stale token fails. This needs `Store` pointed at a temp folder.
- `Repo.applyUpdate` against a temp git repo with a fake upstream: clean tree, dirty tree, conflict, failed build.
- The routing checks only count when they fail. Make every check count.
