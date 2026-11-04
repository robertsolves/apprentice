import Foundation

/// `grow`: what the logs say apprentice should learn next. Repeated errors are candidate code fixes,
/// questions the user answered are candidate playbooks, and open field reports are fixes waiting for review.
/// Claude Code runs it at the start of work in this repo (CLAUDE.md).
enum Grow {
    static func digest(days: Int) -> String {
        let cutoff = Date().addingTimeInterval(-Double(max(days, 1)) * 86_400)
        var errors: [String: (count: Int, example: String)] = [:]
        var asked: [String] = []
        var flows: [String: Int] = [:]
        var learning: [String: Int] = [:]
        var models: [String: Int] = [:]
        var pace = Pace()
        var places: [String: (struggles: Int, kept: Int)] = [:]
        var envs = Set<String>()
        for folder in Sessions.folders() {
            let date = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard date >= cutoff else { continue }
            pace.previous = nil
            for r in Sessions.rows(folder) {
                pace.take(r)
                if let p = r["learned?"] as? String { places[p, default: (0, 0)].struggles += 1 }
                if let p = r["learned"] as? String, r["still"] == nil, r["wrong"] == nil { places[p, default: (0, 0)].kept += 1 }
                if let e = r["env"] as? String { envs.insert(e) }
                if let cmd = r["cmd"] as? String, ["learn", "bug", "commit", "pr", "do"].contains(cmd) { learning[cmd, default: 0] += 1 }
                if r["cmd"] != nil, let m = r["model"] as? String { models[m, default: 0] += 1 }
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
        out += pace.report()
        let top = errors.sorted { $0.value.count > $1.value.count }
        out.append(top.isEmpty ? "errors: none" : "errors (most frequent first; each repeated one is a candidate code fix):")
        out += top.prefix(10).map { "  \($0.value.count)× \($0.key)" }
        out.append(asked.isEmpty ? "questions to the user: none" : "questions to the user (each is a gap in the playbooks or the tool):")
        out += asked.suffix(10).map { "  \($0)" }
        if !learning.isEmpty {
            out.append("learning: " + learning.sorted { $0.key < $1.key }.map { "\($0.value)× \($0.key)" }.joined(separator: " · "))
        }
        if let line = Struggle.growLine(places) {
            out.append(line + (envs.count > 1 ? " · on \(envs.sorted().joined(separator: ", "))" : ""))
        }
        if !models.isEmpty {
            out.append("models: " + models.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value) commands" }.joined(separator: " · "))
        }
        if !flows.isEmpty {
            out.append("flows run:")
            out += flows.sorted { $0.value > $1.value }.map { "  \($0.value)× \($0.key.dropFirst("run flow ".count))" }
        }
        let bugs = Playbooks.bugFile
        let reports = ((try? String(contentsOf: bugs, encoding: .utf8)) ?? "").components(separatedBy: "\n")
            .filter { $0.hasPrefix("### F") }
        out.append(reports.isEmpty ? "field reports: none" : "field reports in \(bugs.path):")
        out += reports.suffix(10).map { "  \($0.dropFirst(4))" }
        out.append("next: propose code changes for the top errors and reports; turn answered questions into playbooks or generic features")
        return out.joined(separator: "\n")
    }

    /// Where a run's time went. Each action is: the agent thinks (gap from the row before to the
    /// proposal), approves (proposal → approved; 0 when both are in one shell call), the tool acts
    /// (`ms` and its `waits`), and often the agent reads again before the next step.
    struct Pace {
        static let actions: Set<String> = ["click", "type", "key", "menu", "scroll", "browse", "open", "upload", "choose", "drag", "hover", "do"]
        var previous: (ts: Date, cmd: String?)?
        var proposedAt: Date?
        var think: [Double] = []
        var approve: [Double] = []
        var tool: [Double] = []
        var waits: [String: Double] = [:]
        var measured = 0
        var count = 0
        var reads = 0

        mutating func take(_ r: [String: Any]) {
            guard let ts = (r["ts"] as? String).flatMap(Events.date) else { return }
            let cmd = r["cmd"] as? String
            defer { previous = (ts, cmd) }
            if r["proposed"] != nil {
                proposedAt = ts
                // Gaps over five minutes are the person away, not the agent thinking.
                if let p = previous { let g = ts.timeIntervalSince(p.ts); if g < 300 { think.append(g) } }
                return
            }
            if r["gate"] != nil, r["approved"] as? Bool == true, let at = proposedAt {
                approve.append(ts.timeIntervalSince(at))
                return
            }
            guard let cmd else { return }
            if cmd == "read", previous?.cmd.map(Pace.actions.contains) == true { reads += 1 }
            guard Pace.actions.contains(cmd) else { return }
            count += 1
            if proposedAt == nil, let p = previous { let g = ts.timeIntervalSince(p.ts); if g < 300 { think.append(g) } }
            if let ms = r["ms"] as? Int {
                tool.append(Double(ms) / 1000)
                measured += 1
                for (k, v) in r["waits"] as? [String: Int] ?? [:] { waits[k, default: 0] += Double(v) / 1000 }
            } else if let at = proposedAt {
                tool.append(ts.timeIntervalSince(at))
            }
            proposedAt = nil
        }

        func report() -> [String] {
            guard count > 0 else { return ["pace: no actions yet"] }
            func median(_ xs: [Double]) -> Double {
                let s = xs.sorted()
                return s.isEmpty ? 0 : s[s.count / 2]
            }
            func s(_ v: Double) -> String { String(format: "%.1f s", v) }
            var line = "pace (\(count) actions): agent thinks \(s(median(think))) before each"
            let a = median(approve)
            line += " · approve adds \(s(a))" + (a < 1 ? " (same call)" : " (own turn)")
            line += " · re-reads after \(reads * 100 / count)%"
            line += " · tool \(s(median(tool))) per action"
            if measured > 0 {
                let parts = waits.sorted { $0.value > $1.value }.map { "\($0.key) \(s($0.value / Double(measured)))" }
                if !parts.isEmpty { line += " (\(parts.joined(separator: " · ")))" }
            }
            var out = [line]
            if a >= 1 { out.append("  approvals are separate agent turns: approve in the same shell call as the command") }
            if reads * 100 / count >= 30 { out.append("  the agent re-reads after most actions: the diff after an action already lists what changed") }
            return out
        }
    }
}
