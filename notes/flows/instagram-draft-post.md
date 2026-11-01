---
scope: flow
match: instagram.com
tags: instagram, ig, post, draft, photo, upload, caption, hashtags
lang: en
verified: 2026-11-01, macOS 26.2, Chrome
status: partial
---
# Draft an Instagram post in Chrome, without sharing

Run: `deskkontrol do instagram-draft-post --image "{absolute path}" --caption "{#tags first, plain text last}" --place "{city}"`

Stops before location, which still needs a person or a screenshot. It never presses Share.

## Steps
1. `session --app "Google Chrome"`
2. `click #link "New post"`
3. `upload #button "Select from computer" "{image}"`
4. `click #button "Next"` — Crop → Edit
5. `click #button "Next"` — Edit → details
6. `type #textarea "Add a caption" "{caption}"` — end the caption with plain text, not a #tag, or a hashtag suggestion list stays open over the fields below.
7. `type #textbox "Add location" "{place}"` — opens a dropdown just below the field
8. Click the matching (or closest) place in that dropdown, e.g. "Melbourne". Leave Share alone.

## Fails
- Steps 1 to 6 ran together through `do` on 2026-11-01, with the real cursor.
- A caption ending in a #tag left a suggestion list open. A click on "Add location" then did not take focus, and typing went into the caption. `type` now checks focus first and stops.
