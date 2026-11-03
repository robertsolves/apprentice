import Foundation

/// A pipeline is a list of prompts that run one after another, now (`pipeline run`) or on a schedule
/// (`schedule add … --pipeline <name>`): "get the new comments from Instagram", then "answer the ones that
/// ask about prices by email". Each step is a prompt for the pipeline's agent CLI (`claude -p`…), run in the
/// pipeline's folder, and it gets the end of the previous step's output, so step two can use what step one
/// found. A step whose whole text is `sh: <command>` runs that command instead. The first step that fails
/// stops the run.
///
/// A pipeline is one Markdown file, so a person can read and edit it anywhere:
///
///     ---
///     name: Morning round
///     agent: claude
///     vm: shop                 # optional; else the project's VM, else this Mac
///     ---
///     # Morning round
///
///     ## Read Instagram
///     Get the comments on my newest Instagram post …
///
///     ## Answer by email
///     …
///
/// It lives in a project's `pipelines/` folder, or in `~/.apprentice/pipelines/` when it belongs to no project.
enum Pipelines {
    struct Step: Equatable {
        var title: String
        var prompt: String

        /// `sh: <command>` as the step's whole text.
        var shell: String? {
            let t = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasPrefix("sh:"), !t.contains("\n") else { return nil }
            return String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
    }

    struct Pipeline {
        var name: String
        var agent = AgentCLIs.defaultID
        var vm: String?
        var about = ""
        var steps: [Step] = []
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
        var about: [String] = []
        var current: Step?
        var body: [String] = []
        func close() {
            if var step = current {
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
        var out = ["---", "name: \(metaQuoted(p.name))", "agent: \(metaQuoted(p.agent))"]
        if let vm = p.vm, !vm.isEmpty { out.append("vm: \(metaQuoted(vm))") }
        out += ["---", "# \(p.name)", ""]
        if !p.about.isEmpty { out += [p.about, ""] }
        for (i, step) in p.steps.enumerated() {
            let title = step.title.trimmingCharacters(in: .whitespaces)
            out.append("## \(i + 1). \(title.isEmpty ? "Step \(i + 1)" : title)")
            out.append(step.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    /// The pipelines in one folder's `pipelines/` (or in `homeDir` when `project` is nil).
    static func inFolder(_ project: URL?) -> [Pipeline] {
        let dir = project.map { $0.appendingPathComponent("pipelines") } ?? homeDir
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" && $0.lastPathComponent != "README.md" }
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
        let hits = all.filter { $0.ref.lowercased() == key || slug($0.slug) == slug(ref) || $0.name.lowercased() == key }
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

    // MARK: - running

    /// The prompt a step's agent gets: the step, where it stands in the pipeline, and what the step before
    /// it printed (its end, so a long answer cannot crowd out the step).
    static func prompt(_ p: Pipeline, step index: Int, previous: String) -> String {
        let step = p.steps[index]
        var text = "This is step \(index + 1) of \(p.steps.count) of the pipeline \"\(p.name)\""
            + (step.title.isEmpty ? "" : ": \(step.title)") + ".\n\n" + step.prompt
        let prior = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prior.isEmpty {
            text += "\n\nWhat the previous step reported:\n" + String(prior.suffix(6000))
        }
        return text
    }

    /// Runs the steps from `from` (1-based), printing each one's output as it comes. Throws at the first
    /// step that fails, with its exit code, unless `keepGoing`.
    static func run(_ p: Pipeline, from: Int = 1, keepGoing: Bool = false) throws -> String {
        guard !p.steps.isEmpty else { throw Fail(5, "\(p.ref) has no steps yet · apprentice pipeline add \(p.ref) \"what to do\"") }
        guard from >= 1, from <= p.steps.count else { throw Fail(5, "--from is 1 to \(p.steps.count)") }
        let started = Date()
        var previous = ""
        // Every step is one owner of the screen (`Device`): the tab or schedule it runs from, else the pipeline.
        let tab = ProcessInfo.processInfo.environment["APPRENTICE_TAB"].flatMap { $0.isEmpty ? nil : $0 } ?? "pipeline:\(p.ref)"
        let who = tab.hasPrefix("schedule:") || tab.hasPrefix("pipeline:") ? tab : "tab:\(tab)"
        var failed: [String] = []
        for i in (from - 1)..<p.steps.count {
            let step = p.steps[i]
            say("\n── step \(i + 1) of \(p.steps.count) · \(step.title.isEmpty ? "untitled" : step.title)\n")
            // One thing at a time on a screen: wait while another agent holds it, up to half an hour.
            var waited = 0
            while let holder = Device.busy(vm: p.effectiveVM, for: who), waited < 1800 {
                if waited == 0 { say("waiting: \(p.effectiveVM.map { "the VM \($0)" } ?? "this Mac") is in use by \(holder)\n") }
                Thread.sleep(forTimeInterval: 15)
                waited += 15
            }
            var argv: [String]
            if let command = step.shell ?? (AgentCLIs.find(p.agent)?.shell == true ? step.prompt : nil) {
                if Config.current.uiOnly { throw Fail(5, "step \(i + 1) is a shell command, and shells are off under [agent] ui_only") }
                argv = ["/bin/zsh", "-lc", command]
            } else {
                argv = ["/bin/zsh", "-lc", "exec \"$@\"", "zsh"] + Schedules.agentArgv(p.agent, prompt(p, step: i, previous: previous))
            }
            let (code, output) = stream(argv, in: p.folder, vm: p.effectiveVM, project: p.project, tab: tab)
            Store.log(["cmd": "pipeline", "pipeline": p.ref, "step": i + 1, "code": Int(code)])
            previous = output
            if code != 0 {
                failed.append("step \(i + 1) exit \(code)")
                if !keepGoing {
                    throw Fail(code == 0 ? 1 : code, "\n\(p.name): step \(i + 1) (\(step.title)) failed with exit \(code). Fix it, then `apprentice pipeline run \(p.ref) --from \(i + 1)`")
                }
            }
            argv.removeAll()
        }
        let seconds = Int(Date().timeIntervalSince(started))
        let ran = p.steps.count - from + 1
        return "\n\(p.name): " + (failed.isEmpty ? (ran == 1 ? "the step is done" : "all \(ran) steps done") : failed.joined(separator: ", ")) + " · \(seconds) s"
    }

    private static func say(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    /// Runs one step with its output shown as it comes and kept for the next step.
    private static func stream(_ argv: [String], in folder: URL, vm: String?, project: URL?, tab: String) -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: argv[0])
        proc.arguments = Array(argv.dropFirst())
        proc.currentDirectoryURL = folder
        var env = ProcessInfo.processInfo.environment
        if let vm { env["APPRENTICE_VM"] = vm }
        env["APPRENTICE_TAB"] = tab
        if let project { env["APPRENTICE_PROJECT"] = project.appendingPathComponent(".apprentice").path }
        proc.environment = env
        proc.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        var collected = Data()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            FileHandle.standardOutput.write(data)
            lock.lock()
            collected.append(data)
            // Only the end goes to the next step; keep the buffer bounded on a chatty step.
            if collected.count > 200_000 { collected = collected.suffix(100_000) }
            lock.unlock()
        }
        do { try proc.run() } catch { return (127, "could not start: \(error.localizedDescription)") }
        proc.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        if !rest.isEmpty { FileHandle.standardOutput.write(rest) }
        lock.lock()
        collected.append(rest)
        let text = String(decoding: collected, as: UTF8.self)
        lock.unlock()
        return (proc.terminationStatus, text)
    }

    // MARK: - CLI

    static let usage = "pipeline list · show <name> · new <name> [\"step\" …] [--project <name>] [--agent <one of agents.toml>] [--vm <name>] · add <name> \"what to do\" [--title \"…\"] · run <name> [--from N] [--keep-going] · path <name> · rm <name>   (on a schedule: apprentice schedule add <name> --daily 09:00 --pipeline <name>)"

    static func command(_ a: Args) throws -> String {
        let name = a.pos.dropFirst().first
        switch a.pos.first ?? "list" {
        case "list":
            let all = all()
            guard !all.isEmpty else { return "no pipelines yet · apprentice pipeline new \"name\" \"first step\" \"second step\"" }
            return all.map { p in
                "\(p.ref) · \(p.name) · \(p.steps.count) step\(p.steps.count == 1 ? "" : "s") · \(p.agent)" + (p.effectiveVM.map { " · VM \($0)" } ?? "")
            }.joined(separator: "\n")
        case "show":
            let p = try find(name ?? "")
            var out = ["\(p.ref) · \(p.name) · \(p.agent)" + (p.effectiveVM.map { " · VM \($0)" } ?? "") + " · \(p.url?.path ?? "")"]
            if !p.about.isEmpty { out.append(p.about) }
            for (i, s) in p.steps.enumerated() { out.append("\(i + 1). \(s.title)\n   " + s.prompt.replacingOccurrences(of: "\n", with: "\n   ")) }
            return out.joined(separator: "\n")
        case "path":
            return try find(name ?? "").url?.path ?? ""
        case "new":
            guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw Fail(5, usage) }
            var project: URL?
            if let ref = a.value("project") {
                guard let found = Projects.find(ref) else { throw Fail(5, "no project \(ref) · apprentice project list") }
                project = found.folder
            } else {
                project = Projects.here()?.folder
            }
            var p = Pipeline(name: name)
            p.project = project
            p.agent = (a.value("agent") ?? Projects.here()?.agent ?? AgentCLIs.defaultID).lowercased()
            p.vm = a.value("vm")
            p.steps = a.pos.dropFirst(2).enumerated().map { Step(title: "Step \($0.offset + 1)", prompt: $0.element) }
            let url = (project.map { $0.appendingPathComponent("pipelines") } ?? homeDir).appendingPathComponent(slug(name) + ".md")
            guard !FileManager.default.fileExists(atPath: url.path) else { throw Fail(5, "\(url.path) already exists") }
            p.url = url
            _ = try write(p)
            return "pipeline \(p.ref) · \(p.steps.count) steps · \(url.path)\nadd a step: apprentice pipeline add \(p.ref) \"what to do\""
        case "add":
            var p = try find(name ?? "")
            guard let text = a.pos.dropFirst(2).first, !text.isEmpty else { throw Fail(5, "pipeline add <name> \"what to do\" [--title \"…\"]") }
            p.steps.append(Step(title: a.value("title") ?? "Step \(p.steps.count + 1)", prompt: text))
            _ = try write(p)
            return "\(p.ref): step \(p.steps.count) added"
        case "run":
            let p = try find(name ?? "")
            return try run(p, from: a.int("from", 1), keepGoing: a.has("keep-going"))
        case "rm":
            let p = try find(name ?? "")
            guard let url = p.url else { throw Fail(5, "no file for \(p.ref)") }
            // To the Trash, not gone: a pipeline is the user's own writing.
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return "moved \(url.lastPathComponent) to the Trash"
        default:
            throw Fail(5, usage)
        }
    }
}
