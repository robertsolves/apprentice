import Foundation

/// What `kit.sh` installed: the clone it built from and that clone's commit, in `~/.apprentice/install.json`.
/// It names the clone without going through the notes link, and tells an updated build from an old one.
enum Build {
    static let number = "0.1.0"

    struct Install: Codable {
        var clone: String
        var commit: String
        var built: String?
        var bin: String?
    }

    static var install: Install? { Store.load(Install.self, "install.json") }

    /// `0.1.0 (a1b2c3d)` for the installed binary; a build run from elsewhere says so.
    static var version: String {
        guard let i = install else { return number }
        if let bin = i.bin, URL(fileURLWithPath: bin).standardizedFileURL.path != URL(fileURLWithPath: Wire.binaryPath()).standardizedFileURL.path {
            return "\(number) (dev build; installed: \(i.commit))"
        }
        return "\(number) (\(i.commit))"
    }
}
