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

        var isEditor: Bool { !editor.isEmpty }
    }

    static var files: [URL] {
        [Repo.resources.appendingPathComponent("agent/agents.toml"), Settings.dir.appendingPathComponent("agents.toml")]
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
            return CLI(id: id, label: v["label"].map(Toml.unquote) ?? id, open: open.isEmpty ? nil : open,
                       run: v["run"].flatMap(Toml.array) ?? [], aliases: (v["aliases"].flatMap(Toml.array) ?? []).map { $0.lowercased() },
                       shell: shell, detect: detect, install: v["install"].map(Toml.unquote).flatMap { $0.isEmpty ? nil : $0 },
                       editor: editor)
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
            p.arguments = ["-lc", script + "; true"]
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
