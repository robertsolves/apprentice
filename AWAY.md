# Away tasks

Design for work that runs while the user is away from the computer and stops when they come back. Not built yet. When it lands, its behaviour moves into `SPEC.md` and this file goes.

The user works at the Mac. When they walk away, apprentice runs the queued tasks. When they come back, it gets out of the way at once. When they leave again, it carries on from where it was.

## The rule that makes it safe

Being interrupted is not the danger: apprentice already stops on the person's first key, click or scroll (`Borrow`, `Watch`), and `checkpoint()` runs just before the step that commits an action. The danger is resuming from memory after the screen changed underneath it.

**Never continue from where it thinks it was. Always re-read the screen, check it against the journal, then decide.** When the screen does not match, the task stops and asks the user. It never guesses.

## 1. Where away work runs

- **In the VM by default.** VM sessions never wait for the person on the Mac and are never stopped by them (`Remote.act`). They also keep running while the Mac is locked. Away tasks there cannot collide with the user; being away only decides *when* they run. The VM's browser profile is signed in to the sites once.
- **On this Mac only with `[away] host = true`.** Real input cannot drive a locked screen, and keeping the screen awake while the user is away means leaving it unlocked. So:
  - host away work stops when the screen locks (`com.apple.screenIsLocked`);
  - once the queue is empty it runs `pmset displaysleepnow`, which locks the Mac when the user's settings ask for a password on wake.

## 2. Deciding the user is away

Being idle is not enough: the user may be watching a video, on a call, or reading.

- The user counts as away after `[away] after_min` minutes (default 3) with no input (`Borrow.humanIdle`), **and** only while no other app holds a display-sleep assertion. Video players and calls hold one.
- Before taking over, the overlay counts down: "apprentice starts in 10 s, move the mouse to keep control". Any input cancels it. This catches most false positives.
- `away on` (already a command) skips the wait. Today it only sends questions to the chat; it would also start the queue.

## 3. Detecting the return

- In away mode **any mouse movement counts as a return**, not only keys, clicks and scrolls as in front mode. Moving the mouse is the first thing a returning person does. This matters: otherwise the user's first keystroke could land in a chat box apprentice had focused, and Return would send it.
- On return apprentice:
  - stops before the next event;
  - brings back the app that was in front when the user left (activation, not input: housekeeping, never acting on a site);
  - shows in the overlay what was left half-done, e.g. "typed 14 of 40 characters into Message on example.com, nothing sent".

## 4. Units and the journal

A task is split into **units**: steps that only make sense completed together, such as typing a message and sending it. Typing followed by Return or a click on Send is grouped automatically; flows can mark units themselves.

At the start of each unit the journal records:

- **Preconditions:** the window, the site's host, and that the next step's element resolves.
- **What it changes on the Mac:** the clipboard if it pastes, a tab it opened.
- **The inverse, when there is one:** clear the field it typed into, close the tab it opened.

On resume:

1. Re-read the screen and check the unit's preconditions. If they do not hold (the user navigated away, closed the tab, edited the field), the task becomes *needs-you*, the question goes to the phone (`[agent] notify`), and nothing is guessed.
2. If a unit was cut off midway, run its inverse, but only when the field still holds exactly apprentice's partial text. Never delete the user's text. Then redo the unit from its start.
3. Before re-running a committing step, check it did not already happen: the user may have come back just after Send was posted. Flows can carry a `check:` line for this ("the message is in the thread").
4. An LLM-driven task gets back what was done, what was cut off, and a fresh read of the screen, never its old ids.

The resume decision (journal + screen in; continue, undo and redo, or hand to the user out) is pure logic and gets `selftest` checks.

## 5. Approvals happen while the user is there

The queue holds **plans already approved**: a `do` flow with its one plan approval, or a `run` task with its allowlist. A step that warns outside the plan still exits 8, and with the user away the question goes to the phone. Budgets, cooldowns and a person's day (`quiet_hours`, `session_max_min`, `actions_per_day`) apply unchanged, so leaving the Mac on never means posting at 3 a.m.

## 6. What the calling agent sees

Agents treat exit 6 as "check the screen and retry", which would fight the user for the mouse. So:

- **Exit 10, "yielded: the user is back".** Nothing was done; do not retry.
- **`apprentice away wait`** blocks until the user is away again, then returns.
- In away mode a command started while the user is present gets exit 10 at once, instead of `waitIdle`'s 30-second wait.

Exit codes are part of the agent contract: `SPEC.md`, `usage()` in `main.swift`, `MCP.swift` and `agent/*.md` change together.

## New pieces

- `away add | list | cancel`, with the queue in `~/.apprentice/away/`. A task records its kind (`flow` or `run`), its approval, where it runs (VM or host), an earliest start, a deadline, and a state: `queued`, `running`, `yielded`, `needs-you`, `done`, `failed`.
- An `Away` monitor in the daemon: the idle and assertion check, the countdown, return and lock detection.
- The per-unit journal and the resume rules.
- Exit 10 and `away wait`.
- Config under `[away]`: `after_min`, `host`, `countdown_s`.

## Build order

1. Exit 10, `away wait`, and the stricter away-mode return detection. Enough for an agent such as Claude Code to pause and resume safely.
2. The queue, and VM-only away runs of approved flows.
3. The journal, undo, and the checks before resuming.
4. Host away work behind `[away] host`, with lock detection and locking afterwards.
