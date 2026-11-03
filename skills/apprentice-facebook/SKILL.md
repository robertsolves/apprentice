---
name: apprentice-facebook
description: How a person uses Facebook, for agents on facebook.com through apprentice - profiles vs Pages, groups, friend requests, comments and posts the way an owner does, the signs of a restriction and what to do. Load before acting on Facebook.
metadata:
  hosts: facebook.com
---

# Facebook through apprentice

Load `apprentice` and `apprentice-web` first. For current labels and steps, run `apprentice playbooks facebook`; `session` prints the key facts.

## Who you are acting as
- Facebook switches between the personal profile and the Pages the user manages. Before posting, commenting or messaging, check which one is active (the avatar in the composer or the top bar). If it's unclear, `ask`.

## A sitting looks like this
- Scroll the feed or the group for a while before acting, and look around after. Short sittings at the user's own hours.
- Mix reactions, comments and reading. Long runs of one action stand out.

## Friends and groups
- Send friend requests only to people the user knows. Requests that go unanswered, or are marked "I don't know them", are what lead to "You can't use this feature right now".
- Groups often ask membership questions and need admin approval. Answer the questions truthfully from what the user told you, or `ask` them. Many groups hold new members' posts for review; that's normal, so don't post again.
- Read a group's rules before posting. The same post or link dropped into several groups is the classic spam pattern: write for each group, and space them hours apart.

## Engaging and posting
- Open a post and read it before reacting or commenting. Comments are specific and in the user's voice (`apprentice voice`), and never the same text twice.
- Posts come at the user's pace. Links to the same site in post after post get less reach and draw review.
- Marketplace and Messenger: reply to people who wrote first. Opening many conversations with strangers is flagged quickly.

## Signs Facebook noticed
- "You can't use this feature right now", "We limit how often…", "Your account is restricted", posts that fail to publish, or a checkpoint asking to confirm identity: stop all actions on the site and tell the user. apprentice starts the cooldown. Checkpoints and identity checks are the user's.
- A new or long-quiet account gets a smaller allowance. Build up over weeks.

## Reading a feed
- A group feed is not in date order, even with "New posts" or `?sorting_setting=CHRONOLOGICAL`: pinned and boosted posts come first, and scrolling only goes further back in time. Never scroll on hoping for something newer.
- Read a post's date before its content. It sits beside the poster's name ("2h", "Yesterday", "November 1 at 7:36 PM", "Sep 3"). A post with no date is treated as old.
- Text is cut off at "… See more" and replies at "View N replies". Click them (`button "See more"`) before judging a post: what was cut off is often the place, date or price. A post seen only cut off has not been read.
- Decide how recent counts before you start, and stop at 3 old posts in a row, 4 screens or 5 minutes. Don't act on a post you couldn't date.

## Budgets
`apprentice budget facebook.com` shows what's left today, including `friend_request` and `group_post`.
