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

    private static func stripComment(_ line: String) -> String {
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

struct PaceConfig {
    var moveMin = 0.2
    var moveMax = 0.9
    var keyMedian = 0.10
    var keySigma = 0.4
    var betweenMin = 0.5
    var betweenMax = 2.0
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
        self = p
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
    var runURL = "https://api.openai.com/v1"
    var runModel = "gpt-4o-mini"
    var runKey = ""
    var visionModel = ""

    static var current = Config.load()
    static var path: URL { Store.dir.appendingPathComponent("config.toml") }
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

    /// What the LLM may use besides the UI. Robert sets this; agents never change it.
    static var policyLine: String {
        (Session.stored?.uiOnly ?? current.uiOnly)
            ? "policy: UI only. Do every task through deskkontrol, including files and folders; no shell commands for them."
            : "policy: websites only through the UI. Quick macOS tasks (files, folders, opening apps) may use shell commands."
    }

    /// Sets `key = value` under `[section]` in config.toml, adding either if missing. Used only for
    /// choices Robert makes in the start-up window; the LLM has no command for it.
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
        if let r = toml["run"] {
            if let v = r["base_url"] { c.runURL = Toml.unquote(v) }
            if let v = r["model"] { c.runModel = Toml.unquote(v) }
            if let v = r["api_key"] { c.runKey = Toml.unquote(v) }
            if let v = r["vision_model"] { c.visionModel = Toml.unquote(v) }
        }
        for (k, v) in ProcessInfo.processInfo.environment {
            switch k {
            case "DESKKONTROL_BASE_URL": c.runURL = v
            case "DESKKONTROL_MODEL": c.runModel = v
            case "DESKKONTROL_API_KEY": c.runKey = v
            case "OPENAI_BASE_URL": if c.runKey.isEmpty || c.runURL.contains("openai.com") { c.runURL = v }
            case "OPENAI_API_KEY": c.runKey = v
            case "OPENAI_MODEL": c.runModel = v
            case "DESKKONTROL_UI_ONLY": c.uiOnly = ["1", "true", "yes"].contains(v.lowercased())
            default: break
            }
        }
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
