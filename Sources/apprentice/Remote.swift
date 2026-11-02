import AppKit
import Foundation

/// The Linux VM's screen, driven from this Mac: its browser or any other Linux app. The guest runs
/// agent/vm/helper.py behind one open ssh connection: it reads the app's accessibility tree and plays
/// input through the X server, in the same labels and commands as a session on this Mac. Everything
/// else stays here, in the same code as a local session: approvals, budgets, cooldowns, pacing, the
/// Bézier paths, diffs and logs. While `active`, `Keys` and `Mouse` send their events to the guest
/// instead of this Mac's input stream, with the same timing, so this Mac's cursor never moves.
enum Remote {
    /// On while a command acts in the VM.
    static var active = false
    /// The guest's cursor, as last moved.
    static var cursor = CGPoint(x: 640, y: 400)
    /// The helper reports the app's accessibility events, so `settled` waits for them instead of polling.
    static var hears = false

    /// Commands that run in the VM once a session lives there.
    static let commands: Set<String> = ["session", "focus", "read", "click", "type", "key", "scroll", "browse", "hover", "open", "menu",
                                        "drag", "upload", "download", "wait-for", "ocr", "shot", "show"]
    /// Commands for a Mac's own file panels, which the VM does not have (`upload` picks files there).
    static let unsupported: Set<String> = ["choose"]

    /// Where a request goes: the VM, or this Mac as before. `--on linux|mac` picks the system; without
    /// it a daemon bound to a VM (`bound`) works only there, and `vm on` sends browsers there. Pure, so
    /// `selftest` checks it.
    static func wants(_ req: Request, on: Bool, bound: Bool = false, vmSession: Bool) -> Bool {
        let a = Args.parse(req.args)
        switch req.cmd {
        case "session", "focus":
            switch a.value("on")?.lowercased() {
            case "linux", "vm": return true
            case "mac", "macos": return false
            default: break
            }
            if bound { return true }
            guard on else { return false }
            // A bare session would bind the user's frontmost app; with the VM on it means the VM's browser.
            if req.cmd == "session" { return a.value("app").map(VM.isBrowser) ?? true }
            return VM.isBrowser(a.pos.first ?? a.value("app") ?? "")
        default:
            return vmSession && (commands.contains(req.cmd) || unsupported.contains(req.cmd))
        }
    }

    /// Runs the request in the VM when it belongs there; nil leaves it to this Mac's commands.
    static func dispatch(_ req: Request) throws -> String? {
        // A named VM's daemon works only in its VM; the main daemon follows `vm on`.
        let bound = Store.vmName != nil
        guard wants(req, on: VM.state.on, bound: bound, vmSession: Session.stored?.vm == true) else {
            if bound, req.cmd == "session" || req.cmd == "focus" {
                throw Fail(4, "blocked: this agent session is bound to the VM \(Store.vmName ?? "") (APPRENTICE_VM). Mac apps run from an agent session without APPRENTICE_VM")
            }
            return nil
        }
        let a = Args.parse(req.args)
        if unsupported.contains(req.cmd) {
            throw Fail(5, "choose is for a Mac's file panels; in the VM, `upload <id> <path>` picks the file in the app's own dialog")
        }
        switch req.cmd {
        case "session", "focus": return try session(a)
        case "read": return try read(a)
        case "click": return try click(a)
        case "type": return try type(a)
        case "key": return try key(a)
        case "scroll": return try scroll(a)
        case "hover": return try hover(a)
        case "browse": return try browse(a)
        case "open": return try open(a)
        case "menu": return try menu(a)
        case "drag": return try drag(a)
        case "upload": return try upload(a)
        case "download": return try download(a)
        case "wait-for": return try waitFor(a)
        case "ocr": return try ocr(a)
        case "shot": return try shot(a)
        case "show": return try show(a)
        default: return nil
        }
    }

    // MARK: - the connection

    private static var proc: Process?
    private static var input: FileHandle?
    private static let lock = NSLock()
    private static var lines: [Data] = []
    private static let arrived = DispatchSemaphore(value: 0)

    static func connect() throws {
        if let proc, proc.isRunning { return }
        disconnect()
        let ip = try VM.address()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = VM.sshArgs(ip) + ["python3 -u /opt/apprentice/helper.py"]
        let inp = Pipe(), out = Pipe()
        p.standardInput = inp
        p.standardOutput = out
        let log = VM.dir.appendingPathComponent("helper.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        p.standardError = (try? FileHandle(forWritingTo: log)) ?? FileHandle.nullDevice
        try p.run()
        proc = p
        input = inp.fileHandleForWriting
        lock.lock()
        lines = []
        lock.unlock()
        // Replies are read on their own thread, so a query can give up on a guest that stopped answering.
        let reader = out.fileHandleForReading
        Thread.detachNewThread {
            var buffer = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer = Data(buffer[(nl + 1)...])
                    lock.lock()
                    lines.append(Data(line))
                    lock.unlock()
                    arrived.signal()
                }
            }
        }
        guard let pong = try? query(["op": "ping"], timeout: 15) else {
            disconnect()
            throw Fail(5, "the VM's helper did not answer: run `apprentice vm install`, or see \(log.path)")
        }
        hears = pong["hears"] as? Bool == true
        if let c = try? query(["op": "cursor"]), let x = c["x"] as? Double, let y = c["y"] as? Double {
            cursor = CGPoint(x: x, y: y)
        }
    }

    static func disconnect() {
        proc?.terminate()
        proc = nil
        input = nil
    }

    /// Input goes out as it happens; the host's own sleeps between events set the pace. Each input op
    /// carries the host time it was meant for (`at`), and the helper plays it at that offset, so ssh
    /// buffering several lines into one read does not play them back to back (BOT_DETECTION V4).
    static let inputOps: Set<String> = ["move", "down", "up", "wheel", "key", "char"]

    static func send(_ op: [String: Any]) {
        var op = op
        if let name = op["op"] as? String, inputOps.contains(name) { op["at"] = ProcessInfo.processInfo.systemUptime }
        guard let input, var data = try? JSONSerialization.data(withJSONObject: op) else { return }
        data.append(0x0A)
        // A dead connection must not take the daemon down: the next query reports it.
        try? input.write(contentsOf: data)
    }

    static func query(_ op: [String: Any], timeout: Double = 10) throws -> [String: Any] {
        guard proc?.isRunning == true else { throw Fail(5, "lost the connection to the VM: check `apprentice vm status`, then retry") }
        lock.lock()
        lines = []
        lock.unlock()
        while arrived.wait(timeout: .now()) == .success {}
        send(op)
        guard arrived.wait(timeout: .now() + timeout) == .success else {
            disconnect()
            throw Fail(5, "the VM stopped answering: check `apprentice vm status`, then retry")
        }
        lock.lock()
        let line = lines.isEmpty ? Data() : lines.removeFirst()
        lock.unlock()
        guard let reply = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            throw Fail(5, "bad reply from the VM: \(String(decoding: line, as: UTF8.self))")
        }
        if let error = reply["error"] as? String { throw Fail(5, "in the VM: \(error)") }
        return reply
    }

    // MARK: - input, called by Keys and Mouse while active

    private static var wheelCarry: Int64 = 0, sideCarry: Int64 = 0

    static func post(_ e: CGEvent) {
        let p = e.location
        switch e.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            move(p)
        case .leftMouseDown, .rightMouseDown:
            if p != cursor { move(p) }
            send(["op": "down", "b": e.type == .leftMouseDown ? 1 : 3])
        case .leftMouseUp, .rightMouseUp:
            send(["op": "up", "b": e.type == .leftMouseUp ? 1 : 3])
        case .scrollWheel:
            // A notch of this Mac's wheel scrolls about half as far as one of the guest's.
            wheelCarry += e.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let ticks = wheelCarry / 2
            wheelCarry -= ticks * 2
            if ticks != 0 { send(["op": "wheel", "n": ticks]) }
            sideCarry += e.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            let side = sideCarry / 2
            sideCarry -= side * 2
            if side != 0 { send(["op": "wheel", "n": side, "sideways": true]) }
        default:
            break
        }
    }

    private static func move(_ p: CGPoint) {
        cursor = p
        send(["op": "move", "x": Double(p.x), "y": Double(p.y)])
    }

    /// cmd is ctrl in the guest, so the shortcuts agents know from the Mac (cmd+a, cmd+l) still work.
    static func press(_ combo: String) throws {
        var mods: [String] = []
        var key: String?
        for part in combo.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command", "ctrl", "control": if !mods.contains("ctrl") { mods.append("ctrl") }
            case "shift": mods.append("shift")
            case "alt", "opt", "option": mods.append("alt")
            case "super", "win", "meta": mods.append("super")
            default: key = part
            }
        }
        guard let key else { throw Fail(5, "no key in \"\(combo)\"") }
        send(["op": "key", "key": key, "mods": mods, "down": true])
        Pace.sleep(Rand.uniform(0.03...0.07))
        send(["op": "key", "key": key, "mods": mods, "down": false])
        Pace.sleep(0.02)
    }

    static func typeChar(_ ch: Character) {
        let c = String(ch)
        send(["op": "char", "c": c, "down": true])
        Pace.sleep(Rand.uniform(0.05...0.11))
        send(["op": "char", "c": c, "down": false])
    }

    /// Acts in the guest. The person on this Mac is never waited for or interrupted by it. The session's
    /// window comes to the front first, as `gate` brings it forward on this Mac.
    static func act<T>(_ body: () throws -> T) throws -> T {
        try connect()
        if (try? query(["op": "raise"].merging(target) { $1 }))?["raised"] as? Bool == true {
            Pace.sleep(Rand.uniform(0.25...0.5))
        }
        // Events from before this action must not count as the screen still changing after it.
        if hears { send(["op": "mark"]) }
        active = true
        defer { active = false }
        return try body()
    }

    /// The app every query reads: the session's, or the one `session` is binding.
    private static var binding: [String: Any]?
    static var target: [String: Any] {
        if let binding { return binding }
        guard let s = Session.stored, s.vm == true else { return [:] }
        return ["app": s.app, "pid": Int(s.pid)]
    }

    // MARK: - reading

    private struct RawElement: Decodable {
        var path: [Int]
        var label: String
        var name: String
        var value: String?
        var frame: [Double]
        var offscreen: Bool
        var kind: String
    }

    private struct RawSnap: Decodable {
        var url: String?
        var title: String
        var scope: String
        var bounds: [Double]
        var elements: [RawElement]
        var busy: Bool?
    }

    /// The bounds of the page in the guest, for scrolling with nothing named.
    static var bounds = CGRect(x: 0, y: 87, width: 1280, height: 713)
    /// Whether the last snapshot caught the page still loading.
    static var loading = false

    static func snapshot(offscreen: Bool = false) throws -> Snapshot {
        try connect()
        let reply = try query(["op": "snap", "offscreen": offscreen].merging(target) { $1 })
        guard let data = try? JSONSerialization.data(withJSONObject: reply),
              let raw = try? JSONDecoder().decode(RawSnap.self, from: data) else {
            throw Fail(5, "bad screen from the VM")
        }
        if raw.bounds.count == 4 { bounds = CGRect(x: raw.bounds[0], y: raw.bounds[1], width: raw.bounds[2], height: raw.bounds[3]) }
        loading = raw.busy == true
        let elements = raw.elements.enumerated().map { n, e in
            Element(id: n + 1, path: e.path, label: e.label, name: e.name, value: e.value, frame: e.frame,
                    offscreen: e.offscreen, gated: e.kind == "control" && Gate.matches(e.name))
        }
        return Snapshot(snap: SnapStore.next(), scope: raw.scope, url: raw.url, title: raw.title,
                        total: elements.count, elements: elements)
    }

    /// Waits for the page to stop changing, as `settle` does for a window on this Mac. A page that is
    /// loading, or still shows exactly what it showed before the action, is given time to arrive: a
    /// link or return starts a new page a moment after the input.
    static func settled(after old: Snapshot?, grace: Double = 0.6, maxWait: Double = 8) throws -> Snapshot {
        let start = Date()
        let shape = { (s: Snapshot) in s.elements.map { $0.key + "|" + ($0.value ?? "") } }
        let before = old.map(shape)
        // The app says when it has gone quiet, so one read is usually enough. A page still loading,
        // still showing what it showed before within `grace`, or that never goes quiet, falls through
        // to polling.
        if hears {
            var first = grace, fresh = false
            while Date().timeIntervalSince(start) < maxWait {
                let left = maxWait - Date().timeIntervalSince(start)
                let r = try query(["op": "quiet", "first": first, "quiet": 0.25, "max": min(2, left), "fresh": fresh], timeout: left + 5)
                fresh = true
                guard r["error"] == nil, r["quiet"] as? Bool == true else { break }
                let next = try snapshot()
                let waited = Date().timeIntervalSince(start)
                if loading || next.elements.isEmpty { first = 0.3; continue }
                if shape(next) == before, (r["events"] as? Int ?? 0) > 0, waited < grace {
                    first = grace - waited
                    continue
                }
                return next
            }
        }
        Pace.sleep(0.1)
        var last = try snapshot()
        var waitedForChange = 0.0
        while Date().timeIntervalSince(start) < maxWait {
            Pace.sleep(0.15)
            let next = try snapshot()
            let stable = shape(next) == shape(last)
            if stable, !loading, !next.elements.isEmpty {
                // Nothing new yet: allow a short while for a navigation to begin.
                if shape(next) == before, waitedForChange < grace {
                    waitedForChange += 0.15
                } else {
                    return next
                }
            }
            last = next
        }
        return last
    }

    /// Finds a listed element again, as `resolve` does: at the same place in the tree, or the one
    /// element left with the same label and name.
    static func resolve(_ id: Int) throws -> Element {
        guard let snap = SnapStore.current else { throw Fail(2, "stale: no snapshot, run `apprentice read`") }
        guard let e = snap.elements.first(where: { $0.id == id }) else { throw Fail(5, "no element \(id) in snap \(snap.snap)") }
        let fresh = try snapshot(offscreen: true).elements
        if var same = fresh.first(where: { $0.path == e.path && $0.key == e.key }) ?? {
            let matches = fresh.filter { $0.key == e.key }
            return matches.count == 1 ? matches[0] : nil
        }() {
            same.id = e.id
            // As on the Mac: an element now wholly out of view is never clicked at a point outside it.
            if same.offscreen { throw Fail(2, "stale: element \(e.short) is out of view now: scroll it into view, then retry") }
            return same
        }
        throw Fail(2, "stale: element \(e.short) changed, re-read")
    }

    // MARK: - commands

    static func prepare(checkAllow: Bool = true) throws -> (Session, Page, Snapshot?) {
        guard var session = Session.stored, session.vm == true else { throw Fail(5, "no session: run `apprentice session`") }
        Config.activate(Config.profileKey(session: session, url: session.url))
        let now = try snapshot()
        let page = Page(url: now.url, title: now.title, scope: now.scope)
        if let was = session.url, let url = now.url, !samePage(was, url) {
            // As on the Mac: reading takes the new page in, an action is refused until the caller has read it.
            guard Commands.reads.contains(Approvals.request.cmd) else {
                throw Fail(2, "stale: the page changed to \(url) without apprentice. The user may be using the VM. Nothing was done: `read` the page and decide again")
            }
            Commands.notice = "note: the page changed to \(url) without apprentice. The user may be using the VM; check before acting."
        }
        session.track(now.url)
        Config.activate(Config.profileKey(session: session, url: now.url))
        try keepLocal(now.url)
        if checkAllow { try allowCheck(session, now.url) }
        try Site.guardPage(page, cmd: Approvals.request.cmd) { (try? snapshot()) ?? now }
        return (session, page, SnapStore.current)
    }

    static func gate(_ session: Session, _ page: Page, _ e: Element?, _ summary: String,
                             details: [String] = [], warn: [String] = [], force: Bool = false) throws {
        let kind = try approveStep(session, page, e, summary, details: details, warn: warn, force: force)
        // The dwell before a budgeted action drifts the guest's cursor, not this Mac's.
        if kind != nil { try act { Site.dwell() } }
    }

    /// `navigates`: a link, return or address that should bring a new page, which a slow site may
    /// start seconds later.
    static func done(_ command: String, _ session: Session, _ page: Page, _ old: Snapshot?, navigates: Bool = false,
                             extra: [String] = [], log: [String: Any] = [:]) throws -> String {
        let web = Session.stored?.isBrowser ?? true
        if let plan = Fidget.plan(after: command, web: web) { _ = try? act { Fidget.perform(plan, in: bounds, web: web) } }
        let new = try Timing.measure("settle") { try settled(after: old, grace: navigates ? 3 : 0.6) }
        do {
            return try finish(command, session, url: page.url, old, new, extra: extra, log: log.merging(["vm": true]) { $1 })
        } catch let fail as Fail where fail.code == 4 && fail.message.contains("challenge") {
            throw Fail(4, fail.message + "\nthe user does this in the VM: `apprentice vm call \"pass the check on the page\"` opens it for them")
        }
    }

    static func session(_ a: Args) throws -> String {
        try connect()
        let focusing = Approvals.request.cmd == "focus"
        let wanted = (focusing ? a.pos.first : nil) ?? a.value("app")
        if let wanted, !VM.isBrowser(wanted) { return try appSession(wanted, a, launch: !focusing) }
        binding = ["app": "Chromium"]
        defer { binding = nil }
        // Chromium takes a few seconds to come up after the VM starts or is updated.
        guard let snap = poll(timeout: 20, interval: 0.5, { try? snapshot() }) else { _ = try snapshot(); throw Fail(5, "Chromium did not start in the VM") }
        var s = Session(app: "Chromium", bundle: "org.chromium.Chromium", pid: 0, wid: 0, allow: Config.current.allow,
                        id: Session.newId(), url: snap.url, vm: true)
        if focusing, let keep = Session.stored { s.id = keep.id; s.allow = keep.allow; s.uiOnly = keep.uiOnly }
        if let allow = a.value("allow") { s.allow = Config.parseAllow(allow) }
        if let url = s.url { try allowCheck(s, url) }
        s.save()
        SnapStore.clear()
        Store.remove("pending.json")
        let firstThisRun = !Commands.optionsAsked
        if !Commands.optionsAsked, Config.current.askOnStart, !a.has("no-options"), !Ask.away {
            s = Commands.startOptions(s)
        }
        Commands.optionsAsked = true
        var out = "\(focusing ? "focus" : "session \(s.id ?? "-")") · Chromium in the Linux VM (its own cursor and keyboard)"
        if firstThisRun { out += "\n⚠ " + Commands.riskWarning + " Tell the user this once." }
        if let url = s.url { out += " · \(url)" }
        let hints = Routes.hintLines(for: hostOf(s.url)) + Policies.lines(for: hostOf(s.url))
            + (focusing ? [] : Prefs.sessionHints(a, app: "Chromium", host: hostOf(s.url)))
        if !hints.isEmpty { out += "\n" + hints.joined(separator: "\n") }
        out += "\n" + Config.policyLine
        if Awake.enabled { out += "\n" + Awake.status }
        if let update = Repo.updateLine() { out += "\n" + update }
        out += Commands.playbookLines(s)
        Store.log(["cmd": "session", "app": "Chromium", "vm": true, "url": s.url ?? ""])
        return out
    }

    private struct LinuxApp: Decodable {
        var name: String
        var pid: Int
        var title: String
    }

    private static func linuxApps() throws -> [LinuxApp] {
        let reply = try query(["op": "apps"])
        guard let data = try? JSONSerialization.data(withJSONObject: reply["apps"] ?? []),
              let apps = try? JSONDecoder().decode([LinuxApp].self, from: data) else { return [] }
        return apps
    }

    /// Binds a Linux app's window, starting the program when `launch` and it is not running, as
    /// `session --app` does on this Mac.
    static func appSession(_ wanted: String, _ a: Args, launch: Bool) throws -> String {
        let needle = wanted.lowercased()
        func find(pid: Int? = nil) -> LinuxApp? {
            let apps = (try? linuxApps()) ?? []
            return apps.first { $0.pid == pid } ?? apps.first { $0.name.lowercased() == needle }
                ?? apps.first { $0.name.lowercased().contains(needle) || $0.title.lowercased().contains(needle) }
        }
        var app = find()
        if app == nil {
            guard launch else { throw Fail(5, "\(wanted) is not running in the VM: start it with `apprentice session --app \"\(wanted)\" --on linux`") }
            let pid: Int?
            do { pid = (try query(["op": "launch", "cmd": wanted]))["pid"] as? Int } catch let fail as Fail where fail.message.hasPrefix("in the VM") {
                throw Fail(5, "could not start \(wanted) in the VM (\(fail.message.dropFirst("in the VM: ".count))). Is it installed? `apprentice vm shell` gives the ssh command to check or install it")
            }
            // A program can hand its window to a process of its own, so a name match counts too.
            app = poll(timeout: 15, interval: 0.4) { find(pid: pid) }
            guard app != nil else {
                throw Fail(5, "\(wanted) did not show a window in the VM. Is it installed? `apprentice vm shell` gives the ssh command to check or install it")
            }
        }
        guard let app else { throw Fail(5, "\(wanted) is not running in the VM") }
        binding = ["app": app.name, "pid": app.pid]
        defer { binding = nil }
        guard poll(timeout: 10, interval: 0.4, { try? snapshot() }) != nil else { _ = try snapshot(); throw Fail(5, "\(app.name) has no window in the VM") }
        let focusing = !launch
        var s = Session(app: app.name, bundle: nil, pid: pid_t(app.pid), wid: 0, allow: Config.current.allow,
                        id: Session.newId(), url: nil, vm: true)
        if focusing, let keep = Session.stored { s.id = keep.id; s.allow = keep.allow; s.uiOnly = keep.uiOnly }
        if let allow = a.value("allow") { s.allow = Config.parseAllow(allow) }
        try allowCheck(s, nil)
        s.save()
        SnapStore.clear()
        Store.remove("pending.json")
        if !focusing, !Commands.optionsAsked, Config.current.askOnStart, !a.has("no-options"), !Ask.away {
            Commands.optionsAsked = true
            s = Commands.startOptions(s)
        }
        var out = "\(focusing ? "focus" : "session \(s.id ?? "-")") · \(app.name) in the Linux VM (its own cursor and keyboard) · \(app.title)"
        if !focusing {
            out += "\n" + Config.policyLine
            if Awake.enabled { out += "\n" + Awake.status }
            if let update = Repo.updateLine() { out += "\n" + update }
        }
        out += Commands.playbookLines(s)
        Store.log(["cmd": Approvals.request.cmd, "app": app.name, "vm": true])
        return out
    }

    private static var inBrowser: Bool { Session.stored?.app == "Chromium" }

    static func read(_ a: Args) throws -> String {
        let (session, _, _) = try prepare()
        let maxLines = try a.count("max", 80)
        let filter = a.value("filter")?.lowercased()
        let snapshot = try snapshot()
        SnapStore.save(snapshot)
        var lines = snapshot.elements.map(\.line)
        if let filter { lines = lines.filter { $0.lowercased().contains(filter) } }
        Store.log(["cmd": "read", "vm": true, "snap": snapshot.snap, "shown": min(lines.count, maxLines), "total": snapshot.total])
        let out = Commands.render(snapshot, app: session.app, lines: lines, max: maxLines)
        if let host = hostOf(snapshot.url) {
            if let marker = Challenge.find(snapshot) {
                let stop = Challenge.start(host, marker, session: session)
                throw Fail(stop.code, out + "\n" + stop.message
                    + "\nthe user does this in the VM: `apprentice vm call \"pass the check on the page\"` opens it for them")
            }
            if Limits.stored.challenged?[Site.domain(host)] != nil {
                Challenge.clear(Site.domain(host))
                return out + "\nchallenge gone: \(Site.domain(host)) can be used again"
            }
        }
        return out
    }

    static func click(_ a: Args) throws -> String {
        let right = a.has("right"), double = a.has("double")
        let verb = Commands.clickVerb(right: right, double: double)
        let (session, page, old) = try prepare()
        if let raw = a.value("at") {
            let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2 else { throw Fail(5, "click --at x,y") }
            let point = CGPoint(x: parts[0], y: parts[1])
            guard bounds.insetBy(dx: -1, dy: -90).contains(point) else { throw Fail(4, "\(raw) is outside the session window") }
            try gate(session, page, nil, "\(verb) at \(raw)", force: a.has("gate"))
            try beforeAction(session, url: page.url)
            try act {
                let point = Mouse.aim(at: point)
                Mouse.move(to: point)
                Pace.sleep(Rand.uniform(0.04...0.12))
                Mouse.click(at: point, right: right, double: double)
            }
            return try done("click", session, page, old, extra: ["→ at \(raw)"], log: ["at": raw])
        }
        let e: Element
        var extra: [String] = []
        if let words = a.value("on") {
            let needle = words.lowercased()
            let snap = try snapshot()
            SnapStore.save(snap)
            let exact = snap.elements.filter { $0.name.lowercased() == needle }
            let candidates = exact.isEmpty
                ? snap.elements.filter { $0.name.lowercased().contains(needle) && !Element.fieldLabels.contains($0.label) } : exact
            if candidates.count > 1 {
                throw Fail(5, "\(candidates.count) elements match \"\(words)\", so nothing was clicked. Pick one with `click <id>`:\n"
                    + candidates.prefix(12).map(\.line).joined(separator: "\n"))
            }
            guard let hit = candidates.first else { return try clickOCR(words, session, page, old, a, verb: verb) }
            e = hit
            extra = ["→ \"\(words)\""]
        } else {
            guard let id = a.pos.first.flatMap(Int.init) else { throw Fail(5, "click <id> | click --at x,y | click --on \"text\"") }
            e = try resolve(id)
        }
        try gate(session, page, e, "\(verb) \(e.short)", force: a.has("gate"))
        try beforeAction(session, url: page.url)
        try act { try Commands.realClick(e.rect, right: right, double: double) }
        return try done("click", session, page, old, navigates: e.label == "link", extra: extra,
                        log: ["id": e.id, "label": e.label, "name": e.name])
    }

    /// `click --on` for text the list leaves out (a menu or dropdown drawn on its own layer): found by
    /// OCR of the guest's screen, inside the session window, as `click --on` falls back on this Mac.
    private static func clickOCR(_ words: String, _ session: Session, _ page: Page, _ old: Snapshot?, _ a: Args, verb: String) throws -> String {
        let needle = words.lowercased()
        let image = try screen()
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let area = bounds.insetBy(dx: -1, dy: -90)
        let lines = Capture.ocr(image, windowFrame: full, merge: false).filter { area.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }
        let exact = lines.filter { $0.text.lowercased() == needle }
        let found = exact.isEmpty ? lines.filter { $0.text.lowercased().contains(needle) } : exact
        if found.count > 1 {
            throw Fail(5, "\(found.count) places on screen show \"\(words)\", so nothing was clicked. Pick one with `click --at x,y`:\n"
                + found.prefix(12).map { "at \(Int($0.box.midX)),\(Int($0.box.midY)) · \"\(clip($0.text, 60))\"" }.joined(separator: "\n"))
        }
        guard let line = found.first else { throw Fail(5, "no \"\(words)\" on screen, in the list or by OCR") }
        try gate(session, page, nil, "\(verb) \"\(words)\" (found by OCR: \"\(clip(line.text, 60))\")",
                 warn: Gate.matches(words) ? ["may be irreversible: \"\(words)\""] : [], force: a.has("gate"))
        try beforeAction(session, url: page.url)
        try act { try Commands.realClick(line.box, right: a.has("right"), double: a.has("double")) }
        return try done("click", session, page, old, extra: ["→ \"\(words)\""], log: ["on": words])
    }

    private static func focused() throws -> [String: Any] { try query(["op": "focus"].merging(target) { $1 }) }

    static func type(_ a: Args) throws -> String {
        let usage = Fail(5, "type <id|focused> \"text\" [--enter] [--pace fast] | type <id> --secret username|password|code")
        let secret = a.value("secret")
        guard let first = a.pos.first, a.pos.count >= 2 || (secret != nil && a.pos.count == 1) else { throw usage }
        let isFocused = first == "focused"
        guard isFocused || Int(first) != nil else { throw usage }
        var text = a.pos.dropFirst().joined(separator: " ")
        let (session, page, old) = try prepare()
        let e: Element
        if isFocused {
            let f = try focused()
            guard f["found"] as? Bool == true else { throw Fail(5, "nothing has keyboard focus in the VM") }
            let frame = (f["frame"] as? [Double]) ?? [0, 0, 0, 0]
            e = Element(id: 0, path: [], label: "focused \(f["label"] as? String ?? "element")", name: f["name"] as? String ?? "",
                        value: f["value"] as? String, frame: frame, offscreen: false, gated: false)
        } else {
            e = try resolve(Int(first) ?? 0)
        }
        let enter = a.has("enter")
        if let secret {
            let summary = try Login.check(secret, url: page.url, field: e)
            try gate(session, page, e, summary, details: enter ? ["then presses return"] : [],
                     warn: ["signs in (login.auto)"] + (enter ? ["return may submit or send"] : []), force: a.has("gate"))
            text = try Login.value(secret, url: page.url, a)
        } else {
            try gate(session, page, e, "type into \(e.short)",
                     details: (e.value.map { ["current text: \($0)"] } ?? []) + ["replaces it with: \(text)"] + (enter ? ["then presses return"] : []),
                     warn: enter ? ["return may submit or send"] : [], force: a.has("gate"))
        }
        try beforeAction(session, url: page.url)
        // Never on a web page: typing at a third of a person's gaps is a keystroke-timing tell (BOT_DETECTION P1).
        let fast = (a.value("pace") == "fast" || Config.current.pace.mode == "fast") && page.url == nil
        var note: String?
        try act {
            if !isFocused {
                try Commands.realClick(e.rect)
                Pace.sleep(0.1)
                // ctrl+a would wipe whatever has focus, so the click must have reached the field.
                let reached = poll(timeout: 1, interval: 0.1) { () -> Bool? in
                    guard let f = try? focused(), f["found"] as? Bool == true else { return nil }
                    let frame = (f["frame"] as? [Double]).map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) } ?? .zero
                    return frame.intersects(e.rect) || (f["name"] as? String) == e.name ? true : nil
                }
                if reached == nil {
                    throw Fail(5, "the click did not reach \(e.short): something may cover it, such as a suggestion list. Nothing was typed")
                }
            }
            let f = try focused()
            let before = f["value"] as? String
            let secret = f["secret"] as? Bool == true || e.label == "password" || e.name.lowercased().contains("password")
            // A terminal takes typing at its prompt: ctrl+a there moves the cursor, it selects nothing.
            let terminal = e.label.hasSuffix("terminal") || f["label"] as? String == "terminal"
            // As on the Mac, only a field known to be empty is typed into as it is: text it does not show is replaced.
            if before != "", !terminal { try Keys.press("cmd+a") }
            // The VM session is Chromium: a line break is shift+return, so a chat composer never sends half the text.
            try Keys.type(text, fast: fast, corrections: !secret, newline: "shift+return")
            if !text.isEmpty, !secret, !terminal {
                Pace.sleep(0.2)
                let after = (try? focused())?["value"] as? String
                if let after, after.isEmpty {
                    throw Fail(5, "the keys did not arrive: \(e.short) is still empty after typing; check with `read`")
                }
                if let after, let before, !before.isEmpty, after == before, before != text {
                    throw Fail(5, "the keys did not arrive: \(e.short) still shows what it had before; check with `read`")
                }
                let squash = { (s: String) in s.filter { !$0.isWhitespace } }
                if let after, !squash(after).contains(squash(text)) {
                    note = "note: \(e.short) now shows something other than the typed text (autocomplete, formatting or a dropped key); check with `read`"
                }
            }
            if enter {
                Pace.sleep(0.1)
                try Keys.press("return")
            }
            Pace.sleep(0.1)
        }
        return try done("type", session, page, old, navigates: enter, extra: note.map { [$0] } ?? [],
                        log: ["id": e.id, "chars": secret == nil ? text.count : 0, "label": e.label, "name": e.name, "secret": secret ?? ""])
    }

    static func key(_ a: Args) throws -> String {
        guard let combo = a.pos.first else { throw Fail(5, "key <combo>") }
        _ = try Keys.parse(combo)
        let (session, page, old) = try prepare()
        let submits = ["return", "enter"].contains { combo.lowercased().contains($0) }
        try gate(session, page, nil, "press \(combo)", warn: submits ? ["\(combo) may submit or send"] : [])
        try beforeAction(session, url: page.url)
        try act { try Keys.press(combo) }
        Pace.sleep(0.1)
        return try done("key", session, page, old, navigates: submits || combo.contains("left") || combo.contains("right"), extra: ["→ \(combo)"], log: ["combo": combo])
    }

    static func scroll(_ a: Args) throws -> String {
        let (direction, count) = try Commands.scrollArgs(a)
        let (session, page, old) = try prepare()
        try beforeAction(session, url: page.url)
        var rect = CGRect(x: bounds.midX - 20, y: bounds.midY - 20, width: 40, height: 40)
        if let raw = a.value("in"), let id = Int(raw) { rect = try resolve(id).rect }
        let at = try a.value("at").map { try Commands.screenPoint($0, "scroll --at x,y") }
        if let at, !bounds.insetBy(dx: -1, dy: -90).contains(at) { throw Fail(4, "\(a.value("at") ?? "") is outside the session window") }
        try act {
            let point = at.map { Mouse.aim(at: $0) } ?? Mouse.landing(in: rect)
            Mouse.move(to: point, size: at == nil ? rect.size : CGSize(width: 20, height: 20))
            Pace.sleep(Rand.uniform(0.15...0.4))
            Wheel.scroll(lines: count * 3, down: direction == "down" || direction == "right",
                         sideways: direction == "left" || direction == "right")
        }
        var log: [String: Any] = ["direction": direction, "count": count]
        if let raw = a.value("at") { log["at"] = raw }
        return try done("scroll", session, page, old, extra: ["→ \(direction) \(count)"], log: log)
    }

    static func browse(_ a: Args) throws -> String {
        let seconds = try Commands.browseSeconds(a)
        let (session, page, old) = try prepare()
        try beforeAction(session, url: page.url)
        var rect = CGRect(x: bounds.midX - 40, y: bounds.midY - 40, width: 80, height: 80)
        if let raw = a.value("in"), let id = Int(raw) { rect = try resolve(id).rect }
        let moved = try act { () -> (down: Int, up: Int) in
            Mouse.move(to: Mouse.landing(in: rect), size: rect.size)
            Pace.sleep(Rand.uniform(0.15...0.4))
            return Wheel.browse(seconds)
        }
        return try done("browse", session, page, old, extra: ["→ browsed \(Int(seconds)) s: \(moved.down) lines down, \(moved.up) back up"],
                        log: ["seconds": Int(seconds), "down": moved.down, "up": moved.up])
    }

    static func hover(_ a: Args) throws -> String {
        guard let id = a.pos.first.flatMap(Int.init) else { throw Fail(5, "hover <id>") }
        let (session, page, old) = try prepare()
        let e = try resolve(id)
        try beforeAction(session, url: page.url)
        try act { Mouse.move(to: Mouse.landing(in: e.rect), size: e.rect.size) }
        return try done("hover", session, page, old, log: ["id": id, "label": e.label, "name": e.name])
    }

    static func open(_ a: Args) throws -> String {
        guard var raw = a.pos.first else { throw Fail(5, "open <url>") }
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw), let hostname = url.host else { throw Fail(5, "bad URL \"\(raw)\"") }
        guard inBrowser else {
            throw Fail(5, "open goes to the VM's browser: `apprentice focus Chromium --on linux` first")
        }
        let (session, page, old) = try prepare(checkAllow: false)
        try allowCheck(session, raw)
        try keepLocal(raw)
        try Cooldown.check(hostname)
        try gate(session, page, nil, "open \(raw)")
        Config.activate(Config.profileKey(session: session, url: raw))
        try Limits.checkNavigation(url)
        try beforeAction(session, url: raw)
        // The address bar belongs to the browser, not the site, so the address goes in quickly.
        try act {
            try Keys.press("cmd+l")
            try Keys.press("cmd+a")
            try Keys.paste(raw)
            Pace.sleep(Rand.uniform(0.2...0.5))
            try Keys.press("forwarddelete")
            try Keys.press("return")
        }
        Pace.sleep(0.6)
        let arrived = poll(timeout: 8, interval: 0.4) { () -> String? in
            guard let now = try? snapshot().url, let host = hostOf(now) else { return nil }
            return Site.matches(host, hostname) || Site.matches(hostname, host) ? now : nil
        }
        guard arrived != nil else {
            throw Fail(5, "the browser did not go to \(hostname): it shows \((try? snapshot())?.url ?? "no page"). Check it with `read`")
        }
        let playbooks = hostname == hostOf(page.url) ? [] : Playbooks.hintLines(app: nil, bundle: nil, host: hostname, system: "linux")
        // Within a site a person follows links and goes back; a run of typed deep links is a tell (P10, P17).
        let sameSite = hostOf(page.url).map { Site.domain($0) == Site.domain(hostname) } ?? false
        let tip = sameSite ? ["tip: within a site, click its links (`click --on \"…\"`) and go back with `key alt+left`; `open` is for arriving"] : []
        let extra = ["→ \(raw)"] + Routes.hintLines(for: hostname) + Policies.lines(for: hostname) + playbooks + tip
        return try done("open", session, page, old, navigates: true, extra: extra, log: ["url": raw])
    }

    /// `menu "File > Save"`: opens each menu in turn by its name and picks the last item, with one
    /// approval for the whole path. Open menus are the app's popup windows, which `snapshot` reads too.
    static func menu(_ a: Args) throws -> String {
        let parts = a.pos.joined(separator: " ").split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        func norm(_ s: String) -> String {
            s.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "").trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard !parts.isEmpty else { throw Fail(5, "menu \"File > New\"") }
        let (session, page, old) = try prepare()
        let path = parts.joined(separator: " > ")
        try gate(session, page, nil, "menu \(path)", warn: Gate.matches(parts.last ?? "") ? ["may be irreversible: \(parts.last ?? "")"] : [])
        try beforeAction(session, url: page.url)
        let kinds: Set<String> = ["menu", "menuitem", "menubutton", "button"]
        try act {
            for (n, part) in parts.enumerated() {
                let needle = norm(part)
                let hits = poll(timeout: n == 0 ? 0.5 : 2, interval: 0.2) { () -> [Element]? in
                    let items = ((try? snapshot())?.elements ?? []).filter { kinds.contains($0.label) }
                    let exact = items.filter { norm($0.name) == needle }
                    let found = exact.isEmpty ? items.filter { norm($0.name).hasPrefix(needle) } : exact
                    return found.isEmpty ? nil : found
                } ?? []
                guard hits.count == 1, let hit = hits.first else {
                    if n > 0 { try? Keys.press("escape") }
                    let under = n > 0 ? " under \(parts[..<n].joined(separator: " > "))" : ""
                    // Several items start with the name: which one is the caller's choice, not a guess.
                    if hits.count > 1 {
                        throw Fail(5, "\(hits.count) menu items\(under) start with \"\(part)\", so nothing was picked. Name one in full:\n"
                            + hits.prefix(12).map(\.line).joined(separator: "\n"))
                    }
                    throw Fail(5, "no menu item \"\(part)\" in \(session.app)\(under): check with `read`")
                }
                try Commands.realClick(hit.rect)
                Pace.sleep(Rand.uniform(0.15...0.3))
            }
        }
        return try done("menu", session, page, old, extra: ["→ \(path)"], log: ["path": path])
    }
}
