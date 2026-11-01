---
scope: site
match: instagram.com
tags: instagram, ig, post, new post, upload, photo, caption, hashtags, location, music, draft
lang: en
verified: 2026-11-01, macOS 26.2, Chrome
status: partial
---
# instagram.com

SPEC.md keeps Instagram out of the allowlist (its terms forbid automated actions). Use it only when Robert asks for a specific step, and never press Share for him.

## Key facts
- New post: `click #link "New post"`, then `upload #button "Select from computer" "{image}"`. The picker opens only for a real click; `upload` handles that.
- Next twice (Crop, then Edit) reaches the details page: caption, location, collaborators, Share.
- Location: typing into `textbox "Add location"` opens a dropdown just below it; click the matching or closest text, e.g. "Melbourne" (from Robert). Typing alone does not set it.
- No music and no saved drafts on the web: music is in the mobile app only, and closing the composer discards the post. A "draft" means the composer is left open.
- `button "Share"` publishes at once. Never press it unless Robert asks for that exact step.

## Works
- Caption and hashtags: `type #textarea "Add a caption" "{caption}"`. The counter button shows the length.
- The Facebook cross-post setting sits under the caption. Leave it alone unless asked.

## Fails
- Location: a real click on `textbox "Add location"` once failed to take focus (focus stayed in the caption), so `type` stopped before typing. The old workaround focused it through accessibility, which deskkontrol no longer does. If it happens again, `show "the Add location field"` and note what Robert does.
- The suggestion list was on screen but `read` missed it: the walker did not look inside fields. Fixed; if it is still missing, ask Robert where it is rather than pressing return blind (return may reach Share).
- A caption ending in a #tag leaves a hashtag suggestion list open. End captions with plain text.
- The first file picker attempt typed the path into the picker's search box. Fixed in `choose`.
