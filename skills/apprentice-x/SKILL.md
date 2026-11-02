---
name: apprentice-x
description: How a person uses X (Twitter), for agents on x.com through apprentice - reading the timeline, replies, reposts, follows and posts the way an owner does, rate limits and duplicate rules, and what to do when they show. Load before acting on X.
metadata:
  hosts: x.com, twitter.com
---

# X through apprentice

Load `apprentice` and `apprentice-web` first. twitter.com counts as x.com. For current labels and steps, run `apprentice playbooks x.com`; `session` prints the key facts.

## A sitting looks like this
- Read the timeline before acting, and stop on posts you engage with. Short sittings at the user's own hours.
- Mix reading, likes, replies and the odd repost. A burst of one action stands out.

## Replies and posts
- Reply to what the post actually says, in the user's voice (`apprentice voice`). Fast generic replies under many large accounts' posts look like a bot even when they aren't.
- X rejects a post identical to a recent one ("You already said that"). Write each post fresh rather than tweaking a template.
- Links and mentions are fine in moderation. Many posts with the same link, or mentions of many accounts who don't follow back, get the account limited.
- Threads: post them at once, as the user wrote them, not spread out by a script.
- Keep to the length the account allows. A cut-off post means a longer one wasn't allowed.

## Following
- Follow accounts the user reads or talks with. Following many in a burst, and unfollowing the ones that don't follow back, is the pattern X limits first.

## Signs X noticed
- "Rate limit exceeded", "Something went wrong. Try reloading.", "You are over the daily limit…", replies hidden behind "Show more replies", or a request to verify by phone or email: stop all actions on the site and tell the user. apprentice starts the cooldown. Verification is the user's.
- Don't reload in a loop on "Something went wrong": the reload cap and the cooldown cover it.
- New accounts get a small allowance. Build up over weeks.

## Budgets
`apprentice budget x.com` shows what's left today.
