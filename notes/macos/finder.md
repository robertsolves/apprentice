---
scope: app
match: Finder, com.apple.finder
tags: files, folder, new folder, rename, move, go to folder, desktop
lang: en
verified: 2026-11-01, macOS 26.2
status: verified
---
# Finder

## Key facts
- Finder acts on its front window: New Folder and rename need the session window in front, which every action ensures.
- With no window open, `session --new-window` opens one. The desktop alone is not a session window.
- List rows exist only while visible. Sort by Date Modified (click its column header) to bring a new item to the top.
- Select a row by clicking its date cell. Clicking the name of a selected row starts a rename.
- Rename: select the row, `key return`, then `type focused "{name}" --enter`.
- Check the path bar at the bottom of `read`: its last item is the current selection.

## Works
- `key cmd+shift+d` goes to the Desktop, even in the background.
- `menu "File > New Folder"` creates `untitled folder` in the current folder.
- `menu "Go > Go to Folder…"` opens a sheet with a path field. A path to a file selects that file.

## Fails
- Typing into a row's name field without starting a rename (return) does not rename the file.
- `key return` renames whatever is selected. Check the path bar first; type-to-select can move the selection.
- Typing letters into the list moves the selection to a matching file (type-to-select). Never type unless a rename field has focus.

## Flows
- flows/finder-new-folder.md
