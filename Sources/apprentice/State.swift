import AppKit
import Foundation
import ApplicationServices

struct Fail: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    init(_ code: Int32, _ message: String) {
        self.code = code
        self.message = message
    }
    var description: String { message }
}

enum Store {
    static let dir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // APPRENTICE_HOME puts all state somewhere else, e.g. to try a change without touching yours.
        let custom = ProcessInfo.processInfo.environment["APPRENTICE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let url = custom ?? home.appendingPathComponent(".apprentice")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var socketPath: String { dir.appendingPathComponent("sock").path }
    static var pidPath: String { dir.appendingPathComponent("daemon.pid").path }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }

    static func day() -> String {
        ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
    }

    /// Local time with its offset, matching the local-date run folders (B16).
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        // Milliseconds: `grow` splits a run into the tool's time and the agent's, which whole seconds blur.
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// One folder per session, as in `runs/<date>-<session>`, with a daily folder as fallback.
    static func runFolder(_ session: Session? = Session.stored) -> URL {
        let name = session?.id.map { "\(day())-\($0)" } ?? day()
        return dir.appendingPathComponent("runs/\(name)")
    }

    static func log(_ entry: [String: Any]) {
        let session = Session.stored
        if let session, Privacy.blocked(session, url: entry["url"] as? String) { return }
        var e = entry
        e["ts"] = stamp.string(from: Date())
        // A command's row carries how long it took and where the time went.
        if entry["cmd"] != nil {
            for (k, v) in Timing.fields where e[k] == nil { e[k] = v }
        }
        guard var line = try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let file = runFolder(session).appendingPathComponent("steps.jsonl")
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            // First row of the day, or the folder was removed while the daemon ran.
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? line.write(to: file)
        }
    }

    static func pruneLogs(days: Int = 30) {
        let runs = dir.appendingPathComponent("runs")
        guard let items = try? FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for item in items {
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if date < cutoff { try? FileManager.default.removeItem(at: item) }
        }
    }
}

enum Privacy {
    static let names = ["1password", "keychain", "bitwarden", "lastpass", "authenticator", "wallet", "bank", "health", "hospital"]

    /// `url` is the page being logged, which may differ from the page the session last saw.
    static func blocked(_ session: Session, url: String? = nil) -> Bool {
        let text = [session.bundle ?? "", session.app, session.url ?? "", url ?? ""].joined(separator: " ").lowercased()
        return names.contains { text.contains($0) }
    }
}

struct Session: Codable {
    var app: String
    var bundle: String?
    var pid: pid_t
    var wid: CGWindowID
    var allow: [String]
    var id: String?
    var url: String?
    /// Chosen in the start-up options window; nil follows `[agent] ui_only`.
    var uiOnly: Bool?

    var isBrowser: Bool {
        guard let bundle else { return false }
        return Session.webHandlers.contains(bundle) || Config.current.browsers.contains(bundle)
    }

    /// Every installed app that can open https links, so any browser counts without a fixed list.
    private static let webHandlers: Set<String> = {
        guard let probe = URL(string: "https://example.com") else { return [] }
        return Set(NSWorkspace.shared.urlsForApplications(toOpen: probe).compactMap { Bundle(url: $0)?.bundleIdentifier })
    }()

    /// The daemon is the only writer of session.json, so it keeps the last value in memory.
    private static var cached: Session?

    static var stored: Session? {
        if cached == nil { cached = Store.load(Session.self, "session.json") }
        return cached
    }

    func save() {
        Store.save(self, "session.json")
        Session.cached = self
    }

    /// Records the page the window is on now, so privacy checks and logs follow navigation.
    mutating func track(_ url: String?) {
        guard let url, url != self.url else { return }
        self.url = url
        save()
    }

    static func current() throws -> Session {
        guard let s = stored else {
            throw Fail(5, "no session: run `apprentice session --app Safari`")
        }
        // macOS reuses pids, so the app at that pid must also be the one attached (B12).
        guard let app = NSRunningApplication(processIdentifier: s.pid),
              s.bundle == nil || app.bundleIdentifier == s.bundle else {
            throw Fail(5, "\(s.app) is no longer running: start a new session")
        }
        return s
    }

    /// Domains and app names in the allowlist; an empty list means the session is unrestricted.
    func allows(url: String?) -> Bool {
        guard !allow.isEmpty else { return true }
        let patterns = allow.map { $0.lowercased() }
        if patterns.contains("*") { return true }
        // The app's own name allows its windows that have no page; a page must match a domain.
        guard let host = url.flatMap(URL.init(string:))?.host?.lowercased() else {
            return patterns.contains(app.lowercased())
        }
        return patterns.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// Where the current command's time goes: waiting for the person (`idle`), pacing gaps (`gap`), cursor
/// travel (`move`), keystrokes (`type`) and waiting for the screen to settle (`settle`). `Store.log`
/// adds the totals to the command's row, and `grow` reads them back to split a slow run into the
/// tool's share and the agent's.
enum Timing {
    static var started: Date?
    static var waits: [String: Double] = [:]

    static func begin() {
        started = Date()
        waits = [:]
    }

    static func add(_ what: String, _ seconds: Double) {
        if seconds > 0 { waits[what, default: 0] += seconds }
    }

    static func measure<T>(_ what: String, _ body: () throws -> T) rethrows -> T {
        let t = Date()
        defer { add(what, Date().timeIntervalSince(t)) }
        return try body()
    }

    static var fields: [String: Any] {
        guard let started else { return [:] }
        var f: [String: Any] = ["ms": Int(Date().timeIntervalSince(started) * 1000)]
        if !waits.isEmpty { f["waits"] = waits.mapValues { Int($0 * 1000) } }
        return f
    }
}

/// Per-domain navigation limits and the pause between web actions.
struct Limits: Codable {
    var navs: [String: [Double]] = [:]
    /// The URL of each entry in `navs`, so the reload cap counts loads of one URL and not the whole domain.
    var navURLs: [String: [String]]?
    var acts: [String: [Double]] = [:]
    var lastAction: Double = 0

    static func checkNavigation(_ url: URL) throws {
        let cfg = Config.current.pace
        var l = Store.load(Limits.self, "limits.json") ?? Limits()
        let domain = url.host ?? "local"
        let key = url.absoluteString
        let now = Date().timeIntervalSince1970
        let marks = l.navs[domain] ?? []
        let urls = l.navURLs?[domain] ?? []
        // Keep the loads still inside the window, each with the URL it loaded.
        var times: [Double] = []
        var loaded: [String] = []
        for (i, mark) in marks.enumerated() where now - mark < cfg.reloadWindow {
            times.append(mark)
            loaded.append(i < urls.count ? urls[i] : "")
        }
        let reloads = loaded.filter { $0 == key }.count
        if Double(reloads) >= cfg.reloadMax {
            throw Fail(4, "refresh limit: \(reloads) loads of \(key) in \(Int(cfg.reloadWindow)) s")
        }
        if let last = times.last, now - last < cfg.navGap {
            Timing.measure("gap") { Pace.sleep(cfg.navGap - (now - last)) }
        }
        times.append(Date().timeIntervalSince1970)
        loaded.append(key)
        l.navs[domain] = times
        l.navURLs = l.navURLs ?? [:]
        l.navURLs?[domain] = loaded
        Store.save(l, "limits.json")
    }

    /// Rate-limits actions on a host, then waits out the pause between web actions. One load, one save.
    static func beforeAction(host: String?, web: Bool) throws {
        guard web || !(host ?? "").isEmpty else { return }
        let cfg = Config.current.pace
        var l = Store.load(Limits.self, "limits.json") ?? Limits()
        let now = Date().timeIntervalSince1970
        if let host, !host.isEmpty {
            var times = (l.acts[host] ?? []).filter { now - $0 < 60 }
            if Double(times.count) >= cfg.actionsPerMin {
                throw Fail(4, "rate limit: \(times.count) actions on \(host) in the last minute")
            }
            // Record this action, or the per-minute cap can never be reached.
            times.append(now)
            l.acts[host] = times
        }
        if web {
            let gap = Double.random(in: cfg.betweenMin...cfg.betweenMax)
            if l.lastAction > 0 {
                let since = now - l.lastAction
                if since < gap { Timing.measure("gap") { Pace.sleep(gap - since) } }
            }
            l.lastAction = Date().timeIntervalSince1970
        }
        Store.save(l, "limits.json")
    }
}

enum Gate {
    /// Nothing here is a complete sentence on purpose: a label containing any of these words is flagged irreversible.
    static let words: Set<String> = [
        "send", "post", "publish", "like", "follow", "comment", "submit", "save", "update", "upload",
        "pay", "buy", "delete", "remove", "confirm", "create", "commit", "merge", "archive", "transfer",
        "install", "allow", "accept", "agree", "enable", "subscribe", "order", "checkout", "apply", "invite",
        "share", "grant", "donate", "reset", "sign", "register", "book", "reserve", "cancel", "unsubscribe",
    ]

    static func matches(_ text: String) -> Bool {
        let tokens = text.lowercased().split(whereSeparator: { !$0.isLetter })
        return tokens.contains { words.contains(String($0)) }
    }

    static func sensitivePage(_ url: String?) -> Bool {
        guard let u = url?.lowercased() else { return false }
        return ["/settings", "/account", "/billing", "/security", "/admin", "/password"].contains { u.contains($0) }
    }

    /// Why an action deserves extra care. The caller can add `--gate`, never remove a warning.
    static func warnings(_ element: Element?, _ t: Target, force: Bool = false) -> [String] {
        var out: [String] = []
        if force { out.append("marked --gate") }
        if sensitivePage(t.url) || sensitivePage(t.title) { out.append("settings, account or billing page") }
        if let e = element, matches(e.name) || matches(e.label) { out.append("may be irreversible: \(e.label) \"\(e.name)\"") }
        // Credentials always stop for a person (I3).
        if let e = element {
            let n = e.name.lowercased()
            if e.label == "password" || ["password", "passcode", "2fa", "one-time", "verification code"].contains(where: n.contains) {
                out.append("a password or security-code field")
            }
        }
        // Controls inside a dialog or sheet usually confirm something (I2).
        if t.scope == "sheet" { out.append("inside a dialog") }
        return out
    }
}

/// A state-changing command first returns a proposal (exit 8) and acts only once the caller
/// runs `apprentice approve <token>`. The caller is an LLM, which decides or asks its user.
enum Approvals {
    struct Pending: Codable {
        var token: String
        var cmd: String
        var args: [String]
        var summary: String
        var snap: Int?
        var at: Double
        /// The element the proposal names (label|name), checked again on approval.
        var element: String?
    }

    static let ttl = 300.0
    /// The request being dispatched, and the approved one while it runs.
    static var request = Request(cmd: "")
    static var granted: Pending?

    static var pending: Pending? { Store.load(Pending.self, "pending.json") }

    /// Set while an approved `do` runs its steps: the plan was approved as a whole.
    static var planActive = false

    static var approved: Bool {
        if planActive { return true }
        guard let g = granted else { return false }
        return g.cmd == request.cmd && g.args == request.args
    }

    /// Returns when the current request was approved; otherwise saves a proposal and throws exit 8.
    static func check(_ summary: String, details: [String], warnings: [String], element: String? = nil) throws {
        if approved {
            // The id may point at something else after a fresh read: then the approval does not apply.
            if let want = granted?.element, let element, want != element {
                throw Fail(2, "stale: the screen changed and the id now points at something else. Run the command again")
            }
            return
        }
        let token = String(UUID().uuidString.prefix(4)).lowercased()
        let p = Pending(token: token, cmd: request.cmd, args: request.args, summary: summary,
                        snap: SnapStore.current?.snap, at: Date().timeIntervalSince1970, element: element)
        Store.save(p, "pending.json")
        Store.log(["proposed": summary, "token": token, "warnings": warnings])
        var out = ["approve? \(summary)"] + details.map { "  \($0)" } + warnings.map { "⚠ \($0)" }
        out.append("nothing was done. approve: apprentice approve \(token) · deny: apprentice deny \(token)")
        throw Fail(8, out.joined(separator: "\n"))
    }

    /// Takes the pending proposal for `token`. Reading the screen first is fine: the element is checked
    /// again when the approved command runs (I1).
    static func take(_ token: String) throws -> Pending {
        guard let p = pending, p.token == token else { throw Fail(5, "no pending action \(token): run the command again") }
        guard Date().timeIntervalSince1970 - p.at < ttl else {
            Store.remove("pending.json")
            throw Fail(5, "approval \(token) expired: run the command again")
        }
        Store.remove("pending.json")
        return p
    }
}
