---
scope: system
match: *
tags: save, save as, open, panel, dialog, go to folder, location, where, file name
lang: en
verified: 2026-11-01, macOS 26.2
status: partial
---
# Save and open panels (every app)

## Key facts
- Use `choose "<path>"`. It handles everything below: an existing file is picked and opened, a folder is gone to, and a new file name is filled in.
- The panel runs in a separate system process and ignores keys sent to the app. It takes real keys only once it has focus, which a real click inside it gives.
- `read` shows the panel (and Go to Folder inside it) while it covers the window.

## Works (what `choose` does)
- Clears the search field: leftover text turns the list into search results.
- Clicks the empty bottom edge of the file list, then presses cmd+shift+g. With focus in the search field, the shortcut does nothing; "/" typed in the list opens Go to Folder too.
- Types the Go to Folder path key by key (each key replaces the offered completion, as for a person), waits for the suggestions, checks the value, and retypes slowly once if it differs, before pressing return.

## Fails
- Typing a path fast into Go to Folder: inline completion eats keys, and a quick return picks a stale suggestion. That saved a file in the wrong folder.
- Keys the panel gets before it has focus are lost: `choose` clicks into the file list first.
- Go to Folder is a sheet inside the panel, which is itself a sheet. Look for it among the panel's descendants, not the panel.

## Not yet confirmed
- `choose` was confirmed opening a file (Chrome upload). Saving under a new name (folder plus name field) has not been run yet.
