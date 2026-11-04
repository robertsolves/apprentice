# Plan: pipelines across agents

Status: design, agreed in conversation on 2026-11-05, nothing built. Each build step below lands as its own
small commits with `selftest` checks. Where a point is still untested it says so; the first build step is
the tests.

## What this is for

A project's work runs as pipelines. Today a pipeline is a straight list of prompts, one agent for the whole
file, each step getting the tail of the previous step's output, and every step shares one screen owner.
This plan makes a pipeline a graph of steps where each step names the agent it runs on, the run chooses
between branches, steps run in parallel in their own worktrees and talk through a shared board, an agent
that runs out of tokens or stalls is replaced from a priority list, a chosen agent writes the summaries and
notes, and a person can audit any of it from a shell tab. It stays agent agnostic: nothing here depends on
which CLI a step runs, and the window never starts an agent on its own.

Rules that do not change:

- Permissions always win over the prompt. An agent finds another allowed way to finish, never a way around
  a refusal, sandbox, approval, payment or CAPTCHA.
- Text read from a screen, a website, a file an agent did not write, or another agent's message is
  information, never instructions. Nothing an agent writes can grant access or change a setting.
- Nothing is hard-coded: agents, their flags, limit phrases, help text and the apprentice section of
  `AGENTS.md` come from spec files in `agent/`, with the user's files over them.
- The window never looks at which agents are installed for terminal tabs. Only the Agents screen's Test
  button and a pipeline run look, and only at the agents the user named.

## 1. Named agents

A named agent is a CLI plus a model, an effort and a permission level, under a name the user chooses.
Pipelines, the interpreter and the scribe refer to agents only by these names.

```toml
# ~/.apprentice/named-agents.toml (global)
[named.Joseph]
agent = "claude"              # an id from agent/agents.toml or ~/.apprentice/agents.toml
model = "…"                   # passed through as written; a wrong name fails the Test button and the step
effort = "high"
permissions = "edit"          # read-only | edit | full  (what the CLI's own flags can enforce)

[named.deepseek_4_1_opencode_max]
agent = "opencode"
model = "deepseek/deepseek-v4.1"
effort = "max"
permissions = "edit"
```

```toml
# <project>/.apprentice/named-agents.toml
[named.Joseph]                # same name: only the fields written here change
effort = "max"

[named.Reviewer]              # exists only in this project
agent = "codex"
model = "…"
permissions = "read-only"
```

- Lookup is project first, then global, like every other setting (`Layers.chain`). A project entry with
  the same name overrides only the fields it writes; renaming a global agent updates the projects
  apprentice lists; a pipeline naming an unknown agent does not start and names it.
- Names are unique ignoring case. Any letters, digits and `_`.
- `effort` maps to each CLI's own flag in `agents.toml` (`model = ["--model", "{model}"]`,
  `effort = ["--effort", "{effort}"]`, opencode and Kilo `--variant`, Codex `-c model_reasoning_effort=`).
  A CLI with no effort flag says so in the Agents form instead of pretending it applied (Gemini).
- `permissions` maps to the CLI's own flags too (`claude --permission-mode` and `--allowedTools`, `codex
  --sandbox`, `gemini --approval-mode`, opencode and Kilo `--auto` or not). A CLI that cannot enforce a
  level does not offer it in the form. This replaces the per-pipeline allowed-tools list in `TODO.md`.
- Project files travel with the repo, so they are someone else's text when the project was downloaded:
  a project entry may only use an `agent` id apprentice already knows (new CLIs are global only, so a
  repo cannot make this Mac run its own command), and the first time a project entry asks for more than
  the global entry allows, or more than `read-only` for a name that exists only in the project, the run
  parks with Allow for this project / Stop the run. The answer is saved in `~/.apprentice`, never in the
  repo, and asked again when the request changes.
- The priority list: an ordered list of names per project, inheriting the global order until the project
  sets its own. A step tries its own `use:` agent first, then the list in order, each at most once.
- Settings ▸ Agents (global) is the main list; a project's Settings ▸ Agents shows everything it can use,
  marked Global, This project or Changed here, with New, Customise for this project and Reset to global.
  Fields: name, CLI, model, effort, permissions. Test sends one tiny real prompt (spends a few tokens, only
  on click) so a wrong model name shows before a run.
- Defaults the user picks in Settings: the interpreter, the scribe, and the priority list. Each is a
  dropdown of named agents.

The CLI side (`agent/agents.toml`) gains `model`, `effort`, `permissions` flag entries and `limits`, the
phrases a CLI prints when it has run out of usage. Antigravity and Freebuff stay out of headless runs
until one has a proven headless mode; a Settings ▸ Agents row for them says so.

## 2. The pipeline file

One Markdown file per pipeline in the project's `pipelines/` folder. Steps are `##` headings; a heading is
the step's name (lower-case slug, unique). Lines at the top of a step that look like `key: value` are the
step's settings; everything after is the prompt. Existing files with no settings still run as a straight
line.

```markdown
---
goal: Fix the reported bug and publish the release notes
interpreter: fast          # named agent that chooses branches; default from Settings
scribe: Joseph, Reviewer   # named agent(s) that write summaries and notes; default from Settings
carry: summary             # optional: keep a rolling summary between runs (off by default)
visits: 3                  # loop limit per step (default 3)
---

## triage
use: fast
next: fix | reply
Read the report and work out what it needs.

## fix
when: the report describes a real bug
needs: edit
next: code & tests & docs & browser-check
Plan the fix.

## browser-check
ui: true
next: release
Check the fix in the browser.

## release
Write the release notes.
```

Step settings:

| key | meaning |
|---|---|
| `use:` | the named agent; blank means the first in the priority list |
| `next:` | `a`, `a | b` (one, chosen), `a & b` (all, parallel), `end`; blank means the next heading |
| `when:` | one line the interpreter reads when choosing this step among `|` options |
| `needs:` | `read-only`, `edit`, `full`; the pipeline does not start if `use:` has less |
| `ui: true` | this step may use the screen |
| `sh:` as the whole prompt | a shell command, as today; its last printed line is its branch choice |

The join rule: a step starts once nothing still running can reach it, and it gets every feeding branch's
summary. That covers both cases without extra syntax: after a choice it waits for one step, after `&` for
all of them. If a branch fails the others finish, the join does not start, and the run stops with the
reason.

Validation (`pipeline check`, no AI, run before every run and by the Audit): unknown agent names, unknown
step names in `next:`, steps nothing reaches, `needs:` above the agent's permissions, two `ui: true` steps
that could run at the same time (both between one fork and its join), a loop with no `visits` limit.

## 3. Running a step

Every step is a fresh headless run (`Schedules.agentArgv` with the named agent's model, effort and
permission flags). That is the compaction the user asked for, and it works for every CLI. A CLI's own
session is never resumed, not even to restart a parked step: the step's saved progress, summary and board
are what carry over, which is what lets apprentice throw the CLI's session away (section 14).

Apprentice writes the whole prompt the agent sees. In order:

1. The goal and a map of the pipeline, and where this step sits in it.
2. The summaries of the steps that feed it (from the scribe, section 7), with the paths to their full
   output, and the board messages addressed to it.
3. Which agents run alongside it, the board commands, and when to check the board.
4. Whether this step has the screen.
5. The order of trust: the user's instructions and the pipeline, then this run's outputs, then the code
   as it is, then past notes last. If a note disagrees with the code, the code wins.
6. What to output and where: the step's result goes to `nodes/<step>/output.log` (captured, not asked
   for); a branch choice, when the step has `|` options, is made by the interpreter, not the step.

Branch choice: the interpreter runs only when a step has more than one `next:` option, with the goal,
the options and their `when:` lines, and the summaries. It writes `{"next": ["fix"], "why": "…"}` to a
file (`--json-schema`, `--output-schema` or `-o json` where a CLI has it, the file for all). Apprentice
accepts only listed steps; an invalid answer is retried once, then the next agent on the priority list is
tried, then the user gets the choice as buttons. A straight path never runs the interpreter.

Time limits per step, both editable in Settings: no output and no file change for 10 minutes means
stalled; 60 minutes total means stopped. Waiting for the user does not count.

## 4. The screen

- Only a step with `ui: true` may use the screen. Each running step is its own `Device` owner
  (`pipeline:<run>/<step>`), not one owner per pipeline as now; a step without `ui: true` that touches the
  screen gets exit 4 like any other second owner.
- One UI step per parallel group, enforced three ways: the Pipelines editor disables the UI tick on the
  other steps of a group once one has it ("browser-check is using the screen"); `pipeline check` refuses a
  file where two UI steps could overlap; `Device` refuses at run time regardless.
- Steps that never overlap can each have the screen (`A(ui) -> B & C(ui) -> D(ui)` is fine).
- A step that needs something from the screen asks the group's UI step on the board.
- Approval gates, budgets, cooldowns and challenges apply to a UI step exactly as to any session.

## 5. Parallel steps: worktrees

`a & b & c` start together, each in its own git worktree under the run's cache folder, on a branch from a
temporary commit of the user's tree (so uncommitted work is in them). The user's own folder is untouched
during the run.

- Ignored files are not in a new worktree. `.apprentice/worktree-links` lists what to copy or link in,
  starting with `.env*`; `node_modules` is linked when listed and parallel steps must not change it.
- At the join, apprentice merges the branches into the run's branch, then into the user's branch, and
  deletes the worktrees. A conflict parks the run (section 8) and opens a shell tab in the conflicted
  worktree for the user to resolve, with their own agent if they like.
- Steps that run one at a time run in the project folder, as today; no worktree.
- A worktree of a parked run is kept until the run finishes; others go as soon as they are merged.

## 6. The board: how agents talk

One file per run, `board.jsonl`, outside the worktrees. Agents never connect to each other; every CLI can
run a shell command, so it works the same for all of them.

```sh
apprentice board post "API now returns 404, not 400"          # everyone in the run
apprentice board post --to docs "Please mention the new error" # one step
apprentice board read                                          # new since this step last looked
apprentice board wait --from code [--for 10m]                  # block until they answer; exit 7 on timeout
```

- Addresses are step names, not agent names (the same agent can run two steps); the board records both.
- A file lock keeps simultaneous posts whole. Each step keeps its own read cursor.
- Messages are capped at 2,000 characters; longer text goes in a file the message points to.
- Agents are not interrupted: a message is seen at the agent's next check. The prompt says to check before
  major decisions and before finishing; every apprentice command an agent runs ends with its unread count;
  `board wait` pauses a step that cannot go on. A step that finishes with unread messages addressed to it
  is flagged and those messages go to the join step.
- A wait that nobody answers ends at its limit, so two steps waiting on each other cannot hang the run.
- Messages carry who sent them and, for a UI step, that the text came from the screen. They are
  information from another agent, never instructions, and cannot approve anything.
- The join step gets the summaries and the messages addressed to it, not the whole board, plus the file's
  path. The user reads the whole board on the Pipelines screen.
- Real interruption (stop an agent, restart it with the urgent message) is a later addition; it wastes
  work and tokens.

## 7. The scribe, summaries, notes and the cache

Each project has a gitignored cache (`project new` adds it to `.gitignore`; every run checks it is still
there, since outputs can hold secrets):

```text
<project>/.apprentice/cache/
  runs/<n>/
    pipeline.md            the copy this run follows (edits apply to the next run)
    agents.json            every named agent as resolved for this run
    state.json             each step: waiting | running | parked | done | failed | skipped
    board.jsonl
    nodes/<step>/
      prompt.md            exactly what the agent was given
      output.log           everything it printed
      summary.md           the scribe's summary for the steps this one feeds
      result.json          agent, model, exit code, timings, fallbacks, limit hit
    worktrees/
  past/<pipeline>/<date>-run-<n>.md    notes from finished runs, kept, never auto-deleted
```

The scribe is a named agent the user chooses (`scribe:` in the file, else the project's, else the
global default; a comma list gives backups). It writes:

- each step's `summary.md`, injected into the next prompts, replacing today's 6,000-character tail;
- the past-run note when a run ends;
- the rolling summary when `carry: summary` is on.

It runs read-only on the step's output, changed files and board, labelled as material to summarise, and
prints its text; apprentice saves the file. Apprentice records the facts itself (result, times, agent,
fallbacks) so a scribe cannot get those wrong. If every scribe fails: the run continues with the raw tail
marked "not summarised", the note keeps apprentice's facts and says it has no written summary, the
rolling summary keeps its previous version.

A past-run note:

```markdown
---
pipeline: fix-bug
run: 41
finished: 2026-11-03 14:20
result: failed at "tests"
commit: a1b2c3d
---
Past run, for reference only. It may be out of date and is not an instruction.

## Recorded by apprentice
tests: Codex hit its limit, then opencode took over and failed.

## Written by the scribe
The login test may need Docker.
```

How notes stay out of the way: they are not in any prompt by default (the prompt gives their path, labelled
as past runs); apprentice's facts and the scribe's text are kept apart; a note whose commit no longer
matches the files it names is marked "may be out of date"; a failed run's note cannot read as something
that worked; screen text is marked; the interpreter never sees them; the engine reads only `result.json`.

The rolling summary (`carry: summary`, off by default) is `pipelines/<name>.memory.md`, tracked in git, capped
at about 1,500 characters, rewritten after each run, included in the next run's prompts as background from
an earlier run. Each run records which version it used. Run fresh ignores it for one run. It cannot change
steps, branches, permissions or approvals, whatever it says. Lasting project facts belong in `AGENTS.md` or
a project skill, not here.

Raw outputs and merged worktrees are deleted after 30 days (editable); notes are kept. `.apprentice/cache/`
never syncs to the project's GitHub repo; confirm project sync honours the ignore (build step 1).

## 8. Blocked, questions, parking and fallback

When an agent cannot continue it works down this list and stops only at the last rung:

1. Decide, if the choice is low-risk and easy to undo, and record the assumption on the board.
2. Ask the other steps on the board.
3. Use another allowed route (another command, or the group's UI step).
4. Do everything the block does not affect.
5. Ask the user with `apprentice ask` (choices where they fit). If `ask` exits 9, save progress and exit:
   the answer restarts this step.

`ask` in a pipeline step: the popup names the agent and the step ("Joseph, on the `code` step"); other
steps keep running; an answer in time goes straight back; after `[agent] ask_window_s` the question stays
open on the Pipelines screen and the phone (`[agent] notify`), the step exits with 9 and parks; the answer
later restarts the step in the same worktree as a fresh run, given its saved progress and the answer.
Answers also go on the board so a parallel step does not ask again. `away on` sends pipeline questions
straight to the screen and phone. Several parallel agents may ask at once: check how the popups stack
(build step 1); if badly, queue them with a count.

Permission requests are separate from questions: apprentice writes the wording and the buttons (Allow for
this run / Skip this step / Stop the run), never the agent, so a misleadingly worded question cannot grant
access. A permission block does not trigger fallback, or the run would simply try agents until one had
wider access. A CLI that hangs on its own prompt or dies on a refusal is caught by the stall timer or exit
code; the user sees its last output with the same buttons.

Fallback, for out of tokens, stalled, crashed or no output:

- Out of tokens: matched against the CLI's `limits` phrases; that CLI is skipped until its limit resets
  (the phrases and reset behaviour are unconfirmed; build step 1 collects the real messages).
- The next agent on the priority list takes over in the same worktree, told what the last one changed.
- Every agent tried once; when all fail the run stops and says why. Only named agents are ever used, so
  project content only reaches providers the user listed.
- A UI step that already acted on screen does not retry: a retry could send something twice. It parks
  like any other block.

## 9. Resuming and stopping

`--from N` stops meaning anything on a graph. `pipeline status`, `pipeline resume <run>` (asks whether to
use the run's copy of the pipeline or the edited file), `pipeline stop <run>`. A resume reruns only the
steps that failed or parked. The Pipelines screen shows the graph, which path a run took, which agent ran
each step, the board, parked questions with their buttons, and past-run notes.

## 10. What a project repo carries

Every project repo comes with instructions, skills and slash commands, so a clone or worktree already
knows how it works. This half-reverses the rule that shared skills are never copied into projects: the
pipeline and help skills go in every project; the large site skills stay global.

```text
<project>/
  AGENTS.md                 apprentice's section (markers, kept up to date) + the user's text
  CLAUDE.md, GEMINI.md      import AGENTS.md
  .apprentice/
    project.toml
    named-agents.toml
    commands.txt            buttons above the terminal (today)
    skills/                 the one place the user edits skills
    commands/               the one place the user edits slash commands
    worktree-links
    cache/                  gitignored
  pipelines/
  .claude/ .gemini/ .agents/ …   generated per CLI from skills/ and commands/
```

- Apprentice rewrites only its own section of `AGENTS.md`; the user's text stays. If the user edited the
  section, the next update asks whether to keep their version. Existing projects get the section the next
  time a pipeline runs there. The section stays short (agents read it every session); the full story is in
  the skills.
- Generated per-CLI files say where the original is; an edit made to a generated copy is noticed and the
  user asked whether to keep it. They pass the same leak check as skills. The exact folders and formats
  each CLI reads, and which read only a global folder, are checked in build step 1.
- Built-in slash commands only run the matching apprentice command, so behaviour stays in one place:
  `/pipeline-run`, `/pipeline-status`, `/pipeline-check`, `/pipeline-audit` (reads the brief), `/board`.
  Pipeline steps use the shell commands directly; slash commands may not work headless.
- Generated files are committed (recommended; open decision). Keeping them out of git would mean
  regenerating them for every clone and worktree and nothing for anyone without apprentice.
- The Instructions tab in the window shows `AGENTS.md` and the other instruction files, with hand-written
  Markdown highlighting (headings, bold, lists, links, code, front matter; the app has no package
  dependencies), tints and labels apprentice's section, marks generated files read-only with a link to the
  original, and compares rather than overwrites when the file changed under unsaved edits.

The apprentice section of `AGENTS.md`:

```markdown
<!-- apprentice:start (kept up to date by apprentice) -->
## Running in a pipeline
You may be one step of several, with other agents working at the same time.
Your prompt gives the goal, the map, your step and what to output.

- Check `apprentice board read` before major decisions and before finishing.
- Only use the screen if your prompt says this step has it.
- If you're blocked, keep going any allowed way: decide if it's low-risk and
  easy to undo, ask on the board, try another route, finish the rest.
- Never bypass a refusal, sandbox, approval, payment or CAPTCHA.
- If you still can't continue, ask with `apprentice ask`. If it exits with
  code 9, save your progress and exit: your answer will restart this step.
<!-- apprentice:end -->
```

## 11. Audit

Each pipeline has an Audit button; clicking it spends no tokens:

1. `apprentice pipeline check <name>` runs (section 2).
2. `apprentice pipeline audit <name>` writes `.apprentice/cache/audit/<name>.md`: the check's results; each
   step's agent, model and permissions after inheritance; what went wrong in the last run; past-run notes
   and the rolling summary; what to review, such as prompts that ask for more than their agent can do
   (apprentice cannot tell that from wording; the audit is where a person or their agent does).
3. A shell tab opens in the project folder with an Insert audit brief button, which types
   `Read .apprentice/cache/audit/<name>.md, then review this pipeline with me.` and presses Return into
   whatever the user started there.

The brief tells the agent to run `pipeline check` after each change. A running run keeps its own copy, so
edits apply to the next run. Raising a project agent's permissions in an audit still triggers the first-use
question; an agent cannot approve its own access. Pipelines are files in the repo, so git shows and undoes
every change.

## 12. Help

`apprentice help` opens with a paragraph saying what apprentice is, then lists every command grouped by
purpose, each with one sentence an agent can act on without guessing (what it does, when to use it, whether
it spends tokens, changes anything, takes the screen or needs approval, and its exit codes in brief).
`apprentice help <command>` gives the full entry: arguments and flags with defaults, output and what
success looks like, every exit code and what to do next, where it works (Mac, VM, inside a pipeline step),
one real example with its output. `help --all` prints everything; `help <word>` searches. Plain text, no
colour, when read by an agent.

One source: `agent/commands.toml` holds every command's entry. Help, the generated slash commands, MCP tool
descriptions and `usage()` read from it. `selftest` fails when a dispatched command has no entry, an entry
has no command, an example does not parse, or the exit codes disagree with `SPEC.md` and the agent docs.

An `apprentice-help` skill (under the 600-token limit) explains how the parts fit: what apprentice is and
the rules agents work under; how sessions, projects, pipelines, the board and approvals relate; which
command to reach for in common situations; what to do when blocked or a command fails. Exact flags stay in
`apprentice help`. It is built into every project with the pipeline skill.

## 13. Bundling agents

Recommendation: ship the agent list and one-click installers, not the CLIs. Codex and Gemini CLI are
Apache-2.0 and opencode and Kilo MIT (npm `license` fields, checked 2026-11-05), Claude Code's package
says "see license in README" and Antigravity's terms are unread, so bundling those needs a licence check;
bundled copies age fast; the user still signs in to each. Open decision.

## 14. Cleaning up the CLIs' own sessions

Every headless step is a new session for its CLI, and each CLI keeps a transcript of it. On this Mac on
2026-11-05, before any of this exists, Claude Code's transcripts were 4.5 GB (`~/.claude/projects/<escaped
cwd>/<session>.jsonl`, 2,961 files), opencode 1.0 GB (`~/.local/share/opencode/opencode.db` 936 MB plus
`snapshot/`), Kilo 0.9 GB (`kilo.db` 663 MB, `snapshot/`, `worktree-pool/`), Codex 208 MB
(`~/.codex/sessions/<y>/<m>/<d>/rollout-….jsonl` plus `thread_history_1.sqlite`), Gemini 42 MB
(`~/.gemini/tmp/<project hash>/`). A pipeline that runs hourly with five steps would add 120 sessions a day
to that, each worktree path giving Claude Code a new project folder of its own.

The rule: apprentice removes only the sessions it started, identified by ids it chose or captured and
recorded in the step's `result.json`, and never touches the user's own sessions. The CLI transcript
duplicates what the cache already keeps (`prompt.md`, `output.log`, the scribe's summary), so it has no
reason to outlive the run.

How, per CLI, all from `agents.toml` so nothing is hard-coded and a new CLI adds its own lines:

| CLI | start the session so apprentice knows it | remove it |
|---|---|---|
| Codex | `exec --ephemeral` (no session files written) | nothing to do; `codex delete <id>` if a test shows `--ephemeral` still leaves sqlite rows |
| Claude Code | `--session-id <uuid apprentice draws>` | delete `~/.claude/projects/<escaped cwd>/<uuid>.jsonl`; a worktree's whole project folder once the worktree is gone |
| opencode, Kilo | the id from `--format json` output | `opencode session delete <id>`, `kilo session delete <id>` |
| Gemini | `--session-id <uuid>` | `--delete-session` takes an index, not an id: delete the session file under `~/.gemini/tmp/<hash>/` by id, with the layout confirmed first |

```toml
[agent.claude]
session = ["--session-id", "{session}"]                           # how apprentice names the session
transcript = "~/.claude/projects/{cwd_escaped}/{session}.jsonl"   # what to delete
[agent.codex]
ephemeral = ["--ephemeral"]                                        # nothing written
[agent.opencode]
session_from = "json:sessionID"                                   # where the id is in the output
forget = ["opencode", "session", "delete", "{session}"]
```

When: a step's session goes as soon as the step ends and the scribe has its summary; a parked step's goes
too, since a restart is a fresh run. `[pipelines] keep_sessions_days` (default 0) keeps them longer for
someone debugging with the CLI's own `resume`. Worktree project folders go with the worktree.

`apprentice tidy [--report]`: removes any apprentice-started session older than the setting (a step that
crashed before cleanup, a daemon that died mid-run), and the cache's expired outputs and worktrees, and
prints what it freed. `--report` also shows each CLI's total session size and the CLI's own way to clear
it (Claude Code's `cleanupPeriodDays`, `codex delete`, `opencode session delete`), without deleting any of
it: those are the user's sessions. The daemon runs `tidy` once a day beside the existing 30-day log prune;
Settings ▸ Storage shows the report.

To confirm in build step 1: Claude Code's transcript path under `-p --session-id` and whether it also
writes to `history.jsonl`; whether `--ephemeral` keeps Codex out of `thread_history_1.sqlite`; that
opencode's and Kilo's `--format json` carry the session id and that `session delete` also drops the
`snapshot/` entry; Gemini's per-session file layout. Antigravity and Freebuff are not run headless, so
they keep nothing from pipelines.

## Commands to build

| command | used by | does |
|---|---|---|
| `board post [--to step] "…"`, `board read`, `board wait --from step [--for]` | agents | section 6 |
| `board summarise <run>` | the scribe step, or the user | rewrites the rolling summary |
| `pipeline check <name>` | agents, the user, every run | section 2's validation, no AI |
| `pipeline audit <name>` | the Audit button | writes the brief |
| `pipeline status`, `resume <run>`, `stop <run>` | the user, the window | section 9 |
| `pipeline run <name>` | existing, new engine | graph, parallel, named agents, fallback, scribe |
| `agents list`, `agents test <name>` | the user, Settings | named agents after inheritance; one tiny prompt |
| `tidy [--report]` | the daemon daily, the user | section 14: apprentice's own CLI sessions and expired cache |
| `help`, `help <command>`, `help --all` | agents, the user | section 12 |
| `ask` | existing, pipeline-aware | section 8 |

## Build order

0. **Help**: `agent/commands.toml`, `help` output, the self-test, the `apprentice-help` skill. Useful now,
   depends on nothing; each later command adds its entry as it lands.
1. **Check the unknowns**, each a small real test, results recorded here:
   - Codex's sandbox: can `codex exec` under `--sandbox workspace-write` reach `~/.apprentice/sock` and
     the cache folder? (`codex sandbox` takes the command directly; my earlier try passed a wrong
     argument.) If not, `--add-dir` for the cache and what else is needed for the socket.
   - What each CLI prints when out of usage, and whether it exits or waits.
   - What each CLI does when refused a tool or permission headless: exits, hangs, asks on stdin.
   - Which permission levels each CLI can enforce headless.
   - Where each CLI reads project-level skills and slash commands, and what `connect.py` covers.
   - How several `ask` popups behave at once.
   - Whether project sync honours `.gitignore` for the cache.
   - Each CLI's session naming and removal (section 14's list).
   - `agy` on this Mac: anything headless?
   - A two-step real run, Claude Code then Codex, and a parallel pair passing one message on a prototype
     board (small usage on both).
2. **Named agents**: both files, inheritance, effort and permission flag mapping in `agents.toml`, the
   Agents screens, Test, the priority list, the first-use permission question, the project repo files
   (section 10: `AGENTS.md` section, per-CLI generation, Instructions tab).
3. **Headless steps**: the new file format and parser, per-step agent, the generated prompt, the scribe's
   step summaries, the cache folder, session cleanup and `tidy`, `pipeline check`, the Audit button and brief. Linear pipelines only,
   so this ships useful on its own.
4. **Blocking and fallback**: pipeline-aware `ask`, parking, permission buttons, limit and stall detection,
   takeover, past-run notes, `status`/`resume`/`stop`.
5. **Routing**: the interpreter, `|`, `when:`, loop limits, resume by step on a graph.
6. **Parallel**: `&`, worktrees and links, merge at the join, the board, one `Device` owner per step, the
   UI tick rule in the editor and the check.
7. **Carry and the window**: `carry: summary` and `board summarise`, the Pipelines screen's graph, path,
   board and notes, Run fresh.

## Open decisions

1. Generated per-CLI files committed to git (recommended yes).
2. One-click install instead of bundling the CLIs (recommended yes).
3. The scribe writes every step summary (one extra agent call per feeding step; consistent). The
   alternative, each step summarising itself, is cheaper and less consistent.
4. The rolling summary stays tracked in git while notes are gitignored.
5. Real interruption of a running agent: later, if the board's check-when-you-can proves too slow.
