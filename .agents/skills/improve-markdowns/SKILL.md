---
name: improve-markdowns
description: >-
  Rewrite the project's markdown files for clarity, fix stale references, remove tables, redistribute off-topic content, and keep CLAUDE.md / README.md lean. Run when docs feel bloated, duplicated or stale, or after files, commands or packages were renamed or moved. Not for asking the owner product questions about a doc — use /interview-docs; not for syncing the core docs with the code — use /update-docs.
---

# improve-markdowns

Read `../../commands/improve-markdowns.md` (from the project root: `.agents/commands/improve-markdowns.md`) in full before doing anything, then follow it step by step.

Text the user gave with the skill is the command's `$ARGUMENTS`. If the skill was picked without any, use the command's default only where it defines one; otherwise ask.

The command file is the only source of truth. Skip frontmatter keys your tool does not understand, but keep their intent: read-only limits and "ask first" steps still apply. Where it says to run another `/command`, run the skill of the same name.
