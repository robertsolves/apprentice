---
name: update-docs
description: >-
  Scan the codebase and update the project's core docs (agent guide, READMEs, architecture docs) to match reality, presenting a diff list for confirmation before applying fixes. Run after a stretch of structural changes (files moved, packages or commands added, subsystems reworked) or when the docs feel stale. Not for rewriting docs for clarity — use /improve-markdowns; not for one dead link or renamed symbol — use /find-stale-references.
---

# update-docs

Read `../../commands/update-docs.md` (from the project root: `.agents/commands/update-docs.md`) in full before doing anything, then follow it step by step.

Text the user gave with the skill is the command's `$ARGUMENTS`. If the skill was picked without any, use the command's default only where it defines one; otherwise ask.

The command file is the only source of truth. Skip frontmatter keys your tool does not understand, but keep their intent: read-only limits and "ask first" steps still apply. Where it says to run another `/command`, run the skill of the same name.
