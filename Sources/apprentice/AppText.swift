import Foundation

/// The window's own words, read from `agent/app-text.toml` (shipped) and `~/.apprentice/app-text.toml` (the
/// user's, whose keys replace the shipped ones one by one): each sidebar section's name, icon and order, and
/// the explainer that says what its screen is for.
enum AppText {
    struct Screen: Equatable {
        var label = ""
        var icon = ""
        var explainerTitle = ""
        var about = ""
        var points: [String] = []
    }

    static var files: [URL] { [Repo.shipped("agent/app-text.toml"), Settings.dir.appendingPathComponent("app-text.toml")] }

    private static var cache: (stamp: String, screens: [(id: String, screen: Screen)])?

    /// The sections in the order written, re-read only when a file changed: the sidebar asks on every draw.
    static var screens: [(id: String, screen: Screen)] {
        let files = files
        let stamp = files.map { f in
            let date = (try? FileManager.default.attributesOfItem(atPath: f.path)[.modificationDate] as? Date) ?? nil
            return "\(f.path)@\(date?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
        if let cache, cache.stamp == stamp { return cache.screens }
        let screens = load(files)
        cache = (stamp, screens)
        return screens
    }

    static func screen(_ id: String) -> Screen { screens.first { $0.id == id }?.screen ?? Screen(label: id) }

    static func load(_ files: [URL]) -> [(id: String, screen: Screen)] {
        var out: [(id: String, screen: Screen)] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let table = Toml.parse(text)
            for line in text.components(separatedBy: "\n") {
                guard let h = Toml.header(line).map(Toml.canonical), h.hasPrefix("section."), let v = table[h] else { continue }
                let id = String(h.dropFirst("section.".count))
                var s = out.first { $0.id == id }?.screen ?? Screen()
                if let x = v["label"] { s.label = Toml.unquote(x) }
                if let x = v["icon"] { s.icon = Toml.unquote(x) }
                if let x = v["explainer_title"] { s.explainerTitle = Toml.unquote(x) }
                if let x = v["about"] { s.about = Toml.unquote(x) }
                if let x = v["points"].flatMap(Toml.array) { s.points = x }
                if let i = out.firstIndex(where: { $0.id == id }) { out[i].screen = s } else { out.append((id, s)) }
            }
        }
        return out
    }

    /// What is wrong with the shipped words for `ids`, so a typo shows in `selftest` rather than as a blank.
    static func problems(_ screens: [(id: String, screen: Screen)], ids: [String]) -> [String] {
        ids.flatMap { id -> [String] in
            guard let s = screens.first(where: { $0.id == id })?.screen else { return ["section.\(id) is missing"] }
            return [("label", s.label), ("icon", s.icon), ("explainer_title", s.explainerTitle), ("about", s.about)]
                .filter { $0.1.isEmpty }.map { "section.\(id).\($0.0) is empty" }
        }
    }
}
