import AppKit
import Foundation

/// Where a session is: captured by apprentice, never typed by an agent. `key` is the short form a fact keeps,
/// "macOS 26 Chrome 156" or "Linux 13 Chromium 142".
struct SessionEnv: Codable, Equatable {
    var system: String
    var os: String
    var app: String
    var appVersion: String
    var reader: String
    var lang: String

    private static func major(_ version: String) -> String { String(version.prefix { $0 != "." }) }

    var key: String {
        let name = system == "linux" ? "Linux" : "macOS"
        return "\(name) \(Self.major(os)) \(Self.shortApp(app))" + (appVersion.isEmpty ? "" : " \(Self.major(appVersion))")
    }

    static func shortApp(_ app: String) -> String { app.hasPrefix("Google ") ? String(app.dropFirst(7)) : app }

    /// The Mac's own: the OS from `ProcessInfo`, the app's version from its bundle.
    static func mac(app: NSRunningApplication?, name: String) -> SessionEnv {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let version = app?.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? ""
        return SessionEnv(system: "macos", os: "\(v.majorVersion).\(v.minorVersion)", app: name, appVersion: version, reader: "ax", lang: Locale.preferredLanguages.first ?? "en")
    }

    private static var guestCache: [String: String] = [:]

    /// The VM's, asked of the guest once per daemon. A guest that does not answer is just "Linux".
    static func guest(app: String) -> SessionEnv {
        func ask(_ key: String, _ command: String) -> String {
            if let known = guestCache[key] { return known }
            guard let ip = try? VM.address() else { return "" }
            let r = VM.ssh(ip, command)
            let text = String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guestCache[key] = r.code == 0 ? text : ""
            return guestCache[key] ?? ""
        }
        let os = ask("os", ". /etc/os-release 2>/dev/null; echo \"$VERSION_ID\"")
        let lower = app.lowercased().split(separator: " ").first.map(String.init) ?? ""
        let version = ask("v-" + lower, "\(VM.shellQuoted(lower)) --version 2>/dev/null | head -1 | grep -oE '[0-9]+(\\.[0-9]+)+' | head -1")
        return SessionEnv(system: "linux", os: os, app: app, appVersion: version, reader: "atspi", lang: "en")
    }

    /// A key taken apart again: system, OS major, app name and app major.
    struct Parts: Equatable {
        var system = ""
        var os = ""
        var app = ""
        var appMajor = ""
    }

    static func parts(_ key: String) -> Parts {
        var words = key.split(separator: " ").map(String.init)
        var p = Parts()
        guard words.count >= 2 else { return p }
        p.system = words.removeFirst().lowercased()
        p.os = words.first?.allSatisfy(\.isNumber) == true ? words.removeFirst() : ""
        if let last = words.last, last.allSatisfy(\.isNumber) { p.appMajor = words.removeLast() }
        p.app = words.joined(separator: " ")
        return p
    }

    /// `[skills] env_match`: "major" (system, OS major, app name, and the app's major for apps that are not browsers:
    /// a browser's major changes every few weeks and rarely matters), "name" or "minor".
    static func same(_ a: String, _ b: String, web: Bool, rule: String = Skills.envRule) -> Bool {
        let x = parts(a), y = parts(b)
        guard x.system == y.system, x.app.lowercased() == y.app.lowercased() else { return false }
        if rule == "name" { return true }
        guard x.os == y.os else { return false }
        if rule == "minor" { return a == b }
        return web || x.appMajor == y.appMajor
    }
}

/// One line of a place's learned file: `- 2026-11-05 ×3 · trap · The sentence. · seen: a, b · not: c`.
struct Fact: Equatable {
    static let kinds = ["trap", "hidden", "works", "layout"]

    var date = ""
    var count = 1
    /// Its own miss pattern happened again in a session that had been told about it.
    var doubted = false
    var kind: String? = nil
    var text = ""
    var seen: [String] = []
    var not: [String] = []

    var key: String { Skills.factKey(text) }

    var line: String {
        var head = date
        if count > 1 { head += " ×\(count)" }
        if doubted { head += " ?" }
        var parts = [head]
        if let kind { parts.append(kind) }
        parts.append(text)
        if !seen.isEmpty { parts.append("seen: " + seen.joined(separator: ", ")) }
        if !not.isEmpty { parts.append("not: " + not.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// Reads a line back; an older `date · text` line reads as a fact seen once, anywhere. Nil for a line with no
    /// date, which is a built-in playbook's plain sentence rather than a dated fact.
    static func parse(_ raw: String) -> Fact? {
        var pieces = raw.components(separatedBy: " · ")
        guard pieces.count >= 2 else { return nil }
        let head = pieces.removeFirst().split(separator: " ").map(String.init)
        guard let date = head.first, date.count == 10, date.allSatisfy({ $0.isNumber || $0 == "-" }) else { return nil }
        var f = Fact(date: date)
        for word in head.dropFirst() {
            if word.hasPrefix("×"), let n = Int(word.dropFirst()) { f.count = n }
            if word == "?" { f.doubted = true }
        }
        func list(_ prefix: String) -> [String]? {
            guard let last = pieces.last, last.hasPrefix(prefix) else { return nil }
            pieces.removeLast()
            return last.dropFirst(prefix.count).components(separatedBy: ", ").filter { !$0.isEmpty }
        }
        if let v = list("not: ") { f.not = v }
        if let v = list("seen: ") { f.seen = v }
        if pieces.count > 1, kinds.contains(pieces[0]) { f.kind = pieces.removeFirst() }
        f.text = pieces.joined(separator: " · ")
        return f.text.isEmpty ? nil : f
    }

    /// The kind from the sentence's first word, or the flag, and the sentence without it.
    static func split(_ sentence: String, kind: String?) -> (kind: String?, text: String) {
        let words = sentence.split(separator: " ", maxSplits: 1).map(String.init)
        if let first = words.first?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":")), kinds.contains(first), words.count == 2 {
            return (first, words[1])
        }
        return (kind.flatMap { kinds.contains($0) ? $0 : nil }, sentence)
    }

    /// Why this sentence is not a fact, in words that say where it belongs; nil when it is one.
    static func refusal(_ text: String) -> String? {
        let patterns = [#"(?i)\bclick\s+\d+"#, #"(?i)\bid\s+\d+"#, #"#\d+"#, #"--at\s+\d+\s*,\s*\d+"#, #"(?i)\bthen\s+click\b.*\bthen\s+click\b"#, #"(?i)\bclick\b.*\bthen\s+click\b.*\bthen\s+click\b"#]
        if patterns.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) {
            return "a fact says what is true of the place, not which id to click. A procedure is `learn \"<task>\"`"
        }
        return nil
    }

    /// The words of the task the fact seems to carry, when the place's facts and the screen's labels do not explain them.
    static func jobWords(_ text: String, task: String?, known: String) -> [String] {
        guard let task else { return [] }
        func words(_ s: String) -> Set<String> { Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 3 }) }
        return words(text).intersection(words(task)).subtracting(words(known)).sorted()
    }

    /// What to print beside a fact never confirmed here; nil when it was, or when nothing says where it was seen.
    static func qualifier(seen: [String], here: String?, web: Bool, rule: String = Skills.envRule) -> String? {
        guard let here, !seen.isEmpty else { return nil }
        if seen.contains(where: { SessionEnv.same($0, here, web: web, rule: rule) }) { return nil }
        let at = SessionEnv.parts(here)
        let others = seen.map(SessionEnv.parts)
        // The smallest difference, so one line costs a few words only when environments really differ.
        if !others.contains(where: { $0.system == at.system }) { return at.system == "linux" ? "(Mac only)" : "(VM only)" }
        let sameSystem = others.filter { $0.system == at.system }
        if !sameSystem.contains(where: { $0.app.lowercased() == at.app.lowercased() }) {
            return "(seen in \(sameSystem[0].app), not here)"
        }
        let os = sameSystem.first { $0.app.lowercased() == at.app.lowercased() }?.os ?? ""
        let name = at.system == "linux" ? "Linux" : "macOS"
        if os != at.os { return "(\(name) \(os) only)" }
        return "(seen in another version)"
    }
}

/// How the facts of a place are ordered and shown: confirmed here first, traps first among those, then by how often
/// they kept being true, then how recently.
extension Skills {
    static var envRule: String { settings["env_match"].map(Toml.unquote) ?? "major" }
    static func staleDays(web: Bool) -> Int { limit(web ? "stale_days_sites" : "stale_days_apps", web ? 60 : 180) }

    static func order(_ facts: [Fact], here: String?, web: Bool) -> [Fact] {
        func score(_ f: Fact) -> (Int, Int, Int, String) {
            let confirmed = here.map { h in f.seen.isEmpty || f.seen.contains { SessionEnv.same($0, h, web: web) } } ?? true
            return (confirmed ? 1 : 0, f.kind == "trap" ? 1 : 0, f.count, f.date)
        }
        return facts.sorted { score($0) > score($1) }
    }

    /// A fact as an agent reads it, or nil when it was found false here.
    static func shown(_ f: Fact, here: String?, web: Bool, today: Date = Date()) -> String? {
        if let here, f.not.contains(where: { SessionEnv.same($0, here, web: web) }) { return nil }
        var parts = [f.date + (f.count > 1 ? " ×\(f.count)" : "") + (f.doubted ? " ?" : "")]
        if let k = f.kind { parts.append(k) }
        parts.append(f.text + (Fact.qualifier(seen: f.seen, here: here, web: web).map { " " + $0 } ?? ""))
        if let at = dayFormat.date(from: f.date), today.timeIntervalSince(at) > Double(staleDays(web: web)) * 86400 {
            parts.append("unchecked since \(f.date)")
        }
        return parts.joined(separator: " · ")
    }

    static let dayFormat: DateFormatter = {
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.dateFormat = "yyyy-MM-dd"
        return d
    }()

    /// `www.facebook.com` and `facebook.com` are one place, so one file.
    static func normalised(_ target: String) -> String {
        let t = target.trimmingCharacters(in: .whitespaces)
        let lower = t.lowercased()
        let isHost = lower.contains(".") && !lower.contains(" ")
        return isHost ? Site.domain(hostOf(lower.contains("://") ? lower : "https://" + lower) ?? lower) : t
    }

    /// What a learned file holds as facts, and its retired lines.
    static func facts(in url: URL) -> [Fact] { existingFacts(url).compactMap(Fact.parse) }

    private static func retired(_ text: String) -> [String] {
        var out: [String] = [], inside = false
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") { inside = line.lowercased().hasPrefix("## retired"); continue }
            if inside, line.hasPrefix("- ") { out.append(String(line.dropFirst(2))) }
        }
        return out
    }

    /// Writes a place's facts and its retired lines, keeping whatever else the file holds. Retired lines go after 90 days.
    static func saveFacts(_ facts: [Fact], retired new: [String] = [], at url: URL, scope: String, match: String, day: String = Store.day(), today: Date = Date()) throws {
        let existing = try? String(contentsOf: url, encoding: .utf8)
        let keptRetired = (retired(existing ?? "") + new).filter { line in
            let date = line.prefix(10)
            return dayFormat.date(from: String(date)).map { today.timeIntervalSince($0) < 90 * 86400 } ?? true
        }
        var block = "## Key facts\n" + facts.map { "- " + $0.line }.joined(separator: "\n") + "\n"
        if !keptRetired.isEmpty { block += "\n## Retired\n" + keptRetired.map { "- " + $0 }.joined(separator: "\n") + "\n" }
        let text: String
        if let existing, let at = existing.range(of: "## Key facts") {
            let after = existing[at.upperBound...]
            // Whatever other sections the file holds stay; Retired is rewritten with the facts.
            var rest = ""
            var keep = false
            for chunk in after.components(separatedBy: "\n## ").dropFirst() {
                keep = !chunk.lowercased().hasPrefix("retired")
                if keep { rest += "\n## " + chunk }
            }
            var out = String(existing[..<at.lowerBound]) + block + rest
            if let u = out.range(of: "\nupdated:.*", options: .regularExpression), out.distance(from: out.startIndex, to: u.lowerBound) < 400 {
                out.replaceSubrange(u, with: "\nupdated: \(day)")
            }
            text = out
        } else if let existing {
            text = existing.trimmingCharacters(in: .newlines) + "\n\n" + block
        } else {
            text = """
            ---
            scope: \(scope)
            match: \(match)
            status: learned
            updated: \(day)
            ---
            # \(match)

            Learned by apprentice while working: one fact per line, most confirmed first, at most \(maxFacts).

            \(block)
            """
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// `learn --still "<first words>"` and `--wrong`: finds one fact by the start of its sentence.
    private static func one(_ facts: [Fact], _ words: String) throws -> Int {
        let prefix = factKey(words)
        guard !prefix.isEmpty else { throw Fail(5, "say which fact: its first words") }
        let hits = facts.indices.filter { factKey(facts[$0].text).hasPrefix(prefix) }
        guard hits.count == 1 else {
            throw Fail(5, hits.isEmpty ? "no fact here starts with \"\(words)\"" : "\(hits.count) facts start with \"\(words)\": give more of it")
        }
        return hits[0]
    }

    /// Confirms a fact without retyping it, adding this environment if it is new.
    static func stillTrue(_ words: String, for target: String, env: String?, day: String = Store.day()) throws -> String {
        let (url, scope, match) = factFile(for: target)
        var list = facts(in: url)
        // A library fact confirmed here becomes a local line under the same key.
        let i: Int
        if let found = try? one(list, words) { i = found }
        else if let found = SkillLibrary.facts(for: target).first(where: { factKey($0.text).hasPrefix(factKey(words)) }) {
            list.append(found)
            i = list.count - 1
        } else { i = try one(list, words) }
        list[i].date = day
        list[i].count += 1
        list[i].doubted = false
        if let env, !list[i].seen.contains(env) { list[i].seen.append(env) }
        list[i].not.removeAll { $0 == env }
        try saveFacts(list, at: url, scope: scope, match: match, day: day)
        Store.log(["learned": match, "still": true])
        return "still true on \(match): \(list[i].text) (×\(list[i].count))"
    }

    /// Marks a fact false where the session is; once nothing is left in `seen:` it is retired, kept 90 days so it is
    /// not relearned next week.
    static func wrong(_ words: String, for target: String, env: String?, day: String = Store.day()) throws -> String {
        let (url, scope, match) = factFile(for: target)
        var list = facts(in: url)
        let i: Int
        if let found = try? one(list, words) { i = found }
        else if let found = SkillLibrary.facts(for: target).first(where: { factKey($0.text).hasPrefix(factKey(words)) }) {
            list.append(found)
            i = list.count - 1
        } else { i = try one(list, words) }
        if let env, !list[i].not.contains(env) { list[i].not.append(env) }
        list[i].seen.removeAll { s in env.map { SessionEnv.same(s, $0, web: url.path.contains("/web/")) } ?? true }
        if list[i].seen.isEmpty {
            let gone = list.remove(at: i)
            try saveFacts(list, retired: ["\(day) · was: \(gone.text)"], at: url, scope: scope, match: match, day: day)
            Store.log(["learned": match, "wrong": true])
            return "retired on \(match): \(gone.text)"
        }
        try saveFacts(list, at: url, scope: scope, match: match, day: day)
        Store.log(["learned": match, "wrong": true])
        return "marked false on \(env ?? "this environment"), kept for \(list[i].seen.joined(separator: ", ")): \(list[i].text)"
    }

    /// A flow that ran to its end was just confirmed. A built-in playbook's date stays the human's.
    static func confirmFlow(_ note: Playbooks.Playbook, env: String?, day: String = Store.day()) {
        guard note.origin == .learned, var text = try? String(contentsOf: note.url, encoding: .utf8) else { return }
        let line = "verified: \(day)" + (env.map { " · \($0)" } ?? "")
        if let r = text.range(of: "(?m)^verified:.*$", options: .regularExpression) { text.replaceSubrange(r, with: line) }
        try? text.write(to: note.url, atomically: true, encoding: .utf8)
    }

    /// A trap the session was told about and fell into anyway is marked, cheaply and honestly, for next time.
    static func doubt(_ target: String, naming words: [String]) {
        let (url, scope, match) = factFile(for: target)
        var list = facts(in: url)
        var changed = false
        for i in list.indices where list[i].kind == "trap" && !list[i].doubted {
            let quoted = list[i].text.components(separatedBy: "\"").enumerated().filter { $0.offset % 2 == 1 }.map { $0.element.lowercased() }
            if quoted.contains(where: { q in words.contains { $0.lowercased().contains(q) && !q.isEmpty } }) {
                list[i].doubted = true
                changed = true
            }
        }
        if changed { try? saveFacts(list, at: url, scope: scope, match: match) }
    }
}

/// The tool knows a struggle happened and where; only the agent knows what it worked out. So the trigger lives here, as
/// one line at the end of a command's output, and the words come from the agent. `learned?` prints on the first action
/// that changes the screen after two or more misses, or after a long think with one miss; `done` prints a closing one
/// when something was worked out and nothing was kept.
struct Struggle: Codable {
    var session = ""
    var misses = 0
    var lastAt = 0.0
    var firstMissAt = 0.0
    var gaps: [Double] = []
    var lastNudge = 0.0
    var lastCommand = ""
    var lastFailed = false
    /// Per place in this session: times it nudged.
    var struggles: [String: Int] = [:]

    static let actions: Set<String> = Playbooks.actions.union(["wait-for"])

    static var missLimit: Int { Skills.limit("nudge_misses", 2) }
    static var gapLimit: Double { Double(Skills.limit("nudge_gap_s", 60)) }
    static var every: Double { Double(Skills.limit("nudge_every_s", 120)) }

    private static func text(_ key: String) -> String {
        for file in AppText.files.reversed() {
            if let v = Toml.load(file)["learning"]?[key] { return Toml.unquote(v) }
        }
        return ""
    }

    /// Pure, so `selftest` can walk it: takes one command's result and says whether to nudge.
    mutating func take(cmd: String, code: Int32, out: String, args: [String], now: Double, place: String) -> String? {
        defer {
            lastAt = now
            lastCommand = cmd
            lastFailed = code != 0 && code != 8
        }
        // A proposal or an approval on its way is not the agent's next try.
        guard code != 8 else { return nil }
        let gap = lastAt > 0 ? now - lastAt : 0
        let unchanged = out.contains("+0 -0 ~0")
        let isAction = Self.actions.contains(cmd)
        var miss = false
        if isAction, code == 2 || code == 5 { miss = true }
        if isAction, code == 0, unchanged { miss = true }
        if cmd == "ocr" || cmd == "shot", lastCommand == "read" { miss = true }
        if cmd == "click", code == 0, args.contains("--at"), lastCommand == "click", lastFailed { miss = true }
        // A question the user answered got a step past a block, when there was one.
        if cmd == "ask" || cmd == "show", code == 0, misses > 0 { misses += Self.missLimit }
        if miss {
            misses += 1
            if firstMissAt == 0 { firstMissAt = now }
        }
        guard isAction, code == 0 else { return nil }
        let median = gaps.sorted().dropFirst(gaps.count / 2).first ?? 0
        if gap > 0, gap < 300 {
            gaps.append(gap)
            if gaps.count > 30 { gaps.removeFirst() }
        }
        guard !unchanged else { return nil }
        let long = gap >= max(Self.gapLimit, 3 * median) && misses >= 1
        guard misses >= Self.missLimit || long else { return nil }
        guard lastNudge == 0 || now - lastNudge >= Self.every else { return nil }
        let tries = misses
        let seconds = Int(now - (firstMissAt > 0 ? firstMissAt : now))
        misses = 0
        firstMissAt = 0
        lastNudge = now
        struggles[place, default: 0] += 1
        return Self.text("nudge").replacingOccurrences(of: "{tries}", with: "\(tries)")
            .replacingOccurrences(of: "{seconds}", with: "\(seconds)").replacingOccurrences(of: "{place}", with: place)
    }

    private static func place(_ s: Session) -> String { Skills.normalised(hostOf(s.url) ?? s.app) }

    /// Called by the daemon after every command; what it returns goes at the end of the output.
    static func after(_ req: Request, code: Int32, out: String) -> String? {
        guard let s = Session.stored, let id = s.id else { return nil }
        var t = Store.load(Struggle.self, "struggle.json") ?? Struggle()
        if t.session != id { t = Struggle(session: id) }
        let where_ = place(s)
        let before = t.misses
        let line = t.take(cmd: req.cmd, code: code, out: out, args: req.args, now: Date().timeIntervalSince1970, place: where_)
        if t.misses > before { Skills.doubt(where_, naming: req.args) }
        Store.save(t, "struggle.json")
        if line != nil { Store.log(["learned?": where_]) }
        return line
    }

    /// At `done`: struggles in this session, and no fact kept.
    static func closing() -> String? {
        guard let s = Session.stored, let t = Store.load(Struggle.self, "struggle.json"), t.session == s.id else { return nil }
        let total = t.struggles.values.reduce(0, +)
        guard total > 0, let top = t.struggles.max(by: { $0.value < $1.value })?.key else { return nil }
        let kept = Sessions.rows(Store.runFolder(s)).contains { $0["learned"] != nil }
        guard !kept else { return nil }
        return text("closing").replacingOccurrences(of: "{count}", with: "\(total)").replacingOccurrences(of: "{place}", with: top)
            .replacingOccurrences(of: "{things}", with: total == 1 ? "thing" : "things")
    }

    /// `grow`'s line: places where struggles came, against the facts kept there.
    static func growLine(_ rows: [String: (struggles: Int, kept: Int)]) -> String? {
        let places = rows.filter { $0.value.struggles > 0 || $0.value.kept > 0 }.sorted { $0.value.struggles > $1.value.struggles }
        guard !places.isEmpty else { return nil }
        return "learned: " + places.prefix(8).map { "\($0.key) \($0.value.struggles) struggles, \($0.value.kept) fact\($0.value.kept == 1 ? "" : "s") kept" }.joined(separator: " · ")
    }
}
