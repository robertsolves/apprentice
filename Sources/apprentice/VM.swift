import AppKit
import Foundation

/// A small Debian guest for apprentice: Chromium, a terminal and any other Linux app, on its own screen,
/// cursor and keyboard, so work there never borrows the user's. By default it runs on this Mac under
/// Tart (about 2 GB on disk and 2 GB of memory); `[vm] host` points at a Debian machine anywhere else,
/// such as a cloud server, reached the same way over ssh. agent/vm holds what runs in it (`provision.sh`,
/// `session.sh`, `helper.py`); `Remote` drives its screen from this Mac. Terminal work there is plain
/// ssh (`shell`), as it is the agent's own shell on this Mac: apprentice only takes the screen.
enum VM {
    struct State: Codable {
        var on = false
        var ip: String?
    }

    /// This VM's own files: its state, logs and ssh connection.
    static var dir: URL { Store.stateDir.appendingPathComponent("vm") }
    /// The ssh key and known hosts, shared by every VM.
    static var shared: URL { Store.dir.appendingPathComponent("vm") }
    static var key: URL { shared.appendingPathComponent("id_ed25519") }
    static var knownHosts: String { shared.appendingPathComponent("known_hosts").path }

    /// `[vm]` sets the defaults; a named VM (`APPRENTICE_VM=linkedin`) reads `[vm.linkedin]` over them. Its
    /// place (`name`, `host`, `port`) is its own, never inherited, so a second VM is never the first one.
    static var settings: [String: String] {
        // The copy `uninstall --keep-vms` left in `vm/` answers for a config.toml that was removed.
        let all = tables
        guard let vm = Store.vmName else { return all["vm"] ?? [:] }
        let base = (all["vm"] ?? [:]).filter { !["name", "host", "port"].contains($0.key) }
        return base.merging(all["vm.\(vm)"] ?? [:]) { $1 }
    }
    /// config.toml's tables over the copy `uninstall --keep-vms` left beside the ssh key.
    static var tables: [String: [String: String]] {
        var all = Toml.load(shared.appendingPathComponent("config.toml"))
        for (section, keys) in Toml.load(Config.path) { all[section] = keys }
        return all
    }
    static func setting(_ key: String, _ fallback: String) -> String { settings[key].map(Toml.unquote) ?? fallback }
    static var name: String { setting("name", Store.vmName.map { "apprentice-\($0)" } ?? "apprentice-browser") }
    static var user: String { setting("user", "admin") }
    /// One shell word, whatever the text holds (a quote, `$` or a backtick in a password).
    static func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The image's login, used once to install the ssh key, and the VNC password for `vm look`.
    /// Its own once `vm setup` has changed it (kept in this VM's folder), else `[vm] password`, else the
    /// image's admin.
    static var password: String {
        if let own = try? String(contentsOf: dir.appendingPathComponent("password"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !own.isEmpty { return own }
        return setting("password", "admin")
    }
    /// A VM somewhere else (a hostname or address); nil runs it on this Mac under Tart.
    static var host: String? { settings["host"].map(Toml.unquote).flatMap { $0.isEmpty ? nil : $0 } }
    static var where_: String { host.map { "\(user)@\($0)" } ?? name }
    static var files: URL { Repo.resources.appendingPathComponent("agent/vm") }

    static var state: State {
        get { (try? JSONDecoder().decode(State.self, from: Data(contentsOf: dir.appendingPathComponent("state.json")))) ?? State() }
        set {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Wire.json(newValue).write(to: dir.appendingPathComponent("state.json"))
        }
    }

    private static let knownBrowsers: Set<String> = [
        "safari", "google chrome", "chrome", "chromium", "firefox", "arc", "brave browser", "brave", "microsoft edge",
        "edge", "orion", "vivaldi", "opera", "zen", "zen browser", "dia",
    ]

    /// Any browser the agent asks for means the VM's Chromium once the VM is on.
    static func isBrowser(_ app: String) -> Bool {
        let wanted = app.lowercased().replacingOccurrences(of: ".app", with: "")
        if knownBrowsers.contains(wanted) { return true }
        guard let probe = URL(string: "https://example.com") else { return false }
        return NSWorkspace.shared.urlsForApplications(toOpen: probe).contains {
            $0.deletingPathExtension().lastPathComponent.lowercased() == wanted
                || Bundle(url: $0)?.bundleIdentifier?.lowercased() == wanted
        }
    }

    /// `vm call "what"`: the user has something to do in the VM (a check only they may pass, a sign-in,
    /// pointing at something). The little window says so on this Mac and opens the VM when they agree.
    static func call(_ what: String) throws -> Response {
        guard !what.isEmpty else { throw Fail(5, "vm call \"what the user should do there\"") }
        let open = Remote.openTheVM, later = "Later"
        let reply = try Wire.sendLocal(Request(cmd: "ask", args: [
            "apprentice needs you in the Linux VM: \(what).", "--choices", "\(open)|\(later)",
        ]))
        guard reply.code == 0 else {
            if reply.code == 9 {
                return Response(code: 9, out: Ask.handOff([
                    "question: the user has to do this in the Linux VM: \(what). When they are at the Mac, `apprentice vm look` opens it.",
                ], push: nil).message)
            }
            return reply
        }
        guard reply.out.contains("user chose: \(open)") else { return Response(code: 5, out: "the user chose later: \(what) is not done yet") }
        try openViewer()
        Store.log(["vm_call": what])
        return Response(code: 0, out: "opened the VM for the user: \(what). Wait for them, then `apprentice read`")
    }

    private static var watching = false

    /// Opens the VM's screen once per daemon run (`[agent] watch_vm`) behind everything, ready for the "Watch" button.
    static func watch() {
        guard Config.current.watchVM, !watching else { return }
        watching = true
        VMDock.open(activate: false)
    }

    /// Screen Sharing to the guest's VNC server; the password is the VM's.
    /// VNC only listens inside the guest; Screen Sharing reaches it through an ssh tunnel, so a VM in the
    /// cloud never exposes its screen to the network.
    static func openViewer(activate: Bool = true) throws {
        let ip = try address()
        // A port of its own per VM, so a tunnel left from one VM never shows another. Names that hash to the
        // same port take the next free one; a busy port counts as this VM's tunnel only when this VM opened it.
        let first = Int(name.utf8.reduce(0) { ($0 &* 31 &+ UInt32($1)) % 1000 } % 40)
        let mark = dir.appendingPathComponent("look-port")
        let mine = (try? String(contentsOf: mark, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        func listening(_ port: Int) -> Bool { run("/usr/bin/nc", ["-z", "-w", "2", "127.0.0.1", "\(port)"]).code == 0 }
        var chosen: Int?
        var lastError = ""
        if let mine, listening(mine) { chosen = mine }
        for step in 0..<40 where chosen == nil {
            let port = 5959 + (first + step) % 40
            let tunnel = run("/usr/bin/ssh", ["-f", "-N", "-o", "ExitOnForwardFailure=yes", "-L", "127.0.0.1:\(port):127.0.0.1:5900"]
                + sshArgs(ip, shared: false))
            if tunnel.code == 0 {
                chosen = port
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? "\(port)".write(to: mark, atomically: true, encoding: .utf8)
            } else {
                lastError = tunnel.err
            }
        }
        guard let port = chosen else { throw Fail(5, "could not open the ssh tunnel to the VM: \(lastError)") }
        let pass = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? ""
        guard let url = URL(string: "vnc://:\(pass)@127.0.0.1:\(port)") else { throw Fail(5, "bad VM address \(ip)") }
        // Opened behind the person's work unless they asked to see it: opening an app brings it to the front.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activate
        NSWorkspace.shared.open(url, configuration: config)
    }

    /// Tart's VMs, as `tart list --format json` describes them.
    static func tartList() -> [[String: Any]] {
        (try? JSONSerialization.jsonObject(with: Data(tart(["list", "--format", "json"]).text.utf8))) as? [[String: Any]] ?? []
    }

    static var running: Bool {
        if let host { return ssh(host, "true").code == 0 }
        guard tartPath != nil else { return false }
        return tartList().contains { ($0["Name"] as? String) == name && ($0["State"] as? String) == "running" }
    }

    // MARK: transport

    /// One shared ssh connection, so each command reaches the guest without a new handshake.
    static func sshArgs(_ ip: String, shared: Bool = true) -> [String] {
        ["-i", key.path, "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR",
         "-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=\(knownHosts)",
         "-o", "ServerAliveInterval=15", "-p", setting("port", "22")]
            + (shared ? ["-o", "ControlMaster=auto", "-o", "ControlPath=\(dir.appendingPathComponent("ssh-%C").path)", "-o", "ControlPersist=600"]
                      : ["-o", "ControlPath=none"])
            + ["\(user)@\(ip)"]
    }

    @discardableResult
    static func ssh(_ ip: String, _ command: String, input: Data? = nil) -> (code: Int32, out: Data, err: String) {
        // The shared connection's socket lives in this VM's folder, which a new VM does not have yet.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return run("/usr/bin/ssh", sshArgs(ip) + [command], input: input)
    }

    static func address(fresh: Bool = false) throws -> String {
        if let host { return writeSSHConfig(host) }
        // A cached address is a DHCP lease that may have changed since: it is used only while the guest answers there.
        if !fresh, let ip = state.ip, answers(ip) { return writeSSHConfig(ip) }
        let r = tart(["ip", name, "--wait", "30"])
        guard r.code == 0, !r.text.isEmpty else {
            if let ip = state.ip, running { throw Fail(5, "the VM is running but does not answer at \(ip): wait a moment, or `apprentice vm up`") }
            throw Fail(5, "the VM is not running: start it with `apprentice vm up`")
        }
        var s = state
        s.ip = r.text
        state = s
        return writeSSHConfig(r.text)
    }

    /// The ssh config agents run terminal commands in the VM with: plain ssh, no wrapper, over the
    /// daemon's shared connection, so a command costs no new handshake.
    static var sshConfig: URL { dir.appendingPathComponent("ssh_config") }
    static var shell: String { "ssh -F \(sshConfig.path) \(name)" }

    @discardableResult
    static func writeSSHConfig(_ ip: String) -> String {
        let text = """
        Host \(name)
          HostName \(ip)
          User \(user)
          Port \(setting("port", "22"))
          IdentityFile \(key.path)
          IdentitiesOnly yes
          BatchMode yes
          ConnectTimeout 5
          LogLevel ERROR
          StrictHostKeyChecking accept-new
          UserKnownHostsFile \(knownHosts)
          ServerAliveInterval 15
          ControlMaster auto
          ControlPath \(dir.appendingPathComponent("ssh-%C").path)
          ControlPersist 600

        """
        if (try? String(contentsOf: sshConfig, encoding: .utf8)) != text {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? text.write(to: sshConfig, atomically: true, encoding: .utf8)
        }
        return ip
    }

    @discardableResult
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
        // Stdin goes in from its own queue, with stderr drained alongside, so a tool that reads and writes
        // more than a pipe holds cannot block against us while we wait on its output.
        var errData = Data()
        let group = DispatchGroup()
        if let input {
            group.enter()
            DispatchQueue.global().async {
                try? inp.fileHandleForWriting.write(contentsOf: input)
                try? inp.fileHandleForWriting.close()
                group.leave()
            }
        }
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

    /// `[vm] home` keeps the VM on another disk.
    static var tartEnv: [String: String] {
        settings["home"].map { ["TART_HOME": (Toml.unquote($0) as NSString).expandingTildeInPath] } ?? [:]
    }

    static func tart(_ args: [String]) -> (code: Int32, text: String, err: String) {
        guard let path = tartPath else { return (127, "", "tart is not installed") }
        let r = run(path, args, env: tartEnv)
        return (r.code, String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), r.err)
    }

    // MARK: vm command

    static func command(_ a: Args) throws -> String {
        switch a.pos.first ?? "status" {
        case "setup": return try setup()
        case "install": return try install()
        case "up": return try up()
        case "down":
            guard host == nil else { throw Fail(5, "\(where_) is not stopped from here; stop it where it is hosted") }
            let r = tart(["stop", name])
            var s = state
            s.ip = nil
            state = s
            return r.code == 0 ? "stopped \(name)" : "could not stop \(name): \(r.err)"
        case "on", "off":
            guard a.pos.first == "off" || host != nil || tart(["get", name]).code == 0 else { throw Fail(5, "no VM yet: run `apprentice vm setup`") }
            var s = state
            s.on = a.pos.first == "on"
            state = s
            return s.on ? "vm: on · browser sessions run in \(name), with its own cursor and keyboard; other apps stay on this Mac unless `--on linux`"
                        : "vm: off · everything runs on this Mac"
        case "watch":
            VMDock.open()
            return "opened the apprentice VM window (a picture of \(name)'s screen with the pointer; `vm look` is the one you can click in)"
        case "look":
            try openViewer()
            return "opened Screen Sharing to \(name) (\(try address()))"
        case "call":
            let r = try call(a.pos.dropFirst().joined(separator: " "))
            guard r.code == 0 else { throw Fail(r.code, r.out) }
            return r.out
        case "status": return status()
        case "list": return list()
        case "shell":
            _ = try address()
            return "\(shell) '<command>'   terminal commands in \(name); GUI apps started there show on its screen"
        case "ssh":
            // A person's own shell in the VM, for the window's "Open a shell in it" tab.
            _ = try address()
            let argv = ["ssh", "-F", sshConfig.path, name]
            var cargs = argv.map { strdup($0) } + [nil]
            execv("/usr/bin/ssh", &cargs)
            throw Fail(1, "vm ssh: could not start ssh")
        default: throw Fail(5, "vm setup | install | up | down | on | off | look | call \"what\" | shell | ssh | status | list")
        }
    }

    /// One VM this Mac knows: `name` is empty for the default one (`apprentice-browser`).
    struct Machine: Identifiable, Equatable {
        var name: String
        var tart: String?
        var state: String
        var host: String?
        var id: String { name }
        var label: String { name.isEmpty ? "default" : name }
    }

    /// The Tart VMs named apprentice-…, and `[vm.<name>]` hosts, for the window's VMs screen.
    static func inventory() -> [Machine] {
        let all = tables
        var out: [String: Machine] = [:]
        for vm in tartList() where (vm["Source"] as? String) == "local" {
            guard let n = vm["Name"] as? String, n.hasPrefix("apprentice-") else { continue }
            let name = n == "apprentice-browser" ? "" : String(n.dropFirst("apprentice-".count))
            out[name] = Machine(name: name, tart: n, state: vm["State"] as? String ?? "?", host: nil)
        }
        for key in all.keys where key.hasPrefix("vm.") {
            let name = String(key.dropFirst(3))
            if let host = all[key]?["host"].map(Toml.unquote), !host.isEmpty {
                out[name] = Machine(name: name, tart: nil, state: "elsewhere", host: host)
            }
        }
        return out.values.sorted { $0.name < $1.name }
    }

    /// Whether a named VM is set up: a Tart VM `apprentice-<name>`, or a `[vm.<name>]` host.
    static func exists(_ vm: String) -> Bool {
        if tables["vm.\(vm)"]?["host"] != nil { return true }
        return tartList().contains { ($0["Name"] as? String) == "apprentice-\(vm)" }
    }

    /// Every VM: the default one, the Tart ones named apprentice-<name>, and `[vm.<name>]` hosts.
    static func list() -> String {
        let tartVMs = tartList()
            .filter { ($0["Source"] as? String) == "local" }
            .compactMap { vm -> (String, String)? in
                guard let n = vm["Name"] as? String, n.hasPrefix("apprentice-") else { return nil }
                return (n, vm["State"] as? String ?? "?")
            }
        var names = Set(tartVMs.map { $0.0 == "apprentice-browser" ? "" : String($0.0.dropFirst("apprentice-".count)) })
        let all = tables
        for key in all.keys where key.hasPrefix("vm.") { names.insert(String(key.dropFirst(3))) }
        guard !names.isEmpty else { return "no VMs: run `apprentice vm setup`" }
        let states = Dictionary(tartVMs, uniquingKeysWith: { a, _ in a })
        return names.sorted().map { n -> String in
            let label = n.isEmpty ? "default" : n
            let use = n.isEmpty ? "agent sessions without APPRENTICE_VM, with `vm on`" : "APPRENTICE_VM=\(n)"
            if let host = all["vm.\(n)"]?["host"].map(Toml.unquote) { return "\(label) · \(host) · \(use)" }
            let tartName = all[n.isEmpty ? "vm" : "vm.\(n)"]?["name"].map(Toml.unquote) ?? (n.isEmpty ? "apprentice-browser" : "apprentice-\(n)")
            return "\(label) · \(tartName) · \(states[tartName] ?? "not set up") · \(use)"
        }.joined(separator: "\n")
    }

    static func status() -> String {
        if host != nil { return "vm \(where_) · \(running ? "reachable" : "not reachable") · routing \(state.on ? "on" : "off")" }
        guard tartPath != nil else { return "vm: tart is not installed · run `apprentice vm setup`" }
        let entry = tartList().first { ($0["Name"] as? String) == name }
        guard let entry else { return "vm: none yet · run `apprentice vm setup`" }
        let s = state
        return "vm \(name) · \(entry["State"] as? String ?? "?") · routing \(s.on ? "on" : "off")" + (s.ip.map { " · \($0)" } ?? "")
    }

    /// Whether an ssh server greets on the guest's port, logged in or not.
    static func answers(_ ip: String) -> Bool {
        let r = run("/usr/bin/nc", ["-w", "2", ip, setting("port", "22")], input: Data())
        return String(decoding: r.out, as: UTF8.self).hasPrefix("SSH-")
    }

    /// Starts the guest without a window: the user sees it through `vm look` when needed.
    static func up() throws -> String {
        if host != nil { return running ? "\(where_) is reachable" : "\(where_) does not answer ssh; start it where it is hosted" }
        guard let path = tartPath else { throw Fail(5, "tart is not installed: run `apprentice vm setup`") }
        if running, let ip = try? address(fresh: true), ssh(ip, "true").code == 0 { return "\(name) is already running at \(ip)" }
        let log = dir.appendingPathComponent("tart.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: log)
        let proc = Process()
        // nohup: the VM keeps running when the terminal that started it closes.
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        proc.arguments = [path, "run", name, "--no-graphics"]
        proc.environment = ProcessInfo.processInfo.environment.merging(tartEnv) { $1 }
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = handle ?? FileHandle.nullDevice
        proc.standardError = handle ?? FileHandle.nullDevice
        try proc.run()
        let ip = try address(fresh: true)
        // Its ssh server answering is enough: a new guest does not take apprentice's key yet.
        let ready = poll(timeout: 60, interval: 1) { answers(ip) ? true : nil } != nil
        return ready ? "\(name) is up at \(ip)" : "\(name) started at \(ip) but ssh is not answering yet; see \(log.path)"
    }

    static func setup() throws -> String {
        var out: [String] = []
        func say(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)); out.append(line) }
        if host == nil, tartPath == nil {
            say("installing tart…")
            let r = run("/bin/bash", [files.appendingPathComponent("get-tart.sh").path])
            guard r.code == 0, tartPath != nil else { throw Fail(5, "could not install tart: \(r.err)") }
        }
        if host == nil, tart(["get", name]).code != 0 {
            let image = setting("image", "ghcr.io/cirruslabs/debian:latest")
            say("downloading \(image) (under 1 GB)…")
            let r = tart(["clone", image, name])
            guard r.code == 0 else { throw Fail(5, "tart clone failed: \(r.err)") }
            // A browser needs little: 2 cores and 2 GB leave the rest of the Mac to the user.
            _ = tart(["set", name, "--cpu", setting("cpu", "2"), "--memory", setting("memory_mb", "2048")])
        }
        say(try up())
        try? FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: key.path) {
            _ = run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "apprentice-vm", "-f", key.path])
        }
        let ip = try address()
        if host != nil, ssh(ip, "true").code != 0 {
            // A server of the user's own: its login is theirs to give, so they add the key once.
            let pub = (try? String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)) ?? ""
            throw Fail(5, "\(where_) does not accept apprentice's key yet. Add this line to ~/.ssh/authorized_keys there (the user needs passwordless sudo too), then run `apprentice vm setup` again:\n\(pub)")
        }
        if ssh(ip, "true").code != 0 {
            // The first login uses the image's password once, to install the key; ssh reads it from SSH_ASKPASS.
            let askpass = dir.appendingPathComponent("askpass.sh")
            try "#!/bin/sh\nprintf '%s\\n' \(shellQuoted(password))\n".write(to: askpass, atomically: true, encoding: .utf8)
            chmod(askpass.path, 0o700)
            defer { try? FileManager.default.removeItem(at: askpass) }
            let pub = (try? Data(contentsOf: key.appendingPathExtension("pub"))) ?? Data()
            let args = ["-o", "PubkeyAuthentication=no", "-o", "StrictHostKeyChecking=accept-new",
                        "-o", "UserKnownHostsFile=\(knownHosts)", "\(user)@\(ip)"]
            // A guest on its first boot resets connections while it makes its host keys, so try a few times.
            var r = (code: Int32(255), out: Data(), err: "")
            for _ in 0..<10 {
                r = run("/usr/bin/ssh", args + ["mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"],
                        input: pub, env: ["SSH_ASKPASS": askpass.path, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0"])
                if r.code == 0 { break }
                Pace.sleep(3)
            }
            guard r.code == 0 else { throw Fail(5, "could not install the ssh key in the VM: \(r.err)") }
        }
        // A VM of apprentice's own drops the image's well-known password for one of its own; the login is
        // by key from here on, and the password is only for VNC (through the ssh tunnel) and sudo.
        let own = dir.appendingPathComponent("password")
        if host == nil, !FileManager.default.fileExists(atPath: own.path) {
            let fresh = (0..<20).map { _ in "abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789".randomElement()! }.map(String.init).joined()
            if ssh(ip, "echo '\(user):\(fresh)' | sudo -n chpasswd").code == 0 {
                FileManager.default.createFile(atPath: own.path, contents: Data(fresh.utf8), attributes: [.posixPermissions: 0o600])
            }
        }
        say("installing Chromium, a terminal and apprentice's helper in the VM…")
        say(try install())
        var s = state
        s.on = true
        state = s
        out += [
            "vm: on · browser sessions now run in \(name)",
            "sign into the sites the agent may use there: `apprentice vm look` opens the VM's screen",
            "terminal commands there: \(shell) '<command>'; Linux apps on screen: `apprentice session --app <name> --on linux`",
        ]
        return out.joined(separator: "\n")
    }

    /// Copies agent/vm into the guest and runs its provision script: packages the first time, then the
    /// session service and the helper. The next command reconnects to the new helper.
    static func install() throws -> String {
        let ip = try address()
        let tar = run("/usr/bin/tar", ["--no-xattrs", "-C", files.path, "-cf", "-", "session.sh", "provision.sh", "helper.py", "ask.py"],
                      env: ["COPYFILE_DISABLE": "1"])
        guard tar.code == 0 else { throw Fail(5, "could not pack \(files.path): \(tar.err)") }
        // The same time zone and language as this Mac (SPEC.md, Consistency).
        let zone = TimeZone.current.identifier
        let lang = (Locale.preferredLanguages.first ?? "en-US").filter { $0.isLetter || $0 == "-" }
        let r = ssh(ip, "rm -rf /tmp/apprentice-vm && mkdir /tmp/apprentice-vm && tar -xf - -C /tmp/apprentice-vm && "
            + "sudo -n sh /tmp/apprentice-vm/provision.sh \(shellQuoted(user)) \(shellQuoted(password)) \(shellQuoted(zone)) \(shellQuoted(lang))", input: tar.out)
        guard r.code == 0 else { throw Fail(5, "could not set up the VM: \(r.err)") }
        Remote.disconnect()
        return "installed the browser, terminal and helper in \(name) (\(ip))\n" + seedClone(ip)
    }

    /// The VM's own `~/.apprentice` and its own clone of the repo (`Layers`). The clone's upstream is this
    /// Mac's clone, sent as a bundle on every install, so notes and local fixes flow down while the VM's own
    /// commits stay in the VM. Only committed work goes; a failure here leaves the VM working as before.
    static func seedClone(_ ip: String) -> String {
        let root = Repo.root
        let current = run("/usr/bin/git", ["-C", root.path, "branch", "--show-current"])
        let branch = String(decoding: current.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.isLetter || $0.isNumber || "._/-".contains($0) }
        guard !branch.isEmpty else { return "warning: \(root.path) is not on a branch, so the VM's clone was not updated" }
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("apprentice-\(UUID().uuidString).bundle")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let made = run("/usr/bin/git", ["-C", root.path, "bundle", "create", "-q", bundle.path, branch])
        guard made.code == 0, let data = try? Data(contentsOf: bundle) else {
            return "warning: could not bundle \(root.path) for the VM's clone: \(made.err)"
        }
        let script = """
        set -e; umask 077; mkdir -p ~/.apprentice; chmod 700 ~/.apprentice
        cat > ~/.apprentice/upstream.bundle
        src=~/.apprentice/src
        if [ -d "$src/.git" ]; then
          git -C "$src" fetch -q upstream
          if ! git -C "$src" rebase -q --autostash upstream/\(branch) 2>/dev/null; then
            git -C "$src" rebase --abort 2>/dev/null || true
            echo "conflict"; exit 3
          fi
        else
          git clone -q -o upstream -b \(branch) ~/.apprentice/upstream.bundle "$src"
          git -C "$src" remote set-url --push upstream no-push
          git -C "$src" config user.name apprentice
          git -C "$src" config user.email "apprentice@$(hostname -s).local"
        fi
        git -C "$src" rev-parse --short HEAD
        """
        let r = ssh(ip, script, input: data)
        let out = String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if r.code == 3 { return "warning: the VM's own commits in ~/.apprentice/src conflict with this Mac's clone; left as it was" }
        guard r.code == 0 else { return "warning: could not update the VM's clone: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))" }
        return "the VM's clone ~/.apprentice/src is at \(out.split(separator: "\n").last ?? ""), from this Mac's \(branch)"
    }
}
