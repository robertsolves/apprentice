import Darwin
import Foundation

/// Which coding agent runs apprentice, and on which model, so every log row and learned flow names it
/// without anyone setting `APPRENTICE_MODEL`. The model when it can be found, else the agent's name.
/// Order: `APPRENTICE_MODEL`; the agent's own signals (environment, its session transcript, its config);
/// then the names of the processes above this one.
enum Agent {
    static let detected: String? = {
        let env = ProcessInfo.processInfo.environment
        if let m = env["APPRENTICE_MODEL"], !m.isEmpty { return m }
        guard let agent = name(env) else { return nil }
        return model(agent, env) ?? agent
    }()

    /// The agent's name: claude-code, codex, gemini, opencode, cursor, …
    static func name(_ env: [String: String]) -> String? {
        if env["CLAUDECODE"] != nil || env["CLAUDE_CODE_ENTRYPOINT"] != nil { return "claude-code" }
        if env["GEMINI_CLI"] != nil { return "gemini" }
        if env["OPENCODE"] != nil { return "opencode" }
        if env["CODEX_SANDBOX"] != nil || env["CODEX_THREAD_ID"] != nil { return "codex" }
        if env["CURSOR_AGENT"] != nil { return "cursor" }
        // A convention some agents follow: AI_AGENT=claude-code_2-1-308_agent.
        if let a = env["AI_AGENT"], let first = a.split(separator: "_").first, !first.isEmpty { return String(first) }
        let known = ["claude", "codex", "opencode", "gemini", "kilo", "cursor-agent", "droid", "amp", "qwen", "copilot",
                     "goose", "crush", "vibe", "auggie", "freebuff", "codebuff", "cline", "aider"]
        for process in ancestors() {
            if let hit = known.first(where: { process == $0 }) { return hit == "claude" ? "claude-code" : hit }
        }
        return nil
    }

    static func model(_ agent: String, _ env: [String: String]) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch agent {
        case "claude-code":
            // The session's own transcript names the model of every reply, including after /model.
            if let id = env["CLAUDE_CODE_SESSION_ID"], let m = claudeTranscriptModel(id, home: home) { return m }
            if let m = env["ANTHROPIC_MODEL"], !m.isEmpty { return m }
            return jsonString(home + "/.claude/settings.json", ["model"])
        case "codex":
            return tomlString((env["CODEX_HOME"] ?? home + "/.codex") + "/config.toml", "model")
        case "gemini":
            return env["GEMINI_MODEL"] ?? jsonString(home + "/.gemini/settings.json", ["model", "name"])
        case "opencode":
            return jsonString(home + "/.config/opencode/opencode.json", ["model"])
        case "qwen":
            return env["OPENAI_MODEL"] ?? jsonString(home + "/.qwen/settings.json", ["model", "name"])
        default:
            return nil
        }
    }

    /// The last model named in the end of `~/.claude/projects/*/<session>.jsonl`.
    static func claudeTranscriptModel(_ session: String, home: String) -> String? {
        let projects = home + "/.claude/projects"
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: projects),
              let path = dirs.lazy.map({ "\(projects)/\($0)/\(session).jsonl" }).first(where: fm.fileExists),
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        return lastModel(in: tail)
    }

    /// The last `"model":"…"` in a transcript, skipping placeholders such as `<synthetic>`.
    static func lastModel(in text: String) -> String? {
        var found: String?
        var rest = text[...]
        while let r = rest.range(of: "\"model\":\"") {
            let value = rest[r.upperBound...].prefix { $0 != "\"" }
            if !value.isEmpty, !value.hasPrefix("<") { found = String(value) }
            rest = rest[r.upperBound...]
        }
        return found
    }

    private static func jsonString(_ path: String, _ keys: [String]) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              var node = try? JSONSerialization.jsonObject(with: data) else { return nil }
        for k in keys {
            guard let next = (node as? [String: Any])?[k] else { return nil }
            node = next
        }
        return (node as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func tomlString(_ path: String, _ key: String) -> String? {
        // Top-level keys only: the part before the first [section].
        let top = Toml.load(URL(fileURLWithPath: path))[""] ?? [:]
        return top[key].map(Toml.unquote).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Executable names of the processes above this one, nearest first.
    static func ancestors() -> [String] {
        var names: [String] = []
        var pid = getppid()
        for _ in 0..<12 where pid > 1 {
            var path = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
                names.append(URL(fileURLWithPath: String(cString: path)).lastPathComponent.lowercased())
            }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { break }
            pid = pid_t(info.pbi_ppid)
        }
        return names
    }
}
