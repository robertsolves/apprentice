import Foundation

/// Playbooks: what was learned about apps, sites and flows, as Markdown kept in the repo's `playbooks/`
/// (linked to ~/.apprentice/playbooks by kit.sh), so `git pull` brings in what was learned elsewhere.
/// Playbooks are shared, so they stay generic: `leaks` keeps personal details out of every commit of them.
enum Playbooks {
    struct Playbook {
        var url: URL
        var path: String
        var meta: [String: String]
        var title: String
        var body: String
        /// Built in, learned by apprentice, or the user's own: from the folder it was read from.
        var origin: Skills.Origin = .builtIn

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
        let env = ProcessInfo.processInfo.environment
        // APPRENTICE_NOTES is the old name, still honoured.
        if let custom = env["APPRENTICE_PLAYBOOKS"] ?? env["APPRENTICE_NOTES"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return Store.dir.appendingPathComponent("playbooks")
    }

    /// Parsed playbooks by path, kept while the file's modification date stays the same: `session` reads the
    /// playbooks three times, and parsing a few hundred files each time adds up.
    private static var cache: [String: (Date, Playbook)] = [:]
    private static let cacheLock = NSLock()

    /// Every skill file of every kind (`Skills.roots`), one per path: yours over learned over built in, unless
    /// `includeShadowed`.
    static func all(includeShadowed: Bool = false) -> [Playbook] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        var out: [Playbook] = []
        var seen = Set<String>()
        for (origin, folder) in Skills.roots {
            let root = folder.resolvingSymlinksInPath()
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let url as URL in walk where url.pathExtension == "md" && url.lastPathComponent != "README.md" {
                let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                var note: Playbook
                if let (when, cached) = cache[url.path], when == stamp {
                    note = cached
                } else {
                    guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    let path = String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
                    note = parse(text, url: url, path: path)
                    cache[url.path] = (stamp, note)
                }
                note.origin = origin
                // A learned file adds to a built-in one of the same path and hides nothing; a learned flow still
                // replaces the one it repaired, and yours and the project's still replace (they are the user's words).
                if origin == .learned, note.meta["scope"] != "flow" {
                    out.append(note)
                    continue
                }
                guard seen.insert(note.path).inserted || includeShadowed else { continue }
                out.append(note)
            }
        }
        return out.sorted { $0.path != $1.path ? $0.path < $1.path : $0.origin.rawValue < $1.origin.rawValue }
    }

    static func parse(_ text: String, url: URL, path: String) -> Playbook {
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
        return Playbook(url: url, path: path, meta: meta, title: title, body: lines.joined(separator: "\n"))
    }

    /// The files one place can be in, in a root: the host and each parent domain up to the registrable one, the root's
    /// general file, or the app under its system's folder. Opening these is a handful of stats and reads, whatever the
    /// library holds, so nothing an agent runs in a session has to walk it.
    static func placePaths(app: String?, bundle: String?, host: String?, system: String = "macos") -> [String] {
        var out: [String] = []
        func name(_ s: String) -> String {
            var out = ""
            for ch in s.lowercased() { out.append(ch.isLetter || ch.isNumber || ch == "." || ch == "-" ? ch : "-") }
            return out
        }
        if let h = host?.lowercased(), !h.isEmpty {
            var parts = Site.domain(h).split(separator: ".").map(String.init)
            while parts.count >= 2 {
                out.append("web/\(name(parts.joined(separator: "."))).md")
                parts.removeFirst()
            }
        }
        for key in [app, bundle].compactMap({ $0 }) where !key.isEmpty { out.append("\(system)/\(name(key)).md") }
        return out
    }

    /// The learned and library files of one place, read directly, never by walking those roots.
    static func placeFiles(app: String?, bundle: String?, host: String?, system: String) -> [Playbook] {
        var out: [Playbook] = []
        for rel in placePaths(app: app, bundle: bundle, host: host, system: system) {
            for (origin, root) in [(Skills.Origin.learned, Skills.learnedDir), (.library, SkillLibrary.folder)] {
                let url = root.appendingPathComponent(rel)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                var note = parse(text, url: url, path: rel)
                note.origin = origin
                out.append(note)
            }
        }
        return out
    }

    /// App and site playbooks for this window; flows are left to `playbooks <query>`. `*` matches every session.
    /// `system` is where the session runs, "macos" or "linux" (the VM): a playbook with `system:` in its front
    /// matter only shows there, so the VM does not get the Mac's general facts.
    static func matching(app: String?, bundle: String?, host: String?, system: String = "macos") -> [Playbook] {
        let keys = [app, bundle].compactMap { $0?.lowercased() }
        let h = host.map { Site.domain($0.lowercased()) }
        // Yours, the project's and built-in ones are few and may match by their front matter, so they are read as a
        // folder; learned and library ones are found by their place's path.
        let small = all().filter { $0.origin != .learned || $0.meta["scope"] == "flow" }
        let placed = placeFiles(app: app, bundle: bundle, host: host, system: system)
        let candidates: [Playbook] = small + placed
        return candidates.filter { note in
            guard note.meta["scope"] != "flow", note.meta["system"].map({ $0 == system }) ?? true else { return false }
            return note.match.contains { m in
                if m == "*" || keys.contains(m) { return true }
                guard let h else { return false }
                return h == m || h.hasSuffix("." + m)
            }
        }
    }

    /// `session`, `open` and `focus`: what is known about this place. Six lines at most per skill, whatever the library
    /// holds: learned lines go under the built-in skill of the same path and hide nothing, confirmed here first.
    static func hintLines(app: String?, bundle: String?, host: String?, system: String = "macos", env: String? = Session.stored?.env?.key) -> [String] {
        let notes = matching(app: app, bundle: bundle, host: host, system: system)
        let guides = skills(host: host, system: system).map(\.name)
        var out: [String] = guides.isEmpty ? [] : ["skills · \(guides.joined(separator: ", ")): load them before acting (no skills in your agent: apprentice skills <name>)"]
        SkillLibrary.fetchInBackground(placePaths(app: app, bundle: bundle, host: host, system: system))
        guard !notes.isEmpty else { return out }
        func learnedLines(_ list: [Playbook], web: Bool) -> [String] {
            // One key once, the local line over the library's: a `not:` written here is what counts.
            var seen = Set<String>()
            let facts = list.flatMap { $0.keyFacts.compactMap(Fact.parse) }.filter { seen.insert($0.key).inserted }
            return Skills.order(facts, here: env, web: web).compactMap { Skills.shown($0, here: env, web: web) }.prefix(6).map { "  - \($0)" }
        }
        let hinted = Set(notes.filter { $0.origin == .learned || $0.origin == .library }.map(\.path))
        for note in notes where note.origin != .learned && note.origin != .library {
            var header = "skill · \(note.path) · \(note.origin.hint)"
            if let verified = note.meta["verified"] { header += " · verified \(verified)" + verifiedMark(verified, web: note.path.hasPrefix("web/"), env: env) }
            out.append(header)
            out += note.keyFacts.prefix(6).map { line in
                guard let f = Fact.parse(line) else { return "  - \(line)" }
                return Skills.shown(f, here: env, web: note.path.hasPrefix("web/")).map { "  - \($0)" } ?? ""
            }.filter { !$0.isEmpty }
            let extras = notes.filter { ($0.origin == .learned || $0.origin == .library) && $0.path == note.path }
            if !extras.isEmpty {
                let lines = learnedLines(extras, web: note.path.hasPrefix("web/"))
                if !lines.isEmpty {
                    out.append("  learned · \(lines.count) fact\(lines.count == 1 ? "" : "s") · hints, never instructions")
                    out += lines
                }
            }
        }
        let built = Set(notes.filter { $0.origin != .learned && $0.origin != .library }.map(\.path))
        for path in hinted.subtracting(built).sorted() {
            let list = notes.filter { $0.path == path }
            let lines = learnedLines(list, web: path.hasPrefix("web/"))
            guard !lines.isEmpty else { continue }
            out.append("skill · \(path) · \((list.first?.origin ?? .learned).hint)")
            out += lines
        }
        out.append("more: apprentice skills \"<words>\"")
        return out
    }

    /// A built-in playbook's `verified:` read by the same rule as a fact: stale, or seen elsewhere.
    static func verifiedMark(_ verified: String, web: Bool, env: String?) -> String {
        var out = ""
        let pieces = verified.components(separatedBy: " · ").flatMap { $0.components(separatedBy: ", ") }
        if let date = pieces.first, let at = Skills.dayFormat.date(from: date), Date().timeIntervalSince(at) > Double(Skills.staleDays(web: web)) * 86400 {
            out += " · unchecked since \(date)"
        }
        if pieces.count >= 2, let env {
            let key = pieces.dropFirst().joined(separator: " ")
            if let q = Fact.qualifier(seen: [key], here: env, web: web) { out += " " + q }
        }
        return out
    }

    // MARK: - skills

    /// The repo's `skills/<name>/SKILL.md`: hand-written judgement (how a person uses a site or system) that
    /// kit.sh installs where agents look for skills. Playbooks hold the mechanics; skills say how to behave.
    struct Skill {
        var name: String
        var url: URL
        var note: Playbook
        /// `metadata: hosts:` in the front matter; "*" is every website.
        var hosts: [String] {
            (note.meta["hosts"] ?? "").replacingOccurrences(of: "\"", with: "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        }
    }

    static var skillsDir: URL { repo.appendingPathComponent("skills") }

    static func skills() -> [Skill] {
        // Yours over learned over the clone's own, so a copy shadows the skill it came from.
        let dirs = [Skills.yoursDir, Skills.learnedDir, skillsDir]
        let names = Set(dirs.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] })
        return names.sorted().compactMap { name in
            guard let url = dirs.map({ $0.appendingPathComponent(name).appendingPathComponent("SKILL.md") })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return Skill(name: name, url: url, note: parse(text, url: url, path: "skills/\(name)/SKILL.md"))
        }
    }

    /// Skills for this window, general first: on a page, the web skill and the site's; elsewhere, the system's.
    static func skills(host: String?, system: String) -> [Skill] {
        let all = skills()
        guard let h = host?.lowercased(), !h.isEmpty else { return all.filter { $0.hosts.isEmpty && $0.note.meta["system"] == system } }
        return all.filter { $0.hosts.contains("*") } + all.filter { s in s.hosts.contains { h == $0 || h.hasSuffix("." + $0) } }
    }

    /// Ranks playbooks by how many query words they contain and shows the matching lines. A query that
    /// names a skill prints the skill, so agents without skill support (MCP apps, the `run` loop) can read it.
    static func search(_ query: String) -> String {
        let named = query.trimmingCharacters(in: .whitespaces).lowercased()
        if let skill = skills().first(where: { $0.name == named }) {
            return "\(skill.note.path)\n\(skill.note.body.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 }
        if !words.isEmpty, let answer = indexed(query, words: words) { return answer }
        let notes = all()
        if words.isEmpty {
            return (["skills: built in, learned by apprentice (hints, unreviewed) and yours · apprentice skills --paths"]
                + notes.map { "\($0.path) · \($0.title) · \($0.origin.label)" }).joined(separator: "\n")
        }
        let ranked = notes.map { note -> (Playbook, Int) in
            let text = (note.path + " " + note.title + " " + (note.meta["tags"] ?? "") + " " + note.body).lowercased()
            return (note, words.filter { text.contains($0) }.count)
        }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        guard !ranked.isEmpty else { return "no skill matches \"\(query)\": work it out on screen, then `apprentice learn`" }
        var out: [String] = []
        for (note, _) in ranked.prefix(5) {
            out.append("\(note.path) · \(note.title) · \(note.origin.hint)")
            let hits = note.body.components(separatedBy: .newlines).filter { line in
                !line.hasPrefix("#") && words.contains { line.lowercased().contains($0) }
            }
            out += hits.prefix(6).map { "  \($0.trimmingCharacters(in: .whitespaces))" }
        }
        out.append("whole skill: cat " + ranked.prefix(1).map { $0.0.url.path }.joined())
        return out.joined(separator: "\n")
    }

    /// The word search through the index, with the project's own few skills read directly and put first. Nil when the
    /// index cannot open, so the walk below still answers.
    private static func indexed(_ query: String, words: [String]) -> String? {
        guard let index = SkillIndex() else { return nil }
        index.update(roots: SkillIndex.roots)
        var grouped: [(path: String, origin: Skills.Origin, title: String, lines: [String], score: Int)] = []
        func add(_ path: String, _ origin: Skills.Origin, _ title: String, _ line: String, _ count: Int) {
            if let i = grouped.firstIndex(where: { $0.path == path && $0.origin == origin }) {
                grouped[i].lines.append(line)
                grouped[i].score += 1 + count
            } else { grouped.append((path, origin, title, [line], 1 + count)) }
        }
        if let dir = Skills.projectDir?.resolvingSymlinksInPath(), let walk = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let url as URL in walk where url.pathExtension == "md" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let rel = String(url.resolvingSymlinksInPath().path.dropFirst(dir.path.count + 1))
                let note = parse(text, url: url, path: rel)
                let hits = note.body.components(separatedBy: .newlines).filter { line in !line.hasPrefix("#") && words.contains { line.lowercased().contains($0) } }
                let inTitle = words.contains { (note.title + " " + (note.meta["tags"] ?? "")).lowercased().contains($0) }
                if hits.isEmpty, !inTitle { continue }
                for line in hits.isEmpty ? [note.title] : hits { add(rel, .project, note.title, line.trimmingCharacters(in: .whitespaces), 5) }
            }
        }
        for hit in index.search(words) {
            let lines = hit.text.components(separatedBy: .newlines).filter { line in !line.hasPrefix("#") && words.contains { line.lowercased().contains($0) } }
            if lines.isEmpty { add(hit.path, hit.origin, hit.title, hit.title, hit.count) }
            for line in lines { add(hit.path, hit.origin, hit.title, line.trimmingCharacters(in: .whitespaces), hit.count) }
        }
        guard !grouped.isEmpty else { return "no skill matches \"\(query)\": work it out on screen, then `apprentice learn`" }
        var out: [String] = []
        let top = grouped.sorted { $0.score > $1.score }.prefix(5)
        for g in top {
            out.append("\(g.path) · \(g.title) · \(g.origin.hint)")
            out += g.lines.prefix(6).map { "  \($0)" }
        }
        if let first = top.first { out.append("whole skill: cat " + Skills.dir(first.origin).appendingPathComponent(first.path).path) }
        return out.joined(separator: "\n")
    }

    /// Playbook text for the `run` loop: the window's playbooks plus the best flow for this task and model, kept
    /// under a budget so a long playbook cannot crowd out the screen.
    static func context(task: String, session: Session?, model: String? = Store.model, budget: Int = 6000) -> String {
        let system = session?.vm == true ? "linux" : "macos"
        var parts = hintLines(app: session?.app, bundle: session?.bundle, host: hostOf(session?.url), system: system)
        // The loop's model has no skills of its own: the site's skill comes in whole, the general ones are named.
        for skill in skills(host: hostOf(session?.url), system: system) where !skill.hosts.contains("*") && !skill.hosts.isEmpty {
            parts.append("skill · \(skill.name)\n\(skill.note.body.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if let best = rank(task: task, model: model, session: session).first {
            parts.append("flow · \(best.note.path) (\(best.why))\n\(best.note.body.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let text = parts.joined(separator: "\n")
        return text.count > budget ? String(text.prefix(budget)) + "\n… (cut; more: apprentice skills \"<words>\")" : text
    }

    struct Ranked {
        var note: Playbook
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
            if let here = session?.env?.key, let verified = note.meta["verified"] {
                let seen = verified.components(separatedBy: " · ").dropFirst().joined(separator: " ")
                let web = host != nil
                if !seen.isEmpty, let q = Fact.qualifier(seen: [seen], here: here, web: web) { why.append("seen elsewhere \(q)") } else if !seen.isEmpty { score += 1 }
            }
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

    static func flow(named name: String) -> Playbook? {
        let flows = all().filter { $0.meta["scope"] == "flow" }
        return flows.first { $0.url.deletingPathExtension().lastPathComponent == name || $0.path == name }
    }

    /// Numbered lines under "## Steps", without their numbers.
    static func steps(_ note: Playbook) -> [String] {
        var out: [String] = []
        var inside = false
        for raw in note.body.components(separatedBy: .newlines) {
            if raw.hasPrefix("## ") { inside = raw.lowercased().hasPrefix("## steps"); continue }
            // Markdown lists are often indented (`  1. click 5`): the number is read past the indent (F5).
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard inside, let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty else { continue }
            out.append(line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces))
        }
        return out
    }

    // MARK: - bug

    /// The repo that holds the playbooks (kit.sh links ~/.apprentice/playbooks into it).
    static var repo: URL { dir.resolvingSymlinksInPath().deletingLastPathComponent() }

    /// Field reports go to the repo's BUGS.md when the playbooks are the repo's own; playbooks pointed
    /// anywhere else keep their reports beside them (L1).
    static var bugFile: URL {
        let isRepo = FileManager.default.fileExists(atPath: repo.appendingPathComponent("Package.swift").path)
        return isRepo ? repo.appendingPathComponent("BUGS.md") : dir.resolvingSymlinksInPath().appendingPathComponent("BUGS.md")
    }

    /// `bug "summary" [--repro …] [--cause …] [--fix …]`: appends a field report to the repo's BUGS.md,
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
        let hash = try? Repo.commit("Field report F\(count): \(summary)", paths: [file.path])
        return "filed F\(count) in \(file.path)" + ((hash ?? nil).map { " (commit \($0))" } ?? "")
    }

    private static func lastError() -> String? {
        guard let session = Session.stored else { return nil }
        for r in Sessions.rows(Store.runFolder(session)).reversed() {
            guard let error = r["error"] as? String else { continue }
            return "\(r["failed"] ?? "?") → exit \(r["code"] ?? "?"): \(error.split(separator: "\n").first ?? "")"
        }
        return nil
    }

    // MARK: - privacy

    /// What in playbook text looks personal: an email, phone or account number, a handle, an id or query in
    /// a URL, a home path, an address, a token, or the user's own name. Playbooks reach everyone through
    /// `pr` and updates, so `commit`, `learn` and `pr` refuse text with any of these; `{placeholders}` pass.
    static func leaks(_ text: String, identity: [String] = identity) -> [String] {
        var out: [String] = []
        func hits(_ pattern: String, _ what: String, options: NSRegularExpression.Options = [], skip: (String) -> Bool = { _ in false }) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range, in: text) else { continue }
                let found = String(text[r])
                if !skip(found) { out.append("\(what): \(found)") }
            }
        }
        let sample = ["example.com", "example.org", "example.net"]
        hits(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#, "an email address",
             skip: { e in sample.contains { e.lowercased().hasSuffix("@" + $0) } })
        hits(#"(?<![\w.@/{])@[A-Za-z0-9_][A-Za-z0-9_.]+"#, "a handle")
        // Eight or more digits, however they are grouped, is a phone, card or account number; a date is not.
        hits(#"(?<![\w.])\+?\d(?:[ ().-]{0,2}\d){7,}(?![\w.])"#, "a phone, card or account number",
             skip: { $0.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil })
        hits(#"(?<![\w.-])\d{6,}(?![\w.-])"#, "a long number (an id?)")
        hits(#"https?://[^\s`"'<>)\]]+"#, "a URL with an id or a query", skip: { !urlIsPersonal($0) })
        hits(#"(?:/Users|/home)/(?!\{|Shared\b)[^/\s`"']+"#, "a home folder")
        hits(#"(?<![\w.])(?!127\.)(?!0\.0\.0\.0)(?:\d{1,3}\.){3}\d{1,3}(?![\w.])"#, "an IP address")
        hits(#"\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[abpr]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{20,})"#, "a token")
        hits(#"(?<![\w-])(?=[A-Za-z0-9_-]*\d)(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{32,}(?![\w-])"#, "a token or long id")
        for word in identity where word.count >= 3 {
            let escaped = NSRegularExpression.escapedPattern(for: word)
            hits(#"(?<![\w])"# + escaped + #"(?![\w])"#, "your own name or account", options: .caseInsensitive)
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// A URL is personal when its query carries values or a path segment looks like an id or a handle
    /// (`/@name`, five or more digits, a long mixed token). Hosts and plain paths like `/new` pass.
    static func urlIsPersonal(_ url: String) -> Bool {
        guard let c = URLComponents(string: url) else { return true }
        if let items = c.queryItems, items.contains(where: { ($0.value ?? "").isEmpty == false && !($0.value ?? "").hasPrefix("{") }) { return true }
        return c.path.split(separator: "/").contains { seg in
            guard !seg.hasPrefix("{") else { return false }
            let digits = seg.filter(\.isNumber).count
            return seg.hasPrefix("@") || seg.hasPrefix("~") || digits >= 5 || (seg.count >= 16 && digits > 0 && seg.contains(where: \.isLetter))
        }
    }

    /// The user's own name, login and git identity, and this Mac's name: none of them may be in a playbook.
    static var identity: [String] {
        var words = NSFullUserName().split(whereSeparator: { !$0.isLetter }).map(String.init)
        words.append(NSUserName())
        for key in ["user.name", "user.email"] {
            let value = Repo.git("config", key).out
            words += key == "user.email" ? [value] : value.split(whereSeparator: { !$0.isLetter }).map(String.init)
        }
        if let host = Host.current().localizedName { words.append(host) }
        // A login like "admin" or a name like "User" says nothing about anyone.
        let generic: Set<String> = ["admin", "user", "root", "mac", "macbook", "imac", "pro", "air", "the", "and"]
        return Array(Set(words.filter { $0.count >= 3 && !generic.contains($0.lowercased()) }))
    }

    /// `leaks` for the playbook lines a change adds (`git diff` or `git log -p` output, "+" lines only), so a
    /// commit is judged on what it brings in. Names each file with what it found.
    static func leaks(inPatch patch: String) -> [String] {
        var file = "", added: [String: [String]] = [:], order: [String] = []
        for line in patch.components(separatedBy: "\n") {
            if line.hasPrefix("+++ ") { file = String(line.dropFirst(4)).replacingOccurrences(of: "b/", with: "", options: .anchored); continue }
            guard line.hasPrefix("+"), !file.isEmpty, file != "/dev/null" else { continue }
            if added[file] == nil { order.append(file) }
            added[file, default: []].append(String(line.dropFirst()))
        }
        return order.flatMap { f in leaks(added[f]!.joined(separator: "\n")).map { "\(f): \($0)" } }
    }

    /// `playbooks --check`: every playbook, whole, through `leaks`, so a personal detail is found before a
    /// commit or a PR refuses it.
    static func checkAll() throws -> String {
        let checked = all() + skills().map(\.note)
        let found = checked.flatMap { p in leaks(p.body + "\n" + p.title + "\n" + p.meta.values.joined(separator: "\n")).map { "\(p.path): \($0)" } }
        guard !found.isEmpty else { return "\(checked.count) playbooks and skills checked: nothing personal found" }
        throw Fail(5, "these look personal, and playbooks are shared:\n" + found.map { "  - \($0)" }.joined(separator: "\n"))
    }

    // MARK: - learn

    static let actions: Set<String> = ["open", "click", "type", "key", "menu", "scroll", "browse", "hover", "drag", "upload", "download", "choose"]

    /// Drafts a flow from the approved steps of the current session, as a learned skill on this Mac; the
    /// caller generalizes it. `--fact "…"` saves one line about the session's site or app instead (`--for`
    /// names another), dated and kept to `[skills] max_facts`.
    static func learn(_ a: Args) throws -> String {
        let session = Session.stored
        let target = a.value("for") ?? session.flatMap { hostOf($0.url) ?? $0.app }
        let env = a.value("for") == nil ? session?.env?.key : nil
        if a.value("still") != nil || a.value("wrong") != nil || a.value("fact") != nil {
            guard let target, !target.isEmpty else { throw Fail(5, "learn --fact \"…\" --for <site or app>: no session to take it from") }
            if let words = a.value("still") { return try Skills.stillTrue(words, for: target, env: env) }
            if let words = a.value("wrong") { return try Skills.wrong(words, for: target, env: env) }
            // The screen's labels and the place's facts explain a word; only what neither explains looks like the job.
            let rows = session.map { Sessions.rows(Store.runFolder($0)) } ?? []
            let task = rows.compactMap { $0["task"] as? String }.last
            let labels = SnapStore.current?.elements.map { "\($0.label) \($0.name)" }.joined(separator: " ") ?? ""
            return try Skills.addFact(a.value("fact") ?? "", for: target, kind: a.value("kind"), env: env, task: task, known: labels)
        }
        let task = a.pos.joined(separator: " ")
        guard !task.isEmpty else { throw Fail(5, "learn \"task\" [--name slug] [--force] · learn --fact \"one line\" [--for site-or-app]") }
        guard let session = Session.stored else { throw Fail(5, "no session: learn drafts a flow from the current session's steps") }
        let steps = stepLines(session)
        // The session line is always there; a flow needs at least one action after it (D1).
        guard steps.count > 1 else { throw Fail(5, "no actions in this session's log yet: nothing to learn") }
        let slug = slugify(a.value("name") ?? "\(session.app) \(task)")
        guard !slug.isEmpty else { throw Fail(5, "the flow needs a name with letters or digits: pass --name") }
        let url = Skills.learnedDir.appendingPathComponent("flows/\(slug).md")
        guard steps.count <= Skills.maxSteps + 1 else {
            throw Fail(5, "this session has \(steps.count - 1) steps, over the \(Skills.maxSteps) a learned flow keeps ([skills] max_steps): learn a shorter task")
        }
        if FileManager.default.fileExists(atPath: url.path), !a.has("force") {
            throw Fail(5, "\(url.path) exists: edit it, or pass --force to replace it")
        }
        let model = a.value("model") ?? Store.model ?? loggedModel(session) ?? "any"
        let text = draft(task, session, steps, model: model)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        Skills.prune()
        let path = url.path
        let found = leaks(text + "\n" + slug)
        // A learned skill stays on this Mac; `skills share` checks it again before it could reach anyone.
        return "learned skill \(path)" + (found.isEmpty ? "" : "\nit looks personal, replace each with a {placeholder}:\n" + found.map { "  - \($0)" }.joined(separator: "\n"))
            + "\nedit it now: generalize names, drop dead steps, add Fails\n\n" + text
    }

    /// Screen text kept to one plain line inside one backticked step: a name with a newline or a
    /// backtick in it would otherwise add a step of its own (a `sh:` one, say) to a playbook, which is trusted.
    static func oneLine(_ s: String, max: Int = 80) -> String {
        let flat = s.map { $0.isNewline || $0 == "`" || $0 == "\t" ? " " : $0 }
        let text = String(flat).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(text.prefix(max))
    }

    /// The site a step opened, without the page: a path or query can name a person, an account or an
    /// order, so `learn` keeps the host and leaves `{path}` for the LLM to generalize.
    static func genericURL(_ url: String) -> String {
        guard var c = URLComponents(string: url), c.host != nil else { return url }
        let hadMore = !(c.path.isEmpty || c.path == "/") || c.query != nil || c.fragment != nil
        c.query = nil; c.fragment = nil; c.path = ""
        return (c.string ?? url) + (hadMore ? "/{path}" : "/")
    }

    static func stepLines(_ session: Session, rows given: [[String: Any]]? = nil) -> [String] {
        let rows = given ?? Sessions.rows(Store.runFolder(session))
        guard !rows.isEmpty else { return [] }
        var out = ["`session --app \"\(oneLine(session.app))\"`"]
        for r in rows {
            guard let cmd = r["cmd"] as? String, actions.contains(cmd), r["diff"] != nil else { continue }
            func el(_ prefix: String = "") -> String {
                let label = oneLine(r[prefix + "label"] as? String ?? "element")
                if label.hasPrefix("focused") { return "focused" }
                let name = oneLine(r[prefix + "name"] as? String ?? "")
                    .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                return "#\(label) \"\(name)\""
            }
            var line: String
            switch cmd {
            case "open": line = "open \(genericURL(oneLine(r["url"] as? String ?? "{url}", max: 300)))"
            case "click": line = "click \(el())"
            case "type": line = "type \(el()) \"{text}\""
            case "key": line = "key \(oneLine(r["combo"] as? String ?? ""))"
            case "menu": line = "menu \"\(oneLine(r["menu"] as? String ?? ""))\""
            case "scroll": line = "scroll \(r["direction"] as? String ?? "down") \(r["count"] ?? 3)"
            case "hover": line = "hover \(el())"
            case "browse": line = "browse \(r["seconds"] ?? 30)"
            case "drag" where r["by"] != nil: line = "drag --by=\(r["by"] ?? "")" + (r["label"] != nil ? " --in \(el())" : "")
            case "drag": line = "drag \(el()) \(el("to_"))"
            case "upload": line = "upload \(el()) \"{file}\""
            case "choose": line = "choose \"{path}\""
            default: line = "download \(el()) \"{path}\""
            }
            if let flags = r["flags"] as? String, !flags.isEmpty { line += " " + oneLine(flags) }
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

    private static let stopwords: Set<String> = ["and", "for", "with", "the", "from", "into", "that", "this", "near", "then", "you", "your", "are", "was", "man", "woman", "her", "his", "their", "our", "not"]

    static func draft(_ task: String, _ session: Session, _ steps: [String], model: String = "any",
                      note: String = "Drafted by `apprentice learn` from approved steps. Run it with `apprentice do <this file's name> --key value`. Before using it widely: replace names from this screen with {placeholders}, delete steps that did nothing, and note what failed.") -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let lang = Locale.preferredLanguages.first ?? "en"
        let match = Skills.normalised(hostOf(session.url) ?? session.app)
        let tags = Set(task.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count > 2 && !stopwords.contains($0) }).sorted()
        return """
        ---
        scope: flow
        match: \(match)
        tags: \(tags.joined(separator: ", "))
        model: \(model)
        lang: \(lang)
        verified: \(Store.day()) · \(session.env?.key ?? "macOS \(os.majorVersion).\(os.minorVersion)")
        status: draft
        ---
        # \(task)

        \(note)

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
