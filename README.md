<p align="center"><img src="assets/icon.svg" width="96" height="96" alt="apprentice"></p>

# apprentice

apprentice lets a coding agent (Claude Code, opencode, Kilo) or a hosted model work one macOS app or website for you, the way a careful person would. It reads the window as a short numbered list, moves the real cursor and presses real keys. It proposes every change and waits for approval. When it is unsure it asks you, and it writes down what it learns so the next run is quicker.

It is built for one person and their own accounts: it keeps to a human pace, with no bulk sending, scraping or multiple accounts.

```
$ apprentice session --app Safari
session 3f9a1c · Safari · window 4120 · https://github.com/settings/profile
policy: websites only through the UI. Quick macOS tasks (files, folders, opening apps) may use shell commands.

$ apprentice read --max 6
<screen>
snap 1 · Safari · github.com/settings/profile · 6 of 41 shown
1 link "Your profile"
2 textbox "Name" value="Sam Lee"
3 textarea "Bio" value=""
4 button "Update profile" [gated]
…
</screen>

$ apprentice type 3 "Software engineer on the Gold Coast"
approve? type into 3 textarea "Bio"
  Safari · https://github.com/settings/profile
  replaces it with: Software engineer on the Gold Coast
⚠ settings, account or billing page
nothing was done. approve: apprentice approve 7c2e · deny: apprentice deny 7c2e
```

## How it works

- **It reads text, not pixels.** The macOS accessibility tree becomes a numbered list of what is on screen. A step costs tens of tokens, not a screenshot. `shot` and `ocr` exist for the rare page that hides from accessibility.
- **It uses real input only.** Every click, scroll and keystroke goes through the system's own input stream with the window in front, and the cursor moves along a curved path at a human pace. Nothing is injected into pages, and nothing is pressed through accessibility. Addresses and file-dialog paths are pasted, because no website can see those boxes. Text inside pages is typed key by key.
- **It stops for you.** It waits until you have been idle for a moment. If you press a key or click while it is acting, it stops with exit 6 and leaves the cursor where you are. ctrl+opt+cmd+. is a kill switch.
- **It proposes, then acts.** Every command that changes something (`open`, `click`, `type`, `key`, `menu`, `drag`, `upload`, `download`, `choose`, `do`) returns `approve? …` and a token, with exit 8. Nothing happens until `apprentice approve <token>`. Steps that look risky carry a `⚠` line: send, post, delete, buy, a password field, a settings page.
- **It asks you.** For any decision that is yours, it opens a little window at the top of the screen and pings:
  - `ask` takes free text or choices;
  - `show` has you point the cursor at something;
  - `confirm` puts a risky step in front of you to approve or deny.

  When you are away from the Mac (`apprentice away on`, or nobody answers within a minute), the question comes back with exit 9 and the agent asks you in the chat instead.
- **It fixes itself.** apprentice runs from your own local clone. When it gets something wrong, the agent fixes the note or the code and commits each small change with `apprentice commit`, which rebuilds, self-tests and restarts apprentice with the fix. Your commits stay in your clone.
- **It updates itself.** Every few hours it checks its upstream. When there's something new, it rebases your commits onto it, rebuilds, runs its self-test and restarts between commands, and the next `session` tells you. If the build or test fails, it stays on the old version. Set `[update] auto = false` to only be told, then run `apprentice update`.
- **It can keep the browser off your desktop.** `apprentice vm setup` makes a separate macOS in a VM (Tart, about 35 GB) that runs only the browser, with its own cursor and keyboard, so you can keep working. `apprentice vm on` sends browser sessions there. Questions and approvals still open on your Mac, and `apprentice vm call` brings you into the VM when only you can do a step.
- **It learns.** Notes about apps and sites live in this repo under `notes/`, so updates share them. `learn` turns a task that worked into a flow. `do <flow>` reruns it with one approval for the whole plan, and hands back to the agent if a step fails. Whenever asking you solved a problem, the note gets updated and a code fix is filed.

## Install

You need macOS 14 or later and Swift 5.9 (Xcode or the command-line tools). One command installs it, and running it again updates:

```sh
git clone https://github.com/robertsolves/apprentice.git ~/.apprentice/src && ~/.apprentice/src/install.sh
```

`install.sh` clones into `~/.apprentice/src` (or `APPRENTICE_DIR`, or the clone of your last install, which it finds through `~/.apprentice/notes`). The clone is your copy: `upstream` is fetch-only, so your commits stay in it. Set `APPRENTICE_UPSTREAM` to install from another git URL (a server, a folder, another Mac's clone). Then it runs `kit.sh`. From a clone you already have, run `./kit.sh` directly.

`kit.sh` builds a release binary, runs its self-test (a failure keeps the installed one), and installs it to `~/.local/bin/apprentice`. It signs it with a local identity named `apprentice`, which it creates in your login keychain the first time, so your permissions survive rebuilds (set `APPRENTICE_SIGN_IDENTITY` to use another). A running browser VM gets the new build too. It also:
- connects every AI assistant it finds on the Mac (`agent/connect.py`), and leaves out the ones that aren't installed:
  - the skill (`agent/SKILL.md`) goes to `~/.claude/skills` and the shared `~/.agents/skills`, which nearly every agent reads, and to `~/.factory/skills` (Factory Droid) and `~/.continue/skills` (Continue), which read only their own;
  - the instructions (`agent/AGENTS.md`) go between `<!-- apprentice -->` markers, replaced on every run, in the global rules file of each installed agent: Codex and the ChatGPT app, opencode, Kilo, Gemini CLI, Qwen Code, GitHub Copilot CLI, Amp, Factory Droid, Crush, Mistral Vibe, Continue, Augment's Auggie, and Freebuff and Codebuff (`~/.AGENTS.md`). The shared `~/.agents/AGENTS.md`, which Cline and goose read, always gets them. Kimi, Warp and Cursor's CLI have no global rules file and get the skill only;
  - the Claude desktop app and Cursor, which have no shell, get the MCP server (`apprentice mcp`);
- puts `~/.local/bin` on your PATH in `~/.zprofile` (or `~/.bash_profile`), so agents can run `apprentice`;
- links `~/.apprentice/notes` to the repo's `notes/`;
- writes example `config.toml` and `routes.toml` files, if you have none yet.

The installer also asks where to keep your settings: on this Mac only, or in a private GitHub repo (`<you>/apprentice-settings`) that every Mac you install on shares.

Then grant **Accessibility** and **Screen Recording** to `~/.local/bin/apprentice` in System Settings → Privacy & Security, and run `apprentice stop` so the next command starts a fresh daemon.

The first `session` after the daemon starts opens an options window:
- **UI only:** no shell commands for macOS tasks;
- **Keep the Mac awake** while a task runs;
- **Allowed sites**, as a list;
- **Remember these** as your defaults.

## Commands

| Command | Does |
| --- | --- |
| `session --app <name> [--new-window] [--allow a.com,b.com]` | Attach to one app window; prints the policy and notes for that app or site |
| `read [--max 80] [--filter text]` | The numbered list of what is on screen |
| `click <id>` · `click --on "text"` · `click --at x,y` | Click an element, visible text (OCR if it is not listed) or a point |
| `type <id\|focused> "text" [--enter]` | Click into a field, then type, key by key |
| `key <combo>` · `menu "File > Save…"` | A shortcut, or a menu item clicked like a person |
| `scroll`, `hover`, `drag`, `wait-for "text"` | The rest of what a hand does |
| `open <url>` | Navigate the browser window, at a polite pace |
| `upload <id> <file>` · `download <id> <path>` · `choose <path>` | Files, through the system's own dialogs |
| `approve <token>` · `deny <token>` · `confirm <token>` · `pending` | Approvals |
| `ask "question" [--choices "A\|B"] [--multi] [--text]` · `show "what"` | Ask the user in the little window |
| `notes "words"` · `learn "task"` · `do <flow> --key value` | Learned notes and flows |
| `route "task"` | Check for a faster route (an API, `gh`, a connector) before using the screen |
| `shot` · `ocr` · `log` | A screenshot, OCR of the window, recent steps |
| `policy` · `away on\|off` · `awake on\|off` | Settings for shell use, remote questions and keep-awake |
| `grow` · `bug "summary" --fix "…"` | What to improve next, and field reports |
| `settings [github \| local \| sync]` | Keep settings on this Mac, or in a private GitHub repo shared by your Macs |
| `commit "what and why"` · `update [--check]` · `selftest` · `repo` | A small commit (rebuilds on a source change), upstream fixes in by hand (it also updates itself), the built-in tests, and where the clone is |
| `vm setup` · `vm on`/`off` · `vm up`/`down` · `vm look` · `vm call "what"` · `vm logs` | The browser VM: make it, send browser sessions to it, start or stop it, see it, bring the user into it, copy its logs here |
| `run "task" --model <name>` · `mcp` | A built-in loop for any OpenAI-compatible model, and an MCP server |

Add `--json` to any command for the raw reply.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | ok |
| 2 | stale: the screen changed, read it again |
| 3 | The user denied the step |
| 4 | blocked by the allowlist or a rate limit |
| 5 | not found, timed out, or a usage error |
| 6 | interrupted by the user or the kill switch |
| 7 | a permission is missing |
| 8 | approval needed: proposed, nothing done yet |
| 9 | ask the user in the chat: they are away or did not answer the window |

## Configuration

Settings are `config.toml` (see `agent/config.example.toml`), `routes.toml` and `budgets.json`, in `~/.apprentice/` on this Mac only. An older install that synced them with GitHub keeps reading them from `~/.apprentice/settings/` until `apprentice settings local` moves them back. Sessions, logs and screenshots stay on the Mac. The browser VM gets a copy of your settings each time `kit.sh` or `apprentice vm install` runs.

`config.toml` has:

- **`[pace.*]`:** mouse, typing and navigation timing, with optional profiles per site or app.
- **`[session] allow`:** the sites a session may act on.
- **`[agent]`:**
  - `ui_only` turns off shell commands for macOS tasks;
  - `keep_awake` keeps the Mac awake while a task runs;
  - `ask_in` (`both`, `window` or `terminal`) and `ask_window_s` decide where questions go;
  - `ask_sound` is the ping, or `"none"`;
  - `ask_on_start` shows the options window.
- **`[run]`:** the model endpoint for `apprentice run`.

`APPRENTICE_HOME` moves all state out of `~/.apprentice`. `APPRENTICE_UI_ONLY`, `APPRENTICE_MODEL`, `APPRENTICE_BASE_URL` and `APPRENTICE_API_KEY` override the file for one shell.

## Notes and flows

```
notes/
  macos/   apps and system parts, e.g. finder.md, save-panel.md
  web/     one file per site, e.g. instagram.com.md
  flows/   runnable task recipes, e.g. finder-new-folder.md
```

Notes are plain Markdown with a little front matter. `session` prints each matching note's **Key facts**. A flow step is one backticked command, which `do` runs:
- `#label "name"` finds that element on screen when the step runs;
- `{key}` takes its value from `--key value`.

`notes/README.md` has the format and the rules. The main one: notes record what worked and what failed, never text copied from a screen.

## Developing

```sh
swift build                  # .build/debug/apprentice
.build/debug/apprentice serve   # run the daemon in the foreground
apprentice grow              # repeated errors, questions asked, open field reports
```

`CLAUDE.md` describes the architecture and the rules for changing it. `SPEC.md` is the design spec. `bugs.md` holds the bug audit and the field reports the tool files about itself. There is no test target yet.

The source has no package dependencies. It keeps two rules: no app- or site-specific code paths, since app knowledge belongs in `notes/`; and no input other than a real cursor and keyboard.
