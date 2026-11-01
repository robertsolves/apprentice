# apprentice — bug audit

## Field reports

Filed by `apprentice bug` while working. Each has a suggested fix to review; none is applied.

### F1 · `vm install` leaks the host's `[vm]` keys into the previous section of the guest config — 2026-11-01
- Cause: `VM.install` filters the host's config with `!$0.hasPrefix("[vm]")`, which drops the header but keeps its keys, so `name`, `home`, `image` and `password` end up under whatever section came before them.
- Suggested fix: track the current section while filtering and drop the `[vm]` section with its body, instead of only the header line.

### F2 · `VM.run` can deadlock when a caller passes a large stdin — 2026-11-01
- Cause: `VM.run` writes the whole `input` to the child's stdin before it starts reading stdout, so a child that both reads more than a pipe buffer and writes more than one to stdout blocks while the writer blocks too. Today's callers (`vm install`'s tar, `wire`'s one line) stay under the limit, so this is latent, not live.
- Suggested fix: write stdin from a background queue in the same `DispatchGroup` as the stderr drain, so stdout is read while the child is still consuming its input.

### F3 · A mixed-case pacing profile is silently ignored — 2026-11-01
- Cause: `Config.load` keys `profiles` by the section as written, while `profileKey` lowercases the host before looking it up, and `profiles[session.app]` matches only exactly. `[pace."LinkedIn.com"]` therefore does nothing, and `[pace."Safari"]` works only because the app name happens to be spelled that way.
- Suggested fix: lowercase the key in `load()` and lowercase `session.app` at the app lookup, so every spelling matches.

### F4 · MCP answers `budget`, `policy` and `activity` from the host while the browser runs in the VM — 2026-11-01
- Cause: `MCP.runLocally` and `MCP.map` call `Budgets.report` / `Policies.describe` / the daemon directly. Only the CLI forwards these to the guest (`VM.forward` in `main.swift`), so with `vm on` an MCP client sees the host's budgets, events and policies, which are for a machine taking no actions.
- Suggested fix: forward the same three commands through `VM.forward` when the VM is on, as `main.swift` does, and answer from the guest.

### F5 · `do <flow>` echoes filled step text, so a value passed as a var reaches the chat and the log — 2026-11-01
- Cause: `Commands.runFlow` prints the step after `fill`, so `type #textbox "..." "{password}" --enter` appears in its ✓ and ✗ lines with the value substituted, unlike `type`, whose log rows never carry typed text.
- Suggested fix: print the unresolved step (`{password}`) and mask values whose key contains `password`, `token` or `secret`.

### F6 · `usage()` still advertises `settings [github | local | sync]` — 2026-11-01
- Cause: `Settings` no longer has a GitHub sync (`Settings.run` accepts only `local`), and `agent/SKILL.md` and `agent/AGENTS.md` still describe `settings github` and `pr`.
- Suggested fix: drop the removed subcommands from `usage()` and both agent docs in the same change that removes them from the code, so the exit-code and command lists stay in sync.
