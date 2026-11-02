import Foundation
import Darwin

signal(SIGPIPE, SIG_IGN)

// `apprentice --vm <name> …` is APPRENTICE_VM for one command: the agent session's own browser VM.
var argvRaw = CommandLine.arguments
if argvRaw.count > 2, argvRaw[1] == "--vm" {
    setenv("APPRENTICE_VM", argvRaw[2], 1)
    argvRaw.removeSubrange(1...2)
}

// A project with a VM (`.apprentice/project.toml`) is that VM for anything run inside its folder, so an
// agent opened there needs no setup. Never for the daemon or the window: they are this Mac's.
if ProcessInfo.processInfo.environment["APPRENTICE_VM"] == nil, argvRaw.count > 1,
   !["serve", "stop", "app", "selftest", "uninstall", "notify-post", "notify-test", "project"].contains(argvRaw[1]),
   let vm = Projects.here()?.vm {
    setenv("APPRENTICE_VM", vm, 1)
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
      apprentice tour [name] | list | use <name> | show [name] | rm <name>   set everything up one choice at a time, saved as a named setup; switch or update any one
      apprentice doctor [--fix]                 check permissions, signature, PATH, clone and settings; --fix opens the panes and runs a smoke test
      apprentice session [--app Safari] [--on mac|linux] [--new-window|--new-tab] [--allow a.com,b.com] [--task "…"] [--no-options]
      apprentice open <url>
      apprentice focus <app> [--on mac|linux]
      apprentice read [--max 80] [--filter text]
      apprentice click <id> | --on "text" | --at x,y [--double|--right]
      apprentice type <id|focused> "text" [--enter] [--pace fast] [--tier 3]
      apprentice type <id> --secret username|password|code [--enter]   sign in ([login] auto): saved account, or the user's code
      apprentice login add|remove|status <domain>   save a sign-in to the Keychain through the little window
      apprentice account login [--start | --wait | --cancel] [--no-browser] | status [--offline] | logout   your GitHub account: sign in with a code at github.com/login/device
      apprentice key <combo> [--tier 3]
      apprentice menu "File > New Folder" [--tier 3]
      apprentice scroll up|down|left|right [n] [--in id | --at x,y]
      apprentice hover <id>
      apprentice browse [seconds] [--in id]
      apprentice drag <id> <id> | --by dx,dy [--in id | --at x,y]   drag one onto another, or pan a map
      apprentice upload <id> <path> [--tier 3]
      apprentice choose <path>                  drive the open or save dialog on the window
      apprentice do <flow> [--key value ...]    run a skill's saved steps (its flow) with one approval
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
      apprentice budget [domain]                what is left of this hour's, today's and this week's caps per site and kind
      apprentice pace [site [fastest|fast|steady|careful|default]]   how fast a site or app goes; fastest (pasted text, no waits) suits logged-out scouting. Apps are fastest, web pages steady, social sites careful
      apprentice project new "name" [--from <git url>] [--vm <name>] [--agent claude] | list | open | save [--push] | add <folder> | forget   a folder for one piece of work: notes agents read, its pipelines, its VM; save commits it, --push puts it on GitHub
      apprentice project [init | status]        a project's own .apprentice/ folder: its own site counts and tighter caps, on top of the account-wide ones
      apprentice pipeline list | show | new "name" "step" … | add <name> "step" | run <name> [--from N] | rm   prompts that run one after another, now or on a schedule (schedule add … --pipeline <name>)
      apprentice cool [--clear domain]          sites cooling down after a rate limit; clearing asks the user
      apprentice activity <domain> [--days 7]   actions per day, rate limits, challenges and flags on one site
      apprentice flag <domain> "what you saw"   record when the user saw a warning or restriction
      apprentice awake on|off|status            keep the Mac from idle sleep and locking while tasks run
      apprentice ask --optional "question" --choices "A|B" [--multi] [--assume A]   a question the user may leave; carries on with the assumption
      apprentice pref <key> [--for site] [--choices "A|B"] [--assume A]   the user's preference here: this site's, else elsewhere, then an optional question
      apprentice voice [show | init | ask]      how the user wants comments and posts written, and their answers per site
      apprentice typing [learn | show | forget]   record how you type (only key timings), so typing keeps your rhythm per letter pair
      apprentice resume                         after the kill switch, carry on once the user says so
      apprentice phone [on|off|test]            one-tap phone setup: questions that go to the chat buzz the phone
      apprentice grow [--days 14]               improvement digest: repeated errors, questions asked, open bug reports
      apprentice log [--tail n] | --session [<id>]   recent steps, or one whole session
      apprentice sessions [--limit 10]          recent sessions: app, sites, steps, errors, model, task
      apprentice route "task"
      apprentice skills ["words"] | <name> | list | --paths | forget <path> | share <path> | --check   what agents know: built in, learned by apprentice (unreviewed hints) and yours; --check looks for anything personal (`playbooks` is the old name)
      apprentice prefs ["words"]                what the user uses (their gym's site, their handles): this device's, then its parent's
      apprentice remember <key> "<value>" --from you|task [--on mac|project]   save one on this device: the user's words, or the site or app the task ran on
      apprentice forget <key> [--on mac|project]   drop one from this device; a parent's value then applies
      apprentice learn "task" [--name slug] [--model m] [--force] | --fact "one line" [--for site-or-app]   save this session's steps, or one fact, as a learned skill on this Mac
      apprentice do --explain "task"            which flow a task would pick for this model, and why
      apprentice run "task" --model <name> [--base-url url] [--screen-anyway] [--save name]
      apprentice replay <name> [--from n] [--approve]
      apprentice mcp
      apprentice vm setup | install | up | down | on | off | look | call "what" | shell | ssh | status | list   a small Linux VM with its own screen, cursor and keyboard: its browser and Linux apps (--on linux); shell prints the ssh command for its terminal
      apprentice device [free]                  who is using this Mac's (or --vm's) screen right now; free lets another agent use it. One agent per screen at a time
      apprentice app                            the window: projects, terminal tabs where agents run, pipelines, schedules, skills, VMs and settings
      apprentice schedule add|list|show|pause|resume|rm|now|agent   prompts and tasks that run later or again
      apprentice away on|off|status|wait|add|list|cancel   work that runs only while you are away, and stops when you are back
      apprentice serve [--background] | stop
      apprentice uninstall [--all] [--keep-vms] [--yes]   list, then remove, everything apprentice installed (--all: the clone too; --keep-vms: the VMs stay)

    output is compact text for an agent. add --json for the raw reply from the commands that go through the daemon, and from `route` and `skills`.
    open, click, type, key, menu, drag, upload, download, choose and do only propose: they exit 8 with a token,
    and act once you run `apprentice approve <token>`. ctrl+opt+cmd+. is the kill switch: it stops whatever runs, and nothing more runs until the user answers.
    exit codes: 0 ok · 2 stale, re-read · 3 the user denied · 4 blocked (another agent is using this screen), rate limited, over budget, cooling or a challenge ·
                5 not found or timeout · 6 interrupted · 7 permission missing · 8 approval needed, nothing done yet ·
                9 ask the user in the chat (they are away or did not answer the window) ·
                10 yielded: the user is back (away mode), nothing was done; wait with `apprentice away wait`
    """)
}

let argv = Array(argvRaw.dropFirst())
// No command is a usage error, so an empty interpolation never reads as success (E4).
guard let command = argv.first else {
    // Opened from the Dock or Spotlight: the bundle's own binary, with no arguments, is the window.
    if Bundle.main.bundleIdentifier == AppBundle.identifier { AppMain.run() }
    usage()
    exit(5)
}
let rest = Array(argv.dropFirst())

/// Commands answered in this process log their own row, so `log --session` and `grow` see `learn`, `bug`,
/// `route` and the rest beside the daemon's commands.
let loggedHere: Set<String> = ["route", "playbooks", "skills", "device", "notes", "learn", "bug", "commit", "update", "settings", "repo", "policy", "budget", "pace",
                               "activity", "flag", "grow", "sessions", "project", "doctor", "pr", "vm", "replay", "phone", "tour", "prefs", "remember", "forget", "account",
                               "pipeline"]
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
case "app":
    if rest.contains("--install") { exit(AppBundle.install()) }
    // `app --bundle <path> [--release]`: the DMG's bundle, made by scripts/make-dmg.sh from this binary.
    if let i = rest.firstIndex(of: "--bundle"), i + 1 < rest.count, let source = Bundle.main.executablePath {
        let ok = AppBundle.build(at: URL(fileURLWithPath: rest[i + 1]), from: source, release: rest.contains("--release"))
        print(ok ? "built \(rest[i + 1])" : "could not build \(rest[i + 1])")
        exit(ok ? 0 : 1)
    }
    AppBundle.launchFromCLI()
case "stop":
    // Says what happened, and fails when the daemon is still there (E3).
    let (stopped, how) = Wire.stopDaemon()
    print(how)
    exit(stopped ? 0 : 5)
case "route", "playbooks", "notes", "skills":
    // Flags are not part of the query; --json works here as everywhere (E1).
    let a = Args.parse(rest)
    var out = ""
    if command == "route" { out = Routes.answer(a.pos.joined(separator: " ")) } else {
        do { out = try Skills.command(a) } catch { fail(error) }
    }
    if a.has("json") {
        print(String(data: Wire.json(Response(code: 0, out: out)), encoding: .utf8) ?? "{}")
    } else {
        print(out)
    }
    done(0)
case "prefs":
    print(Prefs.list(Args.parse(rest)))
    done(0)
case "remember":
    attempt { print(try Prefs.remember(Args.parse(rest))) }
case "forget":
    attempt { print(try Prefs.forget(Args.parse(rest))) }
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
case "pace":
    attempt { print(try PaceStyles.run(Args.parse(rest))) }
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
case "pipeline":
    attempt { print(try Pipelines.command(Args.parse(rest))) }
case "device":
    print(Device.command(Args.parse(rest)))
    done(0)
case "doctor":
    attempt { print(try Doctor.run(Args.parse(rest))) }
case "tour":
    attempt { print(try Tour.command(Args.parse(rest))) }
case "account":
    attempt { print(try Account.command(Args.parse(rest))) }
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
case "notify-test":
    // Builds Apprentice.app if needed and posts one notification through it, whatever `[agent] notifications` says.
    if let exe = Notify.appBundleExecutable() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["notify-post", "apprentice needs you", "This is a test notification."]
        try? p.run()
        p.waitUntilExit()
        print(p.terminationStatus == 0 ? "sent through \(exe)" : "the bundle could not post (exit \(p.terminationStatus)): allow apprentice in System Settings → Notifications")
    } else {
        print("could not build ~/.apprentice/Apprentice.app")
    }
    exit(0)
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
