import Foundation

/// The clone apprentice runs from: install.sh makes it a fork of the upstream repo (or the
/// upstream itself for its owner). Fixes made while using the tool become small commits here,
/// `update` brings in upstream and rebuilds, and `pr` sends the local commits upstream.
enum Repo {
    static var root: URL { Notes.repo }
    static var isGit: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) }
    /// Forks have an `upstream` remote (gh adds it on clone); the owner's clone pushes to origin.
    static var upstream: String { git("remote").out.split(separator: "\n").contains("upstream") ? "upstream" : "origin" }

    @discardableResult
    static func run(_ tool: String, _ args: [String], in dir: URL? = nil) -> (code: Int32, out: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [tool] + args
        proc.currentDirectoryURL = dir ?? root
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return (127, "\(tool) is not installed") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    static func git(_ args: String...) -> (code: Int32, out: String) { run("git", args) }

    /// Commits `paths` (everything when empty) as one small commit. Quiet when there is nothing
    /// to commit or the notes are not in a git clone; returns the short hash otherwise.
    @discardableResult
    static func commit(_ message: String, paths: [String] = []) -> String? {
        guard isGit else { return nil }
        run("git", ["add", "-A", "--"] + (paths.isEmpty ? ["."] : paths))
        guard git("diff", "--cached", "--quiet").code != 0 else { return nil }
        guard git("commit", "-q", "-m", message).code == 0 else { return nil }
        return git("rev-parse", "--short", "HEAD").out
    }

    /// `commit "what and why"`: one small commit of everything changed. A change to the source
    /// rebuilds and restarts apprentice, so the fix is live for the next command.
    static func commitCommand(_ a: Args) throws -> String {
        let message = a.pos.joined(separator: " ")
        guard !message.isEmpty else { throw Fail(5, "commit \"what changed and why\"") }
        guard isGit else { throw Fail(5, "\(root.path) is not a git clone: reinstall with install.sh") }
        let before = git("rev-parse", "HEAD").out
        guard let hash = commit(message) else { return "nothing to commit" }
        var out = "committed \(hash) \(message)"
        if touchesSource(since: before) { out += "\n" + (try rebuild()) }
        return out
    }

    /// `update`: rebases the local commits onto upstream, pushes them to the fork, and rebuilds
    /// when the source changed.
    static func update(_ a: Args) throws -> String {
        guard isGit else { throw Fail(5, "\(root.path) is not a git clone: reinstall with install.sh") }
        try requireClean()
        let remote = upstream
        guard git("fetch", "-q", remote).code == 0 else { throw Fail(5, "could not fetch \(remote): check `gh auth status`") }
        let before = git("rev-parse", "HEAD").out
        let rebase = git("rebase", "-q", "\(remote)/main")
        if rebase.code != 0 {
            git("rebase", "--abort")
            throw Fail(5, "your commits conflict with upstream; nothing changed. Resolve by hand in \(root.path): git rebase \(remote)/main\n\(rebase.out)")
        }
        var out = before == git("rev-parse", "HEAD").out ? "already up to date" : "updated to \(git("log", "-1", "--format=%h %s").out)"
        if remote == "upstream" { push(branch: "main") }
        if touchesSource(since: before) || a.has("build") { out += "\n" + (try rebuild()) }
        return out
    }

    /// `pr ["title"]`: pushes the local commits to a branch of the fork and opens (or updates)
    /// a pull request upstream.
    static func pr(_ a: Args) throws -> String {
        guard isGit else { throw Fail(5, "\(root.path) is not a git clone: reinstall with install.sh") }
        try requireClean()
        let remote = upstream
        git("fetch", "-q", remote)
        let commits = git("log", "--reverse", "--format=- %s", "\(remote)/main..HEAD").out
        guard !commits.isEmpty else { return "no local commits to send" }
        let host = Host.current().localizedName.map(Notes.slugify) ?? "mac"
        let branch = "apprentice/\(host.isEmpty ? "mac" : host)"
        guard push(branch: branch) else { throw Fail(5, "could not push \(branch) to origin") }
        let target = slug(remote)
        let head = remote == "upstream" ? "\(slug("origin").split(separator: "/").first ?? ""):\(branch)" : branch
        let existing = run("gh", ["pr", "view", head, "--repo", target, "--json", "url", "-q", ".url"])
        if existing.code == 0, !existing.out.isEmpty { return "updated \(existing.out)\n\(commits)" }
        let count = commits.split(separator: "\n").count
        let title = a.pos.isEmpty ? (count == 1 ? String(commits.dropFirst(2)) : "Fixes and notes from \(host) (\(count) commits)") : a.pos.joined(separator: " ")
        let body = "Small commits made by apprentice while it was used:\n\n\(commits)\n"
        let made = run("gh", ["pr", "create", "--repo", target, "--base", "main", "--head", head, "--title", title, "--body", body])
        guard made.code == 0 else { throw Fail(5, "gh pr create failed: \(made.out)") }
        return made.out.split(separator: "\n").last.map(String.init) ?? made.out
    }

    /// The line `session` prints when upstream has commits this clone lacks. Fetches in the
    /// background at most once a day, so the check itself stays instant.
    static func updateLine() -> String? {
        guard isGit else { return nil }
        let remote = upstream
        let fetched = root.appendingPathComponent(".git/FETCH_HEAD")
        let age = (try? fetched.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if age.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true { fetchInBackground(remote) }
        guard let behind = Int(git("rev-list", "--count", "HEAD..\(remote)/main").out), behind > 0 else { return nil }
        return "apprentice: \(behind) new upstream commit\(behind == 1 ? "" : "s"); tell Robert, who runs `apprentice update`"
    }

    private static var fetcher: Process?

    private static func fetchInBackground(_ remote: String) {
        guard fetcher?.isRunning != true else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git", "fetch", "-q", remote]
        proc.currentDirectoryURL = root
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        fetcher = proc
    }

    private static func requireClean() throws {
        let dirty = git("status", "--porcelain").out
        guard dirty.isEmpty else { throw Fail(5, "uncommitted changes in \(root.path); commit each with `apprentice commit \"…\"` first:\n\(dirty)") }
    }

    private static func touchesSource(since rev: String) -> Bool {
        !git("diff", "--name-only", rev, "HEAD", "--", "Sources", "Package.swift").out.isEmpty
    }

    @discardableResult
    private static func push(branch: String) -> Bool {
        git("push", "-q", "--force-with-lease", "origin", "HEAD:refs/heads/\(branch)").code == 0
    }

    /// owner/name of a GitHub remote.
    private static func slug(_ remote: String) -> String {
        var url = git("remote", "get-url", remote).out
        if url.hasSuffix(".git") { url.removeLast(4) }
        let parts = url.replacingOccurrences(of: ":", with: "/").split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }

    /// Runs kit.sh, which builds, signs and swaps the binary in place, then stops the daemon so
    /// the next command starts the new one.
    private static func rebuild() throws -> String {
        let built = run("bash", [root.appendingPathComponent("kit.sh").path])
        guard built.code == 0 else { throw Fail(5, "the build failed; the commit stays, fix it and commit again:\n\(built.out.split(separator: "\n").suffix(15).joined(separator: "\n"))") }
        _ = Wire.stopDaemon()
        return "rebuilt and restarted apprentice"
    }
}
