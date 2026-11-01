---
scope: flow
match: Finder
tags: new folder, create folder, rename, folder name, desktop
lang: en
verified: 2026-11-01, macOS 26.2
status: partial
---
# Create a folder on the Desktop in Finder and name it

Run: `deskkontrol do finder-new-folder --name "{name}"`

## Steps
1. `session --app Finder --new-window`
2. `key cmd+shift+d` — the Desktop. For another parent, run `menu "Go > Go to Folder…"` and `choose` instead.
3. `menu "File > New Folder"`
4. `type focused "{name}" --enter` — New Folder leaves the name field focused while Finder stays in front.

## Fails
- Steps 3 and 4 have each worked on their own; this exact pairing is unconfirmed. If step 4 finds no focused field, use the long route in macos/finder.md: sort by Date Modified, click the row's date cell, `key return`, then step 4.
- A `key return` renames whatever is selected. Check the path bar first; cancel a wrong rename with `key escape`.
