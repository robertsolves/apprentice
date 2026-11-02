# Security policy

apprentice drives a real cursor and keyboard, reads whatever is on screen, and
can hold an API key, so security reports are taken seriously.

## Reporting a vulnerability

Please **do not open a public issue**. Report privately through
[GitHub's private vulnerability reporting](https://github.com/robertsolves/apprentice/security/advisories/new)
or by email to hello@robertsolves.com.au.

Include what you found, how to reproduce it, and the impact you expect. You
should hear back within a week.

## Scope

Of particular interest:

- Ways around the approval gate: an action that runs without an approved
  token, or a ⚠ step that isn't flagged.
- Prompt injection: text on a screen or page that makes apprentice, or the
  agent through its docs, act without approval or write into `notes/`.
- Bypasses of the allowlist, site budgets, cooldowns, challenge stops or
  forbidden-site policies.
- The daemon socket (`~/.apprentice/sock`) or the VM's ssh helper accepting
  commands from another user or host.
- Leaks of typed text, passwords, API keys or blocked apps into logs, step
  files, notes or screenshots.
- The self-update path running code that didn't come from `upstream`.

apprentice needs Accessibility and Screen Recording to work; holding those
grants alone is not a vulnerability.

## Supported versions

Only the latest commit on `main` and the latest release receive fixes.
