import Foundation
import Darwin

signal(SIGPIPE, SIG_IGN)

// `apprentice --vm <name> …` is APPRENTICE_VM for one command: the agent session's own browser VM.
var argvRaw = CommandLine.arguments
if argvRaw.count > 2, argvRaw[1] == "--vm" {
    setenv("APPRENTICE_VM", argvRaw[2], 1)
    argvRaw.removeSubrange(1...2)
}

// The self-test works in a folder of its own, never the user's ~/.apprentice. This runs after the `--vm`
// strip so `apprentice --vm x selftest` is caught too.
if argvRaw.count > 1, argvRaw[1] == "selftest" {
    setenv("APPRENTICE_HOME", NSTemporaryDirectory() + "apprentice-selftest-\(getpid())", 1)
    unsetenv("APPRENTICE_VM")
}

let version = Build.version

func usage() {
    print("""
    apprentice \(version) · text-first control of one Mac app or browser window

    usage:
      apprentice doctor [--fix]                 check permissions, signature, PATH, clone and settings; --fix opens the panes and runs a smoke test
      apprentice session [--app Safari] [--on mac|linux] [--new-window] [--allow a.com,b.com] [--task "…"] [--no-options]
      apprentice open <url>
      apprentice focus <app> [--on mac|linux]
      apprentice read [--max 80] [--filter text]
      apprentice click <id> | --on "text" | --at x,y [--double|--right]
      apprentice type <id|focused> "text" [--enter] [--pace fast] [--tier 3]
      apprentice key <combo> [--tier 3]
      apprentice menu "File > New Folder" [--tier 3]
      apprentice scroll up|down|left|right [n] [--in id | --at x,y]
      apprentice hover <id>
      apprentice browse [seconds] [--in id]
      apprentice drag <id> <id> | --by dx,dy [--in id | --at x,y]   drag one onto another, or pan a map
      apprentice upload <id> <path> [--tier 3]
      apprentice choose <path>                  drive the open or save dialog on the window
      apprentice do <flow> [--key value ...]    run a flow from playbooks/flows with one approval
      apprentice download <id> <path>
      apprentice approve <token> [--text "edited text"] | deny <token> | pending
      apprentice wait-for "text" [--timeout 10]
      apprentice ocr [--crop id|x,y,w,h]
      apprentice shot [--crop id|x,y,w,h] [--marks]
      apprentice ask "question" [--choices "A|B|C" [--multi] [--text]]   a little window for the user; prints their reply
      apprentice show "what"                    the user points the cursor at it; prints the element there
      apprentice confirm <token> [--why "…"]    the user approves or denies a pending step in the little window
      apprentice bug "summary" [--repro …] [--cause …] [--fix …]   file a field report in the repo's BUGS.md
      apprentice commit "what and why"          one small commit in the repo; a source change rebuilds and restarts
      apprentice update [--check] [--build]     rebase onto upstream and rebuild (it also does this on its own unless [update] auto = false)
      apprentice selftest                       the built-in tests; kit.sh runs them before installing a build
      apprentice pr [--title t] [--draft] [--fork remote] [--local]   offer the clone's local commits upstream as a pull request
      apprentice settings [local]               where the settings are; local moves an old synced copy back
      apprentice repo                           the clone apprentice runs from
      apprentice policy [domain]                may the LLM use shell commands for macOS tasks? With a domain: notes on its terms
      apprentice budget [domain]                what is left of today's and this hour's caps per site and kind
      apprentice project [init | status]        a project's own .apprentice/ folder: its own site counts and tighter caps, on top of the account-wide ones
      apprentice cool [--clear domain]          sites cooling down after a rate limit; clearing asks the user
      apprentice activity <domain> [--days 7]   actions per day, rate limits, challenges and flags on one site
      apprentice flag <domain> "what you saw"   record when the user saw a warning or restriction
      apprentice awake on|off|status            keep the Mac from idle sleep and locking while tasks run
      apprentice away on|off|status             the user is away: questions come back as exit 9 for the chat
      apprentice resume                         after the kill switch, carry on once the user says so
      apprentice phone [on|off|test]            one-tap phone setup: questions that go to the chat buzz the phone
      apprentice grow [--days 14]               improvement digest: repeated errors, questions asked, open bug reports
      apprentice log [--tail n] | --session [<id>]   recent steps, or one whole session
      apprentice sessions [--limit 10]          recent sessions: app, sites, steps, errors, model, task
      apprentice route "task"
      apprentice playbooks ["words"] [--check]        learned app, site and flow playbooks; --check looks for anything personal
      apprentice learn "task" [--name slug] [--model m] [--force]  draft a flow from this session's steps
      apprentice do --explain "task"            which flow a task would pick for this model, and why
      apprentice run "task" --model <name> [--base-url url] [--screen-anyway] [--save name]
      apprentice replay <name> [--from n] [--approve]
      apprentice mcp
      apprentice vm setup | install | up | down | on | off | look | call "what" | shell | status | list   a small Linux VM with its own screen, cursor and keyboard: its browser and Linux apps (--on linux); shell prints the ssh command for its terminal
      apprentice serve [--background] | stop
      apprentice uninstall [--all] [--yes]      list, then remove, everything apprentice installed (--all: the clone too)

    output is compact text for an agent. add --json for the raw reply from the commands that go through the daemon, and from `route` and `playbooks`.
    open, click, type, key, menu, drag, upload, download, choose and do only propose: they exit 8 with a token,
    and act once you run `apprentice approve <token>`. ctrl+opt+cmd+. is the kill switch: it stops whatever runs, and nothing more runs until the user answers.
    exit codes: 0 ok · 2 stale, re-read · 3 the user denied · 4 blocked, rate limited, over budget, cooling or a challenge ·
                5 not found or timeout · 6 interrupted · 7 permission missing · 8 approval needed, nothing done yet ·
                9 ask the user in the chat (they are away or did not answer the window)
    """)
}

let argv = Array(argvRaw.dropFirst())
// No command is a usage error, so an empty interpolation never reads as success (E4).
guard let command = argv.first else {
    usage()
    exit(5)
}
let rest = Array(argv.dropFirst())

/// Commands answered in this process log their own row, so `log --session` and `grow` see `learn`, `bug`,
/// `route` and the rest beside the daemon's commands.
let loggedHere: Set<String> = ["route", "playbooks", "notes", "learn", "bug", "commit", "update", "settings", "repo", "policy", "budget",
                               "activity", "flag", "grow", "sessions", "project", "doctor", "pr", "vm", "replay", "phone"]
if loggedHere.contains(command) { Timing.begin() }

func done(_ code: Int32) -> Never {
    if loggedHere.contains(command) { Store.log(["cmd": command, "client": true, "code": Int(code)]) }
    exit(code)
}

func fail(_ error: Error) -> Never {
    if let f = error as? Fail {
        FileHandle.standardError.write(Data((f.message + "\n").utf8))
        done(f.code)
    }
    FileHandle.standardError.write(Data(("\(error)\n").utf8))
    done(5)
}

func attempt(_ body: () throws -> Void) -> Never {
    do { try body() } catch { fail(error) }
    done(0)
}

switch command {
case "help", "--help", "-h":
    usage()
    exit(0)
case "version", "--version", "-v":
    print(version)
    exit(0)
case "serve":
    attempt { try Daemon.start(background: rest.contains("--background")) }
case "stop":
    // Says what happened, and fails when the daemon is still there (E3).
    let (stopped, how) = Wire.stopDaemon()
    print(how)
    exit(stopped ? 0 : 5)
case "route", "playbooks", "notes":
    // Flags are not part of the query; --json works here as everywhere (E1).
    let a = Args.parse(rest)
    if command != "route", a.has("check") { attempt { print(try Playbooks.checkAll()) } }
    let out = command == "route" ? Routes.answer(a.pos.joined(separator: " ")) : Playbooks.search(a.pos.joined(separator: " "))
    if a.has("json") {
        print(String(data: Wire.json(Response(code: 0, out: out)), encoding: .utf8) ?? "{}")
    } else {
        print(out)
    }
    done(0)
case "learn":
    attempt { print(try Playbooks.learn(Args.parse(rest))) }
case "bug":
    attempt { print(try Playbooks.fileBug(Args.parse(rest))) }
case "commit":
    attempt { print(try Repo.commitCommand(Args.parse(rest))) }
case "update":
    attempt { print(try Repo.update(Args.parse(rest))) }
case "settings":
    attempt { print(try Settings.run(Args.parse(rest))) }
case "repo":
    print(Repo.root.path)
    done(0)
case "policy":
    let a = Args.parse(rest)
    print(a.pos.first.map { Policies.describe($0.contains("://") ? (hostOf($0) ?? $0) : $0) } ?? Config.policyLine)
    done(0)
case "budget":
    print(Budgets.report(Args.parse(rest).pos.first))
    done(0)
case "activity":
    attempt { print(try Events.activity(Args.parse(rest))) }
case "flag":
    attempt { print(try Events.flag(Args.parse(rest))) }
case "grow":
    print(Grow.digest(days: Args.parse(rest).int("days", 14)))
    done(0)
case "sessions":
    print(Sessions.list(Args.parse(rest)))
    done(0)
case "project":
    attempt { print(try Project.command(Args.parse(rest))) }
case "doctor":
    attempt { print(try Doctor.run(Args.parse(rest))) }
case "uninstall":
    attempt { print(try Doctor.uninstall(Args.parse(rest))) }
case "pr":
    attempt { print(try PR.run(Args.parse(rest))) }
case "run":
    attempt { try AgentLoop.run(Args.parse(rest)) }
case "replay":
    let a = Args.parse(rest)
    attempt { try Replay.run(a.pos.first ?? "", from: max(a.int("from", 1), 1), approve: a.has("approve")) }
case "mcp":
    MCP.run()
    exit(0)
case "vm":
    attempt { print(try VM.command(Args.parse(rest))) }
case "phone":
    attempt { print(try Notify.phone(Args.parse(rest), tty: isatty(STDOUT_FILENO) == 1)) }
case "notify-post":
    exit(Notify.post(title: rest.first ?? "apprentice", text: rest.dropFirst().first ?? ""))
case "selftest":
    SelfTest.run()
default:
    do {
        let response = try Wire.send(Request(cmd: command, args: rest))
        if rest.contains("--json") {
            print(String(data: Wire.json(response), encoding: .utf8) ?? "{}")
        } else if !response.out.isEmpty {
            print(response.out)
        }
        exit(response.code)
    } catch {
        fail(error)
    }
}
