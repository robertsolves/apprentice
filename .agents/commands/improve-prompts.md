---
description: Improve a project's prompts as a controlled experiment — the app's AI generation prompts, or its agent prompts (commands, skills, rules, subagents) so that weak free coding agents can follow them. Measure a baseline batch, review it blind, state one falsifiable hypothesis, change one thing in a new version, rerun the same inputs, decide by a rule fixed in advance, log the result, and adopt with the owner's confirmation. Run when asked to make AI generation better, or when cheap agents keep fumbling a command. Not for rewriting every prompt to the writing standard — use /improve-agent-prompts.
argument-hint: "[kind | command-name] [input…]"
---

# /improve-prompts

You run the project's prompt tool; the owner watches the results. Every change to a prompt goes through that tool, one experiment at a time: a baseline first, one hypothesis written down before the rerun, one change per version, the same inputs rerun, a decision by a rule fixed before you look, a log entry for every result, and adoption only on the owner's yes.

Two kinds of target, one method:

- **App prompts**: what the app sends its AI model to generate output for users. A run is one input through the real production pipeline.
- **Agent prompts**: the commands, skills, rules and subagents coding agents follow in this repo. A run is one weak agent (a free model behind an open-source coding CLI) carrying out one command on a planted task in a throwaway copy of the repo, scored by fixed pass/fail checks plus a blind review. The aim is a prompt the weakest agent still gets right; a strong agent then gets it right too.

Paths below assume the agent material lives in `.agents/`. If the repo has only `.claude/`, read `.claude/` wherever `.agents/` appears.

## Step 1: Pick the target

Take the first word of `$ARGUMENTS` as `<target>` and the rest as `<input>`. Check whether `<target>` is a prompt:

```sh
ls .agents/commands/<target>.md .agents/skills/<target>/SKILL.md .agents/agents/<target>.md .agents/rules/<target>.md 2>/dev/null | head -n 4
```

| Situation | Target |
|---|---|
| `$ARGUMENTS` is empty | stop and ask: "Which app output kind, or which prompt (command, skill, rule, subagent), should I tune?" |
| the `ls` prints a path | agent prompt `<target>` |
| the `ls` prints nothing | app output kind `<target>` (Step 2 confirms it is a kind) |

`<input>` given → **demo**: one run on `<input>`, not an experiment. `<input>` empty → **experiment** on the target's review set.

Done when: your notes say the target, its type (app or agent) and the mode (demo or experiment).

## Step 2: Load the project's prompt tooling

```sh
rg -n '^- \*\*(Prompts|Agent prompts)\*\*' .agents/project-facts.md | head -n 5
```

It prints two bullets. **Prompts** names `<guide>` (the tuning guide for app prompts, or the trial-harness guide for agent prompts) and where the lab and experiment log live. **Agent prompts** gives the harness commands, the wrapper and check commands to run after editing a prompt, and the changelog command. Then list the guide's headings and run the tool's own help once:

```sh
rg -n '^#' <guide> | head -n 60
<tool> --help | head -n 60
```

Read the guide sections those headings point to, by line range, never the whole file. Read `.agents/skills/improve-prompts/references/experiment_guide.md` § Facts to write down, and write each of its notes (`<tool>`, `<log>`, `<show>`, `<pair>` and the rest, used by every later step) as an exact command or path, copied from the guide as written; never improvise one.

Done when: every row of that table for your target's type holds a command or path in your notes. If a row stays empty, or the project has no such tool, stop and tell the owner: "The project facts don't say `<missing fact>`. Where is it?" Change nothing until they answer. If `<target>` is not one of the app kinds, stop and ask: "Is `<target>` an app output kind or a prompt name?"

## Step 3: Set up

Note the current prompt version and check the sign-in, with the guide's commands. Then read the earlier experiments on this target before you form any hypothesis (`<KIND>` is the app output kind, or the command name):

```sh
ls <log>
grep -n '^## E' <log> | tail -n 5
grep -A8 '^## E.* <KIND>' <log> | head -n 40
```

| Situation | Action |
|---|---|
| `ls` prints `No such file` | no earlier experiments; Step 5 starts the log (created on first run) |
| the sign-in check fails | stop and ask the owner to sign in with the guide's command, or to allow the fallback model; run nothing until they answer |
| you run on a fallback model | a fallback is a different variable: never compare a batch made on it with one made on the production model, and say so in Step 11 |

Done when: your notes hold the current version, `signed-in` (or the fallback's name), and the last `## E<N>` number (or `none`).

## Step 4: Measure the baseline

| Mode and state | Action |
|---|---|
| demo | run `<run-one>` on `<input>`; tell the owner the run id and how to see it; offer the full loop on the target's review set (its planted tasks, for an agent prompt). Stop until the owner answers. |
| experiment, and a reviewed batch on the current version covers this kind's whole review set | that is the baseline: save its run ids as a batch and go to Step 5's count |
| experiment, otherwise | generate the review set on the current version with `<fill>`, several at a time in the background, collect the run ids into the batch, and rerun every input that failed (a sign-in hiccup is not a result) |

For an agent prompt, take a fresh snapshot first (a trial copies the working tree as it is now), then fill a batch with every task for the command, 3 runs each:

```sh
<tool> snapshot
<tool> tasks
<tool> fill <batch> <task> [<task> ...]
```

Every trial runs on the free model: never pass `--paid` (the one exception is Step 9's strong-model check, after the owner's yes). A command with no task gets one before any experiment: Read `.agents/skills/improve-prompts/references/experiment_guide.md` § Writing a planted task. Never write a task for, or trial, a command that touches a live environment.

Done when: the batch's run-id list has one id per review-set input (3 per task for an agent prompt) and no input is left failed.

## Step 5: Review and count the baseline

```sh
<show> <run>
<scorecard>
<tag-tally> <batch>
```

1. **Review every run** in the project's two-line shape: a rating (`good`, `ok` or `poor`) with a short reason, then the problem tags. Read a run only through `<show>`; never dump its raw records, and pull a single field out of a recorded call with a cap (`| head -c 3000`). Reuse an existing tag before inventing one. Save each review with `<review>`.
2. **For a batch, use one reviewer subagent on a cheap model.** Brief, filled in: "Review runs `<run ids>`. Read each with `<show> <run>` and ignore which prompt version it used. Write each review in this shape: `<review shape>`. Reuse these tags: `<tag list>`. Reply with one line per run, `<run> <rating> <tags>`, nothing else."
3. **Look for the cause in the recorded calls** before you blame a prompt: the runs the pipeline had to repair or re-ask, the reasons it rejected the model's answers (counted), and what the model was sent and answered in a few bad runs. A dropped field or lost entry may be a code bug, and an automatic answer in the harness may have invented a fact. Grep before you read, then read only the matching lines.
4. **Count, don't read**: run `<scorecard>` and `<tag-tally>`; open single runs only to check a count. Re-review every run the scorecard shows with no rating.

For an agent prompt, the checks come first (`<tool> score <batch>` counts them); the review explains them. In each run read the tool log before the reply: where the agent went off the path is usually a step earlier than where it failed. Tags to reuse: Read `.agents/skills/improve-prompts/references/experiment_guide.md` § Review tags for agent prompts.

Append the entry's first two lines (`## E<N> …` and `baseline: …`, shape in Step 6) to `<log>` now.

Done when: every run in the batch has a rating and tags, the scorecard shows no unrated run, and `<log>` ends with the `baseline:` line.

## Step 6: State the hypothesis

Pick the tag that costs the most: in the most runs, or the one that makes the output unusable. Read `.agents/skills/improve-prompts/references/experiment_guide.md` § Where the fix goes and § What weak agents trip on, and take the first row that fits. A code bug or a broken reference is not a prompt experiment: fix it, then rerun Step 4 for a clean baseline.

Find the rule that already exists before you write a new one. Grep the copy the tool keeps for each prompt version; never read the prompt source in the code whole. If outputs repeat a phrase, count how many contain it and find where in the prompts it comes from (an example in a prompt gets copied):

```sh
rg -n -i '<phrase>' <version folder> | head -n 20
rg -l -F '<copied phrase>' <runs folder> | wc -l
```

Read the guide's lessons, then finish the entry in `<log>` (number one past the last `## E` line):

```text
## E<N> <yyyy-mm-dd> <KIND>: <the question, one line>
baseline: <version>, batch <batch>, good/ok/poor <g>/<o>/<p>, <TAG> in <n>/<total>
evidence: <2-3 run ids>; <what the recorded calls showed>
hypothesis: <cause>. Changing <file> to <the rule> will bring <TAG> to at most <m>/<total>.
prediction: <TAG> ≤ <m>/<total>, paired worse ≤ noise, no new tag in 3+ runs
```

For an agent prompt, the baseline and result lines also carry the check pass rates from `<tool> score` and `<tool> pair`.

Done when: `grep -n '^## E' <log> | tail -n 1` prints your entry's header, and the entry holds all five lines.

## Step 7: Make the new version

```sh
<new-version> "E<N>: <the one change>"
<diff> <version>
```

- App prompts: edit the files in the new version's folder.
- Agent prompts: a version holds edited copies of repo files, tied to the snapshot it was made on. Add each file first (`<tool> version add <vN> <repo path>`), then edit the copy the tool names, never the repo file.

Edit with your file-edit tool, never an in-place stream edit (`sed -i`, `perl -i`), and keep structured files valid. The diff must show only the one change: two changes in one version means you cannot tell which did what. If the tool drafted the version with AI, check that its diff holds one change only, and split it if not.

Show the owner the diff and the hypothesis, then stop: make nothing current and rerun nothing until the owner says go.

Done when: `<diff> <version>` shows exactly the one change and the owner has answered.

## Step 8: Rerun and compare

Only with the owner's go-ahead from Step 7.

```sh
<make-current> <version>
<rerun> <baseline batch> <new batch>
<pair> <baseline batch> <new batch>
```

1. **Rerun the same inputs**: make the new version current, then rerun every run of the baseline batch into a new batch (same input and seed; the model still varies). Agent prompts: same tasks, model, CLI and snapshot as the baseline, only the version differs, 3 runs per task (5 when the result is close); free model only, never `--paid`.
2. **Review blind**, as in Step 5, by a subagent that has not seen the hypothesis, the diff or the baseline reviews.
3. **Measure the noise** on the first experiment for a kind (for every command, for agent prompts: a weak agent varies a lot), or when the result is close: rerun the baseline batch again on the baseline version, review it blind, and switch back. Nothing changed, so every "worse" in its paired comparison is noise. Write that number into the log as `noise:`; later experiments on the kind reuse it until the model changes.
4. **Compare**: the tag tallies, old batch beside new, and `<pair>` (each input against itself, per task and per check for agent prompts; the main number). Read every run that got worse beside its baseline run. Re-review any pair with no rating on one side.

Done when: `<pair>` prints better / same / worse counts with no unrated pair, and your notes hold the noise number (or `not measured`).

## Step 9: Conclude

Apply the rule, with no adjustment after seeing the numbers:

| Result | Verdict and action |
|---|---|
| the target tag met the prediction, paired worse ≤ noise (no noise measured: at most one run in ten), and no new tag in 3+ runs | **SUPPORTED**: keep the version |
| the target tag did not move, or the batch got worse overall | **REFUTED**: `<make-current>` the baseline version again and `<discard>` the new one |
| anything between | **INCONCLUSIVE**: run Step 8 items 1 and 2 once more on the new version and decide on both runs together; still between → REFUTED |

Finish the entry in `<log>`. Log every result, failures included: a refuted hypothesis stops the next session trying the same thing.

```text
change: <version>, batch <new batch>
result: <TAG> <n>→<n'>/<total>; good/ok/poor <g>/<o>/<p>; paired better <b> / same <s> / worse <w>; noise: <w0 or "not measured">
conclusion: SUPPORTED | REFUTED | INCONCLUSIVE. <one line on what was learned>; next: <the next tag or idea>
```

A supported version becomes the baseline of the next experiment. Run as many experiments as the owner wants, one at a time (Steps 6 to 9), then adopt the last supported version once.

For an agent prompt, before adopting, run the version's batch once on a paid, stronger model against the same batch on the old version, only after the owner says yes (it costs money; this is the one run that passes `--paid`). A change that helps the weak agent must not lose a check for the strong one: a lost check means the version is not adopted as it is.

```sh
grep -A8 '^## E<N> ' <log> | head -n 12
```

Done when: that command prints the entry with its `change:`, `result:` and `conclusion:` lines.

## Step 10: Adopt, only on the owner's explicit go-ahead

Unless the owner already asked for the work to be finished unattended, stop and ask: "E`<N>` is SUPPORTED. Adopt `<version>`?" Change nothing until they answer.

```sh
<adopt> <version>
git diff --stat | tail -n 5
```

1. Check for other sessions editing the prompt files, as the guide says.
2. Adopt with `<adopt>`. For an agent prompt the tool refuses if another session changed the same files since the snapshot: merge their edits into the version and rerun, never overwrite them.
3. Do the guide's clean-up after adopting, run its analyze and test commands, and name any pre-deploy gate the change must pass.
4. For an agent prompt, regenerate any wrapper made from the prompt's description and run the checks, both with the commands in the **Agent prompts** bullet.
5. Record the change where the guide says changes go (the changelog command), and copy each SUPPORTED or REFUTED lesson that holds beyond this kind into the guide's lessons list, one line each.

If a check fails twice with the same error, stop and report its output.

Done when: every analyze, test and prompt check passes, and the changelog command exited 0.

## Step 11: Report

```sh
grep -A10 '^## E' <log> | tail -n 40
```

Reply with this shape, one block per experiment, filled in from the log; write it nowhere else:

```text
E<N> <KIND>: <hypothesis, one line>
baseline: <version>, batch <folder>, good/ok/poor <g>/<o>/<p>, <TAG> <n>/<total>
result:   <version>, batch <folder>, good/ok/poor <g>/<o>/<p>, <TAG> <n'>/<total>; paired better <b> / same <s> / worse <w>; noise: <w0>
conclusion: SUPPORTED | REFUTED | INCONCLUSIVE. <what was learned>
adopted: <version> | nothing, because <reason>
model: production | fallback <name> (not comparable with production batches)
```

Done when: your reply holds one filled block per experiment run this session.

## Done means

- `grep -n '^## E' <log> | tail -n 1` prints this session's last entry, and it holds `baseline:`, `hypothesis:`, `prediction:`, `change:`, `result:` and `conclusion:` lines.
- No version was made current, rerun or adopted before the owner's go-ahead (Steps 7, 8 and 10).
- Every trial ran on the free model; `--paid` was passed only for Step 9's strong-model check, after the owner said yes.
- After an adoption, the guide's analyze and test commands pass, plus the **Agent prompts** checks for an agent prompt.
