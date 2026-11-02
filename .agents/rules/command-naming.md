---
# Path-scoped (Claude Code): auto-loads only when a matching file is read or edited.
paths:
  - ".agents/**"
  - ".claude/**"
---

# Command and skill naming and authoring

All reusable workflows for this project (and the owner's other projects) follow two standards: scoped verb-first naming, and the command-file anatomy below. The step-by-step procedure for applying them (templates, the Codex-wrapper script, the checks) is the `command-authoring` skill. Slash-command harnesses invoke `/name`; Codex invokes the matching repository skill as `$name`.

## Rule: scoped verb-first naming

The command name is `[scope-]verb-noun`: an optional scope, then the verb, then what it acts on. Lowercase, hyphens between words.

**Why:** The scope says at a glance whether a command can be copied to another project, and the verb says what it will do to the tree. Listing the commands sorts them into families: every apprentice command together, every `find-` sweep together.

**The scope** is the narrowest one that is true, in this order:

- `apprentice-`: the command names apprentice paths, source files, state files, notes or product rules.
- `swift-` (or another language): it works on any project in that language and on nothing else.
- No scope: it works on any project in any language (`find-bandaids`, `audit-slop`, `interview-docs`).

**The verb** says what happens to the tree:

- `find-`: hunt one class of problem, report it, let the owner pick, then fix the picked ones (`find-dead-code`, `find-exploits`).
- `audit-`: a broad review across many classes of problem, report first (`audit-slop`, `audit-product`).
- `check-`: a pass/fail gate that reports and changes nothing (`check-production-readiness`).
- `fix-`: work through an issue list that already exists somewhere (`fix-sentry`).
- `improve-`: a behaviour-preserving edit pass (`improve-markdowns`, `improve-prompts`).
- Otherwise the most specific accurate verb (`sync`, `make`, `interview`, `refine`, `resume`, `unify`, `update`). Avoid vague verbs like `do` or `run`.

**Generic commands learn the project from `AGENTS.md`.** A command without the `apprentice-` scope names no apprentice path or file. Its body tells the agent to read the project's `AGENTS.md` (and `.agents/project-facts.md`, which it points at) for the project's rules, build and check commands, where findings go, and which doc owns which subsystem. An apprentice fact a generic command needs belongs in the doc that owns that subsystem. Generic commands carry no Self-update step, because they hold no project citations to drift.

**How to apply:**

- The noun is whatever the verb acts on (`code`, `docs`, `prompts`). Compound nouns get hyphens too.
- A rename is not done until every reference has moved: there are no aliases, and an old name simply stops working.
- The file goes in `.agents/commands/` (which `.claude/commands/` resolves to through the symlink). The H1 inside matches the filename: `# /name`.
- Add the matching `.agents/skills/<name>/SKILL.md` Codex wrapper. Its description mirrors the command's, but its body only loads and follows `../../commands/<name>.md`; never duplicate the workflow body. Add `policy.allow_implicit_invocation: false` in `agents/openai.yaml` when the command has `disable-model-invocation: true`.
- After a rename, grep `.agents/`, `AGENTS.md`, `~/.claude/commands/` and the memory folder for stale references.

## Rule: command file anatomy

Every command markdown file starts with YAML frontmatter, then an H1 matching the filename, then the body:

````markdown
---
description: One complete sentence saying what the command does and when to run it.
argument-hint: "<target>"
---

# /name

Body: scope resolution, numbered steps, verification, summary.
````

- **`description` is required.** Without it the harness falls back to the first ~100 characters of the body, and the model gets a worse signal for deciding when to invoke the command. Lead with the verb, include the "run when / run before" trigger, keep it to one or two sentences. Frontmatter is strict YAML: wrap a description containing `: ` in double quotes.
- **`argument-hint`** whenever the command takes arguments. In the body, reference them as `$ARGUMENTS` and state exactly what happens when they're absent (ask, default, or stop).
- **Steps are `## Step N: <title>` headings**, numbered in execution order, never `### Step N`, `## Step N — …`, `## N.` or a `## Steps` list. Reference material may sit in plain `##` sections around them, and an apprentice-specific command's last section is `## Step N: Self-update`.
- **A command's own scripts and guides live in its skill folder**: `.agents/skills/<name>/scripts/` for a script only that command runs, `.agents/skills/<name>/references/` for a guide only it reads, cited by repo-root path. Each script runs from any directory and starts with a header saying what it does and how to call it.
- **`disable-model-invocation: true`** on any command that destroys data, publishes, or drives the real screen without the approval gate. Only the user can then type it.
- **`allowed-tools`** may pre-approve a read-only tool set (`Read, Grep, Glob, Bash`) for report-only commands. A command with a Self-update step still needs `Edit`.
- **Never `model:`** in a command file: Claude Code and OpenCode read the key differently and no value works in both.
- **Don't hardcode repo inventories** (file lists, command lists) that a shell command can produce. Tell the agent to `ls` / `rg` at run time.
- **apprentice-specific commands end with a Self-update step**: verify the file's own path and symbol citations against the current code, edit the command in place when they drifted, and print `self-update: <N> changes` or `self-update: clean`.
- **Findings go where `AGENTS.md` says**: here, a bug the command finds and doesn't fix goes to `BUGS.md` in the field-report format, and deferred work goes to `TODO.md`.

## Which tool reads what

- **Claude Code** reads `.claude/commands` (a symlink to `.agents/commands`), `.claude/rules` (a symlink to `.agents/rules`, loaded per the `paths:` frontmatter) and `.claude/skills/<name>`, one symlink per genuine skill (one with no command twin, such as `command-authoring`). **Never symlink `.agents/skills` into `.claude/` wholesale**: Claude Code lists both `commands/*.md` and `skills/*/SKILL.md`, so every workflow would show twice. A new genuine skill needs its `.claude/skills/` symlink added by hand. Subagents do not inherit rule files; one that depends on a rule must `Read` it.
- **Codex** scans `.agents/skills/*/SKILL.md` and does not read `commands/*.md`, hence the thin wrapper per command. Every wrapper has an `agents/openai.yaml`.
- **OpenCode and Kilo** read `commands/*.md` and `agents/*.md` only through a `.opencode` or `.kilo` symlink to `.agents/`. Agent frontmatter restricts tools with `disallowedTools:`, never a `tools:` allow-list, which OpenCode refuses.
- **Everything else** gets the shared instructions through `AGENTS.md` (`CLAUDE.md` imports it).
