import Foundation

/// Learned notes: Markdown files about apps, sites and flows, kept in the repo's `notes/`
/// (linked to ~/.apprentice/notes by kit.sh), so `git pull` brings in what was learned elsewhere.
enum Notes {
    struct Note {
        var url: URL
        var path: String
        var meta: [String: String]
        var title: String
        var body: String

        var match: [String] {
            (meta["match"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        }

        /// Bullets under "## Key facts", the part `session` prints.
        var keyFacts: [String] {
            var out: [String] = []
            var inside = false
            for line in body.components(separatedBy: .newlines) {
                if line.hasPrefix("## ") { inside = line.lowercased().hasPrefix("## key facts"); continue }
                if inside, line.hasPrefix("- ") { out.append(String(line.dropFirst(2))) }
            }
            return out
        }
    }

    static var dir: URL {
        if let custom = ProcessInfo.processInfo.environment["APPRENTICE_NOTES"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return Store.dir.appendingPathComponent("notes")
    }

    /// Parsed notes by path, kept while the file's modification date stays the same: `session` reads the
    /// notes three times, and parsing a few hundred files each time adds up.
    private static var cache: [String: (Date, Note)] = [:]
    private static let cacheLock = NSLock()

    static func all() -> [Note] {
        let root = dir.resolvingSymlinksInPath()
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        var out: [Note] = []
        for case let url as URL in walk where url.pathExtension == "md" && url.lastPathComponent != "README.md" {
            let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if let (seen, note) = cache[url.path], seen == stamp { out.append(note); continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let path = String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
            let note = parse(text, url: url, path: path)
            cache[url.path] = (stamp, note)
            out.append(note)
        }
        return out.sorted { $0.path < $1.path }
    }

    static func parse(_ text: String, url: URL, path: String) -> Note {
        var meta: [String: String] = [:]
        var lines = text.components(separatedBy: .newlines)
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            for line in lines[1..<end] {
                guard let colon = line.firstIndex(of: ":") else { continue }
                meta[line[..<colon].trimmingCharacters(in: .whitespaces)] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            lines = Array(lines[(end + 1)...])
        }
        let title = lines.first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? url.deletingPathExtension().lastPathComponent
        return Note(url: url, path: path, meta: meta, title: title, body: lines.joined(separator: "\n"))
    }

    /// App and site notes for this window; flows are left to `notes <query>`. `*` matches every session.
    /// `system` is where the session runs, "macos" or "linux" (the VM): a note with `system:` in its front
    /// matter only shows there, so the VM does not get the Mac's general facts.
    static func matching(app: String?, bundle: String?, host: String?, system: String = "macos") -> [Note] {
        let keys = [app, bundle].compactMap { $0?.lowercased() }
        let h = host?.lowercased()
        return all().filter { $0.meta["scope"] != "flow" && ($0.meta["system"].map { $0 == system } ?? true) }.filter { note in
            note.match.contains { m in
                m == "*" || keys.contains(m) || (h.map { $0 == m || $0.hasSuffix("." + m) } ?? false)
            }
        }
    }

    static func hintLines(app: String?, bundle: String?, host: String?, system: String = "macos") -> [String] {
        let notes = matching(app: app, bundle: bundle, host: host, system: system)
        guard !notes.isEmpty else { return [] }
        var out: [String] = []
        for note in notes {
            out.append("notes · \(note.path)")
            out += note.keyFacts.prefix(6).map { "  - \($0)" }
        }
        out.append("more: apprentice notes \"<words>\"")
        return out
    }

    /// Ranks notes by how many query words they contain and shows the matching lines.
    static func search(_ query: String) -> String {
        let root = dir.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: root.path) else {
            return "no notes at \(dir.path): run ./kit.sh to link the repo's notes/, or set APPRENTICE_NOTES"
        }
        let notes = all()
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 }
        if words.isEmpty {
            return (["notes in \(root.path)"] + notes.map { "\($0.path) · \($0.title)" }).joined(separator: "\n")
        }
        let ranked = notes.map { note -> (Note, Int) in
            let text = (note.path + " " + note.title + " " + (note.meta["tags"] ?? "") + " " + note.body).lowercased()
            return (note, words.filter { text.contains($0) }.count)
        }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        guard !ranked.isEmpty else { return "no notes match \"\(query)\": work it out on screen, then `apprentice learn`" }
        var out: [String] = []
        for (note, _) in ranked.prefix(5) {
            out.append("\(note.path) · \(note.title)")
            let hits = note.body.components(separatedBy: .newlines).filter { line in
                !line.hasPrefix("#") && words.contains { line.lowercased().contains($0) }
            }
            out += hits.prefix(6).map { "  \($0.trimmingCharacters(in: .whitespaces))" }
        }
        out.append("full note: cat \(root.path)/<path>")
        return out.joined(separator: "\n")
    }

    /// Note text for the `run` loop: the window's notes plus the best flow for this task and model, kept
    /// under a budget so a long note cannot crowd out the screen.
    static func context(task: String, session: Session?, model: String? = Store.model, budget: Int = 3000) -> String {
        var parts = hintLines(app: session?.app, bundle: session?.bundle, host: hostOf(session?.url))
        if let best = rank(task: task, model: model, session: session).first {
            parts.append("flow · \(best.note.path) (\(best.why))\n\(best.note.body.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let text = parts.joined(separator: "\n")
        return text.count > budget ? String(text.prefix(budget)) + "\n… (cut; full notes: apprentice notes \"<words>\")" : text
    }

    struct Ranked {
        var note: Note
        var score: Int
        var why: String
    }

    /// Flows for a task, best first. A flow learned by another model is left out unless it says `model: any`
    /// (or names none); one learned by this model ranks first. Then tag words, title words, the window's app
    /// or host, and `status: verified`. A flow needs at least one task word in its tags or title.
    static func rank(task: String, model: String?, session: Session?) -> [Ranked] {
        let words = Set(task.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 })
        let model = model?.lowercased()
        let host = hostOf(session?.url)?.lowercased()
        let app = session?.app.lowercased()
        return all().filter { $0.meta["scope"] == "flow" }.compactMap { note -> Ranked? in
            let flowModel = (note.meta["model"] ?? "any").lowercased()
            if flowModel != "any", flowModel != model { return nil }
            let tags = Set((note.meta["tags"] ?? "").lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            let title = Set(note.title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            let tagHits = words.intersection(tags).count, titleHits = words.subtracting(tags).intersection(title).count
            guard tagHits + titleHits > 0 else { return nil }
            var score = tagHits * 3 + titleHits * 2
            var why = ["\(tagHits) tag + \(titleHits) title words"]
            if flowModel != "any" { score += 6; why.append("learned by \(flowModel)") }
            if note.match.contains(where: { m in m == app || (host.map { $0 == m || $0.hasSuffix("." + m) } ?? false) }) {
                score += 3
                why.append("matches this window")
            }
            if note.meta["status"] == "verified" { score += 2; why.append("verified") }
            return Ranked(note: note, score: score, why: why.joined(separator: ", "))
        }.sorted { $0.score != $1.score ? $0.score > $1.score : $0.note.path < $1.note.path }
    }

    /// `do --explain "task"`: which flow the task would pick, and why.
    static func explain(_ task: String, model: String?, session: Session?) -> String {
        let ranked = rank(task: task, model: model, session: session)
        guard !ranked.isEmpty else { return "no flow fits \"\(task)\" for model \(model ?? "any"): work it out on screen, then `apprentice learn`" }
        var out = ["flows for \"\(task)\" · model \(model ?? "any")"]
        for (i, r) in ranked.prefix(5).enumerated() {
            out.append("\(i == 0 ? "→" : " ") \(r.score) · \(r.note.url.deletingPathExtension().lastPathComponent) · \(r.why)")
        }
        out.append("run it: apprentice do \(ranked[0].note.url.deletingPathExtension().lastPathComponent) --key value")
        return out.joined(separator: "\n")
    }

    static func flow(named name: String) -> Note? {
        let flows = all().filter { $0.meta["scope"] == "flow" }
        return flows.first { $0.url.deletingPathExtension().lastPathComponent == name || $0.path == name }
    }

    /// Numbered lines under "## Steps", without their numbers.
    static func steps(_ note: Note) -> [String] {
        var out: [String] = []
        var inside = false
        for line in note.body.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") { inside = line.lowercased().hasPrefix("## steps"); continue }
            guard inside, let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty else { continue }
            out.append(line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces))
        }
        return out
    }

    // MARK: - bug

    /// The repo that holds the notes (kit.sh links ~/.apprentice/notes into it).
    static var repo: URL { dir.resolvingSymlinksInPath().deletingLastPathComponent() }

    /// Field reports go to the repo's bugs.md when the notes are the repo's own; notes pointed
    /// anywhere else keep their reports beside them (L1).
    static var bugFile: URL {
        let isRepo = FileManager.default.fileExists(atPath: repo.appendingPathComponent("Package.swift").path)
        return isRepo ? repo.appendingPathComponent("bugs.md") : dir.resolvingSymlinksInPath().appendingPathComponent("bugs.md")
    }

    /// `bug "summary" [--repro …] [--cause …] [--fix …]`: appends a field report to the repo's bugs.md,
    /// with the last error from the log. The LLM reads the source first and suggests the fix.
    static func fileBug(_ a: Args) throws -> String {
        let summary = a.pos.joined(separator: " ")
        guard !summary.isEmpty else { throw Fail(5, "bug \"summary\" [--repro \"…\"] [--cause \"file:line …\"] [--fix \"…\"]") }
        let file = bugFile
        var text = (try? String(contentsOf: file, encoding: .utf8)) ?? "# apprentice — bug audit\n"
        // The heading on a line of its own: prose that quotes it does not count (M8).
        if !text.components(separatedBy: "\n").contains("## Field reports") {
            text += "\n## Field reports\n\nFiled by `apprentice bug` while working. Each has a suggested fix to review; none is applied.\n"
        }
        // Fixed reports are deleted, so number past the highest one left rather than counting them.
        let count = (text.components(separatedBy: "\n### F").dropFirst()
            .compactMap { Int($0.prefix { $0.isNumber }) }.max() ?? 0) + 1
        var entry = "\n### F\(count) · \(summary) — \(Store.day())\n"
        if let r = a.value("repro") { entry += "- Repro: \(r)\n" }
        if let error = lastError() { entry += "- Last error: `\(error)`\n" }
        if let c = a.value("cause") { entry += "- Cause: \(c)\n" }
        if let f = a.value("fix") { entry += "- Suggested fix: \(f)\n" }
        try (text + entry).write(to: file, atomically: true, encoding: .utf8)
        let hash = Repo.commit("Field report F\(count): \(summary)", paths: [file.path])
        return "filed F\(count) in \(file.path)" + (hash.map { " (commit \($0))" } ?? "")
    }

    private static func lastError() -> String? {
        guard let session = Session.stored,
              let text = try? String(contentsOf: Store.runFolder(session).appendingPathComponent("steps.jsonl"), encoding: .utf8) else { return nil }
        for row in text.split(separator: "\n").reversed() {
            guard let data = row.data(using: .utf8), let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let error = r["error"] as? String else { continue }
            return "\(r["failed"] ?? "?") → exit \(r["code"] ?? "?"): \(error.split(separator: "\n").first ?? "")"
        }
        return nil
    }

    // MARK: - learn

    static let actions: Set<String> = ["open", "click", "type", "key", "menu", "scroll", "browse", "hover", "drag", "upload", "download", "choose"]

    /// Drafts a flow from the approved steps of the current session. The caller generalizes it.
    static func learn(_ a: Args) throws -> String {
        let task = a.pos.joined(separator: " ")
        guard !task.isEmpty else { throw Fail(5, "learn \"task\" [--name slug] [--force]") }
        guard let session = Session.stored else { throw Fail(5, "no session: learn drafts a flow from the current session's steps") }
        let steps = stepLines(session)
        // The session line is always there; a flow needs at least one action after it (D1).
        guard steps.count > 1 else { throw Fail(5, "no actions in this session's log yet: nothing to learn") }
        let slug = slugify(a.value("name") ?? "\(session.app) \(task)")
        guard !slug.isEmpty else { throw Fail(5, "the flow needs a name with letters or digits: pass --name") }
        let url = dir.appendingPathComponent("flows/\(slug).md")
        if FileManager.default.fileExists(atPath: url.path), !a.has("force") {
            throw Fail(5, "\(url.path) exists: edit it, or pass --force to replace it")
        }
        let model = a.value("model") ?? Store.model ?? loggedModel(session) ?? "any"
        let text = draft(task, session, steps, model: model)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let path = url.resolvingSymlinksInPath().path
        let hash = Repo.commit("Draft flow \(slug): \(task)", paths: [path])
        return "wrote \(path)" + (hash.map { " (commit \($0))" } ?? "")
            + "\nedit it now: generalize names, drop dead steps, add Fails; then `apprentice commit \"…\"`\n\n" + text
    }

    static func stepLines(_ session: Session) -> [String] {
        let file = Store.runFolder(session).appendingPathComponent("steps.jsonl")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var out = ["`session --app \"\(session.app)\"`"]
        for row in text.split(separator: "\n") {
            guard let data = row.data(using: .utf8),
                  let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cmd = r["cmd"] as? String, actions.contains(cmd), r["diff"] != nil else { continue }
            func el(_ prefix: String = "") -> String {
                let label = r[prefix + "label"] as? String ?? "element"
                if label.hasPrefix("focused") { return "focused" }
                let name = (r[prefix + "name"] as? String ?? "").replacingOccurrences(of: "\"", with: "\\\"")
                return "#\(label) \"\(name)\""
            }
            var line: String
            switch cmd {
            case "open": line = "open \(r["url"] as? String ?? "{url}")"
            case "click": line = "click \(el())"
            case "type": line = "type \(el()) \"{text}\""
            case "key": line = "key \(r["combo"] as? String ?? "")"
            case "menu": line = "menu \"\(r["menu"] as? String ?? "")\""
            case "scroll": line = "scroll \(r["direction"] as? String ?? "down") \(r["count"] ?? 3)"
            case "hover": line = "hover \(el())"
            case "browse": line = "browse \(r["seconds"] ?? 30)"
            case "drag" where r["by"] != nil: line = "drag --by=\(r["by"] ?? "")" + (r["label"] != nil ? " --in \(el())" : "")
            case "drag": line = "drag \(el()) \(el("to_"))"
            case "upload": line = "upload \(el()) \"{file}\""
            case "choose": line = "choose \"{path}\""
            default: line = "download \(el()) \"{path}\""
            }
            if let flags = r["flags"] as? String, !flags.isEmpty { line += " " + flags }
            line = "`\(line)`"
            if r["diff"] as? String == "+0 -0 ~0" { line += " — no visible change: drop it if it was not needed" }
            out.append(line)
        }
        return out
    }

    /// The model most of this session's rows name, when the caller did not say.
    static func loggedModel(_ session: Session) -> String? {
        let models = Sessions.rows(Store.runFolder(session)).compactMap { $0["model"] as? String }
        return Dictionary(grouping: models, by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }

    static func draft(_ task: String, _ session: Session, _ steps: [String], model: String = "any") -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let lang = Locale.preferredLanguages.first ?? "en"
        let match = hostOf(session.url) ?? session.app
        let tags = Set(task.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count > 2 }).sorted()
        return """
        ---
        scope: flow
        match: \(match)
        tags: \(tags.joined(separator: ", "))
        model: \(model)
        lang: \(lang)
        verified: \(Store.day()), macOS \(os.majorVersion).\(os.minorVersion)
        status: draft
        ---
        # \(task)

        Drafted by `apprentice learn` from approved steps. Run it with `apprentice do <this file's name> --key value`. Before committing: replace names from this screen with {placeholders}, delete steps that did nothing, and note what failed.

        ## Steps
        \(steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))

        ## Fails
        -

        """
    }

    static func slugify(_ s: String) -> String {
        let parts = s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return parts.prefix(8).joined(separator: "-")
    }
}
