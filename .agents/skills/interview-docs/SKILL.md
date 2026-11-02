---
name: interview-docs
description: >-
  Walk every markdown doc, triage each for real questions (scenario gaps, contradictions, vague claims), interview the user in batches of three, and apply the answers back into the doc. Run when asked to interview the user about the docs, or to settle product intent that the docs leave open. Not for questions about source code — use /interview-code; not for one risky code spot — use /interview-risky-spot; not for syncing docs with the code without asking — use /update-docs; not for rewriting docs for clarity — use /improve-markdowns.
---

# interview-docs

Read `../../commands/interview-docs.md` (from the project root: `.agents/commands/interview-docs.md`) in full before doing anything, then follow it step by step.

Text the user gave with the skill is the command's `$ARGUMENTS`. If the skill was picked without any, use the command's default only where it defines one; otherwise ask.

The command file is the only source of truth. Skip frontmatter keys your tool does not understand, but keep their intent: read-only limits and "ask first" steps still apply. Where it says to run another `/command`, run the skill of the same name.
