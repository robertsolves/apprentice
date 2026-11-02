---
description: Walk every markdown doc, triage each for real questions (scenario gaps, contradictions, vague claims), interview the user in batches of three, and apply the answers back into the doc. Run when asked to interview the user about the docs, or to settle product intent that the docs leave open. Not for questions about source code — use /interview-code; not for one risky code spot — use /interview-risky-spot; not for syncing docs with the code without asking — use /update-docs; not for rewriting docs for clarity — use /improve-markdowns.
argument-hint: "[paths] (default: every *.md in the repo)"
---

# /interview-docs

The user is the oracle for product intent and behaviour only they can confirm. Read each doc as a real end user of the product, ask forced-choice questions, and write the answers back into the doc. The strongest question is "a user does X — should (A), (B) or (C) happen?". Engineering questions come after user-perspective ones.

Writes: only the doc being interviewed, plus a `TODO(...)` marker in another file where a step below says so. Everything else goes in your reply. Never commit.

## Step 1: Load the project facts

```sh
rg -n '^- \*\*(Product brief|Audit records)' .agents/project-facts.md | head -n 5
```

Define from the output:

- `<brief line>` = the line starting `- **Product brief**` (the brief, scope doc, user-expectations doc and glossary).
- `<records line>` = the line starting `- **Audit records**` (the point-in-time audit files).

Done when: both are defined. If either line is missing, stop and ask: "Which docs are the product brief and the audit records?"

## Step 2: List the docs

Replace `<paths>` with `$ARGUMENTS`; when `$ARGUMENTS` is empty use `.`.

```sh
rg --files --hidden -g '*.md' -g '!node_modules' -g '!.dart_tool' -g '!build' -g '!coverage' -g '!.git' -g '!*pub-cache*' <paths> | wc -l
rg --files --hidden -g '*.md' -g '!node_modules' -g '!.dart_tool' -g '!build' -g '!coverage' -g '!.git' -g '!*pub-cache*' <paths> | sort | head -n 300
```

Every `*.md` is in scope: root docs, agent guides, agent rules, command specs (this one too), package READMEs. Never in scope: `node_modules/`, `.dart_tool/`, `build/`, `coverage/`, `.git/`, anything in `pub-cache` or a third-party package.

Done when: the first command prints the count and the second the list (when the count is over 300, re-run the second with `| sed -n '301,600p'`, then `'601,900p'`, until the list ends). If the count is `0`, stop and report "no markdown files match".

## Step 3: Confirm the queue with the user

This step is a question. Print the count from Step 2. Using `<records line>`, name the files in the list that are point-in-time artefacts (audit dumps, change logs, to-fix lists). Ask:

```text
<N> docs in scope. These look like point-in-time records: <list>. Include them (default), or skip them?
```

| The user says | Do |
|---|---|
| nothing, or `include` | keep all |
| `skip` | drop the listed files from the queue |
| a path list | drop only those |
| `stop` | end the run |

Done when: the user has answered and the queue is final.

## Step 4: Order the queue

This step is judgement. Order the files: (1) the product brief from `<brief line>`, (2) the scope doc from it, (3) the agent guide (`AGENTS.md` / `CLAUDE.md`), (4) the agent rules, (5) everything else grouped by directory, command specs and root docs last. Alphabetical inside each group. If the user names another order, use theirs.

Done when: you can print the first file of the queue.

## Step 5: Triage the next file

Steps 5 to 10 repeat for each file until the queue is empty. This step is judgement. Read the file in full and decide whether it holds at least one real question that you cannot answer from the file or the repo. "I could maybe ask about…" does not count.

| The file is | Decision |
|---|---|
| tight, consistent, nothing for the user to add | skip |
| a thin index or pointer with no claims of its own | skip |
| a point-in-time artefact the user kept in Step 3 but that only records a past state | skip |
| every question you can think of is answerable from the code or another doc | skip |
| has a scenario gap, unverified claim, contradiction, vague phrase, silent gap, stale reference, missing rationale or terminology drift you cannot resolve | interview |

Done when: you have a decision for this file.

## Step 6: Present the decision

Skip: print one line and go to the next file without waiting.

```text
[i/N] Skipping: <relative path> — <one-line reason, e.g. "thin index, no claims to verify">
```

Interview: print this and wait.

```text
[i/N] Reviewing: <relative path>
<one-sentence description of what this doc claims to be>
Worth interviewing because: <one line naming the strongest 1–2 question categories>

Interview, skip, or stop?
```

| The user says | Do |
|---|---|
| `interview`, `i`, `yes`, `y` | go to Step 7 |
| `skip`, `s`, `n` | go to the next file |
| `stop`, `q` | go to Step 11 |
| `interview <path>` for a file you skipped | queue that file next and go to Step 7 |

Done when: the user has answered, or the file was skipped.

## Step 7: Write the questions

This step is judgement. Read `.agents/skills/interview-docs/references/question_categories.md` § Scenario gaps, then § Other categories, then § Which categories lead. Re-read the file as an end user: every place the doc fails to say what should happen is a candidate.

Before keeping a question, check the ledger (Rules). A stale-reference question needs proof first:

```sh
ls <path-the-doc-names>
rg -n --max-count 3 '<name-the-doc-cites>' <folder> | head -n 10
```

Keep at most 9 questions per file. If a file has more real questions than that, ask the strongest 9 and tell the user the file likely needs a dedicated rewrite session. Each must be answerable in one line or one word, quote the passage with a line range like `(L42–48)`, carry one tag, and end in a forced-choice prompt. Prefer the scenario form "(A) …, (B) …, or (C) …". Use yes/no only when there are two outcomes, and an open prompt only when the user must author wording.

Done when: you have a numbered list of real questions. If you have zero, print "No clarifying questions" and go to the next file without writing anything. Never pad to three.

## Step 8: Ask three at a time

This step is a question to the user. Read `.agents/skills/interview-docs/references/question_categories.md` § Batch format, then print the next three questions in that format and wait. If fewer than three remain, print what is left. Ask only for this file; never mix files in one batch.

Done when: the user has answered every question in the batch. Then do Step 9 for these answers before showing the next batch.

## Step 9: Apply the answers

Edit the doc with your file-edit tool, using the least surrounding text. Keep its headings, order, tone, tense and person. Never edit a file the user skipped.

| The answer | Do |
|---|---|
| `leave it`, `intentional`, `drop`, `skip`, or no answer | change nothing for that question |
| tightens a vague phrase | rewrite the phrase |
| resolves a contradiction | fix this file; if the other side is another file, add `TODO(/interview-docs): <resolution that must land here>` there |
| fills a silent gap | write the user's words, edited only for grammar and house style |
| fixes a stale reference | write the verified current value |
| gives a rationale | add one line |
| shows a missing topic | add `TODO(/interview-docs): <topic>` at the end of the doc; add no section |
| needs a code change of one line (a comment, a rename) | make it |
| needs a larger code change | add `TODO(/interview-code): <change>` in that code file |
| contradicts the product brief | ask: "This contradicts the brief. Update (A) the brief or (B) this answer?" |
| is off-menu ("neither — do X") | apply their wording if actionable; ask one follow-up at most if it is ambiguous |
| shows the whole doc is broadly wrong | stop editing, summarise what you heard, ask: "Rewrite the whole file, or patch only the questioned parts? (default: patch)" |

Add the pair `(question → answer)` to the ledger (Rules). If the answer also affects other files still in the queue (find them with `rg -l --max-count 1 '<term>' <paths> | head -n 20`), ask once:

```text
This answer also affects <files>. Apply the same edit there? (a) yes, (b) pick per file, (c) no, leave for their own rounds.
```

| The user says | Do |
|---|---|
| `yes` | apply the same edit to each listed file, verbatim |
| `pick` | ask per file |
| `no` | keep the answer in the ledger and apply it when that file's interview reaches it |

Done when: every answer in the batch is applied or declined, and `git diff --stat -- <file> | head -n 5` shows the file changed (unless every answer was declined).

If questions remain for this file, go back to Step 8.

## Step 10: Close the file

Print one line, then go to the next file. Do not restate or summarise the doc.

```text
[i/N] <path> — 6 questions across 2 batches, 5 applied, 1 declined. Wrote N edits.
```

Done when: the line is printed.

## Step 11: End the run

When the queue is empty, or the user says `stop`, print:

```text
files reviewed: <n>, files skipped: <n>, questions asked: <n>, edits applied: <n>
suggested commit message: <one line summarising the doc clarifications>
```

If you edited an agent guide, an agent rule or a command spec, read the edited lines once more to check they still make sense as an instruction. Do not commit.

Done when: the summary is printed.

## Rules

- **Ledger.** Keep a list of `(question → answer)` pairs until the user types `stop`. Before asking anything, check it. If an earlier answer settles the question, apply it as if asked, note `answered earlier for <file>`, and skip the question. Never re-ask. Never propagate to a file the user skipped.
- **One file at a time.** Never put questions about two files in one batch.
- **Quote before you question.** Every question points at a line range or an exact phrase.
- **Never invent answers.** If the user says "skip", skip.
- **Honour the agent rules.** When clarifying a term, use the spelling already in the agent rules and glossary. If the doc disagrees with them, ask which is canonical.
- **Stop on confusion.** If you cannot tell what the user meant, ask once. One follow-up per question at most.
- **Triage honestly.** When in doubt, skip with a reason.

## Done means

```sh
git diff --stat | tail -n 1
git status --short | grep '^ T'
```

The first line lists only docs you interviewed (plus any `TODO(...)` marker files). The second command prints nothing. The last reply holds the Step 11 summary.
