import Foundation
import SQLite3

/// Word lookup that does not depend on the size of the library: SQLite FTS5 at `~/.apprentice/skills/index.sqlite`,
/// through the system library. It is a cache: deleting it is safe, `skills --reindex` rebuilds it, and it updates
/// itself from a manifest of each root's files on the first lookup after a change. Looking at one place never comes
/// here at all (`Playbooks.placePaths` opens only that place's files).
final class SkillIndex {
    static var file: URL { Skills.root.appendingPathComponent("index.sqlite") }
    private var db: OpaquePointer?
    private(set) var hasFTS = false

    struct Hit {
        var path: String
        var origin: Skills.Origin
        var title: String
        var text: String
        var count: Int
        var scope: String
    }

    init?(at url: URL = SkillIndex.file) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(db, 3000)
        run("PRAGMA journal_mode=WAL")
        run("PRAGMA synchronous=OFF")
        run("CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, stamp TEXT)")
        hasFTS = run("CREATE VIRTUAL TABLE IF NOT EXISTS items USING fts5(file UNINDEXED, path UNINDEXED, origin UNINDEXED, scope UNINDEXED, count UNINDEXED, title, tags, text)")
        // A Mac whose SQLite has no FTS5: a plain table, searched with LIKE.
        if !hasFTS { run("CREATE TABLE IF NOT EXISTS items_plain(file, path, origin, scope, count, title, tags, text)") }
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    private func run(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    private func statement(_ sql: String) -> OpaquePointer? {
        var s: OpaquePointer?
        return sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK ? s : nil
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ s: OpaquePointer?, _ i: Int32, _ text: String) { sqlite3_bind_text(s, i, text, -1, Self.transient) }

    private func column(_ s: OpaquePointer?, _ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }

    private var table: String { hasFTS ? "items" : "items_plain" }

    /// Replaces the rows of files that changed, adds new ones, removes missing ones. Stats every file, parses only those.
    func update(roots: [(Skills.Origin, URL)]) {
        var seen = Set<String>()
        var known: [String: String] = [:]
        if let s = statement("SELECT path, stamp FROM files") {
            while sqlite3_step(s) == SQLITE_ROW { known[column(s, 0)] = column(s, 1) }
            sqlite3_finalize(s)
        }
        var began = false
        func begin() { if !began { run("BEGIN"); began = true } }
        let delete = statement("DELETE FROM \(table) WHERE file = ?")
        let insert = statement("INSERT INTO \(table)(file, path, origin, scope, count, title, tags, text) VALUES (?,?,?,?,?,?,?,?)")
        let stamp = statement("INSERT OR REPLACE INTO files(path, stamp) VALUES (?,?)")
        let forget = statement("DELETE FROM files WHERE path = ?")
        defer { [delete, insert, stamp, forget].forEach { sqlite3_finalize($0) } }
        for (origin, folder) in roots {
            let root = folder.resolvingSymlinksInPath()
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for case let url as URL in walk where url.pathExtension == "md" && url.lastPathComponent != "README.md" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let mark = "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)-\(values?.fileSize ?? 0)"
                seen.insert(url.path)
                if known[url.path] == mark { continue }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                begin()
                bind(delete, 1, url.path); sqlite3_step(delete); sqlite3_reset(delete)
                let rel = String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
                let note = Playbooks.parse(text, url: url, path: rel)
                func row(_ count: Int, _ body: String) {
                    bind(insert, 1, url.path); bind(insert, 2, note.path); bind(insert, 3, origin.rawValue); bind(insert, 4, note.meta["scope"] ?? "")
                    sqlite3_bind_int(insert, 5, Int32(count))
                    bind(insert, 6, note.title); bind(insert, 7, note.meta["tags"] ?? ""); bind(insert, 8, body)
                    sqlite3_step(insert)
                    sqlite3_reset(insert)
                }
                // One row per fact, so a hit is the line that matched; a file with no facts is one row of its body.
                let facts = note.keyFacts
                if facts.isEmpty { row(0, note.body) } else { for f in facts { row(Fact.parse(f)?.count ?? 1, f) } }
                bind(stamp, 1, url.path); bind(stamp, 2, mark); sqlite3_step(stamp); sqlite3_reset(stamp)
            }
        }
        for path in known.keys where !seen.contains(path) {
            begin()
            bind(delete, 1, path); sqlite3_step(delete); sqlite3_reset(delete)
            bind(forget, 1, path); sqlite3_step(forget); sqlite3_reset(forget)
        }
        if began { run("COMMIT") }
    }

    func rebuild(roots: [(Skills.Origin, URL)]) {
        run("DELETE FROM files")
        run("DELETE FROM \(table)")
        update(roots: roots)
    }

    /// bm25 over the top 200, then how often a fact kept being true as a re-rank.
    func search(_ words: [String]) -> [Hit] {
        guard !words.isEmpty else { return [] }
        var out: [Hit] = []
        if hasFTS {
            let query = words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"" }.joined(separator: " OR ")
            guard let s = statement("SELECT path, origin, title, text, count, scope FROM items WHERE items MATCH ? ORDER BY bm25(items) LIMIT 200") else { return [] }
            defer { sqlite3_finalize(s) }
            bind(s, 1, query)
            while sqlite3_step(s) == SQLITE_ROW { out.append(hit(s)) }
        } else {
            let clause = words.map { _ in "(text LIKE ? OR title LIKE ? OR tags LIKE ?)" }.joined(separator: " OR ")
            guard let s = statement("SELECT path, origin, title, text, count, scope FROM items_plain WHERE \(clause) LIMIT 200") else { return [] }
            defer { sqlite3_finalize(s) }
            var i: Int32 = 1
            for w in words { for _ in 0..<3 { bind(s, i, "%\(w)%"); i += 1 } }
            while sqlite3_step(s) == SQLITE_ROW { out.append(hit(s)) }
        }
        return out
    }

    private func hit(_ s: OpaquePointer?) -> Hit {
        Hit(path: column(s, 0), origin: Skills.Origin(rawValue: column(s, 1)) ?? .learned, title: column(s, 2), text: column(s, 3), count: Int(sqlite3_column_int(s, 4)), scope: column(s, 5))
    }

    var rowCount: Int {
        guard let s = statement("SELECT count(*) FROM \(table)") else { return 0 }
        defer { sqlite3_finalize(s) }
        return sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int(s, 0)) : 0
    }

    /// The global roots: a project's own skills are few, so they are read directly.
    static var roots: [(Skills.Origin, URL)] { [(.yours, Skills.yoursDir), (.learned, Skills.learnedDir), (.library, SkillLibrary.folder), (.builtIn, Playbooks.dir)] }
}

/// A shared library of learned facts, read per place over https, labelled as unreviewed hints. Off until
/// `[skills] library` names a base URL. It never holds anything of the user's: `share --library` offers only facts
/// confirmed twice here that pass the same checks as everything shared.
enum SkillLibrary {
    static var folder: URL { Skills.root.appendingPathComponent("library") }
    static var bases: [String] {
        guard let raw = Skills.settings["library"] else { return [] }
        return Toml.array(raw) ?? [Toml.unquote(raw)].filter { !$0.isEmpty }
    }

    /// The library's layout: sharded by first letter, since a folder of a hundred thousand files is slow.
    static func remotePath(_ rel: String) -> String {
        let parts = rel.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let first = parts[1].first else { return rel }
        return "\(parts[0])/\(first)/\(parts[1])"
    }

    /// One fetched file: read only if it passes the personal-details and step checks, so a bad upload never reaches an agent.
    static func acceptable(_ text: String) -> Bool {
        guard Playbooks.leaks(text, identity: []).isEmpty else { return false }
        let note = Playbooks.parse(text, url: URL(fileURLWithPath: "/x.md"), path: "x.md")
        return !note.keyFacts.contains { Fact.parse($0).map { Fact.refusal($0.text) != nil } ?? (Fact.refusal($0) != nil) }
    }

    /// The first `session` at a place fetches it in the background, with an ETag: the session never waits on it, and
    /// late facts show on the next command.
    static func fetchInBackground(_ rels: [String], session: URLSession = .shared) {
        guard !bases.isEmpty else { return }
        for rel in rels {
            for base in bases {
                guard let url = URL(string: base.hasSuffix("/") ? base + remotePath(rel) : base + "/" + remotePath(rel)) else { continue }
                let local = folder.appendingPathComponent(rel)
                let tag = local.appendingPathExtension("etag")
                var request = URLRequest(url: url, timeoutInterval: 3)
                if let etag = try? String(contentsOf: tag, encoding: .utf8) { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
                session.dataTask(with: request) { data, response, _ in
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data, let text = String(data: data, encoding: .utf8), acceptable(text) else { return }
                    try? FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? text.write(to: local, atomically: true, encoding: .utf8)
                    if let etag = http.value(forHTTPHeaderField: "ETag") { try? etag.write(to: tag, atomically: true, encoding: .utf8) }
                }.resume()
            }
        }
    }

    static func facts(for target: String) -> [Fact] {
        let (url, _, _) = Skills.factFile(for: target)
        guard url.path.hasPrefix(Skills.learnedDir.path) else { return [] }
        let rel = String(url.path.dropFirst(Skills.learnedDir.path.count + 1))
        return Skills.facts(in: folder.appendingPathComponent(rel))
    }

    /// Every learned fact worth offering: confirmed at least twice, and past every check.
    static func offer(from root: URL = Skills.learnedDir) -> [String: [Fact]] {
        var out: [String: [Fact]] = [:]
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return out }
        for case let url as URL in walk where url.pathExtension == "md" && !url.path.contains("/flows/") {
            let rel = String(url.resolvingSymlinksInPath().path.dropFirst(root.resolvingSymlinksInPath().path.count + 1))
            let good = Skills.facts(in: url).filter { f in
                f.count >= 2 && Playbooks.leaks(f.text).isEmpty && Fact.refusal(f.text) == nil && !f.text.contains("(job?)")
            }
            if !good.isEmpty { out[rel] = good }
        }
        return out
    }

    /// `skills share --library`: a pull request against the library's repo, through the user's GitHub CLI and a fork.
    static func share() throws -> String {
        guard let repo = Skills.settings["library_repo"].map(Toml.unquote), !repo.isEmpty else {
            throw Fail(5, "no library to share with: set [skills] library_repo = \"owner/repo\" once one exists")
        }
        let offers = offer()
        guard !offers.isEmpty else { return "nothing to offer: only facts confirmed at least twice here are shared" }
        guard Repo.run("gh", ["auth", "status"]).code == 0 else { throw Fail(5, "the GitHub CLI is not signed in: gh auth login") }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("apprentice-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let fork = Repo.run("gh", ["repo", "fork", repo, "--clone", "--default-branch-only", "--", "--depth=1", "lib"], in: work)
        guard fork.code == 0 else { throw Fail(5, "could not fork \(repo): \(fork.out)") }
        let lib = work.appendingPathComponent("lib")
        let branch = "facts-\(Store.day())-\(UUID().uuidString.prefix(6).lowercased())"
        _ = Repo.run("git", ["checkout", "-q", "-b", branch], in: lib)
        for (rel, facts) in offers {
            let target = lib.appendingPathComponent(remotePath(rel))
            var known = Skills.facts(in: target)
            for f in facts where !known.contains(where: { $0.key == f.key }) { known.append(f) }
            let match = URL(fileURLWithPath: rel).deletingPathExtension().lastPathComponent
            try Skills.saveFacts(known, at: target, scope: rel.hasPrefix("web/") ? "site" : "app", match: match)
        }
        _ = Repo.run("git", ["add", "-A"], in: lib)
        let done = Repo.run("git", ["commit", "-q", "-m", "Facts confirmed on one install"], in: lib)
        guard done.code == 0 else { return "nothing new to offer" }
        let push = Repo.run("git", ["push", "-q", "-u", "origin", branch], in: lib)
        guard push.code == 0 else { throw Fail(5, "could not push: \(push.out)") }
        let pr = Repo.run("gh", ["pr", "create", "--repo", repo, "--fill", "--head", branch], in: lib)
        guard pr.code == 0 else { throw Fail(5, "could not open the pull request: \(pr.out)") }
        return "offered \(offers.values.map(\.count).reduce(0, +)) facts: \(pr.out)"
    }
}
