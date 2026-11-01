import Foundation

/// Where Robert's settings (config.toml, routes.toml) live: in ~/.apprentice on this Mac only, or
/// in ~/.apprentice/settings, a clone of a private GitHub repo that every Mac syncs with. Session
/// state, logs and screenshots never leave the Mac.
enum Settings {
    static let files = ["config.toml", "routes.toml"]
    static var repoDir: URL { Store.dir.appendingPathComponent("settings") }
    static var synced: Bool { FileManager.default.fileExists(atPath: repoDir.appendingPathComponent(".git").path) }
    static var dir: URL { synced ? repoDir : Store.dir }
    static let defaultRepo = "apprentice-settings"

    /// `settings [github [--repo name] | local | sync]`. Robert's command; agents never run it.
    static func run(_ a: Args) throws -> String {
        switch a.pos.first ?? "" {
        case "": return status()
        case "github": return try github(repo: a.value("repo") ?? defaultRepo)
        case "local": return try local()
        case "sync":
            guard synced else { throw Fail(5, "settings are on this Mac only: `apprentice settings github` syncs them") }
            return try sync()
        default: throw Fail(5, "settings [github [--repo name] | local | sync]")
        }
    }

    static func status() -> String {
        guard synced else { return "settings: this Mac only, in \(Store.dir.path)\n`apprentice settings github` keeps them in a private GitHub repo instead" }
        let remote = git("remote", "get-url", "origin").out
        let last = git("log", "-1", "--format=%cr from %s").out
        return "settings: synced with \(remote) (last change \(last))\nfiles: \(files.joined(separator: ", ")) in \(repoDir.path)"
    }

    /// Makes (or reuses) a private repo in the signed-in account and moves the settings into its
    /// clone. A file the repo already has wins, since it came from another Mac; the local copy is
    /// kept beside it as .local.
    static func github(repo: String) throws -> String {
        if synced { return status() }
        let user = Repo.run("gh", ["api", "user", "-q", ".login"], in: Store.dir)
        guard user.code == 0, !user.out.isEmpty else { throw Fail(7, "gh is not signed in: run `gh auth login`") }
        let name = repo.contains("/") ? repo : "\(user.out)/\(repo)"
        if Repo.run("gh", ["repo", "view", name], in: Store.dir).code != 0 {
            let made = Repo.run("gh", ["repo", "create", name, "--private", "--description", "apprentice settings"], in: Store.dir)
            guard made.code == 0 else { throw Fail(5, "could not create \(name): \(made.out)") }
        }
        // A clone that failed halfway leaves a folder that would block this one (M4).
        if let left = try? FileManager.default.contentsOfDirectory(atPath: repoDir.path) {
            guard left.isEmpty else { throw Fail(5, "\(repoDir.path) exists but is not a clone: move its files out and run this again") }
            try FileManager.default.removeItem(at: repoDir)
        }
        let cloned = Repo.run("gh", ["repo", "clone", name, repoDir.path], in: Store.dir)
        guard cloned.code == 0 else { throw Fail(5, "could not clone \(name): \(cloned.out)") }
        var out = ["settings: now in the private repo \(name)"]
        let fm = FileManager.default
        for file in files {
            let here = Store.dir.appendingPathComponent(file), there = repoDir.appendingPathComponent(file)
            guard fm.fileExists(atPath: here.path) else { continue }
            if fm.fileExists(atPath: there.path) {
                let kept = Store.dir.appendingPathComponent(file + ".local")
                try? fm.removeItem(at: kept)  // from an earlier switch (M5)
                try fm.moveItem(at: here, to: kept)
                out.append("\(file): using the one from GitHub; this Mac's copy is \(Store.dir.path)/\(file).local")
            } else {
                try fm.moveItem(at: here, to: there)
            }
        }
        out.append(try sync())
        return out.joined(separator: "\n")
    }

    /// Stops syncing: the files move back to ~/.apprentice. The GitHub repo stays as it is.
    static func local() throws -> String {
        guard synced else { return status() }
        _ = try? sync()
        let fm = FileManager.default
        for file in files where fm.fileExists(atPath: repoDir.appendingPathComponent(file).path) {
            try? fm.removeItem(at: Store.dir.appendingPathComponent(file))
            try fm.moveItem(at: repoDir.appendingPathComponent(file), to: Store.dir.appendingPathComponent(file))
        }
        try fm.removeItem(at: repoDir)
        return "settings: this Mac only, in \(Store.dir.path). The GitHub repo is unchanged."
    }

    /// Commits local changes, rebases on the other Macs' changes and pushes.
    @discardableResult
    static func sync() throws -> String {
        if let secret = secretLine() { throw Fail(4, "not synced: \(secret). Put the key in APPRENTICE_API_KEY instead") }
        commitChanges()
        // A repo just made on GitHub has no branch yet: the first push makes it.
        let empty = git("ls-remote", "--heads", "origin").out.isEmpty
        let pulled = empty ? (code: Int32(0), out: "") : git("pull", "-q", "--rebase", "origin", "HEAD")
        if pulled.code != 0 {
            git("rebase", "--abort")
            throw Fail(5, "settings changed on two Macs at once; merge by hand in \(repoDir.path)\n\(pulled.out)")
        }
        guard git("push", "-q", "-u", "origin", "HEAD").code == 0 else { throw Fail(5, "could not push the settings: check `gh auth status`") }
        return "settings synced"
    }

    /// Called after Robert's settings change and when a session starts (at most hourly):
    /// syncs in the background, so nothing waits on the network.
    static func syncSoon(force: Bool = false) -> String? {
        guard synced else { return nil }
        if let secret = secretLine() { return "settings: not synced to GitHub, \(secret); use APPRENTICE_API_KEY" }
        let stamp = repoDir.appendingPathComponent(".git/FETCH_HEAD")
        let last = (try? stamp.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard force || last.map({ Date().timeIntervalSince($0) > 3600 }) ?? true, syncer?.isRunning != true else { return nil }
        let proc = Repo.quiet(Process())
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", "git add -A && { git diff --cached --quiet || git commit -qm \"$1\"; } ; git pull -q --rebase origin HEAD || git rebase --abort; git push -q -u origin HEAD", "sync", commitMessage]
        proc.currentDirectoryURL = repoDir
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        syncer = proc
        return nil
    }

    private static var syncer: Process?

    private static var commitMessage: String { "Settings from \(Host.current().localizedName ?? "a Mac")" }

    private static func commitChanges() {
        git("add", "-A")
        if git("diff", "--cached", "--quiet").code != 0 { git("commit", "-qm", commitMessage) }
    }

    /// An API key must never reach GitHub, even a private repo.
    private static func secretLine() -> String? {
        let key = Toml.load(repoDir.appendingPathComponent("config.toml"))["run"]?["api_key"].map(Toml.unquote) ?? ""
        return key.isEmpty ? nil : "config.toml has an api_key"
    }

    @discardableResult
    private static func git(_ args: String...) -> (code: Int32, out: String) { Repo.run("git", args, in: repoDir) }
}
