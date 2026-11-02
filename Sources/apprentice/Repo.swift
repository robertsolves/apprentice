import Foundation

/// The clone apprentice runs from. It is the user's own copy: fixes made while using the tool become
/// small commits here and stay here. `upstream` (any git URL: a server, a folder, another Mac's clone) is
/// only fetched. apprentice checks it every few hours and, unless `[update] auto = false`, rebases the
/// local commits onto it, rebuilds, self-tests and restarts on its own.
enum Repo {
    /// The clone kit.sh last installed from (`install.json`), else the one the notes link into.
    static var root: URL {
        if let testRoot { return testRoot }
        if ProcessInfo.processInfo.environment["APPRENTICE_NOTES"] == nil, let clone = Build.install?.clone,
           FileManager.default.fileExists(atPath: clone + "/.git") {
            return URL(fileURLWithPath: clone)
        }
        return Notes.repo
    }
    /// For `selftest`: a throwaway clone, and a build that stands in for kit.sh.
    static var testRoot: URL?
    static var testBuild: (() -> (code: Int32, out: String))?
    static var isGit: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) }
    /// install.sh names it `upstream`; an older plain clone only has origin.
    static var upstream: String { git("remote").out.split(separator: "\n").contains("upstream") ? "upstream" : "origin" }

    /// The upstream's default branch, as the clone recorded it; "main" when it never did.
    static func branch(_ remote: String) -> String {
        let head = git("symbolic-ref", "--short", "refs/remotes/\(remote)/HEAD")
        guard head.code == 0, let name = head.out.split(separator: "/", maxSplits: 1).last, !name.isEmpty else { return "main" }
        return String(name)
    }

    static var settings: [String: String] { Toml.load(Config.path)["update"] ?? [:] }
    /// On unless the user sets `[update] auto = false`; then `session` only says an update is waiting.
    static var auto: Bool { settings["auto"].map(Toml.unquote) != "false" }

    /// The daemon runs what it pulls, so it updates itself only from an https or ssh remote; a folder,
    /// `file://`, `git://` or `http://` upstream is brought in by hand with `update`.
    static var trusted: Bool {
        if testRoot != nil { return true }
        let url = git("remote", "get-url", upstream).out
        return url.hasPrefix("https://") || url.hasPrefix("ssh://") || (url.hasPrefix("git@") && url.contains(":"))
    }
    static var checkSeconds: Double { max(settings["check_hours"].flatMap { Double(Toml.unquote($0)) } ?? 6, 1) * 3600 }

    @discardableResult
    static func run(_ tool: String, _ args: [String], in dir: URL? = nil) -> (code: Int32, out: String) {
        let proc = quiet(Process())
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
        // Named paths commit on their own, so whatever the user has staged stays out of it (M1).
        let scope = ["--"] + (paths.isEmpty ? ["."] : paths)
        run("git", ["add", "-A"] + scope)
        guard run("git", ["diff", "--cached", "--quiet"] + scope).code != 0 else { return nil }
        guard run("git", ["commit", "-q", "-m", message] + (paths.isEmpty ? [] : scope)).code == 0 else { return nil }
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

    /// `update [--check] [--build]`: rebases the local commits onto upstream and rebuilds when the source
    /// changed. `--check` only says whether one is waiting.
    static func update(_ a: Args) throws -> String {
        guard isGit else { throw Fail(5, "\(root.path) is not a git clone: reinstall with install.sh") }
        let remote = upstream
        guard git("fetch", "-q", remote).code == 0 else { throw Fail(5, "could not fetch \(remote) (\(git("remote", "get-url", remote).out))") }
        if a.has("check") {
            let n = behind(remote)
            return n == 0 ? "up to date with \(remote)" : "\(n) new upstream commit\(n == 1 ? "" : "s"):\n" + git("log", "--format=  %h %s", "HEAD..\(remote)/\(branch(remote))").out
        }
        try requireClean()
        let before = git("rev-parse", "HEAD").out
        try rebase(remote)
        var out = before == git("rev-parse", "HEAD").out ? "already up to date" : "updated to \(git("log", "-1", "--format=%h %s").out)"
        if touchesSource(since: before) || a.has("build") { out += "\n" + (try rebuild()) }
        return out
    }

    private static func rebase(_ remote: String) throws {
        let base = branch(remote)
        let rebase = git("rebase", "-q", "\(remote)/\(base)")
        if rebase.code != 0 {
            git("rebase", "--abort")
            throw Fail(5, "your commits conflict with upstream; nothing changed. Resolve by hand in \(root.path): git rebase \(remote)/\(base)\n\(rebase.out)")
        }
    }

    static func behind(_ remote: String) -> Int {
        Int(git("rev-list", "--count", "HEAD..\(remote)/\(branch(remote))").out) ?? 0
    }

    // MARK: - telling the user, and updating on its own

    /// One line about the last automatic update, shown by the next `session` and then dropped.
    struct Notice: Codable { var text: String }

    static func notice(_ text: String) {
        Store.save(Notice(text: text), "update.json")
        Store.log(["update": text])
    }

    /// What `session` prints about updates: the last automatic update, or one that is waiting. Only the
    /// daemon starts an update (`start`); a client process would exit in the middle of it.
    static func updateLine(start: Bool = true) -> String? {
        guard isGit else { return nil }
        var lines: [String] = []
        if let n = Store.load(Notice.self, "update.json") {
            lines.append(n.text)
            Store.remove("update.json")
        }
        let remote = upstream
        let fetched = root.appendingPathComponent(".git/FETCH_HEAD")
        let age = (try? fetched.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        // Only the main daemon updates; a VM's daemon reports what it sees.
        let start = start && Store.vmName == nil
        if start, age.map({ Date().timeIntervalSince($0) > checkSeconds }) ?? true { checkInBackground() }
        let n = behind(remote)
        if n > 0, !updating {
            let commits = "\(n) new upstream commit\(n == 1 ? "" : "s")"
            if auto, trusted {
                if start { startUpdate() }
                lines.append("apprentice: updating itself in the background (\(commits))")
            } else if auto {
                lines.append("apprentice: \(commits); upstream (\(git("remote", "get-url", remote).out)) is not https or ssh, so apprentice does not update itself from it: tell the user, who runs `apprentice update`")
            } else {
                lines.append("apprentice: \(commits); auto-update is off, so tell the user, who runs `apprentice update`")
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The daemon checks upstream a minute after it starts and then every `[update] check_hours`.
    static func scheduleChecks() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: checkSeconds)
        timer.setEventHandler { checkInBackground() }
        timer.resume()
        checkTimer = timer
    }

    private static var checkTimer: DispatchSourceTimer?
    private static let lock = NSLock()
    private static var busy = false
    private static var updating: Bool { lock.lock(); defer { lock.unlock() }; return busy }

    private static func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if busy { return false }
        busy = true
        return true
    }

    private static func release() {
        lock.lock()
        busy = false
        lock.unlock()
    }

    /// Fetches off the command queue, then updates when that is on and there is something new.
    static func checkInBackground() {
        guard isGit, claim() else { return }
        DispatchQueue.global(qos: .utility).async {
            let remote = upstream
            git("fetch", "-q", remote)
            let waiting = behind(remote) > 0
            release()
            if waiting, auto, trusted { startUpdate() }
        }
    }

    private static func startUpdate() {
        guard claim() else { return }
        DispatchQueue.global(qos: .utility).async {
            let restart = applyUpdate()
            release()
            if restart { restartWhenIdle() }
        }
    }

    /// Restarts into the new build between tasks, never in one: not while a proposal waits for approval
    /// or a question is open, nor within a minute of the last command. Otherwise it looks again in a minute.
    /// The next command starts the new binary.
    static func restartWhenIdle() {
        let idle = Approvals.pending == nil && StatusItem.state != .waiting
            && Date().timeIntervalSince(Commands.lastAt) > 60
        guard idle else {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) { restartWhenIdle() }
            return
        }
        Daemon.queue.async { Wire.stopVMDaemons(); _ = Wire.stopDaemon() }
    }

    /// The automatic update: only on a clean tree on the base branch, and back to where it was if the
    /// new build or its self-test fails. Returns whether the daemon should restart.
    static func applyUpdate() -> Bool {
        let remote = upstream
        let base = branch(remote)
        guard installedHere || testRoot != nil else {
            notice("apprentice: updating is off: \(Store.dir.path)/notes no longer links into \(root.path). Run kit.sh in the clone you use")
            return false
        }
        // The session so far goes into the clone first, so its own copy never holds the update back.
        if testRoot == nil { Sessions.archiveCurrent() }
        guard git("status", "--porcelain").out.isEmpty else {
            notice("apprentice: an update is waiting, but \(root.path) has uncommitted changes; once they are committed (`apprentice commit \"…\"`) it updates itself")
            return false
        }
        guard git("branch", "--show-current").out == base else {
            notice("apprentice: an update is waiting, but \(root.path) is not on \(base); `apprentice update` there brings it in")
            return false
        }
        let before = git("rev-parse", "HEAD").out
        do { try rebase(remote) } catch {
            notice("apprentice: could not update itself, because local commits conflict with upstream; nothing changed. `apprentice update` shows where")
            return false
        }
        let to = git("log", "-1", "--format=%h %s").out
        guard touchesSource(since: before) else {
            notice("apprentice: updated its notes and docs to \(to)")
            return false
        }
        let built = testBuild?() ?? run("bash", [root.appendingPathComponent("kit.sh").path])
        guard built.code == 0 else {
            // The tree was clean before the rebase, so this only undoes the update.
            git("reset", "-q", "--hard", before)
            let tail = built.out.split(separator: "\n").suffix(5).joined(separator: "\n")
            notice("apprentice: the update to \(to) failed its build or self-test, so apprentice stayed on the old version:\n\(tail)")
            return false
        }
        notice("apprentice: updated itself to \(to)")
        return true
    }

    /// git fails instead of asking for a login: the daemon may share the user's terminal, and a prompt
    /// there would hang the command and catch their keys (M6).
    static func quiet(_ proc: Process) -> Process {
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        proc.environment = env
        return proc
    }

    private static func requireClean() throws {
        let dirty = git("status", "--porcelain").out
        guard dirty.isEmpty else { throw Fail(5, "uncommitted changes in \(root.path); commit each with `apprentice commit \"…\"` first:\n\(dirty)") }
    }

    private static func touchesSource(since rev: String) -> Bool {
        !git("diff", "--name-only", rev, "HEAD", "--", "Sources", "Package.swift", "kit.sh").out.isEmpty
    }

    /// Only the clone ~/.apprentice/notes links into is the installed one. kit.sh from any other clone
    /// (APPRENTICE_NOTES, a test copy) would reinstall from it and relink the notes (M7).
    private static var installedHere: Bool {
        let installed = Store.dir.appendingPathComponent("notes").resolvingSymlinksInPath().deletingLastPathComponent()
        return installed.standardizedFileURL.path == root.standardizedFileURL.path
    }

    /// Runs kit.sh, which builds, self-tests, signs and swaps the binary in place, then stops the daemon so
    /// the next command starts the new one.
    private static func rebuild() throws -> String {
        guard installedHere else { return "not rebuilt: \(root.path) is not the installed clone" }
        let built = run("bash", [root.appendingPathComponent("kit.sh").path])
        guard built.code == 0 else { throw Fail(5, "the build or self-test failed; the commit stays, fix it and commit again:\n\(built.out.split(separator: "\n").suffix(15).joined(separator: "\n"))") }
        Wire.stopVMDaemons()
        _ = Wire.stopDaemon()
        return "rebuilt and restarted apprentice"
    }
}
