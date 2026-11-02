---
name: improve-prompts
description: >-
  Improve a project's prompts as a controlled experiment — the app's AI generation prompts, or its agent prompts (commands, skills, rules, subagents) so that weak free coding agents can follow them. Measure a baseline batch, review it blind, state one falsifiable hypothesis, change one thing in a new version, rerun the same inputs, decide by a rule fixed in advance, log the result, and adopt with the owner's confirmation. Run when asked to make AI generation better, or when cheap agents keep fumbling a command. Not for rewriting every prompt to the writing standard — use /improve-agent-prompts.
---

# Shared improve-prompts workflow

Read `../../commands/improve-prompts.md` completely before taking task actions, then follow that workflow faithfully.

Treat any text supplied with an explicit `$improve-prompts` invocation as the command document's `$ARGUMENTS`. When invoked implicitly, infer arguments only where the command defines a safe default; otherwise ask the user.

The command document is the single source of truth. Ignore command-harness-only frontmatter while preserving its behavioral intent, including read-only restrictions and explicit confirmation requirements. When it refers to another `/command`, invoke or follow the equivalent `$skill` in Codex.
