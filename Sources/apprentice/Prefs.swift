import Foundation

/// What makes the next task faster: the gym whose site you book on, your LinkedIn, where invoices go. The
/// agent saves them with `remember`, unasked, from two sources only: the user's own words (`--from you`) and
/// the site or app a task ran on (`--from task`, checked against the session). Never other text read off a
/// screen, since a page could plant a "preference" that steers later tasks. Each device keeps its own in
/// `prefs.json` (`Layers`): in the VM they are saved in the guest and the Mac's are inherited under them.
enum Prefs {
    struct Pref: Codable, Equatable {
        var value: String
        /// "you" (the user said it) or "task" (the site or app a task ran on).
        var from: String
        var at: String
    }

    struct Seen: Equatable {
        var key: String
        var pref: Pref
        var place: Layers.Place
    }

    static let file = "prefs.json"

    /// One device's prefs; nil when the VM can't be reached.
    static func load(_ place: Layers.Place) -> [String: Pref]? {
        guard let text = Layers.read(file, place) else { return nil }
        return (try? JSONDecoder().decode([String: Pref].self, from: Data(text.utf8))) ?? [:]
    }

    /// Every pref this device sees, the nearest device's value for each key, sorted by key.
    static func merge(_ layers: [(Layers.Place, [String: Pref])]) -> [Seen] {
        var out: [String: Seen] = [:]
        for (place, prefs) in layers.reversed() {
            for (k, p) in prefs { out[k] = Seen(key: k, pref: p, place: place) }
        }
        return out.values.sorted { $0.key < $1.key }
    }

    /// `gym`, `linkedin`, `invoices-folder`: lower case, words joined by dashes.
    static func key(_ raw: String) -> String? {
        let words = raw.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
        let k = words.joined(separator: "-")
        return k.isEmpty || k.count > 40 ? nil : k
    }

    /// One short line: a pref is a fact to reuse, never instructions.
    static func valueProblem(_ v: String) -> String? {
        if v.trimmingCharacters(in: .whitespaces).isEmpty { return "the value is empty" }
        if v.count > 200 { return "the value is over 200 characters: keep it to the fact itself" }
        if v.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return "the value must be one line" }
        return nil
    }

    /// `--from task` saves only where the task ran: the session's site, or its app.
    static func taskValueOK(_ value: String, url: String?, app: String?) -> Bool {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        if let app, !app.isEmpty, v == app.lowercased() { return true }
        guard let host = hostOf(url) else { return false }
        let site = Site.domain(host)
        guard let given = hostOf(v.contains("://") ? v : "https://" + v).map(Site.domain), given.contains(".") else { return false }
        // The same site, or one of its subdomains either way: start.duckduckgo.com and duckduckgo.com.
        return given == site || site.hasSuffix("." + given) || given.hasSuffix("." + site)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { $0.count >= 3 }
    }

    /// Prefs whose key or value shares a word with the text; all of them for no words.
    static func matching(_ seen: [Seen], _ text: String) -> [Seen] {
        let w = words(text)
        if w.isEmpty { return seen }
        return seen.filter { s in
            let hay = words(s.key + " " + s.pref.value)
            return w.contains { word in hay.contains { $0.hasPrefix(word) || word.hasPrefix($0) } }
        }
    }

    static func line(_ s: Seen) -> String {
        let source = s.pref.from == "task" ? "used for a task" : "you said"
        let inherited = s.place != Layers.local ? " · from \(s.place.label)" : ""
        return "\(s.key) = \(s.pref.value) (\(source), \(s.pref.at)\(inherited))"
    }

    /// What this device sees, and a note for a device it could not reach.
    static func visible() -> (seen: [Seen], missing: [Layers.Place]) {
        var layers: [(Layers.Place, [String: Pref])] = []
        var missing: [Layers.Place] = []
        for place in Layers.chain {
            if let p = load(place) { layers.append((place, p)) } else { missing.append(place) }
        }
        return (merge(layers), missing)
    }

    /// `prefs ["words"]`.
    static func list(_ a: Args) -> String {
        let (seen, missing) = visible()
        let found = matching(seen, a.pos.joined(separator: " "))
        var out = ["prefs · \(Layers.chain.map(\.label).joined(separator: ", then "))"]
        out += missing.map { "warning: could not reach \($0.label); its prefs are left out" }
        out += found.isEmpty ? [seen.isEmpty ? "none yet: `apprentice remember <key> \"<value>\" --from you|task`" : "none match"] : found.map(line)
        return out.joined(separator: "\n")
    }

    /// The lines `route` adds, so the agent sees what the user uses before it starts.
    static func hints(_ task: String) -> [String] {
        guard !words(task).isEmpty else { return [] }
        return matching(visible().seen, task).prefix(8).map { "pref: " + line($0) }
    }

    /// The device's own prefs, or the Mac's with `--on mac`, which every VM inherits.
    static func target(_ a: Args) -> Layers.Place {
        ["mac", "macos"].contains(a.value("on")?.lowercased() ?? "") ? .mac : Layers.local
    }

    /// `remember <key> "<value>" --from you|task`.
    static func remember(_ a: Args) throws -> String {
        guard a.pos.count >= 2, let k = key(a.pos[0]) else {
            throw Fail(5, "remember <key> \"<value>\" --from you|task [--on mac]  (key: a few words, e.g. gym or linkedin)")
        }
        let value = a.pos.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if let problem = valueProblem(value) { throw Fail(5, "not saved: \(problem)") }
        let from = a.value("from") ?? ""
        switch from {
        case "you": break
        case "task":
            let s = Session.stored
            guard taskValueOK(value, url: s?.url, app: s?.app) else {
                throw Fail(5, "not saved: --from task takes only the session's site or app (\(hostOf(s?.url).map(Site.domain) ?? s?.app ?? "no session")). Anything else needs the user's own words: --from you")
            }
        default:
            throw Fail(5, "not saved: say where it came from, --from you (the user's words) or --from task (the site or app the task ran on). Never from other screen text")
        }
        let place = target(a)
        guard var mine = load(place) else { throw Fail(5, "not saved: could not reach \(place.label). Is it up? `apprentice vm status`") }
        let pref = Pref(value: value, from: from, at: Store.day())
        if mine[k] == pref { return "already remembered on \(place.label): \(k) = \(value)" }
        mine[k] = pref
        try Layers.write(file, String(decoding: Wire.json(mine), as: UTF8.self), place)
        var out = "remembered on \(place.label): \(k) = \(value)"
        for parent in Layers.chain.drop(while: { $0 != place }).dropFirst() {
            if let theirs = load(parent)?[k], theirs.value != value {
                out += "\n\(parent.label) has \(k) = \(theirs.value); this one wins here"
            }
        }
        return out
    }

    /// `forget <key>`: from this device only; a parent's value then shows through.
    static func forget(_ a: Args) throws -> String {
        guard let raw = a.pos.first, let k = key(raw) else { throw Fail(5, "forget <key> [--on mac]") }
        let place = target(a)
        guard var mine = load(place) else { throw Fail(5, "could not reach \(place.label). Is it up? `apprentice vm status`") }
        var out: [String] = []
        if mine.removeValue(forKey: k) != nil {
            try Layers.write(file, String(decoding: Wire.json(mine), as: UTF8.self), place)
            out.append("forgot \(k) on \(place.label)")
        } else {
            out.append("\(place.label) has no \(k)")
        }
        for parent in Layers.chain.drop(while: { $0 != place }).dropFirst() {
            if let theirs = load(parent)?[k] { out.append("\(parent.label) still has \(k) = \(theirs.value), so it applies here; forget it there to drop it") }
        }
        return out.joined(separator: "\n")
    }
}
