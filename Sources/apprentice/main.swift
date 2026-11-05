import Foundation
import Darwin

// `__pty <program> <args…>`: how a terminal tab starts (`Pty`). Takes the terminal on stdin as this session's own, then
// becomes the program, the same process. Before anything else, so the program inherits nothing of apprentice's.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "__pty" {
    let TIOCSCTTY: UInt = 0x2000_7461
    _ = ioctl(0, TIOCSCTTY, CInt(0))
    // An ignored signal stays ignored through exec, so a window started from a background job, or one that ignores
    // SIGPIPE itself, would hand its tabs a Ctrl+C that does nothing. A program in a terminal starts with the defaults.
    for sig in [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGPIPE, SIGTSTP, SIGTTIN, SIGTTOU, SIGCHLD] { signal(sig, SIG_DFL) }
    var none = sigset_t()
    sigemptyset(&none)
    sigprocmask(SIG_SETMASK, &none, nil)
    let program = Array(CommandLine.arguments.dropFirst(2))
    var argv = program.map { strdup($0) } + [nil]
    execv(program[0], &argv)
    _exit(127)
}

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

/// Every command and its description are in `agent/commands.toml`, which `help` reads too.
func usage() {
    print(Help.usageText())
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
                               "pipeline", "sync", "board", "agents", "tidy"]
if loggedHere.contains(command) { Timing.begin() }

/// Inside a pipeline step: every command says the step is alive, an action that worked is remembered so the step
/// is not retried over it, and the command's output ends with the board's unread count.
let thisStep = PipelineStep.current
thisStep?.alive()
// Nothing an agent runs may grant access or change a setting: whatever the prompt said, these are the user's.
if Request.callerStep != nil, let refusal = Help.refusedInStep(command, rest) {
    print(refusal)
    exit(7)
}

func endOfCommand(_ code: Int32) {
    guard let step = thisStep else { return }
    if code == 0, Playbooks.actions.contains(command) || command == "do" || command == "approve" { step.touch("acted") }
    if command != "board", let line = Board.unreadLine(run: step.run, step: step.step) { print(line) }
}

func done(_ code: Int32) -> Never {
    if loggedHere.contains(command) { Store.log(["cmd": command, "client": true, "code": Int(code)]) }
    endOfCommand(code)
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
    print(Help.command(Args.parse(rest)))
    exit(0)
case "version", "--version", "-v":
    print(version)
    exit(0)
case "here":
    print(Handback.here())
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
case "voice" where rest.first == "suggest":
    print(Voice.suggestNow())
    done(0)
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
case "board":
    attempt { print(try Board.command(Args.parse(rest))) }
case "agents":
    attempt { print(try NamedAgents.command(Args.parse(rest))) }
case "tidy":
    print(Tidy.command(Args.parse(rest)))
    done(0)
case "device":
    print(Device.command(Args.parse(rest)))
    done(0)
case "doctor":
    attempt { print(try Doctor.run(Args.parse(rest))) }
case "tour":
    attempt { print(try Tour.command(Args.parse(rest))) }
case "account":
    attempt { print(try Account.command(Args.parse(rest))) }
case "sync":
    attempt { print(try Sync.command(Args.parse(rest))) }
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
        // A step without the screen is told so here too: the daemon need not even be running.
        if Request.callerNoScreen == true, Device.screen.contains(command) {
            throw Fail(4, "blocked: this pipeline step does not have the screen. Only a step with ui: true may use it; ask that step on the board, or say what you need in what you print.")
        }
        // Inside a pipeline step a question names who asks, and one left unanswered parks the step.
        if command == "ask", let step = thisStep, !rest.contains("--optional") {
            let (code, out) = try step.aroundAsk(rest)
            if !out.isEmpty { print(out) }
            endOfCommand(code)
            exit(code)
        }
        let response = try Wire.send(Request(cmd: command, args: rest))
        if rest.contains("--json") {
            print(String(data: Wire.json(response), encoding: .utf8) ?? "{}")
        } else if !response.out.isEmpty {
            print(response.out)
        }
        endOfCommand(response.code)
        exit(response.code)
    } catch {
        fail(error)
    }
}
