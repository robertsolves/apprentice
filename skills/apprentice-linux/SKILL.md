---
name: apprentice-linux
description: How to work in apprentice's Linux VM - ssh for terminal work, Chromium and GTK/Qt apps on its own screen, key differences from the Mac, file dialogs, uploads and downloads between Mac and VM. Load with the apprentice skill when a session runs in the VM (vm on, --on linux, APPRENTICE_VM).
metadata:
  system: linux
---

# The Linux VM through apprentice

Load the `apprentice` skill first. The VM has its own screen, cursor and keyboard, so nothing done there moves the Mac's. The user watches with `apprentice vm look`, and `ask`/`confirm` windows open on the VM's screen.

## Terminal work is ssh
- `apprentice vm shell` prints the ssh config. Then run commands with plain `ssh` (apt, files, services) over the daemon's shared connection, as you would in your own shell.
- Use the screen only for what has no command: websites, and GUI apps with no CLI.
- `policy: ui-only` applies here too: no ssh then.

## Keys and navigation
- cmd in a combo is ctrl: `key cmd+l` sends ctrl+l. Back is `key alt+left`, forward is `key alt+right`.
- `session --app <name> --on linux` binds any Linux app. With `vm on`, a browser session is Chromium in the VM.
- Several VMs: `APPRENTICE_VM=<name>` or `apprentice --vm <name> …`. Budgets, cooldowns and site rules are shared across them, so two VMs don't double a site's allowance.

## Reading the screen
- Chromium reads like a Mac browser. GTK and Qt apps read as windows, and terminals read as their lines.
- Some menus and drawn widgets are missing from `read`: `ocr`, then `click --on "text"` or `click --at x,y`.
- The VM is slower than the Mac. After `ok · +0 -0 ~0`, `wait-for "text"` or `read` again before you try anything else.

## Files between Mac and VM
- `upload <id> <mac-path>` takes a file from the Mac into a page or dialog. `download <id> <mac-path>` brings one back: it clicks a link, or saves an image from its right-click menu.
- GTK file dialogs aren't in `read`; `upload` and `download` drive them. Return in the dialog's location box closes it without picking the file.

## When something needs the user
- `vm call "what"` asks them to check or do something on the VM's screen.
- Logins, CAPTCHAs, payments and identity checks are theirs, as on the Mac.
