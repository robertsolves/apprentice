---
name: interview-risky-spot
description: >-
  Interview-style review. Picks one risky spot in the codebase and asks targeted Socratic questions to surface mismatches between what the code does and what you actually wanted. Run when asked to sanity-check vibe-coded code, "does this code do what I meant", or to interview me about a risky file. Read-only, one file per run. Not for walking every source file — use /interview-code.
---

# interview-risky-spot

Read `../../commands/interview-risky-spot.md` (from the project root: `.agents/commands/interview-risky-spot.md`) in full before doing anything, then follow it step by step.

Text the user gave with the skill is the command's `$ARGUMENTS`. If the skill was picked without any, use the command's default only where it defines one; otherwise ask.

The command file is the only source of truth. Skip frontmatter keys your tool does not understand, but keep their intent: read-only limits and "ask first" steps still apply. Where it says to run another `/command`, run the skill of the same name.
