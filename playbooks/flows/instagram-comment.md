---
scope: flow
match: instagram.com
tags: instagram, ig, comment, reply, post comment
lang: en
verified: 2026-11-01, macOS 26.2, Chrome
status: verified
---
# Comment on one of your Instagram posts

Run: `apprentice do instagram-comment --username "{username}" --comment "{comment}"`

## Steps
1. `session --app "Google Chrome"`
2. `click #link "{username}'s profile picture"` — your profile
3. Open the post: the first tile is the newest unless a post is pinned; check its date.
4. `type #textarea "Add a comment" "{comment}"`
5. `click #button "Post"` — sends the comment for everyone to see

## Fails
- The comment box is replaced by a new element when it gains focus, which once made `type` stop. Fixed: `type` accepts the same kind of field with the same name.
