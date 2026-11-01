import Foundation

/// `do <flow>`: runs a flow from notes/flows with one approval, so the LLM only steps in when a step fails.
/// A step is a line under "## Steps" that starts with a backticked command. `#label "name"` in it is
/// resolved to an element id on the screen at that moment, and `{key}` comes from `--key value`.
extension Commands {
    static func runFlow(_ a: Args) throws -> String {
        guard let name = a.pos.first else { throw Fail(5, "do <flow> [--key value ...]: list flows with `apprentice notes flow`") }
        guard let note = Notes.flow(named: name) else { throw Fail(5, "no flow \"\(name)\": find one with `apprentice notes \"<words>\"`") }
        var missing = Set<String>()
        let raw = Notes.steps(note)
        let steps = raw.map { fill($0, a.flags, &missing) }
        guard !steps.isEmpty else { throw Fail(5, "\(note.path) has no steps") }
        guard missing.isEmpty else {
            throw Fail(5, "\(note.path) needs " + missing.sorted().map { "--\($0) \"…\"" }.joined(separator: " "))
        }
        var warn: [String] = []
        let status = note.meta["status"] ?? "draft"
        if status != "verified" { warn.append("the flow is \(status): some steps are unconfirmed") }
        for (i, step) in steps.enumerated() where Gate.matches(step) || step.hasPrefix("upload") || step.hasPrefix("choose") {
            warn.append("step \(i + 1) may be irreversible: \(step)")
        }
        try Approvals.check("run flow \(note.path) (\(steps.count) steps)",
                            details: steps.enumerated().map { "\($0.offset + 1). \($0.element)" }, warnings: warn)

        Approvals.planActive = true
        defer { Approvals.planActive = false }
        var out = ["flow \(note.path) · \(steps.count) steps"]
        var lastResult: String?
        for (i, step) in steps.enumerated() {
            let n = i + 1
            if let lastResult { look(after: lastResult) }
            guard step.hasPrefix("`") else {
                out.append("\(n) · needs you: \(step)")
                throw Fail(5, (out + [try screen()]).joined(separator: "\n"))
            }
            do {
                // Split first, fill after, so a value with a space stays one argument (D4).
                var ignored = Set<String>()
                var tokens = try tokenize(String(raw[i].dropFirst().prefix { $0 != "`" })).map { fill($0, a.flags, &ignored) }
                guard !tokens.isEmpty, tokens[0] != "do" else { throw Fail(5, "bad step") }
                tokens = try resolveRefs(tokens)
                let cmd = tokens.removeFirst()
                let result = try dispatch(Request(cmd: cmd, args: tokens))
                lastResult = result
                out.append("\(n) ✓ \(step) → \(result.split(separator: "\n").first ?? "")")
            } catch let f as Fail {
                out.append("\(n) ✗ \(step) → \(f.message.split(separator: "\n").first ?? "")")
                out.append("stopped: steps \(n)…\(steps.count) were not run. Take over from here:")
                throw Fail(f.code == 8 ? 5 : f.code, (out + [(try? screen()) ?? ""]).joined(separator: "\n"))
            }
        }
        out.append("done · if anything needed fixing, update \(note.path)")
        return out.joined(separator: "\n")
    }

    /// A person's pause between steps, longer when the last one brought more onto the screen. Long
    /// pauses drift the pointer as `dwell` does. Fast-paced apps (`mode = "fast"`) skip it.
    private static func look(after result: String) {
        guard Config.current.pace.mode != "fast", !KillSwitch.tripped else { return }
        let added = result.split(separator: "\n").filter { $0.hasPrefix("+ ") }.count
        let gap = Pace.lookGap(newLines: added)
        Timing.measure("gap") {
            guard gap >= 2 else { return Pace.sleep(gap) }
            if Session.stored?.vm == true {
                if (try? Remote.act { Mouse.linger(gap) }) == nil { Pace.sleep(gap) }
            } else {
                Mouse.linger(gap)
            }
        }
    }

    /// The current screen, saved as the snapshot later ids refer to.
    private static func screen() throws -> String {
        let (_, target, _) = try prepare()
        let snap = readSnapshot(target)
        SnapStore.save(snap)
        return "<screen>\n" + snap.elements.prefix(40).map(\.line).joined(separator: "\n") + "\n</screen>"
    }

    /// `#button` followed by a name becomes the id of the first such element on screen now.
    private static func resolveRefs(_ tokens: [String]) throws -> [String] {
        guard tokens.contains(where: { $0.hasPrefix("#") }) else { return tokens }
        let (session, target, _) = try prepare()
        let snap = readSnapshot(target)
        SnapStore.save(snap)
        SnapshotCache.put(session.wid, snap)
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t.hasPrefix("#"), t.count > 1 {
                // `#label` always takes the next word as the name; a flag or nothing there is an error (D5).
                guard i + 1 < tokens.count, !tokens[i + 1].hasPrefix("--") else {
                    throw Fail(5, "\(t) needs an element name after it, such as \(t) \"Save\"")
                }
                let label = String(t.dropFirst()), name = tokens[i + 1].lowercased()
                let same = snap.elements.filter { $0.label == label }
                guard let hit = same.first(where: { $0.name.lowercased() == name })
                        ?? same.first(where: { !name.isEmpty && $0.name.lowercased().contains(name) }) else {
                    throw Fail(5, "no \(label) \"\(tokens[i + 1])\" on screen")
                }
                out.append(String(hit.id))
                i += 2
            } else {
                out.append(t)
                i += 1
            }
        }
        return out
    }

    private static func fill(_ step: String, _ vars: [String: String], _ missing: inout Set<String>) -> String {
        var s = step
        // A value that brings its own placeholder back would substitute for ever and wedge the
        // daemon; the count bounds that, and anything left stays visible as a marker.
        for _ in 0..<200 {
            guard let open = s.range(of: "{"), let close = s.range(of: "}", range: open.upperBound..<s.endIndex) else { break }
            let key = s[open.upperBound..<close.lowerBound].lowercased().replacingOccurrences(of: " ", with: "-")
            guard let value = vars[key] else {
                missing.insert(key)
                s.replaceSubrange(open.lowerBound..<close.upperBound, with: "‹\(key)›")
                continue
            }
            s.replaceSubrange(open.lowerBound..<close.upperBound, with: value)
        }
        return s
    }

    /// Shell-like split: spaces separate, "double quotes" group, \" escapes.
    static func tokenize(_ s: String) throws -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false, started = false, escape = false
        for ch in s {
            // A backslash escapes only a quote or another backslash; elsewhere it is kept (D6).
            if escape {
                if ch != "\"" && ch != "\\" { cur.append("\\") }
                cur.append(ch)
                escape = false
                continue
            }
            if ch == "\\" { escape = true; continue }
            if ch == "\"" { quoted.toggle(); started = true; continue }
            if ch == " " && !quoted {
                if started || !cur.isEmpty { out.append(cur) }
                cur = ""; started = false
                continue
            }
            cur.append(ch)
        }
        guard !quoted else { throw Fail(5, "unclosed quote in step: \(s)") }
        if escape { cur.append("\\") }
        if started || !cur.isEmpty { out.append(cur) }
        return out
    }
}
