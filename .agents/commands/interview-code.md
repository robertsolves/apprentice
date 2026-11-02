---
description: Walk the project's source files, compare each against the docs, and ask the user forced-choice product questions only they can answer, then write the answers into both code and docs. Run when asked to "interview me about the code", to check what the code does against the product docs, or to pin down undocumented product behaviour. Product behaviour only, never code style. Not for markdown docs — use /interview-docs; not for one risky spot — use /interview-risky-spot.
argument-hint: "[paths or directories] (default: all main source files)"
---

# /interview-code

Use the user as the oracle for product behaviour only they can confirm. Per source file: read it, read the docs for it, ask only real product questions, then edit the code and the docs to match the answers.

Rules that hold in every step:

- Ask product questions only: never names, layers, refactors, error-handling placement or code organisation. Note such issues silently and move on.
- Never put a class, method, file path or line number in a question. Write "a user does X, what should happen?".
- If the docs or the brief already answer it, make the code match and do not ask.
- If the user gives no answer to a question, leave that item untouched.
- Never edit a file the user skipped. Write nothing to a file you were not asked to edit; report in your reply.

## Step 1: Load project facts and arguments

```sh
rg -n '^- \*\*(Product brief|Checks and tests)\*\*' .agents/project-facts.md | head -n 5
```

`<brief docs>` = the paths named in the Product brief line. `<checks>` = the analyze and schema-check commands named in the Checks and tests line. If the project has no `.agents/project-facts.md` or the line is missing, read the agent guide (`AGENTS.md`) and take the same two facts from it.

`$ARGUMENTS` lists paths or directories: restrict the queue to them. Empty: the queue is all main source files.

Done when: you can name `<brief docs>` and `<checks>`. If you cannot find either, stop and ask: "Which docs describe the product, and which command checks my edits?"

## Step 2: Detect the source extensions

```sh
find . -maxdepth 3 \( -name pubspec.yaml -o -name package.json -o -name Cargo.toml -o -name go.mod -o -name pyproject.toml -o -name Gemfile -o -name pom.xml -o -name 'build.gradle*' -o -name mix.exs -o -name '*.csproj' \) -not -path '*/node_modules/*' | head -n 40
```

Map each manifest to its extensions (`pubspec.yaml` → `.dart`, `package.json` → `.ts .tsx .js .jsx`, `Cargo.toml` → `.rs`, `go.mod` → `.go`, `pyproject.toml` → `.py`, `Gemfile` → `.rb`, `pom.xml` or gradle → `.java .kt`, `mix.exs` → `.ex .exs`, `*.csproj` → `.cs`). Always add schema files when present: `.sql .dbml .prisma .graphql .gql .proto`. Drop an extension with no files:

```sh
rg --files -g '*.<ext>' | head -n 3
```

`<exts>` = the extensions that survive. Print `<exts>` and the manifests that justified them, then ask: "Walk these extensions: <exts>? Add or remove any?"

Done when: the user confirmed or amended `<exts>`. If no manifest was found and the user gives none, stop.

## Step 3: Build the queue

Read `.agents/skills/interview-code/references/question_rules.md` § Exclusions for what to drop and the processing order. Count files per directory:

```sh
rg --files -g '*.<ext>' -g '!*.g.*' -g '!*.freezed.*' -g '!*.generated.*' | cut -d/ -f1-2 | sort | uniq -c | sort -rn | head -n 30
```

Run it once per extension in `<exts>`. Print the total, the directory counts and what you excluded (generated, tests, barrels). Ask: "Include all of these directories? Name any to leave out, and say if tests should be walked."

Build the ordered queue of the files that remain. Done when: the user confirmed the queue and you printed its length N. Judgement and a question; no command beyond the count.

## Step 4: Triage one file

Do Steps 4 to 8 for one file, then the next. Never mix files.

```sh
wc -l <file> | head -n 1
```

Read the file in full. Read the docs that describe what it should do, starting from `<brief docs>` and the docs the agent guide maps to its topic. Before you compose a question, check the ledger from Step 6: a prior answer that resolves it is applied, labelled `answered earlier for <other file>`, and not asked again.

Read `.agents/skills/interview-code/references/question_rules.md` § Worth interviewing, or not. Decide: interview or skip. This step is judgement.

Done when: you chose interview or skip for this file.

## Step 5: Present the decision

| Your decision | Print, then |
|---|---|
| skip | `[i/N] Skipping: <relative path> — <one-line reason>`, then go to the next file without waiting |
| interview | the block below, then wait |

```
[i/N] Reviewing: <relative path>
<one sentence: what this file is and what layer it lives in>
Worth interviewing because: <one line naming the strongest 1-2 question categories>

Interview, skip, or stop?
```

| User reply | Action |
|---|---|
| `interview`, `i`, `yes`, `y` | go to Step 6 |
| `skip`, `s`, `n` | next file |
| `stop`, `q` | go to Step 9 |
| `interview <path>` | force-interview that file next |
| no answer | leave the file untouched, next file |
| anything else | stop and ask: "Interview, skip, or stop?" |

Done when: the user replied or you printed a skip line. Question to the user.

## Step 6: Compile and ask the questions

Read `.agents/skills/interview-code/references/question_rules.md` § The three question categories, § Obviousness filter and § Question and batch format.

Find every real product question for the file, at most 6. Ask them three at a time in the batch format, one batch at a time, and wait for answers before the next batch. If there are more than six, ask the strongest six and tell the user the file likely needs a dedicated product review. Fewer than three: ask only those. Zero: print "No real product questions after closer reading" and go to the next file.

Keep a ledger for the whole run: a list of `(question → answer)` pairs, kept until the user types `stop`. Never ask what the ledger resolves, and never propagate an edit to a file the user skipped.

Done when: every question in the batch has an answer or the user gave none. Question to the user.

## Step 7: Apply the answers to code and docs

For each answered question:

| Answer | Code | Docs |
|---|---|---|
| a choice | make the code match: a small edit, or a larger one confined to this file and one or two close neighbours; use your file-edit tool with minimal context | add the rule in one or two lines in the doc's own voice and section; correct a doc that said otherwise |
| a choice with wider reach (several services, schema impact, new API shape) | put a precise `TODO(/interview-code): <change>` comment at the top of the file | as in the row above |
| a rule needing more than two lines of doc text | as above | put a precise `TODO(/interview-docs): <topic and decision>` at the end of the doc |
| "leave it" or "intentional" | nothing | nothing |
| off-menu ("neither, do X") | apply the user's wording verbatim when actionable; one follow-up question at most if it is ambiguous | same |
| you cannot tell which doc owns the rule | | ask once: "Which doc should this go in?"; still unsure: write it in the closest doc and add `TODO(/interview-docs): consider whether this belongs in <other doc> instead` |
| the answer contradicts the product brief | | stop and ask: "This contradicts the product brief. Update the brief or change the answer?" |
| the answer shows the whole file is wrong | stop editing, summarise what you heard | ask: "(a) refactor the file now, (b) leave a high-level TODO and continue, or (c) open a follow-up plan?" Default: (b) |

When an answer applies to other queued files, find them and ask once:

```sh
rg -l '<distinctive phrase from the old behaviour>' <queue directories> | head -n 20
```

"This answer also affects <files>. Apply the same edit there? (a) yes, (b) pick per file, (c) no, leave for their own rounds." Yes: copy the edit verbatim. Pick: ask per file. No: keep it in the ledger and apply when each file's turn comes. No answer: treat as (c).

After code edits, run the `<checks>` command for the language you edited. If it fails, fix the fallout before moving on. After schema file edits (`.sql .dbml .prisma .proto`), tell the user to run the schema check named in `<checks>`.

Done when: every answer is applied or left as a TODO, and the `<checks>` command exits 0 for what you edited. If it fails twice with the same error, stop and report the output.

## Step 8: Summarise the file

Print one line, then go to Step 4 with the next file:

```
[i/N] <path> — 5 questions across 2 batches, 4 applied, 1 left as TODO. Wrote N edits.
```

Do not restate the file's contents.

Done when: the line is printed.

## Step 9: End the run

This step is a summary; its only command is the project's `<checks>`. When the queue is empty or the user typed `stop`, print: files triaged, files skipped (with reasons), files interviewed, questions asked, edits applied, TODOs left. Then run the `<checks>` analyze command for every package whose code you edited, and suggest one commit message. Do not commit unless the user asks.

Done when: the summary and commit-message suggestion are printed.

## Done means

- Every interviewed file has its Step 8 line.
- The `<checks>` analyze command exits 0 for every package you edited.
- No commit was made.
