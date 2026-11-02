import AppKit
import Foundation

enum KillSwitch {
    static var tripped = false

    static func install() {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.control, .option, .command])
            // The "." key on whatever layout is in use; 47 is its US position.
            if flags == [.control, .option, .command], event.charactersIgnoringModifiers == "." || event.keyCode == 47 {
                tripped = true
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
    static func command(_ req: Request) throws -> String {
        if DispatchQueue.getSpecific(key: onQueue) == true { return try Commands.dispatch(req) }
        return try queue.sync { try Commands.run(req) }
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
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // A pid file left behind means the last daemon died without `stop`: say so once, with its last error output.
        if FileManager.default.fileExists(atPath: Store.pidPath) {
            let err = (try? String(contentsOf: Store.stateDir.appendingPathComponent("daemon.err"), encoding: .utf8))?
                .split(separator: "\n").suffix(3).joined(separator: " | ") ?? ""
            Repo.notice("apprentice: the last daemon stopped unexpectedly\(err.isEmpty ? "" : ": \(err)"); this is a fresh one, so read the screen again")
        }
        try? String(ProcessInfo.processInfo.processIdentifier).write(toFile: Store.pidPath, atomically: true, encoding: .utf8)
        Store.pruneLogs()
        Events.prune()
        KillSwitch.install()
        StatusItem.install()
        Borrow.watchHuman()
        if Store.vmName == nil { Repo.scheduleChecks() }
        if Config.current.keepAwake { Awake.set(true) }

        let server = UnixServer(path: Store.socketPath) { req -> (Response, Bool) in
            if req.cmd == "stop" {
                Store.log(["cmd": "stop"])
                return (Response(code: 0, out: "stopped"), true)
            }
            do {
                let aside = Commands.asides.contains(req.cmd) && Daemon.queue(for: req) !== Daemon.queue
                if !aside { Store.model = req.model }
                let out = try aside ? Commands.aside(req) : Commands.run(req)
                return (Response(code: 0, out: out), false)
            } catch let fail as Fail {
                // Proposals are not errors; everything else is kept so `bug` can quote it.
                if fail.code != 8 { Store.log(["error": String(fail.message.prefix(300)), "code": Int(fail.code), "failed": req.cmd]) }
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

        if !background {
            print("apprentice daemon listening on \(Store.socketPath) (pid \(getpid()))")
            fflush(stdout)
        }
        app.run()
    }
}
