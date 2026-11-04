import Foundation

/// Everything the user taught apprentice, and every project they work on, goes to their own GitHub, so
/// signing in on another Mac brings it all back. Two kinds of private repo:
/// - `apprentice-home`: `~/.apprentice` itself is the working copy, with an allow-list `.gitignore` that
///   keeps only the user's own files (settings, prefs, voice, hand and typing, skills, setups, the project
///   list, site counts, logs as text, each VM's settings in `layers/`). Secrets (the Keychain, the VM's ssh
///   key), session state and screenshots never leave the Mac.
/// - one repo per project folder in `projects.json`, named after the project, made the first time. A project
///   whose remote is someone else's is committed here and never pushed.
///
/// Local first: every writer saves its file as before. The main daemon looks every minute and, when
/// something changed or every `[sync] every_min`, commits, rebases onto the repo and pushes. Offline,
/// commits wait. Logs (`*.jsonl`) merge line by line; any other clash keeps this Mac's version, and a file
/// that no longer parses after a merge takes this Mac's copy whole. A file that looks like it holds a key
/// or token is never committed: `sync status` says which and where the value belongs. On by default once
/// the user signs in to GitHub; `[sync] on = false` turns it off.
enum Sync {
    static let repoName = "apprentice-home"

    /// What syncs, relative to `~/.apprentice`; a trailing slash is a folder.
    /// Named agents and the user's own CLIs and prompts follow them to another Mac, and so do learned facts and a copy
    /// of each past-run note. What stays on this Mac: answers to a project's first-use permission question
    /// (`project-agents.json`: a grant should be asked for again on another machine), which CLI is out of usage
    /// (`agent-limits.json`), and each run's raw output, which can hold secrets and lives in the project's cache.
    static let synced = ["config.toml", "routes.toml", "prefs.json", "voice.md", "voice-asked.json", "hand.json", "typing.json",
                         "setups/", "skills/", "projects.json", "budgets.json", "limits.json", "events.jsonl", "muted", "layers/",
                         "named-agents.toml", "agents.toml", "pipeline-prompts.md", "pipeline-notes/"]

    static let gitignore = """
        # apprentice sync: everything is left out but what is listed (`Sync.synced`).
        /*
        !/.gitignore
        !/.gitattributes

        """ + synced.map { "!/\($0)" }.joined(separator: "\n") + """

        !/runs/
        /runs/*/*
        !/runs/*/*.jsonl
        /skills/index.sqlite*
        /skills/library/
        *.bak
        *.lock
        .DS_Store

        """

    /// Logs merge line by line, and so do learned facts: two Macs learning about one place keep both lines, which
    /// `Skills.facts` folds together by the fact's key.
    static let gitattributes = "*.jsonl merge=union\nskills/learned/**/*.md merge=union\n"

    /// What a project folder that had no git repo leaves out from the start.
    static let projectIgnore = """
        .DS_Store
        .env
        .env.*
        node_modules/
        .build/
        build/
        dist/
        .venv/
        __pycache__/
        .apprentice/limits.json
        .apprentice/cache/

        """

    /// A file this big stays out of a commit: GitHub refuses files over 100 MB.
    static let maxFileBytes = 50_000_000

    /// A test points sync at other folders and local bare repos, with no account.
    static var testDir: URL?
    static var testRemote: String?
    static var testProjectRemote: ((String) -> String)?

    static var dir: URL { testDir ?? Store.dir }
    static var statusFile: URL { dir.appendingPathComponent("sync.json") }

    static var settings: [String: String] { Toml.load(Config.path)["sync"] ?? [:] }
    /// On once the user is signed in, unless they turned it off.
    static var on: Bool { testDir != nil || (settings["on"].map(Toml.unquote) != "false" && Account.profile != nil) }
    static var everySeconds: Double { max(settings["every_min"].flatMap { Double(Toml.unquote($0)) } ?? 5, 1) * 60 }

    /// What the last round found, for `sync status` and the window. Kept on this Mac only.
    struct Status: Codable, Equatable {
        var at: Double?
        var pushedAt: Double?
        var error: String?
        /// Files left out because they look like they hold a secret, or are too big, each with why.
        var refused: [String: String] = [:]
        /// Files where this Mac's copy won a clash.
        var kept: [String] = []
        var restoredTo: String?
        /// Per project, what it found: "sent", "up to date", or why not.
        var projects: [String: String] = [:]
    }

    static func loadStatus() -> Status {
        (try? Data(contentsOf: statusFile)).flatMap { try? JSONDecoder().decode(Status.self, from: $0) } ?? Status()
    }

    static func saveStatus(_ s: Status) {
        try? Wire.json(s).write(to: statusFile, options: .atomic)
    }

    // MARK: - git

    /// Git in a folder, signed in when the remote is GitHub: the token goes in an extra header through
    /// `GIT_CONFIG_*`, never in the arguments, a remote URL or `.git/config`.
    @discardableResult
    static func git(_ args: [String], in folder: URL? = nil, token: String? = nil) -> (code: Int32, out: String) {
        var env = ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "credential.helper", "GIT_CONFIG_VALUE_0": ""]
        if let token {
            let basic = Data("x-access-token:\(token)".utf8).base64EncodedString()
            env["GIT_CONFIG_COUNT"] = "2"
            env["GIT_CONFIG_KEY_1"] = "http.https://github.com/.extraheader"
            env["GIT_CONFIG_VALUE_1"] = "Authorization: Basic \(basic)"
        }
        return Repo.run("git", args, in: folder ?? dir, env: env)
    }

    static func isRepo(_ folder: URL) -> Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) }

    static func has(_ ref: String, in folder: URL) -> Bool { git(["rev-parse", "-q", "--verify", ref], in: folder).code == 0 }

    /// Makes `~/.apprentice` a repo with the allow-list, and keeps the list current after an update.
    /// Returns true the first time, when nothing has been committed yet.
    @discardableResult
    static func prepare() throws -> Bool {
        let fresh = !isRepo(dir)
        if fresh {
            let r = git(["init", "-q", "-b", "main"])
            guard r.code == 0 else { throw Fail(5, "sync: could not make \(dir.path) a git repo: \(r.out)") }
        }
        for (name, text) in [(".gitignore", gitignore), (".gitattributes", gitattributes)] {
            let url = dir.appendingPathComponent(name)
            if (try? String(contentsOf: url, encoding: .utf8)) != text { try text.write(to: url, atomically: true, encoding: .utf8) }
        }
        identify(dir)
        return fresh || !has("HEAD", in: dir)
    }

    /// Commits carry the user's GitHub name and private email, set in the folder's own repo only when it has none.
    static func identify(_ folder: URL) {
        let p = Account.profile
        if git(["config", "user.name"], in: folder).out.isEmpty || folder == dir {
            git(["config", "user.name", p?.name ?? p?.login ?? "apprentice"], in: folder)
        }
        if git(["config", "user.email"], in: folder).out.isEmpty || folder == dir {
            git(["config", "user.email", p.map { "\($0.id)+\($0.login)@users.noreply.github.com" } ?? "apprentice@localhost"], in: folder)
        }
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

    // MARK: - signing in

    /// Tokens to try, the apprentice sign-in first. A GitHub App token reaches only repos the app is installed
    /// on and may not make repos; the GitHub CLI's own sign-in, for the same account, covers that.
    static func tokens(_ login: String) -> [String] {
        if let roundTokens { return roundTokens }
        var out: [String] = []
        if let t = Account.token() { out.append(t) }
        let gh = Repo.run("gh", ["auth", "token", "--hostname", "github.com"], in: dir)
        if gh.code == 0, !gh.out.isEmpty, !out.contains(gh.out),
           (Account.api("GET", "/user", token: gh.out).json?["login"] as? String)?.lowercased() == login.lowercased() {
            out.append(gh.out)
        }
        roundTokens = out
        return out
    }

    /// The tokens found for this round, so a round asks the GitHub CLI once.
    private static var roundTokens: [String]?

    /// The token that worked last, tried first next time.
    private static var good: String?

    /// Runs `body` with each token until one works; the last refusal is what is thrown.
    static func signedIn<T>(_ login: String, _ body: (String) throws -> T) throws -> T {
        var list = tokens(login)
        if let good, let i = list.firstIndex(of: good) { list.insert(list.remove(at: i), at: 0) }
        guard !list.isEmpty else { throw Fail(5, "sync: GitHub did not accept the sign-in: `apprentice account login` again") }
        var last: Error?
        for token in list {
            do {
                let out = try body(token)
                good = token
                return out
            } catch { last = error }
        }
        throw last!
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
            if testRemote != nil {
                try home(token: nil, login: "test", &status)
                status.projects = projects { try project($0, token: nil, login: "test") }
            } else {
                guard let login = Account.profile?.login else {
                    throw Fail(5, "sync: not signed in to GitHub: `apprentice account login`, or Settings ▸ GitHub account in the window")
                }
                roundTokens = nil
                try signedIn(login) { token in
                    try ensureRepo(login, repoName, token: token, mustBeEmpty: false)
                    try home(token: token, login: login, &status)
                }
                status.projects = projects { p in try signedIn(login) { try project(p, token: $0, login: login) } }
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

    /// `~/.apprentice` to and from `apprentice-home`.
    private static func home(token: String?, login: String, _ status: inout Status) throws {
        let fresh = try prepare()
        let url = testRemote ?? "https://github.com/\(login)/\(repoName).git"
        setOrigin(url, in: dir)
        let f = git(["fetch", "-q", "origin"], token: token)
        guard f.code == 0 else { throw Fail(5, "sync: could not reach \(label(url)): \(redact(f.out))") }
        let repoHasCommits = has("refs/remotes/origin/main", in: dir)
        if fresh && repoHasCommits {
            status.restoredTo = try restore()
            cloneProjects(token: token)
        }
        status.refused = try commitLocal(in: dir)
        if repoHasCommits { status.kept = try merge(in: dir, onto: "origin/main") }
        if ahead(in: dir, of: "origin/main") > 0 {
            let p = git(["push", "-q", "origin", "HEAD:refs/heads/main"], token: token)
            guard p.code == 0 else { throw Fail(5, "sync: push to \(label(url)) failed: \(redact(p.out))") }
            status.pushedAt = Date().timeIntervalSince1970
        }
    }

    static func label(_ url: String) -> String {
        url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: ".git", with: "")
    }

    static func setOrigin(_ url: String, in folder: URL) {
        let now = git(["remote", "get-url", "origin"], in: folder)
        if now.code != 0 { git(["remote", "add", "origin", url], in: folder) } else if now.out != url { git(["remote", "set-url", "origin", url], in: folder) }
    }

    /// Commits whatever changed, leaving out a file that looks like it holds a secret or is too big to send.
    /// Returns those files, each with why.
    static func commitLocal(in folder: URL) throws -> [String: String] {
        git(["add", "-A"], in: folder)
        var refused: [String: String] = [:]
        for path in git(["diff", "--cached", "--name-only", "--diff-filter=AM"], in: folder).out.split(separator: "\n").map(String.init) {
            let url = folder.appendingPathComponent(path)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            var why: String?
            if size > maxFileBytes { why = "over 50 MB, too big for GitHub" }
            else if size < 2_000_000, let text = try? String(contentsOf: url, encoding: .utf8) { why = secret(in: text) }
            guard let why else { continue }
            refused[path] = why
            git(["reset", "-q", "--", path], in: folder)
        }
        let staged = git(["diff", "--cached", "--name-only"], in: folder).out.split(separator: "\n").map(String.init)
        guard !staged.isEmpty else { return refused }
        let host = Host.current().localizedName ?? "this Mac"
        let names = staged.prefix(4).joined(separator: ", ") + (staged.count > 4 ? " and \(staged.count - 4) more" : "")
        let c = git(["commit", "-q", "--no-verify", "-m", "\(host): \(names)"], in: folder)
        guard c.code == 0 else { throw Fail(5, "sync: commit in \(folder.lastPathComponent) failed: \(c.out)") }
        return refused
    }

    /// Commits not yet in the repo.
    static func ahead(in folder: URL, of remote: String) -> Int {
        guard has(remote, in: folder) else {
            return has("HEAD", in: folder) ? Int(git(["rev-list", "--count", "HEAD"], in: folder).out) ?? 1 : 0
        }
        return Int(git(["rev-list", "--count", "\(remote)..HEAD"], in: folder).out) ?? 0
    }

    /// This Mac's commits on top of the repo's. A clash keeps this Mac's lines (`-X theirs` replays ours);
    /// logs merge line by line; a settings file that no longer parses takes this Mac's copy whole. Files
    /// that were left out (secrets) are set aside and put back, so the rebase starts clean.
    static func merge(in folder: URL, onto remote: String) throws -> [String] {
        let before = git(["rev-parse", "HEAD"], in: folder).out
        guard git(["merge-base", "--is-ancestor", remote, "HEAD"], in: folder).code != 0 else { return [] }
        let dirty = git(["status", "--porcelain"], in: folder).out
        var stashed = false
        if !dirty.isEmpty { stashed = git(["stash", "push", "-q", "--include-untracked"], in: folder).code == 0 }
        defer { if stashed { git(["stash", "pop", "-q"], in: folder) } }
        let r = git(["rebase", "-q", "-X", "theirs", remote], in: folder)
        if r.code != 0 {
            git(["rebase", "--abort"], in: folder)
            throw Fail(5, "sync: this Mac's changes in \(folder.lastPathComponent) and the repo's could not be put together; nothing was lost, and this Mac's stay unsent. \(redact(r.out))")
        }
        var kept: [String] = []
        let changed = git(["diff", "--name-only", before, "HEAD"], in: folder).out.split(separator: "\n").map(String.init)
        for path in changed where !parses(folder.appendingPathComponent(path)) {
            let mine = git(["show", "\(before):\(path)"], in: folder)
            guard mine.code == 0 else { continue }
            try? (mine.out + "\n").write(to: folder.appendingPathComponent(path), atomically: true, encoding: .utf8)
            kept.append(path)
        }
        if !kept.isEmpty {
            git(["add", "--"] + kept, in: folder)
            git(["commit", "-q", "--no-verify", "-m", "keep this Mac's copy of \(kept.joined(separator: ", "))"], in: folder)
        }
        return kept
    }

    /// Whether a file still reads after a merge.
    static func parses(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return true }
        let text = String(decoding: data, as: UTF8.self)
        if text.contains("\n<<<<<<< ") || text.hasPrefix("<<<<<<< ") { return false }
        // prefs.json must also be prefs: a well-formed file of another shape would be erased by the next `remember` (F15).
        if url.lastPathComponent == Prefs.file { return Prefs.parse(text) != nil }
        if url.pathExtension == "json" { return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil }
        return true
    }

    /// First sync on a Mac whose repo already has the user's things: the repo's copies replace this Mac's,
    /// and each file it replaces is kept in `before-sync/<stamp>/`. Returns that folder's path.
    static func restore() throws -> String? {
        let theirs = git(["ls-tree", "-r", "--name-only", "origin/main"]).out.split(separator: "\n").map(String.init)
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

    // MARK: - projects

    /// Each listed project to and from its own repo. Returns what happened to each, by name.
    static func projects(_ each: (Projects.Info) throws -> String) -> [String: String] {
        var out: [String: String] = [:]
        for p in Projects.all() {
            do { out[p.name] = try each(p) } catch let fail as Fail { out[p.name] = "⚠ " + fail.message } catch { out[p.name] = "⚠ \(error)" }
        }
        return out
    }

    /// The repo a project goes to: its own origin, else `<login>/<slug>` (made the first time).
    static func projectURL(_ p: Projects.Info, login: String) -> String {
        testProjectRemote?(p.slug) ?? "https://github.com/\(login)/\(p.slug).git"
    }

    static func project(_ p: Projects.Info, token: String?, login: String) throws -> String {
        let folder = p.folder
        let gitDir = folder.appendingPathComponent(".git")
        // Halfway through something the user is doing: leave it alone this round.
        for busy in ["MERGE_HEAD", "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD"]
            where FileManager.default.fileExists(atPath: gitDir.appendingPathComponent(busy).path) {
            return "waiting: a merge or rebase is under way there"
        }
        // A run's steps are working in this folder: no commit of half their work, and no stash pulling files from under
        // them. The next round after the run ends sends everything.
        if Runs.live(project: folder) { return "waiting: a pipeline is running there" }
        // A run's output can hold secrets, whatever state the ignore file was left in.
        if FileManager.default.fileExists(atPath: Runs.cache(project: folder).path) { ProjectFiles.ensureIgnored(folder) }
        if !isRepo(folder) {
            let r = git(["init", "-q", "-b", "main"], in: folder)
            guard r.code == 0 else { throw Fail(5, "could not make it a git repo: \(r.out)") }
            let ignore = folder.appendingPathComponent(".gitignore")
            if !FileManager.default.fileExists(atPath: ignore.path) { try projectIgnore.write(to: ignore, atomically: true, encoding: .utf8) }
        }
        identify(folder)
        let branch = git(["symbolic-ref", "--short", "HEAD"], in: folder)
        guard branch.code == 0 else { return "waiting: no branch is checked out" }
        let refused = try commitLocal(in: folder)
        let note = refused.isEmpty ? "" : " · ⚠ not sent: " + refused.map { "\($0.key) (\($0.value))" }.sorted().joined(separator: ", ")

        let origin = git(["remote", "get-url", "origin"], in: folder)
        var url = origin.code == 0 ? origin.out : ""
        if url.isEmpty {
            url = projectURL(p, login: login)
            if let token { try ensureRepo(login, p.slug, token: token, mustBeEmpty: true) }
            setOrigin(url, in: folder)
        }
        // Someone else's repo (a project made `--from` a shared one): commits stay here, nothing is pushed.
        let mine = testProjectRemote != nil || url.lowercased().hasPrefix("https://github.com/\(login.lowercased())/")
        guard mine else { return "committed here; not sent, since \(label(url)) is not yours" + note }
        Projects.setRemote(folder, url)

        let f = git(["fetch", "-q", "origin"], in: folder, token: token)
        guard f.code == 0 else { throw Fail(5, "could not reach \(label(url)): \(redact(f.out))") }
        let remote = "origin/\(branch.out)"
        var kept: [String] = []
        if Runs.live(project: folder) { return "waiting: a pipeline started there" + note }
        if has("refs/remotes/\(remote)", in: folder) { kept = try merge(in: folder, onto: remote) }
        let keptNote = kept.isEmpty ? "" : " · ⚠ clashed, kept this Mac's: " + kept.joined(separator: ", ")
        guard ahead(in: folder, of: remote) > 0 else { return "up to date" + note + keptNote }
        let push = git(["push", "-q", "origin", "HEAD:refs/heads/\(branch.out)"], in: folder, token: token)
        guard push.code == 0 else { throw Fail(5, "push to \(label(url)) failed: \(redact(push.out))") }
        return "sent to \(label(url))" + note + keptNote
    }

    /// On a new Mac: every listed project whose folder is missing is cloned from its repo.
    static func cloneProjects(token: String?) {
        for e in Projects.entries() where e.remote != nil {
            let folder = URL(fileURLWithPath: e.path)
            guard !FileManager.default.fileExists(atPath: folder.path), let remote = e.remote else { continue }
            try? FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            git(["clone", "-q", remote, folder.path], in: folder.deletingLastPathComponent(), token: token)
        }
    }

    // MARK: - the repos

    /// Makes the private repo when the account has none. A project's repo is adopted only when it is empty,
    /// so a project never lands on top of an unrelated repo with the same name.
    static func ensureRepo(_ login: String, _ name: String, token: String, mustBeEmpty: Bool) throws {
        let found = Account.api("GET", "/repos/\(login)/\(name)", token: token)
        if found.code == 200 {
            if found.json?["private"] as? Bool == false {
                throw Fail(5, "github.com/\(login)/\(name) is public; it would hold your files: make it private on GitHub, or give the folder another remote")
            }
            if mustBeEmpty, (found.json?["size"] as? Int ?? 0) > 0,
               Account.api("GET", "/repos/\(login)/\(name)/commits?per_page=1", token: token).code == 200 {
                throw Fail(5, "github.com/\(login)/\(name) already has other work in it; set the project's own remote (`git remote add origin <url>` in its folder)")
            }
            return
        }
        guard found.code == 404 else { throw Fail(5, "GitHub did not answer (\(found.code.map(String.init) ?? "offline")); trying again later") }
        let made = Account.api("POST", "/user/repos", ["name": name, "private": true, "auto_init": false,
                                                        "description": name == repoName ? "apprentice: my settings, preferences and skills (private)" : "apprentice project"],
                               token: token)
        guard made.code == 201 else {
            let why = (made.json?["message"] as? String) ?? "code \(made.code.map(String.init) ?? "none")"
            throw Fail(5, "GitHub would not make the private repo \(name) (\(why)). Sign in with the GitHub CLI (`gh auth login`), or install the apprentice GitHub App on all your repositories with Administration and Contents set to read and write")
        }
    }

    /// Git output with anything that looks like a credential taken out.
    static func redact(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)(authorization:[^\n]*|x-access-token:[^@\s]*|gh[pousr]_[A-Za-z0-9]+)"#, with: "…", options: .regularExpression)
            .prefix(300).description
    }

    // MARK: - the daemon's loop

    private static var timer: DispatchSourceTimer?
    private static var lastFull: Date = .distantPast

    /// The main daemon looks every minute: a round when something changed or a commit waits, and one
    /// every `[sync] every_min` for what other Macs sent.
    static func schedule() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 30, repeating: 60)
        t.setEventHandler {
            guard on else { return }
            let due = Date().timeIntervalSince(lastFull) >= everySeconds
            guard due || changed() else { return }
            lastFull = Date()
            if let s = try? round(), let to = s.restoredTo { Store.log(["sync": "restored", "kept": to]) }
        }
        t.resume()
        timer = t
    }

    /// Whether `~/.apprentice` or any project has something to commit or send.
    static func changed() -> Bool {
        let folders = [dir] + Projects.all().map(\.folder)
        return folders.contains { isRepo($0) && !git(["status", "--porcelain"], in: $0).out.isEmpty }
            || !isRepo(dir) || ahead(in: dir, of: "origin/main") > 0
    }

    // MARK: - the command

    static let usage = "sync [status] · on · off · now"

    static func command(_ a: Args) throws -> String {
        switch a.pos.first ?? "status" {
        case "status": return status()
        case "on":
            _ = Toml.set(Config.path, "sync", "on", "true")
            guard Account.profile != nil else { return "sync on: it starts once you sign in, `apprentice account login`" }
            return (["sync on: every \(Int(everySeconds / 60)) min"] + lines(try round())).joined(separator: "\n")
        case "off":
            _ = Toml.set(Config.path, "sync", "on", "false")
            return "sync off: nothing more is sent; the repos and this Mac's files stay as they are"
        case "now":
            guard on else { throw Fail(5, Account.profile == nil ? "sync needs a GitHub sign-in: `apprentice account login`" : "sync is off: `apprentice sync on`") }
            return (["synced"] + lines(try round())).joined(separator: "\n")
        default: throw Fail(5, usage)
        }
    }

    /// After `account login`: the first round, which on a new Mac brings everything back.
    static func afterLogin() -> String {
        guard on else { return "" }
        do { return "\n" + lines(try round()).joined(separator: "\n") } catch { return "\n⚠ \(error)" }
    }

    static func status() -> String {
        guard on else {
            return Account.profile == nil ? "sync waits for a GitHub sign-in: `apprentice account login`"
                : "sync off. `apprentice sync on` keeps your settings and projects in your own private GitHub repos"
        }
        var out = ["sync on · github.com/\(Account.profile?.login ?? "?")/\(repoName) and one repo per project · every \(Int(everySeconds / 60)) min"]
        if isRepo(dir) {
            let waiting = ahead(in: dir, of: "origin/main")
            let changed = git(["status", "--porcelain"]).out.split(separator: "\n").count
            out.append(waiting + changed == 0 ? "settings up to date" : "settings: \(waiting) commit(s) to send, \(changed) file(s) changed since")
        }
        return (out + lines(loadStatus())).joined(separator: "\n")
    }

    static func lines(_ s: Status) -> [String] {
        var out: [String] = []
        if let at = s.pushedAt {
            out.append("settings last sent " + RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: at), relativeTo: Date()))
        }
        if let e = s.error { out.append("⚠ \(e)") }
        for (path, why) in s.refused.sorted(by: { $0.key < $1.key }) { out.append("⚠ \(path) not sent: \(why)") }
        if !s.kept.isEmpty { out.append("⚠ clashed with the repo, kept this Mac's copy: \(s.kept.joined(separator: ", "))") }
        if let to = s.restoredTo { out.append("brought in your settings from the repo; this Mac's old copies are in \(to)") }
        for (name, what) in s.projects.sorted(by: { $0.key < $1.key }) { out.append("project \(name): \(what)") }
        return out
    }
}
