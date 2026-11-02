# Writing agent prompts a weak agent can follow

The standard every command, skill, subagent and rule file is written to. `/improve-agent-prompts` rewrites prompts to it, and the `command-authoring` skill writes new ones to it. Each rule names the scanner code that flags it (`scan_agent_prompts.py`, beside this folder); rules with no code need judgement.

## Contents

1. Who we are writing for
2. The rules (R1–R16)
3. Spending tokens well
4. Cross-tool rules (the spec)
5. Worked example: one step, before and after
6. Sources

## 1. Who we are writing for

The reader is the cheapest agent that will run the prompt: a free model behind OpenCode, Kilo or a similar CLI, with a small effective context, no memory of this project, and no instinct for what "the usual check" is. What such agents do, in rough order of cost:

- **They skip.** Middle steps of long prompts, the *condition* half of a conditional rule, and anything stated once far from where it applies (AgentIF: under 30% of real agent instructions fully followed even by the best model; condition and tool constraints are the weakest).
- **They invent.** A step that says what to find but not how gets a made-up command, flag or path. A file they did not read gets imagined contents.
- **They claim.** "Done" without running the check; a summary in place of the output shape asked for.
- **They wander.** Extra files written (a trial here wrote `dart_review_report.md` despite "no new files"), edits outside scope, or the same failing command retried in a loop.
- **They drown.** Whole files and uncapped greps fill the window, and the task falls out of it (the same trial spent 200k input tokens on one 120-line file).

Strong models cope with a vague prompt; weak ones fail on it, and a strong model loses nothing from a precise one. So write for the weak one.

## 2. The rules

**R1. The description decides selection.** It leads with the verb, says what it does, then `Run when …` / `Use when …` with the literal phrases and paths that should trigger it, then `Not for … — use /other`. Two prompts whose descriptions overlap will be confused. (`no-trigger`, `no-description`, `description-long`)

**R2. The body names only what the agent acts on.** Every command, file, doc or tool named in a body is something a weak agent may go and open, so a mention that no step uses costs a lookup and pulls the run off course. No "see also", no "for X use /other", no history of where a rule came from. Telling neighbours apart is the description's job (R1); once the agent is in the body it has already chosen. (`body-handoff`)

**R3. One action per step, in execution order.** `## Step N: <verb> <object>`, numbered 1, 2, 3 with no gaps. A step that does two things becomes two steps. No list nested three deep: flatten it. (`step-heading`, `step-order`, `deep-nesting`)

**R4. Every step gives the exact command.** Copy-pasteable, from the repo root, with every flag, in a fenced block. Prefer a script the prompt owns over a pipeline described in prose: the agent runs it and reads a short output, and the script cannot be misremembered. Name the action, never one CLI's tool name (`edit the file`, not a named tool such as `TodoWrite`). (`step-no-command`, `harness-tool`)

**R5. Every step says what proves it done.** The output it must print, the exit code, or the file that must exist (`Done when: the last line reads "0 errors"`). An agent with no finish line either skips the step or never stops. (`step-no-proof`)

**R6. Decisions are tables with a default.** Any choice made more than once is a two-column table (`situation → action`), ending in `anything else → stop and ask: "<the exact question>"`. Never offer more than three options at once. No vague words where a rule belongs: `appropriate`, `as needed`, `if relevant`, `where possible`, `properly`, `etc.` each hide a decision the agent cannot make. (`vague-word`)

**R7. Repeat a prohibition where it bites.** A "never" stated once at the top is gone by Step 6. Put it in the step it applies to, phrased as the action to take (`Write findings in your reply, not to a file`), with the expensive negative only where the mistake costs real damage.

**R8. Name files, not "the doc that owns X".** Each hop of indirection is a search a weak agent may never finish. A project-scoped prompt names the path. A generic prompt (one meant to work in any repo) names one project-facts file and the exact heading in it, and that heading holds copy-paste commands, not prose.

**R9. Stop conditions are observable.** "If unsure, ask" never fires. Write the situation and the question: `If the scan prints ERROR for a file you did not edit, stop and ask: "<file> was already broken — fix it too?"`. And cap retries: `If a command fails twice with the same error, stop and report the output.`

**R10. Scope the writes.** Say exactly which files the prompt may create or edit. A read-only prompt says so in the step that produces output, and names where the output goes (the reply, or one named file).

**R11. Show the output shape.** A report, summary or record entry is shown as a filled-in example block, not described. Agents copy the example's shape (and its words, so keep examples neutral).

**R12. One worked example for the step agents miss most.** About ten lines: input, the commands run, the output seen, the decision taken. Use one only where a trial or review showed the step being missed; examples cost tokens every run.

**R13. End with `## Done means`.** The make-or-break commands repeated verbatim with their expected output, so the agent's last act is to check rather than claim. (`no-done-means`)

**R14. Arguments are explicit.** Use `$ARGUMENTS` only (`$1` is 0-based in Claude Code and 1-based in OpenCode), and say in Step 1 what happens when it is empty: a default, or a stop. (`arguments`, `positional-arg`)

**R15. Every cited path exists.** A dead path sends a weak agent searching for something that is not there. In a generic prompt, an example path is written `<placeholder>`-style so it cannot be mistaken for a real one. A path the prompt itself creates is marked `(created on first run)`. (`dead-path`, `example-path`)

**R16. One term per concept.** Pick one word (`record`, not record / log / ledger / tracker) and use it everywhere in the prompt and its neighbours.

## 3. Spending tokens well

Precision is not length. Cut what the agent already knows; keep what it would have to guess.

- **Budgets.** Command body ≤ 200 lines; genuine skill body ≤ 150 lines; anything longer moves to `references/<topic>.md` beside the prompt, one level deep, loaded by the step that needs it. A reference over 100 lines opens with a `## Contents` list. (`long-body`, `no-toc`)
- **Scripts over prose** for anything mechanical: finding files, comparing lists, counting, checking a format. Only the script's output enters the context, never its code. A scan script prints one labelled section per step and caps its output.
- **Capped reads.** Every search has a cap (`rg -l`, `--max-count 3`, `| head -n 40`, `| head -c 4000`). Read line ranges, not whole files, when the prompt knows where to look. (`uncapped-search`)
- **Cite, don't restate.** A rule another file owns is cited by path and heading, never copied (copies drift). The exception is a rule the agent needs mid-step: repeat its one-line action there (R7).
- **No inventories.** File lists, route maps and test lists that a command can print at run time are a command, not a list.
- **Where terseness hurts.** Never cut the exact command, its expected output, the condition of a rule, or a stop question. Cut background, history, motivation essays and restated rules.

## 4. Cross-tool rules (the spec)

The same files are read by Claude Code, Codex, OpenCode, Kilo, Gemini CLI and others. Checked against the official docs 2026-10-29.

- Frontmatter starts on line 1 with `---`, or the file has no frontmatter at all (a subagent without it is silently skipped). (`frontmatter`)
- Frontmatter is strict YAML: a value containing `: ` is wrapped in double quotes, or Gemini CLI drops the file. (`yaml-colon`)
- `description` is at most 1,024 characters (Agent Skills spec; Claude Code truncates the listing at 1,536), key use case first. (`description-long`)
- A skill's `name` equals its folder name: 1–64 lowercase letters, digits and hyphens. A subagent's `name` equals its file name. (`name`)
- A subagent restricts tools with `disallowedTools:`, never a `tools:` list (OpenCode deprecates or rejects it). (`agent-tools-key`)
- No `model:` on a shared command or subagent: Claude Code takes an alias, OpenCode a `provider/model` id, and no value works in both. (`model-key`)
- A command's first heading is `# /<file name>`. (`h1`)
- In a repo that wraps commands as skills, every command has its wrapper and every wrapper's description matches its command's. (`no-wrapper`, `wrapper-drift`, `wrapper-orphan`, `wrapper-yaml`)
- A rule file carries a `paths:` glob unless it truly applies to every session. (`rule-no-paths`)

## 5. Worked example: one step, before and after

Before (what a weak agent gets wrong: no command, no output, no finish line):

```markdown
## Step 2: Find unused code
Look through the packages for code nothing references, using the project's tools where possible.
```

After:

````markdown
## Step 2: List unreferenced symbols

```sh
bash scripts/find_unused.sh | head -n 60
```

Each line is `path:line Symbol`. Done when: the output ends with `--- N candidates`.
If it prints `no packages found`, stop and ask: "Which folder holds the code?"
Write the candidates in your reply. Do not create a file for them.
````

## 6. Sources

- AgentIF, agent instruction following: https://arxiv.org/abs/2505.16944
- Lost in the Middle: https://aclanthology.org/2024.tacl-1.9/
- Instruction count vs compliance (SCALEDIF): https://arxiv.org/pdf/2510.14842
- Weak agents re-invoking tools without progress: https://arxiv.org/pdf/2602.12984
- Anthropic, skill authoring best practices: https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices
- Claude Code skills and commands: https://code.claude.com/docs/en/skills.md · subagents: https://code.claude.com/docs/en/sub-agents.md
- OpenCode agents and commands: https://opencode.ai/docs/agents/ · https://opencode.ai/docs/commands/
- Gemini CLI custom commands: https://geminicli.com/docs/cli/custom-commands/
