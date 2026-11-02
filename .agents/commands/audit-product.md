---
description: "Audit the product through the eyes of a real user. Surfaces design flaws, inconsistencies, and serious functional errors, asks hard questions about them, then fixes the ones the developer confirms. Run when asked to review the product, a feature or a flow as a user would, or before a release. Not a linter: ignores syntax, dependencies, formatting, and test coverage. Not for a project that ships its own product-audit command — use that one."
argument-hint: "[area or feature to focus on] (default: whole product)"
---

# /audit-product

Order: audit, ask, then fix only what is confirmed. Steps 1–5 are read-only. Do not create or edit any file before Step 6. Write questions and the report in your reply, not to a file.

**This is not a linter.** Ignore syntax, types, formatting, dead code, dependency versions, build warnings and missing tests. If the only person who would care is another developer, it is not a question.

Terms: **the developer** is the person running you (they answer). **The user** is the end-user of the product (their view drives the review).

## Step 1: load the product context

```sh
rg -n '^- \*\*(Product brief|Checks and tests)\*\*' .agents/project-facts.md | head -n 5
```

The bullets give `<brief_doc>`, `<scope_doc>`, `<expectations_doc>` and `<check_commands>`. Read each doc named (line ranges, not whole files over 300 lines), plus `README.md`. For a monorepo, note which app each finding belongs to.

| Situation | Action |
|---|---|
| `$ARGUMENTS` is empty | audit the whole product; stay in one app |
| `$ARGUMENTS` names an area | audit only that area |
| the command prints nothing, or no brief doc exists | stop and ask: "I couldn't find a product brief. In one paragraph: who is this product for, what does it promise them, and what would feel 'right' to them? Anything deliberately out of scope?" |

Done when: you can state in your notes the product's purpose, audience, voice, promises, and what is out of scope (from the docs or the developer's answer). Do not invent intent.

## Step 2: list the screens and flows to walk

```sh
git ls-files | rg -i '(screen|page|route|handler|endpoint)' | rg -i -- "${ARGUMENTS:-.}" | head -n 80
```

`$ARGUMENTS` given → stay in that one area. Empty → the whole product, but in a monorepo stay on the main user-facing app unless the developer asked for more.

Done when: you have a list of at most 15 flows or screens in scope, each with its file path. If the output is empty, stop and ask: "Which folder holds the screens or routes?"

## Step 3: investigate as the user

This step is judgement against the code; it has no command. Read the files from Step 2 (line ranges, not whole files). Hold the user's perspective throughout. Look for:

| Look for | Examples |
|---|---|
| Promises vs. reality | the implementation quietly diverges from the brief |
| Dead-end flows | create, edit, delete, view, share, invite, leave, sign out and back in, recover, undo, pay, cancel: where does a user get stuck or lose work? |
| Inconsistencies | loading, empty and error states, optimistic updates, terminology, button placement, confirmation prompts behave differently across screens |
| Edge cases | a member leaves a group, an item deleted mid-edit, a push for a deleted item, offline to online, empty lists, very long or duplicate names, time-zone and DST boundaries, session expiry, slow networks, large attachments |
| Data-model decisions that will hurt later | soft-deletes shown incoherently, renames or ownership changes breaking references, inconsistent history |
| Naming | the same concept with two names, or UI words that differ from the brief |
| Trust and safety | permissions, audit trail, accidental destructive actions, "are you sure?" moments, recoverability |

Skip: type or syntax errors, dependencies, code style, file layout, tests, micro-performance, refactors no user would notice.

Done when: you have a list of candidate problems, each with a `file:line` as evidence and a finished sentence "A user would notice this because …". Drop any candidate where you cannot finish that sentence.

## Step 4: compile 5-10 questions

This step is judgement; it has no command. Write a numbered list of 5-10 questions (never more than 10). Each question:

1. Leads with the user impact, with the `file:line` as evidence.
2. Cross-references the brief or scope where the product diverges.
3. Asks whether this is intentional, a known limitation, or a real problem.
4. Suggests the right product behaviour if it is a problem.
5. Carries exactly one tag: `design flaw`, `inconsistency`, `serious functional error`, `possibly intentional`.

Put anything that loses user data or crashes a core flow first, marked clearly. Example, copy this shape:

> 1. **(design flaw)** When a member leaves a group, their name still appears as assignee on items they ticked (`<path>:<line>`). Others see a ghost name with no way to reassign. The brief says the product should feel "trustworthy and current". Was this intentional, or should we show "Former member" or auto-reassign on leave?

Not questions: tests, variable style, dependency upgrades, long functions, adopting a framework.

Done when: the list has 5-10 questions, each tagged, each with user impact and evidence.

## Step 5: ask and wait

This step is a question to the developer; it has no command. Print the questions and stop. Do not edit anything. Wait for answers to all of them.

Done when: the developer has replied. An item they did not answer is left untouched in Step 6.

## Step 6: fix what was confirmed

Edit files with your file-edit tool. Never use `sed -i`, `perl -i` or shell redirection.

| Developer's answer | Action |
|---|---|
| confirms a problem and wants a change | implement a surgical fix for only that question |
| says it is intentional | do nothing; do not argue |
| no answer, or unclear | leave untouched |

Done when: every confirmed question has a fix, and no other file changed (`git diff --stat` lists only files you meant to edit).

## Step 7: run the checks

Use `<check_commands>` from Step 1 for the languages you edited. If it names none for a language, find the project's check script in its manifest (`package.json`, `pubspec.yaml`, `Makefile`, `Cargo.toml`) and use the closest one.

```sh
git diff --name-only | head -n 40
```

If a command fails twice with the same error, stop and report the output.

Done when: every check you ran exits 0, or you have reported the failure.

## Step 8: report

Reply with this shape, filled in:

```
# Audit Fix Report

## Fixed
- <question N>: <one-line description of the change> (`<path>:<line>`)

## Left as intentional (per developer)
- <question N>: <what the developer said>

## Left untouched (no answer)
- <question N>

## Checks
- <command>: pass / fail (details on failures)
```

Do not grade the product or give a score.

Done when: the reply holds every heading above, filled in.

## Done means

- No file was edited before the developer answered.
- Every changed file traces to a confirmed question: `git diff --stat` lists nothing else.
- Every check from Step 7 exits 0, or the failure is reported.
