import Foundation

/// Prompts and tasks that run later or again: `claude -p "…"`, `apprentice run "…"`, a flow, or a shell
/// command. One entry per schedule in `~/.apprentice/schedules.toml`, written only under that file's lock
/// (`Limits.update`'s lock, shared by every daemon), so the Mac's daemon and each VM's keep the same list.
///
/// The daemon owns the timer: a minute after it starts and every twenty seconds after, it looks for a
/// schedule that is due and runs it as a command (`apprentice run`, `do`, or the agent CLI), so a scheduled
/// run takes exactly the path a person or an agent takes: budgets, cooldowns, quiet hours and the gate all
/// still apply, and an approval nobody is there to give waits or goes to the phone (`away on`).
enum Schedules {
    enum Kind: String, CaseIterable {
        case prompt, run, flow, sh, pipeline

        var label: String {
            switch self {
            case .prompt: return "prompt for an agent CLI"
            case .run: return "apprentice run"
            case .flow: return "playbook flow"
            case .sh: return "shell command"
            case .pipeline: return "pipeline"
            }
        }
    }

    struct Schedule {
        var id: String
        var name: String
        var kind: Kind
        /// The prompt, the task, the flow's name, or the shell command.
        var target: String
        /// `prompt` only: the CLI to run it in (claude, codex, opencode…), and a preset name is allowed.
        var agent: String?
        var at: Date?
        var every: Int?
        var daily: String?
        var weekly: String?
        var cron: String?
        /// ± minutes, drawn through `Rand`, so a daily post never lands at 09:00:00 every day.
        var jitter = 15
        /// The site whose quiet hours apply; empty uses `[pace.default]`.
        var site: String?
        var dir: String?
        var vm: String?
        var model: String?
        var enabled = true
        var lastRun: Date?
        var lastResult: String?
        var next: Date?
        /// The plain time `next` was drawn from, before jitter: the run after it is computed from here, so a
        /// run jittered early never lands on the same base again.
        var base: Date?
        var created = Date()

        var where_: String { dir ?? FileManager.default.currentDirectoryPath }
        var when_: String {
            if let at { return "once at \(Schedules.stamp(at))" }
            if let every { return "every \(every) min" }
            if let daily { return "daily at \(daily)" }
            if let weekly { return weekly }
            if let cron { return "cron \(cron)" }
            return "unscheduled"
        }
    }

    // MARK: - storage

    static var path: URL { Store.dir.appendingPathComponent("schedules.toml") }
    static var runsDir: URL { Store.dir.appendingPathComponent("schedules") }

    static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    static func stamp(_ d: Date) -> String { dateFormat.string(from: d) }
    static func parseDate(_ s: String?) -> Date? { s.flatMap(dateFormat.date(from:)) }

    /// Every schedule, in the order they were added.
    static func all() -> [Schedule] {
        let toml = Toml.load(path)
        var out: [Schedule] = []
        for (section, values) in toml where section.hasPrefix("schedule.") {
            let id = String(section.dropFirst("schedule.".count))
            guard let s = parse(id, values) else { continue }
            out.append(s)
        }
        return out.sorted { $0.created < $1.created }
    }

    private static func parse(_ id: String, _ v: [String: String]) -> Schedule? {
        func text(_ key: String) -> String? {
            guard let raw = v[key] else { return nil }
            let t = Toml.unquote(raw)
            return t.isEmpty ? nil : t
        }
        func number(_ key: String) -> Int? { v[key].flatMap { Int(Toml.unquote($0)) } }
        guard let kind = text("kind").flatMap(Kind.init(rawValue:)) else { return nil }
        var s = Schedule(id: id, name: text("name") ?? id, kind: kind, target: text("target") ?? "")
        s.agent = text("agent")
        s.at = parseDate(text("at"))
        s.every = number("every")
        s.daily = text("daily")
        s.weekly = text("weekly")
        s.cron = text("cron")
        s.jitter = number("jitter") ?? 15
        s.site = text("site")
        s.dir = text("dir")
        s.vm = text("vm")
        s.model = text("model")
        s.enabled = (v["enabled"].map(Toml.unquote) ?? "true") != "false"
        s.lastRun = parseDate(text("last_run"))
        s.lastResult = text("last_result")
        s.next = parseDate(text("next"))
        s.base = parseDate(text("base"))
        s.created = parseDate(text("created")) ?? Date.distantPast
        return s
    }

    /// One quoted TOML string, so a prompt with quotes or a # in it still reads back whole.
    private static func q(_ s: String) -> String {
        let backslash = String(UnicodeScalar(92)!)
        let quote = String(UnicodeScalar(34)!)
        let escaped = s.replacingOccurrences(of: backslash, with: backslash + backslash)
            .replacingOccurrences(of: quote, with: backslash + quote)
        return quote + escaped + quote
    }

    static func render(_ list: [Schedule]) -> String {
        var out = [
            "# Schedules: prompts and tasks apprentice runs later or again.",
            "# `apprentice schedule add …` writes here; every daemon re-reads it. A schedule added by an agent",
            "# is a step only the user approves ([gate] user_only). Times are this Mac's local time.",
            "",
        ]
        for s in list {
            out.append("[schedule.\(q(s.id))]")
            out.append("name = \(q(s.name))")
            out.append("kind = \(q(s.kind.rawValue))")
            out.append("target = \(q(s.target))")
            if let agent = s.agent { out.append("agent = \(q(agent))") }
            if let at = s.at { out.append("at = \(q(stamp(at)))") }
            if let every = s.every { out.append("every = \(every)") }
            if let daily = s.daily { out.append("daily = \(q(daily))") }
            if let weekly = s.weekly { out.append("weekly = \(q(weekly))") }
            if let cron = s.cron { out.append("cron = \(q(cron))") }
            out.append("jitter = \(s.jitter)")
            if let site = s.site { out.append("site = \(q(site))") }
            if let dir = s.dir { out.append("dir = \(q(dir))") }
            if let vm = s.vm { out.append("vm = \(q(vm))") }
            if let model = s.model { out.append("model = \(q(model))") }
            out.append("enabled = \(s.enabled ? "true" : "false")")
            if let last = s.lastRun { out.append("last_run = \(q(stamp(last)))") }
            if let result = s.lastResult { out.append("last_result = \(q(result))") }
            if let next = s.next { out.append("next = \(q(stamp(next)))") }
            if let base = s.base { out.append("base = \(q(stamp(base)))") }
            out.append("created = \(q(stamp(s.created)))")
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    static func save(_ list: [Schedule]) {
        try? FileManager.default.createDirectory(at: Store.dir, withIntermediateDirectories: true)
        try? render(list).write(to: path, atomically: true, encoding: .utf8)
    }

    /// Reads, changes and writes under the lock every daemon respects.
    @discardableResult
    static func update<T>(_ body: (inout [Schedule]) throws -> T) rethrows -> T {
        try Store.locked(at: path) {
            var list = all()
            let result = try body(&list)
            save(list)
            return result
        }
    }

    static func find(_ id: String) -> Schedule? { all().first { $0.id == id } }

    // MARK: - when

    private static let days: [String: Int] = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]

    /// `09:30` as minutes after midnight, or nil.
    static func timeOfDay(_ s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    /// The next occurrence of `minutes` after midnight on or after `from`.
    private static func nextClock(_ clock: Int, after from: Date) -> Date {
        let cal = Calendar.current
        var day = cal.startOfDay(for: from)
        for _ in 0..<3 {
            if let at = clockTime(clock, on: day, cal), at > from { return at }
            day = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        }
        return day
    }

    /// The wall-clock time on `day`, so 09:00 stays 09:00 on the day the clocks change.
    private static func clockTime(_ clock: Int, on day: Date, _ cal: Calendar) -> Date? {
        cal.date(bySettingHour: clock / 60, minute: clock % 60, second: 0, of: day)
    }

    /// `mon,wed` as weekday numbers (Sunday 1), or nil when any name is not a day.
    static func weekdays(_ list: Substring) -> Set<Int>? {
        let names = list.split(separator: ",").map { String($0).lowercased() }
        let wanted = names.compactMap { days[String($0.prefix(3))] }
        return wanted.isEmpty || wanted.count != names.count ? nil : Set(wanted)
    }

    /// The plain next time the schedule says, before jitter and quiet hours.
    static func baseNext(_ s: Schedule, after from: Date, created: Date? = nil) -> Date? {
        if let at = s.at { return at > from ? at : nil }
        if let every = s.every, every > 0 {
            // Anchored on the last run, or on when it was made, so it keeps its rhythm across restarts.
            let anchor = s.lastRun ?? created ?? s.created
            if anchor > from { return anchor }
            let step = Double(every) * 60
            let gap = from.timeIntervalSince(anchor)
            let n = (gap / step).rounded(.down) + 1
            return anchor.addingTimeInterval(n * step)
        }
        if let daily = s.daily, let clock = timeOfDay(daily) {
            return nextClock(clock, after: from)
        }
        if let weekly = s.weekly {
            let parts = weekly.split(separator: " ")
            guard parts.count == 2, let clock = timeOfDay(String(parts[1])) else { return nil }
            guard let wanted = weekdays(parts[0]) else { return nil }
            let cal = Calendar.current
            var day = cal.startOfDay(for: from)
            for _ in 0..<8 {
                if wanted.contains(cal.component(.weekday, from: day)),
                   let at = clockTime(clock, on: day, cal), at > from {
                    return at
                }
                day = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            }
            return nil
        }
        if let cron = s.cron { return nextCron(cron, after: from) }
        return nil
    }

    /// ± `jitter` minutes, drawn through `Rand`, so a daily post never lands at the same second.
    static func jittered(_ base: Date, _ jitter: Int, draw: () -> Double = { Rand.unit() }) -> Date {
        guard jitter > 0 else { return base }
        let spread = Double(jitter) * 60
        return base.addingTimeInterval((draw() * 2 - 1) * spread)
    }

    /// Quiet hours for the schedule's site (`[pace."<site>"]`, else `[pace.default]`). A run that would
    /// start inside them moves to their end, as a person's day would (`BOT_DETECTION` S4).
    static func quietHours(_ s: Schedule) -> (from: Double, to: Double) {
        guard let site = s.site, let p = Config.current.profiles[site.lowercased()] else {
            return (Config.current.defaultPace.quietFrom, Config.current.defaultPace.quietTo)
        }
        return (p.quietFrom, p.quietTo)
    }

    /// Moves `at` past quiet hours when it falls inside them.
    static func outOfQuietHours(_ at: Date, _ hours: (from: Double, to: Double)) -> Date {
        guard hours.from >= 0 else { return at }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: at)
        let local = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
        let inside = hours.from < hours.to ? local >= hours.from && local < hours.to : local >= hours.from || local < hours.to
        guard inside else { return at }
        let cal = Calendar.current
        let day = cal.startOfDay(for: at)
        // The end of the range: later today for a range that wraps (22–6), or tomorrow for 2–6 after 2.
        let toMinutes = Int((hours.to * 60).rounded())
        var end = cal.date(bySettingHour: toMinutes / 60 % 24, minute: toMinutes % 60, second: 0, of: day) ?? at
        if end <= at { end = cal.date(byAdding: .day, value: 1, to: end) ?? end.addingTimeInterval(86_400) }
        return end
    }

    /// The time the schedule will actually fire, jitter and quiet hours included.
    static func fireTime(_ s: Schedule, after from: Date, draw: () -> Double = { Rand.unit() }) -> (base: Date, at: Date)? {
        guard s.enabled, let base = baseNext(s, after: from) else { return nil }
        // Jitter never reaches past half an `every` gap, and never before `from`: no back-to-back runs.
        let jitter = s.every.map { min(s.jitter, max($0 / 2, 0)) } ?? s.jitter
        let at = outOfQuietHours(max(jittered(base, jitter, draw: draw), from.addingTimeInterval(60)), quietHours(s))
        return (base, at)
    }

    /// `--at`, `--every`, `--daily`, `--weekly` and `--cron` are one schedule; a due run missed by less
    /// than `catch_up_min` runs once, older ones are skipped and logged, never a burst of catch-ups.
    static func catchUp(due: Date, now: Date, minutes: Int) -> Bool {
        now.timeIntervalSince(due) <= Double(max(minutes, 0)) * 60
    }

    static var catchUpMinutes: Int {
        Int(Toml.unquote(Toml.load(Config.path)["schedules"]?["catch_up_min"] ?? "60")) ?? 60
    }

    /// The next five runs, jitter and quiet hours applied, for the detail pane and `show`.
    static func preview(_ s: Schedule, count: Int = 5) -> [Date] {
        var out: [Date] = []
        var from = Date()
        // The first is the time the timer will really use, not a fresh draw.
        if let next = s.next, let base = s.base, next > from {
            out.append(next)
            from = max(next, base)
        }
        while out.count < count {
            guard var next = fireTime(s, after: from)?.at else { break }
            // A quiet shift can land a run before the base it came from; keep going forward regardless.
            if next <= from { next = from.addingTimeInterval(60) }
            out.append(next)
            from = next
        }
        return out
    }

    // MARK: - cron

    /// One cron field as a set of numbers: `*`, `*/5`, `1,3,5`, `2-6`, `1-20/2`.
    static func cronField(_ field: String, _ low: Int, _ high: Int, names: [String] = []) -> Set<Int>? {
        var field = field.lowercased()
        // `mon`, `jan`: names stand for their number (`names[0]` is `low`).
        for (i, name) in names.enumerated() { field = field.replacingOccurrences(of: name, with: String(low + i)) }
        var out = Set<Int>()
        for part in field.split(separator: ",") {
            var step = 1
            var range = String(part)
            if let slash = part.firstIndex(of: "/") {
                range = String(part[..<slash])
                guard let n = Int(part[part.index(after: slash)...]), n > 0 else { return nil }
                step = n
            }
            var from = low, to = high
            if range != "*" {
                let ends = range.split(separator: "-")
                guard let first = ends.first, let a = Int(first), a >= low, a <= high else { return nil }
                from = a
                to = ends.count > 1 ? (Int(ends[1]) ?? -1) : (step > 1 ? high : a)
                guard to >= low, to <= high, to >= from else { return nil }
            }
            var v = from
            while v <= to { out.insert(v); v += step }
        }
        return out.isEmpty ? nil : out
    }

    /// A five-field cron line (minute hour day-of-month month day-of-week). Day-of-week 0 and 7 are Sunday.
    static func nextCron(_ expr: String, after from: Date) -> Date? {
        let fields = expr.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count == 5,
              let minutes = cronField(fields[0], 0, 59),
              let hours = cronField(fields[1], 0, 23),
              let daysOfMonth = cronField(fields[2], 1, 31),
              let months = cronField(fields[3], 1, 12, names: ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]) else { return nil }
        var weekdays = cronField(fields[4], 0, 7, names: ["sun", "mon", "tue", "wed", "thu", "fri", "sat"])
        if weekdays?.contains(7) == true { weekdays?.insert(0); weekdays?.remove(7) }
        guard let weekdaySet = weekdays else { return nil }
        let cal = Calendar.current
        var day = cal.startOfDay(for: from)
        // Eight years ahead, so a yearly line or the 29th of February still has a next time.
        let domAny = fields[2].hasPrefix("*"), dowAny = fields[4].hasPrefix("*")
        for _ in 0..<(366 * 8) {
            let comps = cal.dateComponents([.month, .day, .weekday], from: day)
            let domMatches = daysOfMonth.contains(comps.day ?? 0)
            let dowMatches = weekdaySet.contains((comps.weekday ?? 1) - 1)
            // Cron's rule: when both day fields are restricted (neither starts with `*`), either may match.
            let dayOK = !domAny && !dowAny ? (domMatches || dowMatches) : (domMatches && dowMatches)
            if months.contains(comps.month ?? 0), dayOK {
                for h in hours.sorted() {
                    for m in minutes.sorted() {
                        if let at = cal.date(bySettingHour: h, minute: m, second: 0, of: day), at > from { return at }
                    }
                }
            }
            day = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        }
        return nil
    }

    // MARK: - running

    private static let runLock = NSLock()
    private static var running = Set<String>()
    private static var timer: DispatchSourceTimer?

    static func isRunning(_ id: String) -> Bool {
        runLock.lock()
        defer { runLock.unlock() }
        return running.contains(id)
    }

    /// The daemon's timer: twenty seconds, off the command queue, so a schedule fires without anyone
    /// running a command first.
    static func install() {
        guard timer == nil, Store.vmName == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "apprentice.schedules"))
        t.schedule(deadline: .now() + 20, repeating: 20)
        t.setEventHandler { tick() }
        t.resume()
        timer = t
    }

    static func uninstall() {
        timer?.cancel()
        timer = nil
    }

    /// Fires every schedule whose time has come. `now` is injectable for the self-test.
    static func tick(now: Date = Date()) {
        guard Config.current.schedulesOn else { return }
        for s in all() where s.enabled {
            let due = s.next ?? fireTime(s, after: s.lastRun ?? now)?.at
            guard let due else { continue }
            if due > now {
                // A freshly parsed schedule has no stored next time yet: keep it, for the UI to show.
                if s.next == nil { update { list in
                    if let i = list.firstIndex(where: { $0.id == s.id }) { list[i].next = due; list[i].base = list[i].base ?? baseNext(s, after: now) }
                } }
                continue
            }
            if isRunning(s.id) {
                Store.log(["cmd": "schedule", "schedule": s.id, "skipped": "still running"])
                advance(s)
                continue
            }
            // The screen is another agent's right now: wait for it (the next tick looks again), up to the catch-up time.
            if Device.busy(vm: s.vm, for: "schedule:\(s.id)") != nil, catchUp(due: due, now: now, minutes: catchUpMinutes) { continue }
            guard catchUp(due: due, now: now, minutes: catchUpMinutes) else {
                Store.log(["cmd": "schedule", "schedule": s.id, "skipped": "missed while the Mac was asleep or off"])
                advance(s)
                continue
            }
            fire(s)
        }
    }

    /// Moves the schedule's next time on after a run (or a skip), so an `every` schedule keeps its rhythm.
    /// `fired` is set when the stored next time was used (run or skipped): a once schedule is done, and
    /// the next time is drawn after that run's base, never the same base again.
    static func advance(_ s: Schedule, now: Date = Date(), result: String? = nil, fired: Bool = true) {
        update { list in
            guard let i = list.firstIndex(where: { $0.id == s.id }) else { return }
            if result != nil { list[i].lastRun = now; list[i].lastResult = result }
            guard fired else { return }
            if list[i].at != nil { list[i].enabled = false }
            let from = max(now, list[i].base ?? now)
            let next = fireTime(list[i], after: from)
            list[i].next = next?.at
            list[i].base = next?.base
        }
    }

    /// Runs one schedule now, whatever its time. Overlap is skipped: two of the same never run at once.
    static func fire(_ s: Schedule, manual: Bool = false) {
        runLock.lock()
        if running.contains(s.id) {
            runLock.unlock()
            Store.log(["cmd": "schedule", "schedule": s.id, "skipped": "still running"])
            return
        }
        running.insert(s.id)
        runLock.unlock()
        // A manual run leaves the timer's next time alone.
        if !manual { advance(s) }
        Store.log(["cmd": "schedule", "schedule": s.id, "kind": s.kind.rawValue, "started": true])
        DispatchQueue.global(qos: .utility).async {
            let outcome = run(s)
            runLock.lock()
            running.remove(s.id)
            runLock.unlock()
            advance(s, result: outcome, fired: false)
            Store.log(["cmd": "schedule", "schedule": s.id, "result": outcome])
            if outcome != "ok" { Notify.local("schedule \(s.name): \(outcome)", title: "apprentice schedule") }
        }
    }

    /// Where a schedule's run is written: `~/.apprentice/schedules/<id>/<stamp>.log`.
    static func logFile(_ s: Schedule) -> URL {
        let folder = runsDir.appendingPathComponent(s.id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(stamp(Date()).replacingOccurrences(of: ":", with: "") + ".log")
    }

    static func runs(_ id: String) -> [(name: String, url: URL)] {
        let folder = runsDir.appendingPathComponent(id)
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items.filter { $0.pathExtension == "log" }
            .sorted { a, b in
                ((try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
                    > ((try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
            }
            .map { ($0.lastPathComponent, $0) }
    }

    /// One prompt for an agent CLI, run to its end without a terminal, as `agent/agents.toml` says.
    static func agentArgv(_ agent: String, _ prompt: String) -> [String] { AgentCLIs.argv(agent, prompt) }

    /// The command line for a run: the agent CLI with the prompt, `apprentice run` / `do`, or the shell.
    static func command(_ s: Schedule) -> [String] {
        let binary = Wire.binaryPath()
        let vm = s.vm.map { ["--vm", $0] } ?? []
        switch s.kind {
        case .prompt:
            return agentArgv(AgentCLIs.runnable(s.agent), s.target)
        case .pipeline:
            return [binary] + vm + ["pipeline", "run", s.target]
        case .run:
            let model = s.model.map { ["--model", $0] } ?? []
            return [binary] + vm + ["run", s.target] + model
        case .flow:
            return [binary] + vm + ["do", s.target]
        case .sh:
            return ["/bin/zsh", "-lc", s.target]
        }
    }

    /// Runs one schedule to its end, keeping its output in the run's log; returns the short result line.
    private static func run(_ s: Schedule) -> String {
        // A shell command is the one kind the UI-only policy refuses, as in a flow.
        if s.kind == .sh, Config.current.uiOnly || (Session.stored?.uiOnly ?? false) {
            return "refused: shells are off under [agent] ui_only"
        }
        let log = logFile(s)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: log) else { return "could not write \(log.path)" }
        defer { try? handle.close() }
        let header = "# \(s.name) · \(s.kind.rawValue) · \(stamp(Date()))\n# \(command(s).joined(separator: " "))\n\n"
        handle.write(Data(header.utf8))

        let proc = Process()
        var argv = command(s)
        // An agent CLI is found on the user's login PATH: a daemon started at login (`schedule agent on`)
        // has only launchd's.
        if s.kind == .prompt { argv = ["/bin/zsh", "-lc", "exec \"$@\"", "zsh"] + argv }
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = argv
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        env["APPRENTICE_SCHEDULE"] = s.id
        env["APPRENTICE_TAB"] = "schedule:\(s.id)"
        if let dir = s.dir { env["APPRENTICE_PROJECT"] = Project.find(from: dir)?.path ?? ""; proc.currentDirectoryURL = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath) }
        if let vm = s.vm { env["APPRENTICE_VM"] = vm }
        if let model = s.model { env["APPRENTICE_MODEL"] = model }
        proc.environment = env
        proc.standardOutput = handle
        proc.standardError = handle
        // The agent CLI and `apprentice` both expect a terminal; a pipe is enough for -p/exec, and
        // `apprentice` itself only writes text. Nothing here borrows the cursor.
        proc.standardInput = FileHandle.nullDevice
        let started = Date()
        do {
            try proc.run()
        } catch {
            return "could not start: \(error.localizedDescription)"
        }
        proc.waitUntilExit()
        let seconds = Int(Date().timeIntervalSince(started))
        switch proc.terminationStatus {
        case 0: return "ok · \(seconds) s"
        case 8: return "needs approval · \(seconds) s"
        case 9: return "asked in the chat (the user is away) · \(seconds) s"
        case 10: return "yielded: the user came back · \(seconds) s"
        case 4: return "refused by a budget, cooldown or the site's rules · \(seconds) s"
        default: return "exit \(proc.terminationStatus) · \(seconds) s"
        }
    }

    // MARK: - LaunchAgent

    static var agentPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.apprentice.serve.plist")
    }

    static var agentInstalled: Bool { FileManager.default.fileExists(atPath: agentPath.path) }

    /// Starts `apprentice serve` at login, so schedules fire without anyone running a command first.
    @discardableResult
    static func installAgent() -> String {
        guard Store.vmName == nil else { return "schedule agent: the Mac's daemon starts this, not a VM's" }
        let bin = Wire.binaryPath()
        let plist: [String: Any] = [
            "Label": "com.apprentice.serve",
            "ProgramArguments": [bin, "serve", "--background"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "StandardOutPath": Store.stateDir.appendingPathComponent("daemon.err").path,
            "StandardErrorPath": Store.stateDir.appendingPathComponent("daemon.err").path,
            "ProcessType": "Background",
        ]
        do {
            try FileManager.default.createDirectory(at: agentPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentPath)
        } catch {
            return "schedule agent: could not write \(agentPath.path): \(error.localizedDescription)"
        }
        _ = Repo.run("launchctl", ["bootstrap", "gui/\(getuid())", agentPath.path])
        return "schedule agent: on · apprentice starts at login (\(agentPath.path))"
    }

    @discardableResult
    static func removeAgent() -> String {
        guard agentInstalled else { return "schedule agent: off" }
        _ = Repo.run("launchctl", ["bootout", "gui/\(getuid())/com.apprentice.serve"])
        try? FileManager.default.removeItem(at: agentPath)
        return "schedule agent: off · apprentice no longer starts at login"
    }

    // MARK: - CLI

    static let usage = "schedule add <name> (--at|<date>|--every <min>|--daily <HH:MM>|--weekly \"mon,wed 09:00\"|--cron \"m h dom mon dow\") (--prompt \"…\" [--agent claude] | --run \"…\" | --do <flow> | --sh \"…\" | --pipeline <name>) [--project <name>] [--dir] [--vm] [--model] [--jitter min] [--site] · list | show <id> | pause <id> | resume <id> | rm <id> | now <id> | agent on|off"

    static func command(_ a: Args) throws -> String {
        // An MCP client or an older caller names the schedule with --id; the subcommands take it as a word.
        var a = a
        if let id = a.value("id"), a.pos.count == 1, ["show", "pause", "resume", "rm", "now"].contains(a.pos[0]) { a.pos.append(id) }
        switch a.pos.first ?? "list" {
        case "add", "set": return try add(a)
        case "list": return list()
        case "show": return try show(a)
        case "pause", "resume":
            let s = try findOrThrow(a.pos.dropFirst().first)
            try userOnly("\(a.pos[0]) schedule \(s.id) · \(s.name)", ["runs \(s.kind.label): \(s.target)", "when: \(s.when_)"])
            return try toggle(a, on: a.pos.first == "resume")
        case "rm":
            let s = try findOrThrow(a.pos.dropFirst().first)
            try userOnly("remove schedule \(s.id) · \(s.name)", ["runs \(s.kind.label): \(s.target)"])
            return try remove(a)
        case "now":
            let s = try findOrThrow(a.pos.dropFirst().first)
            try userOnly("run schedule \(s.id) · \(s.name) now", ["runs \(s.kind.label): \(s.target)"])
            return try now(a)
        case "agent":
            let off = a.pos.dropFirst().first == "off"
            try userOnly(off ? "stop starting apprentice at login" : "start apprentice at login (a LaunchAgent)",
                         [off ? "removes \(agentPath.path)" : "writes \(agentPath.path)"])
            return off ? removeAgent() : installAgent()
        default: throw Fail(5, usage)
        }
    }

    /// Anything that changes what runs later without the user: only the user approves it (the `confirm`
    /// window, the menu bar or the app), as `[gate] user_only` works. Every caller is gated, a person at a
    /// terminal included: a missing model name never stands for the user.
    static func userOnly(_ summary: String, _ details: [String]) throws {
        if Approvals.fromUser { return }
        try Approvals.check(summary, details: details, warnings: [Gate.userOnlyStep])
    }

    private static func describe(_ s: Schedule) -> String {
        var bits = ["\(s.id) · \(s.name) · \(s.kind.rawValue)"]
        bits.append(s.when_)
        if s.jitter > 0 { bits.append("±\(s.jitter) min") }
        if s.vm != nil { bits.append("VM \(s.vm!)") }
        bits.append(s.enabled ? "on" : "paused")
        if let next = s.next, s.enabled { bits.append("next \(stamp(next))") }
        if let last = s.lastResult { bits.append("last: \(last)") }
        return bits.joined(separator: " · ")
    }

    static func list() -> String {
        let all = all()
        guard !all.isEmpty else { return "no schedules · \(usage)" }
        return (["schedules · \(path.path)"] + all.map { (s: Schedule) in
            let next = s.enabled ? (s.next ?? fireTime(s, after: Date())?.at).map(stamp) ?? "-" : "paused"
            return "\(s.id) · \(s.name) · \(s.kind.rawValue) · \(s.when_) · next \(next)" + (s.lastResult.map { " · last \($0)" } ?? "")
        }).joined(separator: "\n")
    }

    private static func show(_ a: Args) throws -> String {
        guard let id = a.pos.dropFirst().first ?? a.pos.first, let s = find(id) else { throw Fail(5, "schedule show <id>") }
        var out = [describe(s)]
        out.append("  runs: \(s.kind.label): \(s.target)")
        if let dir = s.dir { out.append("  in: \(dir)") }
        if let next = s.next { out.append("  next: \(stamp(next))") }
        out.append("  next 5 runs:")
        out.append(contentsOf: preview(s).map { "    \(stamp($0))" })
        for (name, _) in runs(s.id).prefix(5) { out.append("  run: \(name)") }
        return out.joined(separator: "\n")
    }

    private static func findOrThrow(_ id: String?) throws -> Schedule {
        guard let id, let s = find(id) else { throw Fail(5, "no schedule \(id ?? "") · apprentice schedule list") }
        return s
    }

    private static func toggle(_ a: Args, on: Bool) throws -> String {
        let s = try findOrThrow(a.pos.dropFirst().first)
        return update { list -> String in
            guard let i = list.firstIndex(where: { $0.id == s.id }) else { return "gone" }
            list[i].enabled = on
            list[i].next = on ? fireTime(list[i], after: Date())?.at : nil
            return "\(s.id) · \(s.name) · " + (on ? "resumed · next \(list[i].next.map(stamp) ?? "-")" : "paused")
        }
    }

    private static func remove(_ a: Args) throws -> String {
        let s = try findOrThrow(a.pos.dropFirst().first)
        update { list in list.removeAll { $0.id == s.id } }
        let left = all().count
        var out = "removed \(s.id) · \(s.name)"
        if left == 0 { out += "\nno schedules left; `apprentice schedule agent off` stops starting the daemon at login" }
        return out
    }

    private static func now(_ a: Args) throws -> String {
        let s = try findOrThrow(a.pos.dropFirst().first)
        fire(s, manual: true)
        return "\(s.id) · \(s.name): started; its output goes to \(logFile(s).path)"
    }

    private static func add(_ a: Args) throws -> String {
        let name = a.pos.dropFirst().first ?? a.value("name")
        guard let name, !name.isEmpty else { throw Fail(5, usage) }
        var id = a.value("id") ?? Playbooks.slugify(name)
        if id.isEmpty { id = "schedule" }
        let existing = find(id)

        // Exactly one trigger and one kind, so a schedule can never mean two things.
        let triggers = ["at", "every", "daily", "weekly", "cron"].filter { a.has($0) }
        guard triggers.count == 1, let trigger = triggers.first else {
            throw Fail(6, "schedule add: give one of --at, --every, --daily, --weekly or --cron")
        }
        let kinds = ["prompt", "run", "do", "sh", "pipeline"].filter { a.has($0) }
        guard kinds.count == 1, let kindFlag = kinds.first else {
            throw Fail(6, "schedule add: give one of --prompt, --run, --do, --sh or --pipeline")
        }
        let kind: Kind = kindFlag == "prompt" ? .prompt : kindFlag == "run" ? .run : kindFlag == "do" ? .flow
            : kindFlag == "pipeline" ? .pipeline : .sh
        var target = a.value(kindFlag) ?? ""
        guard !target.isEmpty else { throw Fail(6, "schedule add: \(kindFlag) needs a value") }
        // `--project` runs it in that project: its folder, its VM, and a pipeline name read as one of its own.
        var project: Projects.Info?
        if let named = a.value("project") {
            guard let p = Projects.find(named) else { throw Fail(5, "schedule add: no project \(named) · apprentice project list") }
            project = p
            if kind == .pipeline, !target.contains("/") { target = Projects.folderName(p.name) + "/" + target }
        }
        if kind == .pipeline { _ = try Pipelines.find(target) }

        var s = Schedule(id: id, name: name, kind: kind, target: target)
        if let old = existing { s = old; s.name = name; s.kind = kind; s.target = target }
        switch trigger {
        case "at":
            guard let raw = a.value("at"), let at = parseDate(raw) ?? ISO8601DateFormatter().date(from: raw) else {
                throw Fail(6, "schedule add: --at takes 2026-11-05T09:00:00")
            }
            guard at > Date() else { throw Fail(6, "schedule add: --at \(raw) has already passed") }
            (s.at, s.every, s.daily, s.weekly, s.cron) = (at, nil, nil, nil, nil)
        case "every":
            guard let n = a.value("every").flatMap(Int.init), n >= 1 else { throw Fail(6, "schedule add: --every takes minutes, 1 or more") }
            (s.at, s.every, s.daily, s.weekly, s.cron) = (nil, n, nil, nil, nil)
        case "daily":
            guard let raw = a.value("daily"), timeOfDay(raw) != nil else { throw Fail(6, "schedule add: --daily takes HH:MM") }
            (s.at, s.every, s.daily, s.weekly, s.cron) = (nil, nil, raw, nil, nil)
        case "weekly":
            guard let raw = a.value("weekly"), raw.split(separator: " ").count == 2, weekdays(raw.split(separator: " ")[0]) != nil,
                  timeOfDay(String(raw.split(separator: " ")[1])) != nil else { throw Fail(6, "schedule add: --weekly takes \"mon,wed 09:00\"") }
            (s.at, s.every, s.daily, s.weekly, s.cron) = (nil, nil, nil, raw, nil)
        default:
            guard let raw = a.value("cron"), nextCron(raw, after: Date()) != nil else { throw Fail(6, "schedule add: --cron takes five fields, \"0 9 * * mon\"") }
            (s.at, s.every, s.daily, s.weekly, s.cron) = (nil, nil, nil, nil, raw)
        }
        s.agent = a.value("agent") ?? (kind == .prompt ? existing?.agent : nil)
        s.jitter = max(0, a.int("jitter", existing?.jitter ?? 15))
        s.site = a.value("site") ?? existing?.site
        s.dir = a.value("dir").map { ($0 as NSString).expandingTildeInPath } ?? project?.folder.path ?? existing?.dir
        s.vm = a.value("vm") ?? (kind == .sh ? nil : project?.vm) ?? existing?.vm
        s.model = a.value("model") ?? existing?.model
        if kind == .sh, s.vm != nil { throw Fail(6, "schedule add: --vm does not apply to --sh; the command would run on this Mac") }
        s.enabled = true
        if existing == nil { s.created = Date() }
        let first = fireTime(s, after: Date())
        (s.next, s.base) = (first?.at, first?.base)

        // Only the user approves something that will act again and again without them: an agent's
        // `schedule add` is a ⚠ step it cannot approve itself.
        try userOnly("add schedule \(s.id) · \(s.name)", [
            "runs \(kind.label): \(target)",
            "when: \(s.when_)" + (s.jitter > 0 ? " ±\(s.jitter) min" : ""),
            s.vm.map { "in VM \($0)" } ?? "on this Mac",
        ])

        update { list in
            list.removeAll { $0.id == id }
            list.append(s)
        }
        var out = "added \(describe(s))"
        if let id = s.agent, let note = AgentCLIs.missingNote(id) { out += "\n" + note }
        if !agentInstalled {
            out += "\nschedules fire while the daemon runs. `apprentice schedule agent on` starts it at login, so they run without anything else open"
        }
        return out
    }
}
