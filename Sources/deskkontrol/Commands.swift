import AppKit
import ApplicationServices
import Foundation

struct Args {
    var pos: [String] = []
    var flags: [String: String] = [:]
    var bools: Set<String> = []

    static func parse(_ raw: [String]) -> Args {
        var a = Args()
        var i = 0
        while i < raw.count {
            let token = raw[i]
            if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    a.flags[String(body[..<eq])] = String(body[body.index(after: eq)...])
                } else if i + 1 < raw.count, !raw[i + 1].hasPrefix("--") {
                    a.flags[body] = raw[i + 1]
                    i += 1
                } else {
                    a.bools.insert(body)
                }
            } else {
                a.pos.append(token)
            }
            i += 1
        }
        return a
    }

    func value(_ key: String, _ fallback: String? = nil) -> String? { flags[key] ?? fallback }
    func int(_ key: String, _ fallback: Int) -> Int { flags[key].flatMap(Int.init) ?? fallback }
    func has(_ key: String) -> Bool { bools.contains(key) || flags[key] != nil }
}

// MARK: - Permissions and app lookup

func requireAccessibility() throws {
    guard AXIsProcessTrusted() else {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        throw Fail(7, "Accessibility is not granted: System Settings → Privacy & Security → Accessibility → enable deskkontrol")
    }
}

func runningApp(named name: String?) -> NSRunningApplication? {
    guard let name, !name.isEmpty else { return NSWorkspace.shared.frontmostApplication }
    let lower = name.lowercased()
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    return apps.first { ($0.localizedName ?? "").lowercased() == lower }
        ?? apps.first { ($0.bundleIdentifier ?? "").lowercased() == lower }
        ?? apps.first { ($0.localizedName ?? "").lowercased().contains(lower) }
}

func launch(named name: String) throws -> NSRunningApplication {
    if let app = runningApp(named: name) { return app }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    proc.arguments = ["-a", name]
    try? proc.run()
    guard let app = poll(timeout: 6, { runningApp(named: name) }) else { throw Fail(5, "could not launch \(name)") }
    return app
}

/// Calls `check` until it returns a value or the timeout passes.
func poll<T>(timeout: Double, interval: Double = 0.25, _ check: () -> T?) -> T? {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if let found = check() { return found }
        Pace.sleep(interval)
    }
    return check()
}

func makeNewWindow(_ app: NSRunningApplication) {
    let name = app.localizedName ?? "Safari"
    let command: String
    if name.contains("Safari") {
        command = "tell application \"Safari\" to make new document"
    } else {
        command = "tell application \"\(name)\" to make new window"
    }
    // NSAppleScript is not thread-safe, and commands run off the main thread.
    DispatchQueue.main.sync {
        guard let script = NSAppleScript(source: command) else { return }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
    }
    Pace.sleep(0.7)
}

func pickWindow(_ app: AXUIElement) -> AXUIElement? {
    let list = windows(of: app).filter { el in
        guard let f = el.frame, f.width > 40, f.height > 40 else { return false }
        let subrole = el.string(kAXSubroleAttribute) ?? ""
        return subrole.isEmpty || subrole == "AXStandardWindow" || subrole == "AXDialog"
    }
    // Require a real window id: AXUIElementGetWindow can fail, and nil == nil would otherwise
    // match a window that was filtered out of `list`.
    if let focused = app.attr(kAXFocusedWindowAttribute) as! AXUIElement?,
       let focusedID = focused.windowID,
       list.contains(where: { $0.windowID == focusedID }) {
        return focused
    }
    return list.max { ($0.frame?.width ?? 0) * ($0.frame?.height ?? 0) < ($1.frame?.width ?? 0) * ($1.frame?.height ?? 0) }
}

func windowURL(_ window: AXUIElement) -> String? {
    if let doc = window.string(kAXDocumentAttribute), !doc.isEmpty { return doc }
    if let web = findFirst(window, limit: 2500, where: { $0.role == "AXWebArea" }) {
        return web.string("AXURL")
    }
    return nil
}

func makeSession(app: NSRunningApplication, window: AXUIElement) throws -> Session {
    // Without a window id, every later lookup would have to guess which window was meant.
    guard let wid = window.windowID else { throw Fail(5, "could not get the window id of \(app.localizedName ?? "the app")'s window") }
    let id = String(UUID().uuidString.prefix(6)).lowercased()
    return Session(app: app.localizedName ?? "app", bundle: app.bundleIdentifier, pid: app.processIdentifier,
                   wid: wid, allow: Config.current.allow, id: id, url: windowURL(window))
}

func requireSession() throws -> Session {
    try requireAccessibility()
    let session = try Session.current()
    Config.activate(Config.profileKey(session: session, url: session.url))
    return session
}

func prepare(checkAllow: Bool = true) throws -> (Session, Target, Snapshot?) {
    var session = try requireSession()
    let target = try locate(session)
    session.track(target.url)
    // Pacing profiles follow the page the window is on now, not the page it was attached to.
    Config.activate(Config.profileKey(session: session, url: target.url))
    if checkAllow { try allowCheck(session, target.url) }
    return (session, target, SnapStore.current)
}

func hostOf(_ url: String?) -> String? {
    url.flatMap(URL.init(string:))?.host
}

func allowCheck(_ s: Session, _ url: String?) throws {
    guard s.allows(url: url) else {
        throw Fail(4, "blocked by allowlist: \(hostOf(url) ?? s.app) is not in \(s.allow.joined(separator: ","))")
    }
}

/// Pacing and per-host rate limits, charged to `url`: the page acted on, or the page `open` goes to.
func beforeAction(_ session: Session, url: String?) throws {
    let host = hostOf(url)
    try Limits.beforeAction(host: host, web: host != nil || session.isBrowser)
}

/// Settles, saves and diffs the new snapshot, and writes the one log row for the action.
func finish(_ command: String, tier: Int, _ session: Session, _ target: Target, _ old: Snapshot?,
            extra: [String] = [], log fields: [String: Any] = [:]) -> String {
    let new = settle(target)
    var session = session
    session.track(new.url)
    SnapStore.save(new)
    SnapshotCache.put(session.wid, new)
    let d = diff(old, new)
    var out = "ok · snap \(new.snap) · \(d.summary)"
    if !extra.isEmpty { out += "\n" + extra.joined(separator: "\n") }
    if !d.lines.isEmpty { out += "\n" + d.lines.prefix(25).joined(separator: "\n") }
    if d.lines.count > 25 { out += "\n… \(d.lines.count - 25) more changes, run `deskkontrol read`" }
    Store.log(fields.merging(["cmd": command, "tier": tier, "snap": new.snap, "diff": d.summary]) { $1 })
    return out
}

func saveGateShot(_ session: Session, _ action: String) {
    guard !Privacy.blocked(session), Capture.permission(), let image = Capture.window(session.wid) else { return }
    let stamp = Int(Date().timeIntervalSince1970)
    let url = Store.runFolder().appendingPathComponent("shots/gate-\(stamp).png")
    try? Capture.save(image, to: url)
    Store.log(["gate_shot": url.path, "action": action])
}

/// Every state-changing command passes here before it acts. Until the caller approves this exact
/// request, it throws exit 8 with a proposal; flagged proposals also keep a screenshot in the log.
func gate(_ session: Session, _ target: Target, _ e: Element?, _ summary: String,
          details: [String] = [], warn: [String] = [], force: Bool = false) throws {
    let warnings = Gate.warnings(e, target, force: force) + warn
    if !warnings.isEmpty, !Approvals.approved { saveGateShot(session, summary) }
    let place = "\(session.app) · \(target.url ?? target.title)"
    try Approvals.check(summary, details: [place] + details, warnings: warnings)
}

// MARK: - Actions

/// Presses or focuses the element through accessibility, without moving the mouse.
func pressElement(_ el: AXUIElement?) -> Bool {
    guard let el else { return false }
    if el.actionNames.contains(kAXPressAction), el.perform(kAXPressAction) == .success { return true }
    return el.set(kAXFocusedAttribute, kCFBooleanTrue) == .success
}

func mouseClick(_ e: Element, pid: pid_t, right: Bool = false, double: Bool = false) {
    let point = Mouse.landing(in: e.rect)
    Mouse.move(to: point, size: e.rect.size, pid: pid)
    Mouse.click(at: point, right: right, double: double, pid: pid)
}

// MARK: - Commands

enum Commands {
    static func run(_ req: Request) throws -> String {
        if KillSwitch.tripped, req.cmd != "ping" { throw Fail(6, "interrupted: the kill switch was pressed") }
        let out = try dispatch(req)
        if KillSwitch.tripped, req.cmd != "ping" { throw Fail(6, "interrupted: the kill switch was pressed") }
        return out
    }

    private static func dispatch(_ req: Request) throws -> String {
        Config.reloadIfChanged()
        Approvals.request = req
        let a = Args.parse(req.args)
        switch req.cmd {
        case "ping": return "pong"
        case "approve": return try approve(a)
        case "deny": return try deny(a)
        case "pending": return Approvals.pending.map { "pending \($0.token) · \($0.summary)" } ?? "nothing pending"
        case "session": return try session(a)
        case "focus": return try focus(a)
        case "open": return try open(a)
        case "read": return try read(a)
        case "click": return try click(a)
        case "type": return try type(a)
        case "key": return try key(a)
        case "scroll": return try scroll(a)
        case "hover": return try hover(a)
        case "drag": return try drag(a)
        case "upload": return try upload(a)
        case "download": return try download(a)
        case "wait-for": return try waitFor(a)
        case "ocr": return try ocr(a)
        case "shot": return try shot(a)
        case "log": return try log(a)
        case "route": return Routes.answer(a.pos.joined(separator: " "))
        default: throw Fail(5, "unknown command \"\(req.cmd)\"")
        }
    }

    /// Runs the pending request for `token`. `--text` replaces the text of a pending `type`.
    static func approve(_ a: Args) throws -> String {
        guard let token = a.pos.first else { throw Fail(5, "approve <token> [--text \"edited text\"]") }
        var p = try Approvals.take(token)
        let edited = a.value("text")
        if let edited {
            guard p.cmd == "type" else { throw Fail(5, "--text only applies to a pending type") }
            let o = Args.parse(p.args)
            p.args = [o.pos.first ?? "", edited]
                + o.flags.sorted { $0.key < $1.key }.flatMap { ["--\($0.key)", $0.value] }
                + o.bools.sorted().map { "--\($0)" }
        }
        Store.log(["gate": p.summary, "approved": true, "edited": edited != nil, "token": token])
        Approvals.granted = p
        defer { Approvals.granted = nil }
        return try dispatch(Request(cmd: p.cmd, args: p.args))
    }

    static func deny(_ a: Args) throws -> String {
        guard let token = a.pos.first else { throw Fail(5, "deny <token>") }
        guard let p = Approvals.pending, p.token == token else { throw Fail(5, "no pending action \(token)") }
        Store.remove("pending.json")
        Store.log(["gate": p.summary, "approved": false, "token": token])
        return "denied · \(p.summary) · nothing was done"
    }

    static func session(_ a: Args) throws -> String {
        try requireAccessibility()
        let requested = try a.value("app").map { try launch(named: $0) }
        guard let app = requested ?? NSWorkspace.shared.frontmostApplication, let name = app.localizedName else {
            throw Fail(5, "no app found")
        }
        if a.has("new-window") { makeNewWindow(app) }
        let s = try attach(app, name, a)
        var out = "session \(s.id ?? "-") · \(name) · window \(s.wid)"
        if let url = s.url { out += " · \(url)" }
        let hints = Routes.hintLines(for: hostOf(s.url))
        if !hints.isEmpty { out += "\n" + hints.joined(separator: "\n") }
        Store.log(["cmd": "session", "app": name, "wid": Int(s.wid), "url": s.url ?? ""])
        return out
    }

    static func focus(_ a: Args) throws -> String {
        try requireAccessibility()
        guard let name = a.pos.first ?? a.value("app") else { throw Fail(5, "focus <app>") }
        guard let app = try? launch(named: name) else { throw Fail(5, "app \"\(name)\" is not running") }
        let s = try attach(app, name, a, keep: Session.stored)
        var out = "focus · \(name) · window \(s.wid)"
        if let url = s.url { out += " · \(url)" }
        return out
    }

    /// Picks the app's main window and saves it as the session. `keep` carries over its id and allowlist.
    private static func attach(_ running: NSRunningApplication, _ name: String, _ a: Args, keep: Session? = nil) throws -> Session {
        enableWebAccessibility(appElement(running.processIdentifier))
        Pace.sleep(0.3)
        let app = runningApp(named: name) ?? running
        guard let window = pickWindow(appElement(app.processIdentifier)) else {
            throw Fail(5, "\(name) has no window: open one, or run `deskkontrol session --new-window`")
        }
        var s = try makeSession(app: app, window: window)
        if let keep { s.id = keep.id; s.allow = keep.allow }
        if let allow = a.value("allow") { s.allow = Config.parseAllow(allow) }
        // A window with no URL yet (a fresh blank tab) is attached; its actions are checked later.
        if let url = s.url { try allowCheck(s, url) }
        s.save()
        SnapStore.clear()
        Store.remove("pending.json")
        return s
    }

    static func open(_ a: Args) throws -> String {
        guard var raw = a.pos.first else { throw Fail(5, "open <url>") }
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw), let hostname = url.host else { throw Fail(5, "bad URL \"\(raw)\"") }
        let (session, target, old) = try prepare(checkAllow: false)
        guard session.allows(url: raw) else {
            throw Fail(4, "blocked by allowlist: \(hostname) is not in \(session.allow.joined(separator: ","))")
        }
        try gate(session, target, nil, "open \(raw)")
        try Limits.checkNavigation(url)
        Config.activate(Config.profileKey(session: session, url: raw))
        try beforeAction(session, url: raw)
        if session.isBrowser {
            try Keys.press("cmd+l", pid: session.pid)
            try Keys.press("cmd+a", pid: session.pid)
            Keys.type(raw, pid: session.pid)
            Pace.sleep(Double.random(in: 0.2...0.5))
            try Keys.press("return", pid: session.pid)
        } else {
            target.window.set(kAXDocumentAttribute, raw as NSString)
        }
        Pace.sleep(0.6)
        let extra = ["→ \(raw)"] + Routes.hintLines(for: hostname)
        return finish("open", tier: 2, session, target, old, extra: extra, log: ["url": raw])
    }

    static func read(_ a: Args) throws -> String {
        let (session, target, _) = try prepare()
        let maxLines = a.int("max", 80)
        let filter = a.value("filter")?.lowercased()
        let snapshot = readSnapshotCached(target, wid: session.wid)
        var lines = snapshot.elements.map(\.line)
        if let filter {
            lines = lines.filter { $0.lowercased().contains(filter) }
        }
        Store.log(["cmd": "read", "snap": snapshot.snap, "shown": min(lines.count, maxLines), "total": snapshot.total])
        return render(snapshot, app: session.app, lines: lines, max: maxLines)
    }

    static func click(_ a: Args) throws -> String {
        guard let id = a.pos.first.flatMap(Int.init) else { throw Fail(5, "click <id>") }
        let (session, target, old) = try prepare()
        let (el, e) = try resolve(id, target)
        let right = a.has("right"), double = a.has("double")
        let verb = right ? "right-click" : double ? "double-click" : "click"
        try gate(session, target, e, "\(verb) \(e.short)", force: a.has("gate"))
        try beforeAction(session, url: target.url)
        let forced = a.int("tier", 0)
        let tier: Int
        if forced == 3 {
            tier = 3
        } else if right || double || forced == 2 {
            tier = 2
        } else if pressElement(el) {
            tier = 1
        } else if forced == 1 {
            // --tier 1 is the fast escape and must never move the pointer, so a failed AX press errors.
            throw Fail(5, "element \(id) \(e.label) \"\(e.name)\" has no accessibility press: drop --tier 1 to click with the pointer")
        } else {
            tier = 2
        }
        switch tier {
        case 1:
            break
        case 2:
            mouseClick(e, pid: session.pid, right: right, double: double)
        default:
            try Borrow.run(target) {
                let rect = el?.frame ?? e.rect
                let point = Mouse.landing(in: rect)
                Mouse.move(to: point, size: rect.size)
                try Borrow.checkpoint()
                Mouse.click(at: point, right: right, double: double)
            }
        }
        return finish("click", tier: tier, session, target, old, log: ["id": id, "label": e.label, "name": e.name])
    }

    static func type(_ a: Args) throws -> String {
        guard let id = a.pos.first.flatMap(Int.init), a.pos.count >= 2 else { throw Fail(5, "type <id> \"text\"") }
        let text = a.pos.dropFirst().joined(separator: " ")
        let (session, target, old) = try prepare()
        let (el, e) = try resolve(id, target)
        let enter = a.has("enter")
        try gate(session, target, e, "type into \(e.short)",
                 details: ["replaces its text with: \(text)"] + (enter ? ["then presses return"] : []),
                 warn: enter ? ["return may submit or send"] : [], force: a.has("gate"))
        try beforeAction(session, url: target.url)
        let fast = a.value("pace") == "fast" || a.int("tier", 0) == 1 || Config.current.pace.mode == "fast"
        let tier: Int
        if fast, let el, el.set(kAXValueAttribute, text as NSString) == .success {
            tier = 1
        } else {
            // OCR elements have no AX element, so they are focused by clicking their frame.
            if !pressElement(el) { mouseClick(e, pid: session.pid) }
            Pace.sleep(0.15)
            try Keys.press("cmd+a", pid: session.pid)
            Keys.type(text, pid: session.pid)
            tier = 2
        }
        if enter {
            Pace.sleep(0.2)
            try Keys.press("return", pid: session.pid)
        }
        return finish("type", tier: tier, session, target, old, log: ["id": id, "chars": text.count])
    }

    static func key(_ a: Args) throws -> String {
        guard let combo = a.pos.first else { throw Fail(5, "key <combo>") }
        _ = try Keys.parse(combo)
        let (session, target, old) = try prepare()
        let submits = ["return", "enter"].contains { combo.lowercased().contains($0) }
        try gate(session, target, nil, "press \(combo)", warn: submits ? ["\(combo) may submit or send"] : [])
        try beforeAction(session, url: target.url)
        try Keys.press(combo, pid: session.pid)
        Pace.sleep(0.2)
        return finish("key", tier: 2, session, target, old, extra: ["→ \(combo)"], log: ["combo": combo])
    }

    static func scroll(_ a: Args) throws -> String {
        guard let direction = a.pos.first?.lowercased(), direction == "up" || direction == "down" else {
            throw Fail(5, "scroll <up|down> [n] [--in id]")
        }
        let count = a.pos.count > 1 ? Int(a.pos[1]) ?? 3 : 3
        let (session, target, old) = try prepare()
        try beforeAction(session, url: target.url)
        var point = CGPoint(x: target.bounds.midX, y: target.bounds.midY)
        if let raw = a.value("in"), let id = Int(raw) {
            let (_, e) = try resolve(id, target)
            point = CGPoint(x: e.rect.midX, y: e.rect.midY)
            Mouse.move(to: point, size: e.rect.size, pid: session.pid)
        }
        let wheel = Int32((direction == "down" ? -1 : 1) * count * 3)
        if let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: wheel, wheel2: 0, wheel3: 0) {
            event.location = point
            Keys.post(event, session.pid)
        }
        return finish("scroll", tier: 2, session, target, old, extra: ["→ \(direction) \(count)"],
                      log: ["direction": direction, "count": count])
    }

    static func hover(_ a: Args) throws -> String {
        guard let id = a.pos.first.flatMap(Int.init) else { throw Fail(5, "hover <id>") }
        let (session, target, old) = try prepare()
        let (_, e) = try resolve(id, target)
        try beforeAction(session, url: target.url)
        let point = Mouse.landing(in: e.rect)
        Mouse.move(to: point, size: e.rect.size, pid: session.pid)
        return finish("hover", tier: 2, session, target, old, log: ["id": id])
    }

    static func drag(_ a: Args) throws -> String {
        guard a.pos.count >= 2, let from = Int(a.pos[0]), let to = Int(a.pos[1]) else { throw Fail(5, "drag <id> <id>") }
        let (session, target, old) = try prepare()
        let (_, src) = try resolve(from, target)
        let (_, dst) = try resolve(to, target)
        try gate(session, target, src, "drag \(src.short) onto \(dst.short)",
                 details: ["borrows the real pointer"], warn: Gate.warnings(dst, target).filter { $0.hasPrefix("may") })
        try beforeAction(session, url: target.url)
        try Borrow.run(target) {
            let start = Mouse.landing(in: src.rect)
            let end = Mouse.landing(in: dst.rect)
            Mouse.move(to: start, size: src.rect.size)
            try Borrow.checkpoint()
            Pace.sleep(0.2)
            try Mouse.drag(from: start, to: end)
        }
        return finish("drag", tier: 3, session, target, old, extra: ["→ \(from) onto \(to)"], log: ["from": from, "to": to])
    }

    static func upload(_ a: Args) throws -> String {
        guard let id = a.pos.first.flatMap(Int.init), a.pos.count >= 2 else { throw Fail(5, "upload <id> <path>") }
        let path = a.pos.dropFirst().joined(separator: " ")
        guard FileManager.default.fileExists(atPath: path) else { throw Fail(5, "file not found: \(path)") }
        let (session, target, old) = try prepare()
        let (el, e) = try resolve(id, target)
        try gate(session, target, e, "upload \(path) through \(e.short)", warn: ["sends a file to \(hostOf(target.url) ?? session.app)"])
        try beforeAction(session, url: target.url)
        guard pressElement(el) else { throw Fail(5, "element \(id) does not open a file dialog") }
        let app = appElement(session.pid)
        let sheet = poll(timeout: 6) {
            findFirst(app, limit: 9000) { i in
                i.role == "AXSheet" || (i.role == "AXWindow" && (i.title ?? "").lowercased().contains("open"))
                    || (i.role == "AXWindow" && (i.title ?? "").lowercased().contains("choose"))
            }
        }
        guard let sheet else { throw Fail(5, "file dialog did not appear") }
        guard let field = findFirst(sheet, limit: 4000, where: { $0.role == "AXTextField" || $0.role == "AXComboBox" }) else {
            throw Fail(5, "file dialog has no path field")
        }
        field.set(kAXValueAttribute, path as NSString)
        Pace.sleep(0.25)
        let confirm = findFirst(sheet, limit: 4000) { i in
            guard i.role == "AXButton", let title = i.title?.lowercased() else { return false }
            return ["open", "choose", "upload", "select", "ok"].contains(title)
        }
        if let confirm { _ = confirm.perform(kAXPressAction) } else { try Keys.press("return", pid: session.pid) }
        return finish("upload", tier: 1, session, target, old, extra: ["uploaded \(path)"], log: ["id": id, "path": path])
    }

    static func download(_ a: Args) throws -> String {
        guard let id = a.pos.first.flatMap(Int.init), a.pos.count >= 2 else { throw Fail(5, "download <id> <path>") }
        let path = a.pos.dropFirst().joined(separator: " ")
        let (session, target, old) = try prepare()
        let (el, e) = try resolve(id, target)
        let source = el?.string("AXURL") ?? e.value ?? ""
        try gate(session, target, e, "download \(e.short) to \(path)", details: ["source: \(source)"])
        try beforeAction(session, url: target.url)
        mouseClick(e, pid: session.pid, right: true)
        Pace.sleep(0.4)
        let app = appElement(session.pid)
        let menu = poll(timeout: 4) {
            findFirst(app, limit: 9000) { i in
                guard i.role == "AXMenuItem", let t = i.title?.lowercased() else { return false }
                return t.contains("save image as") || t.contains("download linked file") || t.contains("save link as") || t.contains("download image")
            }
        }
        guard let menu else { throw Fail(5, "no Save Image As / Download Linked File item for \(id)") }
        _ = menu.perform(kAXPressAction)
        let sheet = poll(timeout: 6) {
            findFirst(app, limit: 9000) { i in
                (i.role == "AXSheet" || i.role == "AXWindow") && (i.title ?? "").lowercased().contains("save")
            }
        }
        if let sheet {
            if let field = findFirst(sheet, limit: 4000, where: { $0.role == "AXTextField" || $0.role == "AXComboBox" }) {
                field.set(kAXValueAttribute, path as NSString)
                Pace.sleep(0.2)
            }
            if let save = findFirst(sheet, limit: 4000, where: { $0.role == "AXButton" && ($0.title ?? "").lowercased() == "save" }) {
                _ = save.perform(kAXPressAction)
            }
        }
        let saved = poll(timeout: 4) { FileManager.default.fileExists(atPath: path) ? true : nil } != nil
        return finish("download", tier: 2, session, target, old, extra: [(saved ? "saved " : "requested ") + path],
                      log: ["id": id, "path": path, "source": source])
    }

    static func waitFor(_ a: Args) throws -> String {
        guard let text = a.pos.first else { throw Fail(5, "wait-for \"text\"") }
        let timeout = a.value("timeout").flatMap(Double.init) ?? 10
        let (_, target, _) = try prepare()
        let needle = text.lowercased()
        let start = Date()
        let found = poll(timeout: timeout, interval: 0.3) { () -> (Snapshot, Element)? in
            let snap = readSnapshot(target)
            return snap.elements.first {
                $0.name.lowercased().contains(needle) || ($0.value ?? "").lowercased().contains(needle)
            }.map { (snap, $0) }
        }
        guard let (snap, hit) = found else {
            Store.log(["cmd": "wait-for", "text": text, "found": false])
            throw Fail(5, "timeout: \"\(text)\" not found in \(Int(timeout)) s")
        }
        SnapStore.save(snap)
        Store.log(["cmd": "wait-for", "text": text, "found": true, "snap": snap.snap])
        return "found · snap \(snap.snap) · \(hit.short) (\(Int(Date().timeIntervalSince(start))) s)"
    }

    static func ocr(_ a: Args) throws -> String {
        try Capture.ensure()
        let (session, target, _) = try prepare()
        let (image, frame) = try capture(session, target, a)
        let elements: [Element] = Capture.ocr(image, windowFrame: frame).enumerated().map { index, line in
            Element(id: index + 1, path: [], label: "text", name: clip(line.text, 100), value: nil,
                    frame: [line.box.minX, line.box.minY, line.box.width, line.box.height].map(Double.init),
                    offscreen: false, gated: Gate.matches(line.text))
        }
        let snap = Snapshot(snap: SnapStore.next(), scope: "ocr", url: target.url, title: target.title,
                            total: elements.count, elements: elements)
        SnapStore.save(snap)
        Store.log(["cmd": "ocr", "snap": snap.snap, "lines": elements.count])
        return render(snap, app: session.app, lines: elements.map(\.line), max: a.int("max", 80))
    }

    static func shot(_ a: Args) throws -> String {
        try Capture.ensure()
        let (session, target, _) = try prepare()
        let (image, _) = try capture(session, target, a)
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        let url = Store.runFolder().appendingPathComponent("shots/shot-\(formatter.string(from: Date())).png")
        try Capture.save(image, to: url)
        Store.log(["cmd": "shot", "path": url.path])
        return url.path
    }

    static func log(_ a: Args) throws -> String {
        let tail = a.int("tail", 20)
        let file = Store.runFolder().appendingPathComponent("steps.jsonl")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return "no steps yet" }
        let rows = text.split(separator: "\n").suffix(tail)
        var out: [String] = []
        for row in rows {
            guard let data = row.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            // "2026-11-01T12:34:56Z" → "12:34:56"
            let time = (obj["ts"] as? String).map { String($0.suffix(9).prefix(8)) } ?? ""
            let cmd = obj["cmd"] as? String ?? obj["gate"] as? String
                ?? (obj["proposed"] as? String).map { "proposed \($0)" } ?? "step"
            var bits = ["\(time)", cmd]
            if let tier = obj["tier"] { bits.append("tier \(tier)") }
            if let snap = obj["snap"] { bits.append("snap \(snap)") }
            if let diff = obj["diff"] { bits.append("\(diff)") }
            if let id = obj["id"] { bits.append("#\(id)") }
            if let app = obj["app"] { bits.append("\(app)") }
            if let url = obj["url"], !(url as? String ?? "").isEmpty { bits.append("\(url)") }
            if let found = obj["found"] { bits.append(found as? Bool == true ? "found" : "not found") }
            if let approved = obj["approved"] { bits.append(approved as? Bool == true ? "approved" : "denied") }
            out.append(bits.joined(separator: " · "))
        }
        return out.joined(separator: "\n")
    }

    static func cropRect(_ raw: String, _ target: Target) throws -> CGRect {
        if let id = Int(raw) {
            let (_, e) = try resolve(id, target)
            return e.rect
        }
        let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else { throw Fail(5, "--crop needs an id or x,y,w,h") }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    /// Captures the session window, cropped by `--crop`, with the screen rect the image covers.
    private static func capture(_ session: Session, _ target: Target, _ a: Args) throws -> (CGImage, CGRect) {
        let wframe = target.window.frame ?? target.bounds
        guard let image = Capture.window(session.wid) else { throw Fail(7, "could not capture window \(session.wid)") }
        guard let raw = a.value("crop") else { return (image, wframe) }
        let rect = try cropRect(raw, target)
        guard let cropped = Capture.crop(image, to: rect, windowFrame: wframe) else { throw Fail(5, "empty crop") }
        return (cropped, rect)
    }

    private static func render(_ s: Snapshot, app: String, lines: [String], max: Int) -> String {
        let shown = lines.prefix(max)
        var out = "<screen>\n" + header(s, app: app, shown: shown.count) + "\n"
        out += shown.joined(separator: "\n")
        if lines.count > shown.count { out += "\n… \(lines.count - shown.count) more, use --max or --filter" }
        return out + "\n</screen>"
    }
}
