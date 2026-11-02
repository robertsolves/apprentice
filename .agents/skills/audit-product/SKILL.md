---
name: audit-product
description: >-
  Audit the product through the eyes of a real user. Surfaces design flaws, inconsistencies, and serious functional errors, asks hard questions about them, then fixes the ones the developer confirms. Run when asked to review the product, a feature or a flow as a user would, or before a release. Not a linter: ignores syntax, dependencies, formatting, and test coverage. Not for a project that ships its own product-audit command — use that one.
---

# audit-product

Read `../../commands/audit-product.md` (from the project root: `.agents/commands/audit-product.md`) in full before doing anything, then follow it step by step.

Text the user gave with the skill is the command's `$ARGUMENTS`. If the skill was picked without any, use the command's default only where it defines one; otherwise ask.

The command file is the only source of truth. Skip frontmatter keys your tool does not understand, but keep their intent: read-only limits and "ask first" steps still apply. Where it says to run another `/command`, run the skill of the same name.
