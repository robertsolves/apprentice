---
name: command-authoring
description: "Create, improve, rename or rewrite any agent prompt (a slash command and its Codex skill, a genuine skill, a subagent definition, a rule file) so it follows this project's conventions and fits the agent material already here: the scoped verb-first name, the command-file anatomy, generic versus apprentice-specific bodies, the Codex wrapper, and the records and checks every command shares. Use when asked to \"make a command\", \"add a slash command\", for a \"new skill/workflow/agent\" or to \"improve this command/prompt\", when renaming a command, or for any edit under `.agents/commands/`, `.agents/skills/`, `.agents/agents/` or `.agents/rules/`."
---

# Command authoring

How to add or improve a command (or any other agent prompt) so it looks and behaves like every other one here. The **rules** live in `.agents/rules/command-naming.md`: naming, file anatomy, and which tool reads what. Read it first; it wins over anything below. This skill is the procedure and the templates for following those rules.

## Step 1: Survey the agent material that already exists

A new or improved prompt has to fit what is already there: no overlap, no contradiction, the same wording for the same rule. Before writing anything, look at all of it:

- **Commands**: `.agents/commands/*.md`. Read every description (`grep -h '^description:' .agents/commands/*.md`), then read the nearest neighbours in full.
- **Skills**: `.agents/skills/*/SKILL.md`. Most are thin Codex wrappers; the genuine ones (this one) carry their own rules.
- **Subagents**: `.agents/agents/*.md`, with what each may and may not do.
- **Rules**: `.agents/rules/*.md`. A rule the command relies on is cited, never restated.
- **The agent guide**: `AGENTS.md`, especially "Agent commands", and `.agents/project-facts.md` (the project facts generic commands and skills read; `AGENTS.md` points there). A generic command's project facts must already be reachable from there.
- **Outside the repo**, if they exist: `~/.claude/commands/`, `~/.claude/skills/`, `~/.claude/agents/`, and any `plugins/*/commands/`. A same-named global command shadows or confuses the project one.

Then decide:

- If an existing prompt already covers the request, extend it rather than add an overlapping one. Say so in your answer (`find-vibe-code-issues` was `audit-slop` all along).
- If two prompts could both match one request, tell them apart in each one's description (`Not for <case> — use /<other>`), never in the body: every name in a body is something a weak agent may go and open.
- If the new prompt states a rule another file already states, cite that file instead of copying the rule. Where the two disagree, fix the disagreement first.

**Improving an existing prompt** follows the same survey. After it, re-read the prompt against the anatomy and Step 3's body rules, check every path and symbol it cites still exists, and keep its name unless it breaks the naming rule (then follow Step 5).

## Step 2: Name it

Answer in order, then write `[scope-]verb-noun`:

1. **Scope.** Does the body have to name an apprentice path, source file, state file, note or product rule? → `apprentice-`. Otherwise, does it only make sense for one language? → `swift-` (or that language). Otherwise no prefix. Prefer moving apprentice facts out to the doc that owns them so the command can be generic. The owner wants commands like `improve-prompts` and `fix-sentry` reusable.
2. **Verb.** What it does to the tree: `find-` (hunt one class → owner picks → fix), `audit-` (broad review), `check-` (pass/fail, changes nothing), `fix-` (works an existing list), `improve-` (behaviour-preserving edit), else the most specific verb already in use (`sync`, `deploy`, `make`, `interview`…).
3. **Noun.** What it acts on, hyphenated (`offline-issues`, `bad-comments`).

## Step 3: Write `.agents/commands/<name>.md`

Frontmatter: `description` (leads with the verb, says what and "Run when/before …", one or two sentences) and `argument-hint` if it takes arguments. Frontmatter must be strict YAML: a description containing `: ` is wrapped in double quotes. Add `disable-model-invocation: true` if it can destroy data, publish, or drive the real screen outside the approval gate. Never `model:`.

Body skeleton:

````markdown
# /<name>

<One paragraph: what this hunts or does.>

Read the project's agent guide first (`AGENTS.md`, `CLAUDE.md` or equivalent): it names <the specific things this command needs from the project>, where this command's audit record lives, and the checks to run after a change.

This is a two-phase command: **investigate and ask** (Steps 1–N), then **fix** (Step N+1). Never fix before the user confirms.

## Step 1: Scope and record
If `$ARGUMENTS` names …, … Otherwise <the default>.
Open the records the agent guide names (here `BUGS.md` and `TODO.md`). Re-check each open entry this sweep owns: still open, fixed (delete it), or wrong (delete it).

## Step 2: …   (run any existing tool first; don't re-derive what it checks)
## Step N-1: Update the records   (a bug in the field-report format to `BUGS.md`, deferred work to `TODO.md`)
## Step N: Present and ask   (numbered, worst first, capped per round; fix / leave / defer; wait)
## Step N+1: Fix   (root cause, a `selftest` check where the fix is in a pure part, delete the record)

Then close out with the checks the agent guide lists after a change.
````

That is the `find-` shape (`find-exploits`, `find-bad-comments` are worked examples). A `check-` command has no fix phase: it ends in a pass/fail report. A `fix-` command starts from the list it works, not from a hunt.

Rules for the body:

- **Generic command:** no apprentice path, source file or doc name anywhere; every project fact is "the X the agent guide names". No Self-update step.
- **apprentice- command:** cites real paths, and ends with `## Step N: Self-update` (re-verify its own citations, edit in place, print `self-update: <N> changes` or `self-update: clean`).
- **Steps are `## Step N: <title>`**, in execution order.
- **No inventories** a shell command can produce at run time (file lists, route maps, test lists).
- **Its own scripts and guides live in its skill folder.** A script only this command runs goes in `.agents/skills/<name>/scripts/`, a guide only it reads in `.agents/skills/<name>/references/`; the body cites them by repo-root path (`bash .agents/skills/<name>/scripts/<file>`). Each script runs from any directory (it finds the repo root with `git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel`) and has a header saying what it does and how to call it. Long greps move out of the body into a scan script that prints one labelled section per step (`=== Step N: … ===`) and exits 1 only on a counted invariant, so the body keeps the judgement and the script keeps the mechanics.
- Each finding states its evidence (`file:line`) and a confidence (confirmed / likely / suspected).
- Plain English. Write it for a tired reader; define any internal term on the spot.

Other kinds of agent prompt:

- **Subagent** (`.agents/agents/*.md`): restricts tools with `disallowedTools:`, never `tools:` (OpenCode refuses to boot). It does not inherit rule files, so it must `Read` the ones it depends on.
- **Rule** (`.agents/rules/*.md`): a `paths:` glob in frontmatter so it loads only where it applies; listed under "Project rules" in `AGENTS.md`.
- **Genuine skill** (guidance with no command twin, e.g. this one): `.agents/skills/<name>/SKILL.md` with `name:` and `description:` frontmatter, a hand-written `agents/openai.yaml` in the same shape as this skill's (no `policy:` block, so it can fire by itself), and longer lists in sibling files loaded on demand (`references/*.md`). See Step 4 item 2 for its `.claude/` symlink.

### Writing for cheap models

A prompt is finished when the cheapest model that will use it completes a real task and the guard passes, not when it reads well to a strong model. The standard every prompt is written to is `.agents/skills/improve-agent-prompts/references/weak_agent_standard.md` (rules R1–R16, token budgets, the cross-tool spec, sources): read it before writing the body. Then lint what you wrote:

```sh
python3 -I .agents/skills/improve-agent-prompts/scripts/scan_agent_prompts.py .agents/commands/<name>.md
```

Zero ERROR lines, and every WARN left is one the standard allows. `/improve-agent-prompts` applies the same standard to every existing prompt at once.

Test a new one on the cheapest supported model: three prompts that should select it, two that should reach its neighbour, one real task end to end. A selection failure is fixed in the description; an execution failure gets an explicit step or a worked example, never more prose.

## Step 4: Wire it up

1. **Codex wrapper:** `python3 -I .agents/skills/command-authoring/scripts/make_codex_wrapper.py <name>`. It writes `.agents/skills/<name>/SKILL.md` and `agents/openai.yaml` from the command's frontmatter, adding `allow_implicit_invocation: false` when the command disables model invocation. Re-run it whenever the description changes. Never hand-copy the workflow body into the wrapper.
2. **No `.claude/` symlink** for a command (`.claude/commands` already covers it). Only a genuine skill with no command twin, like this one, gets `.claude/skills/<name>` → `../../.agents/skills/<name>`, and one line in `AGENTS.md`.
3. **AGENTS.md:** a generic command that needs project facts gets them in the doc that owns the subsystem, with one pointer bullet in `.agents/project-facts.md`. A `find-` command records what it doesn't fix in `BUGS.md` and `TODO.md`. Add the command's `/name` to the "Agent commands" list in `AGENTS.md`.
4. **Commit:** `apprentice commit "agent commands: new /<name> …"`, one change per commit.

## Step 5: Renaming an existing command

The new name replaces the old one everywhere in the same change: command file, skill directory, every `/old` and `$old` mention in docs, commands, rules, scripts, `TODO.md` and memory files. There are no aliases. Move files (don't copy), and never `sed -i` / `perl -i` the symlinked paths (`AGENTS.md`'s twins, `.claude/*`); use a script that writes through the files. Seed strings in an applied migration stay; log them in `TODO.md`.

## Step 6: Verify

```sh
for f in .agents/commands/*.md; do n=$(basename "$f" .md); [ -f ".agents/skills/$n/SKILL.md" ] || echo "no wrapper: $n"; done
for d in .agents/skills/*/; do n=$(basename "$d"); [ -f ".agents/commands/$n.md" ] || [ -L ".claude/skills/$n" ] || echo "no command or .claude link: $n"; done
git status --short | grep '^ T'                  # empty: no symlink turned into a file
python3 -I .agents/skills/improve-agent-prompts/scripts/scan_agent_prompts.py .agents/commands/<name>.md
```

Then grep `.agents/commands/<name>.md` for apprentice names if the command is meant to be generic. Every hit is a fact to move out to its owning doc.

To learn whether a cheap agent can actually follow the command, trial it with `/improve-prompts` on the weak-agent harness (`.agents/skills/improve-prompts/scripts/agent_runs/README.md`); a command that changes files deserves a planted task there.

## Done means

- The two wrapper loops in Step 6 print nothing.
- `git status --short | grep '^ T'` prints nothing.
- `python3 -I .agents/skills/improve-agent-prompts/scripts/scan_agent_prompts.py .agents/commands/<name>.md` shows 0 ERROR.
