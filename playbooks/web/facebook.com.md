---
scope: site
match: facebook.com
tags: facebook, group, feed, dates, new posts, join, search
lang: en
verified: 2026-11-03, macOS 26.2, Chrome
status: partial
---
# facebook.com

How to behave here (pace, comments, friend requests, restrictions) is in the `apprentice-facebook` skill; this playbook holds the mechanics.

## Key facts
- Group feeds are not in date order. "New posts" and `?sorting_setting=CHRONOLOGICAL` still put older boosted and pinned posts among the new ones, and the feed only goes further back. Read each post's date first, and stop at 3 old posts in a row, 4 screens or 5 minutes (see the skill).
- `apprentice read` shows only a few posts of text at a time and the post body is often cut short ("… See more"). The date shows as a link or text near the name, for example `text "November 1 at 7:36 PM"` or `"3 hours ago"`. A group's search box ("Search within this group") mostly returns Marketplace listings and old ads, not recent posts.
- Joining a public group is one click on `button "Join group {name}"` and counts as a budgeted `join`. The page can shift after a click, so read again before the next one.
- An open Messenger chat box can sit at the bottom right of the page. It is not part of the group: leave it alone.

- Long posts and comments are cut off in `read` and `ocr` with "… See more", and the part that is cut is often the part that matters (the place, the date, the price). A post you have only seen cut off has not been read. Before judging or skipping a post, `click #button "See more"` on it, then `read` again. Comments hide behind "View N replies" and "View more comments" in the same way, and the poster's answers there often give the details.
- Expanding text is a plain click and changes nothing for anyone else, but each one still needs `approve`. Do the posts you are considering, not every post in the feed.

## Works
- Open a joined group: `click #link "View group"` from facebook.com/groups/joins/, then `wait-for "members"`.
- Browse: `browse 20`, then `read --filter "text"` or `ocr`; do it a few times, not for minutes on end.

- A click on a post's "See more" or a link inside the feed can leave the group (Marketplace, a profile, an ad). Check the address after every click; if it is not the group, go back, re-read for the right id and redo it. Do not read on from the wrong page and do not give up the group.
