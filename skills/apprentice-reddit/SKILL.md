---
name: apprentice-reddit
description: How a person uses Reddit, for agents on reddit.com through apprentice - subreddit rules, karma and account-age gates, commenting, posting and voting the way a member does, removals and "you're doing that too much", and what to do. Load before acting on Reddit.
metadata:
  hosts: reddit.com
---

# Reddit through apprentice

Load `apprentice` and `apprentice-web` first. old.reddit.com and www.reddit.com have different layouts; work in whichever one the user's browser opens. For current labels and steps, run `apprentice playbooks reddit`; `session` prints the key facts.

## Each subreddit is its own site
- Before posting or commenting in a subreddit, read its rules (the sidebar or About) and look at what's on its front page. Flair, title formats, banned topics and link rules differ everywhere.
- Many subreddits have minimum karma or account age, enforced by AutoModerator. A post that seems to work but doesn't show in the subreddit's New tab was removed. Don't post it again: tell the user.

## Participating
- Comment in a thread after reading the post and the top comments. Comments add something specific, in the user's voice (`apprentice voice`). Reddit readers spot generic or AI-sounding comments quickly and downvote or report them.
- Commenting comes before posting. An account that only posts its own links reads as promotion. A common rule of thumb: most of the account's activity is ordinary participation, and only a small share points at the user's own things.
- Never vote on the user's own posts or comments from another place, or ask others to. Votes follow reading: upvote what you read and found useful, not a list.
- Cross-post to several subreddits only where each one welcomes it, and space the posts hours apart.

## Signs Reddit noticed
- "You're doing that too much. Try again in N minutes": stop. That number is the floor, and apprentice starts the cooldown.
- Posts removed by a moderator, a mod message, or a ban from a subreddit: tell the user. Don't post again or message the mods without them.
- If the user's posts and profile seem invisible to others (no votes, no replies, gone when logged out), the account may be filtered site-wide. Stop and tell the user; only they can appeal it.
- New accounts with low karma meet the most filters. Spend the first weeks commenting.

## Budgets
`apprentice budget reddit.com` shows what's left today (`upvote` counts as a like).
