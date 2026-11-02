---
scope: system
system: macos
match: *
tags: input, cursor, keyboard, focus, no change, stuck
lang: any
verified: 2026-11-01, macOS 26.2
status: verified
---
# Any macOS app

## Key facts
- Every action is real input with the window in front: the cursor moves and clicks, keys are pressed. The user's own input stops it (exit 6).
- `ok · +0 -0 ~0` means nothing visible changed: the click may have missed, or the app needs a different gesture. Ask the user (`ask`, `show`) rather than repeating it.
- Fields that `read` does not list (inline rename, field editors) take `type focused "{text}"`.

## Works
- `menu "Menu > Item"` clicks the menu title, rests on submenus and clicks the item, in any app.
- `session --new-window` opens a window with cmd+n when the app has none. In a browser it opens a tab instead (`--new-tab`), in the window apprentice used last, and reuses a tab already on the new-tab page.
- `type` checks that its click gave the field focus before it selects or types anything.

## Fails
- Some apps quit on their own when their last window closes. Open one with `session --new-window`.
- Menu items can be disabled until the right window or selection is active.
