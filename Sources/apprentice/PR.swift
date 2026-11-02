import Foundation

/// `pr [--title t] [--draft] [--repo owner/name] [--fork remote] [--local]`: offers the clone's local
/// commits upstream as one pull request. It never pushes to `upstream` (its push URL is `no-push`) and
/// never force-pushes: the branch goes to a fork remote, then `gh pr create`. `--local` only writes the
/// body and prints the compare URL.
enum PR {
    static func run(_ a: Args) throws -> String {
        guard Repo.isGit else { throw Fail(5, "\(Repo.root.path) is not a git clone: reinstall with install.sh") }
        // The session so far is part of what the commits learned from.
        Sessions.archiveCurrent()
        let dirty = Repo.git("status", "--porcelain").out
        guard dirty.isEmpty else { throw Fail(5, "uncommitted changes; commit each with `apprentice commit \"…\"` first:\n\(dirty)") }
        let remote = Repo.upstream
        guard Repo.git("fetch", "-q", remote).code == 0 else { throw Fail(5, "could not fetch \(remote)") }
        let base = Repo.branch(remote)
        let range = "\(remote)/\(base)..HEAD"
        let subjects = Repo.git("log", "--reverse", "--format=%s", range).out.split(separator: "\n").map(String.init)
        guard !subjects.isEmpty else { return "nothing to offer: no local commits on top of \(remote)/\(base)" }
        let files = Repo.git("diff", "--name-only", "\(remote)/\(base)...HEAD").out.split(separator: "\n").map(String.init)
        let records: Set<String> = ["BUGS.md", "TODO.md"]
        guard files.contains(where: { !records.contains($0) && !$0.hasPrefix("sessions/") }) else {
            throw Fail(5, "the commits change only field reports and session copies; a PR needs a fix to review")
        }
        // A PR is public: session copies go out scrubbed only, whatever `[storage] sessions` kept locally.
        let added = Repo.git("log", "-p", "--format=", range, "--", "sessions/").out
        if added.range(of: #"(?m)^\+.*[{,]"(url|name)":"#, options: .regularExpression) != nil {
            throw Fail(5, "the commits carry full session copies (URLs, element names: [storage] sessions = \"full\"), and a PR offers only scrubbed ones. Set [storage] sessions = \"scrubbed\" in \(Config.path.path), put the fix on a branch without them (git -C \(Repo.root.path) switch -c fix/<name> \(remote)/\(base), then git cherry-pick the fix commits) and run `apprentice pr` there")
        }
        // Playbooks go out to everyone, history and all: every line the commits add is checked, not just the
        // last version, since a push carries each commit.
        let playbooks = Repo.git("log", "-p", "-U0", "--no-ext-diff", "--format=", range, "--", "playbooks/", "skills/").out
        let found = Playbooks.leaks(inPatch: playbooks)
        guard found.isEmpty else {
            throw Fail(5, "nothing was offered: the commits add playbook lines that look personal, and a PR is public:\n"
                + found.prefix(20).map { "  - \($0)" }.joined(separator: "\n")
                + "\nreplace each with a {placeholder} or a generic name, commit, then fold the commits into one so the old lines leave the history: git -C \(Repo.root.path) reset --soft \(remote)/\(base) && apprentice commit \"…\"")
        }
        let test = Repo.run(Wire.binaryPath(), ["selftest"], in: Store.dir)
        guard test.code == 0 else {
            throw Fail(5, "selftest fails, so nothing was offered:\n\(test.out.split(separator: "\n").suffix(10).joined(separator: "\n"))")
        }

        // The session copies `archive` commits ride along but do not name the change.
        let changes = subjects.filter { !$0.hasPrefix("Session ") }
        let title = a.value("title") ?? changes.first ?? subjects[0]
        var branch = Repo.git("branch", "--show-current").out
        if branch == base || branch.isEmpty {
            branch = "fix/" + Playbooks.slugify(title)
            // A branch of its own at this commit, so the PR never names the user's main.
            Repo.git("branch", "-f", branch, "HEAD")
        }
        let body = self.body(changes.isEmpty ? subjects : changes, files: files)
        let upstreamURL = Repo.git("remote", "get-url", remote).out
        let upstreamRepo = a.value("repo") ?? github(upstreamURL)

        if a.has("local") {
            let file = Store.dir.appendingPathComponent("PR.md")
            try ("# \(title)\n\n" + body).write(to: file, atomically: true, encoding: .utf8)
            var out = ["wrote \(file.path) · branch \(branch) · \(subjects.count) commit\(subjects.count == 1 ? "" : "s")"]
            if let repo = upstreamRepo { out.append("compare: https://github.com/\(repo)/compare/\(base)...\(branch) (push \(branch) to your fork first)") }
            out.append(sessionsLine(files))
            return out.filter { !$0.isEmpty }.joined(separator: "\n")
        }

        let fork = try forkRemote(a, upstreamURL: upstreamURL)
        let gh = Repo.run("gh", ["auth", "status"], in: Repo.root)
        guard gh.code != 127 else { throw Fail(5, "gh is not installed: `brew install gh`, then `gh auth login`; or `apprentice pr --local` for the body and a compare URL") }
        guard gh.code == 0 else { throw Fail(5, "gh is not signed in: run `gh auth login`, then `apprentice pr` again") }
        guard let repo = upstreamRepo else { throw Fail(5, "upstream \(upstreamURL) is not on GitHub: pass --repo owner/name, or use --local") }
        let push = Repo.git("push", "-q", fork.name, "\(branch):\(branch)")
        guard push.code == 0 else { throw Fail(5, "could not push \(branch) to \(fork.name) (nothing is force-pushed):\n\(push.out)") }
        let bodyFile = Store.dir.appendingPathComponent("PR.md")
        try body.write(to: bodyFile, atomically: true, encoding: .utf8)
        let owner = github(fork.url)?.split(separator: "/").first.map(String.init)
        var args = ["pr", "create", "--repo", repo, "--base", base, "--head", owner.map { "\($0):\(branch)" } ?? branch,
                    "--title", title, "--body-file", bodyFile.path]
        if a.has("draft") { args.append("--draft") }
        let created = Repo.run("gh", args, in: Repo.root)
        guard created.code == 0 else { throw Fail(5, "gh pr create failed:\n\(created.out)") }
        return ([created.out, sessionsLine(files)]).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func body(_ subjects: [String], files: [String]) -> String {
        var out = ["## Changes"] + subjects.map { "- \($0)" }
        // Field reports the commits name; fixed ones are deleted from BUGS.md, so the commits are the record.
        let pattern = try? NSRegularExpression(pattern: #"\bF\d+\b"#)
        let reports = Set(subjects.flatMap { s in
            (pattern?.matches(in: s, range: NSRange(s.startIndex..., in: s)) ?? []).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
        }).sorted()
        if !reports.isEmpty { out += ["", "## Field reports", reports.map { "- \($0)" }.joined(separator: "\n")] }
        let line = sessionsLine(files)
        if !line.isEmpty { out += ["", "## Sessions", line] }
        out += ["", "`apprentice selftest` passes on this branch."]
        return out.joined(separator: "\n")
    }

    /// How many session copies the PR publishes, how big, and which hosts they touch.
    static func sessionsLine(_ files: [String]) -> String {
        let sessions = files.filter { $0.hasPrefix("sessions/") }
        guard !sessions.isEmpty else { return "" }
        var bytes = 0
        var hosts = Set<String>()
        for f in sessions {
            guard let text = try? String(contentsOf: Repo.root.appendingPathComponent(f), encoding: .utf8) else { continue }
            bytes += text.utf8.count
            for row in text.split(separator: "\n") {
                if let d = row.data(using: .utf8), let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let h = r["host"] as? String { hosts.insert(h) }
            }
        }
        return "publishes \(sessions.count) session cop\(sessions.count == 1 ? "y" : "ies") (\(bytes / 1024 + 1) KB, [storage] sessions = \(Sessions.mode))"
            + (hosts.isEmpty ? "" : " touching " + hosts.sorted().joined(separator: ", "))
    }

    /// `--fork <remote>`, `APPRENTICE_FORK` (a remote name or a URL, added as `fork`), or a remote named fork.
    static func forkRemote(_ a: Args, upstreamURL: String) throws -> (name: String, url: String) {
        let remotes = Repo.git("remote").out.split(separator: "\n").map(String.init)
        var name = a.value("fork") ?? ProcessInfo.processInfo.environment["APPRENTICE_FORK"] ?? "fork"
        if !remotes.contains(name), name.contains("/") || name.contains(":") {
            let url = name
            name = "fork"
            if remotes.contains(name) { Repo.git("remote", "set-url", name, url) } else { Repo.git("remote", "add", name, url) }
        }
        guard Repo.git("remote").out.split(separator: "\n").contains(Substring(name)) else {
            throw Fail(5, "no fork remote: fork the repo on GitHub, then `git -C \(Repo.root.path) remote add fork git@github.com:<you>/apprentice.git`; or `apprentice pr --local`")
        }
        let url = Repo.git("remote", "get-url", "--push", name).out
        let same = github(url).map { $0.lowercased() } == github(upstreamURL).map { $0.lowercased() } && github(url) != nil
        guard name != Repo.upstream, url != upstreamURL, url != "no-push", !same else { throw Fail(5, "\(name) is the upstream itself; pr pushes only to a fork") }
        return (name, url)
    }

    /// owner/name from a GitHub https or ssh URL.
    static func github(_ url: String) -> String? {
        guard let range = url.range(of: "github.com[:/]", options: .regularExpression) else { return nil }
        var path = String(url[range.upperBound...])
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        let parts = path.split(separator: "/")
        return parts.count >= 2 ? "\(parts[0])/\(parts[1])" : nil
    }
}
