## What & why

<!-- What does this change, and which issue does it address? (e.g. Fixes #12) -->

## How it was tested

<!-- Apps or sites you tried it on, local or in the Linux VM; new selftest checks. -->

## Checklist

- [ ] `swift build` and `apprentice selftest` pass
- [ ] Input is still real cursor and keys only (no AX actions, no events posted to a process)
- [ ] No app- or site-specific code paths (that knowledge goes in `playbooks/`)
- [ ] State-changing commands still go through the approval gate and site rules
- [ ] `agent/SKILL.md` and `agent/AGENTS.md` updated if commands or exit codes changed
- [ ] No API keys, passwords or personal screen text in the diff
