import Foundation

/// Everything the user taught apprentice goes to their own private GitHub repo, `apprentice-home`, so
/// signing in on another Mac brings it all back. `~/.apprentice` itself is the working copy: an allow-list
/// `.gitignore` keeps only the files that are the user's (settings, prefs, voice, hand and typing, skills,
/// setups, the project list, site counts, logs as text, each VM's settings in `layers/`). Secrets (the
/// Keychain, the VM's ssh key), session state and screenshots never leave the Mac.
///
/// Local first: every writer saves its file as before. The main daemon looks every minute and, when
/// something changed or every `[sync] every_min`, commits, rebases onto the repo and pushes.
/// Offline, commits wait. Logs (`*.jsonl`) merge line by line; any other clash keeps this Mac's version,
/// and a file that no longer parses after a merge takes this Mac's copy whole. A file that looks like it
/// holds a key or token is never committed: `sync status` says which and where the value belongs.
enum Sync {
    static let repoName = "apprentice-home"

    /// What syncs, relative to `~/.apprentice`; a trailing slash is a folder.
    static let synced = ["config.toml", "routes.toml", "prefs.json", "voice.md", "voice-asked.json", "hand.json", "typing.json",
                         "setups/", "skills/", "projects.json", "budgets.json", "limits.json", "events.jsonl", "muted", "layers/"]

    static let gitignore = """
        # apprentice sync: everything is left out but what is listed (`Sync.synced`).
        /*
        !/.gitignore
        !/.gitattributes

        """ + synced.map { "!/\($0)" }.joined(separator: "\n") + """

        !/runs/
        /runs/*/*
        !/runs/*/*.jsonl
        *.bak
        *.lock
        .DS_Store

        """

    static let gitattributes = "*.jsonl merge=union\n"

    /// A test points sync at another folder and a local bare repo, with no account.
    static var testDir: URL?
    static var testRemote: String?

    static var dir: URL { testDir ?? Store.dir }
    static var statusFile: URL { dir.appendingPathComponent("sync.json") }

    static var settings: [String: String] { Toml.load(Config.path)["sync"] ?? [:] }
    static var on: Bool { testDir != nil || settings["on"].map(Toml.unquote) == "true" }
    static var everySeconds: Double { max(settings["every_min"].flatMap { Double(Toml.unquote($0)) } ?? 5, 1) * 60 }

    /// What the last round found, for `sync status` and the window. Kept on this Mac only.
    struct Status: Codable, Equatable {
        var at: Double?
        var pushedAt: Double?
        var error: String?
        /// Files left out because they look like they hold a secret, each with why.
        var refused: [String: String] = [:]
        /// Files where this Mac's copy won a clash.
        var kept: [String] = []
        var restoredTo: String?
    }

    static func loadStatus() -> Status {
        (try? Data(contentsOf: statusFile)).flatMap { try? JSONDecoder().decode(Status.self, from: $0) } ?? Status()
    }

    static func saveStatus(_ s: Status) {
        try? Wire.json(s).write(to: statusFile, options: .atomic)
    }

    // MARK: - git

    /// Git in the sync folder, signed in when the remote is GitHub: the token goes in an extra header through
    /// `GIT_CONFIG_*`, never in the arguments, a remote URL or `.git/config`.
    @discardableResult
    static func git(_ args: [String], token: String? = nil) -> (code: Int32, out: String) {
        var env = ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "credential.helper", "GIT_CONFIG_VALUE_0": ""]
        if let token {
            let basic = Data("x-access-token:\(token)".utf8).base64EncodedString()
            env["GIT_CONFIG_COUNT"] = "2"
            env["GIT_CONFIG_KEY_1"] = "http.https://github.com/.extraheader"
            env["GIT_CONFIG_VALUE_1"] = "Authorization: Basic \(basic)"
        }
        return Repo.run("git", args, in: dir, env: env)
    }

    static var isRepo: Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) }

    /// Makes `~/.apprentice` a repo with the allow-list, and keeps the list current after an update.
    /// Returns true the first time, when nothing has been committed yet.
    @discardableResult
    static func prepare() throws -> Bool {
        let fresh = !isRepo
        if fresh {
            let r = git(["init", "-q", "-b", "main"])
            guard r.code == 0 else { throw Fail(5, "sync: could not make \(dir.path) a git repo: \(r.out)") }
        }
        for (name, text) in [(".gitignore", gitignore), (".gitattributes", gitattributes)] {
            let url = dir.appendingPathComponent(name)
            if (try? String(contentsOf: url, encoding: .utf8)) != text { try text.write(to: url, atomically: true, encoding: .utf8) }
        }
        let p = Account.profile
        git(["config", "user.name", p?.name ?? p?.login ?? "apprentice"])
        git(["config", "user.email", p.map { "\($0.id)+\($0.login)@users.noreply.github.com" } ?? "apprentice@localhost"])
        return fresh || git(["rev-parse", "-q", "--verify", "HEAD"]).code != 0
    }

    // MARK: - secrets

    /// Values that must never be committed: tokens and keys by their shape, private keys, and the phone's
    /// ntfy topic (anyone who knows it reads the questions). Each with where the value belongs instead.
    static let secretShapes: [(pattern: String, why: String)] = [
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, "a private key"),
        (#"\b(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})"#, "a GitHub token"),
        (#"\bsk-(ant-|proj-|or-)?[A-Za-z0-9_-]{20,}"#, "an API key: use APPRENTICE_API_KEY instead of [run] api_key"),
        (#"\bxox[abpr]-[A-Za-z0-9-]{10,}"#, "a Slack token"),
        (#"\bAKIA[0-9A-Z]{16}\b"#, "an AWS key"),
        (#"(?i)\b(api_key|apikey|secret|password|token)\s*=\s*"[^"]{12,}""#, "a key or password: keep it out of the file (an environment variable)"),
        (#"ntfy\.sh/[A-Za-z0-9_-]{8,}"#, "the phone's ntfy topic ([agent] notify): it stays on this Mac"),
    ]

    /// Why a file's text must not be committed, or nil when it may.
    static func secret(in text: String) -> String? {
        for s in secretShapes where text.range(of: s.pattern, options: .regularExpression) != nil { return s.why }
        return nil
    }

    // MARK: - a round

    /// Only one round at a time, across the daemon and a `sync now` from the CLI.
    static func round() throws -> Status {
        try Store.locked(at: dir.appendingPathComponent("sync")) { try roundLocked() }
    }

    private static func roundLocked() throws -> Status {
        var status = loadStatus()
        status.at = Date().timeIntervalSince1970
        status.kept = []
        do {
            let fresh = try prepare()
            let auth = try remote()
            let token = auth.token
            let f = git(["fetch", "-q", "origin"], token: token)
            guard f.code == 0 else { throw Fail(5, "sync: could not reach \(auth.label): \(redact(f.out))") }
            let repoHasCommits = git(["rev-parse", "-q", "--verify", "refs/remotes/origin/main"]).code == 0
            if fresh && repoHasCommits { status.restoredTo = try restore() }
            status.refused = try commitLocal()
            if repoHasCommits { status.kept = try merge() }
            if ahead() > 0 {
                let p = git(["push", "-q", "origin", "HEAD:refs/heads/main"], token: token)
                guard p.code == 0 else { throw Fail(5, "sync: push to \(auth.label) failed: \(redact(p.out))") }
                status.pushedAt = Date().timeIntervalSince1970
            }
            status.error = nil
        } catch let fail as Fail {
            status.error = fail.message
            saveStatus(status)
            throw fail
        }
        saveStatus(status)
        return status
    }

    /// Commits whatever changed, leaving out a file that looks like it holds a secret. Returns those files.
    static func commitLocal() throws -> [String: String] {
        git(["add", "-A"])
        var refused: [String: String] = [:]
        for path in git(["diff", "--cached", "--name-only", "--diff-filter=AM"]).out.split(separator: "\n").map(String.init) {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8),
                  let why = secret(in: text) else { continue }
            refused[path] = why
            git(["reset", "-q", "--", path])
        }
        let staged = git(["diff", "--cached", "--name-only"]).out.split(separator: "\n").map(String.init)
        guard !staged.isEmpty else { return refused }
        let host = Host.current().localizedName ?? "this Mac"
        let names = staged.prefix(4).joined(separator: ", ") + (staged.count > 4 ? " and \(staged.count - 4) more" : "")
        let c = git(["commit", "-q", "-m", "\(host): \(names)"])
        guard c.code == 0 else { throw Fail(5, "sync: commit failed: \(c.out)") }
        return refused
    }

    /// Commits not yet in the repo.
    static func ahead() -> Int {
        guard git(["rev-parse", "-q", "--verify", "refs/remotes/origin/main"]).code == 0 else {
            return git(["rev-parse", "-q", "--verify", "HEAD"]).code == 0 ? Int(git(["rev-list", "--count", "HEAD"]).out) ?? 1 : 0
        }
        return Int(git(["rev-list", "--count", "origin/main..HEAD"]).out) ?? 0
    }

    /// This Mac's commits on top of the repo's. A clash keeps this Mac's lines (`-X theirs` replays ours);
    /// logs merge line by line; a settings file that no longer parses takes this Mac's copy whole. Files
    /// that were left out (secrets) are set aside and put back, so the rebase starts clean.
    static func merge() throws -> [String] {
        let before = git(["rev-parse", "HEAD"]).out
        guard git(["merge-base", "--is-ancestor", "origin/main", "HEAD"]).code != 0 else { return [] }
        let dirty = git(["status", "--porcelain", "-z"]).out
        var stashed = false
        if !dirty.isEmpty { stashed = git(["stash", "push", "-q", "--include-untracked"]).code == 0 }
        defer { if stashed { git(["stash", "pop", "-q"]) } }
        let r = git(["rebase", "-q", "-X", "theirs", "origin/main"])
        if r.code != 0 {
            git(["rebase", "--abort"])
            throw Fail(5, "sync: this Mac's changes and the repo's could not be put together; nothing was lost, and this Mac's stay unsent. \(redact(r.out))")
        }
        var kept: [String] = []
        let changed = git(["diff", "--name-only", "\(before)", "HEAD"]).out.split(separator: "\n").map(String.init)
        for path in changed where !parses(path) {
            let mine = git(["show", "\(before):\(path)"])
            guard mine.code == 0 else { continue }
            try? (mine.out + "\n").write(to: dir.appendingPathComponent(path), atomically: true, encoding: .utf8)
            kept.append(path)
        }
        if !kept.isEmpty {
            git(["add", "--"] + kept)
            git(["commit", "-q", "-m", "keep this Mac's copy of \(kept.joined(separator: ", "))"])
        }
        return kept
    }

    /// Whether a settings file still reads after a merge.
    static func parses(_ path: String) -> Bool {
        let url = dir.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else { return true }
        let text = String(decoding: data, as: UTF8.self)
        if text.contains("\n<<<<<<< ") || text.hasPrefix("<<<<<<< ") { return false }
        if path.hasSuffix(".json") { return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil }
        return true
    }

    /// First sync on a Mac whose repo already has the user's things: the repo's copies replace this Mac's,
    /// and each file it replaces is kept in `before-sync/<stamp>/`. Returns that folder's path.
    static func restore() throws -> String? {
        let theirs = Set(git(["ls-tree", "-r", "--name-only", "origin/main"]).out.split(separator: "\n").map(String.init))
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let keep = dir.appendingPathComponent("before-sync/\(stamp)")
        let fm = FileManager.default
        var moved = false
        for path in theirs where ![".gitignore", ".gitattributes"].contains(path) {
            let url = dir.appendingPathComponent(path)
            guard fm.fileExists(atPath: url.path) else { continue }
            let to = keep.appendingPathComponent(path)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: to)
            try fm.copyItem(at: url, to: to)
            moved = true
        }
        let r = git(["reset", "-q", "--hard", "origin/main"])
        guard r.code == 0 else { throw Fail(5, "sync: could not bring in the repo's copy: \(r.out)") }
        return moved ? keep.path : nil
    }

    // MARK: - the repo

    /// The repo to sync with, set as `origin` (a plain URL, no token), and the token to reach it.
    static func remote() throws -> (token: String?, label: String) {
        if let testRemote {
            if git(["remote", "get-url", "origin"]).code != 0 { git(["remote", "add", "origin", testRemote]) }
            return (nil, testRemote)
        }
        guard let p = Account.profile, let token = Account.token() else {
            throw Fail(5, "sync: not signed in to GitHub: `apprentice account login`, or Settings ▸ GitHub account in the window")
        }
        let url = "https://github.com/\(p.login)/\(repoName).git"
        if git(["remote", "get-url", "origin"]).out != url {
            let r = git(["remote", "get-url", "origin"]).code == 0 ? git(["remote", "set-url", "origin", url]) : git(["remote", "add", "origin", url])
            guard r.code == 0 else { throw Fail(5, "sync: could not set the repo: \(r.out)") }
            try ensureRepo(p.login, token: token)
        }
        return (token, "github.com/\(p.login)/\(repoName)")
    }

    /// Makes the private repo when the account has none.
    static func ensureRepo(_ login: String, token: String) throws {
        let found = Account.api("GET", "/repos/\(login)/\(repoName)", token: token)
        if found.code == 200 {
            if found.json?["private"] as? Bool == false {
                throw Fail(5, "sync: github.com/\(login)/\(repoName) is public. It would hold your settings: make it private on GitHub first")
            }
            return
        }
        guard found.code == 404 else { throw Fail(5, "sync: GitHub did not answer (\(found.code.map(String.init) ?? "offline")); trying again later") }
        let made = Account.api("POST", "/user/repos", ["name": repoName, "private": true, "auto_init": false,
                                                        "description": "apprentice: my settings, preferences and skills (private)"], token: token)
        guard made.code == 201 else {
            let why = (made.json?["message"] as? String) ?? "code \(made.code.map(String.init) ?? "none")"
            throw Fail(5, "sync: GitHub would not make the private repo \(repoName) (\(why)). The apprentice GitHub App needs to be installed on all your repositories, with Administration and Contents set to read and write")
        }
    }

    /// Git output with anything that looks like a credential taken out.
    static func redact(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)(authorization:[^\n]*|x-access-token:[^@\s]*|gh[pousr]_[A-Za-z0-9]+)"#, with: "…", options: .regularExpression)
            .prefix(300).description
    }

    // MARK: - the daemon's loop

    private static var timer: DispatchSourceTimer?
    private static var lastPull: Date = .distantPast

    /// The main daemon looks every minute: a commit when something changed, a push when there is one to
    /// send, and the repo's changes every `[sync] every_min`.
    static func schedule() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 30, repeating: 60)
        t.setEventHandler {
            guard on, Account.profile != nil || testRemote != nil else { return }
            let due = Date().timeIntervalSince(lastPull) >= everySeconds
            guard due || !git(["status", "--porcelain"]).out.isEmpty || ahead() > 0 else { return }
            if due { lastPull = Date() }
            if let s = try? round(), let to = s.restoredTo {
                Store.log(["sync": "restored", "kept": to])
            }
        }
        t.resume()
        timer = t
    }

    // MARK: - the command

    static let usage = "sync [status] · on · off · now"

    static func command(_ a: Args) throws -> String {
        switch a.pos.first ?? "status" {
        case "status": return status()
        case "on":
            _ = Toml.set(Config.path, "sync", "on", "true")
            let s = try round()
            return "sync on: \(dir.path) goes to github.com/\(Account.profile?.login ?? "?")/\(repoName), every \(Int(everySeconds / 60)) min\n" + lines(s).joined(separator: "\n")
        case "off":
            _ = Toml.set(Config.path, "sync", "on", "false")
            return "sync off: nothing more is sent; the repo and this Mac's files stay as they are"
        case "now":
            guard on else { throw Fail(5, "sync is off: `apprentice sync on`") }
            return (["synced"] + lines(try round())).joined(separator: "\n")
        default: throw Fail(5, usage)
        }
    }

    static func status() -> String {
        guard on else { return "sync off. `apprentice sync on` sends your settings, preferences and skills to your own private GitHub repo, \(repoName)" }
        var out = ["sync on · github.com/\(Account.profile?.login ?? "?")/\(repoName) · every \(Int(everySeconds / 60)) min"]
        if isRepo {
            let waiting = ahead()
            let changed = git(["status", "--porcelain"]).out.split(separator: "\n").count
            out.append(waiting + changed == 0 ? "up to date" : "\(waiting) commit(s) to send, \(changed) file(s) changed since")
        }
        return (out + lines(loadStatus())).joined(separator: "\n")
    }

    static func lines(_ s: Status) -> [String] {
        var out: [String] = []
        if let at = s.pushedAt {
            out.append("last sent " + RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: at), relativeTo: Date()))
        }
        if let e = s.error { out.append("⚠ \(e)") }
        for (path, why) in s.refused.sorted(by: { $0.key < $1.key }) { out.append("⚠ \(path) not sent: it looks like it holds \(why)") }
        if !s.kept.isEmpty { out.append("⚠ clashed with the repo, kept this Mac's copy: \(s.kept.joined(separator: ", "))") }
        if let to = s.restoredTo { out.append("brought in your settings from the repo; this Mac's old copies are in \(to)") }
        return out
    }
}
