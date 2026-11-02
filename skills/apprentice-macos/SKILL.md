---
name: apprentice-macos
description: How to get things done in macOS apps through apprentice - shell first, menus and shortcuts, save and open panels, Finder, System Settings, permission prompts, and what to do when a click changes nothing. Load with the apprentice skill before working in a Mac app.
metadata:
  system: macos
---

# macOS apps through apprentice

Load the `apprentice` skill first. For one app's current labels and steps, see `apprentice playbooks "<app>"`; `session` prints the key facts.

## Shell first
When the `policy:` line allows shell commands, do OS work in your own shell. Use the screen only where no command does the job:
- Open: `open -a "<App>"`, `open <file>`, `open -R <file>` (show it in Finder).
- Find: `mdfind`, `find`. Clipboard: `pbcopy`, `pbpaste`. Settings: `defaults read|write`.
- Files: `cp`, `mv`, `mkdir`, `ditto`, `zip`. Finder's own menus are for when the user wants to see it happen.
- Under UI only (`policy: ui-only`), every step goes through apprentice, shell included.

## Driving an app
- `menu "File > Export…"` reaches any menu item by its title, which is surer than hunting for a toolbar button. A greyed-out item usually needs the right window or a selection first.
- Shortcuts are real keys: `key cmd+s`, `key cmd+shift+g`. Shortcuts a person would use are fine.
- Fields that `read` doesn't list (inline rename, cells, field editors) take `type focused "…"` once a click has put focus there.
- `ok · +0 -0 ~0` means nothing visible changed. The click missed, or the app wants another gesture (double-click, right-click, drag). `ask` or `show` rather than repeating it.
- Some apps quit when their last window closes. `session --new-window` opens one with cmd+n.

## Save and open panels
- `choose "<path>"` drives every system open and save panel: it goes to the folder, picks the file or fills in the name. Don't type paths into the panel yourself.
- `upload <id> <path>` in a browser opens the picker with a real click and runs `choose`.

## System parts that belong to the user
- Privacy prompts ("… would like to access …"), Keychain and password dialogs, Touch ID, admin passwords and System Settings changes: `ask` the user, or `confirm` a gated step. Never click Allow for them.
- Accessibility or Screen Recording missing (exit 7): `apprentice doctor --fix`, then wait for the user.

## Courtesy
- The window comes to the front for each action, and the user's own keys or clicks stop it (exit 6). If they're busy, keep the steps few and short.
- Leave things as you found them: close what you opened when the task ends, unless the user wants to see the result.
