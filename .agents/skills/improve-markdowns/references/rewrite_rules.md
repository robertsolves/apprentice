# Markdown rewrite rules A to M

The rules `/improve-markdowns` applies to one file at a time in its Step 5. Report format is at the end.

## Contents

1. A. Plain language
2. B. Remove tables and render-only constructs
3. C. Reference links
4. D. Structure for machine readers
5. E. On-topic discipline
6. E2. Zero redundancy
7. F. Logical order
8. G. Fix stale references
9. H. Keep `CLAUDE.md` lean
10. I. `README.md` is for programmers
11. J. Match docs to reality
12. K. Spelling and grammar
13. L. Consistent house style
14. M. Never invent
15. Report format

## A. Plain language

- Replace jargon with the simplest accurate term. "Idempotent re-entrant handler" becomes "safe to call twice".
- Short sentences. One idea per sentence.
- Active voice. Imperative where the doc tells the reader to do something.
- If a paragraph survives a 50% trim without losing meaning, trim it.

## B. Remove tables and render-only constructs

Why: most readers see the source raw (Claude, diffs, `cat`, `less`, code review). A `| col | col |` block is a wall of pipes unless a previewer renders it.

- Convert every `| col | col |` table to a bulleted list or short paragraph.
- Two-column "term and definition" tables become `- **term**: definition.` bullets.
- Multi-column comparison tables become a bulleted list grouped by the row label, with the column data as sub-bullets or inline phrases.
- Genuinely tabular data (numbers in a grid where alignment carries meaning): do not convert. Add it to the report under "Questions for the user".
- Apply the same test to other render-only constructs: collapsed `<details>` blocks, HTML `<table>` / `<br>` / `<sub>`, shields, ASCII art, deeply nested blockquotes. If it is unreadable in `cat`, rewrite it as prose or a list, or drop it.

The test: open the file in a plain text view. If a section is harder to read raw than rendered, rewrite it.

## C. Reference links

- Where the doc names a file, command, rule, skill, agent, URL or external system, link it.
- Internal links are relative paths from the doc's location (`<relative path to other doc>`), not absolute repo paths, unless the doc is meant to be installed elsewhere (see G, install-target references).
- External links are a full URL in a markdown link, not bare text.
- If the referenced thing has no canonical URL or path, leave it as plain text. Do not invent a link.

## D. Structure for machine readers

- One H1 at the top, matching the doc's purpose.
- Section headings are noun phrases or short imperative phrases, not full sentences.
- Most important content first.
- Lists for enumerable items, prose for explanations. Do not bullet-point a paragraph.
- Code fences are language-tagged (`sh`, `dart`, `json`).

## E. On-topic discipline

- The doc's name is a contract. A doc named `<topic>.md` is about that topic. Move an off-topic section to the doc that matches it.
- If the right destination doc does not exist, stop and ask: "`<section>` in `<file>` belongs in a doc that does not exist. Create `<new file>`?" Never create it silently.
- If a section belongs to several docs, keep it in the most specific one and add a one-line link to it from the others.

## E2. Zero redundancy

No doc may contain information that is obvious, already stated in another doc, or derivable from the file tree, `git log`, `grep` or a one-line shell command. This applies to every file in scope.

Delete on sight:

- A `## Layout` / `## Structure` section when another doc already has one. Keep the deepest, most authoritative version; replace the others with a one-line link.
- A re-listing of plugins, commands, modules or screens that another doc already lists. One canonical list, linked from elsewhere.
- A bullet that restates the filename or directory name above it.
- A "What this repo is" section in both `README.md` and `CLAUDE.md`. Keep one; the other gets one line and a link.
- Install instructions duplicated in `README.md` and a second doc. Pick the canonical home and link.
- A command file that restates what its frontmatter `description:` already says.
- A file tree. Only non-obvious layout content stays: why a directory exists, what convention governs it, where the canonical source lives when it is not where you would expect.

Test for keeping content: if a competent reader could find it in under 10 seconds with `ls`, `grep`, or by opening one other doc they were going to open anyway, delete it or replace it with a link.

The owning doc is the most specific one. If you cannot tell who owns it, stop and ask: "`<content>` appears in `<file A>` and `<file B>`. Which owns it?"

## F. Logical order

- Lead with what the reader most needs. Entry doc: what the project is, how to run it. Topic doc: what the topic is, then how to use it, then edge cases.
- Background and rationale go after the actionable content.
- "Hard rules", "Don't do this" and similar guard sections go at the bottom.

## G. Fix stale references

- Every file path mentioned: confirm it exists (`ls <path>`). Renamed: update it. Gone: remove the reference. Leave no dangling links.
- Every command name (`/<name>`): confirm its source file exists (for example `ls .agents/commands/<name>.md`). Renamed: update. Deleted: remove the reference.
- External URLs: leave alone unless the user asks for a link check. Internal links must resolve.

Install-target references: some files cite paths like `~/.claude/commands/<name>.md` that resolve to a canonical source elsewhere in the repo (for example `plugins/<plugin>/commands/<name>.md`). Check the canonical source before calling such a reference broken. It is broken only when no canonical source can satisfy it. If the repo's `CLAUDE.md` or `AGENTS.md` gives the mapping, use it.

## H. Keep `CLAUDE.md` lean

`CLAUDE.md` loads into context on every conversation, so every kilobyte costs tokens forever.

- Cut anything discoverable from the file tree, `git log` or a quick `grep`.
- Cut history, decision logs and "we used to do X". That belongs in commit messages.
- Cut content duplicated from `README.md`; link to it.
- Target content: project name, layout overview, the few conventions an agent must know up front, pointers to where the rest lives. Defer anything the agent can read when needed.
- If your edit makes `CLAUDE.md` longer, justify it in the report.

## I. `README.md` is for programmers

`README.md` points readers at the right next file. Permitted contents, and nothing else:

- A one- or two-sentence project description, not repeated elsewhere.
- How to install, run and build, as copy-pasteable commands. This is their canonical home.
- Pointers to deeper docs, in one short list.
- A short list of useful external URLs.

Forbidden: a `## Layout` / `## Structure` section, a re-listing of anything listed elsewhere, any restatement of `CLAUDE.md`, the file tree.

## J. Match docs to reality

- Code without a doc entry (a new screen, endpoint, command, skill, rule): add it to the relevant doc.
- A doc claims something the code no longer supports: fix the doc.
- Doc and code disagree and it is not obvious which is right: stop and ask: "`<file>:<line>` says `<claim>` but the code does `<fact>`. Which is right?" Do not guess.

## K. Spelling and grammar

- Fix typos in every file you edit.
- Fix clear grammar slips (agreement, dropped articles, wrong tense). Keep the author's voice.
- One English variant per repo. Detect the dominant one (US `color`, UK `colour`) and conform. Never switch the repo's variant.
- Proper nouns keep their canonical spelling: `Dart`, `Flutter`, `GitLab`, `Claude Code`, `iOS`, `macOS`.

## L. Consistent house style

The docs should read as one author's work. Across all in-scope files:

- Headings: Title Case or Sentence case, whichever dominates. Never mix within a file.
- Lists: one bullet character per repo (`-` preferred), 2-space indent, and one terminal-punctuation rule (every bullet ends in a period, or none do), whichever dominates.
- Wrap file paths, command names, identifiers and flags in backticks.
- Emphasis: `**bold**` for strong, `*italic*` for light or first-use terms. Not both at once. No ALL CAPS for emphasis.
- Code fences always carry a language tag.
- Links are `[label](url)`, never bare URLs in prose (footer URL lists are fine).
- No em-dash, no en-dash, no `--` as an aside. Rewrite the sentence with a colon, period, comma, parentheses or a list. ASCII `-` in compound words (`read-only`) and flags (`--verbose`) is fine. Text quoted from vendored upstream files is left alone.
- Frontmatter keys appear in the same order across files of one type (commands lead with `description:` then `argument-hint:`).

If files disagree on a style point, use the variant in the majority of in-scope files and conform the minority. Record the choice in the report.

## M. Never invent

- Document only what exists in the codebase now.
- No aspirational features ("will support X in v2").
- No fabricated URLs, paths or command names. Confirm each with `ls`, `grep` or `git ls-files` before writing it.

## Report format

Print this in your reply, filled in. Write it to no file.

```text
# Markdown Improvement

Files in scope: <N>
Files edited: <M>
Files unchanged: <N - M>

## Edits applied
- `<file>`: removed 1 table (lines 9-15), fixed typo "Refrences".

## Content moved
- `<from file>` to `<to file>`: "<section>" (was off-topic).

## Questions for the user
- `<file>:<line>`: claims feature X exists but I can't find it in the code. Keep, remove, or update?
- `<file>`: table of numbers looks like real tabular data. Keep as a table or convert?

## Stale references fixed
- `<file>:<line>`: `<old path>` to `<new path>`.

## Stale references unresolved
- `<file>:<line>`: references `<thing>` which I cannot verify. Flagged for human.

## Style convention chosen
- Heading case: <Title / Sentence>
- English variant: <US / UK>
- Bullet character: <`-` / `*`>

## Summary
- Tables removed: <count>
- References fixed: <count>
- Sections moved: <count>
- Typos fixed: <count>
- Files awaiting user input: <count>
```
