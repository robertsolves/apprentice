---
scope: app
match: TextEdit, com.apple.TextEdit
tags: text, document, txt, plain text, save, new file, note
lang: en
verified: 2026-11-01, macOS 26.2
status: verified
---
# TextEdit

## Key facts
- Start with `session --app TextEdit --new-window`. TextEdit quits when it has no window.
- New documents are rich text. `menu "Format > Make Plain Text"` before saving makes a `.txt`.
- Autocorrect capitalises the first letter of typed text. Check the field's value in the diff.
- Save and Move To use the system save panel; see macos/save-panel.md.

## Works
- `type <textarea> "{text}"` types into the document in front mode.
- `menu "File > Save…"` opens the full save panel, which `read` can see.

## Fails
- `menu "File > Move To…"` opens a compact panel whose location picker is not visible to AX. Use Finder to move the file instead.

## Flows
- flows/textedit-new-text-file.md
