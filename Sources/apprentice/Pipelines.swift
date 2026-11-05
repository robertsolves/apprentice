import Foundation

/// A pipeline is a project's work as a graph of steps. Each step is a prompt for a named agent (`NamedAgents`) or a
/// shell command, it can branch (`next: a | b`, the interpreter chooses), fan out (`next: a & b`, each in its own
/// worktree, talking on the board) and join again. A file with no settings is still a straight line, one step
/// after another, and a simple task is a pipeline of one step (`pipeline task`).
///
/// A pipeline is one Markdown file, so a person can read and edit it anywhere:
///
///     ---
///     name: Fix the bug
///     goal: Fix the reported bug and publish the notes
///     interpreter: fast        # who chooses branches; else the project's default
///     scribe: Joseph, Reviewer # who writes summaries and notes; a list gives backups
///     carry: summary           # optional: keep a rolling summary between runs
///     visits: 3                # how many times a loop may come back to a step
///     vm: shop                 # optional; else the project's VM, else this Mac
///     ---
///     ## triage
///     use: fast
///     next: fix | reply
///     Read the report and work out what it needs.
///
///     ## fix
///     when: the report describes a real bug
///     needs: edit
///     next: code & tests
///     Plan the fix.
///
/// It lives in its project's `pipelines/` folder. One left in `~/.apprentice/pipelines/` by an older version still
/// runs. `PipelineGraph` reads the structure and checks it; `PipelineEngine` runs it.
enum Pipelines {
    struct Step: Equatable {
        var title: String
        var prompt: String
        /// The named agent; nil means the first in the priority list.
        var use: String? = nil
        /// `a`, `a | b`, `a & b` or `end`; nil means the next heading.
        var next: String? = nil
        /// One line the interpreter reads when choosing this step.
        var when: String? = nil
        /// On a step with an OR after it: what decides which branch runs. The interpreter reads it with the `when:` lines.
        var choose: String? = nil
        /// `read-only`, `edit` or `full`: the run does not start if the agent has less.
        var needs: String? = nil
        /// This step may use the screen.
        var ui = false

        /// The step's name, as `next:` and the board address it.
        var id: String { Pipelines.slug(title) }
        var hasSettings: Bool { use != nil || next != nil || when != nil || choose != nil || needs != nil || ui }

        /// `sh: <command>` as the step's whole text.
        var shell: String? {
            let t = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasPrefix("sh:"), !t.contains("\n") else { return nil }
            return String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
    }

    struct Pipeline {
        var name: String
        /// `agent:` from an older file: the CLI its steps run on unless a step says otherwise. Empty for a newer one.
        var agent = ""
        var vm: String?
        var about = ""
        var steps: [Step] = []
        var goal: String? = nil
        var interpreter: String? = nil
        var scribes: [String] = []
        /// `carry: summary` keeps a rolling summary between runs.
        var carry = false
        /// How many times a step may run in one run; 0 writes "no limit", which `pipeline check` refuses in a loop.
        var visits = 3
        /// The file, and the project folder it belongs to (nil: apprentice's own folder).
        var url: URL?
        var project: URL?

        var slug: String { url?.deletingPathExtension().lastPathComponent ?? Pipelines.slug(name) }
        /// `project/slug` for a project's pipeline, else the slug.
        var ref: String {
            guard let project else { return slug }
            return Projects.folderName(Projects.info(project)?.name ?? project.lastPathComponent) + "/" + slug
        }
        /// Where the steps run: the project folder, else the home folder.
        var folder: URL { project ?? FileManager.default.homeDirectoryForCurrentUser }
        /// The VM the steps use: the pipeline's own, else its project's.
        var effectiveVM: String? { vm ?? project.flatMap { Projects.info($0)?.vm } }
    }

    static var homeDir: URL { Store.dir.appendingPathComponent("pipelines") }

    static func slug(_ name: String) -> String {
        let s = Playbooks.slugify(name)
        return s.isEmpty ? "pipeline" : s
    }

    // MARK: - reading and writing

    static func parse(_ text: String, url: URL? = nil, project: URL? = nil) -> Pipeline {
        var lines = text.components(separatedBy: "\n")
        var meta: [String: String] = [:]
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for line in lines[1..<end] {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                meta[key] = metaValue(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
            lines = Array(lines[(end + 1)...])
        }
        var p = Pipeline(name: meta["name"] ?? "")
        if let agent = meta["agent"], !agent.isEmpty { p.agent = agent.lowercased() }
        if let vm = meta["vm"], !vm.isEmpty { p.vm = vm }
        p.goal = meta["goal"].flatMap { $0.isEmpty ? nil : $0 }
        p.interpreter = meta["interpreter"].flatMap { $0.isEmpty ? nil : $0 }
        p.scribes = (meta["scribe"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        p.carry = meta["carry"]?.lowercased() == "summary"
        if let v = meta["visits"].flatMap(Int.init) { p.visits = v }
        var about: [String] = []
        var current: Step?
        var body: [String] = []
        func close() {
            if var step = current {
                settings(&step, &body)
                step.prompt = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !step.prompt.isEmpty { p.steps.append(step) }
            }
            body = []
        }
        for line in lines {
            if line.hasPrefix("## ") {
                close()
                var title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                // "## 2. Answer by email": the number is the order, not the title.
                if let dot = title.firstIndex(of: "."), title[..<dot].allSatisfy(\.isNumber), !title[..<dot].isEmpty {
                    title = title[title.index(after: dot)...].trimmingCharacters(in: .whitespaces)
                }
                current = Step(title: title, prompt: "")
            } else if line.hasPrefix("# "), current == nil {
                if p.name.isEmpty { p.name = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            } else if current != nil {
                body.append(line)
            } else {
                about.append(line)
            }
        }
        close()
        p.about = about.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if p.name.isEmpty { p.name = url?.deletingPathExtension().lastPathComponent ?? "pipeline" }
        p.url = url
        p.project = project
        return p
    }

    /// Lines at the top of a step that look like `key: value` for a known key are its settings; the first other line
    /// starts the prompt. `sh:` stays in the prompt: it is the step's text.
    private static func settings(_ step: inout Step, _ body: inout [String]) {
        var used = 0
        for line in body {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { used += 1; continue }
            guard let colon = t.firstIndex(of: ":") else { break }
            let value = metaValue(t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            switch t[..<colon].lowercased() {
            case "use": step.use = value
            case "next": step.next = value
            case "when": step.when = value
            case "choose": step.choose = value
            case "needs": step.needs = value.lowercased()
            case "ui": step.ui = value.lowercased() == "true" || value.lowercased() == "yes"
            default:
                body = Array(body.dropFirst(used))
                return
            }
            used += 1
        }
        body = Array(body.dropFirst(used))
    }

    /// A front-matter value: a quoted one is read to its closing quote (so `"Budget #2"` keeps its `#`),
    /// and only an unquoted one loses a trailing ` # comment` (F6).
    static func metaValue(_ raw: String) -> String {
        if raw.hasPrefix("\"") {
            var escaped = false
            for i in raw.indices.dropFirst() {
                let ch = raw[i]
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" {
                    return Toml.unquote(String(raw[...i]))
                }
            }
        }
        guard let hash = raw.range(of: " #") else { return raw }
        return String(raw[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    /// Quotes a front-matter value when reading it back plain would change it.
    static func metaQuoted(_ v: String) -> String {
        let plain = !v.contains("#") && !v.hasPrefix("\"") && v == v.trimmingCharacters(in: .whitespaces)
        if plain { return v }
        let escaped = v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    static func render(_ p: Pipeline) -> String {
        var out = ["---", "name: \(metaQuoted(p.name))"]
        if !p.agent.isEmpty { out.append("agent: \(metaQuoted(p.agent))") }
        if let vm = p.vm, !vm.isEmpty { out.append("vm: \(metaQuoted(vm))") }
        if let goal = p.goal, !goal.isEmpty { out.append("goal: \(metaQuoted(goal))") }
        if let v = p.interpreter, !v.isEmpty { out.append("interpreter: \(metaQuoted(v))") }
        if !p.scribes.isEmpty { out.append("scribe: \(metaQuoted(p.scribes.joined(separator: ", ")))") }
        if p.carry { out.append("carry: summary") }
        if p.visits != 3 { out.append("visits: \(p.visits)") }
        out += ["---", "# \(p.name)", ""]
        if !p.about.isEmpty { out += [p.about, ""] }
        // A graph's steps are found by name, so its headings carry no numbers; a straight line keeps them, for reading.
        let numbered = !p.steps.contains(where: \.hasSettings)
        for (i, step) in p.steps.enumerated() {
            let title = step.title.trimmingCharacters(in: .whitespaces)
            let named = title.isEmpty ? "Step \(i + 1)" : title
            out.append(numbered ? "## \(i + 1). \(named)" : "## \(named)")
            if let v = step.use, !v.isEmpty { out.append("use: \(metaQuoted(v))") }
            if let v = step.next, !v.isEmpty { out.append("next: \(metaQuoted(v))") }
            if let v = step.when, !v.isEmpty { out.append("when: \(metaQuoted(v))") }
            if let v = step.choose, !v.isEmpty { out.append("choose: \(metaQuoted(v))") }
            if let v = step.needs, !v.isEmpty { out.append("needs: \(metaQuoted(v))") }
            if step.ui { out.append("ui: true") }
            out.append(step.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    /// The pipelines in one folder's `pipelines/` (or in `homeDir` when `project` is nil).
    static func inFolder(_ project: URL?) -> [Pipeline] {
        let dir = project.map { $0.appendingPathComponent("pipelines") } ?? homeDir
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" && $0.lastPathComponent != "README.md" && !$0.lastPathComponent.hasSuffix(".memory.md") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).map { parse($0, url: url, project: project) } }
    }

    /// Every pipeline: apprentice's own, then each project's.
    static func all() -> [Pipeline] {
        var out = inFolder(nil)
        var seen = Set<String>()
        var projects = Projects.all().map(\.folder)
        if let here = Projects.here()?.folder { projects.insert(here, at: 0) }
        for folder in projects where seen.insert(folder.standardizedFileURL.path).inserted {
            out += inFolder(folder)
        }
        return out
    }

    /// By `project/slug`, by slug or by name; the caller's own project wins a tie.
    static func find(_ ref: String) throws -> Pipeline {
        let all = all()
        let key = ref.lowercased()
        // The window names a pipeline by its file, which stays exact when two projects use one name.
        let path = URL(fileURLWithPath: (ref as NSString).expandingTildeInPath).standardizedFileURL.path
        if let task = task(at: path) { return task }
        let hits = all.filter { $0.url?.standardizedFileURL.path == path || $0.ref.lowercased() == key || slug($0.slug) == slug(ref) || $0.name.lowercased() == key }
        if hits.count == 1 { return hits[0] }
        if hits.isEmpty { throw Fail(5, "no pipeline \(ref) · apprentice pipeline list") }
        if let here = Projects.here()?.folder, let mine = hits.first(where: { $0.project?.standardizedFileURL == here.standardizedFileURL }) { return mine }
        throw Fail(5, "\(ref) names several pipelines: \(hits.map(\.ref).joined(separator: ", ")); use project/name")
    }

    static func write(_ p: Pipeline) throws -> URL {
        let url = p.url ?? (p.project.map { $0.appendingPathComponent("pipelines") } ?? homeDir).appendingPathComponent(slug(p.name) + ".md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try render(p).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// What to call a simple task: its first words.
    static func taskName(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let words = line.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        return words.count <= 48 ? words : String(words.prefix(47)) + "…"
    }

    /// A run's own first and last steps, typed for this run only: they go in the run's copy and never the file. The
    /// first runs before everything. The last runs after everything: every `end` now arrives there, and parallel
    /// branches that ended apart wait for each other at it. A straight list stays straight, so it keeps the screen.
    static func forRun(_ p: Pipeline, first: String?, last: String?) -> Pipeline {
        var out = p
        func title(_ wanted: String) -> String {
            var name = wanted, n = 2
            while out.steps.contains(where: { $0.id == slug(name) }) { name = "\(wanted) \(n)"; n += 1 }
            return name
        }
        func typed(_ text: String?) -> String? { text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } }
        if let last = typed(last) {
            let name = title("Last for this run")
            for i in out.steps.indices where out.steps[i].next?.trimmingCharacters(in: .whitespaces).lowercased() == "end" { out.steps[i].next = name }
            out.steps.append(Step(title: name, prompt: last))
        }
        if let first = typed(first) { out.steps.insert(Step(title: title("First for this run"), prompt: first), at: 0) }
        return out
    }

    /// Where a pipeline's cards sit on the canvas: beside its file, and only about how it looks. The file alone says how it runs.
    static func layoutFile(_ url: URL) -> URL { url.deletingPathExtension().appendingPathExtension("layout.json") }

    static func layout(of url: URL?) -> [String: CGPoint] {
        guard let url, let data = try? Data(contentsOf: layoutFile(url)), let raw = try? JSONDecoder().decode([String: [Double]].self, from: data) else { return [:] }
        return raw.compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
    }

    static func saveLayout(_ positions: [String: CGPoint], of url: URL?) {
        guard let url else { return }
        let raw = positions.mapValues { [Double($0.x.rounded()), Double($0.y.rounded())] }
        if let data = try? JSONEncoder().encode(raw) { try? data.write(to: layoutFile(url), options: .atomic) }
    }

    static func tasksDir(_ project: URL) -> URL { Runs.cache(project: project).appendingPathComponent("tasks") }

    /// One-off tasks, newest first. They stay out of the list of pipelines, and keep their runs' page until `tidy` clears them.
    static func tasks(_ project: URL) -> [Pipeline] {
        let files = (try? FileManager.default.contentsOfDirectory(at: tasksDir(project), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = files.filter { $0.pathExtension == "md" }.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
        return dated.sorted { $0.1 > $1.1 }.compactMap { url, _ in (try? String(contentsOf: url, encoding: .utf8)).map { parse($0, url: url, project: project) } }
    }

    /// A one-off task's file, named by its path.
    private static func task(at path: String) -> Pipeline? {
        let url = URL(fileURLWithPath: path)
        let parts = url.pathComponents
        guard parts.count > 4, Array(parts.suffix(4).prefix(3)) == [".apprentice", "cache", "tasks"], let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text, url: url, project: url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
    }

    /// A one-off task becomes a pipeline of the project's, there to run again.
    @discardableResult
    static func keep(_ task: Pipeline) throws -> URL {
        guard let url = task.url, let project = task.project else { throw Fail(5, "no file for \(task.ref)") }
        let dir = project.appendingPathComponent("pipelines")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var target = dir.appendingPathComponent(url.lastPathComponent), n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(n).md")
            n += 1
        }
        try FileManager.default.moveItem(at: url, to: target)
        try? FileManager.default.moveItem(at: layoutFile(url), to: layoutFile(target))
        return target
    }

    /// A simple task, as a pipeline of one step in the project's cache, so a run's page has it and the list stays yours.
    static func oneOff(_ text: String, in project: URL, agent: String? = nil, vm: String? = nil) throws -> Pipeline {
        try oneStep(text, in: project, agent: agent, vm: vm, dir: tasksDir(project))
    }

    /// Saves a simple task as a pipeline of one step in the project, under a file name of its own.
    static func oneStep(_ text: String, name: String? = nil, in project: URL, agent: String? = nil, vm: String? = nil, dir given: URL? = nil) throws -> Pipeline {
        let title = name ?? taskName(text)
        var p = Pipeline(name: title)
        p.project = project
        if let agent { p.agent = agent.lowercased() }
        p.vm = vm
        p.steps = [Step(title: title, prompt: text)]
        let dir = given ?? project.appendingPathComponent("pipelines")
        var url = dir.appendingPathComponent(slug(title) + ".md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(slug(title))-\(n).md")
            n += 1
        }
        p.url = url
        _ = try write(p)
        return p
    }

    // MARK: - CLI

    static var usage: String { "pipeline " + (Help.entry("pipeline")?.usage.dropFirst("pipeline ".count).description ?? "list") + "   (on a schedule: apprentice schedule add <name> --daily 09:00 --pipeline <name>)" }

    /// The project a new pipeline belongs to: the one named, else the one the caller is in.
    private static func owningProject(_ a: Args) throws -> URL {
        if let ref = a.value("project") {
            guard let found = Projects.find(ref) else { throw Fail(5, "no project \(ref) · apprentice project list") }
            return found.folder
        }
        guard let here = Projects.here()?.folder else {
            throw Fail(5, "a pipeline belongs to a project: run this inside one, or add --project <name> · apprentice project list")
        }
        return here
    }

    private static func options(_ a: Args) -> Options {
        Options(fresh: a.has("fresh"), keepGoing: a.has("keep-going"), from: a.int("from", 1), first: a.value("first"), last: a.value("last"), directed: a.has("directed"))
    }

    private static func launch(_ p: Pipeline, _ a: Args) throws -> String {
        a.has("background") ? try PipelineEngine.startInBackground(p, options: options(a)) : try PipelineEngine.start(p, options: options(a))
    }

    static func command(_ a: Args) throws -> String {
        let name = a.pos.dropFirst().first
        // A step asks about its own run without naming it.
        switch a.pos.first ?? "list" {
        case "list":
            let all = all()
            guard !all.isEmpty else { return "no pipelines yet · apprentice pipeline new \"name\" \"first step\" \"second step\"" }
            return all.map { p in
                "\(p.ref) · \(p.name) · \(p.steps.count) step\(p.steps.count == 1 ? "" : "s") · \(p.steps.compactMap(\.use).first ?? p.agent)" + (p.effectiveVM.map { " · VM \($0)" } ?? "")
            }.joined(separator: "\n")
        case "show":
            let p = try find(name ?? "")
            var out = ["\(p.ref) · \(p.name) · \(p.agent)" + (p.effectiveVM.map { " · VM \($0)" } ?? "") + " · \(p.url?.path ?? "")"]
            if !p.about.isEmpty { out.append(p.about) }
            for (i, s) in p.steps.enumerated() {
                let settings = [s.use.map { "use: \($0)" }, s.next.map { "next: \($0)" }, s.when.map { "when: \($0)" }, s.choose.map { "choose: \($0)" }, s.needs.map { "needs: \($0)" }, s.ui ? "ui: true" : nil].compactMap { $0 }
                out.append("\(i + 1). \(s.title)" + (settings.isEmpty ? "" : " · " + settings.joined(separator: " · ")) + "\n   " + s.prompt.replacingOccurrences(of: "\n", with: "\n   "))
            }
            return out.joined(separator: "\n")
        case "path":
            return try find(name ?? "").url?.path ?? ""
        case "new":
            guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw Fail(5, usage) }
            let project = try owningProject(a)
            var p = Pipeline(name: name)
            p.project = project
            p.agent = (a.value("agent") ?? "").lowercased()
            p.vm = a.value("vm")
            for text in a.pos.dropFirst(2) {
                let title = PipelineWires.name(from: text, taken: Set(p.steps.map(\.id))) ?? PipelineWires.newName(taken: Set(p.steps.map(\.id)))
                p.steps.append(Step(title: title, prompt: text))
            }
            let url = project.appendingPathComponent("pipelines").appendingPathComponent(slug(name) + ".md")
            guard !FileManager.default.fileExists(atPath: url.path) else { throw Fail(5, "\(url.path) already exists") }
            p.url = url
            _ = try write(p)
            return "pipeline \(p.ref) · \(p.steps.count) steps · \(url.path)\nadd a step: apprentice pipeline add \(p.ref) \"what to do\""
        case "task":
            guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Fail(5, usage) }
            return try launch(oneOff(name, in: owningProject(a), agent: a.value("agent"), vm: a.value("vm")), a)
        case "add":
            var p = try find(name ?? "")
            guard let text = a.pos.dropFirst(2).first, !text.isEmpty else { throw Fail(5, "pipeline add <name> \"what to do\" [--title \"…\"]") }
            p.steps.append(Step(title: a.value("title") ?? PipelineWires.name(from: text, taken: Set(p.steps.map(\.id))) ?? PipelineWires.newName(taken: Set(p.steps.map(\.id))), prompt: text))
            _ = try write(p)
            return "\(p.ref): step \(p.steps.count) added"
        case "run":
            return try launch(find(name ?? ""), a)
        case "direct":
            return try PipelineCLI.direct(name, a)
        case "check":
            let p = try find(name ?? "")
            return try PipelineCLI.check(p)
        case "audit":
            let p = try find(name ?? "")
            return try PipelineCLI.audit(p)
        case "status":
            return try PipelineCLI.status(name, a)
        case "answer":
            return try PipelineCLI.answer(a)
        case "resume":
            return try PipelineCLI.resume(name, a)
        case "stop":
            return try PipelineCLI.stop(name, a)
        case "notes":
            return try PipelineCLI.notes(name, a)
        case "rm":
            let p = try find(name ?? "")
            guard let url = p.url else { throw Fail(5, "no file for \(p.ref)") }
            // To the Trash, not gone: a pipeline is the user's own writing.
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            try? FileManager.default.removeItem(at: layoutFile(url))
            let waiting = Schedules.all().filter { $0.kind == .pipeline && [p.ref, p.slug, p.name, url.path].contains($0.target) }.map(\.name)
            return "moved \(url.lastPathComponent) to the Trash" + (waiting.isEmpty ? "" : " · these schedules still name it and will fail: " + waiting.joined(separator: ", "))
        default:
            throw Fail(5, usage)
        }
    }
}
