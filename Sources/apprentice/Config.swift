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

    init() {}

    init(_ values: [String: String], base: PaceConfig = PaceConfig()) {
        var p = base
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
    /// Where questions go: "both" (the window, then the chat if unanswered), "window", or "terminal".
    var askIn = "both"
    var askWindowSeconds = 60.0
    /// Context-menu items `download` looks for, matched lower case; add your system language's.
    var downloadMenu = ["save image as", "download linked file", "save link as", "download image"]
    /// Bundle ids treated as browsers on top of every app registered to open https links.
    var browsers: [String] = []
    var runURL = "https://api.openai.com/v1"
    var runModel = "gpt-4o-mini"
    var runKey = ""
    var visionModel = ""

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
    static var policyLine: String {
        (Session.stored?.uiOnly ?? current.uiOnly)
            ? "policy: UI only. Do every task through apprentice, including files and folders; no shell commands for them."
            : "policy: websites only through the UI. Quick macOS tasks (files, folders, opening apps) may use shell commands."
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
        for (section, values) in toml where section.hasPrefix("pace.") && section != "pace.default" {
            let key = String(section.dropFirst("pace.".count))
            c.profiles[key] = PaceConfig(values, base: c.pace)
        }
        if let s = toml["session"] {
            if let a = s["allow"].flatMap(Toml.array) { c.allow = a }
            else if let one = s["allow"] { c.allow = parseAllow(Toml.unquote(one)) }
        }
        if let v = toml["agent"]?["ui_only"] { c.uiOnly = Toml.unquote(v) == "true" }
        if let v = toml["agent"]?["ask_on_start"] { c.askOnStart = Toml.unquote(v) != "false" }
        if let v = toml["agent"]?["ask_sound"] { c.askSound = Toml.unquote(v) }
        if let v = toml["agent"]?["keep_awake"] { c.keepAwake = Toml.unquote(v) == "true" }
        if let v = toml["agent"]?["ask_in"] { c.askIn = Toml.unquote(v) }
        if let v = toml["agent"]?["download_menu"].flatMap(Toml.array) { c.downloadMenu = v.map { $0.lowercased() } }
        if let v = toml["agent"]?["browsers"].flatMap(Toml.array) { c.browsers = v }
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
        if let host = hostOf(url), current.profiles[host] != nil { return host }
        if current.profiles[session.app] != nil { return session.app }
        return session.isBrowser ? "web" : "native"
    }
}
