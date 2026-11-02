import Foundation

/// What a session did, read back from `runs/<date>-<session>/steps.jsonl`: `sessions` lists recent ones,
/// `log --session` tells one in a screen. `archive` keeps a scrubbed copy in the clone's `sessions/`, so
/// what was learned survives the 30-day pruning and can travel in a PR (`[storage] sessions`).
enum Sessions {
    static var runs: URL { Store.dir.appendingPathComponent("runs") }

    static func rows(_ folder: URL) -> [[String: Any]] {
        Store.readLines(folder.appendingPathComponent("steps.jsonl"))
    }

    /// Run folders, newest first.
    static func folders() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return items.filter { $0.hasDirectoryPath }.sorted { date($0) > date($1) }
    }

    /// The folder for a session id, or the current session's.
    static func folder(_ id: String?) -> URL? {
        guard let id, !id.isEmpty else { return Store.runFolder() }
        return folders().first { $0.lastPathComponent.hasSuffix("-" + id) || $0.lastPathComponent == id }
    }

    struct Summary {
        var name: String
        var app = "", hosts: [String] = [], models: [String] = [], tasks: [String] = []
        var steps = 0, errors = 0, questions = 0, proposals = 0
        var first: Date?, last: Date?

        var minutes: Int { first.flatMap { f in last.map { Int($0.timeIntervalSince(f) / 60) } } ?? 0 }
    }

    static func summarize(_ name: String, _ rows: [[String: Any]]) -> Summary {
        var s = Summary(name: name)
        for r in rows {
            if let t = (r["ts"] as? String).flatMap(Events.date) { s.first = s.first ?? t; s.last = t }
            if r["cmd"] as? String == "session", let app = r["app"] as? String { s.app = app }
            if let h = (r["host"] as? String) ?? hostOf(r["url"] as? String), !h.isEmpty, !s.hosts.contains(h) { s.hosts.append(h) }
            if let m = r["model"] as? String, !s.models.contains(m) { s.models.append(m) }
            if let t = r["task"] as? String { s.tasks.append(t) }
            if r["cmd"] != nil { s.steps += 1 }
            if r["error"] != nil { s.errors += 1 }
            if r["ask"] != nil || r["show"] != nil { s.questions += 1 }
            if r["proposed"] != nil { s.proposals += 1 }
        }
        return s
    }

    /// `sessions [--limit 10]`: recent sessions, one line each.
    static func list(_ a: Args) -> String {
        let all = folders().prefix(max(a.int("limit", 10), 1))
        guard !all.isEmpty else { return "no sessions yet" }
        var out = ["sessions (newest first) · details: apprentice log --session <id>"]
        for folder in all {
            let s = summarize(folder.lastPathComponent, rows(folder))
            var bits = [s.name]
            if !s.app.isEmpty { bits.append(s.app) }
            if !s.hosts.isEmpty { bits.append(s.hosts.prefix(3).joined(separator: ", ")) }
            bits.append("\(s.steps) steps")
            if s.errors > 0 { bits.append("\(s.errors) errors") }
            bits.append("\(s.minutes) min")
            if !s.models.isEmpty { bits.append(s.models.joined(separator: ", ")) }
            if let t = s.tasks.first { bits.append("\"\(clip(t, 50))\"") }
            out.append(bits.joined(separator: " · "))
        }
        return out.joined(separator: "\n")
    }

    /// `log --session [<id>]`: the whole session, one line per step, then a count.
    static func story(_ id: String?) throws -> String {
        guard let folder = folder(id), FileManager.default.fileExists(atPath: folder.path) else {
            throw Fail(5, "no session \(id ?? "") in \(runs.path): `apprentice sessions` lists them")
        }
        let rows = rows(folder)
        let s = summarize(folder.lastPathComponent, rows)
        var out = ["session \(s.name)" + (s.app.isEmpty ? "" : " · \(s.app)") + (s.models.isEmpty ? "" : " · model \(s.models.joined(separator: ", "))")]
        for r in rows {
            let time = (r["ts"] as? String).flatMap { $0.split(separator: "T").last.map { String($0.prefix(8)) } } ?? ""
            var line: String
            if let t = r["task"] as? String { line = "task: \(t)" }
            else if let p = r["proposed"] as? String { line = "proposed \(p)" }
            else if let g = r["gate"] as? String { line = (r["approved"] as? Bool == true ? "approved " : "denied ") + g }
            else if let e = r["error"] as? String { line = "✗ \(r["failed"] ?? "?") → exit \(r["code"] ?? "?"): \(e.split(separator: "\n").first ?? "")" }
            else if let q = r["ask"] as? String { line = "asked: \(q)" }
            else if let q = r["show"] as? String { line = "asked to point at: \(q)" }
            else if let cmd = r["cmd"] as? String {
                line = cmd
                if let label = r["label"] as? String { line += " \(label) \"\(clip(r["name"] as? String ?? "", 40))\"" }
                if let diff = r["diff"] { line += " · \(diff)" }
                if let code = r["code"] as? Int, code != 0 { line += " · exit \(code)" }
                if let ms = r["ms"] as? Int { line += " · \(ms) ms" }
            } else if let u = r["update"] as? String { line = u }
            else { continue }
            out.append("\(time) \(line)")
        }
        out.append("— \(s.steps) steps · \(s.proposals) proposals · \(s.errors) errors · \(s.questions) questions · \(s.minutes) min")
        return out.joined(separator: "\n")
    }

    // MARK: - screenshots

    /// Keeps the newest `keep` screenshots of a session; approval shots (`gate-…`) always stay.
    static func capShots(_ folder: URL, keep: Int = 50) {
        let dir = folder.appendingPathComponent("shots")
        let shots = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "png" && !$0.lastPathComponent.hasPrefix("gate-") }
        guard shots.count > keep else { return }
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        for old in shots.sorted(by: { date($0) > date($1) }).dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
    }

    // MARK: - the clone's copy

    /// `[storage] sessions`: "scrubbed" (the default) keeps commands, diffs, timings, errors, hosts and the
    /// model; "full" keeps whole rows and URLs; "off" keeps nothing in the clone. Never typed text or images.
    static var mode: String {
        let raw = (Toml.load(Config.path)["storage"]?["sessions"]).map(Toml.unquote)?.lowercased() ?? "scrubbed"
        return ["scrubbed", "full", "off"].contains(raw) ? raw : "scrubbed"
    }

    static var dir: URL { Repo.root.appendingPathComponent("sessions") }

    /// Keys never written to the clone, in any mode.
    static let secret = ["api_key", "apikey", "token", "password", "secret", "path"]
    /// What a scrubbed row may keep. Not `menu`: a menu item's title is screen text (a recent file, a bookmark).
    static let kept: Set<String> = ["ts", "cmd", "code", "failed", "error", "diff", "ms", "waits", "app", "model", "task", "kind",
                                    "vm", "label", "approved", "client", "found", "direction", "count", "combo"]

    static func scrub(_ row: [String: Any], mode: String) -> [String: Any]? {
        var r = row.filter { key, _ in !secret.contains { key.lowercased().contains($0) } }
        if mode == "full" { return r }
        let host = (r["host"] as? String) ?? hostOf(r["url"] as? String)
        r = r.filter { kept.contains($0.key) }
        if let host, !host.isEmpty { r["host"] = host }
        // An error may quote what was on screen: quoted text goes, the shape of the failure stays.
        if let e = r["error"] as? String {
            let first = String(e.split(separator: "\n").first ?? "")
            r["error"] = String(first.replacingOccurrences(of: #""[^"]*""#, with: "\"…\"", options: .regularExpression)
                .replacingOccurrences(of: #"https?://\S+"#, with: "<url>", options: .regularExpression)
                .replacingOccurrences(of: #"(~|/Users|/Volumes|/private|/tmp|/var)/\S*"#, with: "<path>", options: .regularExpression).prefix(160))
        }
        if row["proposed"] != nil { r["proposed"] = true }
        if row["gate"] != nil { r["gate"] = true }
        if row["ask"] != nil { r["asked"] = true }
        if row["show"] != nil { r["asked"] = true }
        if r["task"] is String, let t = r["task"] as? String { r["task"] = clip(t, 200) }
        return r.count > 1 ? r : nil
    }

    /// Writes the scrubbed copy of a run folder into the clone and commits it, when it changed.
    /// Returns the clone path it wrote, or nil.
    @discardableResult
    static func archive(_ folder: URL?) -> String? {
        let mode = mode
        guard mode != "off", let folder, Repo.isGit else { return nil }
        let rows = rows(folder)
        guard rows.contains(where: { $0["cmd"] != nil }) else { return nil }
        var text = ""
        for row in rows {
            guard let r = scrub(row, mode: mode),
                  let data = try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]) else { continue }
            text += String(decoding: data, as: UTF8.self) + "\n"
        }
        let file = dir.appendingPathComponent(folder.lastPathComponent + ".jsonl")
        if (try? String(contentsOf: file, encoding: .utf8)) == text { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil else { return nil }
        let s = summarize(folder.lastPathComponent, rows)
        let on = s.hosts.isEmpty ? s.app : s.hosts.prefix(3).joined(separator: ", ")
        try? Repo.commit("Session \(s.name): \(s.steps) steps\(on.isEmpty ? "" : " on \(on)")", paths: [file.path])
        return file.path
    }

    /// The session that just ended, when a new one starts.
    static func archiveCurrent() { archive(Session.stored.map { Store.runFolder($0) }) }
}
