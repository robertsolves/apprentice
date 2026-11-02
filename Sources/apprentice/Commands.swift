import AppKit
import ApplicationServices
import Foundation

struct Args {
    var pos: [String] = []
    var flags: [String: String] = [:]
    var bools: Set<String> = []

    /// Flags that are only on or off, so they never take the next word as their value (B7):
    /// `click --right 5` keeps 5 as the id.
    static let switches: Set<String> = [
        "right", "double", "enter", "new-window", "json", "gate", "approve", "screen-anyway", "no-options",
        "multi", "text", "force", "background", "front", "real", "all",
    ]

    static func parse(_ raw: [String]) -> Args {
        var a = Args()
        var i = 0
        while i < raw.count {
            let token = raw[i]
            if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    a.flags[String(body[..<eq])] = String(body[body.index(after: eq)...])
                } else if switches.contains(body) {
                    a.bools.insert(body)
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

    /// A whole number flag that must parse and be at least `min`; a bad value is an error, not a
    /// silent fallback (D9).
    func count(_ key: String, _ fallback: Int, min lower: Int = 0) throws -> Int {
        guard let raw = flags[key] else { return fallback }
        guard let n = Int(raw), n >= lower else { throw Fail(5, "--\(key) needs a whole number of at least \(lower), not \"\(raw)\"") }
        return n
    }
    func has(_ key: String) -> Bool { bools.contains(key) || flags[key] != nil }
}

// MARK: - Permissions and app lookup

func requireAccessibility() throws {
    guard AXIsProcessTrusted() else {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        throw Fail(7, "Accessibility is not granted: System Settings → Privacy & Security → Accessibility → enable apprentice")
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

/// Opens a window as a person would: the app in front, then cmd+n. Waits for the window, since a
/// just-launched app may not be ready for keys yet.
func makeNewWindow(_ app: NSRunningApplication) {
    let ax = appElement(app.processIdentifier)
    app.activate()
    _ = poll(timeout: 3) { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier ? true : nil }
    Pace.sleep(0.4)
    // Always a fresh window, even when the app has others, then wait until it is the one in front.
    let before = Set(windows(of: ax).compactMap(\.windowID))
    for _ in 0..<2 {
        try? Keys.press("cmd+n")
        if poll(timeout: 3, { pickWindow(ax).flatMap { $0.windowID.map { !before.contains($0) } == true ? $0 : nil } }) != nil { return }
    }
}

func pickWindow(_ app: AXUIElement) -> AXUIElement? {
    let list = windows(of: app).filter { el in
        // No window id means no real window, such as Finder's desktop.
        guard el.windowID != nil, let f = el.frame, f.width > 40, f.height > 40 else { return false }
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
    let id = Session.newId()
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
    // apprentice records every page it leads to, so any other change came from someone else.
    if let was = session.url, let now = target.url, was != now {
        Commands.notice = "note: the page changed to \(now) without apprentice. The user or another tool may be using this window; check before acting."
    }
    session.track(target.url)
    // Pacing profiles follow the page the window is on now, not the page it was attached to.
    Config.activate(Config.profileKey(session: session, url: target.url))
    if checkAllow { try allowCheck(session, target.url) }
    try Site.guardPage(target.page, cmd: Approvals.request.cmd) { readSnapshot(target) }
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
    // Per site, as budgets are: www.x.com, mobile.twitter.com and x.com share one per-minute count.
    let host = hostOf(url).map(Site.domain)
    try Limits.beforeAction(host: host, web: host != nil || session.isBrowser)
}

/// Settles, saves and diffs the new snapshot, and writes the one log row for the action. Throws exit 4,
/// with the diff, when the site answered with a challenge or a throttling message.
func finish(_ command: String, _ session: Session, _ target: Target, _ old: Snapshot?,
            extra: [String] = [], log fields: [String: Any] = [:]) throws -> String {
    // Once per command, after every step of it, so a fidget never moves the page between steps.
    if let plan = Fidget.plan(after: command, web: target.url != nil) {
        _ = try? Borrow.run(target) { Fidget.perform(plan, in: target.bounds, web: target.url != nil) }
    }
    let new = Timing.measure("settle") { settle(target) }
    return try finish(command, session, url: target.url, old, new, extra: extra, log: fields)
}

/// The rest of `finish` once the screen has settled, shared with the browser VM.
func finish(_ command: String, _ session: Session, url: String?, _ old: Snapshot?, _ new: Snapshot,
            extra: [String] = [], log fields: [String: Any] = [:]) throws -> String {
    // The step acted, so its budget count stands.
    Commands.reserved = nil
    var session = session
    let new = keepIds(old, new)
    session.track(new.url)
    SnapStore.save(new)
    SnapshotCache.put(session.wid, new)
    let d = diff(old, new)
    var out = "ok · snap \(new.snap) · \(d.summary)"
    if !extra.isEmpty { out += "\n" + extra.joined(separator: "\n") }
    if !d.lines.isEmpty { out += "\n" + d.lines.prefix(25).joined(separator: "\n") }
    if d.lines.count > 25 { out += "\n… \(d.lines.count - 25) more changes, run `apprentice read`" }
    // Flags only, never typed text: `learn` turns these rows into flows.
    let r = Args.parse(Approvals.request.args)
    let flags = (r.flags.filter { $0.key != "json" }.sorted { $0.key < $1.key }.map { "--\($0.key) \($0.value)" }
        + r.bools.subtracting(["json"]).sorted().map { "--\($0)" }).joined(separator: " ")
    var row = fields.merging(["cmd": command, "snap": new.snap, "diff": d.summary, "flags": flags]) { $1 }
    // The site and the budgeted kind let `activity` count actions per site across sessions.
    if let host = hostOf(url) ?? hostOf(new.url) { row["host"] = Site.domain(host) }
    if let kind = Commands.charged { row["kind"] = kind }
    Commands.charged = nil
    Store.log(row)
    if let stop = Site.inspect(command, old, new, session: session) {
        // Code 0 is a warning (`on_challenge` / `on_soft_block = "warn"`): the action stands.
        if stop.code == 0 { return out + "\n⚠ " + stop.message }
        throw Fail(stop.code, out + "\n" + stop.message)
    }
    return out
}

func saveGateShot(_ session: Session, _ action: String) {
    guard let path = Events.shot(session, "gate") else { return }
    Store.log(["gate_shot": path, "action": action])
}

/// Every state-changing command passes here before it acts. Until the caller approves this exact
/// request, it throws exit 8 with a proposal; flagged proposals also keep a screenshot in the log.
func gate(_ session: Session, _ target: Target, _ e: Element?, _ summary: String,
          details: [String] = [], warn: [String] = [], force: Bool = false) throws {
    let kind = try approveStep(session, target.page, e, summary, details: details, warn: warn, force: force)
    try Watch.begin()
    target.raise()
    if kind != nil { Site.dwell() }
}

/// The approval and the site's budget for one step, wherever it runs. Returns the budgeted kind it
/// was counted as, if any.
@discardableResult
func approveStep(_ session: Session, _ target: Page, _ e: Element?, _ summary: String,
                 details: [String] = [], warn: [String] = [], force: Bool = false) throws -> String? {
    let warnings = Gate.warnings(e, target, force: force) + warn + [Cooldown.warning(hostOf(target.url))].compactMap { $0 }
    // A like, follow, comment or other budgeted action is checked against the site's budget before it
    // is proposed, and counted once approved. Typing counts only when return sends it.
    let host = hostOf(target.url)
    let request = Approvals.request
    let sends = request.cmd == "click" || (request.cmd == "type" && Args.parse(request.args).has("enter"))
    let onSettings = Gate.sensitivePage(target.url) || Gate.sensitivePage(target.title)
    var kind = sends ? Budgets.kind(e.map { "\($0.label) \($0.name)" } ?? summary, gated: !warnings.isEmpty || e?.gated == true) : nil
    if request.cmd == "upload" { kind = "upload" } else if kind == "default", onSettings { kind = "settings" }
    if let host, let kind { try Budgets.check(host, kind, record: false) }
    if !warnings.isEmpty, !Approvals.approved, session.vm != true { saveGateShot(session, summary) }
    let place = "\(session.app) · \(target.url ?? target.title)"
    let how = session.vm == true ? "uses the Linux VM's own cursor and keyboard; this Mac's are not touched"
        : "uses the real cursor and keyboard, with \(session.app) in front"
    try Approvals.check(summary, details: [place] + details + [how], warnings: warnings, element: e?.key)
    if let host, let kind {
        try Budgets.check(host, kind, record: true)
        Commands.charged = kind
        Commands.reserved = (host, kind)
    }
    return kind
}

// MARK: - Actions

/// True when `el` contains `node`, as a web field contains its editable text.
func isAncestor(_ el: AXUIElement, of node: AXUIElement) -> Bool {
    var cur: AXUIElement? = node
    for _ in 0..<12 {
        guard let parent = cur?.attr(kAXParentAttribute) as! AXUIElement? else { return false }
        if CFEqual(parent, el) { return true }
        cur = parent
    }
    return false
}

/// Sheets and dialog windows of the app: a file picker is the one that was not there before.
func fileDialogs(_ app: AXUIElement) -> [AXUIElement] {
    windows(of: app).flatMap { [$0] + $0.children }.filter { el in
        let role = el.string(kAXRoleAttribute) ?? "", sub = el.string(kAXSubroleAttribute) ?? ""
        return role == "AXSheet" || (role == "AXWindow" && (sub == "AXDialog" || sub == "AXSystemDialog"))
    }
}

// MARK: - Commands

enum Commands {
    /// A warning for the caller, added to this command's output.
    static var notice: String?
    /// The budgeted kind the current action was counted as, for its log row.
    static var charged: String?
    /// A budget count taken at approval for a step that has not acted yet: refunded if the command fails first.
    static var reserved: (host: String, kind: String)?
    /// When the last command finished, so an update never restarts the daemon in the middle of a task.
    static var lastAt = Date.distantPast

    static func run(_ req: Request) throws -> String {
        // A press stops the action under way and holds every later step (`KillSwitch.halted`) until the
        // user answers; the press itself is cleared, so reading still works (B5).
        if req.cmd != "ping" { KillSwitch.tripped = false }
        Borrow.interrupted = false
        charged = nil
        Timing.begin()
        StatusItem.busy(true)
        defer { StatusItem.busy(false); lastAt = Date() }
        // A new session ends the last one: its scrubbed copy goes into the clone (`[storage] sessions`).
        if req.cmd == "session" { Sessions.archiveCurrent() }
        let result = Result { try Awake.busy { try dispatch(req) } }
        if case .failure = result, let r = reserved { Budgets.refund(r.host, r.kind) }
        reserved = nil
        // `session --task "…"` records what the user asked for, so the log reads as a task, not just steps.
        if req.cmd == "session", (try? result.get()) != nil, case let a = Args.parse(req.args), let task = a.value("task") ?? a.value("goal") {
            Store.log(["task": task])
        }
        if Watch.end() {
            throw Fail(6, "interrupted: you used the keyboard or mouse while apprentice acted in front, so it stopped. Check the screen with `read`, then retry")
        }
        if KillSwitch.tripped {
            KillSwitch.tripped = false
            throw Fail(6, "interrupted: " + KillSwitch.message)
        }
        let out = try result.get()
        defer { notice = nil }
        return notice.map { out + "\n" + $0 } ?? out
    }

    /// Commands that wait on the person or only read files. They run off the command queue
    /// (`Daemon.queue(for:)`), touch no per-command state, and hop onto the queue for anything on screen.
    static let asides: Set<String> = ["ask", "confirm", "show", "log", "pending"]

    static func aside(_ req: Request) throws -> String {
        let a = Args.parse(req.args)
        switch req.cmd {
        case "ask": return try Ask.run(a)
        case "confirm": return try Ask.confirm(a)
        case "show": return try Ask.pointAt(a)
        case "log": return try log(a)
        default:
            let open = Approvals.all
            return open.isEmpty ? "nothing pending" : open.map { "pending \($0.token) · \($0.summary)" }.joined(separator: "\n")
        }
    }

    static func dispatch(_ req: Request) throws -> String {
        Config.reloadIfChanged()
        Approvals.request = req
        if let out = try Remote.dispatch(req) { return out }
        if asides.contains(req.cmd) { return try aside(req) }
        let a = Args.parse(req.args)
        switch req.cmd {
        case "ping": return "pong"
        case "approve": return try approve(a)
        case "deny": return try deny(a)
        case "session": return try session(a)
        case "focus": return try focus(a)
        case "open": return try open(a)
        case "read": return try read(a)
        case "click": return try click(a)
        case "type": return try type(a)
        case "key": return try key(a)
        case "menu": return try menu(a)
        case "scroll": return try scroll(a)
        case "hover": return try hover(a)
        case "browse": return try browse(a)
        case "drag": return try drag(a)
        case "upload": return try upload(a)
        case "choose": return try choose(a)
        case "do": return try runFlow(a)
        case "awake": return try Awake.run(a)
        case "away": return try Ask.awayCommand(a)
        case "resume":
            let was = KillSwitch.halted
            KillSwitch.halted = false
            return was ? "resumed: the kill switch's stop is lifted" : "nothing to resume"
        case "phone": return try Notify.phone(a, tty: false)
        case "download": return try download(a)
        case "wait-for": return try waitFor(a)
        case "ocr": return try ocr(a)
        case "shot": return try shot(a)
        case "cool": return try Cooldown.command(a)
        case "route": return Routes.answer(a.pos.joined(separator: " "))
        default: throw Fail(5, "unknown command \"\(req.cmd)\"")
        }
    }

    /// Runs the pending request for `token`. `--text` replaces the text of a pending `type`.
    static func approve(_ a: Args) throws -> String {
        guard let token = a.pos.first else { throw Fail(5, "approve <token> [--text \"edited text\"]") }
        if Approvals.byUser == token {
            KillSwitch.halted = false
        } else if KillSwitch.halted {
            throw Fail(6, "stopped: " + KillSwitch.message)
        }
        if let p = Approvals.find(token), p.needsUser, Approvals.byUser != token {
            throw Fail(8, "only the user can approve \(token): \(p.summary) is \(Gate.credential). Run `apprentice confirm \(token) --why \"…\"` so they decide in the window. Nobody can approve it for them, nor from the chat")
        }
        var p = try Approvals.take(token)
        // `--text` is a bare switch (it turns on the reply field for `ask --text`), so the parser
        // leaves the replacement text in the positional list: `approve 7c2e --text "new words"`
        // is the token, then the words. Reading only the flag silently typed the old text (I4).
        var edited = a.value("text")
        if edited == nil, a.has("text") {
            let words = a.pos.dropFirst().joined(separator: " ")
            guard !words.isEmpty else { throw Fail(5, "approve <token> --text \"edited text\"") }
            edited = words
        }
        if let edited {
            guard p.cmd == "type" else {
                // Nothing was done, so the proposal stays pending: a flag in the wrong command must
                // not throw away the approval the caller meant to give.
                Approvals.add(p)
                throw Fail(5, "--text only applies to a pending type")
            }
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
        guard let p = Approvals.find(token) else { throw Fail(5, "no pending action \(token)") }
        Approvals.drop(token)
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
        var s = try attach(app, name, a)
        if !optionsAsked, Config.current.askOnStart, !a.has("no-options"), !Ask.away {
            optionsAsked = true
            s = startOptions(s)
        }
        var out = "session \(s.id ?? "-") · \(name) · window \(s.wid)"
        if let url = s.url { out += " · \(url)" }
        let hints = Routes.hintLines(for: hostOf(s.url)) + Policies.lines(for: hostOf(s.url))
        if !hints.isEmpty { out += "\n" + hints.joined(separator: "\n") }
        out += "\n" + Config.policyLine
        if Awake.enabled { out += "\n" + Awake.status }
        if let update = Repo.updateLine() { out += "\n" + update }
        out += notesLines(s)
        Store.log(["cmd": "session", "app": name, "wid": Int(s.wid), "url": s.url ?? ""])
        return out
    }

    static func focus(_ a: Args) throws -> String {
        try requireAccessibility()
        guard let name = a.pos.first ?? a.value("app") else { throw Fail(5, "focus <app>") }
        // focus only switches to a running app; `session --app` is the way to launch one (B9).
        guard let app = runningApp(named: name) else { throw Fail(5, "app \"\(name)\" is not running: start it with `apprentice session --app \"\(name)\"`") }
        let s = try attach(app, name, a, keep: Session.stored)
        var out = "focus · \(name) · window \(s.wid)"
        if let url = s.url { out += " · \(url)" }
        out += notesLines(s)
        return out
    }

    /// The start-up options window is shown once per daemon run, on its first `session`.
    static var optionsAsked = false

    /// Asks the user how this run should work. Skipping keeps the defaults; "Remember" saves them.
    static func startOptions(_ s: Session) -> Session {
        let uiOnly = "UI only: no shell commands for OS tasks"
        let awake = "Keep the Mac awake while a task runs"
        let remember = "Remember these as defaults"
        var s = s
        let reply = DispatchQueue.main.sync {
            Ask.show("apprentice is starting with \(s.app). Options for this session:",
                     choices: [uiOnly, awake, remember], multi: true, withText: true, timeout: Ask.windowTime(120),
                     sendTitle: "Start", checked: Set((Config.current.uiOnly ? [uiOnly] : []) + (Awake.enabled ? [awake] : [])),
                     placeholder: "Allowed sites, comma separated (empty: any)", initialText: s.allow.joined(separator: ", "))
        }
        guard let reply, !reply.skipped else { return s }
        s.uiOnly = reply.chosen.contains(uiOnly)
        Awake.set(reply.chosen.contains(awake))
        s.allow = Config.parseAllow(reply.text).filter { !$0.isEmpty }
        s.save()
        if reply.chosen.contains(remember) {
            Config.remember("agent", "ui_only", s.uiOnly == true ? "true" : "false")
            Config.remember("agent", "keep_awake", Awake.enabled ? "true" : "false")
            Config.remember("session", "allow", "[" + s.allow.map { "\"\($0)\"" }.joined(separator: ", ") + "]")
        }
        Store.log(["options": true, "ui_only": s.uiOnly == true, "allow": s.allow.joined(separator: ",")])
        return s
    }

    /// Key facts from the notes for this app and page, printed under `session` and `focus`.
    static func notesLines(_ s: Session) -> String {
        let lines = Notes.hintLines(app: s.app, bundle: s.bundle, host: hostOf(s.url), system: s.vm == true ? "linux" : "macos")
        return lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n")
    }

    /// Picks the app's main window and saves it as the session. `keep` carries over its id and allowlist.
    private static func attach(_ running: NSRunningApplication, _ name: String, _ a: Args, keep: Session? = nil) throws -> Session {
        enableWebAccessibility(appElement(running.processIdentifier))
        Pace.sleep(0.3)
        let app = runningApp(named: name) ?? running
        var picked = pickWindow(appElement(app.processIdentifier))
        if picked == nil {
            // A fresh daemon may see the app's windows half-described until it is active.
            app.activate()
            picked = poll(timeout: 2) { pickWindow(appElement(app.processIdentifier)) }
        }
        guard let window = picked else {
            throw Fail(5, "\(name) has no window: open one, or run `apprentice session --new-window`")
        }
        var s = try makeSession(app: app, window: window)
        // `focus` keeps the session: its id, its allowlist and the UI-only choice made in the
        // start-up window, which would otherwise fall back to the config default (E5).
        if let keep { s.id = keep.id; s.allow = keep.allow; s.uiOnly = keep.uiOnly }
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
        guard session.isBrowser else { throw Fail(5, "open works in browser sessions; in \(session.app), use its own controls") }
        try allowCheck(session, raw)
        try Cooldown.check(hostname)
        try gate(session, target, nil, "open \(raw)")
        // The profile for the page being opened sets the navigation gap and reload cap, not the
        // profile of the page the window is on now.
        Config.activate(Config.profileKey(session: session, url: raw))
        try Limits.checkNavigation(url)
        try beforeAction(session, url: raw)
        // The address bar belongs to the browser, not the site, so the address is pasted there.
        try Borrow.run(target) {
            try Keys.press("cmd+l")
            try Keys.press("cmd+a")
            try Keys.paste(raw)
            Pace.sleep(Rand.uniform(0.2...0.5))
            // The address bar may still complete inline (a past address, selected): delete that first.
            try Keys.press("forwarddelete")
            try Borrow.checkpoint()
            try Keys.press("return")
        }
        Pace.sleep(0.6)
        // The page must actually be the one asked for, or later commands act on a stale screen (B8).
        let arrived = poll(timeout: 8, interval: 0.4) { () -> String? in
            guard let now = try? locate(session).url, let host = hostOf(now) else { return nil }
            return Site.matches(host, hostname) || Site.matches(hostname, host) ? now : nil
        }
        guard arrived != nil else {
            throw Fail(5, "the window did not go to \(hostname): it shows \((try? locate(session).url) ?? "no page"). Check it with `read`")
        }
        let notes = hostname == hostOf(target.url) ? [] : Notes.hintLines(app: nil, bundle: nil, host: hostname)
        let extra = ["→ \(raw)"] + Routes.hintLines(for: hostname) + Policies.lines(for: hostname) + notes
        return try finish("open", session, target, old, extra: extra, log: ["url": raw])
    }

    static func read(_ a: Args) throws -> String {
        let (session, target, _) = try prepare()
        let maxLines = try a.count("max", 80)
        let filter = a.value("filter")?.lowercased()
        let snapshot = readSnapshotCached(target, wid: session.wid)
        var lines = snapshot.elements.map(\.line)
        if let filter {
            lines = lines.filter { $0.lowercased().contains(filter) }
        }
        Store.log(["cmd": "read", "snap": snapshot.snap, "shown": min(lines.count, maxLines), "total": snapshot.total])
        let out = render(snapshot, app: session.app, lines: lines, max: maxLines)
        // A challenge stops work on the site until the user completes it; reading shows when it is gone.
        if let host = hostOf(snapshot.url) {
            if let marker = Challenge.find(snapshot) {
                let stop = Challenge.start(host, marker, session: session)
                throw Fail(stop.code, out + "\n" + stop.message)
            }
            if Limits.stored.challenged?[Site.domain(host)] != nil {
                Challenge.clear(Site.domain(host))
                return out + "\nchallenge gone: \(Site.domain(host)) can be used again"
            }
        }
        return out
    }

    static func click(_ a: Args) throws -> String {
        if let at = a.value("at") { return try clickAt(at, a) }
        if let words = a.value("on") { return try clickOn(words, a) }
        guard let id = a.pos.first.flatMap(Int.init) else { throw Fail(5, "click <id> | click --at x,y") }
        let (session, target, old) = try prepare()
        let (el, e) = try resolve(id, target)
        let right = a.has("right"), double = a.has("double")
        let verb = clickVerb(right: right, double: double)
        try gate(session, target, e, "\(verb) \(e.short)", force: a.has("gate"))
        try beforeAction(session, url: target.url)
        let (_, rect) = liveRect(el, e, target)
        try Borrow.run(target) { try realClick(rect, right: right, double: double) }
        return try finish("click", session, target, old, log: ["id": id, "label": e.label, "name": e.name])
    }

    /// Where an element is right now. Panels slide in and pages replace elements, so the snapshot's
    /// frame can be stale: when the element is gone it is found again by label and name, and the
    /// frame is read until it holds still (F6).
    static func liveRect(_ el: AXUIElement?, _ e: Element, _ target: Target) -> (AXUIElement?, CGRect) {
        var node = el
        if node?.frame == nil, !e.path.isEmpty {
            let snap = readSnapshot(target)
            if let again = snap.elements.first(where: { $0.key == e.key }) {
                node = walkPath(target.root, again.path)
                if node == nil { return (nil, again.rect) }
            }
        }
        var last = node?.frame ?? e.rect
        for _ in 0..<6 {
            Pace.sleep(0.05)
            let now = node?.frame ?? last
            if now == last { break }
            last = now
        }
        return (node, last)
    }

    /// Moves the real cursor into `rect` along a curved path and clicks. Call inside `Borrow.run`.
    static func realClick(_ rect: CGRect, right: Bool = false, double: Bool = false) throws {
        let point = Mouse.landing(in: rect)
        Mouse.move(to: point, size: rect.size)
        try Borrow.checkpoint()
        // A person's hand comes to rest over the target before pressing.
        let rest = Mouse.settle(at: point)
        try Borrow.checkpoint()
        Mouse.click(at: rest, right: right, double: double)
    }

    /// Clicks into a field, checks it took focus, selects what is there and types over it, all with
    /// real input. Call inside `Borrow.run`. `focused` skips the click for the field that already has focus.
    /// Returns a note when the field ends up showing something other than the text.
    @discardableResult
    static func typeInto(_ el: AXUIElement?, _ rect: CGRect, _ text: String, _ target: Target,
                         focused: Bool = false, fast: Bool = false, label: String = "the field") throws -> String? {
        if !focused {
            try realClick(rect)
            Pace.sleep(0.1)
        }
        try Borrow.checkpoint()
        // cmd+a would wipe whatever has focus, so check that the click reached the field. Browsers
        // report the new focus a moment late, so give it up to a second.
        let reached = { () -> Bool? in
            guard let el, let now = target.app.attr(kAXFocusedUIElementAttribute) as! AXUIElement? else { return true }
            if CFEqual(now, el) || isAncestor(el, of: now) { return true }
            // Pages often replace a field with a fresh element when it gains focus: the same kind of
            // field with the same name, or one sitting where we clicked, is still the field.
            let sameKind = now.string(kAXRoleAttribute) == el.string(kAXRoleAttribute)
            let sameName = (now.string(kAXDescriptionAttribute) ?? now.string(kAXTitleAttribute))
                == (el.string(kAXDescriptionAttribute) ?? el.string(kAXTitleAttribute))
            let overlaps = now.frame.map { $0.intersects(rect) } ?? false
            return sameKind && (sameName || overlaps) ? true : nil
        }
        if !focused, poll(timeout: 1, interval: 0.1, reached) == nil {
            throw Fail(5, "the click did not reach \(label): something may cover it, such as a suggestion list. Nothing was typed")
        }
        // The focused field's text, when it shows it; password fields never do.
        let shown = { () -> String? in
            guard let now = target.app.attr(kAXFocusedUIElementAttribute) as! AXUIElement?,
                  now.string(kAXSubroleAttribute) != "AXSecureTextField" else { return nil }
            return now.string(kAXValueAttribute)
        }
        let before = shown()
        // Select all only to replace something; an empty field is typed into as it is.
        if before != "" { try Keys.press("cmd+a") }
        let secret = (target.app.attr(kAXFocusedUIElementAttribute) as! AXUIElement?)?.string(kAXSubroleAttribute) == "AXSecureTextField"
            || label.lowercased().contains("password")
        try Keys.type(text, fast: fast, corrections: !secret)
        // Keys can land nowhere (another app or tool has focus) while every step "works" (F4). Checked
        // before any return is pressed, so nothing half-typed is sent.
        guard !text.isEmpty else { return nil }
        Pace.sleep(0.2)
        guard let after = shown() else { return nil }
        if after.isEmpty {
            throw Fail(5, "the keys did not arrive: \(label) is still empty after typing. Another app or tool may have focus; check with `read`")
        }
        if let before, !before.isEmpty, after == before, before != text {
            throw Fail(5, "the keys did not arrive: \(label) still shows what it had before. Another app or tool may have focus; check with `read`")
        }
        // Autocomplete, formatting (a phone number) or a dropped key can all change what a field
        // shows. That is worth a look, not a failure.
        let squash = { (s: String) in s.filter { !$0.isWhitespace } }
        return squash(after).contains(squash(text)) ? nil : "note: \(label) now shows something other than the typed text (autocomplete, formatting or a dropped key); check with `read`"
    }

    /// `click --on "text"`: clicks visible text. The list is tried first; text the page never exposes to
    /// accessibility (a dropdown drawn on its own layer) is found by OCR of the window, which needs
    /// Screen Recording, and clicked with the real cursor (F1).
    private static func clickOn(_ words: String, _ a: Args) throws -> String {
        let (session, target, old) = try prepare()
        let needle = words.lowercased()
        let snap = readSnapshot(target)
        SnapStore.save(snap)
        let listed = snap.elements.first { $0.name.lowercased() == needle }
            ?? snap.elements.first { e in
                e.name.lowercased().contains(needle) && !Element.fieldLabels.contains(e.label)
            }
        var rect = listed?.rect
        var how = listed.map { "listed as \($0.short)" } ?? ""
        if rect == nil {
            try Capture.ensure()
            let (image, frame) = try capture(session, target, Args())
            let lines = Capture.ocr(image, windowFrame: frame, merge: false)
            let line = lines.first { $0.text.lowercased() == needle } ?? lines.first { $0.text.lowercased().contains(needle) }
            guard let line else { throw Fail(5, "no \"\(words)\" on screen, in the list or by OCR") }
            rect = line.box
            how = "found by OCR: \"\(clip(line.text, 60))\""
        }
        guard let rect else { throw Fail(5, "no \"\(words)\" on screen") }
        let right = a.has("right"), double = a.has("double")
        try gate(session, target, listed, "click \"\(words)\" (\(how))",
                 warn: listed == nil && Gate.matches(words) ? ["may be irreversible: \"\(words)\""] : [], force: a.has("gate"))
        try beforeAction(session, url: target.url)
        try Borrow.run(target) { try realClick(rect, right: right, double: double) }
        return try finish("click", session, target, old, extra: ["→ \"\(words)\""], log: ["on": words])
    }

    /// `click --at x,y`: a real click at a screen point, for things `read` cannot list (from `show`).
    private static func clickAt(_ raw: String, _ a: Args) throws -> String {
        let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { throw Fail(5, "click --at x,y") }
        let point = CGPoint(x: parts[0], y: parts[1])
        let (session, target, old) = try prepare()
        guard target.window.frame?.contains(point) ?? false else { throw Fail(4, "\(raw) is outside the session window") }
        let right = a.has("right"), double = a.has("double")
        try gate(session, target, nil, "\(clickVerb(right: right, double: double)) at \(raw)", force: a.has("gate"))
        try beforeAction(session, url: target.url)
        try Borrow.run(target) {
            Mouse.move(to: point)
            try Borrow.checkpoint()
            Pace.sleep(Rand.uniform(0.04...0.12))
            Mouse.click(at: point, right: right, double: double)
        }
        return try finish("click", session, target, old, extra: ["→ at \(raw)"], log: ["at": raw])
    }

    static func type(_ a: Args) throws -> String {
        let usage = Fail(5, "type <id|focused> \"text\" [--enter] [--pace fast]")
        guard let first = a.pos.first, a.pos.count >= 2 else { throw usage }
        let focused = first == "focused"
        guard focused || Int(first) != nil else { throw usage }
        let id = Int(first) ?? 0
        let text = a.pos.dropFirst().joined(separator: " ")
        let (session, target, old) = try prepare()
        let (el, e) = focused ? try focusedElement(target) : try resolve(id, target)
        let enter = a.has("enter")
        try gate(session, target, e, "type into \(e.short)",
                 details: (e.value.map { ["current text: \($0)"] } ?? []) + ["replaces it with: \(text)"]
                    + (enter ? ["then presses return"] : []),
                 warn: enter ? ["return may submit or send"] : [], force: a.has("gate"))
        try beforeAction(session, url: target.url)
        let fast = a.value("pace") == "fast" || Config.current.pace.mode == "fast"
        let (node, rect) = focused ? (el, e.rect) : liveRect(el, e, target)
        var note: String?
        try Borrow.run(target) {
            note = try typeInto(node, rect, text, target, focused: focused, fast: fast, label: e.short)
            if enter {
                Pace.sleep(0.1)
                try Keys.press("return")
            }
            Pace.sleep(0.1)
        }
        return try finish("type", session, target, old, extra: note.map { [$0] } ?? [],
                      log: ["id": id, "chars": text.count, "label": e.label, "name": e.name])
    }

    /// The element that has keyboard focus, such as an inline rename field that `read` cannot list.
    /// It must be inside the session window.
    private static func focusedElement(_ t: Target) throws -> (AXUIElement?, Element) {
        guard let el = t.app.attr(kAXFocusedUIElementAttribute) as! AXUIElement? else {
            throw Fail(5, "nothing has keyboard focus in \(t.title)")
        }
        let f = el.frame ?? .zero
        // Field editors such as an inline rename hang off the application with no window,
        // so they count as inside when they sit within the session window's frame.
        if let window = el.attr(kAXWindowAttribute) as! AXUIElement? {
            guard window.windowID == t.window.windowID else { throw Fail(4, "the focused element is outside the session window") }
        } else {
            guard let wf = t.window.frame, !f.isEmpty, wf.contains(f) else { throw Fail(4, "the focused element is outside the session window") }
        }
        let name = el.string(kAXTitleAttribute) ?? el.string(kAXDescriptionAttribute) ?? ""
        return (el, Element(id: 0, path: [], label: "focused \(el.string(kAXRoleAttribute) ?? "element")", name: name, value: el.string(kAXValueAttribute),
                            frame: [f.minX, f.minY, f.width, f.height].map(Double.init), offscreen: false, gated: Gate.matches(name)))
    }

    static func key(_ a: Args) throws -> String {
        guard let combo = a.pos.first else { throw Fail(5, "key <combo>") }
        _ = try Keys.parse(combo)
        let (session, target, old) = try prepare()
        let submits = ["return", "enter"].contains { combo.lowercased().contains($0) }
        try gate(session, target, nil, "press \(combo)", warn: submits ? ["\(combo) may submit or send"] : [])
        try beforeAction(session, url: target.url)
        try Borrow.run(target) { try Keys.press(combo) }
        Pace.sleep(0.1)
        return try finish("key", session, target, old, extra: ["→ \(combo)"], log: ["combo": combo])
    }

    /// Picks a menu-bar item the way a person does, e.g. `menu "File > New Folder"`: a real click on the
    /// menu title, the cursor over each submenu, and a click on the item. The path is checked first.
    static func menu(_ a: Args) throws -> String {
        func norm(_ s: String) -> String {
            s.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
                .trimmingCharacters(in: .whitespaces).lowercased()
        }
        let path = a.pos.joined(separator: " ").split(separator: ">").map { norm(String($0)) }.filter { !$0.isEmpty }
        guard !path.isEmpty else { throw Fail(5, "menu \"File > New Folder\"") }
        let (session, target, old) = try prepare()
        guard let bar = target.app.attr(kAXMenuBarAttribute) as! AXUIElement? else { throw Fail(5, "\(session.app) has no menu bar") }
        var nodes: [AXUIElement] = []
        var titles: [String] = []
        var node = bar
        for (n, name) in path.enumerated() {
            // Menu-bar items and submenu items hold their entries in a single AXMenu child.
            let items = n == 0 ? node.children : (node.children.first?.children ?? [])
            guard let next = items.first(where: { norm($0.string(kAXTitleAttribute) ?? "") == name }) else {
                let names = items.compactMap { $0.string(kAXTitleAttribute) }.filter { !$0.isEmpty }
                throw Fail(5, "no menu item \"\(name)\" in \(titles.isEmpty ? "the menu bar" : titles.joined(separator: " > ")): \(names.joined(separator: ", "))")
            }
            nodes.append(next)
            node = next
            titles.append(next.string(kAXTitleAttribute) ?? name)
        }
        let label = titles.joined(separator: " > ")
        try gate(session, target, nil, "menu \(label)",
                 warn: Gate.matches(titles.last ?? "") ? ["may be irreversible: \(titles.last ?? "")"] : [])
        try beforeAction(session, url: target.url)
        try Borrow.run(target) {
            for (i, item) in nodes.enumerated() {
                // An item has a place on screen only once its menu is open.
                guard let f = poll(timeout: 2, { item.frame.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } }) else {
                    try? Keys.press("esc")
                    throw Fail(5, "menu item \"\(titles[i])\" did not appear")
                }
                let last = i == nodes.count - 1
                if last, item.attr(kAXEnabledAttribute) as? Bool == false {
                    try? Keys.press("esc")
                    throw Fail(5, "menu item \"\(label)\" is disabled right now")
                }
                if i == 0 || last {
                    try realClick(f)
                } else {
                    // Submenus open when the cursor rests on them.
                    Mouse.move(to: Mouse.landing(in: f), size: f.size)
                    try Borrow.checkpoint()
                    Pace.sleep(0.35)
                }
                Pace.sleep(0.25)
            }
        }
        return try finish("menu", session, target, old, extra: ["→ \(label)"], log: ["menu": label])
    }

    static func scroll(_ a: Args) throws -> String {
        let (direction, count) = try scrollArgs(a)
        let (session, target, old) = try prepare()
        try beforeAction(session, url: target.url)
        var rect = CGRect(x: target.bounds.midX - 20, y: target.bounds.midY - 20, width: 40, height: 40)
        if let raw = a.value("in"), let id = Int(raw) { rect = try resolve(id, target).1.rect }
        let at = try a.value("at").map { try screenPoint($0, "scroll --at x,y") }
        if let at, !(target.window.frame?.contains(at) ?? false) { throw Fail(4, "\(a.value("at") ?? "") is outside the session window") }
        try Borrow.run(target) {
            // The wheel scrolls whatever is under the cursor, so the cursor goes there first. A map
            // zooms on the point under it, so `--at` lands exactly there.
            let point = at ?? Mouse.landing(in: rect)
            Mouse.move(to: point, size: at == nil ? rect.size : CGSize(width: 20, height: 20))
            try Borrow.checkpoint()
            Pace.sleep(Rand.uniform(0.15...0.4))
            // In flicks of a few notches, as a wheel turns, instead of one jump of every line at once.
            Wheel.scroll(lines: count * 3, down: direction == "down" || direction == "right",
                         sideways: direction == "left" || direction == "right")
        }
        var log: [String: Any] = ["direction": direction, "count": count]
        if let raw = a.value("at") { log["at"] = raw }
        return try finish("scroll", session, target, old, extra: ["→ \(direction) \(count)"], log: log)
    }

    /// `browse [seconds] [--in id]`: reads down the page or feed for a while (30 s, at most 120), flick by
    /// flick with reading pauses and now and then a look back up. Clicks and types nothing, so like
    /// `scroll` it needs no approval.
    static func browse(_ a: Args) throws -> String {
        let seconds = try browseSeconds(a)
        let (session, target, old) = try prepare()
        try beforeAction(session, url: target.url)
        var rect = CGRect(x: target.bounds.midX - 40, y: target.bounds.midY - 40, width: 80, height: 80)
        if let raw = a.value("in"), let id = Int(raw) { rect = try resolve(id, target).1.rect }
        let moved = try Borrow.run(target) { () -> (down: Int, up: Int) in
            Mouse.move(to: Mouse.landing(in: rect), size: rect.size)
            try Borrow.checkpoint()
            Pace.sleep(Rand.uniform(0.15...0.4))
            return Wheel.browse(seconds)
        }
        return try finish("browse", session, target, old, extra: ["→ browsed \(Int(seconds)) s: \(moved.down) lines down, \(moved.up) back up"],
                      log: ["seconds": Int(seconds), "down": moved.down, "up": moved.up])
    }

    /// `scroll up|down [n]`: the direction and the steps, 3 by default and at most 50.
    static func scrollArgs(_ a: Args) throws -> (direction: String, count: Int) {
        guard let direction = a.pos.first?.lowercased(), ["up", "down", "left", "right"].contains(direction) else {
            throw Fail(5, "scroll <up|down|left|right> [n] [--in id | --at x,y]")
        }
        guard a.pos.count > 1 else { return (direction, 3) }
        guard let n = Int(a.pos[1]), n >= 1 else { throw Fail(5, "scroll needs a whole number of steps, not \"\(a.pos[1])\"") }
        return (direction, min(n, 50))
    }

    /// `x,y` in screen points, as `click --at`, `scroll --at` and `drag --at` take it (and `--by`'s offset).
    static func screenPoint(_ raw: String, _ usage: String) throws -> CGPoint {
        let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, parts.allSatisfy(\.isFinite) else { throw Fail(5, usage) }
        return CGPoint(x: parts[0], y: parts[1])
    }

    static func clickVerb(right: Bool, double: Bool) -> String {
        right ? "right-click" : double ? "double-click" : "click"
    }

    static func browseSeconds(_ a: Args) throws -> Double {
        guard let raw = a.pos.first else { return 30 }
        guard let s = Double(raw), s.isFinite, s >= 1 else { throw Fail(5, "browse [seconds] [--in id]: seconds is a number, 1–120") }
        return min(s, 120)
    }

    static func hover(_ a: Args) throws -> String {
        guard let id = a.pos.first.flatMap(Int.init) else { throw Fail(5, "hover <id>") }
        let (session, target, old) = try prepare()
        let (_, e) = try resolve(id, target)
        try beforeAction(session, url: target.url)
        try Borrow.run(target) { Mouse.move(to: Mouse.landing(in: e.rect), size: e.rect.size) }
        return try finish("hover", session, target, old, log: ["id": id, "label": e.label, "name": e.name])
    }

    static func drag(_ a: Args) throws -> String {
        if let raw = a.value("by") { return try dragBy(raw, a) }
        guard a.pos.count >= 2, let from = Int(a.pos[0]), let to = Int(a.pos[1]) else { throw Fail(5, dragUsage) }
        let (session, target, old) = try prepare()
        let (_, src) = try resolve(from, target)
        let (_, dst) = try resolve(to, target)
        try gate(session, target, src, "drag \(src.short) onto \(dst.short)",
                 warn: Gate.warnings(dst, target.page).filter { $0.hasPrefix("may") })
        try beforeAction(session, url: target.url)
        try Borrow.run(target) {
            let start = Mouse.landing(in: src.rect)
            let end = Mouse.landing(in: dst.rect)
            Mouse.move(to: start, size: src.rect.size)
            try Borrow.checkpoint()
            Pace.sleep(0.2)
            try Mouse.drag(from: start, to: end)
        }
        return try finish("drag", session, target, old, extra: ["→ \(from) onto \(to)"], log: ["from": from, "to": to, "label": src.label, "name": src.name, "to_label": dst.label, "to_name": dst.name])
    }

    static let dragUsage = "drag <id> <id> | drag --by dx,dy [--in id | --at x,y]"

    /// `drag --by dx,dy [--in id | --at x,y]`: presses inside the element (or the middle of the window, or
    /// at a point), moves by the offset and lets go, as a hand pans a map, canvas or timeline. The whole
    /// path stays in the window. Gated like any drag, since on a slider or a list it changes things.
    private static func dragBy(_ raw: String, _ a: Args) throws -> String {
        let by = try screenPoint(raw, dragUsage)
        let (session, target, old) = try prepare()
        var rect = CGRect(x: target.bounds.midX - 40, y: target.bounds.midY - 40, width: 80, height: 80)
        var e: Element?
        if let r = a.value("in"), let id = Int(r) { e = try resolve(id, target).1; rect = e!.rect }
        let start = try a.value("at").map { try screenPoint($0, dragUsage) } ?? Mouse.landing(in: rect)
        let end = CGPoint(x: start.x + by.x, y: start.y + by.y)
        guard let frame = target.window.frame, frame.contains(start), frame.contains(end) else {
            throw Fail(4, "a drag by \(raw) from \(Int(start.x)),\(Int(start.y)) leaves the session window: drag less, or in two steps")
        }
        let what = e.map { "drag in \($0.short) by \(raw)" } ?? "drag at \(Int(start.x)),\(Int(start.y)) by \(raw)"
        try gate(session, target, e, what, force: a.has("gate"))
        try beforeAction(session, url: target.url)
        try Borrow.run(target) {
            Mouse.move(to: start, size: e == nil ? CGSize(width: 20, height: 20) : rect.size)
            try Borrow.checkpoint()
            Pace.sleep(Rand.uniform(0.1...0.25))
            try Mouse.drag(from: start, to: end)
        }
        var log: [String: Any] = ["by": raw]
        if let e { log["label"] = e.label; log["name"] = e.name }
        return try finish("drag", session, target, old, extra: ["→ by \(raw)"], log: log)
    }

    /// `choose <path>`: drives the open or save dialog on the session window. An existing file is
    /// selected and opened; a folder is gone to; a new file name goes to its folder and the name field.
    static func choose(_ a: Args) throws -> String {
        let path = (a.pos.joined(separator: " ") as NSString).expandingTildeInPath
        guard !path.isEmpty else { throw Fail(5, "choose <path>") }
        let (session, target, old) = try prepare()
        let app = appElement(session.pid)
        let dialogs = fileDialogs(app)
        guard let dialog = dialogs.first(where: { $0.string(kAXRoleAttribute) == "AXSheet" }) ?? dialogs.first else {
            throw Fail(5, "no open or save dialog on the session window: press the control that opens one first")
        }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let file = exists && !isDir.boolValue
        let folder = exists ? path : (path as NSString).deletingLastPathComponent
        let summary = file ? "choose and open \(path)" : exists ? "go to \(path)" : "save as \(path)"
        try gate(session, target, nil, summary + " in the file dialog",
                 warn: file ? ["opens or attaches the file in \(session.app)"] : [])
        try beforeAction(session, url: nil)
        try choosePath(file ? path : folder, in: dialog, app: app, target, open: file)
        if !exists { try fillName((path as NSString).lastPathComponent, in: dialog, target) }
        let next = file ? "chose \(path)" : exists ? "in \(path)" : "name set: press the dialog's Save button"
        return try finish("choose", session, target, old, extra: [next], log: ["path": path])
    }

    /// Goes to `path` through the dialog's Go to Folder sheet, then opens it when `open` is set.
    /// Everything is real input: the panel runs in a system process and takes keys once it has focus.
    private static func choosePath(_ path: String, in dialog: AXUIElement, app: AXUIElement, _ target: Target, open: Bool) throws {
        let gone = { fileDialogs(app).contains { CFEqual($0, dialog) } ? nil : true }
        // The dialog is itself a sheet, so look for Go to Folder among its descendants only.
        let goField = { () -> AXUIElement? in
            dialog.children.lazy.compactMap { child in
                child.string(kAXRoleAttribute) == "AXSheet" ? child : findFirst(child, limit: 4000) { $0.role == "AXSheet" }
            }.first.flatMap { sheet in
                findFirst(sheet, limit: 500) { $0.role == "AXTextField" || $0.role == "AXComboBox" }
            }
        }
        let search = findFirst(dialog, limit: 4000, where: { $0.subrole == "AXSearchField" })
        let list = findFirst(dialog, limit: 4000, where: { $0.role == "AXOutline" || $0.role == "AXTable" })
        try Borrow.run(target) {
            Pace.sleep(0.4)
            // Text left in the search field turns the list into search results: clear it as a person would.
            if let search, !(search.string(kAXValueAttribute) ?? "").isEmpty, let f = search.frame {
                try realClick(f)
                try Keys.press("cmd+a")
                try Keys.press("backspace")
            }
            // The panel takes keys only once it has focus. The bottom edge of the file list is usually
            // empty, so a click there gives focus and selects nothing.
            if goField() == nil, let f = list?.frame ?? dialog.frame, f.height > 30 {
                try realClick(CGRect(x: f.minX + 20, y: f.maxY - 14, width: f.width - 40, height: 10))
                Pace.sleep(0.3)
            }
            if goField() == nil { try Keys.press("cmd+shift+g") }
            // With focus in the search field the shortcut does nothing; "/" typed in the file list opens it too.
            if poll(timeout: 1.5, goField) == nil { try Keys.press("/") }
            guard let field = poll(timeout: 3, goField) else { throw Fail(5, "Go to Folder did not open in the file dialog") }
            // A system dialog, not a website, so the path is pasted: no inline completion eats keys.
            // If the field still shows something else, type it key by key once.
            for attempt in 0..<2 where field.string(kAXValueAttribute) != path {
                try Borrow.checkpoint()
                try Keys.press("cmd+a")
                if attempt == 0 { try Keys.paste(path) } else { try Keys.type(path) }
                Pace.sleep(1.5)
            }
            guard field.string(kAXValueAttribute) == path else {
                throw Fail(5, "Go to Folder shows \"\(field.string(kAXValueAttribute) ?? "")\", not the path: nothing was chosen")
            }
            try Keys.press("return")
            guard open else { return }
            // A file path selects the file; some panels open it on the same return, others need Open.
            if poll(timeout: 1.5, gone) == nil {
                let button = findFirst(dialog, limit: 4000) { i in
                    i.role == "AXButton" && ["open", "choose", "upload", "select"].contains((i.title ?? "").lowercased())
                }
                if let f = button?.frame { try realClick(f) } else { try Keys.press("return") }
            }
        }
        if open, poll(timeout: 5, gone) == nil {
            throw Fail(5, "the file dialog is still open: `read` shows it; press its Open or Cancel button")
        }
    }

    /// Types a file name into the save dialog's name field: the first text field outside lists and
    /// sheets. Returns the note `typeInto` makes when the field ends up showing something else.
    @discardableResult
    private static func fillName(_ name: String, in dialog: AXUIElement, _ target: Target) throws -> String? {
        func walk(_ el: AXUIElement, _ depth: Int) -> AXUIElement? {
            guard depth < 12 else { return nil }
            for child in el.children {
                let role = child.string(kAXRoleAttribute) ?? ""
                if ["AXOutline", "AXTable", "AXSheet", "AXList"].contains(role) { continue }
                if role == "AXTextField", child.string(kAXSubroleAttribute) != "AXSearchField" { return child }
                if let hit = walk(child, depth + 1) { return hit }
            }
            return nil
        }
        guard let field = walk(dialog, 0), let f = field.frame else { throw Fail(5, "the save dialog has no name field") }
        return try Borrow.run(target) { try typeInto(field, f, name, target, label: "the name field") }
    }

    static func upload(_ a: Args) throws -> String {
        guard let id = a.pos.first.flatMap(Int.init), a.pos.count >= 2 else { throw Fail(5, "upload <id> <path>") }
        // Agents quote paths, so the shell never expands ~ for them (K1).
        let path = (a.pos.dropFirst().joined(separator: " ") as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { throw Fail(5, "file not found: \(path)") }
        guard !isDir.boolValue else { throw Fail(5, "\(path) is a folder: upload takes a file") }
        let (session, target, old) = try prepare()
        let (el, e) = try resolve(id, target)
        try gate(session, target, e, "upload \(path) through \(e.short)", warn: ["sends a file to \(hostOf(target.url) ?? session.app)"])
        try beforeAction(session, url: target.url)
        let app = appElement(session.pid)
        let before = fileDialogs(app)
        // A picker already open on the session window, say from an earlier attempt, is used as it is.
        var found: AXUIElement? = before.first { $0.string(kAXRoleAttribute) == "AXSheet" }
        if found == nil {
            try Borrow.run(target) { try realClick(el?.frame ?? e.rect) }
            found = poll(timeout: 6) { fileDialogs(app).first { d in !before.contains { CFEqual($0, d) } } }
        }
        guard let dialog = found else { throw Fail(5, "no file dialog appeared after clicking \(e.short)") }
        try choosePath(path, in: dialog, app: app, target, open: true)
        return try finish("upload", session, target, old, extra: ["uploaded \(path)"], log: ["id": id, "path": path, "label": e.label, "name": e.name])
    }

    static func download(_ a: Args) throws -> String {
        guard let id = a.pos.first.flatMap(Int.init), a.pos.count >= 2 else { throw Fail(5, "download <id> <path>") }
        let path = (a.pos.dropFirst().joined(separator: " ") as NSString).expandingTildeInPath
        let (session, target, old) = try prepare()
        let (el, e) = try resolve(id, target)
        let source = el?.string("AXURL") ?? e.value ?? ""
        try gate(session, target, e, "download \(e.short) to \(path)", details: ["source: \(source)"])
        try beforeAction(session, url: target.url)
        let app = appElement(session.pid)
        let before = fileDialogs(app)
        // An older file already at the path must not count as this download (B13).
        let started = Date()
        let modified = { () -> Bool? in
            let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            return date.map { $0 >= started.addingTimeInterval(-1) } == true ? true : nil
        }
        try Borrow.run(target) {
            try realClick(el?.frame ?? e.rect, right: true)
            Pace.sleep(0.4)
            let item = poll(timeout: 4) {
                findFirst(app, limit: 9000) { i in
                    guard i.role == "AXMenuItem", let t = i.title?.lowercased() else { return false }
                    return Config.current.downloadMenu.contains { t.contains($0) }
                }
            }
            guard let f = item?.frame else {
                try? Keys.press("esc")
                throw Fail(5, "no download item in the context menu for \(id); add its label to [agent] download_menu")
            }
            try realClick(f)
        }
        let saved: Bool
        if let dialog = poll(timeout: 6, { fileDialogs(app).first { d in !before.contains { CFEqual($0, d) } } }) {
            try choosePath((path as NSString).deletingLastPathComponent, in: dialog, app: app, target, open: false)
            try fillName((path as NSString).lastPathComponent, in: dialog, target)
            // The panel's default button is Save in any language; the title is the fallback.
            let window = dialog.attr(kAXWindowAttribute) as! AXUIElement? ?? dialog
            let button = dialog.attr(kAXDefaultButtonAttribute) as! AXUIElement? ?? window.attr(kAXDefaultButtonAttribute) as! AXUIElement?
                ?? findFirst(dialog, limit: 4000, where: { $0.role == "AXButton" && ($0.title ?? "").lowercased() == "save" })
            if let f = button?.frame {
                try Borrow.run(target) { try realClick(f) }
            }
            saved = poll(timeout: 10, modified) != nil
        } else {
            saved = false
        }
        guard saved else {
            // Some browsers save straight to Downloads without asking.
            throw Fail(5, "nothing new was saved at \(path). The browser may have saved it to Downloads without asking; check there")
        }
        return try finish("download", session, target, old, extra: ["saved " + path],
                      log: ["id": id, "path": path, "source": source, "label": e.label, "name": e.name])
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
        return render(snap, app: session.app, lines: elements.map(\.line), max: try a.count("max", 80))
    }

    static func shot(_ a: Args) throws -> String {
        try Capture.ensure()
        let (session, target, old) = try prepare()
        var (image, frame) = try capture(session, target, a)
        var marked: Snapshot?
        if a.has("marks") {
            // A fresh read with the ids of the last list, so the boxes match what the caller has seen.
            let snap = keepIds(old, readSnapshot(target))
            SnapStore.save(snap)
            image = Capture.mark(image, frame: frame, snap.elements)
            marked = snap
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        let url = Store.runFolder().appendingPathComponent("shots/shot-\(formatter.string(from: Date())).png")
        try Capture.save(image, to: url)
        Sessions.capShots(Store.runFolder())
        Store.log(["cmd": "shot", "path": url.path, "marks": marked != nil])
        return url.path + (marked.map { " · snap \($0.snap) · \($0.elements.filter { !$0.offscreen }.count) ids marked" } ?? "")
    }

    static func log(_ a: Args) throws -> String {
        if a.has("session") { return try Sessions.story(a.value("session")) }
        let tail = try a.count("tail", 20)
        let rows = Sessions.rows(Store.runFolder())
        guard !rows.isEmpty else { return "no steps yet" }
        var out: [String] = []
        for obj in rows.suffix(tail) {
            // "2026-11-01T12:34:56+10:00" → "12:34:56", in the local time the stamp was written in
            let time = (obj["ts"] as? String).flatMap { $0.split(separator: "T").last.map { String($0.prefix(8)) } } ?? ""
            let cmd = obj["cmd"] as? String ?? obj["gate"] as? String
                ?? (obj["proposed"] as? String).map { "proposed \($0)" }
                ?? (obj["error"] as? String).map { "\(obj["failed"] ?? "?") failed: \($0.split(separator: "\n").first ?? "")" } ?? "step"
            var bits = ["\(time)", cmd]
            if let snap = obj["snap"] { bits.append("snap \(snap)") }
            if let diff = obj["diff"] { bits.append("\(diff)") }
            if let id = obj["id"] { bits.append("#\(id)") }
            if let app = obj["app"] { bits.append("\(app)") }
            if let url = obj["url"], !(url as? String ?? "").isEmpty { bits.append("\(url)") }
            if let found = obj["found"] { bits.append(found as? Bool == true ? "found" : "not found") }
            if let approved = obj["approved"] { bits.append(approved as? Bool == true ? "approved" : "denied") }
            if let ms = obj["ms"] as? Int {
                let waits = (obj["waits"] as? [String: Int] ?? [:]).sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }
                bits.append("\(ms) ms" + (waits.isEmpty ? "" : " (\(waits.joined(separator: ", ")))"))
            }
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

    static func render(_ s: Snapshot, app: String, lines: [String], max: Int) -> String {
        let shown = lines.prefix(Swift.max(max, 0))
        var out = "<screen>\n" + header(s, app: app, shown: shown.count) + "\n"
        out += shown.joined(separator: "\n")
        if lines.count > shown.count { out += "\n… \(lines.count - shown.count) more, use --max or --filter" }
        return out + "\n</screen>"
    }
}
