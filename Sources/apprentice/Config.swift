import Foundation

/// A deliberately small TOML reader: sections, `key = value`, strings, numbers,
/// `[a, b]` arrays and one-line `{ k = v }` tables. That covers config.toml.
enum Toml {
    static func load(_ path: URL) -> [String: [String: String]] {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [:] }
        return parse(text)
    }

    static func parse(_ text: String) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        var section = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                section = section.replacingOccurrences(of: "\"", with: "")
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            out[section, default: [:]][key] = value
        }
        return out
    }

    static func stripComment(_ line: String) -> String {
        var inString = false
        var prev: Character = " "
        for (i, ch) in line.enumerated() {
            if ch == "\"" && prev != "\\" { inString.toggle() }
            if ch == "#" && !inString { return String(line.prefix(i)) }
            prev = ch
        }
        return line
    }

    static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }

    static func array(_ s: String) -> [String]? {
        guard s.hasPrefix("["), s.hasSuffix("]") else { return nil }
        return splitTop(String(s.dropFirst().dropLast())).map { unquote($0) }
    }

    /// Splits on commas outside quotes, so `["Acme, Inc"]` stays one item.
    static func splitTop(_ s: String) -> [String] {
        var parts: [String] = []
        var cur = ""
        var quote: Character?
        var prev: Character = " "
        for ch in s {
            if let q = quote {
                if ch == q && prev != "\\" { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "," {
                parts.append(cur)
                cur = ""
                prev = ch
                continue
            }
            cur.append(ch)
            prev = ch
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(cur) }
        return parts
    }

    static func doubles(_ s: String) -> [Double]? {
        array(s)?.compactMap { Double($0) }
    }

    static func table(_ s: String) -> [String: String] {
        guard s.hasPrefix("{"), s.hasSuffix("}") else { return [:] }
        var out: [String: String] = [:]
        for part in splitTop(String(s.dropFirst().dropLast())) {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { out[pair[0]] = pair[1] }
        }
        return out
    }

    /// Changes one key's value in place and leaves every other byte of the file as it was, comments
    /// included: the app's forms edit a hand-written config without rewriting it. The key is added at the
    /// end of its section (and the section at the end of the file) when it is missing. The value is the
    /// TOML text of the value, quotes and all. Returns whether the file was written.
    @discardableResult
    static func set(_ path: URL, _ section: String, _ key: String, _ literal: String) -> Bool {
        var lines = ((try? String(contentsOf: path, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        guard !lines.isEmpty else { return false }
        guard let (start, end) = bounds(lines, section) else {
            lines.append("")
            lines.append("[\(section)]")
            lines.append("\(key) = \(literal)")
            return write(lines, path)
        }
        if let i = keyLine(lines, start, end, key) {
            // Keep the line's own indentation and whatever comment followed the old value.
            let bare = stripComment(lines[i])
            let indent = String(lines[i].prefix { $0 == " " || $0 == "\t" })
            let comment = String(lines[i].dropFirst(bare.count)).trimmingCharacters(in: .whitespaces)
            lines[i] = indent + key + " = " + literal + (comment.isEmpty ? "" : " " + comment)
            return write(lines, path)
        }
        // Not there yet: at the end of its section, before the blank lines and the next header.
        var insert = end
        while insert > start, lines[insert - 1].trimmingCharacters(in: .whitespaces).isEmpty { insert -= 1 }
        lines.insert("\(key) = \(literal)", at: insert)
        return write(lines, path)
    }

    /// Removes a key from a section, leaving its comments alone. False when it was not there.
    @discardableResult
    static func remove(_ path: URL, _ section: String, _ key: String) -> Bool {
        guard var lines = try? String(contentsOf: path, encoding: .utf8).components(separatedBy: "\n"),
              let (start, end) = bounds(lines, section), let i = keyLine(lines, start, end, key) else { return false }
        lines.remove(at: i)
        return write(lines, path)
    }

    /// A section name as the reader keys it: no quotes, no spaces around the dots, so `[pace."x.com"]`,
    /// `[ pace.x.com ]` and `pace.x.com` are one section.
    static func canonical(_ section: String) -> String {
        section.replacingOccurrences(of: "\"", with: "").split(separator: ".", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ".")
    }

    /// The section a line opens, or nil when it is not a header (`[[…]]` tables included as headers).
    static func header(_ line: String) -> String? {
        let t = stripComment(line).trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), t.hasSuffix("]"), !t.contains("=") else { return nil }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).trimmingCharacters(in: .whitespaces)
    }

    /// The lines of `section`'s body (after its header, up to the next header outside a multi-line array);
    /// the whole file for the top level. Nil when the section is not there.
    static func bounds(_ lines: [String], _ section: String) -> (Int, Int)? {
        var start = 0
        if !section.isEmpty {
            let want = canonical(section)
            guard let found = lines.firstIndex(where: { header($0).map(canonical) == want }) else { return nil }
            start = found + 1
        }
        var depth = 0
        for i in start..<lines.count {
            if depth == 0, header(lines[i]) != nil { return (start, i) }
            depth = max(0, depth + bracketDepth(stripComment(lines[i])))
        }
        return (start, lines.count)
    }

    /// Every `"` string on the line ends on it (`\"` escapes).
    static func closedStrings(_ line: String) -> Bool {
        var inString = false
        var prev: Character = " "
        for ch in line {
            if ch == "\"" && prev != "\\" { inString.toggle() }
            prev = ch
        }
        return !inString
    }

    /// `[` minus `]` outside strings: how far a line opens a multi-line array.
    static func bracketDepth(_ text: String) -> Int {
        var depth = 0
        var quote: Character?
        var prev: Character = " "
        for ch in text {
            if let q = quote { if ch == q && prev != "\\" { quote = nil } }
            else if ch == "\"" || ch == "'" { quote = ch }
            else if ch == "[" { depth += 1 }
            else if ch == "]" { depth -= 1 }
            prev = ch
        }
        return depth
    }

    /// The line that sets `key` (exactly that key: `allow` never matches `allow_x`).
    private static func keyLine(_ lines: [String], _ start: Int, _ end: Int, _ key: String) -> Int? {
        (start..<end).first { i in
            let body = stripComment(lines[i]).trimmingCharacters(in: .whitespaces)
            guard body.hasPrefix(key) else { return false }
            return body.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
        }
    }

    /// What is wrong with a TOML text this reader would misread, with line numbers; empty when it reads
    /// cleanly. The raw settings view saves nothing while there is a problem.
    static func problems(_ text: String) -> [String] {
        var out: [String] = []
        var depth = 0
        for (n, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if depth > 0 {
                depth = max(0, depth + bracketDepth(line))
                continue
            }
            if !closedStrings(line) { out.append("line \(n + 1): a string is not closed"); continue }
            if line.hasPrefix("[") {
                if header(raw) == nil || header(raw)?.isEmpty == true { out.append("line \(n + 1): a section header is not closed") }
                continue
            }
            guard let eq = line.firstIndex(of: "="), !line[..<eq].trimmingCharacters(in: .whitespaces).isEmpty else {
                out.append("line \(n + 1): expected key = value")
                continue
            }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.isEmpty { out.append("line \(n + 1): \(line[..<eq].trimmingCharacters(in: .whitespaces)) has no value") }
            depth = max(0, bracketDepth(value))
            if value.hasPrefix("{"), !value.hasSuffix("}") { out.append("line \(n + 1): an inline table must close on its line") }
        }
        if depth > 0 { out.append("an array is not closed") }
        return out
    }

    private static func write(_ lines: [String], _ path: URL) -> Bool {
        (try? lines.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)) != nil
    }
}

/// Keystrokes keep a slight human rhythm; cursor travel and the pause between actions do not wait
/// by default. A site profile can put the gaps back (`between_actions_ms`, `move_ms`).
struct PaceConfig {
    var moveMin = 0.05
    var moveMax = 0.2
    var keyMedian = 0.14
    var keySigma = 0.4
    var betweenMin = 0.0
    var betweenMax = 0.0
    var navGap = 5.0
    var reloadMax = 3.0
    var reloadWindow = 120.0
    var actionsPerMin = 30.0
    var mode = "human"
    /// Least time on a page before a budgeted action there (a like, follow, comment…); 0 is off.
    var dwellMin = 0.0
    var dwellMax = 0.0
    /// Web actions in a row before a rest; 0 is off.
    var burstMin = 0.0
    var burstMax = 0.0
    var restMin = 20.0
    var restMax = 90.0
    /// Share of letters typed wrong, then backspaced and retyped; 0 is off. Never in password fields.
    var keyErrorRate = 0.0
    /// Share of long cursor moves that go past the target before correcting back onto it.
    var overshoot = 0.33
    /// Share of actions followed by a fidget that changes nothing (`Fidget`); 0 is off.
    var fidget = 0.0
    /// Share of actions on a web page followed by `browse_s` of reading down the feed and back; 0 is off.
    var browseShare = 0.0
    var browseMin = 10.0
    var browseMax = 40.0
    /// Local hours, `[from, to)`, in which apprentice takes no actions on the site; -1 is off.
    var quietFrom = -1.0
    var quietTo = -1.0
    /// Longest sitting on one site, in minutes, before a break of `break_min`; 0 is off. A pause at
    /// least as long as the shortest break starts a new sitting.
    var sittingMax = 0.0
    var breakMin = 15.0
    var breakMax = 40.0
    /// Actions on one site in a day, under any budget; 0 is off.
    var actionsPerDay = 0.0

    init() {}

    /// `style = "fastest" | "fast" | "steady" | "careful"`: the timing keys at once. `fastest` (short moves,
    /// no waits, pasted text) is the built-in default for apps, `steady` for web pages, and `careful` for social
    /// sites (`Config.socialSites`); `careful` is the least likely to be taken for a script and the slowest.
    /// Limits that guard the account (navigation gap, reload cap) are never loosened by a style.
    static func preset(_ name: String, on base: PaceConfig) -> PaceConfig? {
        var p = base
        switch name {
        case "fastest":
            (p.moveMin, p.moveMax, p.keyMedian, p.keySigma) = (0.03, 0.09, 0.07, 0.3)
            (p.betweenMin, p.betweenMax, p.dwellMin, p.dwellMax, p.burstMin, p.burstMax) = (0, 0, 0, 0, 0, 0)
            (p.keyErrorRate, p.overshoot, p.fidget, p.mode) = (0, 0.1, 0, "fast")
        case "fast":
            let d = PaceConfig()
            (p.moveMin, p.moveMax, p.keyMedian, p.keySigma) = (d.moveMin, d.moveMax, d.keyMedian, d.keySigma)
            (p.betweenMin, p.betweenMax, p.dwellMin, p.dwellMax, p.burstMin, p.burstMax) = (0, 0, 0, 0, 0, 0)
            (p.keyErrorRate, p.overshoot, p.fidget, p.mode) = (0, d.overshoot, 0, "human")
        case "steady":
            (p.moveMin, p.moveMax, p.keyMedian, p.keySigma) = (0.12, 0.5, 0.15, 0.4)
            (p.betweenMin, p.betweenMax, p.dwellMin, p.dwellMax, p.burstMin, p.burstMax) = (0.5, 2.5, 1, 3, 0, 0)
            (p.keyErrorRate, p.overshoot, p.fidget, p.mode) = (0.008, 0.4, 0.1, "human")
            p.actionsPerMin = min(p.actionsPerMin, 15)
        case "careful":
            (p.moveMin, p.moveMax, p.keyMedian, p.keySigma) = (0.25, 1.0, 0.18, 0.45)
            (p.betweenMin, p.betweenMax, p.dwellMin, p.dwellMax, p.burstMin, p.burstMax) = (3, 12, 3, 8, 3, 6)
            (p.restMin, p.restMax) = (30, 120)
            (p.keyErrorRate, p.overshoot, p.fidget, p.mode) = (0.015, 0.45, 0.25, "human")
            p.actionsPerMin = min(p.actionsPerMin, 6)
            // A person's day: nothing in the small hours, a break after most of an hour, a few hundred actions at most.
            (p.quietFrom, p.quietTo, p.sittingMax, p.breakMin, p.breakMax) = (2, 6, 50, 15, 40)
            // Now and then a spell of reading the feed, as a person mostly reads one.
            p.browseShare = 0.08
            p.actionsPerDay = p.actionsPerDay > 0 ? min(p.actionsPerDay, 400) : 400
        default:
            return nil
        }
        return p
    }

    init(_ values: [String: String], base: PaceConfig = PaceConfig()) {
        var p = base
        if let style = values["style"].map(Toml.unquote), let preset = PaceConfig.preset(style.lowercased(), on: base) { p = preset }
        if let a = values["move_ms"].flatMap(Toml.doubles), a.count >= 2 {
            p.moveMin = a[0] / 1000
            p.moveMax = a[1] / 1000
        }
        if let v = values["key_ms_median"].flatMap(Double.init) { p.keyMedian = v / 1000 }
        if let v = values["key_ms_sigma"].flatMap(Double.init) { p.keySigma = v }
        if let a = values["between_actions_ms"].flatMap(Toml.doubles), a.count >= 2 {
            p.betweenMin = a[0] / 1000
            p.betweenMax = a[1] / 1000
        }
        if let v = values["nav_min_gap_s"].flatMap(Double.init) { p.navGap = v }
        if let t = values["reload_max"] {
            let table = Toml.table(t)
            if let c = table["count"].flatMap(Double.init) { p.reloadMax = c }
            if let w = table["window_s"].flatMap(Double.init) { p.reloadWindow = w }
        }
        if let v = values["actions_per_min"].flatMap(Double.init) { p.actionsPerMin = v }
        if let m = values["mode"] { p.mode = Toml.unquote(m) }
        if let a = values["dwell_s"].flatMap(Toml.doubles), a.count >= 2 {
            p.dwellMin = a[0]
            p.dwellMax = a[1]
        }
        if let a = values["burst"].flatMap(Toml.doubles), a.count >= 2 {
            p.burstMin = a[0]
            p.burstMax = a[1]
        }
        if let a = values["rest_s"].flatMap(Toml.doubles), a.count >= 2 {
            p.restMin = a[0]
            p.restMax = a[1]
        }
        if let v = values["key_error_rate"].flatMap(Double.init) { p.keyErrorRate = v }
        if let v = values["overshoot"].flatMap(Double.init) { p.overshoot = v }
        if let v = values["fidget"].flatMap(Double.init) { p.fidget = v }
        if let v = values["browse"].flatMap(Double.init) { p.browseShare = v }
        if let a = values["browse_s"].flatMap(Toml.doubles), a.count >= 2 {
            p.browseMin = a[0]
            p.browseMax = a[1]
        }
        if let a = values["quiet_hours"].flatMap(Toml.doubles) {
            (p.quietFrom, p.quietTo) = a.count >= 2 ? (a[0], a[1]) : (-1, -1)
        }
        if let v = values["session_max_min"].flatMap(Double.init) { p.sittingMax = v }
        if let a = values["break_min"].flatMap(Toml.doubles), a.count >= 2 {
            p.breakMin = a[0]
            p.breakMax = a[1]
        }
        if let v = values["actions_per_day"].flatMap(Double.init) { p.actionsPerDay = v }
        self = p.sanitized()
    }

    /// Config values reach sleeps, random ranges and step counts, so out-of-range or non-finite ones
    /// would trap the daemon (B3, D3, H2). Each bad value falls back to the default; pairs are ordered.
    func sanitized() -> PaceConfig {
        let d = PaceConfig()
        func ok(_ v: Double, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double {
            v.isFinite && v >= lo && v <= hi ? v : fallback
        }
        var p = self
        p.moveMin = ok(moveMin, 0.01, 5, d.moveMin)
        p.moveMax = ok(moveMax, 0.01, 5, d.moveMax)
        if p.moveMin > p.moveMax { swap(&p.moveMin, &p.moveMax) }
        p.keyMedian = ok(keyMedian, 0.005, 2, d.keyMedian)
        p.keySigma = ok(keySigma, 0, 3, d.keySigma)
        p.betweenMin = ok(betweenMin, 0, 60, d.betweenMin)
        p.betweenMax = ok(betweenMax, 0, 60, d.betweenMax)
        if p.betweenMin > p.betweenMax { swap(&p.betweenMin, &p.betweenMax) }
        p.navGap = ok(navGap, 0, 600, d.navGap)
        p.reloadMax = ok(reloadMax, 1, 1000, d.reloadMax)
        p.reloadWindow = ok(reloadWindow, 1, 86_400, d.reloadWindow)
        p.actionsPerMin = ok(actionsPerMin, 1, 10_000, d.actionsPerMin)
        p.dwellMin = ok(dwellMin, 0, 120, d.dwellMin)
        p.dwellMax = ok(dwellMax, 0, 120, d.dwellMax)
        if p.dwellMin > p.dwellMax { swap(&p.dwellMin, &p.dwellMax) }
        p.burstMin = ok(burstMin.rounded(), 0, 1000, d.burstMin)
        p.burstMax = ok(burstMax.rounded(), 0, 1000, d.burstMax)
        if p.burstMin > p.burstMax { swap(&p.burstMin, &p.burstMax) }
        if p.burstMin < 1 { p.burstMin = p.burstMax }
        // Rests stay short enough to finish inside one command.
        p.restMin = ok(restMin, 0, 120, d.restMin)
        p.restMax = ok(restMax, 0, 120, d.restMax)
        if p.restMin > p.restMax { swap(&p.restMin, &p.restMax) }
        p.keyErrorRate = ok(keyErrorRate, 0, 0.1, d.keyErrorRate)
        p.overshoot = ok(overshoot, 0, 1, d.overshoot)
        // At most one action in two: a fidget costs seconds every time it runs.
        p.fidget = ok(fidget, 0, 0.5, d.fidget)
        // A browse costs tens of seconds, so at most one action in five, each at most 2 min.
        p.browseShare = ok(browseShare, 0, 0.2, d.browseShare)
        p.browseMin = ok(browseMin, 1, 120, d.browseMin)
        p.browseMax = ok(browseMax, 1, 120, d.browseMax)
        if p.browseMin > p.browseMax { swap(&p.browseMin, &p.browseMax) }
        // Whole hours of the day; a pair that is off, out of range or empty turns quiet hours off.
        let hours = (quietFrom.rounded(), quietTo.rounded())
        if hours.0 >= 0, hours.0 <= 23, hours.1 >= 0, hours.1 <= 24, hours.0 != hours.1 { (p.quietFrom, p.quietTo) = hours } else { (p.quietFrom, p.quietTo) = (-1, -1) }
        p.sittingMax = ok(sittingMax, 0, 24 * 60, d.sittingMax)
        p.breakMin = ok(breakMin, 1, 24 * 60, d.breakMin)
        p.breakMax = ok(breakMax, 1, 24 * 60, d.breakMax)
        if p.breakMin > p.breakMax { swap(&p.breakMin, &p.breakMax) }
        p.actionsPerDay = ok(actionsPerDay.rounded(), 0, 100_000, d.actionsPerDay)
        return p
    }

    /// True when local hour `hour` falls in the quiet hours; a range like 22–6 wraps past midnight.
    func isQuiet(hour: Int) -> Bool {
        guard quietFrom >= 0 else { return false }
        let h = Double(hour)
        return quietFrom < quietTo ? h >= quietFrom && h < quietTo : h >= quietFrom || h < quietTo
    }
}

struct Config {
    var pace = PaceConfig()
    var defaultPace = PaceConfig()
    var profiles: [String: PaceConfig] = [:]
    var allow: [String] = []
    /// When true, macOS tasks go through the UI too; the LLM may not use shell commands for them.
    var uiOnly = false
    var askOnStart = false
    /// The system sound played when the little window pops up; "none" turns it off.
    var askSound = "Ping"
    var keepAwake = false
    /// The menu-bar item that says whether apprentice is working, waiting for the user or holding a proposal.
    var menuBar = true
    /// `[typing] learn`: sample the person's own typing now and then, for `Typing`'s per-pair rhythm.
    var typingLearn = true
    /// `[agent] optional_questions`: now and then a question the user may answer or leave (`OptionalAsk`).
    var optionalQuestions = true
    var optionalWaitSeconds = 60.0
    var optionalEveryHours = 4.0
    var overlay = true
    var sounds = true
    var notifications = false
    var dockIcon = true
    /// Where questions go: "both" (the window, then the chat if unanswered), "window", or "terminal".
    var askIn = "both"
    var askWindowSeconds = 60.0
    /// An ntfy topic URL that gets a push when a question goes to the chat; empty sends nothing.
    var notify = ""
    /// Context-menu items `download` looks for, matched lower case; add your system language's.
    var downloadMenu = ["save image as", "download linked file", "save link as", "download image"]
    /// Bundle ids treated as browsers on top of every app registered to open https links.
    var browsers: [String] = []
    var runURL = "https://api.openai.com/v1"
    var runModel = "gpt-4o-mini"
    var runKey = ""
    var visionModel = ""
    var runMaxSteps = 40
    var runMaxMinutes = 15.0
    var flowShellSeconds = 120.0
    /// Text a site shows when it throttles the account; seeing one after an action cools the site down.
    /// English first, then the same messages as the big sites word them in other languages (BOT_DETECTION D1).
    var softBlockPhrases = [
        "try again later", "you're doing that too much", "you are doing that too much", "temporarily restricted",
        "temporarily blocked", "unusual activity", "we limit how often", "rate limit", "too many requests",
        "action blocked", "suspicious activity", "temporarily limited", "over the daily limit",
        "später erneut", "vorübergehend gesperrt", "vorübergehend eingeschränkt", "ungewöhnliche aktivität", "zu viele anfragen",
        "réessayer plus tard", "réessayez plus tard", "temporairement bloqué", "temporairement restreint", "activité inhabituelle",
        "trop de requêtes", "inténtalo más tarde", "vuelve a intentarlo más tarde", "bloqueado temporalmente",
        "restringido temporalmente", "actividad inusual", "demasiadas solicitudes", "tente novamente mais tarde",
        "bloqueado temporariamente", "atividade incomum", "riprova più tardi", "temporaneamente bloccato", "attività insolita",
        "probeer het later opnieuw", "tijdelijk geblokkeerd", "spróbuj ponownie później", "tymczasowo zablokowane",
        "daha sonra tekrar dene", "geçici olarak engellendi", "повторите попытку позже", "временно заблокирован",
        "необычная активность", "しばらくしてから", "一時的にブロック", "制限されています", "잠시 후 다시", "일시적으로 차단",
        "稍后再试", "請稍後再試", "暂时被限制", "操作过于频繁",
    ]
    /// What a soft block does: "stop" cools the site down and refuses actions there until it ends,
    /// "warn" only says so, "off" does not look.
    var onSoftBlock = "stop"
    /// How long each cooldown lasts in hours: the first, the second, then every later one.
    var cooldownHours = [1.0, 6, 24]
    /// What a CAPTCHA or identity check does: "stop" refuses actions on the site while it is on screen,
    /// "warn" only says so, "off" does not look. apprentice never completes one in any mode.
    var onChallenge = "stop"
    /// Signing in (`Login`): off by default. On, agents may type a saved account and password and ask the
    /// user for sign-in codes, on every site or only those in `sites`.
    var loginAuto = false
    var loginSites: [String] = []
    /// Sign-ins on one site: at least this many minutes apart, and at most this many a day.
    var loginGapMinutes = 30.0
    var loginPerDay = 3
    /// Words and phrases that make a step one only the user can approve, in the little window: the
    /// agent's `approve` is refused. Matched as whole words in the element's label and name.
    var userOnly = [
        "pay", "pay now", "buy", "buy now", "purchase", "checkout", "check out", "place order", "order now",
        "donate", "transfer", "upgrade", "captcha", "not a robot", "verify you are human", "delete account",
        "close account", "deactivate",
    ]
    /// Signs of a CAPTCHA or identity check, which only the user may complete.
    var challengeMarkers = [
        "captcha", "verify you are human", "verify you're human", "i'm not a robot", "i am not a robot",
        "are you a robot", "confirm it's you", "confirm it is you", "enter the code", "security check",
        "press and hold", "help us confirm", "your account has been locked", "your account is locked",
        "bestätige, dass du ein mensch bist", "sicherheitsüberprüfung", "je ne suis pas un robot", "vérifiez que vous êtes humain",
        "confirmez qu'il s'agit bien de vous", "no soy un robot", "verifica que eres humano", "confirma que eres tú",
        "não sou um robô", "confirme que é você", "non sono un robot", "conferma che sei tu", "ik ben geen robot",
        "nie jestem robotem", "robot değilim", "я не робот", "подтвердите, что это вы", "ロボットではありません",
        "本人確認", "로봇이 아닙니다", "본인 인증", "我不是机器人", "安全验证", "验证身份",
    ]
    /// More words per budgeted kind, from `[sites.kinds]`: `like = ["gostei"]`.
    var kindWords: [String: [String]] = [:]

    /// `[schedules] enabled`: the daemon's timer fires schedules unless this is false.
    var schedulesOn = true
    /// `[app]`: the window. Its terminal's font, whether scrollback comes back after a relaunch, and
    /// whether selecting text copies it.
    var appFont = "SF Mono"
    var appFontSize = 12.0
    var appTheme = "system"
    var keepScrollback = false
    var copyOnSelect = false
    /// `[app.tabs]`: tab presets, `shop = { dir = "~/work/shop", cmd = "claude", vm = "linux1" }`.
    var tabPresets: [String: [String: String]] = [:]

    /// Sites built in at the `careful` style: the social networks, where an account's standing is
    /// what is at stake. twitter.com counts as x.com (`Site.domain`).
    static let socialSites = ["facebook.com", "instagram.com", "threads.net", "threads.com", "tiktok.com", "linkedin.com",
                              "x.com", "reddit.com", "pinterest.com", "youtube.com", "bsky.app"]

    static var current = Config.load()
    static var path: URL { Settings.dir.appendingPathComponent("config.toml") }
    private static var loadedAt: Date?
    private static var loadedOverlay: String?

    /// Re-reads config.toml only when it, or the VM's own one over it (`Layers`), changed, and starts each
    /// command on the default pace.
    static func reloadIfChanged() {
        let stamp = (try? path.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let overlay = Layers.local == .vm ? Layers.read("config.toml", .vm) : nil
        if stamp != loadedAt || overlay != loadedOverlay {
            loadedAt = stamp
            loadedOverlay = overlay
            current = load()
        }
        current.pace = current.defaultPace
    }

    /// What the LLM may use besides the UI. The user sets this; agents never change it.
    /// Terminal first: the screen is for what no command can do. Websites always go through the UI.
    static var policyLine: String {
        if Session.stored?.uiOnly ?? current.uiOnly {
            return "policy: UI only. Do every task through apprentice, including files and folders; no shell commands for them."
        }
        var line = "policy: terminal first, the screen only where no command does it. Websites only through the UI. macOS: your own shell"
        if FileManager.default.fileExists(atPath: VM.sshConfig.path) { line += "; Linux: \(VM.shell) '<command>'" }
        return line + "."
    }

    /// Sets `key = value` under `[section]` in config.toml, adding either if missing. Used only for
    /// choices the user makes in the start-up window; the LLM has no command for it.
    static func remember(_ section: String, _ key: String, _ value: String) {
        var lines = ((try? String(contentsOf: path, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        let header = "[\(section)]"
        if let start = lines.firstIndex(of: header) {
            var i = start + 1
            while i < lines.count, !lines[i].hasPrefix("[") {
                if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(key + " ") || lines[i].hasPrefix(key + "=") {
                    lines[i] = "\(key) = \(value)"
                    try? lines.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
                    return
                }
                i += 1
            }
            lines.insert("\(key) = \(value)", at: start + 1)
        } else {
            lines += ["", header, "\(key) = \(value)"]
        }
        try? lines.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
    }

    static func parseAllow(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func load() -> Config {
        var c = Config()
        let toml = Layers.config()
        // Apps on the Mac and in the VM run `fastest` unless `[pace.default]` says otherwise: no site watches them.
        if let d = toml["pace.default"] { c.pace = PaceConfig(d) } else if let fastest = PaceConfig.preset("fastest", on: c.pace) { c.pace = fastest }
        c.defaultPace = c.pace
        // Built in, under anything the file says: web pages at `steady`, social sites at `careful`
        // (BOT_DETECTION S1). `[pace.styles] fast = ["web"]` undoes it.
        var styled: [String: PaceConfig] = [:]
        if let steady = PaceConfig.preset("steady", on: c.pace) { styled["web"] = steady }
        if let careful = PaceConfig.preset("careful", on: c.pace) {
            for site in socialSites { styled[site] = careful }
        }
        // `[pace.styles] careful = ["linkedin.com", "x.com"]`: a style for each listed site or app.
        // A `[pace."<site>"]` section for the same site starts from that style and lists what differs.
        for (style, raw) in toml["pace.styles"] ?? [:] {
            guard let preset = PaceConfig.preset(style.lowercased(), on: c.pace) else { continue }
            for site in Toml.array(raw) ?? [] where !site.isEmpty { styled[site.lowercased()] = preset }
        }
        c.profiles = styled
        for (section, values) in toml where section.hasPrefix("pace.") && !["pace.default", "pace.styles"].contains(section) {
            // Lower case, as the lookups are, so `[pace."LinkedIn.com"]` and `[pace."Safari"]` match in any spelling.
            let key = String(section.dropFirst("pace.".count)).lowercased()
            c.profiles[key] = PaceConfig(values, base: styled[key] ?? c.pace)
        }
        if let s = toml["session"] {
            if let a = s["allow"].flatMap(Toml.array) { c.allow = a }
            else if let one = s["allow"] { c.allow = parseAllow(Toml.unquote(one)) }
        }
        if let v = toml["agent"]?["ui_only"] { c.uiOnly = Toml.unquote(v) == "true" }
        if let v = toml["agent"]?["ask_on_start"] { c.askOnStart = Toml.unquote(v) == "true" }
        if let v = toml["agent"]?["ask_sound"] { c.askSound = Toml.unquote(v) }
        if let v = toml["agent"]?["keep_awake"] { c.keepAwake = Toml.unquote(v) == "true" }
        if let v = toml["agent"]?["menu_bar"] { c.menuBar = Toml.unquote(v) != "false" }
        if let v = toml["typing"]?["learn"] { c.typingLearn = Toml.unquote(v) != "false" }
        if let v = toml["agent"]?["optional_questions"] { c.optionalQuestions = Toml.unquote(v) != "false" }
        if let v = toml["agent"]?["optional_wait_s"].flatMap({ Double(Toml.unquote($0)) }), v.isFinite { c.optionalWaitSeconds = min(max(v, 10), 600) }
        if let v = toml["agent"]?["optional_every_h"].flatMap({ Double(Toml.unquote($0)) }), v.isFinite { c.optionalEveryHours = min(max(v, 0.25), 168) }
        if let v = toml["agent"]?["dock_icon"] { c.dockIcon = Toml.unquote(v) != "false" }
        if let v = toml["agent"]?["notifications"] { c.notifications = Toml.unquote(v) == "true" }
        if let v = toml["agent"]?["sounds"] { c.sounds = Toml.unquote(v) != "false" }
        if let v = toml["agent"]?["overlay"] { c.overlay = Toml.unquote(v) != "false" }
        if let v = toml["agent"]?["ask_in"] { c.askIn = Toml.unquote(v) }
        if let v = toml["agent"]?["notify"] { c.notify = Toml.unquote(v) }
        if let v = toml["agent"]?["download_menu"].flatMap(Toml.array) { c.downloadMenu = v.map { $0.lowercased() } }
        if let v = toml["agent"]?["browsers"].flatMap(Toml.array) { c.browsers = v }
        if let v = toml["sites"]?["soft_block"].flatMap(Toml.array) { c.softBlockPhrases = v.map { $0.lowercased() } }
        if let v = toml["sites"]?["challenge"].flatMap(Toml.array) { c.challengeMarkers = v.map { $0.lowercased() } }
        // `_extra` lists add to the built-in ones instead of replacing them.
        if let v = toml["sites"]?["soft_block_extra"].flatMap(Toml.array) { c.softBlockPhrases += v.map { $0.lowercased() } }
        if let v = toml["sites"]?["challenge_extra"].flatMap(Toml.array) { c.challengeMarkers += v.map { $0.lowercased() } }
        for (kind, raw) in toml["sites.kinds"] ?? [:] { c.kindWords[kind.lowercased()] = (Toml.array(raw) ?? []).map { $0.lowercased() } }
        if let v = toml["sites"]?["on_soft_block"].map(Toml.unquote), ["stop", "warn", "off"].contains(v) { c.onSoftBlock = v }
        if let v = toml["sites"]?["cooldown_hours"].flatMap(Toml.doubles), !v.isEmpty { c.cooldownHours = v }
        if let v = toml["sites"]?["on_challenge"].map(Toml.unquote), ["stop", "warn", "off"].contains(v) { c.onChallenge = v }
        if let v = toml["login"]?["auto"] { c.loginAuto = Toml.unquote(v) == "true" }
        if let v = toml["login"]?["gap_min"].flatMap({ Double(Toml.unquote($0)) }) { c.loginGapMinutes = v }
        if let v = toml["login"]?["per_day"].flatMap({ Int(Toml.unquote($0)) }) { c.loginPerDay = v }
        if let v = toml["login"]?["sites"].flatMap(Toml.array) { c.loginSites = v.map { $0.lowercased() }.filter { !$0.isEmpty } }
        if let v = toml["gate"]?["user_only"].flatMap(Toml.array) { c.userOnly = v.map { $0.lowercased() }.filter { !$0.isEmpty } }
        if let v = toml["agent"]?["ask_window_s"].flatMap({ Double(Toml.unquote($0)) }) { c.askWindowSeconds = v }
        if let v = toml["schedules"]?["enabled"] { c.schedulesOn = Toml.unquote(v) != "false" }
        if let v = toml["app"]?["font"] { c.appFont = Toml.unquote(v) }
        if let v = toml["app"]?["font_size"].flatMap({ Double(Toml.unquote($0)) }), v >= 8, v <= 32 { c.appFontSize = v }
        if let v = toml["app"]?["theme"] { c.appTheme = Toml.unquote(v) }
        if let v = toml["app"]?["keep_scrollback"] { c.keepScrollback = Toml.unquote(v) == "true" }
        if let v = toml["app"]?["copy_on_select"] { c.copyOnSelect = Toml.unquote(v) == "true" }
        // Values as text, without their quotes: `dir = "~/work"` is a folder, not a quoted word.
        for (name, raw) in toml["app.tabs"] ?? [:] { c.tabPresets[name] = Toml.table(raw).mapValues(Toml.unquote) }
        if let r = toml["run"] {
            if let v = r["base_url"] { c.runURL = Toml.unquote(v) }
            if let v = r["model"] { c.runModel = Toml.unquote(v) }
            if let v = r["api_key"] { c.runKey = Toml.unquote(v) }
            if let v = r["vision_model"] { c.visionModel = Toml.unquote(v) }
            if let v = r["max_steps"].flatMap({ Int(Toml.unquote($0)) }), v >= 1, v <= 500 { c.runMaxSteps = v }
            if let v = r["max_minutes"].flatMap({ Double(Toml.unquote($0)) }), v > 0, v <= 240 { c.runMaxMinutes = v }
        }
        if let v = toml["flow"]?["sh_timeout_s"].flatMap({ Double(Toml.unquote($0)) }), v >= 1, v <= 3600 { c.flowShellSeconds = v }
        // A fixed order, so the same environment always means the same model: OPENAI_* first, then
        // APPRENTICE_* on top (K2).
        let env = ProcessInfo.processInfo.environment
        if let v = env["OPENAI_BASE_URL"] { c.runURL = v }
        if let v = env["OPENAI_API_KEY"] { c.runKey = v }
        if let v = env["OPENAI_MODEL"] { c.runModel = v }
        if let v = env["APPRENTICE_BASE_URL"] { c.runURL = v }
        if let v = env["APPRENTICE_API_KEY"] { c.runKey = v }
        if let v = env["APPRENTICE_MODEL"] { c.runModel = v }
        if let v = env["APPRENTICE_UI_ONLY"] { c.uiOnly = ["1", "true", "yes"].contains(v.lowercased()) }
        return c
    }

    /// Activates the profile for a domain or app for the next action.
    static func activate(_ key: String?) {
        current.pace = current.defaultPace
        guard let key, let p = current.profiles[key.lowercased()] else { return }
        current.pace = p
    }

    static func profileKey(session: Session, url: String?) -> String {
        // `[pace."linkedin.com"]` also covers www.linkedin.com and any other subdomain.
        if var host = hostOf(url).map(Site.domain) {
            while true {
                if current.profiles[host] != nil { return host }
                guard let dot = host.firstIndex(of: "."), host[host.index(after: dot)...].contains(".") else { break }
                host = String(host[host.index(after: dot)...])
            }
        }
        if current.profiles[session.app.lowercased()] != nil { return session.app.lowercased() }
        return session.isBrowser ? "web" : "native"
    }
}

/// `pace [site [style | default]]`: which style a site or app runs at, kept as `[pace.styles]` lists in
/// config.toml. `fastest` suits a logged-out site the user only reads (scouting): real input still, but
/// no waits, short moves and pasted text. A social site never goes below `steady` here, as its standing is the
/// account's; the user can still list it by hand.
enum PaceStyles {
    static let names = ["fastest", "fast", "steady", "careful"]

    static func run(_ a: Args) throws -> String {
        guard let raw = a.pos.first else { return list(Toml.load(Config.path)["pace.styles"] ?? [:]) }
        let site = key(raw)
        guard let style = a.pos.dropFirst().first?.lowercased() else { return "pace: \(site) at \(current(site))" }
        guard style == "default" || names.contains(style) else { throw Fail(5, "pace <site> \(names.joined(separator: "|"))|default") }
        if let refusal = refusal(site, style) { throw Fail(4, refusal) }
        let lists = moved(site, to: style, in: Toml.load(Config.path)["pace.styles"] ?? [:])
        for name in names {
            let sites = lists[name] ?? []
            let literal = "[" + sites.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
            if sites.isEmpty { Toml.remove(Config.path, "pace.styles", name) } else { Toml.set(Config.path, "pace.styles", name, literal) }
        }
        dropIfEmpty()
        return "pace: \(site) at \(current(site)) from the next command"
    }

    /// The `[pace.styles]` header goes too once its last list does, with the blank line above it.
    static func dropIfEmpty() {
        guard var lines = try? String(contentsOf: Config.path, encoding: .utf8).components(separatedBy: "\n"),
              let (start, end) = Toml.bounds(lines, "pace.styles"), start > 0,
              lines[start..<end].allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return }
        var from = start - 1
        while from > 0, lines[from - 1].trimmingCharacters(in: .whitespaces).isEmpty { from -= 1 }
        lines.removeSubrange(from..<end)
        try? lines.joined(separator: "\n").write(to: Config.path, atomically: true, encoding: .utf8)
    }

    /// A URL or host as the profiles key it (`www.x.com` is `x.com`); an app name lower case.
    static func key(_ raw: String) -> String {
        let host = raw.contains("://") ? hostOf(raw) : (raw.contains(".") && !raw.contains(" ") ? raw : nil)
        return host.map(Site.domain) ?? raw.lowercased()
    }

    static func refusal(_ site: String, _ style: String) -> String? {
        guard Config.socialSites.contains(site), style == "fast" || style == "fastest" else { return nil }
        return "pace: \(site) stays at steady or careful here, as a social site's pace is the account's standing; "
            + "the user can list it under [pace.styles] in \(Config.path.path) by hand"
    }

    /// The `[pace.styles]` lists with `site` in `style`'s alone (in none for `default`), so no site sits in
    /// two lists, where which one won would be chance.
    static func moved(_ site: String, to style: String, in table: [String: String]) -> [String: [String]] {
        var lists: [String: [String]] = [:]
        for name in names {
            let sites = table[name].flatMap(Toml.array) ?? []
            lists[name] = sites.filter { $0.lowercased() != site }
        }
        if style != "default" { lists[style, default: []].append(site) }
        return lists
    }

    static func current(_ site: String) -> String {
        let table = Toml.load(Config.path)["pace.styles"] ?? [:]
        if let name = names.first(where: { (table[$0].flatMap(Toml.array) ?? []).map { $0.lowercased() }.contains(site) }) { return name }
        if Config.socialSites.contains(site) { return "careful (built in for social sites)" }
        return site.contains(".") ? "steady (built in for web pages)" : "fastest (built in for apps)"
    }

    static func list(_ table: [String: String]) -> String {
        let rows = names.compactMap { name -> String? in
            let sites = table[name].flatMap(Toml.array) ?? []
            return sites.isEmpty ? nil : "\(name): \(sites.joined(separator: ", "))"
        }
        return (rows.isEmpty ? ["pace: no sites listed"] : rows)
            .joined(separator: "\n") + "\nbuilt in: web pages steady, social sites careful, apps fastest"
    }
}
