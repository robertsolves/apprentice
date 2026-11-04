<p align="center"><img src="assets/icon.svg" width="96" height="96" alt="apprentice"></p>

# apprentice

apprentice lets a coding agent or a hosted model use macOS, Linux and the web for you the way a careful person would, not a bot. It reads the window as a short numbered list, moves the real cursor and presses real keys. It proposes every change and waits for approval. When it is unsure it asks you, and it writes down what it learns so the next run is quicker.

You don't type its commands. You ask your coding agent (Claude Code, Codex, Gemini CLI, Freebuff, Cursor and the rest) as you normally would, and it runs apprentice for you:

```
you    Download my January internet bill and put it in ~/Documents/Bills.

agent  (reads the dashboard, opens January's bill, presses Download: you asked for that, so it approves it)
       Saving to ~/Downloads. You said ~/Documents/Bills, so I've asked you in the window.

you    (chooses ~/Documents/Bills in the save panel)

agent  Saved: Internet, January, $84.20.
```

The agent's words vary by model. What doesn't: every change is proposed first, the agent approves the steps you asked for, and anything risky you didn't mention (spending a credit, sending, deleting) comes to you in apprentice's window, or in the chat when you're away.

## What you can ask

Anything you'd do yourself with the mouse and keyboard, one task at a time:

- "Download my January internet bill and put it in ~/Documents/Bills."
- "Forward the invoice from Acme to my accountant."
- "Move my dentist appointment from Tuesday to Thursday."
- "Fill in the passport renewal form with my details from contacts.md."
- "Turn on Do Not Disturb from 10pm until 8am."
- "Post this changelog to the #updates channel in our Discord."
- "Reorder the coffee beans I bought last month."
- "Rename the screenshots in ~/Downloads to YYYY-MM-DD and move them to ~/Pictures/Screenshots."
- "Do the weekly Shopify stock check like last time." (a flow it learned earlier, rerun with one approval)
- "In the Linux VM, open the staging site in Chromium and check the login page loads."

It reads the screen as text, proposes each change, and asks you before anything risky: sending, posting, deleting, buying, passwords and settings. It won't do bulk outreach, mass following, scraping at volume or run several accounts on one site.

Under the hood, the agent calls the CLI. Part of the same task from its side:

```
$ apprentice read --filter spin
14 link "Spin · Thu 7:00 AM · 3 spots"

$ apprentice click 22
approve? click 22 button "Book"
⚠ may be irreversible: button "Book"
nothing was done. approve: apprentice approve 9f1b · deny: apprentice deny 9f1b

$ apprentice approve 9f1b
ok · snap 4 · +2 -0 ~0
+ 23 text "This uses 1 credit from your class pack."
+ 24 button "Confirm"
```

## How it works

- **It reads text, not pixels.** The macOS accessibility tree becomes a numbered list of what is on screen. A step costs tens of tokens, not a screenshot. `shot` and `ocr` exist for the rare page that hides from accessibility.
- **It uses real input only.** Every click, scroll and keystroke goes through the system's own input stream with the window in front, and the cursor moves at a human pace along paths that vary every time: different curves and speeds, overshoot and correction, all drawn from one fast random generator. Nothing is injected into pages, and nothing is pressed through accessibility. Addresses and file-dialog paths are pasted, because no website can see those boxes. Text inside pages is typed key by key, with Shift as a key of its own, keys that overlap as fluent typing does, and dead keys for accents; only a character no key types (an emoji) is pasted. The hand's speed and typing rhythm are kept across restarts, so the person never changes.
- **It stops for you.** It waits until you have been idle for a moment. If you press a key or click while it is acting, it stops with exit 6 and leaves the cursor where you are. ctrl+opt+cmd+. is a kill switch: nothing more runs until you answer the agent or click Resume in the menu bar.
- **It proposes, then acts.** Every command that changes something (`open`, `click`, `type`, `key`, `menu`, `drag`, `upload`, `download`, `choose`, `do`) returns `approve? …` and a token, with exit 8. Nothing happens until `apprentice approve <token>`. Steps that look risky carry a `⚠` line: send, post, delete, buy, a password field, a settings page.
- **It asks you.** For any decision that is yours, it opens a little window at the top of the screen and pings:
  - `ask` takes free text or choices;
  - `show` has you point the cursor at something;
  - `confirm` puts a risky step in front of you to approve or deny.

  When you are away from the Mac (`apprentice away on`, or nobody answers within a minute), the question comes back with exit 9 and the agent asks you in the chat instead, with a screenshot of what it is about. Say "set up my phone" once: `apprentice phone` gives you one link to tap (an ntfy topic), and from then on those questions also buzz your phone.
- **It fixes itself.** apprentice runs from your own local clone. When it gets something wrong, the agent fixes the playbook or the code and commits each small change with `apprentice commit`, which rebuilds, self-tests and restarts apprentice with the fix. Your commits stay in your clone.
- **It updates itself.** Every few hours it checks its upstream. When there's something new, it rebases your commits onto it, rebuilds, runs its self-test and restarts once nothing is waiting on you (no pending approval, no open question, no command in the last minute). The next `session` tells you. If the build or test fails, it stays on the old version. Set `[update] auto = false` to only be told, then run `apprentice update`.
- **It shares fixes in one command.** `apprentice pr` takes your local commits, checks the tree is clean and the self-test passes, pushes a `fix/…` branch to your fork and opens a pull request with `gh`. `apprentice pr --local` writes the description and prints a compare URL instead.
- **It shows what it is doing.** A menu-bar item reads `α` when idle, `α …` while working, `α ?` while a question waits for you and `α !` when a step needs approval. Its menu approves or denies that step, opens the session's log and stops apprentice.
- **It can keep the browser off your desktop, and drive Linux too.** A small Linux VM (about 2 GB, under a gigabyte to download) runs Chromium, a terminal and any Linux app you install, with its own screen, cursor and keyboard, so the agent works while you keep working. Terminal first: the agent runs commands over plain ssh (`apprentice vm shell`) and takes the screen (`session --app <name> --on linux`) only where no command does it. Approvals, budgets and logs stay on your Mac; `apprentice vm look` shows you the VM, and `apprentice vm call "what"` asks you into it when a site needs a person. The VM is Linux only for now; a macOS VM, for Mac apps and Safari, is planned.
- **One VM per job.** `APPRENTICE_VM=linkedin apprentice vm setup` makes another VM, and an agent session started with `APPRENTICE_VM=linkedin` works only there, so two agents run side by side without touching each other's browser. Each site's budgets and cooldowns count across all of them. Uploads and downloads move files between your Mac and the VM, and questions open on the VM's screen and on your Mac, so you answer wherever you are looking.
- **It remembers your usual.** When you say "my gym is …" or a task runs on a site you'll use again, the agent saves it (`apprentice remember gym "bookings.examplegym.com.au" --from you`), so next time it goes straight there instead of asking. It saves only your own words or the site or app a task ran on, never other text from a screen. `apprentice prefs` lists them, `forget` drops one. Each VM keeps its own `~/.apprentice` and clone, and inherits your Mac's values under its own.
- **It learns, per model.** Playbooks for apps and sites live in this repo under `playbooks/`, so updates share them. `learn` turns a task that worked into a flow tagged with the model that did it. Next time, the same model finds its own flow first (`do --explain "task"` shows the pick and why), and `do <flow>` reruns it with one approval for the whole plan, handing back if a step fails. Whenever asking you solved a problem, the playbook gets updated and a code fix is filed. See [How the next run gets faster](#how-the-next-run-gets-faster).
- **It logs every session.** Every command is logged, including the ones that don't touch the screen (`learn`, `bug`, `route`), with the model and the exit code. `apprentice sessions` lists recent sessions, and `apprentice log --session` replays one on a single screen.

## Install

You need macOS 14 or later.

**The app (recommended):** download [`apprentice-macos.dmg`](https://github.com/robertsolves/apprentice/releases/latest/download/apprentice-macos.dmg), drag Apprentice to Applications and open it. On first launch it puts `apprentice` on your PATH (`~/.local/bin`), brings in the playbooks, and connects your coding agents (that step needs python3 from the command-line tools; the Updates & health screen retries it). When a new release is out, the window says so and one click downloads it, checks it against the release's checksums and signature, and relaunches. `apprentice update` does the same from a terminal. Playbooks you change or learn stay yours across updates.

**From source** (to change apprentice and offer fixes back): you need Swift 5.9 (Xcode or `xcode-select --install`). One command installs it, and running it again updates; a clone install updates from git instead of releases, and takes over from the app when both are on the Mac:

```sh
git clone https://github.com/robertsolves/apprentice.git ~/.apprentice/src && ~/.apprentice/src/install.sh
```

`install.sh` clones into `~/.apprentice/src` (or `APPRENTICE_DIR`, or the clone of your last install, which it finds through `~/.apprentice/playbooks`). The clone is your copy: `upstream` is fetch-only, so your commits stay in it. Set `APPRENTICE_UPSTREAM` to install from another git URL (a server, a folder, another Mac's clone). Then it runs `kit.sh`. From a clone you already have, run `./kit.sh` directly.

`kit.sh` builds a release binary, runs its self-test (a failure keeps the installed one), and installs it to `~/.local/bin/apprentice`. It signs it with a local identity named `apprentice`, which it creates in your login keychain the first time, so your permissions survive rebuilds (set `APPRENTICE_SIGN_IDENTITY` to use another). A running Linux VM gets the new build too. It also:
- connects every AI assistant it finds on the Mac (`agent/connect.py`), and leaves out the ones that aren't installed:
  - the skill (`agent/SKILL.md`) goes to `~/.claude/skills` and the shared `~/.agents/skills`, which nearly every agent reads, and to `~/.factory/skills` (Factory Droid) and `~/.continue/skills` (Continue), which read only their own;
  - the instructions (`agent/AGENTS.md`) go between `<!-- apprentice -->` markers, replaced on every run, in the global rules file of each installed agent: Codex and the ChatGPT app, opencode, Kilo, Gemini CLI, Qwen Code, GitHub Copilot CLI, Amp, Factory Droid, Crush, Mistral Vibe, Continue, Augment's Auggie, and Freebuff and Codebuff (`~/.AGENTS.md`). The shared `~/.agents/AGENTS.md`, which Cline and goose read, always gets them. Kimi, Warp and Cursor's CLI have no global rules file and get the skill only;
  - the Claude desktop app and Cursor, which have no shell, get the MCP server (`apprentice mcp`);
- puts `~/.local/bin` on your PATH in `~/.zprofile` (or `~/.bash_profile`), so agents can run `apprentice`;
- links `~/.apprentice/playbooks` to the repo's `playbooks/`;
- writes example `config.toml` and `routes.toml` files, if you have none yet.

`install.sh` also installs Tart and sets up the Linux VM (`APPRENTICE_SKIP_VM=1` skips it). There is no macOS VM yet.

Last, `install.sh` runs `apprentice doctor --fix`. It checks the install, opens **Accessibility** and then **Screen Recording** in System Settings → Privacy & Security, waits while you switch apprentice on in each, restarts the daemon and runs a smoke test on Finder. Run `apprentice doctor` any time to see what's missing.

If `kit.sh` can't add its signing identity to your keychain, it signs the binary ad hoc. Then every rebuild or update drops the two permission grants. `doctor` warns about this; fix it by setting `APPRENTICE_SIGN_IDENTITY` to an identity you have, then re-running `kit.sh`.

`apprentice uninstall` lists everything apprentice installed, and `apprentice uninstall --yes` removes it: the binary, the agent skills and rules sections, the MCP entries, the signing identity, the PATH lines, the VMs and `~/.apprentice`. Your clone stays, since it holds your commits and playbooks; `--all` removes it too.

With `[agent] ask_on_start = true`, the first `session` after the daemon starts opens an options window (off by default, so nothing stands between install and the first task):
- **UI only:** no shell commands for macOS tasks;
- **Keep the Mac awake** while a task runs;
- **Allowed sites**, as a list;
- **Remember these** as your defaults.

## Commands

| Command | Does |
| --- | --- |
| `doctor [--fix]` | Check permissions, signature, PATH, clone and settings; `--fix` opens the panes and runs a smoke test |
| `session --app <name> [--new-window|--new-tab] [--allow a.com,b.com] [--task "…"]` | Attach to one app window (in a browser `--new-window` opens a tab, reusing a blank one; without `--new-tab` or `--new-window` the session can only read, scroll and browse, so a tab you had open is never navigated, typed in or closed); prints the policy and playbooks for that app or site. `--task` records what you asked for in the log |
| `read [--max 80] [--filter text]` | The numbered list of what is on screen |
| `click <id>` · `click --on "text"` · `click --at x,y` | Click an element, visible text (OCR if it is not listed) or a point |
| `type <id\|focused> "text" [--enter]` | Click into a field, then type, key by key |
| `key <combo>` · `menu "File > Save…"` | A shortcut, or a menu item clicked like a person |
| `focus <app> [--on mac\|linux]` | Bring an app or the VM's browser to the front and bind to it |
| `budget` · `cool` · `activity` · `flag` | What is left of the site caps, a site's cooldown, recent events, and flagging a page |
| `pace [site [style]]` | How fast a site or app goes; `fastest` for a site you scout without signing in |
| `serve` · `stop` · `replay <name> [--from n] [--approve]` | Run the daemon in the foreground, stop it, replay a saved run |
| `scroll`, `hover`, `drag`, `wait-for "text"` | The rest of what a hand does |
| `browse [seconds]` | Read down a page or feed at a reading pace, clicking nothing |
| `open <url>` | Navigate the browser window, at a polite pace |
| `upload <id> <file>` · `download <id> <path>` · `choose <path>` | Files, through the system's own dialogs |
| `approve <token>` · `deny <token>` · `confirm <token>` · `pending` | Approvals |
| `ask "question" [--choices "A\|B"] [--multi] [--text]` · `show "what"` | Ask the user in the little window |
| `playbooks "words"` · `playbooks --check` · `learn "task" [--model m]` · `do <flow> --key value` · `do --explain "task"` | Playbooks and flows; `--explain` shows which flow this model would pick, and why |
| `route "task"` | Check for a faster route (an API, `gh`, a connector) before using the screen; also prints matching preferences |
| `prefs ["words"]` · `remember <key> "<value>" --from you\|task [--on mac]` · `forget <key> [--on mac]` | What you use (your gym's site, your handles), on this device and inherited from its parent |
| `shot` · `ocr` · `log [--tail n]` · `log --session [<id>]` · `sessions` | A screenshot, OCR of the window, recent steps, one whole session, recent sessions |
| `project [init \| status]` | A project's own `.apprentice/` folder: its own site counts and tighter caps |
| `policy` · `away on\|off` · `phone [on\|off\|test]` · `awake on\|off` | Settings for shell use, remote questions and keep-awake |
| `grow` · `bug "summary" --fix "…"` | What to improve next, and field reports |
| `settings [local]` | Where the settings are; `local` moves an older synced copy back to this Mac |
| `commit "what and why"` · `update [--check]` · `selftest` · `repo` · `version` | A small commit (rebuilds on a source change), upstream fixes in by hand (it also updates itself), the built-in tests, where the clone is, and the installed commit |
| `pr [--title t] [--draft] [--fork remote] [--local]` | Offer your local commits upstream as a pull request, from your fork |
| `uninstall [--all] [--yes]` | List, then remove, everything apprentice installed |
| `vm setup` · `vm on`/`off` · `vm up`/`down` · `vm list` · `vm shell` · `vm watch` · `vm look` · `vm call "what"` · `vm install` | The Linux VM: make it, send browser sessions to it, start or stop it, print its ssh config, watch it in apprentice's window or click in it with Screen Sharing, bring the user into it, update what runs in it |
| `run "task" --model <name>` · `mcp` | A built-in loop for any OpenAI-compatible model, and an MCP server |

Add `--json` for the raw reply on the commands that go through the daemon, and on `route` and `playbooks`.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | ok |
| 2 | stale: the screen changed, or the page changed without apprentice; read it again (actions are refused until then) |
| 3 | The user denied the step |
| 4 | blocked: allowlist, rate limit, budget, a site cooling down after it throttled the account, or a check only the user may complete |
| 5 | not found, timed out, or a usage error |
| 6 | interrupted by the user during borrow mode, or by the kill switch (later steps are held until the user answers) |
| 7 | a permission is missing |
| 8 | approval needed: proposed, nothing done yet |
| 9 | ask the user in the chat: they are away or did not answer the window |

## Configuration

Settings are `config.toml` (see `agent/config.example.toml`), `routes.toml` and `budgets.json`, in `~/.apprentice/` on this Mac only. An older install that synced them with GitHub keeps reading them from `~/.apprentice/settings/` until `apprentice settings local` moves them back. Sessions, logs and screenshots stay on the Mac. The Linux VM gets a copy of your settings each time `kit.sh` or `apprentice vm install` runs.

`config.toml` has:

- **`[pace.*]`:** mouse, typing and navigation timing, with profiles per site or app. `style` sets them all at once: `fastest` (the default in apps: no waits, and text is pasted), `fast`, `steady` (the default on web pages), or `careful`, the slowest and least scripted, which is built in for Facebook, Instagram, Threads, TikTok, LinkedIn, X, Reddit, Pinterest, YouTube and Bluesky and also keeps quiet hours (2–6), takes a break after 50 minutes on a site and stops at 400 actions a day. `[pace.styles]` assigns a style to each site or app and wins over the built-in ones, e.g. `fast = ["web"]`; `apprentice pace example.com fastest` adds a site you only read without signing in, so it goes as fast as it can. `overshoot` and `fidget` tune how often the cursor passes its target and how often a harmless gesture (a glance, reading a few lines, a scroll and back) follows an action; `browse` and `browse_s` make a site now and then read down its feed for a while and scroll back. `steady` and `careful` turn them on.
- **`[session] allow`:** the sites a session may act on.
- **`[agent]`:**
  - `ui_only` turns off shell commands for macOS tasks;
  - `keep_awake` (on by default) keeps the Mac awake while a task runs and lets it sleep once the agent says `apprentice done`; `takeover_after_s` (30 by default) is how long you must be still before apprentice takes the cursor mid-task, `takeover_first_s` (5) is the wait before the first action of a task and `takeover_quick_s` (5) is what the overlay button "Go in 5 s" shortens the wait to;
  - `ask_in` (`both`, `window` or `terminal`) and `ask_window_s` decide where questions go;
  - `ask_sound` is the ping, or `"none"`;
  - `ask_on_start` shows the options window;
  - `menu_bar = false` hides the menu-bar item.
  - `overlay_open_on_work` and `overlay_hide_idle_s` (seconds, 0 never) say when the status box comes back and goes away; its yellow button hides it and the menu bar icon brings it back.
  - `overlay = false` hides the always-on-top status box (working, handed to you, paused; its icon opens the window; closing it asks, then stops apprentice).
- **`[update]`:** `auto = false` to only be told about updates; `check_hours` (6).
- **`[storage]`:** `sessions = "scrubbed"` (the default), `"full"` or `"off"`: what the clone keeps of each session (see below).
- **`[run]`:** the model endpoint for `apprentice run`.

Site rules ship as defaults and live in your own files:
- `budgets.json` caps each kind of action per site, per hour and per day, with a minimum gap. Only the caps in it apply; it starts with conservative ones for LinkedIn, X, Reddit, Instagram, Facebook and TikTok, well below shadow-ban levels.
- `[sites]` in `config.toml` says what a rate-limit message or a CAPTCHA does: `on_soft_block` and `on_challenge` are `stop` (the default), `warn` or `off`, and `cooldown_hours` sets the waits. apprentice never completes a CAPTCHA.
- `[gate] user_only` lists steps only you can approve, in apprentice's window or menu-bar item: payments, checkout, donations, transfers, CAPTCHAs, closing an account. Password fields always are.
- `[pace.styles]` lists the social sites on the `careful` style (dwell, bursts, rests, fidgets, quiet hours, breaks), with `[pace."<site>"]` sections for what differs.
- `[policy."<site>"]` in `routes.toml` is your note on a site's terms (link, date checked, official API). It never refuses a site: apprentice works on any site.

The counts behind budgets and cooldowns are kept in `~/.apprentice/limits.json`, shared by every session and VM. `apprentice budget` shows what is left.

A project can keep its own numbers too. `apprentice project init` in a project's folder makes a `.apprentice/` there. Commands run from inside that project then also count in its `.apprentice/limits.json` (git-ignored) and check its own `budgets.json`, if it has one, which can set tighter caps for that project. Project caps only add limits: the account-wide caps in `~/.apprentice` always apply as well, because a site sees one account, whichever project drives it. `apprentice project status` shows which folder is in use, and `APPRENTICE_PROJECT=<path>` or `off` picks one by hand.

`APPRENTICE_HOME` moves all state out of `~/.apprentice`.

The model driving apprentice is detected from the agent that runs it, so the log and learned flows know which model did what. For Claude Code that is the exact model of the session, read from its transcript. For Codex, Gemini CLI, opencode and Qwen it is the model in their config. Other agents are recognised by name, and MCP apps by the name they give. Set `APPRENTICE_MODEL` to override it. `APPRENTICE_UI_ONLY`, `APPRENTICE_MODEL`, `APPRENTICE_BASE_URL` and `APPRENTICE_API_KEY` override the file for one shell.

## Security and privacy

- `~/.apprentice` is readable only by you (`0700`). It holds URLs, page titles, screenshots and maybe an API key; `doctor` warns if it or `config.toml` can be read by others.
- Auto-update runs code from your `upstream` without review: that is what "updates itself" means. It only does so from an `https` or `ssh` remote. A folder, `file://`, `git://` or `http://` upstream is updated by hand with `apprentice update`. Turn it off with `[update] auto = false`.
- Logs never contain typed text. Password managers, banking and health apps are never logged.
- The scrubbed session copies in the clone hold commands, diffs, timings, errors (with quoted text removed), hosts, the model and the task. They never hold URLs, element names, typed text or images. `pr` says how many it would publish and which hosts they touch. Set `[storage] sessions = "off"` to keep them out.
- `pr` pushes only to a fork remote, never to `upstream` and never with force.

## How the next run gets faster

Everything apprentice learns is kept in your clone, where updates and `pr` can share it:

| What | Where | Written by | Read by |
| --- | --- | --- | --- |
| Key facts about an app or site | `playbooks/macos/`, `playbooks/web/`, `playbooks/linux/` | you or the agent, after a question or a fix | `session` and `open` print them |
| Flows: a task as steps, tagged with the model | `playbooks/flows/<slug>.md` | `learn "task"` drafts one from the session's approved steps | `do --explain` picks one for this model; `do <flow>` runs it with one approval |
| Your preferences: sites you use, your handles | `prefs.json` in this device's `.apprentice` (in a VM, inside the VM) | the agent, from your own words or the site a task ran on (`remember`) | `route` and `prefs` print them |
| Learned routes | `playbooks/routes-learned.toml` | `do`, the first time a model gets through a flow | `route "task"` sends that model straight to the flow |
| Session copies | `sessions/<date>-<session>.jsonl` | the daemon, when a session ends | you, `grow`, and anyone reviewing a `pr` |

The raw logs (`~/.apprentice/runs/`, with screenshots) stay on the Mac and are pruned after 30 days. `apprentice grow` reads them to say what to fix next.

## Playbooks and flows

```
playbooks/
  macos/   apps and system parts, one file each (<app>.md, save-panel.md)
  linux/   the Linux VM
  web/     one file per site (<host>.md)
  flows/   runnable task recipes, one per task
```

Playbooks are plain Markdown with a little front matter. `session` prints each matching playbook's **Key facts**. A flow step is one backticked command, which `do` runs:
- `#label "name"` finds that element on screen when the step runs;
- `{key}` takes its value from `--key value`;
- `` `sh: <command>` `` runs a shell command under the same approval (refused when the policy is UI only).

A flow's `model:` line names the model that learned it. Another model skips the flow unless it says `model: any`.

`playbooks/README.md` has the format and the rules. The main one: playbooks record what worked and what failed, never text copied from a screen. Since `pr` and updates share them with everyone, they also never hold personal information (names, handles, emails, phone or account numbers, ids from URLs, home paths, tokens); `{placeholders}` stand in, and `commit`, `learn` and `pr` refuse a playbook that looks like it holds any.

## Developing

```sh
swift build                  # .build/debug/apprentice
.build/debug/apprentice serve   # run the daemon in the foreground
apprentice grow              # repeated errors, questions asked, open field reports
```

`CLAUDE.md` describes the architecture and the rules for changing it. `SPEC.md` is the design spec. `BUGS.md` holds the field reports the tool files about itself, and `TODO.md` the deferred work. There is no test target; `apprentice selftest` runs the built-in checks, and CI ([`ci.yml`](.github/workflows/ci.yml)) builds the universal release binary and runs them on every PR and push to `main`.

The source has no package dependencies. It keeps two rules: no app- or site-specific code paths, since app knowledge belongs in `playbooks/`; and no input other than a real cursor and keyboard.

## Releasing

Run `scripts/release.sh 0.2.0`: it bumps the version in `Build.swift`, builds, self-tests and packages the DMG locally, then commits and tags, and prints the push that publishes it (`git push origin main v0.2.0`). [`release.yml`](.github/workflows/release.yml) builds the universal binary, runs the self-test, packages `Apprentice.app` into `apprentice-macos.dmg` ([`scripts/make-dmg.sh`](scripts/make-dmg.sh): the window, the CLI in `Contents/Helpers`, and `agent/`, `skills/` and `playbooks/`), signs and notarizes both when the Apple secrets are configured, and attaches the DMG, `apprentice-macos.zip` (the bare binary) and `SHA256SUMS.txt` to a GitHub Release. Installed apps find it through the `releases/latest` API and offer it. The release fails if the tag and the version string disagree. *Actions ▸ Release ▸ Run workflow* does the same as a draft, for testing. Pushes to `main` that touch `site/` redeploy the landing page ([`pages.yml`](.github/workflows/pages.yml)).

Installs made with `install.sh` update from `main`, not from releases. Run `scripts/make-dmg.sh .build/release/apprentice dist` to build an ad hoc signed DMG locally; [`ci.yml`](.github/workflows/ci.yml) builds and checks one on every PR.

## Contributing

Issues and PRs are welcome: see [`CONTRIBUTING.md`](CONTRIBUTING.md), and report security problems through [`SECURITY.md`](SECURITY.md). apprentice is [MIT licensed](LICENSE).
