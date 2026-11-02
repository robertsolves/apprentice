---
name: improve-agent-prompts
description: >-
  Rewrite every agent prompt (commands, skills, subagents, rules) so a weak free coding agent can follow it — an exact command and a finish line in every step, decision tables, stop questions, fewer tokens — and fix whatever is broken for one of the CLIs that read them. Run after adding or editing several prompts, when cheap agents fumble a command, or as periodic hygiene. Not for measuring one change on one prompt — use /improve-prompts.
---

# Shared improve-agent-prompts workflow

Read `../../commands/improve-agent-prompts.md` completely before taking task actions, then follow that workflow faithfully.

Treat any text supplied with an explicit `$improve-agent-prompts` invocation as the command document's `$ARGUMENTS`. When invoked implicitly, infer arguments only where the command defines a safe default; otherwise ask the user.

The command document is the single source of truth. Ignore command-harness-only frontmatter while preserving its behavioral intent, including read-only restrictions and explicit confirmation requirements. When it refers to another `/command`, invoke or follow the equivalent `$skill` in Codex.
