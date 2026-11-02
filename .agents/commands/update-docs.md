---
description: Scan the codebase and update the project's core docs (agent guide, READMEs, architecture docs) to match reality, presenting a diff list for confirmation before applying fixes. Run after a stretch of structural changes (files moved, packages or commands added, subsystems reworked) or when the docs feel stale. Not for rewriting docs for clarity — use /improve-markdowns; not for one dead link or renamed symbol — use /find-stale-references.
---

# /update-docs

Fix stale references, add missing entries, remove mentions of things that no longer exist. The only files you edit are core docs, and only after Step 6.

## Step 1: Learn which docs are core

```sh
rg -n 'Core docs|Search helpers' .agents/project-facts.md | head -n 5
```

The **Core docs** line names the doc and heading that list the core docs and, for each, what it must match in the code (directories it summarises, scripts it describes, counts it states, inventories it must never re-grow). The **Search helpers** line names the project's doc-drift script, if any. Read that heading:

```sh
rg -n -A40 '^## <heading from the Core docs line>' <doc named on that line> | head -n 80
```

Write in your notes: the core-doc list, each doc's "must match" rule, and the drift script command.

| Result | Action |
|---|---|
| the rules file has a **Core docs** line | use the list it points at |
| no such line | take this set and ask: "Is this the core set: the agent guide, the root `README.md`, each package `README.md`, and the docs index with the docs it calls the authority for setup, the database and the API?" |
| the line points at a heading that is missing | stop and ask: "`<heading>` is gone from `<doc>`. Where is the core-doc list now?" |

Done when: your notes hold the core-doc list with one "must match" rule per doc.

If the **Search helpers** bullet names no script of its own, use the ones in the `search-helpers` skill: `bash .agents/skills/search-helpers/scripts/find_symbol.sh` is the symbol finder, `bash .agents/skills/search-helpers/scripts/capped_grep.sh` the grep helper and `bash .agents/skills/search-helpers/scripts/doc_drift.sh` the drift tool.

## Step 2: Read every core doc

Read each doc in the list, with its "must match" rule beside it. Read in whole; these docs are the task. Fetch several in one batch of parallel reads.

Done when: you have read every doc in the list.

## Step 3: Run the mechanical checks

If Step 1 found a drift script, run it from the repo root with no argument for all checks:

```sh
bash <drift script> 2>&1 | head -n 80
```

Each finding line names a file, a line and the dead target. Copy every finding into your diff list. If the project has no drift script, check by hand for each core doc:

```sh
test -e <path cited in the doc> && echo ok || echo MISSING
```

Check three things: every relative link and backticked repo path resolves; every file a docs index promises to list is listed and nothing listed is missing from disk; every workflow, script, command or rule file a doc cites still exists.

For each dead path, find where it went:

```sh
git log --diff-filter=R --name-status --format= -- '<old path>' | head -n 5
```

| Result | Fix to propose |
|---|---|
| renamed | cite the new path |
| deleted, nothing replaced it | reword the sentence, and flag it in the diff list |
| no trace in git | add to the diff list as "path missing, no history" and ask in Step 6 |

Done when: every finding or missing path is in your diff list, or the check printed nothing and you wrote "mechanical checks clean".

## Step 4: Check the judgment items

No script does these. For each core doc, in order:

1. List the directories it summarises (`ls <dir> | head -n 60`) and compare with what the doc says.
2. Read the source files the doc describes (dependency manifests, routers, auth middleware, setup scripts, config files) instead of trusting the doc's own summary. Read a chain such as an auth middleware's early returns top to bottom: a whole branch can be added without the doc's narrative looking wrong.
3. Where the doc states a count or an ordered list, recount it from the source (`ls <dir> | wc -l`, or read the list).
4. Where a bug was fixed by inverting a documented behaviour, check the doc does not still describe the broken version as the design.
5. Find code with no doc entry (a new screen, endpoint, command). Add it to the diff list unless the doc's "must match" rule says it keeps no inventory of that kind.

Done when: each core doc has been through all five checks and every discrepancy is in the diff list.

## Step 5: Present the diff list

Write it in your reply, not to a file. Group by file. Use this shape, one row per discrepancy:

```text
<doc path>
  line <N>: doc says "<text>" — code says "<fact>" (<path or command that shows it>) → proposed fix: <edit>
```

Done when: every discrepancy from Steps 3 and 4 is in the reply. If there are none, reply `docs match the code` and stop.

## Step 6: Ask the user to confirm

Ask: "Apply these <N> fixes?" Wait for the answer before editing anything.

| Answer | Action |
|---|---|
| yes | go to Step 7 |
| yes with changes | apply the list with the user's changes |
| no | stop; edit nothing |

Done when: the user has answered.

## Step 7: Apply the fixes

Edit each doc with your file-edit tool, one discrepancy at a time. Edit only the docs in the diff list. Never use `sed -i` or `perl -i`: they turn symlinked docs into diverging copies. Then check no symlink changed:

```sh
git status --short | grep '^ T'
```

Done when: every confirmed fix is applied and the command prints nothing.

## Step 8: Report

Reply with one line per file, filled in:

```text
<doc path>: <N> fixes — <short list of what changed>
```

Done when: every edited file has its line.

## Rules

- Document only what exists in the codebase right now. Do not invent.
- A section you cannot match to code may be planned: keep it and ask in Step 6.
- Change a doc's wording, tone and structure only to fix a factual error.
- A doc that cites a file that does not exist: flag it in the diff list, never silently remove the reference.
- Keep the agent guide short: it is loaded into every conversation.
- Preserve each doc's table and section layout: add rows, do not restructure.

## Done means

- Every discrepancy was shown in Step 5 and confirmed in Step 6 before any edit.
- If you ran Step 7, `git status --short | grep '^ T'` prints nothing.
- The drift script, if the project has one, no longer reports the findings you fixed.
