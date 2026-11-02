# apprentice playbooks

What an LLM learned driving apps and sites, kept so the next run does not have to guess. `kit.sh` links `~/.apprentice/playbooks` to this folder, so `git pull` brings in playbooks learned on other machines.

- `apprentice session` and `open` print the **Key facts** of every playbook whose `match` fits the app, bundle id or host.
- `apprentice playbooks "words"` ranks playbooks by those words and shows the matching lines.
- `apprentice learn "task"` drafts `flows/<slug>.md` from the session's approved steps. Edit it, then commit.
- `apprentice do <flow> --key value` runs a flow: one approval for the whole plan, element names found on screen as it goes, and it stops with the screen at the first step that fails.
- `apprentice do --explain "task"` shows which flow a task would pick for the current model (`APPRENTICE_MODEL`), and why.
- `routes-learned.toml` is written by `do` the first time a model runs a flow to the end, so `route` points that model straight at it next time.

Playbooks are the mechanics: labels, steps and flows, learned on screen. Judgement (how a person behaves on a site or system) lives in the repo's `skills/apprentice-*`, which `kit.sh` installs as agent skills; `session` names the ones that fit.

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
