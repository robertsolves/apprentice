import Foundation

/// A project's own `.apprentice/` folder, found from the caller's working directory upwards (or
/// `APPRENTICE_PROJECT`). It keeps that project's site counts in `limits.json` and, optionally, tighter
/// caps in `budgets.json`. It only ever adds limits: the account-wide counts and caps in `~/.apprentice`
/// always apply as well, since a site sees one account, whichever project drives it.
enum Project {
    /// The caller's project folder (its `.apprentice/` inside), sent with each request; the daemon sets
    /// it per command.
    static var dir: URL? = find()

    static func find(from start: String = FileManager.default.currentDirectoryPath) -> URL? {
        let env = ProcessInfo.processInfo.environment["APPRENTICE_PROJECT"] ?? ""
        if env == "off" { return nil }
        let fm = FileManager.default
        if !env.isEmpty {
            let root = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
            return root.lastPathComponent == ".apprentice" ? root : root.appendingPathComponent(".apprentice")
        }
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        var url = URL(fileURLWithPath: start).standardizedFileURL
        // Up to, not including, the home folder: ~/.apprentice is the account-wide one.
        while url.path != "/", url.path != home {
            let candidate = url.appendingPathComponent(".apprentice")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue,
               candidate.standardizedFileURL.path != Store.dir.standardizedFileURL.path {
                return candidate
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// Reads, changes and writes the project's limits under its own lock.
    @discardableResult
    static func update<T>(_ dir: URL, _ body: (inout Limits) throws -> T) rethrows -> T {
        let file = dir.appendingPathComponent("limits.json")
        let fd = open(dir.appendingPathComponent("limits.json.lock").path, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        var l = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Limits.self, from: $0) } ?? Limits()
        let result = try body(&l)
        if let data = try? JSONEncoder().encode(l) { try? data.write(to: file, options: .atomic) }
        return result
    }

    static func limits(_ dir: URL) -> Limits {
        (try? Data(contentsOf: dir.appendingPathComponent("limits.json"))).flatMap { try? JSONDecoder().decode(Limits.self, from: $0) } ?? Limits()
    }

    /// `project [init | status]`.
    static func command(_ a: Args) throws -> String {
        switch a.pos.first ?? "status" {
        case "init":
            let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".apprentice")
            guard here.standardizedFileURL.path != Store.dir.standardizedFileURL.path else { throw Fail(5, "this is the account-wide folder; run `project init` in a project") }
            try FileManager.default.createDirectory(at: here, withIntermediateDirectories: true)
            // The counts are this Mac's; the caps may be shared with the project.
            let ignore = here.appendingPathComponent(".gitignore")
            if !FileManager.default.fileExists(atPath: ignore.path) { try "limits.json\nlimits.json.lock\n".write(to: ignore, atomically: true, encoding: .utf8) }
            return "project folder \(here.path): its site counts go in limits.json (git-ignored). Add budgets.json there for caps tighter than \(Budgets.path.path); the account-wide caps still apply"
        case "status":
            guard let dir else { return "no project folder: counts and caps are account-wide in \(Store.dir.path). `apprentice project init` in a project adds one" }
            let own = FileManager.default.fileExists(atPath: dir.appendingPathComponent("budgets.json").path)
            return "project \(dir.path) · counts in limits.json · caps: " + (own ? "its own budgets.json, on top of the account-wide ones" : "the account-wide ones, counted for this project too")
        default:
            throw Fail(5, "project [init | status]")
        }
    }
}
