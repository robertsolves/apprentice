---
description: Rewrite the project's markdown files for clarity, fix stale references, remove tables, redistribute off-topic content, and keep CLAUDE.md / README.md lean. Run when docs feel bloated, duplicated or stale, or after files, commands or packages were renamed or moved. Not for asking the owner product questions about a doc — use /interview-docs; not for syncing the core docs with the code — use /update-docs.
argument-hint: "[paths] (default: every tracked .md file in the project)"
---

# /improve-markdowns

Brings every markdown file in line with reality. It rewords for humans, drops tables, fixes stale references, moves misplaced content to the right doc, and keeps `CLAUDE.md` and `README.md` short.

This command edits the in-scope `.md` files with your file-edit tool: targeted edits for rewrites, a full rewrite only for one doc at a time. Never use `sed -i` or `perl -i` (they turn symlinked files such as `CLAUDE.md` into diverging copies). Create no new file without the user's yes (Step 5 and the rules say when to ask). Make no commit and no push: the user reviews the working tree.

## Step 1: Resolve the scope

Arguments: `$ARGUMENTS`

| `$ARGUMENTS` | Action |
|---|---|
| empty | run `git ls-files '*.md'` (tracked files only; ignored paths are never in scope) |
| a list of paths | run the check below |
| a path not ending in `.md` | stop with one line: "`<path>` is not a .md file." |

```sh
for f in $ARGUMENTS; do ls "$f"; done
```

Write the resolved list in your reply as `<N> files:` followed by the paths, before you read any of them.

Done when: your reply holds the count and the paths. If the list is empty, stop and say "no markdown files in scope".

## Step 2: Build a cheap index

Do not read whole files yet. For each in-scope file run these three commands:

```sh
head -n 40 <file>
grep -nE '^\|.*\|' <file>
grep -noE '\]\(([^)]+)\)|`[~./][^`]+`' <file> | head -n 40
```

The first prints the H1, any frontmatter and the first headings. The second prints one `<line>:<text>` per table row (no output means no table). The third prints link targets and path-like references. Keep in your notes, per file: path, H1, section titles, table line ranges, reference targets.

Done when: every in-scope file has a notes entry. Write the index in your reply only if the user asked for it; do not write it to a file.

## Step 3: Tag each file with a role

This step is judgement: no command. Tag every file with one role from its name and location.

| File | Role |
|---|---|
| `README.md`, `CLAUDE.md` | entry doc: the audience matters most |
| under `doc/` or `docs/`, or named after a feature | topic doc |
| rule, skill or plan files, written for an agent or a narrow workflow | reference doc |
| under `ideas/`, `plans/`, `scratch/`, or with a name that does not say its purpose | scratch |

The role decides what belongs in the file: a topic doc named for one topic holds only that topic.

Done when: every file in your notes carries one role.

## Step 4: Load the rules

```sh
cat .agents/skills/improve-markdowns/references/rewrite_rules.md
```

It holds rules A to M and the report format. Keep them in your notes for Step 5.

Done when: the output ends with the `## Report format` block.

## Step 5: Rewrite each file, one at a time

Order: `CLAUDE.md` first, then `README.md`, then topic docs, then reference docs, then scratch. For each file do 5a to 5d before opening the next.

**5a. Read it.** Read the whole file now (not before).

**5b. Apply rules A to M** from Step 4. Check every path or command name the file mentions before you keep it:

```sh
ls <path>
```

`ls` printing the path means it exists. An error means it is stale: fix it by rule G. Never write a path, URL or command name you have not confirmed with `ls`, `grep` or `git ls-files`.

**5c. Re-read the file** once. Done when it reads top to bottom, and no table (`grep -nE '^\|.*\|' <file>` prints nothing) remains unless you flagged it as real tabular data for the report.

**5d. Decide stops.** Apply this table:

| Situation | Action |
|---|---|
| code and a doc disagree and it is not clear which is right | stop and ask: "`<file>:<line>` says `<claim>` but the code does `<fact>`. Which is right?" Do not edit that line |
| a section belongs in a doc that does not exist | stop and ask: "Create `<new file>` for `<section>`?" |
| you cannot tell which doc owns duplicated content | stop and ask: "`<content>` is in `<file A>` and `<file B>`. Which owns it?" |
| a table is real numeric data | keep it, list it under "Questions for the user" |
| anything else | decide by the rules |

Do not reformat a paragraph that already reads cleanly: edit only to fix a concrete violation of rules A to M. Do not invent facts.

## Step 6: Consolidate across docs

After all files are edited, walk your index once more.

1. Find content now duplicated in two or more docs. The most specific doc owns it. Replace the other copies with a one-line link to the owner.
2. Find references that point at nothing because Step 5 moved or renamed content:

```sh
git ls-files '*.md' | xargs grep -noE '\]\(([^)#]+)' | head -n 100
```

Each line is `<file>:<line>:](<target>`. Resolve each relative target from its file's folder with `ls`, and patch every one that fails.
3. Re-check `CLAUDE.md` and `README.md` for length added by the moves. If either grew, say why in the report.

Done when: every link target in the edited files resolves, or is listed under "Stale references unresolved".

## Step 7: Report

Print the report in the shape given at the end of `.agents/skills/improve-markdowns/references/rewrite_rules.md` (`## Report format`), filled in, in your reply only. Write it to no file.

Done when: your reply holds every heading of that block, with counts filled in.

## Done means

- The reply opened with the resolved file count and paths (Step 1).
- For every edited file, `grep -nE '^\|.*\|' <file>` prints nothing, or each remaining table is listed under "Questions for the user".
- Every path you wrote in an edited file passed `ls`.
- `git status --short | grep '^ T'` prints nothing (a `T` means a symlink became a plain file).
- No commit was made, and no file was created without the user's yes.
- The report block was printed with all headings.
