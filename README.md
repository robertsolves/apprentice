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
2 textbox "Name" value="Robert M."
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
- **It learns.** Notes about apps and sites live in this repo under `notes/`, so a `git pull` shares them between machines. `learn` turns a task that worked into a flow. `do <flow>` reruns it with one approval for the whole plan, and hands back to the agent if a step fails. Whenever asking you solved a problem, the note gets updated and a code fix is filed.

## Install

You need macOS 14 or later and Swift 5.9 (Xcode or the command-line tools). One command installs it, and running it again updates:

```sh
gh api repos/robertsolves/apprentice/contents/install.sh -H "Accept: application/vnd.github.raw" | bash
```

`install.sh` clones the repo to `~/.apprentice/src` (set `APPRENTICE_DIR` to put it elsewhere), or pulls if it is already there, then runs `kit.sh`. The repo is private, so it clones with your `gh` login, or with your SSH key when `gh` is not signed in. From a clone you already have, run `./kit.sh` directly.

`kit.sh` builds a release binary into `~/.local/bin/apprentice` and signs it. Set `APPRENTICE_SIGN_IDENTITY`, or keep a keychain identity named `apprentice`, so your permissions survive rebuilds. It also:
- connects every AI assistant it finds on the Mac (`agent/connect.py`), and leaves out the ones that aren't installed:
  - Claude Code gets the skill (`agent/SKILL.md`);
  - Codex and the ChatGPT app, opencode, Kilo and Gemini CLI get `agent/AGENTS.md` in their global rules file, between `<!-- apprentice -->` markers, replaced on every run;
  - the Claude desktop app and Cursor, which have no shell, get the MCP server (`apprentice mcp`);
- links `~/.apprentice/notes` to the repo's `notes/`;
- writes example `config.toml` and `routes.toml` files to `~/.apprentice/`.

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
| `ask "question" [--choices "A\|B"] [--multi] [--text]` · `show "what"` | Ask Robert in the little window |
| `notes "words"` · `learn "task"` · `do <flow> --key value` | Learned notes and flows |
| `route "task"` | Check for a faster route (an API, `gh`, a connector) before using the screen |
| `shot` · `ocr` · `log` | A screenshot, OCR of the window, recent steps |
| `policy` · `away on\|off` · `awake on\|off` | Settings for shell use, remote questions and keep-awake |
| `grow` · `bug "summary" --fix "…"` | What to improve next, and field reports |
| `run "task" --model <name>` · `mcp` | A built-in loop for any OpenAI-compatible model, and an MCP server |

Add `--json` to any command for the raw reply.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | ok |
| 2 | stale: the screen changed, read it again |
| 3 | Robert denied the step |
| 4 | blocked by the allowlist or a rate limit |
| 5 | not found, timed out, or a usage error |
| 6 | interrupted by Robert or the kill switch |
| 7 | a permission is missing |
| 8 | approval needed: proposed, nothing done yet |
| 9 | ask Robert in the chat: he is away or did not answer the window |

## Configuration

`~/.apprentice/config.toml` (see `agent/config.example.toml`):

- **`[pace.*]`:** mouse, typing and navigation timing, with optional profiles per site or app.
- **`[session] allow`:** the sites a session may act on.
- **`[agent]`:**
  - `ui_only` turns off shell commands for macOS tasks;
  - `keep_awake` keeps the Mac awake while a task runs;
  - `ask_in` (`both`, `window` or `terminal`) and `ask_window_s` decide where questions go;
  - `ask_sound` is the ping, or `"none"`;
  - `ask_on_start` shows the options window.
- **`[run]`:** the model endpoint for `apprentice run`.

`APPRENTICE_UI_ONLY`, `APPRENTICE_MODEL`, `APPRENTICE_BASE_URL` and `APPRENTICE_API_KEY` override the file for one shell.

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
