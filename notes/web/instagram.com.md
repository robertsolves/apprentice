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
- Location: type into `textbox "Add location"`; a dropdown opens just below it. Click the matching place, e.g. "Melbourne"; typing alone does not set it. The dropdown is not in the accessibility tree, so `read` cannot list it: `show` it, or click about 45 px below the field's centre (the first suggestion).
- No music and no saved drafts on the web: music is in the mobile app only, and closing the composer discards the post. A "draft" means the composer is left open.
- `button "Share"` publishes at once. Never press it unless Robert asks for that exact step.

## Works
- Comment on a post: open it, `type #textarea "Add a comment" "{comment}"`, then `click #button "Post"`. The comment shows at once with your name and "2s".
- Leaving the composer: Escape does nothing; click the dark area outside it, then `click #button "Discard"`.
- Your profile is `click #link "{username}'s profile picture"`; the grid's first tile can be a pinned post, so check the date inside.
- Caption and hashtags: `type #textarea "Add a caption" "{caption}"`. The counter button shows the length.
- The Facebook cross-post setting sits under the caption. Leave it alone unless asked.

## Fails
- Location: a real click on `textbox "Add location"` does focus it; Chrome reports the new focus a moment late, and apprentice's focus check used to look too early and stop (fixed: it now waits up to 1 s). Robert pointed at the field to settle it.
- The suggestion list was on screen but `read` missed it: the walker did not look inside fields. Fixed; if it is still missing, ask Robert where it is rather than pressing return blind (return may reach Share).
- A caption ending in a #tag leaves a hashtag suggestion list open. End captions with plain text.
- The first file picker attempt typed the path into the picker's search box. Fixed in `choose`.
