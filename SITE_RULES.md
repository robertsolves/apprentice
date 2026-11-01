# deskkontrol: Working Within Site Rules

Five additions would make permitted work on Robert's own accounts safer and easier to audit: daily budgets, rate-limit backoff, a machine-readable site policy, a clean handoff for challenges, and a restriction review. They keep sessions inside published or commonly enforced limits and stop cleanly when a site asks for a pause. None of them overrides a site's controls or expands what is permitted. The per-minute caps, reload limit, approval gate and allowlist already exist and are left out.

This is compliance work, not concealment: the daemon enforces limits and keeps a record. Where a site forbids automation, the policy entry refuses the session.

## Per-site budgets

Add hourly and daily caps per action kind, on top of today's per-minute cap. Sites commonly enforce limits over hours (follows, likes, posts per day), not only on bursts within a minute.

- The caps live in `~/.deskkontrol/budgets.json`, seeded from `agent/budgets.example.json`. Each domain inherits from `default` and overrides only what it sets.
- Each action kind has `hour`, `day`, an optional `week`, and `min_gap_s`, the shortest time allowed between two actions of that kind.
- The action kind comes from the label of the gated element: Follow → `follow`, Connect → `connect`, Add friend → `friend_request`, and so on. An unmatched gated action counts against `default`.
- Store the counts in `limits.json` next to the current timestamps. Days reset at local midnight, weeks on Monday.
- When a budget runs out, exit 4 with `budget: 20 likes on instagram.com today`. The calling agent should stop, not retry.
- Add `deskkontrol budget`, which prints the remaining budget per domain so an agent can plan before it starts.
- A missing or unreadable `budgets.json` falls back to the built-in `default`. It never falls back to no limits.

### Platform caps (per day, with the minimum gap between actions)

| Action | Instagram | TikTok | LinkedIn | Facebook | Reddit | X |
| --- | --- | --- | --- | --- | --- | --- |
| Post | 3 · 30 min | 3 · 60 min | 2 · 60 min | 5 · 30 min | 3 · 30 min | 10 · 10 min |
| Story / group post | 10 stories · 5 min | — | — | 3 group posts · 60 min | — | — |
| Comment / reply | 20 · 2 min | 20 · 2 min | 15 · 3 min | 20 · 2 min | 20 · 2 min | 20 · 2 min |
| Like / upvote | 100 · 30 s | 100 · 20 s | 50 · 30 s | 100 · 20 s | 100 · 15 s | 100 · 15 s |
| Repost | — | — | — | — | — | 20 · 2 min |
| Follow | 20 · 3 min | 25 · 2.5 min | 20 · 3 min | 20 · 3 min | 10 · 5 min | 20 · 3 min |
| Unfollow | 20 · 3 min | 25 · 2.5 min | — | — | — | 20 · 3 min |
| Join subreddit | — | — | — | — | 10 · 5 min | — |
| Connect / friend request | — | — | 15 a day, 80 a week · 5 min | 10 · 5 min | — | — |
| Direct message | 20 · 3 min | 15 · 3 min | 20 · 3 min | 20 · 3 min | 10 · 5 min | 20 · 3 min |
| Endorse | — | — | 10 · 2 min | — | — | — |

Reddit communities also set their own rules, often a minimum account age, karma, or a limit on self-promotion. The daemon can't see these, so the agent should read a subreddit's rules before it posts there. Reddit and X both have official APIs, so check `route` first, as with GitHub.

The hourly caps in the JSON stop a whole day's budget from being used in one burst. They come to roughly a quarter of the daily cap.

None of the four platforms publishes exact limits. These figures are deliberately set well below the levels at which platforms are commonly reported to intervene. Treat them as ceilings, not targets. A normal day for a real person is often far below them.

Volume caps don't decide whether automation is allowed. `SPEC.md` already keeps Instagram and Facebook out of the allowlist because their terms forbid automated actions, and the terms of TikTok, LinkedIn, Reddit and X also restrict automated access outside their APIs. Check each site's terms in **Site policies** before enabling any of them.

## Rate-limit detection and backoff

When a site signals that it is throttling the account, stop work on that domain. Continuing past a rate limit can turn a temporary pause into a longer restriction, and it makes the session harder to support.

What to watch for after each action, using the text the Reader already builds:

- Phrases such as "try again later", "you're doing that too much", "temporarily restricted", "unusual activity", "we limit how often", "rate limit".
- The page title or URL changing to a checkpoint, challenge or verify path.
- The same action failing twice in a row with no change on screen.

What the daemon does:

1. Mark the domain `cooling` in `limits.json` and refuse every action on it with exit 4 `soft block: x.com, cooling until 15:40`.
2. Hold off for 1 hour the first time, 6 hours the second time, then 24 hours. The counter resets after 7 days with no block.
3. Log the trigger phrase, the last 5 steps and a screenshot.
4. Let Robert clear it early with `deskkontrol cool --clear <domain>`. Agents cannot clear it.

Keep the phrase list in `config.toml`, so new wordings can be added without a rebuild.

## Site policies

Turn the "keep sites that forbid automation out of the allowlist" rule into data the daemon enforces. Today the rule depends on remembering it. A `[policy."<domain>"]` entry in `routes.toml` would hold:

| Field | Values | Effect |
| --- | --- | --- |
| `automation` | `allowed`, `read-only`, `forbidden` | `forbidden` refuses `session` even if the domain is allowlisted. `read-only` allows `read`, `ocr` and `shot` only |
| `terms_url` | URL | Printed in the refusal so the reason can be checked |
| `checked` | date | Warn when older than 6 months, since terms change |
| `api` | short text | Shown next to the refusal, for example the official API or export |

A `deskkontrol policy <domain>` command prints the entry. An unknown domain prints `no policy on file` once per session, so a gap gets noticed instead of ignored. Robert fills each entry after reading the site's terms. The tool should not guess them.

## Handing challenges to Robert

CAPTCHAs, 2FA prompts and identity checkpoints are out of scope, and the daemon should notice one rather than click around it. An agent that keeps clicking through a challenge is more likely to prolong the restriction than clear it.

1. **Detect.** After each read, match known markers: an iframe or element labelled captcha, "verify you are human", "enter the code", "confirm it's you", or a one-time-code field.
2. **Pause.** Return a new exit code, `8 challenge`, with the kind detected. Refuse all actions on that window until it clears.
3. **Notify.** Post a macOS notification that names the site and the kind. Clicking it brings the session window to the front.
4. **Resume.** Poll every 5 s, up to 10 minutes, and treat the challenge as solved once the markers are gone. Polling only observes the window; Robert is the only one who completes the challenge. Then return `0 resumed`, and the agent re-reads before acting.

The agent should wait on exit 8 or end the task. It must never try the challenge itself. Add that rule to `SKILL.md` and `AGENTS.md`.

## Reviewing a restriction

Step logs are kept per session, but a restriction usually comes from activity across several sessions and days. Add a view by domain:

- `deskkontrol activity <domain> [--days 7]` prints action counts per day and kind, budget use, rate limits and challenges, all on one timeline across sessions.
- Keep a small `~/.deskkontrol/events.jsonl` of rate limits, challenges and budget refusals for 180 days, longer than the 30-day step logs. Restrictions often show up weeks after the activity that caused them.
- `deskkontrol flag <domain> "note"` records the time Robert saw a warning or restriction. `activity` then marks that point, so the 48 hours before it can be compared with a normal week.

## Order of work

The two that stop damage while it is happening come first.

- [ ] Rate-limit detection and cooldown (`Limits` in `State.swift`, phrase match in `Commands.swift`)
- [ ] Challenge detection, exit 8 and notification, plus the agent-doc rule
- [ ] Hourly and daily budgets and `deskkontrol budget`
- [ ] `[policy]` entries in `routes.toml` and `deskkontrol policy`
- [ ] `events.jsonl`, `activity` and `flag`
