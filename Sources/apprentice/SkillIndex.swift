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

    /// `useFTS: false` is what a Mac whose SQLite has no FTS5 gets, so `selftest` can check that path too.
    init?(at url: URL = SkillIndex.file, useFTS: Bool = true) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(db, 3000)
        run("PRAGMA journal_mode=WAL")
        run("PRAGMA synchronous=OFF")
        run("CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, stamp TEXT)")
        hasFTS = useFTS && run("CREATE VIRTUAL TABLE IF NOT EXISTS items USING fts5(file UNINDEXED, path UNINDEXED, origin UNINDEXED, scope UNINDEXED, count UNINDEXED, title, tags, text)")
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
    func update(roots: [(Skills.Origin, URL)], indexFiles: [URL] = SkillLibrary.indexFiles) {
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
            // Hidden: the library's own per-base copies, which the file agents read already folds together.
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: .skipsHiddenFiles) else { continue }
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
        // The library's published index: what it knows about places never fetched here, so a search can find them.
        if roots.contains(where: { $0.0 == .library }) {
            for file in indexFiles {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let mark = "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)-\(values?.fileSize ?? 0)"
                seen.insert(file.path)
                if known[file.path] == mark { continue }
                begin()
                bind(delete, 1, file.path); sqlite3_step(delete); sqlite3_reset(delete)
                for r in SkillLibrary.rows(in: file) {
                    bind(insert, 1, file.path); bind(insert, 2, r.place); bind(insert, 3, Skills.Origin.library.rawValue); bind(insert, 4, r.place.hasPrefix("web/") ? "site" : "app")
                    sqlite3_bind_int(insert, 5, Int32(r.count))
                    bind(insert, 6, r.title); bind(insert, 7, ""); bind(insert, 8, r.line)
                    sqlite3_step(insert)
                    sqlite3_reset(insert)
                }
                bind(stamp, 1, file.path); bind(stamp, 2, mark); sqlite3_step(stamp); sqlite3_reset(stamp)
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
