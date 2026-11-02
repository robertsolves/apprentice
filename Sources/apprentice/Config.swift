import Foundation

/// A deliberately small TOML reader: sections, `key = value`, strings, numbers,
/// `[a, b]` arrays and one-line `{ k = v }` tables. That covers config.toml.
enum Toml {
    static func load(_ path: URL) -> [String: [String: String]] {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [:] }
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
        return s.dropFirst().dropLast().split(separator: ",").map { unquote(String($0)) }
    }

    static func doubles(_ s: String) -> [Double]? {
        array(s)?.compactMap { Double($0) }
    }

    static func table(_ s: String) -> [String: String] {
        guard s.hasPrefix("{"), s.hasSuffix("}") else { return [:] }
        var out: [String: String] = [:]
        for part in s.dropFirst().dropLast().split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { out[pair[0]] = pair[1] }
        }
        return out
    }
}

/// Keystrokes keep a slight human rhythm; cursor travel and the pause between actions do not wait
/// by default. A site profile can put the gaps back (`between_actions_ms`, `move_ms`).
struct PaceConfig {
    var moveMin = 0.05
    var moveMax = 0.2
    var keyMedian = 0.10
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

    init() {}

    /// `style = "fastest" | "fast" | "steady" | "careful"`: the timing keys at once. `fast` is the
    /// built-in default; `careful` is the least likely to be taken for a script and the slowest.
    /// Limits that guard the account (navigation gap, reload cap) are never loosened by a style.
    static func preset(_ name: String, on base: PaceConfig) -> PaceConfig? {
        var p = base
        switch name {
        case "fastest":
            (p.moveMin, p.moveMax, p.keyMedian, p.keySigma) = (0.03, 0.09, 0.045, 0.3)
            (p.betweenMin, p.betweenMax, p.dwellMin, p.dwellMax, p.burstMin, p.burstMax) = (0, 0, 0, 0, 0, 0)
            (p.keyErrorRate, p.overshoot, p.fidget, p.mode) = (0, 0.1, 0, "fast")
        case "fast":
            let d = PaceConfig()
            (p.moveMin, p.moveMax, p.keyMedian, p.keySigma) = (d.moveMin, d.moveMax, d.keyMedian, d.keySigma)
            (p.betweenMin, p.betweenMax, p.dwellMin, p.dwellMax, p.burstMin, p.burstMax) = (0, 0, 0, 0, 0, 0)
            (p.keyErrorRate, p.overshoot, p.fidget, p.mode) = (0, d.overshoot, 0, "human")
        case "steady":
            (p.moveMin, p.moveMax, p.keyMedian, p.keySigma) = (0.12, 0.5, 0.12, 0.4)
            (p.betweenMin, p.betweenMax, p.dwellMin, p.dwellMax, p.burstMin, p.burstMax) = (0.5, 2.5, 1, 3, 0, 0)
            (p.keyErrorRate, p.overshoot, p.fidget, p.mode) = (0.008, 0.4, 0.1, "human")
            p.actionsPerMin = min(p.actionsPerMin, 15)
        case "careful":
            (p.moveMin, p.moveMax, p.keyMedian, p.keySigma) = (0.25, 1.0, 0.14, 0.45)
            (p.betweenMin, p.betweenMax, p.dwellMin, p.dwellMax, p.burstMin, p.burstMax) = (3, 12, 3, 8, 3, 6)
            (p.restMin, p.restMax) = (30, 120)
            (p.keyErrorRate, p.overshoot, p.fidget, p.mode) = (0.015, 0.45, 0.25, "human")
            p.actionsPerMin = min(p.actionsPerMin, 6)
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
        return p
    }
}

struct Config {
    var pace = PaceConfig()
    var defaultPace = PaceConfig()
    var profiles: [String: PaceConfig] = [:]
    var allow: [String] = []
    /// When true, macOS tasks go through the UI too; the LLM may not use shell commands for them.
    var uiOnly = false
    var askOnStart = true
    /// The system sound played when the little window pops up; "none" turns it off.
    var askSound = "Ping"
    var keepAwake = false
    /// The menu-bar item that says whether apprentice is working, waiting for the user or holding a proposal.
    var menuBar = true
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
    /// Text a site shows when it throttles the account; seeing one after an action cools the site down.
    var softBlockPhrases = [
        "try again later", "you're doing that too much", "you are doing that too much", "temporarily restricted",
        "temporarily blocked", "unusual activity", "we limit how often", "rate limit", "too many requests",
        "action blocked", "suspicious activity", "temporarily limited", "over the daily limit",
    ]
    /// What a soft block does: "stop" cools the site down and refuses actions there until it ends,
    /// "warn" only says so, "off" does not look.
    var onSoftBlock = "stop"
    /// How long each cooldown lasts in hours: the first, the second, then every later one.
    var cooldownHours = [1.0, 6, 24]
    /// What a CAPTCHA or identity check does: "stop" refuses actions on the site while it is on screen,
    /// "warn" only says so, "off" does not look. apprentice never completes one in any mode.
    var onChallenge = "stop"
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
    ]

    static var current = Config.load()
    static var path: URL { Settings.dir.appendingPathComponent("config.toml") }
    private static var loadedAt: Date?

    /// Re-reads config.toml only when it changed, and starts each command on the default pace.
    static func reloadIfChanged() {
        let stamp = (try? path.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if stamp != loadedAt {
            loadedAt = stamp
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
        let toml = Toml.load(path)
        if let d = toml["pace.default"] { c.pace = PaceConfig(d) }
        c.defaultPace = c.pace
        // `[pace.styles] careful = ["linkedin.com", "x.com"]`: a style for each listed site or app.
        // A `[pace."<site>"]` section for the same site starts from that style and lists what differs.
        var styled: [String: PaceConfig] = [:]
        for (style, raw) in toml["pace.styles"] ?? [:] {
            guard let preset = PaceConfig.preset(style.lowercased(), on: c.pace) else { continue }
            for site in Toml.array(raw) ?? [] where !site.isEmpty { styled[site.lowercased()] = preset }
        }
        c.profiles = styled
        for (section, values) in toml where section.hasPrefix("pace.") && !["pace.default", "pace.styles"].contains(section) {
            let key = String(section.dropFirst("pace.".count))
            c.profiles[key] = PaceConfig(values, base: styled[key.lowercased()] ?? c.pace)
        }
        if let s = toml["session"] {
            if let a = s["allow"].flatMap(Toml.array) { c.allow = a }
            else if let one = s["allow"] { c.allow = parseAllow(Toml.unquote(one)) }
        }
        if let v = toml["agent"]?["ui_only"] { c.uiOnly = Toml.unquote(v) == "true" }
        if let v = toml["agent"]?["ask_on_start"] { c.askOnStart = Toml.unquote(v) != "false" }
        if let v = toml["agent"]?["ask_sound"] { c.askSound = Toml.unquote(v) }
        if let v = toml["agent"]?["keep_awake"] { c.keepAwake = Toml.unquote(v) == "true" }
        if let v = toml["agent"]?["menu_bar"] { c.menuBar = Toml.unquote(v) != "false" }
        if let v = toml["agent"]?["ask_in"] { c.askIn = Toml.unquote(v) }
        if let v = toml["agent"]?["notify"] { c.notify = Toml.unquote(v) }
        if let v = toml["agent"]?["download_menu"].flatMap(Toml.array) { c.downloadMenu = v.map { $0.lowercased() } }
        if let v = toml["agent"]?["browsers"].flatMap(Toml.array) { c.browsers = v }
        if let v = toml["sites"]?["soft_block"].flatMap(Toml.array) { c.softBlockPhrases = v.map { $0.lowercased() } }
        if let v = toml["sites"]?["challenge"].flatMap(Toml.array) { c.challengeMarkers = v.map { $0.lowercased() } }
        if let v = toml["sites"]?["on_soft_block"].map(Toml.unquote), ["stop", "warn", "off"].contains(v) { c.onSoftBlock = v }
        if let v = toml["sites"]?["cooldown_hours"].flatMap(Toml.doubles), !v.isEmpty { c.cooldownHours = v }
        if let v = toml["sites"]?["on_challenge"].map(Toml.unquote), ["stop", "warn", "off"].contains(v) { c.onChallenge = v }
        if let v = toml["gate"]?["user_only"].flatMap(Toml.array) { c.userOnly = v.map { $0.lowercased() }.filter { !$0.isEmpty } }
        if let v = toml["agent"]?["ask_window_s"].flatMap({ Double(Toml.unquote($0)) }) { c.askWindowSeconds = v }
        if let r = toml["run"] {
            if let v = r["base_url"] { c.runURL = Toml.unquote(v) }
            if let v = r["model"] { c.runModel = Toml.unquote(v) }
            if let v = r["api_key"] { c.runKey = Toml.unquote(v) }
            if let v = r["vision_model"] { c.visionModel = Toml.unquote(v) }
        }
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
        guard let key, let p = current.profiles[key] else { return }
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
        if current.profiles[session.app] != nil { return session.app }
        return session.isBrowser ? "web" : "native"
    }
}
