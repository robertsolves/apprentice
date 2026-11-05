import AppKit
import Foundation

enum KillSwitch {
    /// Stops the action under way.
    static var tripped = false
    /// Kept after a press until the user answers a question, approves a step themselves or says to carry
    /// on (`resume`): meanwhile no step is proposed or run. Reading still works.
    static var halted = false
    static let message = "the user pressed the kill switch. Stop: do nothing more on screen and ask them what to do (`apprentice ask`). Their answer in the window lifts the stop; if they answer in the chat and say to carry on, run `apprentice resume`"

    static func install() {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.control, .option, .command])
            // The "." key on whatever layout is in use; 47 is its US position.
            if flags == [.control, .option, .command], event.charactersIgnoringModifiers == "." || event.keyCode == 47 {
                tripped = true
                halted = true
                NSSound.beep()
                Daemon.queue.async { Store.log(["kill_switch": true]) }
            }
        }
    }
}

enum Daemon {
    /// Commands run one at a time on this queue, never on main.
    static let queue: DispatchQueue = {
        let q = DispatchQueue(label: "apprentice.commands")
        q.setSpecific(key: onQueue, value: true)
        return q
    }()
    private static let onQueue = DispatchSpecificKey<Bool>()
    /// Questions wait for the person here, one at a time, so an open window never holds up `approve`,
    /// `log` or another agent's commands (`Commands.asides`).
    static let questions = DispatchQueue(label: "apprentice.questions")
    /// `log` and `pending` only read files, so they answer at once whatever else is running.
    static let reads = DispatchQueue(label: "apprentice.reads", attributes: .concurrent)

    static func queue(for req: Request) -> DispatchQueue {
        guard Commands.asides.contains(req.cmd) else { return queue }
        if req.cmd == "log" || req.cmd == "pending" { return reads }
        // In a VM session `show` points on the VM's screen, through the connection the command queue owns.
        if req.cmd == "show", Session.stored?.vm == true { return queue }
        return questions
    }

    /// Runs `req` as a command: on the command queue, or in place when already on it (a flow's `confirm` step).
    /// `byUser`: the user's own approval (the `confirm` window, the menu bar), which a credential step needs.
    static func command(_ req: Request, byUser: Bool = false) throws -> String {
        func run(_ body: () throws -> String) rethrows -> String {
            guard byUser else { return try body() }
            Approvals.byUser = req.args.first
            defer { Approvals.byUser = nil }
            return try body()
        }
        if DispatchQueue.getSpecific(key: onQueue) == true { return try run { try Commands.dispatch(req) } }
        return try queue.sync { try run { try Commands.run(req) } }
    }

    /// Runs `body` on the command queue, or in place when already on it.
    static func serial<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: onQueue) == true { return try body() }
        return try queue.sync(execute: body)
    }

    static func start(background: Bool) throws {
        if Wire.ping() {
            if !background { print("apprentice daemon already running") }
            return
        }
        try requireAccessibility()
        Pause.on = false
        let app = NSApplication.shared
        app.delegate = Reopen.shared
        // A Dock icon shows it is running; without one it is menu-bar only. While the window is open its
        // icon is enough: two Dock icons for one tool read as two tools (`DockIcon`).
        app.setActivationPolicy(Config.current.dockIcon && !DockIcon.windowOpen ? .regular : .accessory)
        if Config.current.dockIcon { app.applicationIconImage = Ask.icon; DockIcon.watch() }
        DockIcon.follow()

        // A pid file left behind means the last daemon died without `stop`: tell the next agent once, with its last
        // error output, since its snapshot may be stale. The user has nothing to do about it, so not in the menu bar.
        if FileManager.default.fileExists(atPath: Store.pidPath) {
            let err = (try? String(contentsOf: Store.stateDir.appendingPathComponent("daemon.err"), encoding: .utf8))?
                .split(separator: "\n").suffix(3).joined(separator: " | ") ?? ""
            Repo.notice("apprentice: the last daemon stopped unexpectedly\(err.isEmpty ? "" : ": \(err)"); this is a fresh one, so read the screen again", agentsOnly: true)
        }
        try? String(ProcessInfo.processInfo.processIdentifier).write(toFile: Store.pidPath, atomically: true, encoding: .utf8)
        KillSwitch.install()
        StatusItem.install()
        Overlay.install()
        Borrow.watchHuman()
        Typing.Sampler.install()
        Voice.install()
        // The window's own process is separate (`apprentice app`), so a stuck terminal or a crashed view
        // never takes the daemon and a pending approval down with it.
        if Store.vmName == nil { Repo.scheduleChecks(); Sync.schedule(); SkillLibrary.scheduleRefresh() }
        Schedules.install()
        Away.install()
        if Config.current.keepAwake { Awake.set(true) }
        // Apprentice's own CLI sessions and expired pipeline output: looked at hourly, done once a day.
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in Tidy.daily() }

        let server = UnixServer(path: Store.socketPath) { req -> (Response, Bool) in
            if req.cmd == "stop" {
                Store.log(["cmd": "stop"])
                return (Response(code: 0, out: "stopped"), true)
            }
            do {
                // An away task's steps go in the journal, so a return can undo a half-typed unit.
                if req.away == true { Away.recording = req.awayTask ?? "" }
                // The app is a user channel, like the menu bar: its click is the user's own approval.
                if req.user == true, req.cmd == "approve" { Approvals.byUser = req.args.first }
                defer { Away.recording = nil; if req.user == true { Approvals.byUser = nil } }
                // An MCP tool call comes straight here, past the check the CLI makes.
                if req.step != nil, req.user != true, let refusal = Help.refusedInStep(req.cmd, req.args) { throw Fail(7, refusal) }
                let aside = Commands.asides.contains(req.cmd) && Daemon.queue(for: req) !== Daemon.queue
                if !aside {
                    Store.model = req.model
                    if let host = req.host, req.user != true {
                        Handback.agentHost = host
                    }
                    Project.dir = req.project.map { URL(fileURLWithPath: $0) }
                    // One agent at a time on this screen (`Device`).
                    try Device.check(req)
                }
                // Marked on disk while it runs, so an update's restart and the window see a long command (`Running`).
                let marked = req.cmd != "ping"
                if marked { Running.enter() }
                defer { if marked { Running.leave() } }
                let out = try aside ? Commands.aside(req) : Commands.run(req)
                // `learned?`: the tool says when; the agent says what.
                if let nudge = Struggle.after(req, code: 0, out: out) { return (Response(code: 0, out: out + "\n" + nudge), false) }
                return (Response(code: 0, out: out), false)
            } catch let fail as Fail {
                // Proposals are not errors; everything else is kept so `bug` can quote it.
                if fail.code != 8 { Store.log(["error": String(fail.message.prefix(300)), "code": Int(fail.code), "failed": req.cmd]) }
                _ = Struggle.after(req, code: fail.code, out: fail.message)
                return (Response(code: fail.code, out: fail.message), false)
            } catch {
                return (Response(code: 5, out: "\(error)"), false)
            }
        }

        do {
            try server.start()
        } catch {
            try? FileManager.default.removeItem(atPath: Store.pidPath)
            throw error
        }
        // Pruning can take a while on a long history, so the socket answers first; on the command
        // queue, so it never rewrites events.jsonl under a command recording one.
        Daemon.queue.async {
            Store.pruneLogs()
            Tidy.daily()
            Events.prune()
        }

        if !background {
            print("apprentice daemon listening on \(Store.socketPath) (pid \(getpid()))")
            fflush(stdout)
        }
        app.run()
    }
}


/// Clicking the Dock icon or `open -a Apprentice` while the daemon runs re-activates this process, which has no
/// window of its own: the window is a separate process (see `AppMain`), so a reopen starts it.
final class Reopen: NSObject, NSApplicationDelegate {
    static let shared = Reopen()
    private var window: Process?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Still starting counts: a second reopen must not open a second window.
        if let w = window, w.isRunning {
            NSRunningApplication(processIdentifier: w.processIdentifier)?.activate()
            return false
        }
        guard let exe = Bundle.main.executablePath else { return false }
        let p = Process()
        // The real file: run through the CLI's link it is no bundle, so `app` would ask `open` for the window, and
        // `open` sends this process another reopen, for ever.
        p.executableURL = URL(fileURLWithPath: exe).resolvingSymlinksInPath()
        p.arguments = ["app"]
        try? p.run()
        window = p
        return false
    }
}

/// Whether a daemon is in the middle of a command right now: `running` in its state folder, holding its pid,
/// for as long as any request (a command or an open question) is under way. Other processes read it: the main
/// daemon's update waits while a VM's daemon runs a long command (`Repo.vmBusy`), and the window shows a
/// project as working even with the on-screen box turned off (`[agent] overlay = false`).
enum Running {
    private static let lock = NSLock()
    private static var count = 0

    static func file(_ stateDir: URL = Store.stateDir) -> URL { stateDir.appendingPathComponent("running") }

    static func enter() {
        lock.lock(); defer { lock.unlock() }
        count += 1
        if count == 1 {
            try? FileManager.default.createDirectory(at: Store.stateDir, withIntermediateDirectories: true)
            try? Data(String(getpid()).utf8).write(to: file(), options: .atomic)
        }
    }

    static func leave() {
        lock.lock(); defer { lock.unlock() }
        count = max(0, count - 1)
        if count == 0 { try? FileManager.default.removeItem(at: file()) }
    }

    /// True when the daemon of `stateDir` is running a request: its marker names a live process.
    static func busy(_ stateDir: URL) -> Bool {
        guard let text = try? String(contentsOf: file(stateDir), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    /// The state folders of every VM's daemon (`~/.apprentice/vms/<name>`).
    static var vmStateDirs: [URL] {
        let root = Store.dir.appendingPathComponent("vms")
        return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
    }

    /// Any daemon at all, this Mac's or a VM's, is running a request.
    static var anyDaemon: Bool { busy(Store.dir) || vmStateDirs.contains(where: busy) }
}
