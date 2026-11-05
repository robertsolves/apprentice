import Foundation

/// A merge that needs a person: where to resolve it, and what git said.
struct MergeConflict: Error {
    var folder: URL
    var detail: String
}

/// Parallel steps: each starts in its own git worktree under the run's cache folder, on a branch from a temporary
/// commit of the tree it forked from, so uncommitted work is in them and that tree stays untouched. At the join the
/// branches merge into a third worktree, and the difference is applied to the folder they forked from, so the user's
/// own commits and uncommitted changes stay theirs: nothing is committed to their branch.
extension PipelineEngine {
    private var gitIdentity: [String: String] {
        ["GIT_AUTHOR_NAME": "apprentice", "GIT_AUTHOR_EMAIL": "apprentice@localhost", "GIT_COMMITTER_NAME": "apprentice", "GIT_COMMITTER_EMAIL": "apprentice@localhost"]
    }

    private func git(_ args: [String], in folder: URL, env: [String: String] = [:]) -> (code: Int32, out: String) {
        Repo.run("git", args, in: folder, env: gitIdentity.merging(env) { $1 })
    }

    /// The repo's top; a folder that is not in one gets its own, since a worktree needs a repo.
    private func repoRoot() throws -> URL {
        var r = git(["rev-parse", "--show-toplevel"], in: cwd)
        if r.code != 0 {
            // Only a project's own folder: outside one this could be the home folder, and the next step adds all of it.
            guard project != nil else { throw Fail(5, "parallel steps need a project, or a folder that is already a git repo") }
            guard git(["init", "-q"], in: cwd).code == 0 else { throw Fail(5, "this folder is not a git repo and git init failed") }
            r = git(["rev-parse", "--show-toplevel"], in: cwd)
        }
        return URL(fileURLWithPath: r.out)
    }

    private func folder(of ws: String) -> URL {
        guard ws != "root", let w = state.workspaces.first(where: { $0.id == ws }) else { return cwd }
        return URL(fileURLWithPath: w.path)
    }

    /// A commit of a folder as it stands, honouring its ignore files, without touching its index or files.
    private func snapshot(_ folder: URL) throws -> String {
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("apprentice-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let env = ["GIT_INDEX_FILE": index.path]
        let top = git(["rev-parse", "--show-toplevel"], in: folder).out
        let at = top.isEmpty ? folder : URL(fileURLWithPath: top)
        _ = git(["read-tree", "HEAD"], in: at, env: env)
        let added = git(["add", "-A"], in: at, env: env)
        guard added.code == 0 else { throw Fail(5, "git add failed: \(added.out)") }
        let tree = git(["write-tree"], in: at, env: env)
        guard tree.code == 0 else { throw Fail(5, "git write-tree failed: \(tree.out)") }
        let head = git(["rev-parse", "--verify", "-q", "HEAD"], in: at)
        let parents = head.code == 0 ? ["-p", head.out] : []
        let commit = git(["commit-tree", tree.out] + parents + ["-m", "apprentice: the tree at a pipeline's fork"], in: at)
        guard commit.code == 0 else { throw Fail(5, "git commit-tree failed: \(commit.out)") }
        return commit.out
    }

    /// `.apprentice/worktree-links`: ignored files a new worktree needs. A folder is linked, a file copied.
    private func linkIgnored(into worktree: URL) -> [String] {
        let list = (project ?? cwd).appendingPathComponent(".apprentice/worktree-links")
        let lines = ((try? String(contentsOf: list, encoding: .utf8)) ?? ProjectFiles.worktreeLinksTemplate).components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        var made: [String] = []
        let fm = FileManager.default
        for pattern in lines {
            guard !pattern.contains(".."), !pattern.hasPrefix("/") else { continue }
            for source in AgentRun.globbed(cwd.appendingPathComponent(pattern).path) {
                let rel = String(source.dropFirst(cwd.path.count + 1))
                let target = worktree.appendingPathComponent(rel)
                guard !fm.fileExists(atPath: target.path) else { continue }
                try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: source, isDirectory: &isDir)
                if isDir.boolValue { try? fm.createSymbolicLink(atPath: target.path, withDestinationPath: source) }
                else { try? fm.copyItem(atPath: source, toPath: target.path) }
                made.append(rel)
            }
        }
        return made
    }

    /// Starts one worktree per target, returning each target's workspace id.
    func fork(_ targets: [String], from parent: String, at id: String) throws -> [(String, String)] {
        gitLock.lock()
        defer { gitLock.unlock() }
        let root = try repoRoot()
        let base = try snapshot(folder(of: parent))
        let groupID = "\(id)-\(state.steps[id]?.visits ?? 1)"
        var made: [RunState.Workspace] = []
        var pairs: [(String, String)] = []
        for t in targets {
            let wsID = "\(t)-\(groupID)"
            let path = dir.appendingPathComponent("worktrees/\(wsID)")
            let branch = "apprentice/run-\(state.run)/\(wsID)"
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let added = git(["worktree", "add", "-q", "-b", branch, path.path, base], in: root)
            guard added.code == 0 else { throw Fail(5, "git worktree add failed: \(added.out)") }
            let links = linkIgnored(into: path)
            try? links.joined(separator: "\n").write(to: linkRecord(wsID), atomically: true, encoding: .utf8)
            made.append(RunState.Workspace(id: wsID, path: path.path, branch: branch, group: groupID, parent: parent))
            pairs.append((t, wsID))
        }
        let group = RunState.Group(id: groupID, targets: targets, base: base, applied: base, parent: parent)
        updateState { s in
            s.workspaces += made
            s.groups.append(group)
        }
        return pairs
    }

    private func linkRecord(_ ws: String) -> URL { dir.appendingPathComponent("worktrees/\(ws).links") }

    /// What a parallel step did goes in a commit on its own branch; a sequential step's stays in the user's folder.
    func commitWorkspace(_ ws: String, message: String) throws {
        guard ws != "root", let w = state.workspaces.first(where: { $0.id == ws }), !w.merged else { return }
        let path = URL(fileURLWithPath: w.path)
        let links = ((try? String(contentsOf: linkRecord(ws), encoding: .utf8)) ?? "").split(separator: "\n").map { ":(exclude)\($0)" }
        _ = git(["add", "-A", "--", "."] + links, in: path)
        guard git(["diff", "--cached", "--quiet"], in: path).code != 0 else { return }
        let r = git(["commit", "-q", "-m", "apprentice: \(message)"], in: path)
        guard r.code == 0 else { throw Fail(5, "commit failed: \(r.out)") }
    }

    /// Which folder a step works in: the branch it came along, or, at a join, the parent, with the branches merged.
    func workspaceFor(_ id: String) throws -> URL {
        var arrivals = state.steps[id]?.arrivals ?? ["root"]
        if arrivals.isEmpty { arrivals = ["root"] }
        while true {
            let worktrees = arrivals.filter { $0 != "root" }
            if worktrees.isEmpty { break }
            if arrivals.count == 1, let only = worktrees.first, !isJoin(id, only) {
                updateStep(id) { $0.workspace = only }
                return folder(of: only)
            }
            // Deepest first: a nested fork's branches come home before their parent does.
            var next = Set(arrivals.filter { $0 == "root" })
            for w in worktrees {
                try mergeUp(w)
                next.insert(state.workspaces.first { $0.id == w }?.parent ?? "root")
            }
            arrivals = Array(next)
            updateStep(id) { $0.arrivals = arrivals }
        }
        updateStep(id) { $0.workspace = nil }
        return cwd
    }

    /// Two or more branches of its fork can reach this step, so here they come back together.
    private func isJoin(_ id: String, _ ws: String) -> Bool {
        guard let w = state.workspaces.first(where: { $0.id == ws }), let g = state.groups.first(where: { $0.id == w.group }) else { return false }
        return g.targets.filter { $0 == id || graph.ahead($0).contains(id) }.count >= 2
    }

    /// Commits a branch, merges it into its group's merge worktree, applies what is new to the parent folder, and
    /// removes the branch's worktree. Throws `MergeConflict`, leaving the conflict in place for a person.
    func mergeUp(_ ws: String) throws {
        gitLock.lock()
        defer { gitLock.unlock() }
        guard ws != "root", let w = state.workspaces.first(where: { $0.id == ws }) else { return }
        guard let g = state.groups.first(where: { $0.id == w.group }) else { return }
        let root = try repoRoot()
        var mergePath = g.mergePath.map { URL(fileURLWithPath: $0) }
        if mergePath == nil {
            let path = dir.appendingPathComponent("worktrees/merge-\(g.id)")
            let branch = "apprentice/run-\(state.run)/merge-\(g.id)"
            let added = git(["worktree", "add", "-q", "-b", branch, path.path, g.base], in: root)
            guard added.code == 0 else { throw Fail(5, "git worktree add failed: \(added.out)") }
            updateState { s in
                if let i = s.groups.firstIndex(where: { $0.id == g.id }) { s.groups[i].mergePath = path.path; s.groups[i].mergeBranch = branch }
            }
            mergePath = path
        }
        guard let merge = mergePath else { return }
        // A conflict left for the user: once it is resolved the merge is finished here.
        if FileManager.default.fileExists(atPath: gitDir(merge).appendingPathComponent("MERGE_HEAD").path) {
            stageResolved(in: merge)
            let left = git(["diff", "--name-only", "--diff-filter=U"], in: merge)
            guard left.out.isEmpty else { throw MergeConflict(folder: merge, detail: "still conflicted:\n\(left.out)") }
            _ = git(["add", "-A"], in: merge)
            let done = git(["commit", "-q", "--no-edit"], in: merge)
            guard done.code == 0 else { throw MergeConflict(folder: merge, detail: done.out) }
        }
        if !w.merged {
            try commitWorkspace(ws, message: "the end of a parallel step")
            let merged = git(["merge", "-q", "--no-ff", "--no-edit", "-m", "apprentice: merge \(ws)", w.branch], in: merge)
            if merged.code != 0 {
                let conflicted = git(["diff", "--name-only", "--diff-filter=U"], in: merge)
                throw MergeConflict(folder: merge, detail: conflicted.out.isEmpty ? merged.out : "conflicted:\n\(conflicted.out)")
            }
            // The folder's name must still resolve to find what a CLI keeps for it, so that goes first.
            if PipelineSettings.keepSessionDays(project) <= 0 { forgetFolderForAllCLIs(URL(fileURLWithPath: w.path)) }
            _ = git(["worktree", "remove", "--force", w.path], in: root)
            _ = git(["branch", "-q", "-D", w.branch], in: root)
            updateState { s in if let i = s.workspaces.firstIndex(where: { $0.id == ws }) { s.workspaces[i].merged = true } }
        }
        try applyMerged(g.id)
    }

    /// A person who fixed a conflict in an editor and did not `git add` it has still resolved it: no markers left is enough.
    private func stageResolved(in folder: URL) {
        for name in git(["diff", "--name-only", "--diff-filter=U"], in: folder).out.split(separator: "\n").map(String.init) {
            let text = (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? "<<<<<<<"
            if !text.contains("<<<<<<<") { _ = git(["add", "--", name], in: folder) }
        }
    }

    private func gitDir(_ folder: URL) -> URL {
        let r = git(["rev-parse", "--absolute-git-dir"], in: folder)
        return URL(fileURLWithPath: r.out)
    }

    private func forgetFolderForAllCLIs(_ folder: URL) {
        for cli in AgentCLIs.agents() where cli.projectDir != nil { AgentRun.forgetFolder(cli: cli, cwd: folder) }
    }

    /// Applies what the merge worktree has that the parent folder has not had yet, then cleans up once every branch
    /// of the group is home. What does not apply is left where a person can resolve it and is counted as applied, so
    /// the next branch brings only its own work and nothing is applied twice: conflict markers where git can merge,
    /// else a `.rej` beside the file, with everything else landed.
    private func applyMerged(_ groupID: String) throws {
        guard let g = state.groups.first(where: { $0.id == groupID }), let path = g.mergePath, !g.done else { return }
        let merge = URL(fileURLWithPath: path)
        let parent = folder(of: g.parent)
        let top = git(["rev-parse", "--show-toplevel"], in: parent).out
        let at = top.isEmpty ? parent : URL(fileURLWithPath: top)
        func change(_ edit: (inout RunState.Group) -> Void) {
            updateState { s in if let i = s.groups.firstIndex(where: { $0.id == groupID }) { edit(&s.groups[i]) } }
        }
        if g.conflictAt != nil, g.conflictResolved == true {
            // The user said it is resolved, and their folder is now the result.
            stageResolved(in: at)
            let left = git(["diff", "--name-only", "--diff-filter=U"], in: at)
            guard left.out.isEmpty else {
                change { $0.conflictResolved = false }
                throw MergeConflict(folder: at, detail: "still conflicted:\n\(left.out)")
            }
            for name in g.rejects ?? [] { try? FileManager.default.removeItem(at: at.appendingPathComponent(name)) }
            change { $0.conflictAt = nil; $0.conflictResolved = nil; $0.rejects = nil }
        }
        let head = git(["rev-parse", "HEAD"], in: merge).out
        if head != g.applied {
            let patch = dir.appendingPathComponent("worktrees/\(groupID)-\(String(head.prefix(8))).patch")
            let diff = Repo.run("git", ["diff", "--binary", g.applied, head, "--output=\(patch.path)"], in: merge)
            guard diff.code == 0 else { throw Fail(5, "git diff failed: \(diff.out)") }
            if ((try? Data(contentsOf: patch))?.isEmpty ?? true) == false {
                var r = git(["apply", "--whitespace=nowarn", patch.path], in: at)
                if r.code != 0 { r = git(["apply", "--3way", "--whitespace=nowarn", patch.path], in: at) }
                if r.code != 0 {
                    // `--3way` refuses outright over a file with unstaged changes: then each hunk that fits goes in.
                    var rejects: [String] = []
                    if git(["diff", "--name-only", "--diff-filter=U"], in: at).out.isEmpty {
                        let names = git(["apply", "--numstat", patch.path], in: at).out.split(separator: "\n").compactMap { $0.split(separator: "\t").last.map(String.init) }
                        r = git(["apply", "--reject", "--whitespace=nowarn", patch.path], in: at)
                        rejects = names.map { $0 + ".rej" }.filter { FileManager.default.fileExists(atPath: at.appendingPathComponent($0).path) }
                    }
                    change { $0.applied = head; $0.conflictAt = head; $0.conflictResolved = nil; $0.rejects = (($0.rejects ?? []) + rejects) }
                    let how = rejects.isEmpty ? "The conflicts are marked in the files." : "What did not fit is in \(rejects.joined(separator: ", ")), beside the files."
                    throw MergeConflict(folder: at, detail: "some of the merged work does not fit this folder, which changed since the fork. \(how)\n\(r.out)")
                }
            }
            change { $0.applied = head }
        }
        // While a conflict waits, the folder it is in is still needed.
        guard state.groups.first(where: { $0.id == groupID })?.conflictAt == nil else { return }
        let home = state.workspaces.filter { $0.group == groupID }.allSatisfy(\.merged)
        guard home else { return }
        let root = try repoRoot()
        _ = git(["worktree", "remove", "--force", path], in: root)
        if let branch = g.mergeBranch { _ = git(["branch", "-q", "-D", branch], in: root) }
        change { $0.done = true }
    }
}
