---
scope: flow
match: TextEdit
tags: text file, txt, new text document, create file, note, save into folder
lang: en
verified: 2026-11-01, macOS 26.2
status: partial
---
# Create a plain text file with TextEdit

Finder has no "new text file" command, so make the file in TextEdit and save it where it belongs.

Run: `deskkontrol do textedit-new-text-file --text "{text}" --path "{folder}/{file}.txt"`

## Steps
1. `session --app TextEdit --new-window`
2. `menu "Format > Make Plain Text"`
3. `type #textarea "" "{text}"` — autocorrect may capitalise the first letter.
4. `menu "File > Save…"`
5. `choose "{path}"` — goes to the folder in the save panel and sets the file name.
6. `click #button "Save"`

## Fails
- Step 5 is new (`choose`). Before it existed, a fast Go to Folder sent the file to the folder the panel showed last. If the file lands in the wrong place, move it in Finder.
