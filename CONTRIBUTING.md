# Contributing to apprentice

Thanks for helping! apprentice is **vibe coded**: most of the code was written
by an AI (Claude Code) with a human steering, reviewing and testing. That means
two things for you:

- There are rough edges. Bug reports are genuinely useful, even small ones.
- The architecture and its rules are written down, because the AI needed them
  too. Read [`AGENTS.md`](AGENTS.md) before a non-trivial change: it is the
  best map of the code and the rules every coding agent here follows.
  [`SPEC.md`](SPEC.md) is the design: input and pacing, the approval gate,
  site rules and exit codes.

## Reporting a bug

[Open an issue](https://github.com/robertsolves/apprentice/issues/new/choose)
and pick the bug template. The most useful details are: macOS version, which
app or site, local or in the Linux VM, the command you ran and its exit code,
and `apprentice version`.

Never paste API keys, `config.toml` with `api_key` set, or screen text with
personal data into an issue. Security problems go through
[`SECURITY.md`](SECURITY.md), not public issues.

## Getting set up

You need macOS 14+ and the Xcode command-line tools (`xcode-select --install`).

```sh
swift build                       # .build/debug/apprentice
.build/debug/apprentice selftest
./kit.sh                          # release build, self-test, sign, install to ~/.local/bin
apprentice stop                   # so the next command starts the new daemon
```

Test anything that touches the screen against the binary `kit.sh` installs:
Accessibility and Screen Recording are granted to the signed binary, and an
ad-hoc signed debug build loses them on every rebuild.

CI builds the universal release binary and runs `selftest` on every PR.

## Making a change

- Comment on an issue before starting something large so work isn't duplicated.
- **Real input only.** Every action is a real cursor move, click, scroll or
  keystroke. No accessibility presses, no values set through AX, no events
  posted to an app's process. Accessibility is for reading the screen.
- **No app- or site-specific code.** Knowledge about one app or site goes in
  [`playbooks/`](playbooks/README.md); code stays generic. A good playbook is a great
  first contribution.
- **Safety is the product.** Every state-changing command goes through the
  approval gate, budgets, cooldowns, allowlists and site policies. Don't add a
  path around them.
- **Scope.** apprentice is built for one person at a pace they could keep by
  hand. Bulk outreach, mass following, scraping at volume, multiple accounts on
  one site and ways around CAPTCHAs or checkpoints are out of scope, and PRs
  that add them won't be merged.
- Add a check to `apprentice selftest` (`SelfTest.swift`) when you fix a bug
  in a part it covers.
- A new daemon command needs its `case` in `Commands.dispatch`, a line in
  `usage()`, an MCP tool if agents should see it, and updates to
  `agent/SKILL.md` and `agent/AGENTS.md`. Exit codes must stay in sync with
  `SPEC.md` and the agent docs.
- Match the style of the surrounding code. Keep PRs focused: one fix or
  feature per PR.

Using an AI assistant for your PR is welcome; just review what it wrote as
carefully as you'd review a stranger's code, and make sure `selftest` passes.

## License

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE).
