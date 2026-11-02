---
name: interview-code
description: >-
  Walk the project's source files, compare each against the docs, and ask the user forced-choice product questions only they can answer, then write the answers into both code and docs. Run when asked to "interview me about the code", to check what the code does against the product docs, or to pin down undocumented product behaviour. Product behaviour only, never code style. Not for markdown docs — use /interview-docs; not for one risky spot — use /interview-risky-spot.
---

# interview-code

Read `../../commands/interview-code.md` (from the project root: `.agents/commands/interview-code.md`) in full before doing anything, then follow it step by step.

Text the user gave with the skill is the command's `$ARGUMENTS`. If the skill was picked without any, use the command's default only where it defines one; otherwise ask.

The command file is the only source of truth. Skip frontmatter keys your tool does not understand, but keep their intent: read-only limits and "ask first" steps still apply. Where it says to run another `/command`, run the skill of the same name.
