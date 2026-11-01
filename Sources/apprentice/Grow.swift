import Foundation

/// `grow`: what the logs say apprentice should learn next. Repeated errors are candidate code fixes,
/// questions Robert answered are candidate notes, and open field reports are fixes waiting for review.
/// Claude Code runs it at the start of work in this repo (CLAUDE.md).
enum Grow {
    static func digest(days: Int) -> String {
        let cutoff = Date().addingTimeInterval(-Double(max(days, 1)) * 86_400)
        let runs = Store.dir.appendingPathComponent("runs")
        let folders = (try? FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var errors: [String: (count: Int, example: String)] = [:]
        var asked: [String] = []
        var flows: [String: Int] = [:]
        for folder in folders {
            let date = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard date >= cutoff, let text = try? String(contentsOf: folder.appendingPathComponent("steps.jsonl"), encoding: .utf8) else { continue }
            for row in text.split(separator: "\n") {
                guard let data = row.data(using: .utf8),
                      let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let e = r["error"] as? String {
                    let first = String(e.split(separator: "\n").first ?? "")
                    // Group by the message with numbers taken out, so "window 144" and "window 7101" count together.
                    let key = "\(r["failed"] ?? "?"): " + first.replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
                    errors[key, default: (0, first)].count += 1
                }
                if let q = r["ask"] as? String { asked.append("ask: \(q)") }
                if let q = r["show"] as? String { asked.append("show: \(q)") }
                if let g = r["gate"] as? String, g.hasPrefix("run flow ") { flows[g, default: 0] += 1 }
            }
        }
        var out = ["grow · last \(days) days"]
        let top = errors.sorted { $0.value.count > $1.value.count }
        out.append(top.isEmpty ? "errors: none" : "errors (most frequent first; each repeated one is a candidate code fix):")
        out += top.prefix(10).map { "  \($0.value.count)× \($0.key)" }
        out.append(asked.isEmpty ? "questions to Robert: none" : "questions to Robert (each is a gap in the notes or the tool):")
        out += asked.suffix(10).map { "  \($0)" }
        if !flows.isEmpty {
            out.append("flows run:")
            out += flows.sorted { $0.value > $1.value }.map { "  \($0.value)× \($0.key.dropFirst("run flow ".count))" }
        }
        let bugs = Notes.bugFile
        let reports = ((try? String(contentsOf: bugs, encoding: .utf8)) ?? "").components(separatedBy: "\n")
            .filter { $0.hasPrefix("### F") }
        out.append(reports.isEmpty ? "field reports: none" : "field reports in \(bugs.path):")
        out += reports.suffix(10).map { "  \($0.dropFirst(4))" }
        out.append("next: propose code changes for the top errors and reports; turn answered questions into notes or generic features")
        return out.joined(separator: "\n")
    }
}
