import Foundation

/// Keeps a pipeline's traces from piling up. Every headless step is a new session for its CLI, and the CLI keeps a
/// transcript of it. Apprentice removes only the sessions it started, by the ids in each step's `result.json`, and
/// never the user's own; `--report` shows each CLI's total and its own way to clear them, without deleting any.
enum Tidy {
    static func short(_ text: String) -> String { String(ProjectFiles.hash(text).prefix(8)) }

    private static var stamp: URL { Store.dir.appendingPathComponent("tidy.stamp") }

    /// Once a day, beside the log prune; called by the daemon.
    static func daily() {
        let at = (try? stamp.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        guard Date().timeIntervalSince(at) > 23 * 3600 else { return }
        FileManager.default.createFile(atPath: stamp.path, contents: nil)
        DispatchQueue.global(qos: .utility).async { _ = run() }
    }

    /// Every cache apprentice keeps: each listed project's, and its own for pipelines outside a project.
    private static var places: [URL?] { Projects.all().map { Optional($0.folder) } + [nil] }

    private static func size(_ url: URL) -> Int64 {
        let r = Repo.run("/usr/bin/du", ["-sk", url.path])
        guard r.code == 0, let kb = r.out.split(whereSeparator: \.isWhitespace).first.flatMap({ Int64($0) }) else { return 0 }
        return kb * 1024
    }

    static func human(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Removes leftover sessions and expired runs. A run that may still be resumed keeps its worktrees.
    @discardableResult
    static func run(now: Date = Date()) -> String {
        var sessions = 0
        var runs = 0
        var freed: Int64 = 0
        for project in places {
            let keepSessions = PipelineSettings.keepSessionDays(project) * 86400
            let keepOutputs = PipelineSettings.keepOutputDays(project) * 86400
            for (dir, state) in Runs.all(project: project) {
                // Sessions left by a step that crashed before cleanup, or kept by [pipelines] keep_sessions_days.
                let nodes = (try? FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("nodes"), includingPropertiesForKeys: nil)) ?? []
                for node in nodes {
                    let file = node.appendingPathComponent("result.json")
                    guard var result = (try? Data(contentsOf: file)).flatMap({ try? JSONDecoder().decode(StepResult.self, from: $0) }) else { continue }
                    guard now.timeIntervalSince1970 - result.at >= keepSessions, !Runs.alive(state.pid) else { continue }
                    var changed = false
                    for i in result.tries.indices where !result.tries[i].sessionRemoved {
                        if let id = result.tries[i].session {
                            let cwd = URL(fileURLWithPath: result.tries[i].cwd)
                            if !AgentRun.forget(cli: AgentCLIs.find(result.tries[i].cli), session: id, cwd: cwd).isEmpty { sessions += 1 }
                        }
                        result.tries[i].sessionRemoved = true
                        changed = true
                    }
                    if changed { try? Wire.json(result).write(to: file, options: .atomic) }
                }
                guard let finished = state.finished, now.timeIntervalSince1970 - finished >= keepOutputs, ["done", "failed", "stopped"].contains(state.status) else { continue }
                freed += size(dir)
                removeWorktrees(of: state, dir: dir)
                try? FileManager.default.removeItem(at: dir)
                runs += 1
            }
        }
        var out = ["\(sessions) leftover session\(sessions == 1 ? "" : "s") removed", "\(runs) expired run\(runs == 1 ? "" : "s") removed (\(human(freed)))"]
        out.append("past-run notes stay")
        return out.joined(separator: " · ")
    }

    private static func removeWorktrees(of state: RunState, dir: URL) {
        let folder = state.project.map { URL(fileURLWithPath: $0) } ?? Store.dir
        for w in state.workspaces where !w.merged {
            _ = Repo.run("git", ["worktree", "remove", "--force", w.path], in: folder)
            _ = Repo.run("git", ["branch", "-q", "-D", w.branch], in: folder)
            for cli in AgentCLIs.agents() where cli.projectDir != nil { AgentRun.forgetFolder(cli: cli, cwd: URL(fileURLWithPath: w.path)) }
        }
        for g in state.groups where !g.done {
            if let path = g.mergePath { _ = Repo.run("git", ["worktree", "remove", "--force", path], in: folder) }
            if let branch = g.mergeBranch { _ = Repo.run("git", ["branch", "-q", "-D", branch], in: folder) }
        }
        _ = Repo.run("git", ["worktree", "prune"], in: folder)
    }

    /// What each CLI keeps, and what apprentice's caches hold. Deletes nothing.
    static func report() -> String {
        var out: [String] = ["The CLIs' own sessions (yours: apprentice removes only the ones it started):"]
        for cli in AgentCLIs.agents() {
            guard let root = cli.sessionsRoot else { continue }
            let url = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            out.append("  \(cli.label) · \(human(size(url))) · \(root)" + (cli.clearHint.map { " · \($0)" } ?? ""))
        }
        out.append("apprentice's pipeline caches:")
        var any = false
        for project in places {
            let cache = Runs.cache(project: project)
            guard FileManager.default.fileExists(atPath: cache.path) else { continue }
            any = true
            let notes = Runs.cache(project: project).appendingPathComponent("past")
            out.append("  \(project.map { Projects.info($0)?.name ?? $0.lastPathComponent } ?? "outside a project") · \(human(size(cache))) · \(Runs.numbers(project: project).count) runs, \(human(size(notes))) of notes")
        }
        if !any { out.append("  none yet") }
        out.append("kept: run output \(Int(PipelineSettings.keepOutputDays(nil))) days ([pipelines] keep_outputs_days), CLI sessions \(Int(PipelineSettings.keepSessionDays(nil))) days ([pipelines] keep_sessions_days), notes for good")
        return out.joined(separator: "\n")
    }

    static func command(_ a: Args) -> String {
        a.has("report") ? run() + "\n" + report() : run()
    }
}
