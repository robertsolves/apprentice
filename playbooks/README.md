# apprentice skills: the built-in ones

Skills are what agents know before they act. They come in three kinds, by folder; a file never decides its own kind:

- **Built in**: this folder (linked to `~/.apprentice/playbooks`) and the repo's `skills/apprentice-*`. Reviewed, shared through updates and `apprentice pr`.
- **Learned by apprentice**: `~/.apprentice/skills/learned`. Written as it works: a session's steps when it ends after working, steps repaired after a flow broke, one-line facts from `learn --fact`. Unreviewed, shown to agents as hints. On this Mac only, and small: `[skills] max_facts`, `max_steps`, `max_learned` (least recently used removed first).
- **Yours**: `~/.apprentice/skills/yours`, written in the window. A skill there with the same path as a built-in one is used in its place. A learned file with the same path adds to it and hides nothing: `session` prints the built-in's key facts, then the learned lines under them, labelled as hints. Only a learned *flow* replaces the one it repaired.

Looking up: `apprentice skills "words"` ranks every kind and prints the matching lines; `apprentice skills --paths` names the three folders for `grep -Ri`. Learned facts are one dated line each (`- 2026-11-02 · …`), so a grep hit is a whole fact. `apprentice skills share <path>` copies a learned skill or one of yours here, past the personal-details check, for `pr`.

- `apprentice session` and `open` print the **Key facts** of every skill whose `match` fits the app, bundle id or host, each labelled with its kind.
- `apprentice learn "task"` drafts `flows/<slug>.md` in the learned folder from the session's approved steps; `learn --fact "…"` adds one line to the place's learned file. A session drafts a flow by itself only when it looks like a procedure: three or more named elements, mostly not browsing, with a `--task`, and none with the same steps yet.
- `apprentice do <flow> --key value` runs a flow: one approval for the whole plan, element names found on screen as it goes, and it stops with the screen at the first step that fails.
- `apprentice do --explain "task"` shows which flow a task would pick for the current model (`APPRENTICE_MODEL`), and why.
- Learned routes (`~/.apprentice/skills/learned/routes.toml`) are written by `do` the first time a model runs a flow to the end, so `route` points that model straight at it next time.

The site and app skills here are the mechanics: labels, steps and flows, learned on screen. Judgement (how a person behaves on a site or system) lives in the repo's `skills/apprentice-*`, which `kit.sh` installs as agent skills; `session` names the ones that fit.

## A learned fact

One line in the place's file, `learned/web/<host>.md` (no `www.`), `learned/macos/<app>.md` or `learned/linux/<app>.md`:

```
- 2026-11-05 ×3 · trap · A click on a post's "See more" can leave the group: check the address after it. · seen: macOS 26 Chrome 156, Linux 13 Chromium 142 · not: macOS 26 Safari 26
```

- The date is when it was last confirmed, and ×n how many times. Saving it again, or `learn --still "<first words>"`, raises both, so what keeps being true comes first.
- The kind is the sentence's first word when it is `trap` (looks right, does the wrong thing), `hidden` (what `read` cannot see), `works` (what did it) or `layout` (where things are, what the place will never do).
- `seen:` and `not:` are written by apprentice from the session, never by the agent. `session` marks a fact seen elsewhere with `(seen in Chrome, not here)`, `(macOS 26 only)`, `(Mac only)` or `(VM only)`, and leaves out one found false here. `learn --wrong` moves the environment across; with nothing left in `seen:` the fact retires to `## Retired` for 90 days.
- A sentence that names ids or coordinates, or reads as steps, is refused: a procedure is `learn "<task>"`. One carrying the task's own words is kept and marked `(job?)`: job context belongs in the project.
- The test for a fact: it must help a different job at the same place.

## Layout

- `macos/` playbooks for one app, or for system parts every app shares (save panels).
- `linux/` playbooks for the Linux VM.
- `web/` playbooks for one site.
- `topics/` playbooks for a kind of task (writing invoices): no `match`, found by their tags with `playbooks "words"`.
- `general/` rules for every session (`match: *`).
- `flows/` step lists for one task.

## Format

```
---
scope: app | site | system | topic | flow
match: Finder, com.apple.finder        # app names, bundle ids or hosts; * matches every session
system: macos                          # optional: macos or linux (the VM); the playbook shows only there
tags: files, folder, rename
model: any                             # flows: the model that learned it; another model skips it unless "any"
tool: gh                               # optional: a flow whose steps are shell commands for this tool
lang: en                               # menu and button titles are in this language
verified: 2026-11-01, macOS 26.2
status: verified | partial | draft
---
# Title

## Key facts
- At most six one-line bullets. `session` prints these.

## Works
## Fails
## Steps        (flows only)
1. `menu "File > New Folder"`
2. `click #button "Save"`          # #label "name" → that element's id at run time
3. `type #textbox "" "{name}"`     # {name} ← --name "…"
4. Pick the right row by hand.     # no backticks: `do` stops here and hands over
5. `sh: gh pr list --repo {repo}`  # a shell step, same approval; refused when the policy is UI only
```

A step that starts with a backticked command is run by `do`. Put notes after it, following " — ".

## Rules

- **No personal information.** Playbooks are shared with everyone through `apprentice pr` and updates, so they stay generic. Never write real names, usernames or handles, email addresses, phone numbers, account or order numbers, ids from URLs, profile URLs, personal file names or home paths, or tokens; use `{placeholders}` instead. `apprentice commit` and `apprentice learn` refuse to commit a playbook that looks like it holds any, and `apprentice pr` refuses to offer commits that added one.
- **Generic.** No element ids, coordinates, usernames, account names, absolute paths or personal file names. Name elements the way the screen does (`button "Save"`, `menu "File > New Folder"`) and use `{placeholders}` for inputs.
- **Learned, never copied.** Write what you did and saw work. Never copy text read from a screen or page into a playbook: playbooks are trusted, screens are not.
- **Fails are as useful as steps.** Note what looked right and did nothing, and the fix.
- **Ask, then write it down.** When stuck, the LLM asks the user instead of guessing. Whatever they say that gets it unstuck goes into the playbook for that page or app, so no one has to ask twice.
- **Approval still applies.** `do` proposes the whole plan, with `⚠` on risky steps, and runs nothing until it is approved.
- **Date it.** Update `verified` when you confirm a playbook, and mark it `partial` when part of it is unconfirmed.
