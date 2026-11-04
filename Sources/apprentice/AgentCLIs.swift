import Foundation

/// The agent CLIs apprentice can start, read from `agent/agents.toml` (shipped) and `~/.apprentice/agents.toml`
/// (the user's, added to it and replacing an entry with the same id), so a new agent is a few lines in a file
/// and every picker, the new-tab menu, projects, pipelines and schedules offer it.
enum AgentCLIs {
    struct CLI: Identifiable, Equatable {
        let id: String
        let label: String
        /// What a terminal tab starts; nil for a plain shell.
        let open: String?
        /// One prompt without a terminal, `{prompt}` where it goes.
        let run: [String]
        let aliases: [String]
        /// The prompt is a shell command.
        let shell: Bool
        /// What says it is installed: commands looked up in the login shell, or app paths. Empty: always.
        var detect: [String] = []
        /// Where to get it, shown for one that is not installed.
        var install: String? = nil
        /// An editor app rather than a terminal agent: opened on a project's folder, `{folder}` where it goes.
        var editor: [String] = []
        /// The one line that installs it, typed into a shell tab from Settings ▸ Agents.
        var installCommand: String? = nil
        /// Flags for a named agent's model and effort (`{model}`, `{effort}`). Empty: the CLI has none.
        var modelFlags: [String] = []
        var effortFlags: [String] = []
        /// Flags per permission level. A level with no entry is one this CLI cannot enforce.
        var permissionFlags: [String: [String]] = [:]
        /// Levels whose sandbox stops apprentice's own commands (no board posts, no questions).
        var sealed: [String] = []
        var addDir: [String] = []
        /// Its session: flags naming it, flags keeping it from being written, or where its id is in JSON output.
        var session: [String] = []
        var sessionShort: Int? = nil
        var ephemeral: [String] = []
        var sessionFrom: String? = nil
        var textFrom: String? = nil
        var errorFrom: String? = nil
        var transcript: String? = nil
        var projectDir: String? = nil
        var forget: [String] = []
        /// Phrases it prints when out of usage, and when refused a tool or a permission.
        var limits: [String] = []
        var refusals: [String] = []
        var sessionsRoot: String? = nil
        var clearHint: String? = nil
        /// Where it reads a project's skills and slash commands.
        var skillsDir: String? = nil
        var commandsDir: String? = nil
        var commandsFormat: String = "md"

        var isEditor: Bool { !editor.isEmpty }
        /// The permission levels this CLI can enforce, loosest last.
        var levels: [String] { NamedAgents.levels.filter { permissionFlags[$0] != nil } }
    }

    static var files: [URL] {
        [Repo.shipped("agent/agents.toml"), Settings.dir.appendingPathComponent("agents.toml")]
    }

    static func all(_ files: [URL] = files) -> [CLI] {
        var out: [CLI] = []
        for file in files {
            for cli in parse((try? String(contentsOf: file, encoding: .utf8)) ?? "") {
                if let i = out.firstIndex(where: { $0.id == cli.id }) { out[i] = cli } else { out.append(cli) }
            }
        }
        return out
    }

    /// The `[agent.<id>]` sections in the order written.
    static func parse(_ text: String) -> [CLI] {
        let table = Toml.parse(text)
        var order: [String] = []
        for line in text.components(separatedBy: "\n") {
            if let h = Toml.header(line).map(Toml.canonical), h.hasPrefix("agent."), !order.contains(h) { order.append(h) }
        }
        return order.map { section in
            let v = table[section] ?? [:]
            let id = String(section.dropFirst("agent.".count)).lowercased()
            let editor = v["editor"].flatMap(Toml.array) ?? []
            let open = v["open"].map(Toml.unquote) ?? (editor.isEmpty ? id : "")
            let shell = v["shell"].map(Toml.unquote) == "true"
            // Unless the file says otherwise, an agent is installed when its own command is on the PATH.
            let firstWord = open.split(separator: " ").first.map(String.init)
            let detect = v["detect"].flatMap(Toml.array) ?? (shell ? [] : firstWord.map { [$0] } ?? [])
            func list(_ key: String) -> [String] { v[key].flatMap(Toml.array) ?? [] }
            func text(_ key: String) -> String? { v[key].map(Toml.unquote).flatMap { $0.isEmpty ? nil : $0 } }
            var permissions: [String: [String]] = [:]
            for level in NamedAgents.levels {
                if let flags = v["permission_" + level.replacingOccurrences(of: "-", with: "_")].flatMap(Toml.array) { permissions[level] = flags }
            }
            return CLI(id: id, label: v["label"].map(Toml.unquote) ?? id, open: open.isEmpty ? nil : open,
                       run: v["run"].flatMap(Toml.array) ?? [], aliases: (v["aliases"].flatMap(Toml.array) ?? []).map { $0.lowercased() },
                       shell: shell, detect: detect, install: v["install"].map(Toml.unquote).flatMap { $0.isEmpty ? nil : $0 },
                       editor: editor, installCommand: text("install_command"), modelFlags: list("model"), effortFlags: list("effort"),
                       permissionFlags: permissions, sealed: list("sealed"), addDir: list("add_dir"), session: list("session"),
                       sessionShort: text("session_short").flatMap(Int.init), ephemeral: list("ephemeral"), sessionFrom: text("session_from"),
                       textFrom: text("text_from"), errorFrom: text("error_from"), transcript: text("transcript"), projectDir: text("project_dir"),
                       forget: list("forget"), limits: list("limits"), refusals: list("refusals"), sessionsRoot: text("sessions_root"),
                       clearHint: text("clear_hint"), skillsDir: text("skills_dir"), commandsDir: text("commands_dir"),
                       commandsFormat: text("commands_format") ?? "md")
        }
    }

    /// The terminal agents: what tabs, projects, pipelines and schedules offer.
    static func agents(_ list: [CLI] = all()) -> [CLI] { list.filter { !$0.isEditor } }

    /// The editor apps a project's folder can be opened in.
    static func editors(_ list: [CLI] = all()) -> [CLI] { list.filter(\.isEditor) }

    /// A line saying an agent is not installed and where to get it, nil when it is (or is unknown).
    static func missingNote(_ id: String) -> String? {
        let list = all()
        guard let cli = find(id, in: list), !cli.detect.isEmpty, !installed(list).contains(cli.id) else { return nil }
        return "\(cli.id) is not installed on this Mac" + (cli.install.map { " · get it: \($0)" } ?? "")
    }

    /// The ids of the ones installed on this Mac. Commands are looked up in the user's login shell, since an
    /// app opened from Finder has a bare PATH without ~/.local/bin, npm's folder or Homebrew; this blocks for
    /// as long as that shell takes to start, so callers run it off the main thread.
    static func installed(_ list: [CLI] = all()) -> Set<String> {
        let fm = FileManager.default
        let commands = Set(list.flatMap(\.detect).filter { !$0.hasPrefix("/") && !$0.hasPrefix("~") })
        var found = Set<String>()
        if !commands.isEmpty {
            let script = commands.sorted().map { "command -v \(VM.shellQuoted($0)) >/dev/null 2>&1 && echo \(VM.shellQuoted($0))" }
                .joined(separator: "; ")
            let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: shell)
            p.arguments = [AgentRun.plainShell ? "-c" : "-lc", script + "; true"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            if (try? p.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                found = Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
            }
        }
        return Set(list.filter { cli in
            cli.detect.isEmpty || cli.detect.contains { d in
                d.hasPrefix("/") || d.hasPrefix("~") ? fm.fileExists(atPath: (d as NSString).expandingTildeInPath) : found.contains(d)
            }
        }.map(\.id))
    }

    /// The command line that opens `folder` in an editor.
    static func editorArgv(_ cli: CLI, folder: URL) -> [String] {
        cli.editor.map { $0.replacingOccurrences(of: "{folder}", with: folder.path) }
    }

    /// The first one listed.
    static var defaultID: String { agents().first?.id ?? "" }

    /// The agent for a run with nobody there to pick: the one a file names if it is installed or is not ours to
    /// judge (not listed), else the first installed. Any agent will do, so a missing one never stops a run.
    static func pick(_ wanted: String?, agents list: [CLI], installed: Set<String>) -> String {
        if let wanted, !wanted.isEmpty, installed.contains(wanted) || !list.contains(where: { $0.id == wanted }) { return wanted }
        return list.first { !$0.shell && installed.contains($0.id) }?.id ?? wanted ?? list.first?.id ?? ""
    }

    static func runnable(_ wanted: String? = nil) -> String {
        let list = agents()
        return pick(find(wanted ?? "", in: list)?.id ?? wanted, agents: list, installed: installed(list))
    }

    static func find(_ name: String, in list: [CLI] = all()) -> CLI? {
        let n = name.lowercased()
        return list.first { $0.id == n || $0.aliases.contains(n) }
    }

    static func label(_ id: String) -> String { find(id)?.label ?? id }

    /// The command line for one prompt; an agent not listed is run as `<name> <prompt>`.
    static func argv(_ name: String, _ prompt: String, in list: [CLI] = all()) -> [String] {
        guard let cli = find(name, in: list), !cli.run.isEmpty else { return [name, prompt] }
        return cli.run.map { $0.replacingOccurrences(of: "{prompt}", with: prompt) }
    }
}
