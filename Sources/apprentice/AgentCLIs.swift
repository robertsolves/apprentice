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
            let open = v["open"].map(Toml.unquote) ?? id
            return CLI(id: id, label: v["label"].map(Toml.unquote) ?? id, open: open.isEmpty ? nil : open,
                       run: v["run"].flatMap(Toml.array) ?? [], aliases: (v["aliases"].flatMap(Toml.array) ?? []).map { $0.lowercased() },
                       shell: v["shell"].map(Toml.unquote) == "true")
        }
    }

    /// The first one listed.
    static var defaultID: String { all().first?.id ?? "" }

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
