import Foundation

struct RouteEntry {
    var domain: String
    var label: String
    var keywords: [String]
    var faster: String
    var remaining: String?
}

enum Routes {
    static let defaults: [RouteEntry] = [
        RouteEntry(domain: "github.com", label: "github",
                   keywords: ["github", "gh", "bio", "repo", "repository", "issue", "pull request", "pr", "gist", "release", "star"],
                   faster: "gh api / gh repo / gh issue / gh pr", remaining: "avatar upload and settings pages with no endpoint"),
        RouteEntry(domain: "gmail.com", label: "email",
                   keywords: ["gmail", "email", "mail", "inbox", "message"],
                   faster: "Gmail connector (search, read, send, label)", remaining: "settings and unusual attachment formats"),
        RouteEntry(domain: "calendar.google.com", label: "calendar",
                   keywords: ["calendar", "event", "meeting", "schedule", "invite"],
                   faster: "Google Calendar connector (list, create, move)", remaining: "guest-facing confirmations"),
        RouteEntry(domain: "drive.google.com", label: "drive",
                   keywords: ["drive", "document", "spreadsheet", "sheet", "slide"],
                   faster: "Google Drive connector (list, read, create)", remaining: "local uploads and share dialogs"),
        RouteEntry(domain: "linear.app", label: "linear",
                   keywords: ["linear", "ticket", "sprint", "backlog"],
                   faster: "Linear API or connector", remaining: nil),
        RouteEntry(domain: "slack.com", label: "slack",
                   keywords: ["slack", "channel", "dm", "thread"],
                   faster: "Slack API or connector", remaining: nil),
    ]

    static var customPath: URL { Store.dir.appendingPathComponent("routes.toml") }

    static func custom() -> [RouteEntry] {
        guard let text = try? String(contentsOf: customPath, encoding: .utf8) else { return [] }
        var out: [RouteEntry] = []
        var current: [String: String] = [:]
        func flush() {
            guard let domain = current["domain"], let label = current["label"] else { current = [:]; return }
            let words = current["keywords"].map(Toml.array)?.flatMap { $0 } ?? []
            out.append(RouteEntry(domain: Toml.unquote(domain), label: Toml.unquote(label), keywords: words,
                                  faster: Toml.unquote(current["faster"] ?? ""),
                                  remaining: current["remaining"].map(Toml.unquote)))
            current = [:]
        }
        for raw in text.components(separatedBy: .newlines) {
            // Same comment rules as config.toml, so a trailing "# note" never lands in a value (D2).
            let line = Toml.stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "[[route]]" { flush(); continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            current[key] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        flush()
        return out
    }

    static func all() -> [RouteEntry] { defaults + custom() }

    /// Keywords match whole words (or whole phrases), so "pr" does not match "improve" (B10).
    static func match(_ task: String) -> [RouteEntry] {
        let text = task.lowercased()
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let padded = " " + words.joined(separator: " ") + " "
        return all().filter { entry in
            text.contains(entry.domain) || entry.keywords.contains { padded.contains(" " + $0.lowercased() + " ") }
        }
    }

    static func hints(for domain: String?) -> [RouteEntry] {
        guard let domain else { return [] }
        return all().filter { domain == $0.domain || domain.hasSuffix("." + $0.domain) }
    }

    static func answer(_ task: String) -> String {
        let matches = match(task)
        var lines = ["route · \"\(task)\""]
        if matches.isEmpty {
            lines.append("no faster route: use screen control")
            return lines.joined(separator: "\n")
        }
        for m in matches {
            let remaining = m.remaining.map { " (screen still needed: \($0))" } ?? ""
            lines.append("\(m.label) → \(m.faster)\(remaining)")
        }
        return lines.joined(separator: "\n")
    }

    static func hintLines(for domain: String?) -> [String] {
        hints(for: domain).map { h in
            let tail = h.remaining.map { " · screen: \($0)" } ?? ""
            return "hint: \(h.domain) has a faster route: \(h.faster)\(tail)"
        }
    }
}
