import Foundation

/// Each website's own settings, for the window's Sites screen: its pace, a person's day there and its caps
/// per action. What the screen shows comes from `agent/site-settings.toml` (fields, groups and presets), so a
/// new setting or preset is a line in that file. Values are written where the commands already read them:
/// `[pace."<site>"]` and the `[pace.styles]` lists in config.toml (as `pace <site> <style>` does), and the
/// site's entry in budgets.json. `web` is every website without settings of its own (`[pace.web]` and
/// budgets.json's `default`).
enum SiteSettings {
    static let everyWebsite = "web"

    struct Group: Identifiable {
        let id: String
        let title: String
        let about: String
    }

    struct Field: Identifiable {
        let id: String
        let group: String
        /// "pace", "style" or "budget".
        let store: String
        /// "choice", "number", "range", "percent", "hours" or "cap".
        let type: String
        let key: String
        let label: String
        let help: String
        let unit: String
        /// What 0 means for a number ("no limit"); empty when 0 is just 0.
        let zero: String
        let choices: [String]
        let labels: [String]
        let notes: [String]
        let min: Double
        let max: Double
        let step: Double
        /// The file holds the shown value times this (milliseconds shown as seconds).
        let scale: Double
        /// The sites the field is for; empty for every site.
        let only: [String]

        func applies(to site: String) -> Bool { only.isEmpty || only.contains(site) }
    }

    struct Preset: Identifiable {
        let site: String
        let label: String
        let icon: String
        /// Field id → the value as the file takes it.
        let values: [String: String]
        var id: String { site }
    }

    struct Spec {
        var title = "Sites"
        var subtitle = ""
        var about = ""
        var points: [String] = []
        var groups: [Group] = []
        var fields: [Field] = []
        var presets: [Preset] = []

        func preset(_ site: String) -> Preset? { presets.first { $0.site == site } }
        func label(_ site: String) -> String { site == everyWebsite ? "Every website" : preset(site)?.label ?? site }
    }

    static let types: Set<String> = ["choice", "number", "range", "percent", "hours", "cap"]
    static let stores: Set<String> = ["pace", "style", "budget"]

    static var specFile: URL { Repo.resources.appendingPathComponent("agent/site-settings.toml") }

    static func spec(_ file: URL = specFile) -> Spec {
        parse((try? String(contentsOf: file, encoding: .utf8)) ?? "")
    }

    /// The spec in the order its sections are written, which is the order the screen shows them.
    static func parse(_ text: String) -> Spec {
        let table = Toml.parse(text)
        var order: [String] = []
        for line in text.components(separatedBy: "\n") {
            if let h = Toml.header(line).map(Toml.canonical), !order.contains(h) { order.append(h) }
        }
        var spec = Spec()
        func s(_ v: [String: String], _ k: String) -> String { v[k].map(Toml.unquote) ?? "" }
        func list(_ v: [String: String], _ k: String) -> [String] { v[k].flatMap(Toml.array) ?? [] }
        func d(_ v: [String: String], _ k: String, _ fallback: Double) -> Double { v[k].flatMap { Double(Toml.unquote($0)) } ?? fallback }
        if let screen = table["screen"] {
            spec.title = s(screen, "title").isEmpty ? spec.title : s(screen, "title")
            spec.subtitle = s(screen, "subtitle")
            spec.about = s(screen, "about")
            spec.points = list(screen, "points")
        }
        for section in order {
            guard let v = table[section] else { continue }
            if section.hasPrefix("group.") {
                spec.groups.append(Group(id: String(section.dropFirst(6)), title: s(v, "title"), about: s(v, "about")))
            } else if section.hasPrefix("field.") {
                spec.fields.append(Field(
                    id: String(section.dropFirst(6)), group: s(v, "group"), store: s(v, "store"), type: s(v, "type"),
                    key: s(v, "key"), label: s(v, "label"), help: s(v, "help"), unit: s(v, "unit"), zero: s(v, "zero"),
                    choices: list(v, "choices"), labels: list(v, "labels"), notes: list(v, "notes"),
                    min: d(v, "min", 0), max: d(v, "max", 100_000), step: d(v, "step", 1), scale: d(v, "scale", 1),
                    only: list(v, "only").map { $0.lowercased() }))
            } else if section.hasPrefix("preset.") {
                var values = v
                let label = s(v, "label"), icon = s(v, "icon")
                values["label"] = nil
                values["icon"] = nil
                spec.presets.append(Preset(site: String(section.dropFirst(7)).lowercased(), label: label,
                                           icon: icon.isEmpty ? "globe" : icon, values: values))
            }
        }
        return spec
    }

    /// What is wrong with a spec, so a typo in it shows in `selftest` rather than as a blank control.
    static func problems(_ spec: Spec) -> [String] {
        var out: [String] = []
        let groups = Set(spec.groups.map(\.id))
        for f in spec.fields {
            if !types.contains(f.type) { out.append("field.\(f.id): type \"\(f.type)\"") }
            if !stores.contains(f.store) { out.append("field.\(f.id): store \"\(f.store)\"") }
            if !groups.contains(f.group) { out.append("field.\(f.id): group \"\(f.group)\"") }
            if f.key.isEmpty || f.label.isEmpty { out.append("field.\(f.id): needs key and label") }
            if f.type == "choice", f.choices.isEmpty || f.labels.count != f.choices.count { out.append("field.\(f.id): choices and labels") }
            if f.store == "pace", PaceConfig().literal(f.key) == nil { out.append("field.\(f.id): unknown pace key \(f.key)") }
        }
        for p in spec.presets {
            if p.label.isEmpty { out.append("preset.\(p.site): needs a label") }
            for (id, value) in p.values {
                guard let f = spec.fields.first(where: { $0.id == id }) else { out.append("preset.\(p.site): no field \(id)"); continue }
                if f.type == "choice", !f.choices.contains(Toml.unquote(value)) { out.append("preset.\(p.site).\(id): not a choice") }
                if f.type == "cap", cap(value) == nil { out.append("preset.\(p.site).\(id): not a cap") }
                if let refusal = f.store == "style" ? PaceStyles.refusal(p.site, Toml.unquote(value)) : nil { out.append(refusal) }
            }
        }
        return out
    }

    // MARK: - Where the values live

    struct Files {
        var config = Config.path
        var budgets = Budgets.path
    }

    static func section(_ site: String) -> String { "pace.\"\(site)\"" }
    static func budgetKey(_ site: String) -> String { site == everyWebsite ? "default" : site }

    /// The websites with settings of their own: a pace section, a style list entry or a budgets.json entry.
    static func sites(_ files: Files = Files()) -> [String] {
        let toml = Toml.load(files.config)
        var out = Set<String>()
        for section in toml.keys where section.hasPrefix("pace.") {
            let site = String(section.dropFirst(5)).lowercased()
            if site.contains(".") { out.insert(site) }
        }
        for (_, raw) in toml["pace.styles"] ?? [:] {
            for site in Toml.array(raw) ?? [] where site.contains(".") { out.insert(site.lowercased()) }
        }
        for site in budgetsJSON(files.budgets).keys where site.contains(".") && !site.hasPrefix("_") { out.insert(site) }
        return out.sorted()
    }

    /// The value the site's own settings give a field, as the file writes it; nil when it has none.
    static func explicit(_ site: String, _ field: Field, _ files: Files = Files()) -> String? {
        let toml = Toml.load(files.config)
        switch field.store {
        case "style":
            if let own = toml["pace.\(site)"]?["style"] { return own }
            let lists = toml["pace.styles"] ?? [:]
            return PaceStyles.names.first { (lists[$0].flatMap(Toml.array) ?? []).map { $0.lowercased() }.contains(site) }.map { "\"\($0)\"" }
        case "pace":
            return toml["pace.\(site)"]?[field.key]
        default:
            guard let caps = budgetsJSON(files.budgets)[budgetKey(site)] as? [String: Any], let c = caps[field.key] as? [String: Any] else { return nil }
            return capLiteral(c.compactMapValues { ($0 as? NSNumber)?.doubleValue })
        }
    }

    /// The value that applies when the site's own settings say nothing: its style's, every website's or the
    /// built-in one, read the way the daemon reads it.
    static func usual(_ site: String, _ field: Field, config: Config = Config.load(), files: Files = Files()) -> String {
        switch field.store {
        case "style":
            return "\"\(builtInStyle(site, config: files.config))\""
        case "pace":
            // What applies without this key: the site's style (its own or built in) over the default pace.
            let style = explicit(site, field.with(store: "style"), files).map(Toml.unquote) ?? builtInStyle(site, config: files.config)
            let base = PaceConfig.preset(style, on: config.defaultPace) ?? config.defaultPace
            return base.literal(field.key) ?? ""
        default:
            var table = Budgets.table(files.budgets)
            table[budgetKey(site)]?[field.key] = nil
            let c = Budgets.cap(site == everyWebsite ? "" : site, field.key, table: table)
            return capLiteral(["hour": c.hour, "day": c.day, "week": c.week, "min_gap_s": c.min_gap_s].compactMapValues { $0 })
        }
    }

    /// The style a site runs at with no list naming it: every website's for a site (steady unless the
    /// `web` list moved), careful for a social site.
    static func builtInStyle(_ site: String, config: URL) -> String {
        if Config.socialSites.contains(site) { return "careful" }
        if site != everyWebsite {
            let lists = Toml.load(config)["pace.styles"] ?? [:]
            if let web = PaceStyles.names.first(where: { (lists[$0].flatMap(Toml.array) ?? []).contains(everyWebsite) }) { return web }
        }
        return "steady"
    }

    // MARK: - Writing

    /// Sets one field for a site (nil puts the usual value back).
    static func set(_ site: String, _ field: Field, _ literal: String?, _ files: Files = Files()) throws {
        switch field.store {
        case "style":
            let style = literal.map(Toml.unquote) ?? "default"
            if let refusal = PaceStyles.refusal(site, style) { throw Fail(4, refusal) }
            Toml.remove(files.config, section(site), "style")
            removeSection(files.config, section(site), onlyIfEmpty: true)
            let lists = PaceStyles.moved(site, to: style, in: Toml.load(files.config)["pace.styles"] ?? [:])
            for name in PaceStyles.names {
                let sites = lists[name] ?? []
                if sites.isEmpty { Toml.remove(files.config, "pace.styles", name) }
                else { Toml.set(files.config, "pace.styles", name, "[" + sites.map { "\"\($0)\"" }.joined(separator: ", ") + "]") }
            }
            removeSection(files.config, "pace.styles", onlyIfEmpty: true)
        case "pace":
            if let literal {
                ensureFile(files.config)
                Toml.set(files.config, section(site), field.key, literal)
            } else {
                Toml.remove(files.config, section(site), field.key)
                removeSection(files.config, section(site), onlyIfEmpty: true)
            }
        default:
            try editBudgets(files.budgets) { all in
                var caps = all[budgetKey(site)] as? [String: Any] ?? [:]
                caps[field.key] = literal.flatMap(cap)
                all[budgetKey(site)] = caps.isEmpty ? nil : caps
            }
        }
    }

    /// Writes a preset over whatever the site had.
    static func apply(_ preset: Preset, spec: Spec, _ files: Files = Files()) throws {
        try remove(preset.site, files)
        for field in spec.fields {
            if let value = preset.values[field.id] { try set(preset.site, field, value, files) }
        }
    }

    /// A website with no preset starts at the style it runs at already, so it shows in the list.
    static func add(_ raw: String, spec: Spec, _ files: Files = Files()) throws -> String {
        let site = PaceStyles.key(raw.trimmingCharacters(in: .whitespaces))
        guard site.contains("."), !site.contains(" ") else { throw Fail(5, "a website is a name like example.com") }
        if let preset = spec.preset(site) { try apply(preset, spec: spec, files); return site }
        if let style = spec.fields.first(where: { $0.store == "style" }) {
            try set(site, style, "\"\(builtInStyle(site, config: files.config))\"", files)
        }
        return site
    }

    /// Everything the site has of its own, in both files.
    static func remove(_ site: String, _ files: Files = Files()) throws {
        try set(site, styleField, nil, files)
        removeSection(files.config, section(site))
        if FileManager.default.fileExists(atPath: files.budgets.path) {
            try editBudgets(files.budgets) { $0[budgetKey(site)] = nil }
        }
    }

    /// The style list entry, for removing it when the spec has no style field.
    static let styleField = Field(id: "style", group: "", store: "style", type: "choice", key: "style", label: "", help: "", unit: "",
                                  zero: "", choices: [], labels: [], notes: [], min: 0, max: 0, step: 1, scale: 1, only: [])

    static func ensureFile(_ url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }

    /// Takes a section out of a TOML file with its header (only when nothing is left in it, with
    /// `onlyIfEmpty`), and the blank lines before it.
    static func removeSection(_ path: URL, _ section: String, onlyIfEmpty: Bool = false) {
        guard var lines = try? String(contentsOf: path, encoding: .utf8).components(separatedBy: "\n"),
              let (start, end) = Toml.bounds(lines, section), start > 0 else { return }
        if onlyIfEmpty, !lines[start..<end].allSatisfy({ Toml.stripComment($0).trimmingCharacters(in: .whitespaces).isEmpty }) { return }
        var from = start - 1
        while from > 0, lines[from - 1].trimmingCharacters(in: .whitespaces).isEmpty { from -= 1 }
        lines.removeSubrange(from..<end)
        // One blank line still parts what was before from the next section, and the file still ends in a newline.
        if from > 0 { lines.insert("", at: from) }
        try? lines.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
    }

    // MARK: - budgets.json

    static func budgetsJSON(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Changes budgets.json in place. A file that is there but not JSON is left alone: it stops every
    /// budgeted action until it is fixed, and overwriting it would lose what the person wrote.
    static func editBudgets(_ url: URL, _ change: (inout [String: Any]) -> Void) throws {
        var all: [String: Any] = [:]
        if let data = try? Data(contentsOf: url) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw Fail(4, "\(url.path) is not valid JSON; fix it by hand first")
            }
            all = parsed
        }
        change(&all)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try budgetsText(all).write(to: url, atomically: true, encoding: .utf8)
    }

    /// budgets.json as the example writes it: one line per kind, notes first, `default` before the sites.
    static func budgetsText(_ all: [String: Any]) -> String {
        func str(_ s: String) -> String {
            (try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        }
        func value(_ v: Any) -> String {
            if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return number(n.doubleValue) }
            if let s = v as? String { return str(s) }
            if let d = v as? [String: Any] {
                let order = ["hour", "day", "week", "min_gap_s"]
                let keys = d.keys.sorted { (order.firstIndex(of: $0) ?? 9, $0) < (order.firstIndex(of: $1) ?? 9, $1) }
                return "{ " + keys.map { "\(str($0)): \(value(d[$0]!))" }.joined(separator: ", ") + " }"
            }
            return (try? JSONSerialization.data(withJSONObject: v, options: .fragmentsAllowed)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        }
        func rank(_ k: String) -> Int { k.hasPrefix("_") ? 0 : k == "default" ? 1 : 2 }
        let sites = all.keys.sorted { (rank($0), $0) < (rank($1), $1) }
        let body = sites.map { site -> String in
            guard let kinds = all[site] as? [String: Any] else { return "  \(str(site)): \(value(all[site]!))" }
            func note(_ k: String) -> Int { k == "inherit" || k.hasPrefix("_") ? 0 : 1 }
            let keys = kinds.keys.sorted { (note($0), $0) < (note($1), $1) }
            let rows = keys.map { "    \(str($0)): \(value(kinds[$0]!))" }
            return "  \(str(site)): {\n" + rows.joined(separator: ",\n") + "\n  }"
        }
        return "{\n" + body.joined(separator: ",\n") + "\n}\n"
    }

    /// `{ hour = 1, day = 3, min_gap_s = 1800 }` as budgets.json's numbers; nil when it holds none.
    static func cap(_ literal: String) -> [String: Any]? {
        let t = Toml.table(literal.trimmingCharacters(in: .whitespaces))
        var out: [String: Any] = [:]
        for k in ["hour", "day", "week", "min_gap_s"] {
            if let v = t[k].flatMap({ Double(Toml.unquote($0)) }), v.isFinite, v >= 0 { out[k] = v == v.rounded() ? Int(v) as Any : v as Any }
        }
        return out.isEmpty ? nil : out
    }

    static func capLiteral(_ c: [String: Double]) -> String {
        let order = ["hour", "day", "week", "min_gap_s"]
        let parts = order.compactMap { k in c[k].map { "\(k) = \(number($0))" } }
        return parts.isEmpty ? "" : "{ " + parts.joined(separator: ", ") + " }"
    }

    /// A number as a person writes it: no `.0`, and no float noise (`150`, not `150.00000000000003`).
    static func number(_ v: Double) -> String {
        let r = (v * 10_000).rounded() / 10_000
        return r == r.rounded() && abs(r) < 1e15 ? String(Int(r)) : String(r)
    }
}

extension SiteSettings.Field {
    func with(store: String) -> SiteSettings.Field {
        SiteSettings.Field(id: id, group: group, store: store, type: type, key: key, label: label, help: help, unit: unit, zero: zero,
                           choices: choices, labels: labels, notes: notes, min: min, max: max, step: step, scale: scale, only: only)
    }
}

extension PaceConfig {
    /// A `[pace]` key's value as the file writes it, so the window shows what applies when the file says
    /// nothing. Nil for a key the reader does not know.
    func literal(_ key: String) -> String? {
        let n = SiteSettings.number
        func pair(_ a: Double, _ b: Double) -> String { "[\(n(a)), \(n(b))]" }
        switch key {
        case "move_ms": return pair(moveMin * 1000, moveMax * 1000)
        case "key_ms_median": return n(keyMedian * 1000)
        case "key_ms_sigma": return n(keySigma)
        case "between_actions_ms": return pair(betweenMin * 1000, betweenMax * 1000)
        case "nav_min_gap_s": return n(navGap)
        case "actions_per_min": return n(actionsPerMin)
        case "dwell_s": return pair(dwellMin, dwellMax)
        case "burst": return pair(burstMin, burstMax)
        case "rest_s": return pair(restMin, restMax)
        case "key_error_rate": return n(keyErrorRate)
        case "overshoot": return n(overshoot)
        case "fidget": return n(fidget)
        case "browse": return n(browseShare)
        case "browse_s": return pair(browseMin, browseMax)
        case "quiet_hours": return quietFrom < 0 ? "[]" : pair(quietFrom, quietTo)
        case "session_max_min": return n(sittingMax)
        case "break_min": return pair(breakMin, breakMax)
        case "actions_per_day": return n(actionsPerDay)
        default: return nil
        }
    }
}
