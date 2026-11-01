import AppKit
import Foundation

/// A macOS guest under Tart that runs one browser for apprentice. It has its own cursor, keyboard and
/// window server, so browser work never borrows the user's. Native apps stay on the host. The guest runs
/// the same signed binary as a LaunchAgent in its login session; the host reaches it over ssh with
/// `apprentice wire`, one Request in and one Response out.
enum VM {
    struct State: Codable {
        var on = false
        /// Where the current session lives: "vm" or "local".
        var target = "local"
        var ip: String?
    }

    static var dir: URL { Store.dir.appendingPathComponent("vm") }
    static var key: URL { dir.appendingPathComponent("id_ed25519") }
    static var settings: [String: String] { Toml.load(Config.path)["vm"] ?? [:] }
    static func setting(_ key: String, _ fallback: String) -> String { settings[key].map(Toml.unquote) ?? fallback }
    static var name: String { setting("name", "apprentice-browser") }
    static var user: String { setting("user", "admin") }
    static var browser: String { setting("browser", "Safari") }
    /// Written into the guest's own config, so it never routes on and only drives browsers.
    static var isGuest: Bool { setting("guest", "false") == "true" }

    static var state: State {
        get { (try? JSONDecoder().decode(State.self, from: Data(contentsOf: dir.appendingPathComponent("state.json")))) ?? State() }
        set {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Wire.json(newValue).write(to: dir.appendingPathComponent("state.json"))
        }
    }

    // MARK: routing

    /// The user's own channel and the daemon's switches stay on the host; everything else follows the session.
    static let hostOnly: Set<String> = ["ask", "awake", "away", "ping", "stop", "kill"]

    private static let knownBrowsers: Set<String> = [
        "safari", "google chrome", "chrome", "chromium", "firefox", "arc", "brave browser", "brave", "microsoft edge",
        "edge", "orion", "vivaldi", "opera", "zen", "zen browser", "dia",
    ]

    static func isBrowser(_ app: String) -> Bool {
        let wanted = app.lowercased().replacingOccurrences(of: ".app", with: "")
        if knownBrowsers.contains(wanted) || wanted == browser.lowercased() { return true }
        guard let probe = URL(string: "https://example.com") else { return false }
        return NSWorkspace.shared.urlsForApplications(toOpen: probe).contains {
            $0.deletingPathExtension().lastPathComponent.lowercased() == wanted
                || Bundle(url: $0)?.bundleIdentifier?.lowercased() == wanted
        }
    }

    enum Place {
        /// On the host; a non-nil target means the session moved back to this Mac.
        case local(target: String?)
        /// In the guest; `claims` moves the session there once it succeeds.
        case remote(Request, claims: Bool)
        /// The approval window opens on the host for a step pending in the guest.
        case confirm
    }

    /// Where a request runs. Pure, so `selftest` checks it.
    static func place(_ req: Request, on: Bool, target: String) -> Place {
        guard on, !hostOnly.contains(req.cmd) else { return .local(target: nil) }
        let a = Args.parse(req.args)
        switch req.cmd {
        case "session":
            // A bare session would bind the user's frontmost app; with the VM on it means the VM's browser.
            guard let app = a.value("app") else { return .remote(Request(cmd: "session", args: req.args + ["--app", browser]), claims: true) }
            return isBrowser(app) ? .remote(req, claims: true) : .local(target: "local")
        case "focus":
            return isBrowser(a.pos.first ?? a.value("app") ?? "") ? .remote(req, claims: true) : .local(target: "local")
        case "confirm":
            return target == "vm" ? .confirm : .local(target: nil)
        default:
            return target == "vm" ? .remote(req, claims: false) : .local(target: nil)
        }
    }

    /// The reply from the guest when this request belongs there; nil runs it on the host as before.
    static func send(_ req: Request) throws -> Response? {
        guard !isGuest else { return nil }
        var s = state
        switch place(req, on: s.on, target: s.target) {
        case .local(let target):
            if let target, target != s.target {
                s.target = target
                state = s
            }
            return nil
        case .confirm:
            try Wire.startDaemon()
            return try confirm(Args.parse(req.args))
        case .remote(let req, let claims):
            // The host daemon holds the kill switch and the little window, so it runs alongside the guest.
            try Wire.startDaemon()
            if req.cmd == "show" {
                // Pointing happens in the VM, so the user is called there first.
                let what = Args.parse(req.args).pos.joined(separator: " ")
                let called = try call("point at \(what)")
                guard called.code == 0, called.out.hasPrefix("opened") else { return called }
            }
            var reply = try remote(req)
            if claims, reply.code == 0 {
                // Re-read: remote() may have saved a fresh ip, and `s` was read before it ran.
                var s = state
                s.target = "vm"
                state = s
                // The guest runs a copy, so updates are this Mac's to report; its daemon applies them.
                if req.cmd == "session", let update = Repo.updateLine(start: false) { reply.out += "\n" + update }
            }
            if reply.code == 4, reply.out.hasPrefix("challenge:") {
                reply.out += "\nthe user does this in the browser VM: `apprentice vm call \"pass the check on the page\"` opens it for them"
            }
            return reply
        }
    }

    /// `vm call "what"`: the user has something to do in the VM (a check only they may pass, a sign-in,
    /// pointing at something). The little window says so on the host and opens the VM when they agree.
    static func call(_ what: String) throws -> Response {
        guard !what.isEmpty else { throw Fail(5, "vm call \"what the user should do there\"") }
        let open = "Open the VM", later = "Later"
        let reply = try Wire.sendLocal(Request(cmd: "ask", args: [
            "apprentice needs you in the browser VM: \(what).", "--choices", "\(open)|\(later)",
        ]))
        guard reply.code == 0 else {
            if reply.code == 9 {
                return Response(code: 9, out: Ask.handOff([
                    "question: the user has to do this in the browser VM: \(what). When they are at the Mac, `apprentice vm look` opens it.",
                ]).message)
            }
            return reply
        }
        guard reply.out.contains("user chose: \(open)") else { return Response(code: 5, out: "the user chose later: \(what) is not done yet") }
        try openViewer()
        Store.log(["vm_call": what])
        return Response(code: 0, out: "opened the VM for the user: \(what). Wait for them, then `apprentice read`")
    }

    static func openViewer() throws {
        let ip = try address()
        let password = setting("password", "admin").addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? ""
        guard let url = URL(string: "vnc://\(user):\(password)@\(ip)") else { throw Fail(5, "bad VM address \(ip)") }
        NSWorkspace.shared.open(url)
    }

    /// The session apprentice is working in: the guest's while it holds it, otherwise this Mac's.
    static var session: Session? {
        guard !isGuest, state.on, state.target == "vm", running else { return Session.stored }
        pullLogs()
        let r = ssh(state.ip ?? "", "cat ~/.apprentice/session.json")
        return r.code == 0 ? try? JSONDecoder().decode(Session.self, from: r.out) : nil
    }

    static var running: Bool {
        guard tartPath != nil, state.ip != nil else { return false }
        let list = tart(["list", "--format", "json"]).text
        return ((try? JSONSerialization.jsonObject(with: Data(list.utf8))) as? [[String: Any]])?
            .contains { ($0["Name"] as? String) == name && ($0["State"] as? String) == "running" } ?? false
    }

    /// Copies the guest's step logs into this Mac's `runs/`, so `grow`, `learn` and `bug` see VM sessions.
    /// Folder names carry the session id, so they never clash with the host's.
    static func pullLogs() {
        guard !isGuest, running, let ip = state.ip else { return }
        let r = ssh(ip, "tar -C ~/.apprentice -cf - runs 2>/dev/null")
        guard r.code == 0, !r.out.isEmpty else { return }
        _ = run("/usr/bin/tar", ["-xf", "-", "-C", Store.dir.path], input: r.out)
    }

    /// Budgets, activity and flags live where the browser runs. With the VM on, these commands run there.
    static func forward(_ argv: [String]) -> (code: Int32, out: String)? {
        guard !isGuest, state.on, running, let ip = state.ip else { return nil }
        let quoted = argv.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let r = ssh(ip, "~/.local/bin/apprentice " + quoted)
        guard r.code != 255 else { return nil }
        return (r.code, (String(decoding: r.out, as: UTF8.self) + r.err).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `confirm` for a step pending in the guest: the window opens on the host, where the user is.
    private static func confirm(_ a: Args) throws -> Response {
        guard let token = a.pos.first else { throw Fail(5, "confirm <token>") }
        let pending = try remote(Request(cmd: "pending")).out
        guard pending.hasPrefix("pending \(token) · ") else { throw Fail(5, "no pending action \(token): run the command again") }
        let summary = String(pending.dropFirst("pending \(token) · ".count))
        let why = a.value("why").map { "\n\nWhy: \($0)" } ?? ""
        var args = ["Approve this step?\n\n\(summary)\(why)", "--choices", "Approve|Deny", "--text"]
        if let t = a.value("timeout") { args += ["--timeout", t] }
        let reply = try Wire.sendLocal(Request(cmd: "ask", args: args))
        if reply.code == 9 {
            return Response(code: 9, out: Ask.handOff([
                "question: approve this step? \(summary)\(why.replacingOccurrences(of: "\n\n", with: " "))",
                "if they say yes in the chat: `apprentice approve \(token)`; if no: `apprentice deny \(token)`. Nothing is done until then.",
            ]).message)
        }
        let lines = reply.out.components(separatedBy: "\n")
        let note = lines.first { $0.hasPrefix("user: ") }.map { "\n" + $0 } ?? ""
        guard reply.code == 0, lines.contains("user chose: Approve") else {
            if reply.code == 0 || reply.out.contains("skipped") { _ = try remote(Request(cmd: "deny", args: [token])) }
            return Response(code: 3, out: (reply.code == 0 ? "The user denied: \(summary)" : "no answer: nothing was done") + note)
        }
        Store.log(["confirm": summary, "by": "user", "vm": true])
        var approved = try remote(Request(cmd: "approve", args: [token]))
        approved.out += note
        return approved
    }

    /// The kill switch on the host also stops a command running in the guest.
    static func interrupt() {
        guard !isGuest, state.on, state.target == "vm" else { return }
        _ = try? remote(Request(cmd: "kill"))
    }

    // MARK: transport

    static func sshArgs(_ ip: String) -> [String] {
        ["-i", key.path, "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR",
         "-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=\(dir.appendingPathComponent("known_hosts").path)",
         "\(user)@\(ip)"]
    }

    static func remote(_ req: Request) throws -> Response {
        var data = Wire.json(req)
        data.append(0x0A)
        var result = ssh(try address(), "~/.local/bin/apprentice wire", input: data)
        if result.code == 255 {
            // The guest takes a new address when it restarts.
            result = ssh(try address(fresh: true), "~/.local/bin/apprentice wire", input: data)
        }
        guard result.code != 255 else {
            throw Fail(5, "cannot reach the VM: start it with `apprentice vm up` (\(result.err))")
        }
        guard let resp = try? JSONDecoder().decode(Response.self, from: result.out) else {
            throw Fail(5, "bad reply from the VM: \(String(decoding: result.out, as: UTF8.self)) \(result.err)")
        }
        return resp
    }

    @discardableResult
    static func ssh(_ ip: String, _ command: String, input: Data? = nil) -> (code: Int32, out: Data, err: String) {
        run("/usr/bin/ssh", sshArgs(ip) + [command], input: input)
    }

    static func address(fresh: Bool = false) throws -> String {
        if !fresh, let ip = state.ip { return ip }
        let r = tart(["ip", name, "--wait", "30"])
        guard r.code == 0, !r.text.isEmpty else { throw Fail(5, "the VM is not running: start it with `apprentice vm up`") }
        var s = state
        s.ip = r.text
        state = s
        return r.text
    }

    static func run(_ tool: String, _ args: [String], input: Data? = nil, env: [String: String] = [:]) -> (code: Int32, out: Data, err: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args
        proc.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let out = Pipe(), err = Pipe(), inp = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = input == nil ? FileHandle.nullDevice : inp
        do { try proc.run() } catch { return (127, Data(), "\(tool): \(error.localizedDescription)") }
        if let input {
            inp.fileHandleForWriting.write(input)
            try? inp.fileHandleForWriting.close()
        }
        // Stderr drains on its own, so a chatty tool cannot block on a full pipe while we read stdout.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        proc.waitUntilExit()
        return (proc.terminationStatus, data, String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static var tartPath: String? {
        ["/opt/homebrew/bin/tart", "/usr/local/bin/tart", NSHomeDirectory() + "/Applications/tart.app/Contents/MacOS/tart"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `[vm] home` keeps the VM on another disk, such as an external SSD.
    static var tartEnv: [String: String] {
        settings["home"].map { ["TART_HOME": (Toml.unquote($0) as NSString).expandingTildeInPath] } ?? [:]
    }

    static func tart(_ args: [String]) -> (code: Int32, text: String, err: String) {
        guard let path = tartPath else { return (127, "", "tart is not installed") }
        let r = run(path, args, env: tartEnv)
        return (r.code, String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), r.err)
    }

    // MARK: the guest side

    /// In the guest, sessions only bind a browser: a bare session takes the configured one.
    static func guestRequest(_ req: Request) throws -> Request {
        guard isGuest, req.cmd == "session" || req.cmd == "focus" else { return req }
        let a = Args.parse(req.args)
        guard let app = req.cmd == "focus" ? (a.pos.first ?? a.value("app")) : a.value("app") else {
            return req.cmd == "session" ? Request(cmd: "session", args: req.args + ["--app", browser]) : req
        }
        guard isBrowser(app) else { throw Fail(4, "blocked: this VM only runs a browser; \(app) stays on the host Mac") }
        return req
    }

    /// `apprentice wire` in the guest: one Request line on stdin, one Response line out. It never starts a
    /// daemon itself, since one started from ssh is outside the login session and could not see the screen.
    static func wire() -> Never {
        let line = FileHandle.standardInput.readDataToEndOfFile().split(separator: 0x0A).first.map { Data($0) } ?? Data()
        var resp: Response
        if let req = try? JSONDecoder().decode(Request.self, from: line) {
            if Wire.ping() {
                resp = (try? Wire.sendLocal(req)) ?? Response(code: 5, out: "the VM's daemon closed the connection")
            } else {
                resp = Response(code: 7, out: "apprentice is not running in the VM: grant it Accessibility there (`apprentice vm look`), then retry")
            }
        } else {
            resp = Response(code: 5, out: "bad request")
        }
        print(String(decoding: Wire.json(resp), as: UTF8.self))
        exit(0)
    }

    // MARK: vm command

    static func command(_ a: Args) throws -> String {
        switch a.pos.first ?? "status" {
        case "setup": return try setup(a)
        case "install": return try install()
        case "up": return try up(window: a.has("window"))
        case "down":
            let r = tart(["stop", name])
            var s = state
            s.ip = nil
            s.target = "local"
            state = s
            return r.code == 0 ? "stopped \(name)" : "could not stop \(name): \(r.err)"
        case "on", "off":
            guard a.pos.first == "off" || tart(["get", name]).code == 0 else { throw Fail(5, "no VM yet: run `apprentice vm setup`") }
            var s = state
            s.on = a.pos.first == "on"
            s.target = "local"
            state = s
            return s.on ? "vm: on · browser sessions run in \(name); other apps stay on this Mac" : "vm: off · everything runs on this Mac"
        case "look":
            try openViewer()
            return "opened Screen Sharing to \(name) (\(try address()))"
        case "call":
            let r = try call(a.pos.dropFirst().joined(separator: " "))
            guard r.code == 0 else { throw Fail(r.code, r.out) }
            return r.out
        case "logs":
            guard running else { throw Fail(5, "the VM is not running: start it with `apprentice vm up`") }
            pullLogs()
            return "copied the VM's step logs into \(Store.dir.appendingPathComponent("runs").path)"
        case "status": return status()
        default: throw Fail(5, "vm setup [--force] | install | up [--window] | down | on | off | look | call \"what\" | logs | status")
        }
    }

    static func status() -> String {
        guard tartPath != nil else { return "vm: tart is not installed · run `apprentice vm setup`" }
        let list = tart(["list", "--format", "json"]).text
        let entry = (try? JSONSerialization.jsonObject(with: Data(list.utf8)) as? [[String: Any]])?
            .first { ($0["Name"] as? String) == name }
        guard let entry else { return "vm: none yet · run `apprentice vm setup`" }
        let s = state
        return "vm \(name) · \(entry["State"] as? String ?? "?") · routing \(s.on ? "on" : "off") · session \(s.target)"
            + (s.ip.map { " · \($0)" } ?? "")
    }

    static func up(window: Bool) throws -> String {
        guard let path = tartPath else { throw Fail(5, "tart is not installed: run `apprentice vm setup`") }
        if tart(["ip", name, "--wait", "1"]).code == 0 { return "\(name) is already running" }
        let log = dir.appendingPathComponent("tart.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: log)
        let proc = Process()
        // nohup: the VM keeps running when the terminal that started it closes.
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        proc.arguments = [path, "run", name] + (window ? [] : ["--no-graphics"])
        proc.environment = ProcessInfo.processInfo.environment.merging(tartEnv) { $1 }
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = handle ?? FileHandle.nullDevice
        proc.standardError = handle ?? FileHandle.nullDevice
        try proc.run()
        let ip = try address(fresh: true)
        let ready = poll(timeout: 90, interval: 2) { ssh(ip, "true").code == 0 ? true : nil } != nil
        return ready ? "\(name) is up at \(ip)\(window ? "" : " (no window; `apprentice vm look` to see it)")"
                     : "\(name) started at \(ip) but ssh is not answering yet; see \(log.path)"
    }

    static func setup(_ a: Args) throws -> String {
        var out: [String] = []
        func say(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)); out.append(line) }
        if tartPath == nil {
            say("installing tart…")
            let r = run("/opt/homebrew/bin/brew", ["install", "cirruslabs/cli/tart"])
            if r.code != 0 || tartPath == nil {
                // The tap's formula breaks on some Homebrew versions; the signed release app works the same.
                say("brew could not install tart; installing the release app into ~/Applications…")
                let apps = NSHomeDirectory() + "/Applications"
                try? FileManager.default.createDirectory(atPath: apps, withIntermediateDirectories: true)
                let fetch = run("/bin/sh", ["-c", "curl -fsSL https://github.com/cirruslabs/tart/releases/latest/download/tart.tar.gz | tar -xzf - -C \"$1\" tart.app", "sh", apps])
                guard fetch.code == 0, tartPath != nil else { throw Fail(5, "could not install tart: \(r.err) \(fetch.err)") }
            }
        }
        if tart(["get", name]).code != 0 {
            // The image is a 24 GB download that unpacks to a sparse 50 GB disk, about 30 GB in use.
            let home = URL(fileURLWithPath: tartEnv["TART_HOME"] ?? (NSHomeDirectory() + "/.tart"))
            let probe = FileManager.default.fileExists(atPath: home.path) ? home : URL(fileURLWithPath: NSHomeDirectory())
            let free = (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? 0
            let gb = Int(free / 1_000_000_000)
            guard gb >= 40 || a.has("force") else {
                throw Fail(5, "only \(gb) GB free on \(probe.path); the VM needs about 35 GB. Free some space, or put it on another disk with `[vm] home = \"/Volumes/<disk>/tart\"` in config.toml, then run `apprentice vm setup` again")
            }
            let image = setting("image", "ghcr.io/cirruslabs/macos-tahoe-vanilla:latest")
            say("downloading \(image) (about 24 GB)…")
            let r = tart(["clone", image, name])
            guard r.code == 0 else { throw Fail(5, "tart clone failed: \(r.err)") }
            // A browser needs little: 4 cores and 4 GB leave the rest of the Mac to the user.
            _ = tart(["set", name, "--cpu", setting("cpu", "4"), "--memory", setting("memory_mb", "4096")])
        }
        say(try up(window: true))
        if !FileManager.default.fileExists(atPath: key.path) {
            _ = run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "apprentice-vm", "-f", key.path])
        }
        let ip = try address()
        if ssh(ip, "true").code != 0 {
            // The first login uses the image's password once, to install the key; ssh reads it from SSH_ASKPASS.
            let askpass = dir.appendingPathComponent("askpass.sh")
            try "#!/bin/sh\necho '\(setting("password", "admin"))'\n".write(to: askpass, atomically: true, encoding: .utf8)
            chmod(askpass.path, 0o700)
            defer { try? FileManager.default.removeItem(at: askpass) }
            let pub = (try? Data(contentsOf: key.appendingPathExtension("pub"))) ?? Data()
            var args = sshArgs(ip)
            args.replaceSubrange(0..<4, with: ["-o", "PubkeyAuthentication=no", "-o", "BatchMode=no"])
            let r = run("/usr/bin/ssh", args + ["mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"],
                        input: pub, env: ["SSH_ASKPASS": askpass.path, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0"])
            guard r.code == 0 else { throw Fail(5, "could not install the ssh key in the VM: \(r.err)") }
        }
        say(try install())
        // Screen Sharing lets `vm look` show the guest once it runs without a window.
        ssh(ip, "sudo -n launchctl enable system/com.apple.screensharing; sudo -n launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist")
        ssh(ip, "open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'")
        out += [
            "",
            "next, in the VM window:",
            "  1. System Settings → Privacy & Security → Accessibility: turn on apprentice (Screen Recording too, for shot and ocr)",
            "  2. open \(browser) and sign into the sites the agent may use",
            "then on this Mac: `apprentice vm on`. Later, `apprentice vm down && apprentice vm up` runs it without a window.",
        ]
        return out.joined(separator: "\n")
    }

    /// Copies this Mac's signed binary, notes and settings into the guest and (re)starts its daemon. The
    /// signature travels with the binary, so the guest's permission grants survive every update.
    static func install() throws -> String {
        let ip = try address()
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("apprentice-vm-\(getpid())")
        try? FileManager.default.removeItem(at: stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        let fm = FileManager.default
        let bin = stage.appendingPathComponent(".local/bin"), conf = stage.appendingPathComponent(".apprentice")
        let agents = stage.appendingPathComponent("Library/LaunchAgents")
        for d in [bin, conf, agents] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try fm.copyItem(atPath: Wire.binaryPath(), toPath: bin.appendingPathComponent("apprentice").path)
        let notes = Repo.root.appendingPathComponent("notes")
        if fm.fileExists(atPath: notes.path) { try fm.copyItem(at: notes, to: conf.appendingPathComponent("notes")) }
        for file in ["routes.toml", "budgets.json"] {
            let src = Settings.dir.appendingPathComponent(file)
            if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: conf.appendingPathComponent(file)) }
        }
        // The host's settings, then the guest's own: later keys win in apprentice's TOML reader.
        let hostConfig = (try? String(contentsOf: Config.path, encoding: .utf8)) ?? ""
        let guestConfig = hostConfig.components(separatedBy: "\n").filter { !$0.hasPrefix("[vm]") }.joined(separator: "\n") + """


            # Written by `apprentice vm install`: the guest only runs a browser. Questions open on the host;
            # only `show` opens its window here, once `vm call` has put the user in front of the VM.
            [agent]
            ui_only = true
            ask_on_start = false
            ask_in = "both"
            keep_awake = true

            [vm]
            guest = true
            browser = "\(browser)"

            """
        try guestConfig.write(to: conf.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>Label</key><string>com.apprentice.serve</string>
              <key>ProgramArguments</key><array><string>/Users/\(user)/.local/bin/apprentice</string><string>serve</string></array>
              <key>LimitLoadToSessionType</key><string>Aqua</string>
              <key>RunAtLoad</key><true/>
              <key>KeepAlive</key><true/>
              <key>ThrottleInterval</key><integer>30</integer>
              <key>StandardErrorPath</key><string>/Users/\(user)/.apprentice/serve.log</string>
            </dict></plist>
            """
        try plist.write(to: agents.appendingPathComponent("com.apprentice.serve.plist"), atomically: true, encoding: .utf8)
        let tar = run("/usr/bin/tar", ["-C", stage.path, "-cf", "-", "."])
        guard tar.code == 0 else { throw Fail(5, "could not pack the install: \(tar.err)") }
        // Notes are replaced whole, so a note deleted on the host goes in the guest too.
        let unpack = ssh(ip, "rm -rf ~/.apprentice/notes && tar -xf - -C ~ && "
            + "launchctl bootout gui/$(id -u)/com.apprentice.serve 2>/dev/null; sleep 1; "
            + "launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.apprentice.serve.plist", input: tar.out)
        guard unpack.code == 0 else { throw Fail(5, "could not install into the VM: \(unpack.err)") }
        // The same time zone as the host, so a session's log folder has the same date on both sides.
        ssh(ip, "sudo -n systemsetup -settimezone '\(TimeZone.current.identifier)' >/dev/null 2>&1")
        return "installed apprentice in \(name) (\(ip))"
    }
}
