import AppKit
import Foundation

/// Working within each site's rules (`SPEC.md`, Site rules): per-kind budgets, a cooldown when a site
/// throttles the account, a stop when it shows a challenge, and a long record of all three. The daemon
/// enforces these; agents cannot lift them. Site policies are notes on a site's terms and never refuse it.
enum Site {
    /// The site a host belongs to for budgets, cooldowns and pace: www.linkedin.com and
    /// linkedin.com count together, and so do a site's old and new names (twitter.com is x.com).
    static func domain(_ host: String) -> String {
        var h = host.lowercased()
        for prefix in ["www.", "m.", "mobile.", "web."] where h.hasPrefix(prefix) && h.dropFirst(prefix.count).contains(".") {
            h = String(h.dropFirst(prefix.count))
        }
        return renamed[h] ?? h
    }

    /// One account, two names: the same login and limits whichever one the browser lands on.
    static let renamed = ["twitter.com": "x.com"]

    static func matches(_ host: String, _ domain: String) -> Bool {
        let h = host.lowercased(), d = domain.lowercased()
        return h == d || h.hasSuffix("." + d)
    }

    static func time(_ t: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = Date(timeIntervalSince1970: t).timeIntervalSinceNow > 20 * 3600 ? "EEE HH:mm" : "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    /// Commands that only look. They still run while a site cools down or shows a challenge.
    static let looking: Set<String> = ["read", "ocr", "shot", "wait-for", "log", "pending", "deny"]

    /// The checks every command on a page passes before it acts: the site's cooldown and any
    /// challenge still on screen.
    static func guardPage(_ page: Page, cmd: String, read: () -> Snapshot) throws {
        guard let host = hostOf(page.url) else { return }
        if looking.contains(cmd) { return }
        // `open` may leave a cooling site; it checks the site it goes to itself.
        if cmd != "open" { try Cooldown.check(host) }
        try Challenge.stillThere(host, read: read)
    }

    /// Looks at the screen after an action: a challenge or a throttling message stops work on the site,
    /// or with `on_challenge` / `on_soft_block = "warn"` comes back as a Fail with code 0, a warning.
    /// The throttling check reads only what the action brought up on the same page, outside text
    /// fields: a new page, a scrolled feed or the user's own words that merely mention "rate limit"
    /// do not cool the site down.
    static func inspect(_ command: String, _ old: Snapshot?, _ new: Snapshot, session: Session) -> Fail? {
        guard let host = hostOf(new.url) else { return nil }
        if Config.current.onChallenge != "off", let marker = Challenge.find(new) { return Challenge.start(host, marker, session: session) }
        guard Config.current.onSoftBlock != "off", let old, old.url == new.url, !["scroll", "browse", "hover", "open"].contains(command) else { return nil }
        let before = Set(old.elements.map(\.key))
        let fresh = new.elements.filter { !before.contains($0.key) && !Element.fieldLabels.contains($0.label) }
        let texts = fresh.map { $0.name.lowercased() }
        for phrase in Config.current.softBlockPhrases where !phrase.isEmpty {
            if texts.contains(where: { $0.count < 400 && $0.contains(phrase) }) {
                return Cooldown.start(host, phrase, session: session)
            }
        }
        return nil
    }

    /// A macOS notification, for things the user has to see even when the chat is elsewhere.
    static func notify(_ title: String, _ body: String) {
        func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "'") + "\"" }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "display notification \(quoted(body)) with title \(quoted(title)) sound name \"Ping\""]
        try? proc.run()
    }

    /// Waits until the window has been on its page for the profile's `dwell_s`, so an agent cannot
    /// like or follow something within a second of opening it. The cursor rests meanwhile.
    static func dwell() {
        let p = Config.current.pace
        guard p.dwellMax > 0 else { return }
        let want = Rand.uniform(p.dwellMin...p.dwellMax)
        let since = Date().timeIntervalSince1970 - (Limits.stored.pageAt ?? 0)
        if since < want { Timing.measure("gap") { Mouse.linger(want - since) } }
    }
}

// MARK: - Budgets

enum Budgets {
    struct Cap: Codable {
        var hour: Double?
        var day: Double?
        var week: Double?
        var min_gap_s: Double?
    }

    /// A kind with no cap of its own counts against a close one: an upvote is a like.
    static let alias = ["upvote": "like", "story": "post", "group_post": "post", "repost": "post",
                        "connect": "follow", "friend_request": "follow", "endorse": "like", "join": "follow"]

    static var path: URL { Settings.dir.appendingPathComponent("budgets.json") }

    /// budgets.json maps each site to its caps per kind. Keys starting with "_" and "inherit" are notes.
    /// Only the caps in the file apply: no file, no caps. `kit.sh` installs careful ones.
    static func table(_ file: URL = path) -> [String: [String: Cap]] { (try? load(file)) ?? [:] }

    /// Throws when the file is there but cannot be read, so a typo stops work instead of lifting every cap.
    static func load(_ file: URL) throws -> [String: [String: Cap]] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Fail(4, "budget: \(file.path) is not valid JSON. Fix it; until then apprentice takes no budgeted actions")
        }
        var out: [String: [String: Cap]] = [:]
        for (site, value) in raw where !site.hasPrefix("_") {
            guard let kinds = value as? [String: Any] else { continue }
            for (kind, cap) in kinds {
                guard let c = cap as? [String: Any] else { continue }
                func n(_ k: String) -> Double? { (c[k] as? NSNumber)?.doubleValue }
                out[site, default: [:]][kind] = Cap(hour: n("hour"), day: n("day"), week: n("week"), min_gap_s: n("min_gap_s"))
            }
        }
        return out
    }

    /// The cap for one kind on one site: the site's own entry, else the default's, else the cap of
    /// its alias, else the default's "default" entry, else none.
    static func cap(_ domain: String, _ kind: String, table t: [String: [String: Cap]] = table()) -> Cap {
        let site = t.keys.filter { $0 != "default" && Site.matches(domain, $0) }.max { $0.count < $1.count }
        for k in [kind, alias[kind]].compactMap({ $0 }) {
            if let site, let c = t[site]?[k] { return c }
            if let c = t["default"]?[k] { return c }
        }
        return t["default"]?["default"] ?? Cap()
    }

    /// Kinds in the order they are tested, so "unfollow" wins over "follow" and "add friend" over "add".
    static let words: [(String, [String])] = [
        ("unfollow", ["unfollow"]), ("friend_request", ["add friend"]), ("connect", ["connect"]),
        ("repost", ["repost", "retweet", "reshare", "quote"]), ("endorse", ["endorse"]), ("join", ["join"]),
        ("follow", ["follow", "subscribe"]), ("upvote", ["upvote"]), ("like", ["like", "heart"]),
        ("comment", ["comment", "reply"]), ("message", ["message", "send"]), ("story", ["story"]),
        ("post", ["post", "publish", "tweet", "share"]),
    ]

    /// The budgeted kind of an action from its label and name, or "default" for any other gated
    /// action. Whole words only: "Unlike" and "Following" are not a like or a follow.
    static func kind(_ text: String, gated: Bool) -> String? {
        let padded = " " + text.lowercased().split(whereSeparator: { !$0.isLetter }).joined(separator: " ") + " "
        for (kind, list) in words where list.contains(where: { padded.contains(" \($0) ") }) { return kind }
        return gated ? "default" : nil
    }

    static func plural(_ kind: String) -> String {
        kind == "default" ? "gated actions" : kind.replacingOccurrences(of: "_", with: " ") + "s"
    }

    /// Throws exit 4 when the action would exceed a budget. With `record`, a short `min_gap_s`
    /// remainder is waited out and the action is counted.
    static func check(_ host: String, _ raw: String, record: Bool) throws {
        let domain = Site.domain(host)
        // An upvote is a like and a repost is a post, so the alias shares its counter: counted apart,
        // the two together got twice the cap the alias promises.
        let kind = alias[raw] ?? raw
        // A project folder adds its own count and caps; the account-wide ones below always apply too.
        let project = Project.dir
        let caps = try load(path)
        let projectCaps = try project.map { try Budgets.projectCaps($0, fallback: caps) }
        if let project, let projectCaps {
            var l = Project.limits(project)
            _ = try count(&l, domain, kind, cap(domain, kind, table: projectCaps), record: false, scope: "in this project")
        }
        // Only a recorded step changes the shared counts, so only it takes the lock and writes them.
        let wait: Double
        if record {
            wait = try Limits.update { try count(&$0, domain, kind, cap(domain, kind, table: caps), record: true, scope: nil) }
        } else {
            var l = Limits.stored
            wait = try count(&l, domain, kind, cap(domain, kind, table: caps), record: false, scope: nil)
        }
        if record, let project, let projectCaps {
            _ = try? Project.update(project) { try count(&$0, domain, kind, cap(domain, kind, table: projectCaps), record: true, scope: "in this project") }
        }
        if wait > 0 { Timing.measure("gap") { Pace.sleep(wait) } }
    }

    /// Takes back the count of an approved step that never ran: refused by a rate limit, or stopped by the
    /// user or the kill switch before it acted. It was counted at approval so other VMs' daemons see it.
    static func refund(_ host: String, _ raw: String) {
        let domain = Site.domain(host), kind = alias[raw] ?? raw
        func drop(_ l: inout Limits) {
            guard var times = l.kinds?[domain]?[kind], let last = times.indices.max(by: { times[$0] < times[$1] }) else { return }
            times.remove(at: last)
            l.kinds?[domain]?[kind] = times
        }
        Limits.update { drop(&$0) }
        if let project = Project.dir { Project.update(project) { drop(&$0) } }
    }

    /// A project's own budgets.json, else the account-wide caps.
    static func projectTable(_ project: URL, fallback: @autoclosure () -> [String: [String: Cap]] = table()) -> [String: [String: Cap]] {
        (try? projectCaps(project, fallback: fallback())) ?? [:]
    }

    static func projectCaps(_ project: URL, fallback: @autoclosure () throws -> [String: [String: Cap]]) throws -> [String: [String: Cap]] {
        let file = project.appendingPathComponent("budgets.json")
        return FileManager.default.fileExists(atPath: file.path) ? try load(file) : try fallback()
    }

    /// Checks one kind's count against `cap` and, with `record`, counts it; returns how long to wait first.
    private static func count(_ l: inout Limits, _ domain: String, _ kind: String, _ cap: Cap, record: Bool, scope: String?) throws -> Double {
        let now = Date().timeIntervalSince1970
        let times = (l.kinds?[domain]?[kind] ?? []).filter { now - $0 < 8 * 86_400 }
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date()).timeIntervalSince1970
        var monday = Calendar(identifier: .iso8601)
        monday.timeZone = .current
        let week = monday.dateInterval(of: .weekOfYear, for: Date())?.start.timeIntervalSince1970 ?? day
        let name = plural(kind)
        func over(_ count: Int, _ limit: Double?, _ span: String) throws {
            guard let limit, Double(count) >= limit else { return }
            Events.add(domain, "budget", ["kind": kind, "span": span, "count": count])
            throw Fail(4, "budget: \(count) \(name) on \(domain) \(span)\(scope.map { " " + $0 } ?? "") (cap \(Int(limit))). Stop here; the user can change caps in budgets.json")
        }
        try over(times.filter { now - $0 < 3600 }.count, cap.hour, "in the last hour")
        try over(times.filter { $0 >= day }.count, cap.day, "today")
        try over(times.filter { $0 >= week }.count, cap.week, "this week")
        var wait = 0.0
        if let gap = cap.min_gap_s, let last = times.last, now - last < gap {
            wait = gap - (now - last)
            if wait > 30 {
                throw Fail(4, "budget: the next \(kind.replacingOccurrences(of: "_", with: " ")) on \(domain) is allowed after \(Site.time(last + gap)) (\(Int(gap)) s apart)")
            }
        }
        guard record else { return 0 }
        // Counted now, at the time it will happen, so another VM's daemon sees it while this one waits.
        var kinds = l.kinds ?? [:]
        kinds[domain, default: [:]][kind] = times + [now + wait]
        l.kinds = kinds
        return wait
    }

    /// `apprentice budget [domain]`: what is left today and this hour, per kind, for the sites used lately.
    static func report(_ only: String?) -> String {
        let caps = table()
        var out = report(only, Limits.stored, caps, title: "budget")
        if let project = Project.dir {
            out += "\n" + report(only, Project.limits(project), projectTable(project, fallback: caps), title: "project budget (\(project.deletingLastPathComponent().lastPathComponent))")
        }
        return out
    }

    static func report(_ only: String?, _ l: Limits, _ t: [String: [String: Cap]], title: String) -> String {
        let now = Date().timeIntervalSince1970
        let day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        var domains = Set(l.kinds?.keys.map { $0 } ?? []).union(l.cooling?.keys.map { $0 } ?? []).union(l.challenged?.keys.map { $0 } ?? [])
        if let only { domains = [Site.domain(only)] }
        guard !domains.isEmpty else { return "\(title) · nothing used in the last 8 days. Caps: \(path.path)" }
        var out: [String] = []
        for domain in domains.sorted() {
            out.append("\(title) · \(domain)")
            if let c = l.cooling?[domain], c.until > now { out.append("  cooling until \(Site.time(c.until)) (strike \(c.strikes))") }
            if let marker = l.challenged?[domain] { out.append("  challenge on screen: \(marker)") }
            let used = l.kinds?[domain] ?? [:]
            let kinds = only == nil ? used.keys.sorted() : Set(used.keys).union(words.map(\.0)).sorted()
            for kind in kinds {
                let cap = cap(domain, kind, table: t)
                let times = used[kind] ?? []
                var parts: [String] = []
                if let d = cap.day { parts.append("today \(times.filter { $0 >= day }.count)/\(Int(d))") }
                if let h = cap.hour { parts.append("hour \(times.filter { now - $0 < 3600 }.count)/\(Int(h))") }
                if let g = cap.min_gap_s { parts.append("\(Int(g)) s apart") }
                out.append("  \(kind): " + parts.joined(separator: " · "))
            }
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - Cooldown

enum Cooldown {
    static func check(_ host: String) throws {
        let domain = Site.domain(host)
        let l = Limits.stored
        guard let c = l.cooling?.first(where: { Site.matches(domain, $0.key) })?.value,
              c.until > Date().timeIntervalSince1970, Config.current.onSoftBlock == "stop" else { return }
        throw Fail(4, "soft block: \(domain), cooling until \(Site.time(c.until)). Stop work on this site and tell the user; only they can clear it early")
    }

    /// The ⚠ line on a proposal while a site cools down under `on_soft_block = "warn"`.
    static func warning(_ host: String?) -> String? {
        guard let host, Config.current.onSoftBlock == "warn",
              let c = Limits.stored.cooling?.first(where: { Site.matches(Site.domain(host), $0.key) })?.value,
              c.until > Date().timeIntervalSince1970 else { return nil }
        return "this site asked to slow down; cooling until \(Site.time(c.until)) (on_soft_block = \"warn\")"
    }

    /// Holds off `[sites] cooldown_hours` (1, 6, then 24 by default). A week without a block resets it.
    static func start(_ host: String, _ phrase: String, session: Session) -> Fail {
        let domain = Site.domain(host)
        let now = Date().timeIntervalSince1970
        let c = Limits.update { l -> Limits.Cooling in
            var c = l.cooling?[domain] ?? Limits.Cooling(until: 0, strikes: 0, last: 0)
            if now - c.last > 7 * 86_400 { c.strikes = 0 }
            let hours = Config.current.cooldownHours
            let hold = hours[min(c.strikes, hours.count - 1)] * 3600
            c.strikes += 1
            c.last = now
            c.until = now + hold
            var all = l.cooling ?? [:]
            all[domain] = c
            l.cooling = all
            return c
        }
        Events.add(domain, "soft_block", ["phrase": phrase, "strike": c.strikes, "until": Site.time(c.until),
                                          "steps": Events.lastSteps(), "shot": Events.shot(session, "soft-block") ?? ""])
        if Config.current.onSoftBlock == "warn" {
            Site.notify("\(domain) asked apprentice to slow down", "The site said \"\(phrase)\". Work goes on (on_soft_block = warn).")
            return Fail(0, "soft block: \(domain) showed \"\(phrase)\". on_soft_block is \"warn\", so work may go on; slow down and tell the user")
        }
        Site.notify("apprentice stopped on \(domain)", "The site said \"\(phrase)\". Cooling until \(Site.time(c.until)).")
        return Fail(4, "soft block: \(domain) showed \"\(phrase)\", cooling until \(Site.time(c.until)). Stop work on this site and tell the user")
    }

    /// `apprentice cool [--clear domain]`: lists cooldowns; clearing one asks the user in the little window.
    static func command(_ a: Args) throws -> String {
        var l = Limits.stored
        let now = Date().timeIntervalSince1970
        guard let raw = a.value("clear") else {
            let live = (l.cooling ?? [:]).filter { $0.value.until > now }
            if live.isEmpty { return "no site is cooling down" }
            return live.sorted { $0.key < $1.key }.map { "\($0.key) · cooling until \(Site.time($0.value.until)) · strike \($0.value.strikes)" }
                .joined(separator: "\n")
        }
        let domain = Site.domain(raw)
        if l.challenged?[domain] != nil {
            let reply = DispatchQueue.main.sync {
                Ask.show("apprentice thinks \(domain) shows a check only you can complete. Is it gone, so apprentice may act there again?",
                         choices: ["It is gone", "Not yet"], multi: false, withText: false, timeout: 120)
            }
            guard reply?.chosen == ["It is gone"] else { throw Fail(3, "\(domain) stays paused until the check is gone") }
            Challenge.clear(domain)
            l = Limits.stored
            if (l.cooling?[domain]?.until ?? 0) <= now { return "\(domain) can be used again" }
        }
        guard let c = l.cooling?[domain], c.until > now else { return "\(domain) is not cooling down" }
        // Agents cannot clear a cooldown: the user says yes in the little window, never in the chat.
        let clear = "Clear it", keep = "Keep waiting"
        let reply = DispatchQueue.main.sync {
            Ask.show("\(domain) asked apprentice to slow down. Clear the cooldown (until \(Site.time(c.until))) and allow actions there again?",
                     choices: [clear, keep], multi: false, withText: false, timeout: 120)
        }
        guard let reply, reply.chosen == [clear] else { throw Fail(3, "the cooldown on \(domain) stays until \(Site.time(c.until))") }
        Limits.update { $0.cooling?[domain]?.until = now }
        Events.add(domain, "cool_cleared", [:])
        return "cleared the cooldown on \(domain). The strike count stays, so the next one lasts longer"
    }
}

// MARK: - Challenges

enum Challenge {
    static let paths = ["/challenge", "/checkpoint", "/captcha", "/sorry/", "/account/access", "/verify", "/authwall"]

    /// The first challenge marker in the page's address, title or short texts.
    static func find(_ s: Snapshot) -> String? {
        let url = s.url?.lowercased() ?? ""
        if let p = paths.first(where: { URL(string: url)?.path.contains($0) ?? false }) { return "address \(p)" }
        let texts = [s.title.lowercased()] + s.elements.map { $0.name.lowercased() }.filter { $0.count < 160 }
        for marker in Config.current.challengeMarkers where !marker.isEmpty {
            if texts.contains(where: { $0.contains(marker) }) { return "\"\(marker)\"" }
        }
        return nil
    }

    static func start(_ host: String, _ marker: String, session: Session) -> Fail {
        let domain = Site.domain(host)
        let first = Limits.update { l -> Bool in
            let first = l.challenged?[domain] == nil
            var all = l.challenged ?? [:]
            all[domain] = marker
            l.challenged = all
            return first
        }
        if Config.current.onChallenge == "warn" {
            if first {
                Events.add(domain, "challenge", ["marker": marker, "mode": "warn", "steps": Events.lastSteps(), "shot": Events.shot(session, "challenge") ?? ""])
                Site.notify("apprentice needs you on \(domain)", "A check is on screen (\(marker)). Only you can complete it.")
            }
            return Fail(0, "challenge: \(domain) shows a check only the user may complete (\(marker)). Do not touch it and tell the user; on_challenge is \"warn\", so other work may go on")
        }
        if first {
            Events.add(domain, "challenge", ["marker": marker, "steps": Events.lastSteps(), "shot": Events.shot(session, "challenge") ?? ""])
            Site.notify("apprentice needs you on \(domain)", "A check is on screen (\(marker)). Only you can complete it.")
        }
        return Fail(4, "challenge: \(domain) shows a check only the user may complete (\(marker)). Do not touch it. Tell the user; once they say it is done, run `apprentice read`. If there is no check on screen, the user can run `apprentice cool --clear \(domain)`")
    }

    /// Refuses actions while the site's challenge is still on screen, and clears it once it is gone.
    static func stillThere(_ host: String, read: () -> Snapshot) throws {
        let domain = Site.domain(host)
        guard Limits.stored.challenged?[domain] != nil else { return }
        let snap = read()
        if let marker = find(snap) {
            guard Config.current.onChallenge == "stop" else { return }
            throw Fail(4, "challenge: \(domain) still shows a check only the user may complete (\(marker)). Wait for them")
        }
        clear(domain)
    }

    static func clear(_ domain: String) {
        guard Limits.update({ $0.challenged?.removeValue(forKey: domain) != nil }) else { return }
        Events.add(domain, "challenge_cleared", [:])
    }
}

// MARK: - Policies

/// A `[policy."<domain>"]` entry in routes.toml: the user's note on a site's terms. It informs, and
/// never refuses a site.
struct SitePolicy {
    var domain: String
    var terms: String?
    var checked: String?
    var api: String?
}

enum Policies {
    static func all() -> [SitePolicy] {
        var out: [String: SitePolicy] = [:]
        for (section, v) in Toml.load(Routes.customPath) where section.hasPrefix("policy.") {
            let domain = String(section.dropFirst("policy.".count)).lowercased()
            out[domain] = SitePolicy(domain: domain, terms: v["terms_url"].map(Toml.unquote), checked: v["checked"].map(Toml.unquote),
                                     api: v["api"].map(Toml.unquote))
        }
        return Array(out.values)
    }

    static func find(_ host: String?) -> SitePolicy? {
        guard let host else { return nil }
        return all().filter { Site.matches(host, $0.domain) }.max { $0.domain.count < $1.domain.count }
    }

    /// Printed under `session` and `open`: a warning when the entry is old.
    static func lines(for host: String?) -> [String] {
        guard let p = find(host) else { return [] }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        if let checked = p.checked.flatMap(f.date(from:)), Date().timeIntervalSince(checked) > 182 * 86_400 {
            return ["policy: the entry for \(p.domain) was checked on \(p.checked ?? ""), over 6 months ago. Terms change; the user should re-read them"]
        }
        return []
    }

    /// `apprentice policy <domain>`.
    static func describe(_ host: String) -> String {
        guard let p = find(host) else { return "policy · \(Site.domain(host)) · no policy on file. Add `[policy.\"\(Site.domain(host))\"]` to \(Routes.customPath.path)" }
        var out = ["policy · \(p.domain)"]
        if let t = p.terms { out.append("terms: \(t)") }
        if let c = p.checked { out.append("checked: \(c)") }
        if let a = p.api { out.append("instead: \(a)") }
        return out.joined(separator: "\n")
    }
}

// MARK: - Events

/// Rate limits, challenges, budget refusals and the user's flags, kept 180 days: restrictions often
/// show up weeks after the activity behind them, long after the 30-day step logs are gone.
enum Events {
    static var file: URL { Store.dir.appendingPathComponent("events.jsonl") }
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f
    }()

    /// Step logs carry milliseconds; events do not.
    private static let stampMs: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func date(_ ts: String) -> Date? { stamp.date(from: ts) ?? stampMs.date(from: ts) }

    static func add(_ domain: String, _ kind: String, _ fields: [String: Any]) {
        var e = fields
        e["ts"] = stamp.string(from: Date())
        e["domain"] = domain
        e["event"] = kind
        Store.appendLine(e, to: file)
    }

    static func all() -> [[String: Any]] { Store.readLines(file) }

    static func prune(days: Double = 180) {
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        let rows = all()
        let keep = rows.filter { ($0["ts"] as? String).flatMap(date).map { $0 >= cutoff } ?? false }
        guard keep.count < rows.count else { return }
        let lines = keep.compactMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            .map { String(decoding: $0, as: UTF8.self) }
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: file, atomically: true, encoding: .utf8)
    }

    /// The last 5 rows of this session's step log, which never hold typed text.
    static func lastSteps() -> [String] {
        let f = Store.runFolder().appendingPathComponent("steps.jsonl")
        let rows = ((try? String(contentsOf: f, encoding: .utf8)) ?? "").split(separator: "\n").suffix(5)
        return rows.map(String.init)
    }

    static func shot(_ session: Session, _ name: String) -> String? {
        guard !Privacy.blocked(session), Capture.permission(), let image = Capture.window(session.wid) else { return nil }
        let url = Store.runFolder().appendingPathComponent("shots/\(name)-\(Int(Date().timeIntervalSince1970)).png")
        try? Capture.save(image, to: url)
        return url.path
    }

    /// `apprentice flag <domain> "note"`: when the user saw a warning or restriction.
    static func flag(_ a: Args) throws -> String {
        guard let raw = a.pos.first else { throw Fail(5, "flag <domain> \"what you saw\"") }
        let domain = Site.domain(raw.contains("://") ? (hostOf(raw) ?? raw) : raw)
        let note = a.pos.dropFirst().joined(separator: " ")
        add(domain, "flag", ["note": note])
        return "flagged \(domain) at \(Site.time(Date().timeIntervalSince1970)). `apprentice activity \(domain)` shows the days before it"
    }

    /// `apprentice activity <domain> [--days 7]`: actions per day and kind, with rate limits,
    /// challenges, budget refusals and flags, across every session.
    static func activity(_ a: Args) throws -> String {
        guard let raw = a.pos.first else { throw Fail(5, "activity <domain> [--days 7]") }
        let domain = Site.domain(raw.contains("://") ? (hostOf(raw) ?? raw) : raw)
        let days = try a.count("days", 7, min: 1)
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let dayOf = { (ts: String) in String(ts.prefix(10)) }
        var counts: [String: [String: Int]] = [:]
        for folder in Sessions.folders() {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            guard modified >= cutoff else { continue }
            for row in Sessions.rows(folder) {
                guard let host = row["host"] as? String, Site.matches(host, domain),
                      let cmd = row["cmd"] as? String, let ts = row["ts"] as? String,
                      let when = date(ts), when >= cutoff else { continue }
                counts[dayOf(ts), default: [:]][row["kind"] as? String ?? cmd, default: 0] += 1
            }
        }
        var marks: [String: [String]] = [:]
        for e in all() where (e["domain"] as? String).map({ Site.matches($0, domain) }) ?? false {
            guard let ts = e["ts"] as? String, let when = date(ts), when >= cutoff else { continue }
            let what = e["event"] as? String ?? "event"
            let detail = (e["note"] ?? e["phrase"] ?? e["marker"] ?? e["kind"]).map { " \($0)" } ?? ""
            marks[dayOf(ts), default: []].append("\(what == "flag" ? "⚑" : "⚠") \(ts.dropFirst(11).prefix(5)) \(what)\(detail)")
        }
        var out = ["activity · \(domain) · last \(days) days"]
        let daysSeen = Set(counts.keys).union(marks.keys).sorted()
        if daysSeen.isEmpty { out.append("nothing recorded") }
        for d in daysSeen {
            let line = (counts[d] ?? [:]).sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")
            out.append("\(d)  \(line.isEmpty ? "-" : line)")
            for m in marks[d] ?? [] { out.append("            \(m)") }
        }
        return out.joined(separator: "\n")
    }
}
