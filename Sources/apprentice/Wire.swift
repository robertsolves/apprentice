import Foundation
import Darwin
import AppKit

struct Request: Codable {
    var cmd: String
    var args: [String] = []
    /// The model driving this command, for its log row; older clients leave it out.
    var model: String? = Request.callerModel
    /// The caller's project `.apprentice/` folder, for project-scoped site counts.
    var project: String? = Project.dir?.path
    /// The terminal tab that started this command (`APPRENTICE_TAB`), so a log row, a pending approval or
    /// a question can be shown in the tab it came from.
    var tab: String? = Request.callerTab
    /// True for a command started by an away task (`APPRENTICE_AWAY=1`): its steps go in the journal.
    var away: Bool? = Request.callerAway
    /// The away task that started it (`APPRENTICE_AWAY_TASK`), so its journal units name the task.
    var awayTask: String? = Request.callerAwayTask
    /// True when the app (`apprentice app`) sends it: the user's own channel, like the menu bar.
    var user: Bool?
    /// The app the caller runs inside (a terminal, an editor): the nearest app that owns a window among the
    /// caller's parents. The overlay's "Go to agent" button takes the user there.
    var host: Int32? = Request.callerHost

    /// The calling agent's model (`Agent.detected`: `APPRENTICE_MODEL`, else found from the agent itself);
    /// `run --model` and an MCP client's name set it for their own requests.
    static var callerModel: String? = Agent.detected

    /// The tab the caller runs in, from the terminal the app started (`APPRENTICE_TAB`).
    static var callerTab: String? {
        let raw = ProcessInfo.processInfo.environment["APPRENTICE_TAB"] ?? ""
        return raw.isEmpty ? nil : String(raw.prefix(80))
    }

    /// Walks up the caller's parent processes to the first running app with a Dock icon.
    static let callerHost: Int32? = {
        var pid = getppid()
        for _ in 0..<12 where pid > 1 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return pid }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
            pid = info.kp_eproc.e_ppid
        }
        return nil
    }()

    static var callerAway: Bool { ProcessInfo.processInfo.environment["APPRENTICE_AWAY"] == "1" }

    static var callerAwayTask: String? {
        let raw = ProcessInfo.processInfo.environment["APPRENTICE_AWAY_TASK"] ?? ""
        return raw.isEmpty ? nil : String(raw.prefix(40))
    }
}

struct Response: Codable {
    var code: Int32 = 0
    var out: String = ""
    var data: [String: String]?
}

enum Wire {
    static func json<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data()
    }

    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        // strncpy returns its destination, so an over-long path must be rejected before copying.
        guard path.utf8.count < maxLen else { return nil }
        path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                    _ = strncpy(dst, src, maxLen - 1)
                }
            }
        }
        return addr
    }

    static func connect(_ path: String = Store.socketPath) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard var addr = address(path) else { close(fd); return nil }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bindPtr in
                Darwin.connect(fd, bindPtr, size)
            }
        }
        if result != 0 {
            close(fd)
            return nil
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Read and write time limits on a socket, so a silent peer cannot hold it forever (B19, H1).
    static func setTimeout(_ fd: Int32, _ seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func readAll(_ fd: Int32) -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            // A signal mid-read is not the end of the reply (B20).
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            out.append(buffer, count: n)
            if out.count > 8 * 1024 * 1024 { break }
        }
        return out
    }

    static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { break }
                sent += n
            }
        }
    }

    /// Sends one request line on `fd`, reads the whole reply and closes the socket.
    private static func roundTrip(_ fd: Int32, _ req: Request) -> Data {
        defer { close(fd) }
        var data = json(req)
        data.append(0x0A)
        writeAll(fd, data)
        shutdown(fd, SHUT_WR)
        return readAll(fd)
    }

    /// Every request goes to this Mac's daemon; it drives the browser VM itself (`Remote`).
    static func send(_ req: Request) throws -> Response { try sendLocal(req) }

    /// One request to a VM's daemon (`vms/<name>/sock`), which must already be running.
    static func send(_ req: Request, vm: String) throws -> Response {
        let path = Store.dir.appendingPathComponent("vms/\(vm)/sock").path
        guard let fd = connect(path) else { throw Fail(5, "the \(vm) daemon is not running") }
        setTimeout(fd, 1500)
        let reply = roundTrip(fd, req)
        guard !reply.isEmpty, let resp = try? JSONDecoder().decode(Response.self, from: reply) else {
            throw Fail(5, "no reply from the \(vm) daemon")
        }
        return resp
    }

    static func sendLocal(_ req: Request) throws -> Response {
        var fd = connect()
        if fd == nil {
            try startDaemon()
            fd = connect()
        }
        guard let fd else { throw Fail(5, "daemon did not start: run `apprentice serve` to see why") }
        // A question window can take its full timeout; past that the daemon is stuck, not busy.
        setTimeout(fd, 1500)
        let reply = roundTrip(fd, req)
        guard !reply.isEmpty else { throw Fail(5, "daemon closed the connection") }
        guard let resp = try? JSONDecoder().decode(Response.self, from: reply) else {
            throw Fail(5, "bad reply from daemon")
        }
        return resp
    }

    static func ping() -> Bool {
        guard let fd = connect() else { return false }
        setTimeout(fd, 3)
        return !roundTrip(fd, Request(cmd: "ping")).isEmpty
    }

    static func binaryPath() -> String {
        // The app's bundle only ever opens the window, so from there the CLI is the installed binary.
        if AppBundle.inBundle {
            let bin = Build.install?.bin ?? Release.cli?.path
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/apprentice").path
            if FileManager.default.isExecutableFile(atPath: bin) { return bin }
        }
        if let path = Bundle.main.executablePath { return path }
        return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    }

    static func startDaemon() throws {
        if ping() { return }
        let logPath = Store.stateDir.appendingPathComponent("daemon.err")
        FileManager.default.createFile(atPath: logPath.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logPath)
        let sink = log ?? FileHandle(forWritingAtPath: "/dev/null")
        // On its own, so its grants are apprentice's whether the window, a tab or a terminal started it.
        guard let pid = Own.spawn(binaryPath(), ["serve", "--background"], out: sink?.fileDescriptor ?? 2) else {
            throw Fail(5, "cannot start daemon: \(String(cString: strerror(errno)))")
        }
        // Reaped when it ends, so a window that outlives it keeps no zombie.
        DispatchQueue.global(qos: .utility).async { var status: Int32 = 0; waitpid(pid, &status, 0) }
        let started = poll(timeout: 10, interval: 0.12) { ping() ? true : nil } != nil
        try? log?.close()
        if started {
            try? FileManager.default.removeItem(at: logPath)
            return
        }
        let detail = (try? String(contentsOf: logPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hint = detail.isEmpty ? "" : ": \(detail)"
        // 7 means a missing permission; a daemon that did not come up is a plain failure (B6).
        throw Fail(5, "daemon did not start\(hint)")
    }

    /// Whether the daemon is gone afterwards, and what happened.
    /// Stops the other VMs' daemons too, after a rebuild or an update: each runs the old binary.
    static func stopVMDaemons() {
        let root = Store.dir.appendingPathComponent("vms")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
            let path = root.appendingPathComponent("\(name)/sock").path
            guard path != Store.socketPath, let fd = connect(path) else { continue }
            setTimeout(fd, 5)
            _ = roundTrip(fd, Request(cmd: "stop"))
        }
    }

    static func stopDaemon() -> (Bool, String) {
        if let fd = connect() {
            setTimeout(fd, 5)
            _ = roundTrip(fd, Request(cmd: "stop"))
            let gone = poll(timeout: 3, interval: 0.1) { ping() ? nil : true } != nil
            return gone ? (true, "stopped") : (false, "the daemon is still running: it may be busy with a command")
        }
        // No socket: either nothing runs, or the daemon is too busy to accept. Clear what a crash
        // left behind only once the process is gone, so a second `stop` still finds a live pid.
        func clear() {
            unlink(Store.socketPath)
            try? FileManager.default.removeItem(atPath: Store.pidPath)
        }
        guard let raw = try? String(contentsOfFile: Store.pidPath, encoding: .utf8),
              let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            clear()
            return (true, "not running")
        }
        // A pid left by a crash may now belong to another program: only signal apprentice (E2).
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
              String(cString: buffer).hasSuffix("/apprentice") else {
            clear()
            return (true, "not running (cleared a stale pid file)")
        }
        kill(pid, SIGTERM)
        let gone = poll(timeout: 3, interval: 0.1) { kill(pid, 0) == 0 ? nil : true } != nil
        if gone { clear() }
        return gone ? (true, "stopped") : (false, "pid \(pid) did not stop")
    }
}

final class UnixServer {
    private let path: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let handler: (Request) -> (Response, Bool)
    private var stopping = false

    init(path: String, handler: @escaping (Request) -> (Response, Bool)) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Fail(5, "socket: \(String(cString: strerror(errno)))") }

        guard var addr = Wire.address(path) else { throw Fail(5, "socket path too long: \(path)") }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) }
        }
        guard bound == 0 else { throw Fail(5, "bind \(path): \(String(cString: strerror(errno)))") }
        guard listen(fd, 16) == 0 else { throw Fail(5, "listen: \(String(cString: strerror(errno)))") }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.acceptReady() }
        src.resume()
        source = src
    }

    private func acceptReady() {
        while true {
            var addr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let cfd = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) }
            }
            if cfd < 0 { break }
            var one: Int32 = 1
            setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.serve(cfd)
            }
        }
    }

    private func serve(_ cfd: Int32) {
        // Accepted sockets can inherit O_NONBLOCK on Darwin; read must block until the caller sends.
        let flags = fcntl(cfd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(cfd, F_SETFL, flags & ~O_NONBLOCK) }
        Wire.setTimeout(cfd, 10)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(cfd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
            if data.contains(0x0A) { break }
            if data.count > 4 * 1024 * 1024 { break }
        }
        var stop = false
        let response: Response
        if let line = data.split(separator: 0x0A).first,
           var req = try? JSONDecoder().decode(Request.self, from: Data(line)) {
            // The user's channel is the signed app only: a `user` flag from anything else is dropped (`Peer`).
            if req.user == true, !Peer.isApp(cfd) { req.user = nil }
            // ping and stop never wait behind a running command, such as an open question window (H1).
            if req.cmd == "ping" {
                response = Response(code: 0, out: "pong")
            } else if req.cmd == "stop" {
                Store.log(["cmd": "stop"])
                response = Response(code: 0, out: "stopped")
                stop = true
            } else {
                // Not the main queue: the kill switch and Borrow's monitors run there and must fire mid-command.
                let result = Daemon.queue(for: req).sync { () -> (Response, Bool) in
                    // A question window watches this socket, so it can tell when the caller stops waiting.
                    Thread.current.threadDictionary[Ask.callerKey] = cfd
                    defer { Thread.current.threadDictionary.removeObject(forKey: Ask.callerKey) }
                    return handler(req)
                }
                response = result.0
                stop = result.1
            }
        } else {
            response = Response(code: 5, out: "bad request")
        }
        var payload = Wire.json(response)
        payload.append(0x0A)
        Wire.writeAll(cfd, payload)
        close(cfd)
        if stop {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.stop() }
        }
    }

    func stop() {
        guard !stopping else { return }
        stopping = true

        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
        unlink(path)
        try? FileManager.default.removeItem(atPath: Store.pidPath)
        // An open question window would hold terminate back, so close it first; exit if terminate returns.
        NSApplication.shared.abortModal()
        NSApplication.shared.terminate(nil)
        exit(0)
    }
}

/// Starts a process that answers to macOS for itself. A child normally counts as part of whoever started
/// it, so the same binary would get Accessibility and Screen Recording as the terminal, the window or an
/// agent's shell, whichever ran it, and the grants would change with the caller. Started this way, the
/// daemon and every grant check are apprentice's own binary, the one entry the user switches on.
enum Own {
    /// `responsibility_spawnattrs_setdisclaim`, as Terminal uses for its shells; private, so looked up.
    static func disclaim(_ attr: inout posix_spawnattr_t?) {
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") {
            _ = unsafeBitCast(sym, to: Disclaim.self)(&attr, 1)
        }
    }

    /// Spawns `path` with stdin closed and stdout and stderr on `out`; nil when it cannot start.
    static func spawn(_ path: String, _ args: [String], out: Int32) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out, 1)
        posix_spawn_file_actions_adddup2(&actions, out, 2)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        disclaim(&attr)
        let argv = ([path] + args).map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attr)
        }
        var pid: pid_t = 0
        return posix_spawn(&pid, path, &actions, &attr, argv, environ) == 0 ? pid : nil
    }

    /// Runs `path` to the end on its own and returns its exit code and output.
    static func run(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
        let pipe = Pipe()
        guard let pid = spawn(path, args, out: pipe.fileHandleForWriting.fileDescriptor) else {
            return (5, "could not run \(path)")
        }
        try? pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return (code, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
