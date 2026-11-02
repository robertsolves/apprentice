---
description: Rewrite every agent prompt (commands, skills, subagents, rules) so a weak free coding agent can follow it — an exact command and a finish line in every step, decision tables, stop questions, fewer tokens — and fix whatever is broken for one of the CLIs that read them. Run after adding or editing several prompts, when cheap agents fumble a command, or as periodic hygiene. Not for measuring one change on one prompt — use /improve-prompts.
argument-hint: "[prompt file or name ...]"
---

# /improve-agent-prompts

This command scans every agent prompt against a written standard, then rewrites each one, worst first, so the cheapest agent that runs it gets exact commands, a finish line per step and no guesswork. It changes how a prompt is *written*, never what the prompt *does*. It runs unattended: it asks only at the stop points written into the steps.

Paths below assume the agent material lives in `.agents/`. If the repo has only `.claude/`, read `.claude/` wherever `.agents/` appears.

## Step 1: Load the standard and the project facts

```sh
cat .agents/skills/improve-agent-prompts/references/weak_agent_standard.md
rg -n -A3 'Agent prompts' AGENTS.md .agents/rules | head -n 30
```

The first file is the standard: rules R1–R16, each with the scanner code that flags it. The second command finds the project's **Agent prompts** facts: the wrapper command, the checks to run after editing prompts, the trial harness, the changelog command, and any project-specific prompt rules (for example a required closing step). Keep those facts in your notes; Steps 3, 5, 6 and 7 use them.

Done when: you have the standard's R1–R16 and the project's wrapper and check commands in your notes. If the second command prints nothing, stop and ask: "Where are this project's rules for agent prompts and the checks to run after editing one?"

## Step 2: Scan and pick the files

```sh
python3 -I .agents/skills/improve-agent-prompts/scripts/scan_agent_prompts.py
```

Each line is `<score> E<errors> <file> (<lines>): <code>×<count> …`, worst first. The last line is the baseline, for example `--- 118 prompt files, 52 clean, 4 errors`. Copy it into your notes.

Pick the files to work from `$ARGUMENTS`:

| `$ARGUMENTS` | Files to work |
|---|---|
| empty | every file the scan lists, top to bottom |
| a path to a prompt file | that file |
| a bare name | `.agents/commands/<name>.md`, else `.agents/skills/<name>/SKILL.md`, else `.agents/agents/<name>.md` |
| anything else | stop and ask: "Which prompt file is `<argument>`?" |

Skip generated files: a skill whose body only says to read `../../commands/<name>.md` is a wrapper, and Step 5 regenerates it.

Done when: your notes hold the baseline line and the ordered list of files.

## Step 3: Fix every ERROR first

ERRORs mean a file is broken for at least one CLI. List them:

```sh
python3 -I .agents/skills/improve-agent-prompts/scripts/scan_agent_prompts.py --errors
```

Each line is `<file>:<line> ERROR <code>: <what is wrong>`; the last is `--- <N> errors`.

| Code | Fix |
|---|---|
| `frontmatter` | Put `---` on line 1 and close the block with `---`. |
| `yaml-colon` | Wrap the whole value in double quotes; escape inner `"` as `\"`. |
| `description-long` | Cut to 1,024 characters or fewer, key use case first. |
| `name` | Make `name:` equal the folder (skill) or file (subagent) name. |
| `agent-tools-key` | Replace `tools:` with a `disallowedTools:` list of the tools it must not use. |
| `h1` | Make the first heading `# /<file name without .md>`. |
| `dead-path` | Find where it went: `git log --oneline -3 -- <path>` and `rg --files \| rg -i '<file name>' \| head -n 5`. Moved → cite the new path. Deleted on purpose → delete the sentence. No trace → stop and ask: "`<path>` is gone. What replaced it?" |
| `no-wrapper`, `wrapper-drift`, `wrapper-yaml` | Run the project's wrapper command (Step 1) for that name. |
| `wrapper-orphan` | Stop and ask: "The wrapper `<path>` has no command. Delete it?" |

Done when: the scan's last line reads `0 errors`.

## Step 4: Rewrite each file, one at a time

Work through your list in order. For each file, do 4a–4f before opening the next one.

**4a. Get its to-do list.** `python3 -I .agents/skills/improve-agent-prompts/scripts/scan_agent_prompts.py <file>`. Each line is `<file>:<line> WARN <code>: <what to change>`.

**4b. Read it and its neighbours.** Read the whole file. Then list the other prompts' descriptions so yours stays distinct: `grep -h '^description:' .agents/commands/*.md | cut -c1-180`.

**4c. Write down what must not change**, before editing anything. In your notes, list for this file:

- every file or folder it creates, edits or deletes, and where its output goes;
- every point where it asks the user, and what it waits for;
- every guard on a destructive or live action, and `disable-model-invocation` if set;
- the order of its side effects (scan before fix, ask before edit);
- its name, arguments, record locations, and any closing step the project requires.

**4d. Rewrite it** to R1–R16, working down the to-do list. Edit the file with your file-edit tool: never `sed -i` or `perl -i`, which turn symlinked files into diverging copies. For every command you add to a step, prove it works:

| The command… | Prove it by |
|---|---|
| only reads | running it and checking that its output matches what the step says it prints |
| writes, deploys, deletes, pushes or touches a live environment | `ls <script>` and `<script> --help` only; never run it |
| comes from another file in the repo | copying it from there exactly |

If a file is over its line budget, move whole reference sections (tables, long lists, background) to `.agents/skills/<name>/references/<topic>.md` and replace each one with `Read <path> § <heading>` in the step that needs it.

**4e. Re-scan the file.** Run 4a again. Done when it shows zero ERROR and every WARN left is one of these:

| WARN left | Allowed when |
|---|---|
| `step-no-command` | the step is pure judgement or a question to the user, and says so |
| `long-body` | the file is still smaller than before and every remaining section is needed during a step |
| `vague-word` | the word is quoted or part of a name, not an instruction |

Any other WARN left → fix it or stop and ask: "`<file>`: `<code>` at line `<N>` — I can't fix this without changing what the command does. Leave it?"

**4f. Check the diff against 4c.** `git diff --stat -- <file>` then `git diff -- <file> | head -n 200`. Every item in your 4c list must still hold. If one does not, put that part back the way it was.

If your CLI can run subagents, you may hand out 4a–4f with one file per subagent and at most four at once. Paste this brief, filled in: "Rewrite `<file>` to the standard in `.agents/skills/improve-agent-prompts/references/weak_agent_standard.md`. Follow Step 4 (4a–4f) of `.agents/commands/improve-agent-prompts.md` exactly. Edit only `<file>` and new files under its skill folder's `references/`. Reply with the 4c list, the remaining WARNs with reasons, and `git diff --stat`." Then run 4f on each result yourself.

## Step 5: Make the neighbours agree

```sh
git diff --name-only -- .agents | head -n 100
git diff -U0 -- .agents/commands .agents/skills | rg '^\+(description|name):' | head -n 60
```

1. For every command whose `description` changed, run the project's wrapper command (Step 1) with its name.
2. Read the changed descriptions together. If two could both match one request, add `Not for <case> — use /<other>` to each description. Never add a cross-reference to a body: an agent may open everything a body names.
3. If you wrote the same rule into two files, keep it in the one that owns it and cite that file from the other.

Done when: the scan shows no `wrapper-drift` or `no-wrapper`, and no two descriptions claim the same request.

## Step 6: Run the checks

```sh
python3 -I .agents/skills/improve-agent-prompts/scripts/scan_agent_prompts.py | tail -n 1
git status --short | grep '^ T'
```

Then run every check the project facts list (Step 1). The scan's last line must show `0 errors` and at least as many clean files as the baseline. The `grep '^ T'` must print nothing (a `T` means a symlink became a plain file: restore it with `git checkout -- <path>` only if you changed it in this run). If a check fails on a file you edited, fix it and run it again; if it fails twice with the same error, stop and report the output.

Done when: every check passes.

## Step 7: Try the riskiest changes on a weak agent

```sh
rg -n -i 'trial|harness' AGENTS.md .agents/rules | head -n 5
```

If the project facts name a weak-agent trial harness, list its tasks, then pick at most two commands you changed that have a task. Run each task once on the edited tree, using the harness's own commands from the project facts (take a fresh snapshot first). Report each check's `PASS` / `FAIL` line. A `FAIL` you can trace to your rewrite (the agent misread a step you changed) → fix that step and rerun once. If the project has no harness or no matching task, write `trials: none available` in the report.

Done when: each picked task has a recorded result, or the report says why there is none.

## Step 8: Report

Reply with this shape, filled in, and write it nowhere else:

```text
improve-agent-prompts: <N> files rewritten, <M> skipped
scan before: --- 118 prompt files, 52 clean, 4 errors
scan after:  --- 118 prompt files, 97 clean, 0 errors
moved to references/: <file> → <reference>, …
left as is (with reason): <file>: <code> — <reason>
trials: <task> PASS 4/4 · <task> FAIL has_summary (traced to Step 3 wording, fixed, rerun PASS)
checks: <each project check> ok
```

Then add one changelog line with the project's changelog command (Step 1): `Agent tooling: /improve-agent-prompts rewrote <N> prompts for weak agents`.

Done when: your reply holds every line of the block above, filled in, and the changelog command exited 0.

## Done means

- `python3 -I .agents/skills/improve-agent-prompts/scripts/scan_agent_prompts.py | tail -n 1` prints `0 errors`, with at least as many clean files as the baseline.
- `git status --short | grep '^ T'` prints nothing.
- Every project check from Step 1 passes.
- For every edited file, the 4c list still holds in its diff.
