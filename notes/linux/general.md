---
scope: system
system: linux
match: *
tags: vm, linux, input, cursor, keyboard, dialog, upload, download, no change
lang: any
verified: 2026-11-01, Debian 13 VM, Chromium
status: verified
---
# Any app in the Linux VM

## Key facts
- The VM has its own screen, cursor and keyboard: actions there never move this Mac's. The user sees it with `apprentice vm look`; questions open on the VM's screen.
- cmd in a combo is ctrl there (cmd+a, cmd+l); back is `key alt+left`, forward `key alt+right`.
- `ok · +0 -0 ~0` means nothing visible changed. A slow site may still be loading: `wait-for "text"` or `read` again before retrying.
- `upload <id> <path>` takes a file from this Mac; `download <id> <path>` brings one back (a link is clicked, an image is saved from its right-click menu).
- Text the list leaves out (some menus, drawn widgets): `ocr`, then `click --on "text"` or `click --at x,y`.

## Works
- File dialogs are GTK's, and are not in `read`: `upload` and `download` drive them on their own.
- Right-click menus may be missing from `read`; `ocr` reads them.

## Fails
- Return in a GTK file dialog's location box closes it without picking the file; `upload` clicks the dialog's button instead.
