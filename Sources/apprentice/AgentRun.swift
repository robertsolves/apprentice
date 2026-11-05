import Darwin
import Foundation

/// Runs one agent CLI (or a shell step) to its end without a terminal: output kept and shown as it comes, JSON-line
/// CLIs decoded to their text, and the time limits watched. Waiting for the user does not count as a stall.
enum AgentRun {
    enum Outcome: String, Codable {
        case ok, failed, stalled, timedOut = "timed out", noOutput = "no output", stopped, interrupted
    }

    struct Result {
        var outcome: Outcome
        var code: Int32
        /// Everything it printed, decoded, without colour codes.
        var text: String
        /// Standard output only: what a scribe or an interpreter answered, without a CLI's own noise.
        var stdout: String
        /// The session id, when the CLI's output carries one.
        var session: String?
        var seconds: Int
    }

    /// Filled in when a run should not go through the user's login shell (a self-test, where it adds seconds).
    static var plainShell: Bool { ProcessInfo.processInfo.environment["APPRENTICE_PIPELINE_SHELL"] == "plain" }

    /// The command line wrapped in a login shell, so the CLI is found as it is in the user's own terminal, with
    /// this binary first on the PATH so an agent's `apprentice` is the build running the pipeline.
    static func wrapped(_ argv: [String]) -> [String] {
        let dir = URL(fileURLWithPath: Wire.binaryPath()).deletingLastPathComponent().path
        let script = "PATH=\(VM.shellQuoted(dir)):\"$PATH\" exec \"$@\""
        return ["/bin/zsh", plainShell ? "-c" : "-lc", script, "zsh"] + argv
    }

    private static let colour = try? NSRegularExpression(pattern: "\u{1b}\\[[0-9;?]*[A-Za-z]|\u{1b}\\][^\u{07}]*\u{07}")

    static func plain(_ text: String) -> String {
        guard let colour else { return text }
        return colour.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// A dotted path into one JSON object.
    static func dig(_ object: Any, _ path: String) -> Any? {
        var at: Any? = object
        for key in path.split(separator: ".") { at = (at as? [String: Any])?[String(key)] }
        return at
    }

    /// One line of a JSON-printing CLI: its text or error, if any, and its session id, if any.
    static func decode(line: String, cli: AgentCLIs.CLI?) -> (text: String?, session: String?) {
        guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return (line, nil) }
        let session = cli?.sessionFrom.flatMap { dig(object, $0) as? String }
        if let path = cli?.errorFrom, let message = dig(object, path) as? String { return (message, session) }
        if let path = cli?.textFrom, let text = dig(object, path) as? String { return (text, session) }
        return (nil, session)
    }

    private final class Capture {
        let lock = NSLock()
        var all = "", out = "", session: String?, last = Date()
        var buffers: [Int: String] = [:]
        var finished = Set<Int>()
    }

    /// `activity`: files whose change counts as the step being alive. `paused`: the clock stops while true.
    /// `interrupt`: stop this one CLI, the run going on. `echo`: called with each piece of decoded output.
    static func run(_ argv: [String], cli: AgentCLIs.CLI?, in dir: URL, env extra: [String: String], log: URL?,
                    stallSeconds: Double, totalSeconds: Double, activity: [URL] = [], paused: @escaping () -> Bool = { false },
                    stop: @escaping () -> Bool = { false }, interrupt: @escaping () -> Bool = { false }, echo: ((String) -> Void)? = nil) -> Result {
        let started = Date()
        guard !argv.isEmpty else { return Result(outcome: .failed, code: 127, text: "no CLI to run", stdout: "", session: nil, seconds: 0) }
        let proc = Process()
        let line = wrapped(argv)
        proc.executableURL = URL(fileURLWithPath: line[0])
        proc.arguments = Array(line.dropFirst())
        proc.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extra { env[k] = v }
        proc.environment = env
        proc.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        if let log {
            try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        }
        let logHandle = log.flatMap { try? FileHandle(forWritingTo: $0) }
        _ = try? logHandle?.seekToEnd()
        let rawURL = cli?.textFrom == nil ? nil : log?.deletingLastPathComponent().appendingPathComponent("raw.jsonl")
        if let rawURL, !FileManager.default.fileExists(atPath: rawURL.path) { FileManager.default.createFile(atPath: rawURL.path, contents: nil) }
        let rawHandle = rawURL.flatMap { try? FileHandle(forWritingTo: $0) }
        _ = try? rawHandle?.seekToEnd()
        let cap = Capture()

        func take(_ text: String, isOut: Bool) {
            let clean = plain(text)
            guard !clean.isEmpty else { return }
            cap.all += clean
            if isOut { cap.out += clean }
            // Keep the buffers bounded on a chatty step: only the end is ever read back here, the log has the rest.
            if cap.all.count > 400_000 { cap.all = String(cap.all.suffix(200_000)) }
            if cap.out.count > 400_000 { cap.out = String(cap.out.suffix(200_000)) }
            if let data = clean.data(using: .utf8) { try? logHandle?.write(contentsOf: data) }
            echo?(clean)
        }
        func feed(_ data: Data, id: Int) {
            cap.lock.lock()
            defer { cap.lock.unlock() }
            cap.last = Date()
            let text = String(decoding: data, as: UTF8.self)
            guard cli?.textFrom != nil else { take(text, isOut: id == 1); return }
            try? rawHandle?.write(contentsOf: data)
            var buffer = cap.buffers[id, default: ""] + text
            while let newline = buffer.firstIndex(of: "\n") {
                let one = String(buffer[..<newline])
                buffer = String(buffer[buffer.index(after: newline)...])
                let decoded = decode(line: one, cli: cli)
                if let s = decoded.session { cap.session = s }
                if let t = decoded.text, !t.isEmpty { take(t.hasSuffix("\n") ? t : t + "\n", isOut: id == 1) }
            }
            cap.buffers[id] = buffer
        }
        for (id, pipe) in [(1, outPipe), (2, errPipe)] {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    cap.lock.lock(); cap.finished.insert(id); cap.lock.unlock()
                } else {
                    feed(data, id: id)
                }
            }
        }
        do { try proc.run() } catch {
            for pipe in [outPipe, errPipe] { pipe.fileHandleForReading.readabilityHandler = nil }
            try? logHandle?.close(); try? rawHandle?.close()
            return Result(outcome: .failed, code: 127, text: "could not start: \(error.localizedDescription)", stdout: "", session: nil, seconds: 0)
        }

        // The clock: output, a changed file or a touched activity file resets the stall timer; a pause stops both.
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("apprentice-stall-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: marker) }
        var lastActive = Date(), lastScan = Date(), pausedFor = 0.0, lastTick = Date()
        var ending: Outcome?
        var killedAt: Date?
        var victims: [pid_t] = []
        while proc.isRunning {
            usleep(100_000)
            let now = Date()
            if paused() { pausedFor += now.timeIntervalSince(lastTick); lastActive = now }
            lastTick = now
            if ending == nil {
                if stop() { ending = .stopped }
                else if interrupt() { ending = .interrupted }
                else {
                    cap.lock.lock(); let heard = cap.last; cap.lock.unlock()
                    if heard > lastActive { lastActive = heard }
                    for file in activity {
                        if let at = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, at > lastActive { lastActive = at }
                    }
                    if stallSeconds < totalSeconds, now.timeIntervalSince(lastScan) > min(30, stallSeconds / 4) {
                        lastScan = now
                        if filesChanged(in: dir, since: marker) {
                            lastActive = now
                            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: marker.path)
                        }
                    }
                    if now.timeIntervalSince(started) - pausedFor > totalSeconds { ending = .timedOut }
                    else if now.timeIntervalSince(lastActive) > stallSeconds { ending = .stalled }
                }
                if ending != nil {
                    victims = tree(proc.processIdentifier)
                    for pid in victims { kill(pid, SIGTERM) }
                    killedAt = now
                }
            } else if let killedAt, now.timeIntervalSince(killedAt) > 5 {
                victims = Array(Set(victims + tree(proc.processIdentifier)))
                for pid in victims { kill(pid, SIGKILL) }
            }
        }
        proc.waitUntilExit()
        // The CLI went on SIGTERM, but whatever it started may not have, and must not keep working in the folder.
        if ending != nil {
            usleep(200_000)
            for pid in victims where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        // A grandchild can hold the pipes open past the CLI's end: give the rest a moment, then stop reading.
        let drain = Date().addingTimeInterval(1)
        while Date() < drain {
            cap.lock.lock(); let both = cap.finished.count == 2; cap.lock.unlock()
            if both { break }
            usleep(20_000)
        }
        for pipe in [outPipe, errPipe] { pipe.fileHandleForReading.readabilityHandler = nil }
        try? logHandle?.close(); try? rawHandle?.close()
        cap.lock.lock()
        defer { cap.lock.unlock() }
        // A JSON CLI's last line with no newline.
        for (_, rest) in cap.buffers where !rest.isEmpty {
            let decoded = decode(line: rest, cli: cli)
            if let s = decoded.session { cap.session = s }
            if let t = decoded.text { take(t, isOut: true) }
        }
        let code = proc.terminationStatus
        var outcome = ending ?? (code == 0 ? Outcome.ok : .failed)
        if outcome == .ok, cap.all.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { outcome = .noOutput }
        return Result(outcome: outcome, code: code, text: cap.all, stdout: cap.out, session: cap.session, seconds: Int(Date().timeIntervalSince(started)))
    }

    /// The process and everything under it, however deep: a CLI's bash, its npm and its node would otherwise carry on
    /// editing the folder while the next agent works there. Children first.
    static func tree(_ pid: pid_t) -> [pid_t] {
        let r = Repo.run("/usr/bin/pgrep", ["-P", "\(pid)"])
        let children = r.out.split(separator: "\n").compactMap { pid_t($0) }
        return children.flatMap(tree) + [pid]
    }

    private static func filesChanged(in dir: URL, since marker: URL) -> Bool {
        let r = Repo.run("/usr/bin/find", [dir.path, "-type", "f", "-newer", marker.path, "-not", "-path", "*/.git/*", "-not", "-path", "*/node_modules/*",
                                           "-not", "-path", "*/.apprentice/cache/*", "-print", "-quit"])
        return r.code == 0 && !r.out.isEmpty
    }

    // MARK: - reading the output

    static func limitPhrase(cli: AgentCLIs.CLI?, text: String) -> String? {
        let tail = String(text.suffix(4000)).lowercased()
        return cli?.limits.first { tail.contains($0.lowercased()) }
    }

    static func refusalPhrase(cli: AgentCLIs.CLI?, text: String) -> String? {
        let tail = String(text.suffix(4000)).lowercased()
        return cli?.refusals.first { tail.contains($0.lowercased()) }
    }

    /// The agent's own last-resort line: `BLOCKED: what it needs`. Every CLI can print a line, even one whose
    /// sandbox stops it reaching apprentice.
    static func blockedLine(_ text: String) -> String? {
        for line in text.components(separatedBy: .newlines).suffix(30).reversed() {
            let t = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t`*>"))
            if t.hasPrefix("BLOCKED:") { return String(t.dropFirst("BLOCKED:".count)).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    /// When a limit says when it ends ("try again at Nov 17th, 2026 1:16 PM"), that moment.
    static func limitEnds(_ text: String) -> Date? {
        guard let at = text.range(of: "try again at ", options: [.caseInsensitive, .backwards]) else { return nil }
        var rest = String(text[at.upperBound...].prefix { !$0.isNewline })
        if rest.hasSuffix(".") { rest.removeLast() }
        rest = rest.replacingOccurrences(of: #"(\d)(st|nd|rd|th)"#, with: "$1", options: .regularExpression)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["MMM d, yyyy h:mm a", "MMMM d, yyyy h:mm a", "MMM d, yyyy", "h:mm a"] {
            f.dateFormat = format
            if let d = f.date(from: rest), d.timeIntervalSinceNow > 0 { return d }
        }
        return nil
    }

    // MARK: - the CLI's own session

    /// A path as the file system really names it (`/tmp` is `/private/tmp`): CLIs key their folders on that.
    static func real(_ url: URL) -> String {
        guard let r = realpath(url.path, nil) else { return url.path }
        defer { free(r) }
        return String(cString: r)
    }

    static func escaped(_ cwd: URL) -> String { real(cwd).map { $0 == "/" || $0 == "." ? "-" : $0 }.reduce(into: "") { $0.append($1) } }

    static func expand(_ template: String, cli: AgentCLIs.CLI?, session: String?, cwd: URL) -> String {
        var id = session ?? ""
        if let short = cli?.sessionShort { id = String(id.prefix(short)) }
        let t = template.replacingOccurrences(of: "{cwd_escaped}", with: escaped(cwd))
            .replacingOccurrences(of: "{cwd_base}", with: URL(fileURLWithPath: real(cwd)).lastPathComponent)
            .replacingOccurrences(of: "{session}", with: id)
        return (t as NSString).expandingTildeInPath
    }

    static func globbed(_ pattern: String) -> [String] {
        var g = glob_t()
        defer { globfree(&g) }
        guard glob(pattern, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_matchc)).compactMap { g.gl_pathv[$0].map { String(cString: $0) } }
    }

    /// Removes one session this run started: only ever an id apprentice chose or read from that run's own output.
    /// Returns what it removed, in words, for `tidy`.
    @discardableResult
    static func forget(cli: AgentCLIs.CLI?, session: String?, cwd: URL) -> [String] {
        guard let cli, let session, !session.isEmpty else { return [] }
        var out: [String] = []
        if let t = cli.transcript {
            for path in globbed(expand(t, cli: cli, session: session, cwd: cwd)) where (try? FileManager.default.removeItem(atPath: path)) != nil {
                out.append(path)
            }
        }
        if !cli.forget.isEmpty {
            let argv = cli.forget.map { $0.replacingOccurrences(of: "{session}", with: session) }
            let line = wrapped(argv)
            let r = Repo.run(line[0], Array(line.dropFirst()))
            if r.code == 0 { out.append("\(cli.id) session \(session)") }
        }
        return out
    }

    /// The folder a CLI keeps for a working folder that is going away (a worktree).
    static func forgetFolder(cli: AgentCLIs.CLI?, cwd: URL) {
        guard let t = cli?.projectDir else { return }
        try? FileManager.default.removeItem(atPath: expand(t, cli: cli, session: nil, cwd: cwd))
    }
}
