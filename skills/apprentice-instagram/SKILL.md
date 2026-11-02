---
name: apprentice-instagram
description: How a person uses Instagram, for agents on instagram.com through apprentice - session rhythm, liking, commenting, following and posting the way an owner does, the signs of an action block and what to do. Load before acting on Instagram.
metadata:
  hosts: instagram.com
---

# Instagram through apprentice

Load `apprentice` and `apprentice-web` first. For current labels and steps (new post, location, comments), run `apprentice playbooks instagram`; `session` prints the key facts.

## A sitting looks like this
- Open the home feed and `browse` for a minute before the task. When the task is done, look around a little before leaving. Accounts that sign in, act and vanish stand out.
- Short sittings spread across the day, at the hours the user is usually awake, read better than one long run.
- Mix what you do in a sitting. A run of the same action (ten follows, twenty likes) is the clearest pattern there is.

## Engaging
- Open a post before you like or comment on it, and stay on it long enough to have seen it. Liking from the grid at speed is what scripts do.
- Comments should be about that post: something specific, in the user's voice (`apprentice voice`). Never post the same comment twice. Generic praise and emoji-only comments look automated, and people notice.
- Follow accounts you've interacted with, not a list. Don't follow and later unfollow the same accounts in cycles: that churn is the pattern Instagram watches hardest.
- In DMs, message people who already know the account. A message to a non-follower lands in their requests, and many unanswered requests count against the sender.

## Posting
- Posts and stories come at the user's own rhythm, a few a week, not in batches. Vary the captions.
- A handful of relevant hashtags reads better than the maximum. Don't paste the same block of tags on every post.
- Never press Share unless the user asked for that exact step. The web has no saved drafts, so a "draft" means leaving the composer open.

## Signs Instagram noticed
- "Try again later", "We restrict certain activity…", or an action that silently undoes itself (the like vanishes on reload): that's an action block. Stop all actions on the site and tell the user. apprentice starts the cooldown. Blocks get longer each time they're pushed.
- A login check, "Was this you?", or a request to confirm by phone or email belongs to the user.
- A new or long-quiet account gets a much smaller allowance. Start well under the budget and build up over weeks.

## Budgets
`apprentice budget instagram.com` shows what's left today. The caps are deliberately below what Instagram tolerates; plan the task inside them.
