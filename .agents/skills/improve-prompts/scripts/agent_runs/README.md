# Agent runs: trying commands on weak agents

`run_agent_trials.sh` measures how well a weak, free coding agent (Nemotron by
default, through OpenCode or Kilo) carries out one of our commands. It is
the tool `/improve-prompts` uses for **agent prompts**: commands, skills,
rules and subagents. The app's AI generation prompts use a different tool
(`doc/guides/improving_ai_generation.md`).

One trial ("run"):

1. copies a snapshot of the working tree into a throwaway sandbox,
2. overlays the version under test (edited copies of prompt files),
3. plants one problem (the task's `setup_task.sh`) and commits,
4. runs the agent on the command, then sends the owner's scripted replies,
5. runs the task's checks (`check_task.sh`) and records cost and tool use,
6. deletes the sandbox and the agent's session.

Everything lives in the lab, `~/.agent_runs/<repo name>` (or
`$AGENT_RUNS_HOME`), outside the repo. `run_agent_trials.sh help` lists
every subcommand.

## Ready-made commands

The shell is zsh; paste these as they are.

```sh
bash <<'SH'
cd "$(git rev-parse --show-toplevel)"
R=.agents/skills/improve-prompts/scripts/agent_runs/run_agent_trials.sh
bash $R snapshot                                   # copy the tree as it is now
bash $R tasks                                      # the planted tasks
bash $R run find-dead-code-unused-helper           # one trial, prints its run id
SH
```

A baseline, then an experiment (one change) against it:

```sh
bash <<'SH'
cd "$(git rev-parse --show-toplevel)"
R=.agents/skills/improve-prompts/scripts/agent_runs/run_agent_trials.sh
bash $R fill base-dead-code find-dead-code-unused-helper    # 3 runs per task
bash $R score base-dead-code
bash $R version new "E1: name the exact grep in Step 2"     # prints v1
bash $R version add v1 .agents/commands/find-dead-code.md   # prints the copy to edit
# edit that copy with the Edit tool, then:
bash $R version diff v1
bash $R fill e1-dead-code --like base-dead-code --version v1
bash $R pair base-dead-code e1-dead-code                    # the main number
SH
```

Reviewing a run (read it with `show`, which hides the version and batch):

```sh
bash .agents/skills/improve-prompts/scripts/agent_runs/run_agent_trials.sh show <run>
bash .agents/skills/improve-prompts/scripts/agent_runs/run_agent_trials.sh review <run> poor "never ran the drift tool" "SKIPPED_STEP"
```

Keep the experiment log in `<lab>/log.md`, in the `## E<N>` shape
`/improve-prompts` gives; for agent runs the baseline and result lines
carry the check pass rates from `score` and `pair` as well as the ratings.

## What the agent can and cannot reach

- It works in the sandbox, a copy. The real repo, its `.git` and the
  remote are out of reach (`external_directory` is denied).
- Its environment is rebuilt from nothing: a lab home instead of yours,
  no cloud, GitHub, Postgres or Google credentials, no git remote or SSH,
  no global agent config, no MCP servers.
- Its shell may not run git push/fetch/pull/clone, `gh`, `curl` and
  friends, `kill`, `open`, `osascript`, `security`, `docker`, `tart`,
  `codesign`, publishing, `kit.sh`, `install.sh`, or the `apprentice`
  binary itself, which drives the real screen (`agent_config.json`).
- Commands that touch a live environment are never trialled, nor is any
  command whose frontmatter sets `disable-model-invocation: true`.
- A non-free model is refused unless `--paid` is passed; pass it only
  with the owner's go-ahead. Sign the lab in once for a paid provider:
  `HOME=~/.agent_runs/apprentice/home XDG_DATA_HOME=~/.agent_runs/apprentice/data opencode auth login`.

## Writing a task

A task is a folder under `tasks/`, named `<command>-<what is planted>`:

- `task.env`: `COMMAND=`, `ARGS=` and optionally `TURN_TIMEOUT=` (seconds
  per turn, default 900). Plain `KEY=value` lines; never sourced.
- `setup_task.sh`: plants the problem, run in the sandbox root. It must fail
  loudly if the file it edits has changed shape.
- `replies.txt` (optional): one reply per line, sent as the owner's next
  turn. Blank and `#` lines are skipped.
- `check_task.sh`: sources `$CHECK_LIB` (`check_lib.sh`) and prints one
  `PASS <name>` or `FAIL <name>: <why>` line per check. Name checks after
  the behaviour (`asks_before_editing`), so `pair` reads as a sentence.

Run a new task once on a strong model and read its checks: a check a
correct run fails is a broken check. The plant must be unique in the tree
(grep for it) and leave the package analyze-clean, so a check sees only
what the agent did.

`find-stale-references-dead-script-path` plants a dead script name inside
a command line, which the repo's drift tool does not catch: it tests
whether the agent looks past the tool.

## Limits

- **Data goes to the free provider.** The agent reads whatever it wants
  from the snapshot, which includes tracked env files. Free tiers may
  train on what they are sent.
- **An accident guard, not a jail.** The deny list and scrubbed
  environment stop a confused agent; a hostile one could still find a
  way out of a pattern-matched shell. Never run this on a machine where
  that matters.
- **One commit of history.** The sandbox's git log holds one commit, so a
  command that digs through history (`git log -S`) finds nothing.
- **Versions cannot delete files**, only add or change them.
- Tokens spent by the agent's own subagents are not counted in `cost.txt`.
- Killing the harness with SIGKILL skips its clean-up; leftover processes
  carry `AGENT_RUNS_ID=<run>` in their environment
  (`ps -axE -ww -o pid=,command= | grep AGENT_RUNS_ID`).
