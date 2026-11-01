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
                DispatchQueue.global().async { VM.interrupt() }
                Daemon.queue.async { Store.log(["kill_switch": true]) }
            }
        }
    }
}

enum Daemon {
    /// Commands run one at a time on this queue, never on main.
    static let queue = DispatchQueue(label: "apprentice.commands")

    static func start(background: Bool) throws {
        if Wire.ping() {
            if !background { print("apprentice daemon already running") }
            return
        }
        try requireAccessibility()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        try? String(ProcessInfo.processInfo.processIdentifier).write(toFile: Store.pidPath, atomically: true, encoding: .utf8)
        Store.pruneLogs()
        Events.prune()
        KillSwitch.install()
        Borrow.watchHuman()
        Repo.scheduleChecks()
        if Config.current.keepAwake { Awake.set(true) }

        let server = UnixServer(path: Store.socketPath) { req -> (Response, Bool) in
            if req.cmd == "stop" {
                Store.log(["cmd": "stop"])
                return (Response(code: 0, out: "stopped"), true)
            }
            do {
                let out = try Commands.run(req)
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
