import Foundation

/// `apprentice help`: what apprentice is, and every command, from one source (`agent/commands.toml`), which the slash
/// commands a project is given, the MCP tools' descriptions and the usage text read too.
enum Help {
    struct Entry {
        var name: String
        var group: String
        var usage: String
        var summary: String
        var flags: [String] = []
        var output = ""
        var exits: [String] = []
        var place = ""
        var tokens: String? = nil
        var changes: String? = nil
        var screen = false
        var approval = false
        var example = ""
        var exampleOutput = ""
        var mcp: String? = nil
        var slash: [String] = []
        var aliases: [String] = []
        var hidden = false
    }

    struct Book {
        var about = ""
        var notes: [String] = []
        var exits: [Int: String] = [:]
        var entries: [Entry] = []
    }

    static var file: URL { Repo.shipped("agent/commands.toml") }

    static func parse(_ text: String) -> Book {
        let table = Toml.parse(text)
        var book = Book()
        book.about = table["help"]?["about"].map(Toml.unquote) ?? ""
        book.notes = table["help"]?["notes"].flatMap(Toml.array) ?? []
        for (k, v) in table["exit"] ?? [:] { if let code = Int(k) { book.exits[code] = Toml.unquote(v) } }
        var order: [String] = []
        for line in text.components(separatedBy: "\n") {
            if let h = Toml.header(line).map(Toml.canonical), h.hasPrefix("command.") {
                let name = String(h.dropFirst("command.".count))
                if !order.contains(name) { order.append(name) }
            }
        }
        book.entries = order.map { name in
            let v = table["command.\(name)"] ?? [:]
            func text(_ key: String) -> String { v[key].map(Toml.unquote) ?? "" }
            func opt(_ key: String) -> String? { v[key].map(Toml.unquote).flatMap { $0.isEmpty ? nil : $0 } }
            func list(_ key: String) -> [String] { v[key].flatMap(Toml.array) ?? [] }
            func flag(_ key: String) -> Bool { v[key].map(Toml.unquote) == "true" }
            return Entry(name: name, group: text("group"), usage: text("usage"), summary: text("summary"), flags: list("flags"), output: text("output"),
                         exits: list("exits"), place: text("where"), tokens: opt("tokens"), changes: opt("changes"), screen: flag("screen"), approval: flag("approval"),
                         example: text("example"), exampleOutput: text("example_output"), mcp: opt("mcp"), slash: list("slash"), aliases: list("aliases"), hidden: flag("hidden"))
        }
        return book
    }

    private static let bookLock = NSLock()
    private static var cached: Book?

    static var book: Book {
        bookLock.lock()
        defer { bookLock.unlock() }
        if let cached { return cached }
        let b = parse((try? String(contentsOf: file, encoding: .utf8)) ?? "")
        cached = b
        return b
    }

    static func entry(_ name: String, in book: Book = book) -> Entry? {
        let n = name.lowercased()
        return book.entries.first { $0.name == n || $0.aliases.contains(n) }
    }

    static func mcpDescription(_ tool: String) -> String {
        let key = tool.replacingOccurrences(of: "_", with: "-")
        guard let e = entry(key) else { return tool }
        return e.mcp ?? e.summary
    }

    /// What an agent needs to know at a glance beyond the sentence itself.
    static func traits(_ e: Entry) -> String {
        var t: [String] = []
        if let tokens = e.tokens { t.append(tokens == "yes" ? "spends tokens" : "spends tokens: \(tokens)") }
        if e.screen { t.append("takes the screen") }
        if e.approval { t.append("needs approval") }
        if let c = e.changes { t.append("changes \(c)") } else { t.append("changes nothing") }
        let codes = e.exits.compactMap { $0.split(separator: ":").first.map(String.init) }
        if !codes.isEmpty { t.append("exits " + codes.joined(separator: " ")) }
        return t.joined(separator: " · ")
    }

    static func exitLine(_ book: Book) -> String {
        "exit codes: " + book.exits.keys.sorted().map { "\($0) \(book.exits[$0] ?? "")" }.joined(separator: " · ")
    }

    /// `help`: the paragraph, then every command grouped by purpose.
    static func overview(_ book: Book = book) -> String {
        var out = ["apprentice \(version)", "", book.about, "", "`apprentice help <command>` gives the arguments, exit codes and an example; `help --all` prints everything; `help <word>` searches.", ""]
        var groups: [String] = []
        for e in book.entries where !e.hidden && !groups.contains(e.group) { groups.append(e.group) }
        for g in groups {
            out.append(g + ":")
            for e in book.entries where e.group == g && !e.hidden {
                out.append("  \(e.name): \(e.summary) [\(traits(e))]")
            }
            out.append("")
        }
        out += book.notes
        out.append(exitLine(book))
        return out.joined(separator: "\n")
    }

    static func full(_ e: Entry, book: Book = book) -> String {
        var out = ["apprentice \(e.usage)", "", e.summary, ""]
        if !e.flags.isEmpty { out += ["Flags:"] + e.flags.map { "  \($0)" } + [""] }
        out += ["Prints: \(e.output)"]
        out.append("Works: \(e.place)")
        out.append(traits(e).capitalizedFirst)
        out.append("")
        var exits = ["  0: \(book.exits[0] ?? "ok")"] + e.exits.map { "  \($0)" }
        if e.exits.isEmpty { exits.append("  5: \(book.exits[5] ?? "")") }
        out += ["Exit codes:"] + exits + [""]
        out += ["Example:", "  $ \(e.example)"] + e.exampleOutput.components(separatedBy: "\n").map { "  \($0)" }
        return out.joined(separator: "\n")
    }

    static func usageText(_ book: Book = book) -> String {
        var out = ["apprentice \(version) · text-first control of one Mac app or browser window", "", "usage:"]
        for e in book.entries where !e.hidden {
            out.append("  apprentice \(e.usage)\n      \(e.summary)")
        }
        out += [""] + book.notes + [exitLine(book)]
        return out.joined(separator: "\n")
    }

    static func command(_ a: Args) -> String {
        let book = book
        if a.has("all") {
            let visible = book.entries.filter { !$0.hidden }
            return ([overview(book)] + visible.map { "── \($0.name)\n" + full($0, book: book) }).joined(separator: "\n\n")
        }
        let word = a.pos.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return overview(book) }
        if let e = entry(word, in: book) { return full(e, book: book) }
        let w = word.lowercased()
        let hits = book.entries.filter { e in
            !e.hidden && ([e.name, e.usage, e.summary, e.output] + e.flags + e.exits).contains { $0.lowercased().contains(w) }
        }
        guard !hits.isEmpty else { return "no command mentions \(word) · apprentice help" }
        return hits.map { "\($0.name): \($0.summary) [\(traits($0))]" }.joined(separator: "\n")
    }

    // MARK: - self-test

    /// Every command the source dispatches, read from the source when it is here (not in the DMG's app).
    static func dispatched(sources: URL) -> Set<String>? {
        guard let main = try? String(contentsOf: sources.appendingPathComponent("main.swift"), encoding: .utf8),
              let commands = try? String(contentsOf: sources.appendingPathComponent("Commands.swift"), encoding: .utf8) else { return nil }
        var names = Set<String>()
        func found(_ line: String) {
            for piece in line.components(separatedBy: "\"").enumerated() where piece.offset % 2 == 1 { names.insert(piece.element) }
        }
        for line in main.components(separatedBy: "\n") where line.hasPrefix("case \"") {
            let head = line.prefix { $0 != ":" }
            found(head.components(separatedBy: " where ").first ?? String(head))
        }
        // The two switches that dispatch daemon commands, in `Commands`.
        var inside = false
        for line in commands.components(separatedBy: "\n") {
            if line.contains("static let asides:") { found(line) }
            if line.contains("static func aside(") || line.contains("static func dispatch(") { inside = true; continue }
            if inside, line.hasPrefix("    }") { inside = false; continue }
            if inside, line.hasPrefix("        case \"") { found(String(line.prefix { $0 != ":" })) }
        }
        return names.subtracting(["--help", "-h", "--version", "-v"])
    }

    /// The problems `selftest` reports. `spec` and `docs` are SPEC.md and the agent docs, when they are here.
    static func problems(_ book: Book, dispatched: Set<String>?, spec: String?, docs: [String]) -> [String] {
        var out: [String] = []
        for e in book.entries {
            if e.summary.isEmpty || e.usage.isEmpty { out.append("\(e.name): no summary or usage") }
            guard e.example.hasPrefix("apprentice ") else { out.append("\(e.name): its example does not start with apprentice"); continue }
            let word = e.example.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            if word != e.name, !e.aliases.contains(word) { out.append("\(e.name): its example runs \(word)") }
            if e.example.filter({ $0 == "\"" }).count % 2 != 0 { out.append("\(e.name): its example has an unclosed quote") }
            for code in e.exits {
                guard let n = code.split(separator: ":").first.flatMap({ Int($0) }), book.exits[n] != nil else { out.append("\(e.name): unknown exit in \(code)"); continue }
            }
        }
        if let dispatched {
            let known = Set(book.entries.flatMap { [$0.name] + $0.aliases })
            for name in dispatched.subtracting(known) { out.append("\(name) is a command with no entry in commands.toml") }
            for e in book.entries where !dispatched.contains(e.name) && !e.aliases.contains(where: dispatched.contains) { out.append("\(e.name) has an entry and no command") }
        }
        let codes = Set(book.exits.keys)
        if let spec {
            let found = Set(spec.components(separatedBy: "\n").compactMap { line -> Int? in
                guard line.hasPrefix("| ") else { return nil }
                let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                return parts.first.flatMap(Int.init)
            })
            if !found.isEmpty, found != codes.subtracting([]) { out.append("SPEC.md's exit codes \(found.sorted()) differ from commands.toml's \(codes.sorted())") }
        }
        for doc in docs {
            guard let line = doc.components(separatedBy: "\n").first(where: { $0.hasPrefix("Exit codes:") }) else { continue }
            let found = Set(line.dropFirst("Exit codes:".count).components(separatedBy: "·").compactMap { $0.trimmingCharacters(in: .whitespaces).split(separator: " ").first.flatMap { Int($0) } })
            if found != codes { out.append("an agent doc's exit codes \(found.sorted()) differ from commands.toml's \(codes.sorted())") }
        }
        return out
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
