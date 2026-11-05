import CryptoKit
import Foundation

/// A named agent is a CLI plus a model, an effort and a permission level, under a name the user chooses
/// ("Joseph", "deepseek_4_1_opencode_max"). Pipelines, the interpreter and the scribe refer to agents only by
/// these names. They live in `~/.apprentice/named-agents.toml` and `<project>/.apprentice/named-agents.toml`:
/// a project entry with a name the global file has changes only the fields it writes. The same files hold the
/// defaults (`[defaults] interpreter, scribe, priority`), which a project inherits until it sets its own.
///
/// A project's file travels with the repo, so it is someone else's text once the project was downloaded: it may
/// only name a CLI apprentice already knows, and asking for more than the global entry allows (or more than
/// read-only for a name only the project has) needs the user's answer once, kept on this Mac, never in the repo.
enum NamedAgents {
    static let levels = ["read-only", "edit", "full"]

    /// How tight a level is; unset is the CLI's own `run` line, which is treated as read-only for trust.
    static func rank(_ level: String?) -> Int { level.flatMap { levels.firstIndex(of: $0) } ?? 0 }

    enum Origin: String, Codable { case global, project, changedHere, cli }

    struct Named: Equatable, Codable {
        var name: String
        var agent: String
        var model: String? = nil
        var effort: String? = nil
        var permissions: String? = nil
        var origin: Origin = .global

        var originLabel: String {
            switch origin {
            case .global: return "Global"
            case .project: return "This project"
            case .changedHere: return "Changed here"
            case .cli: return "The CLI as it is"
            }
        }
    }

    struct Defaults: Equatable {
        var interpreter: String? = nil
        var scribe: [String] = []
        var priority: [String] = []
    }

    static var globalFile: URL { Settings.dir.appendingPathComponent("named-agents.toml") }
    static func projectFile(_ folder: URL) -> URL { folder.appendingPathComponent(".apprentice/named-agents.toml") }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
    }

    // MARK: - reading

    /// Name order as written, since a list on screen should not reshuffle.
    private static func order(_ text: String) -> [String] {
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            guard let h = Toml.header(line).map(Toml.canonical), h.hasPrefix("named.") else { continue }
            let name = String(h.dropFirst("named.".count))
            if !out.contains(name) { out.append(name) }
        }
        return out
    }

    private static func entries(_ text: String) -> [(name: String, fields: [String: String])] {
        let table = Toml.parse(text)
        return order(text).map { name in
            (name, (table["named.\(name)"] ?? [:]).mapValues(Toml.unquote).filter { !$0.value.isEmpty })
        }
    }

    private static func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    /// Global entries, then the project's over them. Names are matched ignoring case.
    static func merge(global: String, project: String?) -> [Named] {
        var out: [Named] = []
        for (name, f) in entries(global) {
            guard let agent = f["agent"] else { continue }
            out.append(Named(name: name, agent: agent.lowercased(), model: f["model"], effort: f["effort"], permissions: f["permissions"]))
        }
        guard let project else { return out }
        for (name, f) in entries(project) {
            if let i = out.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
                if let agent = f["agent"] { out[i].agent = agent.lowercased() }
                if let v = f["model"] { out[i].model = v }
                if let v = f["effort"] { out[i].effort = v }
                if let v = f["permissions"] { out[i].permissions = v }
                out[i].origin = .changedHere
            } else if let agent = f["agent"] {
                out.append(Named(name: name, agent: agent.lowercased(), model: f["model"], effort: f["effort"], permissions: f["permissions"], origin: .project))
            }
        }
        return out
    }

    static func all(project: URL?) -> [Named] {
        merge(global: read(globalFile), project: project.map { read(projectFile($0)) })
    }

    /// What a step's Agent menu offers: the named agents, then each CLI on this Mac under its own name, which `find`
    /// runs as it is, so a Mac with no named agents can still choose one for each step.
    static func choices(project: URL?, installed: Set<String>, clis: [AgentCLIs.CLI] = AgentCLIs.agents()) -> [(id: String, label: String)] {
        let named = all(project: project).map(\.name)
        let plain = clis.filter { installed.contains($0.id) && !$0.run.isEmpty && $0.shell != true && !named.map { $0.lowercased() }.contains($0.id) }
        return named.map { ($0, $0) } + plain.map { ($0.id, $0.label) }
    }

    /// A name from the files, else a CLI's own id as it is, so a pipeline with no agents set up still runs.
    static func find(_ name: String, project: URL?, list: [Named]? = nil) -> Named? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let hit = (list ?? all(project: project)).first(where: { $0.name.lowercased() == key }) { return hit }
        guard let cli = AgentCLIs.find(key), !cli.isEditor else { return nil }
        return Named(name: cli.id, agent: cli.id, origin: .cli)
    }

    private static func defaults(_ text: String) -> Defaults {
        let v = Toml.parse(text)["defaults"] ?? [:]
        return Defaults(interpreter: v["interpreter"].map(Toml.unquote).flatMap { $0.isEmpty ? nil : $0 },
                        scribe: v["scribe"].flatMap(Toml.array) ?? [], priority: v["priority"].flatMap(Toml.array) ?? [])
    }

    /// The project's defaults over the global ones, key by key.
    static func defaults(project: URL?) -> Defaults {
        let global = defaults(read(globalFile))
        guard let project else { return global }
        let own = defaults(read(projectFile(project)))
        return Defaults(interpreter: own.interpreter ?? global.interpreter,
                        scribe: own.scribe.isEmpty ? global.scribe : own.scribe,
                        priority: own.priority.isEmpty ? global.priority : own.priority)
    }

    // MARK: - turning one into a command line

    /// What one run needs beyond the prompt.
    struct Extras {
        var session: String? = nil
        /// A folder it must be able to write besides its working folder.
        var dir: URL? = nil
        var permissions: String? = nil
    }

    /// The command line: the CLI's `run` line, then the flags for the model, effort, permission level and session.
    /// A setting the CLI has no flag for is left out; the Agents form says so when it is chosen.
    static func argv(_ n: Named, prompt: String, extras: Extras = Extras(), clis: [AgentCLIs.CLI]? = nil) -> [String] {
        let list = clis ?? AgentCLIs.all()
        // Empty for a name no CLI answers to: a project's file must not be able to make this Mac run its own command.
        guard let cli = AgentCLIs.find(n.agent, in: list), !cli.run.isEmpty else { return [] }
        var out = cli.run.map { $0.replacingOccurrences(of: "{prompt}", with: prompt) }
        func fill(_ flags: [String], _ key: String, _ value: String) -> [String] { flags.map { $0.replacingOccurrences(of: "{\(key)}", with: value) } }
        if let model = n.model { out += fill(cli.modelFlags, "model", model) }
        if let effort = n.effort { out += fill(cli.effortFlags, "effort", effort) }
        let level = extras.permissions ?? n.permissions
        if let level, let flags = cli.permissionFlags[level] { out += flags }
        if let session = extras.session, !cli.session.isEmpty { out += fill(cli.session, "session", session) }
        out += cli.ephemeral
        if let dir = extras.dir, !sealed(cli, level) { out += fill(cli.addDir, "dir", dir.path) }
        return out
    }

    /// At this level its sandbox stops apprentice's own commands, so the prompt says so.
    static func sealed(_ cli: AgentCLIs.CLI?, _ level: String?) -> Bool { level.map { cli?.sealed.contains($0) == true } ?? false }

    /// Problems with one entry, in words: an unknown CLI, a setting the CLI cannot apply.
    static func problems(_ n: Named, clis: [AgentCLIs.CLI]? = nil) -> [String] {
        let list = clis ?? AgentCLIs.all()
        guard let cli = AgentCLIs.find(n.agent, in: list) else { return ["\(n.name): no CLI called \(n.agent) (agents.toml)"] }
        if cli.isEditor { return ["\(n.name): \(cli.label) only opens a folder; it cannot run a step"] }
        var out: [String] = []
        if n.effort != nil, cli.effortFlags.isEmpty { out.append("\(n.name): \(cli.label) has no effort setting; it will be left out") }
        if n.model != nil, cli.modelFlags.isEmpty { out.append("\(n.name): \(cli.label) has no model setting; it will be left out") }
        if let level = n.permissions {
            if !levels.contains(level) { out.append("\(n.name): permissions is read-only, edit or full, not \(level)") }
            else if cli.permissionFlags[level] == nil { out.append("\(n.name): \(cli.label) cannot enforce \(level)") }
        }
        return out
    }

    // MARK: - what a project may ask for

    static var approvalsFile: URL { Store.dir.appendingPathComponent("project-agents.json") }

    private static func approvalKey(_ n: Named, project: URL, level: String?) -> String {
        let text = "\(project.standardizedFileURL.path)|\(n.name.lowercased())|\(n.agent)|\(level ?? "")"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func approvals() -> Set<String> {
        (try? Data(contentsOf: approvalsFile)).flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? []
    }

    /// Why a project's entry needs the user's answer, or nil when it needs none: it asks for more than the global
    /// entry of that name allows, or for more than read-only under a name only the project has.
    static func wants(_ n: Named, project: URL, globals: [Named]? = nil) -> String? {
        guard n.origin == .project || n.origin == .changedHere else { return nil }
        let global = (globals ?? merge(global: read(globalFile), project: nil)).first { $0.name.lowercased() == n.name.lowercased() }
        let limit = global.map { rank($0.permissions) } ?? 0
        // A new name with no level runs at the CLI's own default, which for some can edit: that is more than read-only.
        let asks = n.permissions == nil && global == nil ? limit + 1 : rank(n.permissions)
        guard asks > limit else { return nil }
        guard !approvals().contains(approvalKey(n, project: project, level: n.permissions)) else { return nil }
        return "This project's files ask for \(n.name) to run \(AgentCLIs.label(n.agent)) with \(n.permissions ?? "the CLI's default") permissions"
            + (global.map { ", more than the \($0.permissions ?? "default") you set" } ?? "") + "."
    }

    static func approve(_ n: Named, project: URL) {
        var set = approvals()
        set.insert(approvalKey(n, project: project, level: n.permissions))
        try? Wire.json(set).write(to: approvalsFile, options: .atomic)
    }

    // MARK: - writing

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func list(_ items: [String]) -> String { "[" + items.map(quote).joined(separator: ", ") + "]" }

    /// Removes one `[named.x]` section and its keys, whatever else the file holds staying as it was.
    private static func removeSection(_ url: URL, _ name: String) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var out: [String] = []
        var skipping = false
        for line in text.components(separatedBy: "\n") {
            if let h = Toml.header(line).map(Toml.canonical) { skipping = h.lowercased() == "named.\(name.lowercased())" }
            if !skipping { out.append(line) }
        }
        try? out.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func file(_ project: URL?) -> URL { project.map(projectFile) ?? globalFile }

    /// A project's first mention of a global name writes only the fields it was given.
    static func set(_ name: String, fields: [String: String?], project: URL?) throws {
        guard validName(name) else { throw Fail(5, "a name is letters, digits and _: \(name)") }
        let url = file(project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { try "".write(to: url, atomically: true, encoding: .utf8) }
        // A name already here under other capitals is the same agent.
        let existing = order(read(url)).first { $0.lowercased() == name.lowercased() } ?? name
        if let cli = fields["agent"] ?? nil {
            guard AgentCLIs.find(cli) != nil else { throw Fail(5, "no CLI called \(cli): add new CLIs in \(AgentCLIs.files[1].path)") }
        }
        if let level = fields["permissions"] ?? nil, !level.isEmpty, !levels.contains(level) { throw Fail(5, "permissions is read-only, edit or full") }
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            if let value, !value.isEmpty { Toml.set(url, "named.\(existing)", key, quote(value)) }
            else { Toml.remove(url, "named.\(existing)", key) }
        }
    }

    static func remove(_ name: String, project: URL?) { removeSection(file(project), name) }

    static func setDefaults(_ new: Defaults, keys: Set<String>, project: URL?) throws {
        let url = file(project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { try "".write(to: url, atomically: true, encoding: .utf8) }
        if keys.contains("interpreter") {
            if let v = new.interpreter { Toml.set(url, "defaults", "interpreter", quote(v)) } else { Toml.remove(url, "defaults", "interpreter") }
        }
        if keys.contains("scribe") {
            if new.scribe.isEmpty { Toml.remove(url, "defaults", "scribe") } else { Toml.set(url, "defaults", "scribe", list(new.scribe)) }
        }
        if keys.contains("priority") {
            if new.priority.isEmpty { Toml.remove(url, "defaults", "priority") } else { Toml.set(url, "defaults", "priority", list(new.priority)) }
        }
    }

    /// Renames a global agent here and in every listed project, so a rename never strands a project's change.
    /// A pipeline file naming the old name is reported, not rewritten: it is the user's writing.
    static func rename(_ old: String, to new: String, project: URL?) throws -> [String] {
        guard validName(new) else { throw Fail(5, "a name is letters, digits and _: \(new)") }
        guard all(project: project).contains(where: { $0.name.lowercased() == old.lowercased() }) else { throw Fail(5, "no agent called \(old)") }
        guard !all(project: project).contains(where: { $0.name.lowercased() == new.lowercased() }) else { throw Fail(5, "there is already an agent called \(new)") }
        func renameIn(_ url: URL) -> Bool {
            guard let text = try? String(contentsOf: url, encoding: .utf8), text.lowercased().contains(old.lowercased()) else { return false }
            let lines = text.components(separatedBy: "\n").map { line -> String in
                if Toml.header(line).map(Toml.canonical)?.lowercased() == "named.\(old.lowercased())" { return "[named.\(new)]" }
                // The defaults name it too, or a rename would quietly empty a priority list.
                guard let eq = line.firstIndex(of: "="), ["priority", "scribe", "interpreter"].contains(line[..<eq].trimmingCharacters(in: .whitespaces)) else { return line }
                let value = String(line[line.index(after: eq)...])
                let renamed = value.replacingOccurrences(of: "(?i)\"\(NSRegularExpression.escapedPattern(for: old))\"", with: "\"\(new)\"", options: .regularExpression)
                return String(line[...eq]) + renamed
            }
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return true
        }
        var out: [String] = []
        if project == nil {
            _ = renameIn(globalFile)
            for p in Projects.all() where renameIn(projectFile(p.folder)) { out.append("updated \(p.name)") }
        } else if let project { _ = renameIn(projectFile(project)) }
        for p in project.map({ Pipelines.inFolder($0) }) ?? Pipelines.all() {
            if p.steps.contains(where: { $0.use?.lowercased() == old.lowercased() }) || p.interpreter?.lowercased() == old.lowercased() || p.scribes.contains(where: { $0.lowercased() == old.lowercased() }) {
                out.append("\(p.ref) still names \(old): edit it")
            }
        }
        return out
    }

    // MARK: - CLI

    static let usage = "agents list [--project p] · test <name> [--project p] · set <name> [--agent cli] [--model m] [--effort e] [--permissions read-only|edit|full] [--project p] · rm <name> [--project p] · rename <old> <new> · defaults [--interpreter a] [--scribe a,b] [--priority a,b,c] [--project p] · install <cli> · clis"

    private static func project(_ a: Args) throws -> URL? {
        if let ref = a.value("project") {
            guard let p = Projects.find(ref) else { throw Fail(5, "no project \(ref) · apprentice project list") }
            return p.folder
        }
        return Projects.here()?.folder
    }

    static func describe(_ n: Named) -> String {
        [n.name, AgentCLIs.label(n.agent), n.model.map { "model \($0)" }, n.effort.map { "effort \($0)" },
         n.permissions.map { "permissions \($0)" } ?? "permissions as the CLI's run line", n.originLabel.lowercased()]
            .compactMap { $0 }.joined(separator: " · ")
    }

    static func command(_ a: Args) throws -> String {
        let where_ = try project(a)
        let scope = a.has("global") ? nil : (a.value("project") != nil ? where_ : nil)
        let name = a.pos.dropFirst().first
        switch a.pos.first ?? "list" {
        case "list":
            let list = all(project: where_)
            let d = defaults(project: where_)
            var out = list.isEmpty ? ["no named agents yet · apprentice agents set Joseph --agent claude --permissions edit"] : list.map(describe)
            for n in list { out += problems(n).map { "  ⚠ \($0)" } }
            out.append("interpreter: \(d.interpreter ?? "none set") · scribe: \(d.scribe.isEmpty ? "none set" : d.scribe.joined(separator: ", ")) · priority: \(d.priority.isEmpty ? "none set" : d.priority.joined(separator: ", "))")
            return out.joined(separator: "\n")
        case "clis":
            let installed = AgentCLIs.installed()
            return AgentCLIs.agents().filter { !$0.shell }.map { c in
                "\(c.id) · \(c.label) · \(installed.contains(c.id) ? "installed" : "not installed") · permissions: \(c.levels.isEmpty ? "none it can enforce" : c.levels.joined(separator: ", "))"
                    + (c.effortFlags.isEmpty ? " · no effort setting" : "")
            }.joined(separator: "\n")
        case "test":
            guard let name, let n = find(name, project: where_) else { throw Fail(5, "no agent called \(name ?? "") · apprentice agents list") }
            return try test(n)
        case "set":
            guard let name else { throw Fail(5, usage) }
            var fields: [String: String?] = [:]
            for key in ["agent", "model", "effort", "permissions"] {
                if a.flags[key] != nil { fields[key] = a.flags[key] }
                if a.has("no-\(key)") { fields[key] = String?.none }
            }
            guard !fields.isEmpty else { throw Fail(5, usage) }
            if scope == nil, fields["agent"] == nil, !all(project: nil).contains(where: { $0.name.lowercased() == name.lowercased() }) {
                throw Fail(5, "a new agent needs --agent <cli> · apprentice agents clis")
            }
            try set(name, fields: fields, project: scope)
            let shown = find(name, project: scope)
            return (shown.map(describe) ?? name) + (shown.map { problems($0) }?.map { "\n⚠ \($0)" }.joined() ?? "")
        case "rm":
            guard let name else { throw Fail(5, usage) }
            remove(name, project: scope)
            return "removed \(name)" + (scope != nil ? " from this project; a global \(name), if any, applies again" : "")
        case "rename":
            guard let name, let new = a.pos.dropFirst(2).first else { throw Fail(5, usage) }
            let notes = try rename(name, to: new, project: scope)
            return (["renamed \(name) to \(new)"] + notes).joined(separator: "\n")
        case "defaults":
            var d = Defaults()
            var keys = Set<String>()
            func names(_ raw: String) -> [String] { raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            if let v = a.value("interpreter") { d.interpreter = v.isEmpty ? nil : v; keys.insert("interpreter") }
            if let v = a.value("scribe") { d.scribe = names(v); keys.insert("scribe") }
            if let v = a.value("priority") { d.priority = names(v); keys.insert("priority") }
            for key in ["interpreter", "scribe", "priority"] where a.has("no-\(key)") { keys.insert(key) }
            if !keys.isEmpty { try setDefaults(d, keys: keys, project: scope) }
            let now = defaults(project: scope ?? where_)
            return "interpreter: \(now.interpreter ?? "none set") · scribe: \(now.scribe.joined(separator: ", ")) · priority: \(now.priority.joined(separator: ", "))"
        case "install":
            guard let name, let cli = AgentCLIs.find(name) else { throw Fail(5, "agents install <cli> · apprentice agents clis") }
            guard let line = cli.installCommand else { return cli.install.map { "\(cli.label) has no one-line install; get it from \($0)" } ?? "\(cli.label) has no one-line install" }
            return line
        default:
            throw Fail(5, usage)
        }
    }

    /// One tiny real prompt, so a wrong model name shows before a run. Spends a few tokens, only when asked.
    static func test(_ n: Named, seconds: Double = 120) throws -> String {
        let cli = AgentCLIs.find(n.agent)
        guard cli?.run.isEmpty == false else { throw Fail(5, "\(n.name): \(AgentCLIs.label(n.agent)) cannot run a prompt") }
        let word = "ready"
        let session = cli?.session.isEmpty == false ? UUID().uuidString.lowercased() : nil
        let argv = argv(n, prompt: "Reply with exactly one word: \(word)", extras: Extras(session: session))
        let started = Date()
        let result = AgentRun.run(argv, cli: cli, in: FileManager.default.temporaryDirectory, env: [:], log: nil, stallSeconds: seconds, totalSeconds: seconds)
        AgentRun.forget(cli: cli, session: session ?? result.session, cwd: FileManager.default.temporaryDirectory)
        let took = Int(Date().timeIntervalSince(started))
        if result.outcome == .ok, result.text.lowercased().contains(word) { return "\(n.name) works · \(took) s · \(describe(n))" }
        let last = result.text.split(separator: "\n").suffix(3).joined(separator: "\n")
        let why = AgentRun.limitPhrase(cli: cli, text: result.text) != nil ? "it has run out of usage" : result.outcome.rawValue
        throw Fail(5, "\(n.name) failed: \(why) after \(took) s\n\(last)")
    }
}
