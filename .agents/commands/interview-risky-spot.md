---
description: Interview-style review. Picks one risky spot in the codebase and asks targeted Socratic questions to surface mismatches between what the code does and what you actually wanted. Run when asked to sanity-check vibe-coded code, "does this code do what I meant", or to interview me about a risky file. Read-only, one file per run. Not for walking every source file — use /interview-code.
argument-hint: "[path or area to focus on] (default: auto-pick from risk signals)"
allowed-tools: Read, Bash, Glob, Grep
---

# /interview-risky-spot
A read-only, conversational sanity check. It confirms the code does what the user intended, not just what looked plausible at the time. It does not grade or refactor: it surfaces assumptions the user made implicitly so they can confirm them or spot a mismatch.

Rules for the whole run:

- Works on any language. One file or function per run; coverage comes from running it again.
- Read-only. Edit nothing, create no file. The output is the conversation plus one summary in your reply.
- Ask, don't lecture. No fixes or best-practice talk mid-interview.

## Step 1: triage scan

If `$ARGUMENTS` is a path, skip to Step 2 with that path. Otherwise run these from the repo root (judgement: drop any that do not fit the project, and stop once you have enough signal):

```sh
git log --since="3 weeks ago" --name-only --pretty=format: | grep -v '^$' | sort | uniq -c | sort -rn | head -n 20
git grep -n -E '(TODO|FIXME|HACK|XXX|kludge)' | head -n 40
git grep -l -E '(fetch\(|http\.|requests\.|sql|firestore|stripe|webhook|migration)' | head -n 30
git ls-files | grep -E '\.(ts|tsx|js|py|go|rs|dart|swift|kt|java|rb)$' | head -n 3000 | xargs wc -l | sort -rn | head -n 10
```

Meaning: (1) files churned most recently, (2) confessions, (3) integration boundaries (auth, payment, db, parsing, queues), (4) the largest files. If there is no git history, skip the first.

Done when: you have written a one-paragraph triage summary naming the scans run, what stood out and what was quiet.

## Step 2: pick ONE area

Judgement, no command. Pick one file, ideally one function in it, that stacks the most signals. State the pick in one short paragraph:

> Focusing on `src/auth/session.ts`. It changed 11 times in 3 weeks, has a `// FIXME: figure out refresh race`, and is the only caller of the token refresh endpoint.

| Situation | Action |
|---|---|
| `$ARGUMENTS` is a path | pick it; state it, skip the reasoning |
| Nothing stood out | widen the scan once (older history), else pick the largest file in the most business-critical directory |
| You cannot read the file's language fluently | stop and ask: "I can't read this language well. Can you summarise what `<file>` does before we start?" |

Done when: your reply names one path and the reason.

## Step 3: read the picked area

Read the file. If it is over 500 lines, read only the function or section the signals point to, using a line range.

```sh
wc -l <file>
```

Build a private model, and do not share it with the user yet: what it does step by step, what it assumes about inputs and callers, where side effects land (db, network, state, files), where errors come from and what happens to them, and what the user sees.

Done when: you can say, for each point above, one line about this code.

## Step 4: interview

Judgement and conversation, no command. Ask 3 to 7 open-ended questions, **one at a time**: ask one, stop, wait for the answer, then decide on a follow-up (vague or surprising answer) or the next question. Never ask two questions in one message.

Question shapes:

- **Intent.** "What is this function supposed to do, in one sentence, in your words?"
- **Edge cases.** "What should happen if `userId` is empty, null, or belongs to a deleted account?"
- **Failure.** "If the network call on line 42 times out, what does the user see, and what state is the system left in?"
- **Ordering.** "Two requests arrive together: does it matter which wins?"
- **Assumptions.** "This code assumes X. Is that always true, or most of the time?"
- **Ownership.** "Who else reads or writes this state? Can anything change it between line 50 and line 60?"
- **Reversibility.** "If this runs by mistake, can you undo it? Should you be able to?"
- **Why this.** "You picked approach A. Was B considered? What made A right?"

Never ask: leading questions ("shouldn't you add a null check?"), yes/no questions that close the topic, quiz questions you already know the answer to. Be curious and collaborative; the user is the domain expert.

| Situation | Action |
|---|---|
| ~5 questions asked and the answers are coherent | go to Step 5 |
| The user says they are done or "wrap it up" | go to Step 5 |
| A clear mismatch surfaced and the user wants to act on it | go to Step 5 |
| The user gives no answer to a question | do not touch the code; go to Step 5 and list it under Open questions |

Done when: the interview ended by one of the first three rows above, or the user gave no answer.

## Step 5: summarise

Write this in your reply, not to a file. Cap each section at 5 entries; keep the most important.

```
# Interview Summary

**Area:** <file path, function name if applicable>
**Picked because:** <one line>

## Confirmed correct
- <thing the user described that matches what the code does>

## Possible mismatch
- <thing the user described that does NOT match the code>
  - You said: <quote or paraphrase>
  - The code does: <one line>
  - Suggested follow-up: <one line>

## Open questions
- <thing the user was unsure about>

## Suggested next step
<one of: "Nothing: code matches intent." / "Worth fixing X in <file>." / "Worth a deeper look at <related area>: rerun /interview-risky-spot there." / "Worth writing a test that captures the intent you described.">
```

Done when: the reply contains all four sections and the next-step line.

## Done means

- No file was edited or created. Check: `git status --short | head -n 20` shows nothing you caused.
- The user answered every question one at a time, or the unanswered ones are under Open questions.
- The reply ends with the `# Interview Summary` block.

Never: edit or write source files (if you reach for an edit tool, abort); grade the code ("quality score", "overall assessment"); roam to a second area.
