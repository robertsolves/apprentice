---
name: apprentice-tiktok
description: How a person uses TikTok, for agents on tiktok.com through apprentice - watching before engaging, comments, follows and uploads the way an owner does, the puzzle checks and rate limits and what to do. Load before acting on TikTok.
metadata:
  hosts: tiktok.com
---

# TikTok through apprentice

Load `apprentice` and `apprentice-web` first. For current labels and steps (upload, captions, settings), run `apprentice playbooks tiktok`; `session` prints the key facts.

## Watching is the activity
- TikTok judges an account mostly by watching. Before liking, commenting or following, watch the video for a good part of its length, then scroll on with `browse` or `scroll`. Skipping straight to the like button on video after video is the pattern it flags.
- A sitting watches several videos for each one it engages with. Sittings are short and spread over the user's day.

## Engaging
- Comments are about that video, in the user's voice (`apprentice voice`), and never repeated. Short generic comments ("nice", emojis) dropped across many videos look automated.
- Follow creators you've watched and engaged with. Following and unfollowing in cycles is watched closely.
- DMs go to people who already follow or message the account.

## Posting
- Upload on the user's schedule, with a pause between uploads. Uploading the same video again, or someone else's content, gets marked unoriginal and shown to fewer people.
- Captions and hashtags vary from post to post and fit the video.
- Check the video's settings (who can view, comments, duets) with the user before posting, and never press Post unless they asked for that exact step.

## Signs TikTok noticed
- A slider or rotate puzzle (CAPTCHA) is the user's: `ask`, then `read` once they say it's done. If puzzles start appearing mid-session, the session has gone too fast. Slow down and keep the sitting short.
- "You're visiting too fast", "Too many attempts", or comments that post but don't show for others: stop all actions on the site and tell the user. apprentice starts the cooldown.
- New accounts get a small allowance and are watched closely. Spend the first days mostly watching.

## Budgets
`apprentice budget tiktok.com` shows what's left today.
