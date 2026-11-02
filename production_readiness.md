# Production readiness

An audit of apprentice against six requirements: install and work out of the box, update itself (with an
opt-out), keep fixes locally and open a PR with one command, log every session, keep per-model pipelines
so a repeat task is faster, and keep everything learned in the local clone. UI/UX is audited last.

Nothing here is implemented yet. Each item names the file it touches and the test that proves it.

## Verdict

| Requirement | Today | Verdict |
| --- | --- | --- |
| Installs and works out of the box | `install.sh` + `kit.sh` do the whole install; Accessibility and Screen Recording are still two manual System Settings steps, and there is no `doctor` or `uninstall` | **close** — 2 blocking gaps |
| Auto-updates, can be turned off | `Repo` already checks, rebases, rebuilds, self-tests, rolls back and honours `[update] auto = false`; `selftest` covers four failure modes | **done** — 3 hardening gaps |
| Bug → local commit → one-command PR | `bug` files into `bugs.md` and commits locally; there is no PR command and `upstream` is deliberately unpushable | **missing the PR half** |
| Every session logged | `steps.jsonl` per session with diffs, timings, errors; client-side commands are not logged, and there is no session summary | **partial** |
| Per-tool/site pipelines cached per model | Flows (`learn`/`do`) and `routes.toml` exist, but nothing records or matches the model | **missing the per-model key** |
| Everything saved in the local clone | Notes, flows and `bugs.md` are in the clone; sessions, events, budgets and settings are in `~/.apprentice` and pruned at 30 days | **missing, and needs a privacy decision** |
| UI/UX production ready | Question windows, start-up options, exit codes and `--json` are solid; no status surface, no onboarding, and a waiting question blocks every other command | **partial** |

## What already exists (do not rebuild)

- **Install**: `install.sh` checks macOS 14 and Swift, clones to `~/.apprentice/src` with `upstream`
  fetch-only (push URL set to `no-push`), rebases on re-run, sets a git identity, runs `kit.sh`, then Tart
  and `vm setup` unless `APPRENTICE_SKIP_VM=1`. `kit.sh` builds release, runs `selftest`, signs with a
  stable local identity so TCC grants survive, swaps the binary by rename, updates the VM, runs
  `agent/connect.py`, links `~/.apprentice/notes` → `notes/`, writes example configs and puts
  `~/.local/bin` on PATH.
- **Updates**: `Repo.auto`, `Repo.checkSeconds`, `scheduleChecks` (60 s after start, then every
  `check_hours`), `checkInBackground`, `applyUpdate` (clean tree + base branch only, rebase, `kit.sh`,
  `git reset --hard` on failure), `notice`, and the `updateLine` the next `session` prints.
  `SelfTest.updates` covers clean, dirty, conflict and failed-build against throwaway repos.
- **Local fixes**: `Repo.commit` scopes a named path so the user's staged work stays out; `Notes.fileBug`
  appends `### F<n>` and commits only that file. Nothing in the tool pushes: `upstream` is fetch-only.
- **Logging**: `Store.log` writes one JSON row per command into `runs/<date>-<session>/steps.jsonl`
  (`cmd`, `ms`, `waits`, `diff`, `url`, `host`, `kind`, `vm`, gate results, errors, `ask`/`show`), with
  `Privacy.blocked` skipping password managers, banking and health; `events.jsonl` keeps site events for
  180 days; `Grow` digests both; `pruneLogs` deletes run folders older than 30 days.
- **Reuse**: `Notes.context(task:session:)` injects the window's key facts and the best-matching flow into
  `run`'s prompt; `do <flow>` replays a flow with one approval; `Routes` maps task words to a faster tool.

## G1 · Install and first run

Blocking:

1. **Two permission grants are manual and unverified.** `requireAccessibility()` throws exit 7 with a
   message, but nothing tells the user *which* pane to open or whether Screen Recording is granted
   (Accessibility alone passes `read`; `shot`/`ocr` then fail later, mid-task). Add
   `apprentice doctor [--fix]`: version, Swift, binary path, both TCC grants (via
   `AXIsProcessTrusted()` and `CGPreflightScreenCaptureAccess()`), daemon reachability, notes symlink,
   config parse, git remotes, VM state, PATH. `--fix` opens
   `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` and
   `…?Privacy_ScreenCapture` and re-checks every two seconds until granted. `install.sh` ends by running it.
2. **No uninstall.** A desktop tool that writes a PATH line, a login-keychain certificate, a symlink, a
   VM and a LaunchAgent-shaped daemon needs `apprentice uninstall [--keep-notes]`: stop daemons, delete the
   binary, the certificate, the PATH block between markers, the symlink, `~/.apprentice` state, and the
   VM (`tart delete`). Print what it will remove first, and require `--yes`.

Hardening:

3. **Swift is a hard prerequisite.** `xcode-select --install` is a multi-GB GUI download, which is the
   single worst step of "just works". Publishing a signed, notarized universal binary as a release asset
   and having `install.sh` prefer it (falling back to building) removes the toolchain for most users. If
   that is out of scope for now, say so in the README rather than leaving it implicit.
4. **`kit.sh`'s fallback is silent-ish.** If `security import` fails, it ad-hoc signs and warns, but the
   consequence — every update silently invalidating the Accessibility grant — deserves a `doctor` check
   and a line in the README.
5. **First-run smoke test.** After grants, run one read of Finder and print a green checklist. Today the
   first real proof the tool works is an agent's first command failing with exit 7.
6. **`~/.apprentice` is world-readable.** `Store.dir` is created with default permissions and holds URLs,
   page titles and screenshots. `chmod 0700` the directory and `0600` config/state on creation.

Acceptance: on a clean Mac with only the Xcode CLT, `install.sh` finishes, `doctor` reports two missing
grants and opens both panes, and after granting them `doctor` exits 0 and a scripted `session --app Finder
&& read --max 3` succeeds without further input.

## G2 · Updates

Already correct, including rollback. Three gaps:

1. **A silent no-op.** `Repo.applyUpdate` starts with `guard installedHere || testRoot != nil else { return
   false }`. If the clone moves (or the notes symlink points elsewhere), auto-update stops and says
   nothing. Emit a `notice` ("updating is off: `~/.apprentice/notes` no longer points at this clone").
2. **Restart can land mid-task.** `startUpdate` restarts through `Wire.stopDaemon()` as soon as the build
   finishes. `session.json`, `pending.json` and `pace.json` survive on disk, so the next command resumes,
   but a pending approval silently disappears and a running flow stops between steps. Gate the restart:
   skip while `Approvals.pending != nil`, while a VM call is in flight, or while the last command row is
   younger than ~60 s; check again on the next timer tick instead.
3. **Supply-chain trust is implicit.** The daemon pulls and executes code from `upstream` with no review.
   Keep auto-on (it is the requested behaviour) but document it in the README's security section, and
   refuse non-HTTPS or `file://` remotes for auto-update (`APPRENTICE_UPSTREAM` stays allowed for manual
   `update`). `auto` and `check_hours` are already documented in `agent/config.example.toml`; only the
   trust model is missing.

Also: `apprentice version` prints a hardcoded `0.1.0` (`main.swift`), which cannot distinguish an updated
build from an old one. Derive it at build time (`kit.sh` writes the short hash into a generated
`Version.swift`, or read `git describe --tags --always` at runtime) and print `0.1.0 (<hash>)`.

Acceptance: `selftest` still passes; with a pending approval, an available update is not restarted into;
moving the clone makes `session` print the updating-off notice.

## G3 · Bug → local commit → PR in one command

The local half is done. The PR half does not exist: there is no `pr` command, `gh` is not used anywhere
except as route keywords, and `upstream`'s push URL is `no-push`, so a fork remote is required by design.

Add `apprentice pr [--title t] [--draft] [--repo owner/name] [--fork remote] [--local]`:

1. Refuse unless the tree is clean and `selftest` passes (reuse `Repo.run("bash", kit.sh)`? no — run the
   installed binary's `selftest`, which is cheap and does not rebuild).
2. Create or reuse `fix/<slug>` from the current commit when HEAD is on the base branch, so the PR is a
   reviewable branch, not the user's main.
3. Push to a fork remote. `install.sh` sets `upstream`'s push URL to `no-push` on purpose; add
   `APPRENTICE_FORK` or a `fork` remote on first use (document `git remote add fork git@github.com:you/apprentice.git`).
   Never force-push, never push to `upstream`.
4. Build the body from `git log --format='- %s' upstream/main..HEAD`, the `bugs.md` entries the commits
   name (`F<n>`), and the relevant `grow` lines. Title defaults to the first commit's subject.
5. `gh pr create --repo <upstream> --head <fork>:<branch> --base <base> --title … --body …` when `gh`
   exists and is authenticated; otherwise `--local` writes `PR.md` and prints the compare URL. Detect `gh`
   once and say exactly what to install, rather than failing with a shell error.

Two supporting changes the loop needs:

- **`bugs.md` has no closed state.** `grow` lists every `### F` line forever, so a fixed report looks open.
  Add `apprentice bug --fixed F3` (or a `status: fixed <hash>` line) and have `grow` list only open ones
  and `pr` cite the closed ones.
- **A PR needs a diff worth reviewing.** `Repo.commit` messages are one line by design; that is fine, but
  `pr` should refuse a branch whose only change is `bugs.md`, which would otherwise open empty PRs.

Acceptance: in a test clone with a fork remote pointing at a second local repo, `pr --local` writes a body
that lists the commits and the closed reports and prints a URL; `pr` on a dirty tree exits 5 with the dirty
paths; a branch changing only `bugs.md` is refused.

## G4 · Log every session

What exists is good: one row per command, diffs, timings, errors, questions, screenshots, privacy filter,
30-day pruning, `log --tail`, `grow`.

Gaps:

1. **Client-side commands are not logged at all.** `main.swift` answers `route`, `notes`, `policy`,
   `budget`, `activity`, `flag`, `learn`, `bug`, `commit`, `update`, `settings`, `repo`, `grow`, `vm`,
   `selftest` in the client process, so no `steps.jsonl` row is written. Those are exactly the
   learning-relevant commands: a session that reads as "read, click, done" hides the `learn` and `bug` that
   followed. Add a `Store.log([...])` at each case (a one-line helper, e.g. `logClient(command, rest)`),
   before the output is printed.
2. **No session summary.** "See what we did in a session" is `log --tail`. Add `apprentice log --session
   [<id>] [--since]` that prints one line per step, the diff summary, the errors, the questions, and a
   closing count; and a `sessions` listing of recent run folders with app, URL, steps and duration.
3. **The task is not recorded.** `run "task"` logs each command but never the task line, and a plain
   agent session has no user intent at all. Log a `task` row from `AgentLoop.run` and from `session` when
   `--task`/`--goal` is passed (add the flag; it costs nothing and makes every log readable).
4. **No `model` field.** Without it, requirement G5 cannot be measured and `grow` cannot answer "which
   model wastes actions". When `APPRENTICE_MODEL` or `run --model` is set, add `model` to every row (the
   daemon can read it from the `Request`, so pass the model through the wire for `run`-driven commands).
5. **Disk growth.** Screenshots are only pruned with their 30-day folder; a long session can hold
   hundreds. Cap the folder (keep the newest N shots, and always keep those a gate proposal referenced).

Acceptance: run `session`, `read`, `learn "x"`, `bug "y"`, then `log --session` shows all four, with the
model on each row, and `grow` counts the `learn`/`bug` calls.

## G5 · Per-model pipelines and tool shortcuts

Today the memory is site/task-shaped and model-blind:

- `Notes.learn` drafts `notes/flows/<slug>.md` from the session's approved steps; `do` replays it;
  `Notes.context(task:session:)` puts the best word-overlap flow into `run`'s system prompt.
- `Routes` (defaults + `routes.toml`) maps task words to a faster tool (`gh api`, connectors) but is
  static: nothing records that a route actually worked, or for which model.
- Front matter has `scope`, `match`, `system`, `tags`, `lang`, `verified`, `status` — no `model`, no `tool`.

Changes:

1. **Key the pipeline by model.** Add `model: <name>` (or `model: any`) to flow front matter; `learn`
   writes it from `--model` / `APPRENTICE_MODEL` / `[run] model`; `do` and `Notes.context` rank an
   exact-model flow above `any`, then by tag overlap. This is the requested behaviour: the same model on a
   similar task finds its own cached plan first.
2. **Add a `tool:` scope for non-UI pipelines.** A flow whose steps are shell commands (or a `route`) is
   as reusable as a click list: `gh pr create`, `git rebase -i`, `tart`, `ssh`. Give flows an optional
   `tool: <name>` and let `do` run `sh:` steps under the same single approval, so "shortcuts for every tool
   or site" is one mechanism rather than two.
3. **Record that a route paid off.** On a successful `do` or a route the agent followed, append to
   `notes/routes-learned.toml` (in the clone) `{ domain, task keywords, tool, model, hits, last }`; `route`
   ranks a learned entry above a static default when the model matches. Static `routes.toml` stays the
   seed.
4. **Make similarity explicit and cheap.** Word overlap with a minimum score, tags first, then `match`
   (host/app); prefer `status: verified` over `draft`; cap injected context (it is concatenated into the
   prompt today with no budget). Add `do --explain` showing which flow was chosen, why, and its score —
   otherwise a wrong pick is invisible.
5. **Cache the index.** `Notes.all()` walks and parses every Markdown file on each call (three calls per
   `session`). Memoize per process keyed on directory mtime; at a few hundred notes this is the difference
   between 1 ms and 100 ms on every command.

Acceptance: `learn "post a draft" --model m1` writes `model: m1`; `run "post a draft" --model m1` chooses
that flow, `--model m2` does not; `do --explain` prints the score; a `tool: gh` flow runs its `sh:` step
under one approval.

## G6 · Everything saved in the local clone

Today:

- In the clone: `notes/`, flows, `bugs.md`, `production_readiness.md`, `FEATURES.md`.
- Outside, in `~/.apprentice`: `runs/` (steps, screenshots), `events.jsonl`, `budgets.json`, `limits.json`,
  `vm/state.json`, `config.toml`, `routes.toml`, `sessions`/`pace`/`pending` per VM, plus the socket and pid.
  `pruneLogs` deletes runs after 30 days, so a PR cannot learn from them.

Two decisions must be made before writing code, because they conflict:

**The privacy tension.** Session rows contain page URLs, element names, menu paths and diff text;
screenshots contain the screen. `Privacy.blocked` covers password managers, banking and health, but not
email, DMs, or an internal intranet. `Repo` is meant to be pushed upstream as a PR. Committing raw sessions
turns every PR into a potential leak of what the user was doing, and of their employer's data.

**Recommended shape** (keeps the requirement, removes the leak):

1. Keep `runs/` where it is: raw, local, pruned, permission `0700`. Raw screenshots never enter the clone.
2. Add a **scrubbed** `sessions/<date>-<session>/` inside the clone, written by the daemon at session end:
   the task line, the ordered commands with `diff` summaries, timings, errors and exit codes, hosts (not
   full URLs — `host` only, query strings stripped), the model, and the flows/reports the session produced.
   No typed text, no screenshots, no page titles. Skip the whole session when `Privacy.blocked` matched it.
3. Make it a setting, `[storage] sessions = "scrubbed" | "full" | "off"`, defaulting to `scrubbed`, so a
   private clone can keep `full` and a cautious user can keep `off`.
4. `pr` includes `sessions/` only when the setting is not `off`, and prints how many sessions and bytes it
   is about to publish, with the hosts they touch.

Implementation constraint found while auditing: `Notes.repo` derives the clone from the notes symlink,
which derives from `Store.dir`, so `Store` cannot simply move into the clone — the cycle is
`Store.dir → Notes.dir → Repo.root → Store.dir`. Break it by recording the clone path in
`~/.apprentice/install.json` (written by `kit.sh`) and reading that in `Repo`, keeping `~/.apprentice` as
the pointer and the clone as the store. Do not hardcode `~/.apprentice/src`: `install.sh` honours
`APPRENTICE_DIR`.

Also in this group: `.gitignore` currently ignores only `.build/`, `.swiftpm/`, `*.o`, `.DS_Store` and
Python caches — correct for the plan above, but add `sessions/**/shots/` and `*.png` as a belt-and-braces
guard against a screenshot landing in a session folder.

Acceptance: a session leaves a scrubbed folder in the clone with no URLs, no typed text and no images;
`pr --local` lists the sessions it would publish; with `sessions = "off"` the folder is not written.

## G7 · UI/UX

Working well: the approval-then-act flow with `⚠` warnings, the token/`--json` protocol, exit codes,
`away`/`ask_in` hand-off to the chat, the start-up options window, the kill switch, and compact agent-facing
text.

Problems, in order of how much they cost a real user:

1. **A waiting question blocks every other command.** `Wire.swift:281` runs every command through
   `Daemon.queue.sync`, and `Ask.run` waits on that queue for up to `ask_window_s`/600 s. While one agent
   is asking, `approve`, `log`, `status` and a second agent's commands all queue behind it and eventually
   time out. Move the user-facing waits (`ask`, `show`, `confirm`, the start-up options) off the serial
   command queue onto their own concurrent queue — they only need the main thread, not exclusivity — while
   keeping screen actions serialized. This is the most important UX fix in this document.
2. **No ambient status.** An agent working looks like an idle Mac; an agent waiting for approval looks the
   same as one that crashed. Add an `NSStatusItem` with four states (idle, working, waiting for you, needs
   approval), the session's app/host as its title, a menu with `log`, `approve`/`deny` for the pending
   token, `stop`, and the last update notice. It also gives update and permission failures somewhere to
   appear besides the next command's stderr.
3. **Questions can be missed.** The panel is `.floating` with no `collectionBehavior`, so it does not join
   other Spaces or sit above a full-screen app. Set `[.canJoinAllSpaces, .fullScreenAuxiliary]`, centre it
   on the screen with the cursor, and keep the `ask_sound` ping. A repeat ping after 30 s of no answer is
   cheap and would prevent the exit-9 hand-off happening to someone sitting right there.
4. **The windows are not accessible.** They are AppKit controls, which is a good start, but nothing sets
   accessibility labels for the question text, the choices or the diff in `confirm`; the fixed 380 pt panel
   with a wrapping label truncates long questions and long element names. Autosize to content with a cap,
   set labels, and make Return/Escape behaviour visible in the button titles.
5. **Onboarding is a wall of text.** The install prints eight paragraphs and then asks the user to grant two
   permissions by hand. Replace it with `doctor --fix` (G1) and one screen: what apprentice is, the two
   grants with live check marks, a "try it on Finder" button that runs `session`/`read` and shows the
   result. You need a bundle for a proper window at install time; until then a terminal checklist is
   acceptable, provided it is interactive and verifies rather than instructs.
6. **Docs drift.** The README's command table still documents `settings [github | local | sync]` and a
   private GitHub repo, while `Settings.run` accepts only `local`; the agent docs carry no stale GitHub
   text, but the new commands (`doctor`, `pr`, `sessions`, `log --session`, `uninstall`) must go into
   `usage()`, `agent/SKILL.md` and `agent/AGENTS.md`, since `AGENTS.md` requires the exit codes and
   command lists to stay in sync.
7. **Kill switch discoverability.** It is in the README but not in `usage()` or the start-up window. One
   line in both is enough.

Acceptance: with a question open, `apprentice log --tail` returns immediately; the menu-bar item shows
"waiting for you" while a question is open and "needs approval" while a proposal is pending; a question
raised from another Space appears; VoiceOver reads the question and its choices.

## Cross-cutting

- **Versioning and releases**: derive the version from git (see G2), tag releases, and let
  `update --check` say what is new in user terms (the commit subjects are already good).
- **Tests**: `selftest` is strong on the pure parts but has no coverage of `Notes` (front matter, `steps`,
  `learn` drafting), `Flows` (substitution, a failing step), `Routes`/`Grow`, `Budgets`/`Policies`,
  `MCP`'s tool list, or `agent/vm/helper.py`. The first four are pure and cheap; add them before the PR
  command ships, since a PR is the first thing that leaves the machine.
- **CI**: nothing runs on push. A GitHub Actions job on macOS with `swift build` + `selftest` would catch
  the class of breakage that just happened locally (a dangling `Settings.syncSoon` call left the tree
  uncompilable mid-refactor).
- **Crash visibility**: a daemon crash is silent; the next command restarts it and the user sees a fresh
  session. Log the crash reason and surface it in the menu bar and the next `session`.
- **Secrets**: `config.toml` can hold `[run] api_key`; ensure `doctor` warns if the settings directory is
  group/world readable, and never let a scrubbed session row carry an API key (the redaction list must
  include `api_key`, `token`, `password`, `secret`).

## Backlog, in order

| # | Item | Why now | Size |
| --- | --- | --- | --- |
| 1 | `doctor [--fix]` with TCC checks and pane links; `install.sh` ends by running it | Without it "just works" is false | S |
| 2 | Move `ask`/`show`/`confirm`/start options off the serial command queue | A question currently freezes the whole tool | S |
| 3 | Log client-side commands; add `model` and `task` rows; `log --session`, `sessions` | Every later feature reads these rows | S |
| 4 | `[storage] sessions = scrubbed` + scrubbed session writer in the clone | Makes "learn from a PR" real without leaking | M |
| 5 | `model:`/`tool:` on flows; model-first ranking; `do --explain`; `routes-learned.toml` | The per-model cache requirement | M |
| 6 | `pr [--local] [--draft]`, fork remote, `bug --fixed`, `grow` filtered to open reports | The one-command PR requirement | M |
| 7 | Update restart guarded on pending approval; notice when auto-update is off; version from git | Auto-update is on by default, so its edges matter | S |
| 8 | Menu-bar status item with approve/deny and links to `log` | The missing ambient UI | M |
| 9 | `uninstall`; permission check for `~/.apprentice`; notarized release binary | Install hygiene | M–L |
| 10 | README/`SKILL.md`/`usage()` sweep; `selftest` for Notes/Flows/Routes/Grow; CI | Keeps the above from drifting | S |

## Decisions needed

1. **Sessions in the clone**: scrubbed-by-default (recommended), full, or off? This changes what a PR
   publishes.
2. **Auto-update trust**: keep auto-on with HTTPS-only remotes and a documented trust model, or default to
   `auto = false` for the first release and turn it on after a few weeks? The requirement says auto-on;
   the security review says warn loudly.
3. **Distribution**: build from source (today, needs the toolchain) or ship a notarized binary as the
   primary path?
4. **PR target**: the public upstream directly, or always a fork plus `gh pr create`? A fork is the only
   safe default given `upstream`'s push URL is `no-push`.

## Definition of done

- Clean Mac, `install.sh`, `doctor --fix`, two clicks, one smoke test — no other steps.
- `[update] auto = false` leaves the clone untouched and `session` says an update is waiting.
- `bug "…" --fix "…"` → `commit` → `pr --local` → a PR body that names the closed report and the commit.
- Every command, including `learn`, `bug`, `route` and `policy`, appears in the session log with its model
  and exit code; `log --session` reconstructs the session in one screen.
- The same model asked to repeat a task picks its cached flow (`do --explain` proves it); a different model
  does not, unless the flow says `any`.
- A scrubbed session folder exists in the clone, holds no URL, typed text or image, and `pr` reports what
  it publishes.
- With a question open, another command returns immediately, and the menu bar says who is waiting.
