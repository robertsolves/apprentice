import AppKit
import CoreGraphics
import Foundation

/// Work that runs while the user is away and stops the moment they come back: `away add`, the monitor in
/// the daemon, exit 10 ("yielded: the user is back") and `away wait`, so an agent such as Claude Code can
/// pause and resume safely instead of fighting the person for the mouse.
///
/// The rule that makes it safe: never continue from where it thinks it was. After a yield the screen is
/// read again and checked against the journal; when it does not match, the task becomes needs-you and the
/// question goes to the phone. It never guesses.
enum Away {
    // MARK: - mode

    /// `away on` (the file `Ask.away` already reads, so questions keep going to the chat as before).
    static var mode: Bool { Store.load(Ask.Away.self, "away.json")?.on ?? false }

    static func setMode(_ on: Bool) {
        if on { Store.save(Ask.Away(on: true), "away.json") } else { Store.remove("away.json") }
        Store.log(["away": on])
    }

    static var afterMinutes: Double {
        let v = Toml.load(Config.path)["away"]?["after_min"].map(Toml.unquote) ?? "3"
        return max(Double(v) ?? 3, 0.5)
    }

    static var hostAllowed: Bool { (Toml.load(Config.path)["away"]?["host"].map(Toml.unquote) ?? "false") == "true" }

    static var countdownSeconds: Int {
        Int(Toml.unquote(Toml.load(Config.path)["away"]?["countdown_s"] ?? "10")) ?? 10
    }

    // MARK: - presence

    /// Apps that hold a display-sleep assertion: a video player, a call. Being idle in front of one is not
    /// being away (`pmset -g assertions`).
    static func displayAsserters() -> [String] {
        guard let text = try? String(contentsOfFile: "/usr/bin/pmset", encoding: .utf8) else { return [] }
        return text.components(separatedBy: "pid ").compactMap { part in
            guard part.contains("PreventUserIdleDisplaySleep") else { return nil }
            let name = part.split(separator: "(").first.map(String.init) ?? ""
            return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The list of assertion holders, read from `pmset` (a subprocess, so it is cheap and cached briefly).
    private static var asserterCache: (at: Date, names: [String]) = (.distantPast, [])
    static func holdingDisplay() -> [String] {
        if Date().timeIntervalSince(asserterCache.at) < 20 { return asserterCache.names }
        let out = Repo.run("/usr/bin/pmset", ["-g", "assertions"]).out
        var names: [String] = []
        var inside = false
        for line in out.components(separatedBy: "\n") {
            if line.contains("PreventUserIdleDisplaySleep") { inside = true; continue }
            if inside {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { inside = false; continue }
                if let name = trimmed.split(separator: " ").first, name != "pid" { names.append(String(name)) }
            }
        }
        // apprentice's own hold (`Awake`) does not keep the user at the Mac.
        names.removeAll { $0.contains("apprentice") }
        asserterCache = (Date(), names)
        return names
    }

    static var screenLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Away needs both: the person has not touched anything for `after_min`, and nothing holds the display
    /// awake. A video or a call keeps it, so nobody is "away" while watching.
    static func isAway(now: Date = Date()) -> Bool {
        guard mode else { return false }
        return Borrow.humanIdle >= afterMinutes * 60 && holdingDisplay().isEmpty
    }

    /// Used by commands: the user is at the Mac right now.
    static func userPresent() -> Bool { Borrow.humanIdle < afterMinutes * 60 }

    // MARK: - the queue

    enum State: String, Codable {
        case queued, running, yielded, needsYou = "needs-you", done, failed

        var label: String {
            switch self {
            case .queued: return "queued"
            case .running: return "running"
            case .yielded: return "yielded (you came back)"
            case .needsYou: return "needs you"
            case .done: return "done"
            case .failed: return "failed"
            }
        }
    }

    struct Task: Codable {
        var id: String
        var kind: String  // flow | run
        var target: String
        var vm: String?
        var host: Bool?
        var state: State
        var created: Double
        var started: Double?
        var finished: Double?
        var earliest: Double?
        var deadline: Double?
        var note: String?
        var log: String?

        var whenLabel: String {
            guard let earliest else { return "as soon as you are away" }
            return "not before " + Date(timeIntervalSince1970: earliest).formatted(date: .abbreviated, time: .shortened)
        }
    }

    static var dir: URL {
        let url = Store.dir.appendingPathComponent("away")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var queuePath: URL { dir.appendingPathComponent("queue.json") }
    static var journalPath: URL { dir.appendingPathComponent("journal.jsonl") }

    static func all() -> [Task] {
        guard let data = try? Data(contentsOf: queuePath),
              let list = try? JSONDecoder().decode([Task].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [Task]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: queuePath, options: .atomic)
        chmod(queuePath.path, 0o600)
    }

    @discardableResult
    static func update<T>(_ body: (inout [Task]) throws -> T) rethrows -> T {
        try Store.locked(at: queuePath) {
            var list = all()
            let result = try body(&list)
            save(list)
            return result
        }
    }

    static func find(_ id: String) -> Task? { all().first { $0.id == id } }

    static func add(_ t: Task) { update { $0.append(t) } }

    // MARK: - journal

    /// One unit: steps that only make sense completed together, such as typing a message and sending it.
    struct Unit: Codable {
        /// The queue task it belongs to, or "" for a command an agent ran itself.
        var task: String
        var step: String
        var host: String?
        var window: Int?
        var label: String?
        var typed: String?
        /// What undo does: `clear` a field that still holds exactly what was typed.
        var inverse: String?
        var at: Double
    }

    /// The queue task whose command is running now, so its steps land in the journal.
    private static let recordingKey = DispatchSpecificKey<String>()
    static var recording: String? {
        get { Thread.current.threadDictionary["apprentice.away.recording"] as? String }
        set {
            if let newValue { Thread.current.threadDictionary["apprentice.away.recording"] = newValue }
            else { Thread.current.threadDictionary.removeObject(forKey: "apprentice.away.recording") }
        }
    }

    static func journal(_ unit: Unit) {
        guard let data = try? JSONEncoder().encode(unit) else { return }
        var line = data
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: journalPath) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: journalPath)
        }
        chmod(journalPath.path, 0o600)
    }

    static func units(_ task: String? = nil) -> [Unit] {
        Store.readLines(journalPath).compactMap { row -> Unit? in
            guard let data = try? JSONSerialization.data(withJSONObject: row) else { return nil }
            return try? JSONDecoder().decode(Unit.self, from: data)
        }.filter { task == nil || $0.task == task }
    }

    /// What was left half-done, in words the overlay can show: "typed 14 of 40 characters into Message on
    /// example.com, nothing sent".
    static func leftover(_ task: Task) -> String? {
        guard let unit = units(task.id).last else { return nil }
        let where_ = unit.host.map { " on \($0)" } ?? ""
        if let text = unit.typed, !text.isEmpty {
            return "typed \(text.count) character\(text.count == 1 ? "" : "s") into \(unit.label ?? "a field")\(where_), nothing sent"
        }
        return "stopped after \(unit.step)\(where_)"
    }

    // MARK: - the resume decision

    enum Decision: String {
        case proceed
        case redoUnit
        case needsUser
    }

    /// Pure: the journal and a fresh read of the screen in, the next move out. If the screen does not match
    /// the unit's preconditions, or the unit already happened, only the user can decide.
    static func decide(preconditionsHold: Bool, cutMidway: Bool, alreadyHappened: Bool) -> Decision {
        if !preconditionsHold { return .needsUser }
        if alreadyHappened { return .needsUser }
        if cutMidway { return .redoUnit }
        return .proceed
    }

    /// Clears a field that still holds exactly what was typed, and nothing else. False when it cannot be
    /// sure, which makes the task needs-you.
    static func undo(_ unit: Unit) -> Bool {
        guard unit.inverse == "clear", let typed = unit.typed, !typed.isEmpty,
              let session = Session.stored, session.vm != true else { return false }
        guard let app = NSRunningApplication(processIdentifier: session.pid), !app.isTerminated else { return false }
        let root = appElement(session.pid)
        guard let focused = root.attr(kAXFocusedUIElementAttribute) as! AXUIElement?,
              let value = focused.string(kAXValueAttribute),
              // Only the field that still holds exactly apprentice's partial text: never the user's words.
              value.filter({ !$0.isWhitespace }) == typed.filter({ !$0.isWhitespace }) else { return false }
        app.activate()
        Pace.sleep(0.3)
        try? Keys.press("cmd+a")
        try? Keys.press("delete")
        return true
    }

    /// On the return: stop before the next event, give the app back, and say what was left. Never resumes
    /// by memory: the caller reads the screen again first.
    static func resume(_ task: Task) {
        let note = leftover(task) ?? "stopped before acting"
        update { list in
            guard let i = list.firstIndex(where: { $0.id == task.id }) else { return }
            list[i].state = .needsYou
            list[i].note = note
            list[i].finished = Date().timeIntervalSince1970
        }
        Store.log(["cmd": "away", "task": task.id, "yielded": note])
        Notify.local("Away task \(task.target) stopped: \(note)", title: "apprentice: you are back")
    }

    // MARK: - monitor

    private static var timer: DispatchSourceTimer?
    private static var runningTask: String?

    static func install() {
        guard timer == nil, Store.vmName == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "apprentice.away"))
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { tick() }
        t.resume()
        timer = t
    }

    static func uninstall() {
        timer?.cancel()
        timer = nil
    }

    /// One look: yield a running task when the user is back, start the next one when they are away.
    static func tick(now: Date = Date()) {
        guard mode else { return }
        if let id = runningTask, let task = find(id) {
            if !isAway(now: now) { resume(task) }
            return
        }
        guard isAway(now: now) else { return }
        let queued = all().filter { $0.state == .queued }.sorted { $0.created < $1.created }
        guard let next = queued.first else { return }
        if let earliest = next.earliest, earliest > now.timeIntervalSince1970 { return }
        if let deadline = next.deadline, deadline < now.timeIntervalSince1970 {
            update { list in
                if let i = list.firstIndex(where: { $0.id == next.id }) {
                    list[i].state = .failed
                    list[i].note = "past its deadline before it could run"
                    list[i].finished = now.timeIntervalSince1970
                }
            }
            return
        }
        if next.host == true, !hostAllowed { return }
        guard next.host == true || next.vm != nil || hostAllowed else { return }
        start(next)
    }

    /// Runs one task on its own queue, so the monitor keeps watching for the user's return.
    static func start(_ task: Task) {
        runningTask = task.id
        update { list in
            guard let i = list.firstIndex(where: { $0.id == task.id }) else { return }
            list[i].state = .running
            list[i].started = Date().timeIntervalSince1970
        }
        DispatchQueue.global(qos: .utility).async {
            let (state, note) = run(task)
            runningTask = nil
            update { list in
                guard let i = list.firstIndex(where: { $0.id == task.id }) else { return }
                list[i].state = state
                list[i].note = note
                list[i].finished = Date().timeIntervalSince1970
            }
            Store.log(["cmd": "away", "task": task.id, "state": state.rawValue])
            if state == .needsYou || state == .failed { Notify.local("Away task \(task.target): \(note ?? state.label)", title: "apprentice away") }
        }
    }

    private static func run(_ task: Task) -> (State, String?) {
        let binary = Wire.binaryPath()
        var argv = [binary]
        if let vm = task.vm, !vm.isEmpty { argv += ["--vm", vm] }
        argv += task.kind == "flow" ? ["do", task.target] : ["run", task.target]
        let logURL = dir.appendingPathComponent("\(task.id).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return (.failed, "could not write \(logURL.path)") }
        defer { try? handle.close() }
        handle.write(Data("# away \(task.kind): \(task.target)\n\n".utf8))
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = Array(argv.dropFirst())
        var env = ProcessInfo.processInfo.environment
        env["APPRENTICE_AWAY"] = "1"
        env["APPRENTICE_AWAY_TASK"] = task.id
        proc.environment = env
        proc.standardOutput = handle
        proc.standardError = handle
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() } catch { return (.failed, "could not start: \(error.localizedDescription)") }
        proc.waitUntilExit()
        let note = "exit \(proc.terminationStatus) · output in \(logURL.path)"
        switch proc.terminationStatus {
        case 0: return (.done, note)
        case 10: return (.yielded, "you came back; nothing more was done")
        case 8, 9: return (.needsYou, "a step needs your approval or an answer")
        case 6: return (.yielded, "stopped: the screen was taken")
        default: return (.failed, note)
        }
    }

    // MARK: - CLI

    static let usage = "away on|off|status|wait|add|list|cancel <id>|run <id> · add (--do <flow> | --run \"task\") [--vm name|--host] [--at <date>] [--deadline <date>]"

    static func command(_ a: Args) throws -> String {
        switch a.pos.first ?? "status" {
        case "on":
            setMode(true)
            var out = "away: on · queued work runs while you are away, and stops when you touch the Mac. Questions go to the chat (exit 9)."
            if let next = all().first(where: { $0.state == .queued }) { out += "\nqueued: \(next.target)" }
            if !hostAllowed { out += "\naway work runs in a VM or a flow; this Mac runs it only with [away] host = true." }
            return out
        case "off":
            let was = mode
            setMode(false)
            update { list in
                for i in list.indices where list[i].state == .running {
                    list[i].state = .yielded
                    list[i].note = "away mode turned off"
                }
            }
            return was ? "away: off · nothing new starts; questions open the little window again" : "away: off"
        case "status": return status()
        case "wait": return try wait(a)
        case "add": return try add(a)
        case "list": return list()
        case "cancel": return try cancel(a)
        case "run": return try runNow(a)
        default: throw Fail(5, usage)
        }
    }

    static func status() -> String {
        let idle = Int(Borrow.humanIdle)
        let holders = holdingDisplay()
        var lines = [
            "away: \(mode ? "on" : "off") · \(mode ? (isAway() ? "you are away: queued work runs" : "you are here: nothing starts") : "`away on` starts it")",
            "idle \(idle) s (away after \(Int(afterMinutes * 60)) s)" + (holders.isEmpty ? "" : " · another app holds the display awake: \(holders.prefix(3).joined(separator: ", "))"),
            "screen \(screenLocked ? "locked" : "unlocked") · this Mac runs away work \(hostAllowed ? "yes" : "only in a VM ([away] host = true)")",
        ]
        let queue = all()
        if queue.isEmpty { lines.append("queue: empty · `away add --do <flow>` or `away add --run \"task\"`") }
        for t in queue.sorted(by: { $0.created < $1.created }).suffix(8) {
            var bits = ["\(t.id) · \(t.kind) \(t.target) · \(t.state.label)"]
            if let note = t.note { bits.append(note) }
            if let note = leftover(t) { bits.append("left: \(note)") }
            lines.append(bits.joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }

    static func list() -> String { status() }

    private static func add(_ a: Args) throws -> String {
        let flows = a.has("do")
        let runs = a.has("run")
        guard flows != runs else { throw Fail(5, "away add: give one of --do <flow> or --run \"task\"") }
        let kind = flows ? "flow" : "run"
        let target = (a.value("do") ?? a.value("run") ?? "").trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { throw Fail(5, "away add: the task is empty") }
        var task = Task(id: String(UUID().uuidString.prefix(4)).lowercased(), kind: kind, target: target,
                        vm: a.value("vm"), host: a.has("host"), state: .queued, created: Date().timeIntervalSince1970)
        if let raw = a.value("at") {
            let date = Schedules.parseDate(raw) ?? ISO8601DateFormatter().date(from: raw)
            guard let date else { throw Fail(5, "away add: --at takes 2026-11-05T09:00:00") }
            task.earliest = date.timeIntervalSince1970
        }
        if let raw = a.value("deadline") {
            let date = Schedules.parseDate(raw) ?? ISO8601DateFormatter().date(from: raw)
            guard let date else { throw Fail(5, "away add: --deadline takes 2026-11-05T09:00:00") }
            task.deadline = date.timeIntervalSince1970
        }
        if task.host == true, !hostAllowed {
            throw Fail(5, "away add: this Mac runs away work only with [away] host = true; give --vm <name> instead")
        }
        if task.vm == nil && task.host != true {
            // A flow may run on this Mac when the config allows it; otherwise it waits for a VM.
            guard hostAllowed else { throw Fail(5, "away add: give --vm <name>, or set [away] host = true to run it on this Mac while you are away") }
            task.host = true
        }
        add(task)
        var out = "away add: \(task.id) · \(kind) \(target) · runs when you are away" + (task.whenLabel.isEmpty ? "" : " (\(task.whenLabel))")
        if !mode { out += "\n`away on` is not set: nothing runs until it is" }
        return out
    }

    private static func cancel(_ a: Args) throws -> String {
        guard let id = a.pos.dropFirst().first ?? a.pos.first, let task = find(id) else { throw Fail(5, "away cancel <id>") }
        update { list in list.removeAll { $0.id == task.id } }
        return "away cancel: \(task.id) · \(task.target) dropped"
    }

    private static func runNow(_ a: Args) throws -> String {
        guard let id = a.pos.dropFirst().first, let task = find(id) else { throw Fail(5, "away run <id>") }
        guard task.state == .queued || task.state == .yielded || task.state == .needsYou else {
            throw Fail(5, "away run: \(task.id) is \(task.state.label)")
        }
        update { list in
            if let i = list.firstIndex(where: { $0.id == task.id }) { list[i].state = .queued }
        }
        start(task)
        return "away run: \(task.id) started"
    }

    /// Blocks until the user is away, then returns: an agent can wait out a visit and carry on.
    private static func wait(_ a: Args) throws -> String {
        let timeout = a.value("timeout").flatMap(Double.init) ?? 3600
        let deadline = Date().addingTimeInterval(timeout)
        let wasMode = mode
        if !wasMode { setMode(true) }
        defer { if !wasMode { setMode(false) } }
        while !isAway() {
            if Date() > deadline {
                throw Fail(5, "away wait: you are still here after \(Int(timeout)) s")
            }
            if KillSwitch.halted { throw Fail(6, "stopped: " + KillSwitch.message) }
            Pace.sleep(0.5)
        }
        return "away: the user is away. Run the task now; a return gives exit 10."
    }

    static let yieldMessage = "yielded: the user is back at the Mac. Nothing was done; do not retry. Wait with `apprentice away wait` and start again when they leave."

    /// Commands that would touch the Mac; in away mode, with the user present, they yield at once instead of
    /// waiting thirty seconds for the person to go still (`waitIdle`).
    static let acting: Set<String> = ["session", "focus", "open", "click", "type", "key", "menu", "scroll", "hover",
                                      "browse", "drag", "upload", "download", "choose", "do", "replay"]
}
