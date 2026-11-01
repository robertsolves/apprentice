# Features

Every feature apprentice has, with how to tell from the logs whether it earns its place. Review this list every few weeks: a feature nobody uses, or one that never changes an outcome, is a candidate to take out. A feature that can't be measured yet says so; adding the log field is the first step.

Where the numbers come from:

- `~/.apprentice/runs/<date>-<session>/steps.jsonl`: one row per command, with `cmd`, `ms`, `waits` (`idle`, `gap`, `move`, `type`, `settle`), `diff`, `host`, `kind`, `vm`, gate results, errors and questions. `apprentice log` prints the tail.
- `~/.apprentice/events.jsonl`: rate limits, challenges, cooldowns and flags, kept 180 days. `apprentice activity <domain>` reads it.
- `apprentice grow`: the pace summary, repeated errors, questions asked and flows run over the last 14 days.

Verdicts: **keep** (used and pays off), **watch** (too new or too little data), **cut?** (little use; look closer before removing).

## Reading the screen

| Feature | Where | How to measure | Keep if | Verdict |
| --- | --- | --- | --- | --- |
| `read`: numbered element list | `Reader.swift` | `read` rows per action (grow's re-read %), `ms` | It stays the main source and the re-read rate falls | keep |
| Diffs after actions | `Reader.swift` `diff` | Re-reads after actions (grow) | Agents act from the diff; re-reads under 30% | keep |
| Ids that survive actions | `Reader.swift` `keepIds` | Re-read % before and after 2026-11-01; exit-2 (`stale`) count | Re-reads drop without more `stale` errors | watch |
| `--filter` / `--max` | `Commands.swift` | `flags` on `read` rows | Agents use them to keep lists short | watch |
| `ocr` | `Capture.swift` | `ocr` rows, and whether the next action used an OCR id | It unblocks pages the tree can't read | watch |
| `shot` / `shot --crop` | `Capture.swift` | `shot` rows | Used when a label is missing | watch |
| `shot --marks` | `Capture.swift` `mark` | `shot` rows with `marks: true`, then whether the next click used a marked id | It replaces `show` / `ask` questions about where something is | watch |
| `wait-for` | `Commands.swift` | `wait-for` rows, found vs timed out | It saves polling `read`s | watch |
| Snapshot cache (300 ms) | `Reader.swift` | Not measured: add a hit count | Hits are common | cut? |

## Acting

| Feature | Where | How to measure | Keep if | Verdict |
| --- | --- | --- | --- | --- |
| `click` (id, `--on`, `--at`) | `Commands.swift` | Rows by form; `stale` errors | Each form is used | keep |
| `type`, `key`, `menu`, `scroll`, `hover`, `drag` | `Commands.swift` | Rows per command | Each is used in real runs | keep; check `drag` and `hover` |
| `upload`, `download`, `choose` | `Commands.swift` | Rows and their errors (grow lists repeats) | Error rate keeps falling | keep, fix repeat errors |
| Event-driven settle in the VM | `Remote.swift` `settled`, `helper.py` `quiet` | `waits.settle` on `vm` rows, before and after | Median settle well under the old 1.3 s, no rise in actions on a half-loaded page | watch |
| Polling settle on this Mac | `Reader.swift` `settle` | `waits.settle` on non-`vm` rows (no data yet) | It stays under ~0.5 s; if not, add AXObserver events | watch |

## Pacing and human input

| Feature | Where | How to measure | Keep if | Verdict |
| --- | --- | --- | --- | --- |
| Bézier pointer paths, overshoot, settle, Gaussian landing | `Input.swift` `Mouse` | `waits.move`; challenges and soft blocks per site in `events.jsonl` | No challenges traced to pointer motion | keep |
| Key rhythm, thinking pauses, corrections | `Input.swift` `Keys`, `Pace` | `waits.type` per character | Typing stays human-paced without slowing short fields | keep |
| Gaps, bursts, rests | `State.swift` `Limits` | `waits.gap` on social sites | Sites with profiles stay free of soft blocks | keep |
| Dwell before budgeted actions | `SiteRules.swift` `Site.dwell` | `waits.gap` on rows with a `kind` | Same | keep |
| Look pauses between flow steps | `Pace.lookGap`, `Flows.swift` | `waits.gap` on rows inside a `do` | Flows show uneven timing, no new challenges on flow runs | watch |
| Pointer drift (linger) | `Input.swift` `Mouse.linger` | Not measured on its own | Hard to show; keep while cheap | watch |
| Pacing profiles per domain | `Config.swift` | Which profiles were active (add the profile name to rows) | Each profile is used | watch |

## Safety

| Feature | Where | How to measure | Keep if | Verdict |
| --- | --- | --- | --- | --- |
| Approval gate, tokens, `approve` / `deny` | `State.swift` `Approvals`, `gate()` | Proposals, approvals, denials; grow's approval wait | Part of the product | keep |
| `confirm` for ⚠ steps | `Ask.swift` | Confirms, denies, time to answer | The user denies sometimes (it catches things) | keep |
| Gate words and `[gated]` marks | `State.swift` `Gate` | ⚠ proposals vs denied ones | Warnings line up with what the user cares about | keep; prune words that never matter |
| Per-site budgets | `SiteRules.swift` `Budgets` | Budget stops (grow lists them) | Part of the product | keep |
| Cooldowns, soft-block detection | `SiteRules.swift` `Cooldown` | `events.jsonl` soft blocks; false alarms | Real blocks caught, few false ones | keep |
| Challenge hand-off | `SiteRules.swift` `Challenge` | `events.jsonl` challenges | Part of the product | keep |
| Site policies (Meta, TikTok refused) | `SiteRules.swift` `Policies` | Policy refusals | Part of the product | keep |
| Allowlist per session | `allowCheck` | Allowlist refusals | Used in the start-up window | keep |
| Kill switch | `Daemon.swift` `KillSwitch` | Not logged: add a row when it trips | It gets used, or stays as insurance | keep |
| Privacy scrubbing | `State.swift` `Privacy` | Not measured | Required | keep |
| Rate limits, reload cap, nav gap | `State.swift` `Limits` | `rate limit` and `refresh limit` errors | They fire rarely and on real loops | keep |

## Talking to the user

| Feature | Where | How to measure | Keep if | Verdict |
| --- | --- | --- | --- | --- |
| `ask`, `show` | `Ask.swift` | Questions per run (grow); unanswered ones | Each answer leads to a note or fix, and the count falls | keep |
| Away mode, exit 9 | `Ask.swift` | `away` rows, exit-9 count | Used when the user is remote | watch |
| Ask sound | `Config.swift` | Not measured | Cheap | keep |
| Start-up options window | `Commands.swift` `session` | How often defaults are changed there | People change something | watch |
| Keep-awake | `Awake.swift` | `awake` rows | Long runs finish without sleep | watch |

## Learning and reuse

| Feature | Where | How to measure | Keep if | Verdict |
| --- | --- | --- | --- | --- |
| Notes | `Notes.swift`, `notes/` | Notes printed by `session` / `open`, then used | Questions about the same page stop | keep |
| Flows (`do`) | `Flows.swift` | Flows run, steps completed vs stopped (grow) | Most runs complete; they replace agent steps | keep |
| `learn` | `Notes.swift` | Flows drafted that later ran | Drafts turn into used flows | watch |
| Routes (`route`) | `Routes.swift` | `route` calls that named a faster route | Agents take the route | cut? if never hit |
| `run` loop | `AgentLoop.swift` | `run` sessions, steps, stops | Someone runs tasks without a coding agent | cut? if unused |
| `replay` | `AgentLoop.swift` | `replay` runs, checks failed | Saved runs get replayed | cut? if unused |
| `grow`, `bug`, `commit`, self-update | `Grow.swift`, `Repo.swift` | Fixes made from grow items; failed updates | The tool keeps improving from use | keep |

## Platforms and integration

| Feature | Where | How to measure | Keep if | Verdict |
| --- | --- | --- | --- | --- |
| Linux VM (browser and apps) | `VM.swift`, `Remote*.swift`, `agent/vm/` | Share of rows with `vm: true`; VM errors | Most browser work moves there | keep |
| `vm call`, `vm look` | `VM.swift` | Calls per challenge | The user passes checks through it | watch |
| MCP server | `MCP.swift` | Sessions started through `mcp` (add a field) | An agent without a shell uses it | watch |
| CLI agent docs (`SKILL.md`, `AGENTS.md`) | `agent/` | Agent errors from misuse (bad flags, wrong order) | Misuse errors fall | keep |
| `activity`, `flag` | `SiteRules.swift` `Events` | `flag` rows; `activity` calls | Used after a warning | watch |

## Gaps to close

These features can't be measured yet:

- The snapshot cache's hit rate.
- Which pace profile each row ran under.
- Kill switch trips.
- How a session started (CLI, MCP or `run`).

Adding one log field each, and a grow line that totals them, makes the next review possible.
