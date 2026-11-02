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
        // It holds URLs, page titles, screenshots and maybe an API key: this user only.
        chmod(url.path, 0o700)
        return url
    }()

    /// The browser VM this process works for (`APPRENTICE_VM`, or `apprentice --vm <name> …`), one per
    /// agent session; nil is this Mac and the default VM.
    static let vmName: String? = {
        let raw = ProcessInfo.processInfo.environment["APPRENTICE_VM"] ?? ""
        let name = String(raw.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(40))
        return name.isEmpty ? nil : name
    }()

    /// One daemon runs per VM, each with its own socket and its own session, snapshot, pending approval
    /// and pacing, so agent sessions on different VMs never touch each other's. Sites, budgets, logs,
    /// playbooks and settings stay in `dir`, shared by all of them.
    static let stateDir: URL = {
        guard let vmName else { return dir }
        let url = dir.appendingPathComponent("vms/\(vmName)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Files that belong to one agent session; every other file is shared.
    static let perSession: Set<String> = ["session.json", "snap.json", "pending.json", "pace.json"]

    static func url(_ name: String) -> URL { (perSession.contains(name) ? stateDir : dir).appendingPathComponent(name) }

    static var socketPath: String { stateDir.appendingPathComponent("sock").path }
    static var pidPath: String { stateDir.appendingPathComponent("daemon.pid").path }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(name))
    }

    /// Runs `body` holding a lock on `name` that other apprentice processes respect, for a shared file
    /// that several VMs' daemons read, change and write back.
    static func locked<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        try locked(at: dir.appendingPathComponent(name), body)
    }

    /// The same lock for a file outside the state folder, such as a project's.
    static func locked<T>(at file: URL, _ body: () throws -> T) rethrows -> T {
        let fd = open(file.path + ".lock", O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        return try body()
    }

    private static let dayFormat: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    static func day() -> String {
        dayFormat.timeZone = .current
        return dayFormat.string(from: Date())
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

    /// The model driving the current command: the caller's `APPRENTICE_MODEL` or `run --model`, which the
    /// daemon takes from each `Request`. Every row carries it, so `grow` and flows can tell models apart.
    static var model: String? = Request.callerModel
    private static let logLock = NSLock()

    static func log(_ entry: [String: Any]) {
        let session = Session.stored
        if let session, Privacy.blocked(session, url: entry["url"] as? String) { return }
        var e = entry
        e["ts"] = stamp.string(from: Date())
        if let model, e["model"] == nil { e["model"] = model }
        // A command's row carries how long it took and where the time went.
        if entry["cmd"] != nil {
            for (k, v) in Timing.fields where e[k] == nil { e[k] = v }
        }
        // Questions are answered off the command queue, so two rows can arrive at once.
        logLock.lock()
        defer { logLock.unlock() }
        appendLine(e, to: runFolder(session).appendingPathComponent("steps.jsonl"))
    }

    /// Appends one JSON object as a line of a `.jsonl` file.
    static func appendLine(_ row: [String: Any], to file: URL) {
        guard var line = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        line.append(0x0A)
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

    /// The JSON objects in a `.jsonl` file, skipping lines that don't parse.
    static func readLines(_ file: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    static func pruneLogs(days: Int = 30) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: Sessions.runs, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
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
        // The app's own window is scrubbed by name, never by a site whose URL happens to say "apprentice".
        if session.bundle == AppBundle.identifier || session.app.lowercased() == "apprentice" { return true }
        let text = [session.bundle ?? "", session.app, session.url ?? "", url ?? ""].joined(separator: " ").lowercased()
        return names.contains { text.contains($0) }
    }
}

struct Session: Codable {
    static func newId() -> String { String(UUID().uuidString.prefix(6)).lowercased() }

    var app: String
    var bundle: String?
    var pid: pid_t
    var wid: CGWindowID
    var allow: [String]
    var id: String?
    var url: String?
    /// Chosen in the start-up options window; nil follows `[agent] ui_only`.
    var uiOnly: Bool?
    /// The session is in the Linux VM (`Remote`): its browser or another Linux app, not a window on this Mac.
    var vm: Bool?

    var isBrowser: Bool {
        if vm == true { return app == "Chromium" }
        guard let bundle else { return false }
        return Session.webHandlers.contains(bundle) || Config.current.browsers.contains(bundle)
    }

    static func handlesWeb(_ bundle: String) -> Bool { webHandlers.contains(bundle) || Config.current.browsers.contains(bundle) }

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
        Limits.notePage()
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
    /// Times of each budgeted action, per site and kind, kept for 8 days (`Budgets`).
    var kinds: [String: [String: [Double]]]?
    /// Sites that signalled a rate limit, and how long apprentice leaves them alone (`Cooldown`).
    var cooling: [String: Cooling]?
    /// Sites showing a challenge only the user can complete, with the marker that was seen.
    var challenged: [String: String]?
    /// When the window last arrived on a new page, for the dwell before acting on it.
    var pageAt: Double?
    /// Web actions in the current burst, and how many the burst may hold before a rest.
    var burst: Int?
    var burstAt: Int?
    /// Each site's current sitting and any break it is on (`session_max_min`), shared by every VM's daemon.
    var sittings: [String: Sitting]?
    /// Actions per site today (`actions_per_day`).
    var days: [String: DayCount]?

    struct Sitting: Codable {
        var start: Double
        var last: Double
        var breakUntil: Double
    }

    struct DayCount: Codable {
        var day: String
        var count: Int
    }

    struct Cooling: Codable {
        var until: Double
        var strikes: Int
        var last: Double
    }

    /// This agent session's own rhythm (`pace.json`); everything else here is per site and shared by
    /// every VM's daemon, so budgets and cooldowns hold across them.
    struct SessionPace: Codable {
        var lastAction: Double = 0
        var pageAt: Double?
        var burst: Int?
        var burstAt: Int?
    }

    static var stored: Limits {
        var l = Store.load(Limits.self, "limits.json") ?? Limits()
        // Before pace.json, the default daemon kept its rhythm in limits.json; a VM's daemon starts fresh.
        let p = Store.load(SessionPace.self, "pace.json")
            ?? (Store.vmName == nil ? SessionPace(lastAction: l.lastAction, pageAt: l.pageAt, burst: l.burst, burstAt: l.burstAt) : SessionPace())
        (l.lastAction, l.pageAt, l.burst, l.burstAt) = (p.lastAction, p.pageAt, p.burst, p.burstAt)
        return l
    }

    /// Reads, changes and writes the limits under a lock other daemons respect, so two VMs counting
    /// actions on one site never lose each other's. Keep waits out of `body`: they would hold the lock.
    @discardableResult
    static func update<T>(_ body: (inout Limits) throws -> T) rethrows -> T {
        try Store.locked("limits.json") {
            var l = stored
            let result = try body(&l)
            var shared = l
            (shared.lastAction, shared.pageAt, shared.burst, shared.burstAt) = (0, nil, nil, nil)
            Store.save(shared, "limits.json")
            Store.save(SessionPace(lastAction: l.lastAction, pageAt: l.pageAt, burst: l.burst, burstAt: l.burstAt), "pace.json")
            return result
        }
    }

    static func notePage() {
        update { $0.pageAt = Date().timeIntervalSince1970 }
    }

    static func checkNavigation(_ url: URL) throws {
        let cfg = Config.current.pace
        let wait = try update { l -> Double in
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
        var wait = 0.0
        if let last = times.last, now - last < cfg.navGap { wait = cfg.navGap - (now - last) }
        // Counted at the time it will happen, after the wait.
        times.append(now + wait)
        loaded.append(key)
        l.navs[domain] = times
        l.navURLs = l.navURLs ?? [:]
        l.navURLs?[domain] = loaded
        return wait
        }
        if wait > 0 { Timing.measure("gap") { Pace.sleep(wait) } }
    }

    /// Holds actions on a host to its per-minute cap, then waits out the pause between web actions. One load, one save.
    /// What a person's day allows on a site right now: nil, or why not. Quiet hours, a sitting that has
    /// run its length (which starts a break), and the daily count (BOT_DETECTION S4). Counts the action.
    static func sittingRefusal(_ l: inout Limits, host: String, cfg: PaceConfig, now: Double) -> String? {
        let date = Date(timeIntervalSince1970: now)
        if cfg.isQuiet(hour: Calendar.current.component(.hour, from: date)) {
            return "quiet hours: apprentice takes no actions on \(host) between \(Int(cfg.quietFrom)):00 and \(Int(cfg.quietTo) % 24):00 local time ([pace] quiet_hours). Stop here and tell the user; reading still works"
        }
        var sittings = l.sittings ?? [:]
        var s = sittings[host] ?? Sitting(start: now, last: 0, breakUntil: 0)
        if s.breakUntil > now {
            return "break: \(host) is resting until \(Site.time(s.breakUntil)) after a long sitting ([pace] session_max_min). Do other work or tell the user"
        }
        // A pause as long as the shortest break is a break already: a new sitting starts.
        if s.last == 0 || now - s.last >= cfg.breakMin * 60 { s.start = now }
        if cfg.sittingMax > 0, now - s.start >= cfg.sittingMax * 60 {
            s.breakUntil = now + Rand.uniform(cfg.breakMin...cfg.breakMax) * 60
            s.start = s.breakUntil
            sittings[host] = s
            l.sittings = sittings
            return "break: \(host) has been used for \(Int(cfg.sittingMax)) min in one sitting, so apprentice rests it until \(Site.time(s.breakUntil)) ([pace] session_max_min). Do other work or tell the user"
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: date)
        var days = l.days ?? [:]
        var d = days[host].flatMap { $0.day == today ? $0 : nil } ?? DayCount(day: today, count: 0)
        if cfg.actionsPerDay > 0, Double(d.count) >= cfg.actionsPerDay {
            return "daily cap: \(d.count) actions on \(host) today ([pace] actions_per_day = \(Int(cfg.actionsPerDay))). Stop here and tell the user; it resets at midnight"
        }
        d.count += 1
        days[host] = d
        l.days = days
        s.last = now
        sittings[host] = s
        l.sittings = sittings
        return nil
    }

    static func beforeAction(host: String?, web: Bool) throws {
        guard web || !(host ?? "").isEmpty else { return }
        let cfg = Config.current.pace
        let waits = update { l -> (gap: Double, rest: Double, refusal: String?) in
        let now = Date().timeIntervalSince1970
        var gapWait = 0.0, restWait = 0.0, minuteWait = 0.0
        if let host, !host.isEmpty, let refusal = sittingRefusal(&l, host: host, cfg: cfg, now: now) {
            Events.add(host, "pace", ["reason": String(refusal.prefix(while: { $0 != ":" }))])
            // Thrown after the file is written, so a break that starts here holds for every daemon.
            return (0, 0, refusal)
        }
        if let host, !host.isEmpty {
            var times = (l.acts[host] ?? []).filter { now - $0 < 60 }.sorted()
            // At the cap, wait (under a minute) until the oldest action leaves the window rather than
            // refuse an approved step: the rate stays the same and the task goes on.
            let cap = max(1, Int(cfg.actionsPerMin))
            if times.count >= cap { minuteWait = max(0, times[times.count - cap] + 60 - now) }
            // Record this action at the time it will happen, or the per-minute cap can never be reached.
            times.append(now + minuteWait)
            l.acts[host] = times
        }
        if web {
            let gap = Rand.uniform(cfg.betweenMin...cfg.betweenMax)
            if l.lastAction > 0 {
                let since = now - l.lastAction
                if since < gap { gapWait = gap - since }
            }
            // A profile with `burst` rests after a run of quick actions, as a person pauses between bursts.
            if cfg.burstMax > 0 {
                let count = l.lastAction > 0 && now - l.lastAction < 30 ? (l.burst ?? 0) + 1 : 1
                let limit = l.burstAt ?? Rand.uniform(Int(cfg.burstMin)...Int(cfg.burstMax))
                if count > limit {
                    restWait = Rand.uniform(cfg.restMin...cfg.restMax)
                    l.burst = 1
                    l.burstAt = Rand.uniform(Int(cfg.burstMin)...Int(cfg.burstMax))
                } else {
                    l.burst = count
                    l.burstAt = limit
                }
            }
            l.lastAction = now + max(gapWait, minuteWait) + restWait
        }
        return (max(gapWait, minuteWait), restWait, nil)
        }
        if let refusal = waits.refusal { throw Fail(4, refusal) }
        if waits.gap + waits.rest > 0 { Timing.measure("gap") { Pace.sleep(waits.gap + waits.rest) } }
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

    /// The warning only the user can approve: `approve` refuses it unless it comes from `confirm` or the menu.
    static let credential = "a password or security-code field"

    static func matches(_ text: String) -> Bool { !wordsIn(text).isEmpty }

    /// The gate-list words in `text`.
    static func wordsIn(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)).intersection(words)
    }

    static func sensitivePage(_ url: String?) -> Bool {
        guard let u = url?.lowercased() else { return false }
        return ["/settings", "/account", "/billing", "/security", "/admin", "/password"].contains { u.contains($0) }
    }

    /// The warning on a step `[gate] user_only` names (a payment, a CAPTCHA, closing an account):
    /// like a credential, only the user can approve it.
    static let userOnlyStep = "only the user approves this ([gate] user_only)"

    /// The warnings `approve` takes only from the user (`confirm`, the menu bar), even inside a flow.
    static let forUser: Set<String> = [credential, userOnlyStep]

    static func userOnly(_ e: Element?) -> Bool {
        guard let e else { return false }
        let padded = " " + "\(e.label) \(e.name)".lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ") + " "
        return Config.current.userOnly.contains { padded.contains(" \($0) ") }
    }

    /// Why an action deserves extra care. The caller can add `--gate`, never remove a warning.
    static func warnings(_ element: Element?, _ t: Page, force: Bool = false) -> [String] {
        var out: [String] = []
        if force { out.append("marked --gate") }
        if sensitivePage(t.url) || sensitivePage(t.title) { out.append("settings, account or billing page") }
        if let e = element, matches(e.name) || matches(e.label) { out.append("may be irreversible: \(e.label) \"\(e.name)\"") }
        // Credentials always stop for a person (I3): `approve` takes them only from the user. A saved
        // secret or a code the user gives, on a site where they turned login on, is the agent's to approve.
        if let e = element, !Login.secretStep(t.url) {
            let n = e.name.lowercased()
            if e.label == "password" || ["password", "passcode", "2fa", "one-time", "verification code"].contains(where: n.contains) {
                out.append(credential)
            }
        }
        if userOnly(element) { out.append(userOnlyStep) }
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
        /// Set when the proposal was put in front of the user, who may take longer than `ttl` to answer.
        var until: Double?
        var warnings: [String]?
        /// The terminal tab or schedule the proposal came from, so the app shows its banner there.
        var tab: String?

        var expires: Double { until ?? at + Approvals.ttl }
        /// A credential step runs only once the user approves it themselves.
        var needsUser: Bool { warnings?.contains(where: Gate.forUser.contains) == true }
    }

    static let ttl = 300.0
    /// How many proposals wait at once. A new one no longer drops the one the user is deciding on.
    static let kept = 5
    /// How long a proposal stays open once it is handed to the user in the chat or on their phone.
    static let userTTL = 3600.0
    /// The request being dispatched, and the approved one while it runs.
    static var request = Request(cmd: "")
    static var granted: Pending?
    /// The token the user is approving right now, in the `confirm` window or the menu bar.
    static var byUser: String?
    /// The user acts in person: approving in the window or the menu bar, or a click in the app (its `user`
    /// flag survives only from the signed bundle, `Peer.isApp`).
    static var fromUser: Bool { byUser != nil || request.user == true }

    /// The proposals still open, oldest first, each answered by its own token.
    static var all: [Pending] {
        let now = Date().timeIntervalSince1970
        return stored.filter { now < $0.expires }
    }
    /// The newest open proposal.
    static var pending: Pending? { all.last }
    static func find(_ token: String) -> Pending? { all.last { $0.token == token } }

    /// Every saved proposal, expired ones too. An older pending.json held a single one.
    private static var stored: [Pending] {
        Store.load([Pending].self, "pending.json") ?? Store.load(Pending.self, "pending.json").map { [$0] } ?? []
    }

    private static func store(_ list: [Pending]) {
        if list.isEmpty { Store.remove("pending.json") } else { Store.save(Array(list.suffix(kept)), "pending.json") }
    }

    static func add(_ p: Pending) { store(all.filter { $0.token != p.token } + [p]) }
    static func drop(_ token: String) { store(all.filter { $0.token != token }) }

    /// Keeps `token` open for `seconds` more while the user decides; it never shortens one.
    static func extend(_ token: String, by seconds: Double) {
        let until = Date().timeIntervalSince1970 + seconds
        store(all.map { p in
            var p = p
            if p.token == token { p.until = max(p.expires, until) }
            return p
        })
    }

    /// Set while an approved `do` runs its steps: the plan was approved as a whole.
    static var planActive = false
    /// Whether the plan showed the step now running with a `⚠` line.
    static var planFlagged = false

    /// What the approved plan covers of a step's live warnings. A step the plan did not flag, or one on a
    /// password field, is proposed on its own, so a flow never runs a risk the approver did not see.
    static func planCovers(_ warnings: [String]) -> Bool {
        warnings.isEmpty || (planFlagged && !warnings.contains(where: Gate.forUser.contains))
    }

    static var approved: Bool {
        if planActive { return true }
        guard let g = granted else { return false }
        return g.cmd == request.cmd && g.args == request.args
    }

    /// Returns when the current request was approved; otherwise saves a proposal and throws exit 8.
    static func check(_ summary: String, details: [String], warnings: [String], element: String? = nil) throws {
        if KillSwitch.halted { throw Fail(6, "stopped: " + KillSwitch.message) }
        if approved, !planActive || planCovers(warnings) {
            // The id may point at something else after a fresh read: then the approval does not apply.
            if let want = granted?.element, let element, want != element {
                throw Fail(2, "stale: the screen changed and the id now points at something else. Run the command again")
            }
            return
        }
        let token = String(UUID().uuidString.prefix(4)).lowercased()
        let p = Pending(token: token, cmd: request.cmd, args: request.args, summary: summary,
                        snap: SnapStore.current?.snap, at: Date().timeIntervalSince1970, element: element, warnings: warnings,
                        tab: request.tab)
        add(p)
        Store.log(["proposed": summary, "token": token, "warnings": warnings])
        var out = ["approve? \(summary)"] + details.map { "  \($0)" } + warnings.map { "⚠ \($0)" }
        out.append("nothing was done. approve: apprentice approve \(token) · deny: apprentice deny \(token)")
        throw Fail(8, out.joined(separator: "\n"))
    }

    /// Takes the pending proposal for `token`. Reading the screen first is fine: the element is checked
    /// again when the approved command runs (I1).
    static func take(_ token: String) throws -> Pending {
        guard let p = stored.last(where: { $0.token == token }) else { throw Fail(5, "no pending action \(token): run the command again") }
        drop(token)
        guard Date().timeIntervalSince1970 < p.expires else { throw Fail(5, "approval \(token) expired: run the command again") }
        return p
    }
}
