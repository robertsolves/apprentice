import Foundation

/// What apprentice knows about websites, read from `agent/sites.toml` (shipped) and `~/.apprentice/sites.toml`
/// (the user's, which only adds): the social networks, which words on a control are a like, a follow or a
/// post, the words a site uses when it throttles an account or puts up a check, and the steps only the
/// user may approve. config.toml's `[sites]` and `[gate]` keys still add to or replace these per install.
enum SiteLists {
    struct Lists: Equatable {
        var social: [String] = []
        var renamed: [String: String] = [:]
        /// Kinds in the order they are tested, each with its words.
        var kinds: [Kind] = []
        var softBlock: [String] = []
        var challenge: [String] = []
        var challengePaths: [String] = []
        var userOnly: [String] = []
        var ownWindowUserOnly: [String] = []

        /// A kind with no cap of its own counts against this one: an upvote is a like.
        var countsAs: [String: String] {
            Dictionary(kinds.compactMap { k in k.countsAs.map { (k.id, $0) } }, uniquingKeysWith: { a, _ in a })
        }
    }

    struct Kind: Equatable {
        let id: String
        var countsAs: String?
        var words: [String]
    }

    static var files: [URL] { [Repo.shipped("agent/sites.toml"), Settings.dir.appendingPathComponent("sites.toml")] }

    private static var cache: (stamp: String, lists: Lists)?
    private static let lock = NSLock()

    /// The lists, re-read only when a file changed: `Budgets.kind` asks on every gated action.
    static var current: Lists {
        let files = files
        let stamp = files.map { f in
            let date = (try? FileManager.default.attributesOfItem(atPath: f.path)[.modificationDate] as? Date) ?? nil
            return "\(f.path)@\(date?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
        lock.lock()
        defer { lock.unlock() }
        if let cache, cache.stamp == stamp { return cache.lists }
        let lists = load(files)
        cache = (stamp, lists)
        return lists
    }

    /// The shipped file, then each later one added to it: a later file adds sites, words, phrases and
    /// kinds, never takes one away, so no user file can lift a social site off the careful style.
    static func load(_ files: [URL]) -> Lists {
        var out = Lists()
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let more = parse(text)
            func add(_ a: inout [String], _ b: [String]) { for x in b where !a.contains(x) { a.append(x) } }
            add(&out.social, more.social)
            out.renamed.merge(more.renamed) { old, _ in old }
            for k in more.kinds {
                if let i = out.kinds.firstIndex(where: { $0.id == k.id }) {
                    add(&out.kinds[i].words, k.words)
                    if out.kinds[i].countsAs == nil { out.kinds[i].countsAs = k.countsAs }
                } else {
                    out.kinds.append(k)
                }
            }
            add(&out.softBlock, more.softBlock)
            add(&out.challenge, more.challenge)
            add(&out.challengePaths, more.challengePaths)
            add(&out.userOnly, more.userOnly)
            add(&out.ownWindowUserOnly, more.ownWindowUserOnly)
        }
        return out
    }

    static func parse(_ text: String) -> Lists {
        let table = Toml.parse(text)
        func list(_ section: String, _ key: String) -> [String] {
            (table[section]?[key].flatMap(Toml.array) ?? []).map { $0.lowercased() }.filter { !$0.isEmpty }
        }
        var out = Lists()
        out.social = list("social", "sites")
        out.renamed = Dictionary((table["renamed"] ?? [:]).map { (Toml.unquote($0.key).lowercased(), Toml.unquote($0.value).lowercased()) },
                                 uniquingKeysWith: { a, _ in a })
        for line in text.components(separatedBy: "\n") {
            guard let h = Toml.header(line).map(Toml.canonical), h.hasPrefix("kind."), let v = table[h] else { continue }
            let id = String(h.dropFirst("kind.".count)).lowercased()
            guard !out.kinds.contains(where: { $0.id == id }) else { continue }
            let to = v["counts_as"].map(Toml.unquote).map { $0.lowercased() }
            out.kinds.append(Kind(id: id, countsAs: to?.isEmpty == false ? to : nil, words: list(h, "words")))
        }
        out.softBlock = list("phrases", "soft_block")
        out.challenge = list("phrases", "challenge")
        out.challengePaths = list("phrases", "challenge_paths")
        out.userOnly = list("gate", "user_only")
        out.ownWindowUserOnly = list("gate", "own_window_user_only")
        return out
    }

    /// What is wrong with the shipped lists. Empty ones would treat every social site as an ordinary page
    /// and miss every throttle and check, so `doctor` and `session` say so rather than carry on quietly.
    static func problems(_ lists: Lists = current) -> [String] {
        var out: [String] = []
        if lists.social.isEmpty { out.append("no social sites") }
        if lists.kinds.allSatisfy({ $0.words.isEmpty }) { out.append("no action words") }
        if lists.softBlock.isEmpty { out.append("no throttle phrases") }
        if lists.challenge.isEmpty { out.append("no check phrases") }
        if lists.userOnly.isEmpty { out.append("no user-only steps") }
        if lists.ownWindowUserOnly.isEmpty { out.append("no user-only controls for apprentice's own window") }
        let ids = Set(lists.kinds.map(\.id))
        for k in lists.kinds { if let to = k.countsAs, !ids.contains(to) { out.append("kind.\(k.id) counts as unknown kind \(to)") } }
        return out
    }
}
