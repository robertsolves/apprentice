---
name: apprentice-linkedin
description: How a person uses LinkedIn, for agents on linkedin.com through apprentice - invitations, profile views, messages, comments and posts the way a professional does, the weekly invitation and search limits, and what to do when they show. Load before acting on LinkedIn.
metadata:
  hosts: linkedin.com
---

# LinkedIn through apprentice

Load `apprentice` and `apprentice-web` first. For current labels and steps, run `apprentice playbooks linkedin`; `session` prints the key facts.

## Profile views are seen
- Viewing a profile can show up in that person's "Who viewed your profile". Look at profiles the task needs and stay a while on each. Paging through dozens of profiles in a row is both visible and a pattern LinkedIn watches.
- Free accounts hit a monthly search limit (the "commercial use limit") when they search people heavily. Search narrowly with filters and open fewer results.

## Invitations
- Invite people the user has a real reason to know. Invitations that are ignored, or answered "I don't know this person", count against the account more than anything else.
- A short note that says why reads as a person, but free accounts get only a few notes a month. Save them for the invitations that need one, and `ask` the user which.
- LinkedIn caps invitations per week (roughly a hundred, lower for new or low-acceptance accounts), and the `connect` budget has its own weekly cap. If many invitations are pending for weeks, `ask` whether to withdraw the oldest. A withdrawn invitation can't be resent to that person for a few weeks.

## Messages, comments and posts
- Message connections and people who wrote first. Long, templated first messages to new connections are what people report.
- Comments add something to the post, in the user's professional voice (`apprentice voice`). One-word comments ("Great post!", "Congrats!") across many posts look automated.
- Posts come at the user's pace, a few a week. Read and answer the comments on the user's own post first; that's where the engagement is.
- Endorse skills for people the user has actually worked with, a few at a time.

## Signs LinkedIn noticed
- "You've reached the weekly invitation limit", a "commercial use limit" notice, "We've restricted your account", or a security check asking to confirm identity: stop all actions on the site and tell the user. apprentice starts the cooldown. Identity checks are the user's.
- A new account, or one that hasn't been used in a while, gets a smaller allowance. Build up over weeks.

## Budgets
`apprentice budget linkedin.com` shows what's left today and this week (`connect` has a `week` cap).
