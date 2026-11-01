import Foundation

/// Where the user's settings (config.toml, routes.toml, budgets.json) live: ~/.apprentice, on this Mac only.
/// An older install may still keep them in ~/.apprentice/settings, a clone it once synced with GitHub; they
/// are read from there until `settings local` moves them back. Session state, logs and screenshots never
/// leave the Mac.
enum Settings {
    static let files = ["config.toml", "routes.toml", "budgets.json"]
    static var repoDir: URL { Store.dir.appendingPathComponent("settings") }
    static var synced: Bool { FileManager.default.fileExists(atPath: repoDir.appendingPathComponent(".git").path) }
    static var dir: URL { synced ? repoDir : Store.dir }

    /// `settings [local]`. The user's command; agents never run it.
    static func run(_ a: Args) throws -> String {
        switch a.pos.first ?? "" {
        case "": return status()
        case "local": return try local()
        default: throw Fail(5, "settings [local]")
        }
    }

    static func status() -> String {
        synced ? "settings: in \(repoDir.path), from an older install that synced them; `apprentice settings local` moves them to \(Store.dir.path)"
               : "settings: \(files.joined(separator: ", ")) in \(Store.dir.path), on this Mac only"
    }

    /// Moves the settings out of the old synced clone into ~/.apprentice and removes the clone.
    static func local() throws -> String {
        guard synced else { return status() }
        let fm = FileManager.default
        for file in files where fm.fileExists(atPath: repoDir.appendingPathComponent(file).path) {
            try? fm.removeItem(at: Store.dir.appendingPathComponent(file))
            try fm.moveItem(at: repoDir.appendingPathComponent(file), to: Store.dir.appendingPathComponent(file))
        }
        try fm.removeItem(at: repoDir)
        return "settings: now in \(Store.dir.path), on this Mac only"
    }
}
