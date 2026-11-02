import Foundation

/// `do <flow>`: runs a flow from playbooks/flows with one approval, so the LLM only steps in when a step fails.
/// A step is a line under "## Steps" that starts with a backticked command. `#label "name"` in it is
/// resolved to an element id on the screen at that moment, and `{key}` comes from `--key value`.
/// A step of the form `sh: <command>` runs a shell command (a `tool:` flow: `gh`, `git`, `ssh`), under the
/// same one approval, unless the policy is UI only.
extension Commands {
    static func runFlow(_ a: Args) throws -> String {
        if a.has("explain") {
            let task = a.value("explain") ?? a.pos.joined(separator: " ")
            return Playbooks.explain(task, model: Store.model, session: Session.stored)
        }
        guard let name = a.pos.first else { throw Fail(5, "do <flow> [--key value ...]: list flows with `apprentice playbooks flow`") }
        guard let note = Playbooks.flow(named: name) else { throw Fail(5, "no flow \"\(name)\": find one with `apprentice playbooks \"<words>\"`") }
        var missing = Set<String>()
        let raw = Playbooks.steps(note)
        // `sh:` steps are the shell's own text: only the keys the caller passed are substituted, so `${HOME}`,
        // `awk '{print $1}'` and `{a,b}` reach the shell untouched. `real` runs; `steps` is what is shown, with
        // the values of secret-looking keys hidden so they never reach the chat or the log.
        let real = raw.map { fill($0, a.flags, &missing, onlyKnown: $0.hasPrefix("`sh:")) }
        let steps = raw.map { fill($0, a.flags, &missing, onlyKnown: $0.hasPrefix("`sh:"), hide: true) }
        guard !steps.isEmpty else { throw Fail(5, "\(note.path) has no steps") }
        guard missing.isEmpty else {
            throw Fail(5, "\(note.path) needs " + missing.sorted().map { "--\($0) \"…\"" }.joined(separator: " "))
        }
        var warn: [String] = []
        let status = note.meta["status"] ?? "draft"
        if status != "verified" { warn.append("the flow is \(status): some steps are unconfirmed") }
        let shell = real.indices.filter { shellCommand(real[$0]) != nil }
        if !shell.isEmpty, Session.stored?.uiOnly ?? Config.current.uiOnly {
            throw Fail(4, "blocked: \(note.path) runs shell commands and the policy is UI only")
        }
        for i in shell { warn.append("step \(i + 1) runs a shell command on this Mac: \(shellCommand(steps[i]) ?? "")") }
        // Steps start with a backtick, so the command is the word after it.
        let flagged = Set(steps.indices.filter { i in
            let body = steps[i].drop { $0 == "`" }
            return shell.contains(i) || Gate.matches(gateText(steps[i])) || ["upload", "choose", "key"].contains { body.hasPrefix($0) }
                || steps[i].contains("--enter") || steps[i].contains("--gate")
        })
        for i in flagged.sorted() where !shell.contains(i) { warn.append("step \(i + 1) may be irreversible: \(steps[i])") }
        try Approvals.check("run flow \(note.path) (\(steps.count) steps)",
                            details: steps.enumerated().map { "\($0.offset + 1). \($0.element)" }, warnings: warn)

        Approvals.planActive = true
        defer { Approvals.planActive = false; Approvals.planFlagged = false }
        var out = ["flow \(note.path) · \(steps.count) steps"]
        var lastResult: String?
        // A flow of shell steps alone needs no window, so a failure hands back without reading one.
        let screenless = shell.count == steps.count
        func handBack() -> String { screenless ? "" : ((try? screen()) ?? "") }
        for (i, step) in steps.enumerated() {
            let n = i + 1
            Approvals.planFlagged = flagged.contains(i)
            // A kill-switch press between steps stops the flow before the next one, shell steps included.
            if KillSwitch.tripped || KillSwitch.halted {
                // Cleared here so this message, with the steps that ran, is the one the caller gets; `halted` stays.
                KillSwitch.tripped = false
                out.append("stopped: steps \(n)…\(steps.count) were not run")
                throw Fail(6, (out + ["interrupted: " + KillSwitch.message]).joined(separator: "\n"))
            }
            if let lastResult, !shell.contains(i) { look(after: lastResult) }
            guard step.hasPrefix("`") else {
                out.append("\(n) · needs you: \(step)")
                throw Fail(5, (out + [handBack()]).joined(separator: "\n"))
            }
            if let command = shellCommand(real[i]) {
                let r = runShell(command)
                guard r.code == 0 else {
                    out.append("\(n) ✗ \(step) → exit \(r.code): \(r.out.split(separator: "\n").last ?? "")")
                    out.append("stopped: steps \(n)…\(steps.count) were not run. Take over from here:")
                    throw Fail(5, (out + [handBack()]).joined(separator: "\n"))
                }
                Store.log(["cmd": "sh", "flow": note.path, "code": 0])
                lastResult = r.out
                out.append("\(n) ✓ \(step)" + (r.out.isEmpty ? "" : "\n" + r.out.split(separator: "\n").prefix(8).map { "    \($0)" }.joined(separator: "\n")))
                continue
            }
            do {
                // Split first, fill after, so a value with a space stays one argument (D4).
                var ignored = Set<String>()
                var tokens = try tokenize(String(raw[i].dropFirst().prefix { $0 != "`" })).map { fill($0, a.flags, &ignored) }
                guard !tokens.isEmpty, tokens[0] != "do" else { throw Fail(5, "bad step") }
                tokens = try resolveRefs(tokens)
                let cmd = tokens.removeFirst()
                // Steps skip `run`, so the user's return in away mode is checked before each one.
                try Away.yieldIfPresent(cmd)
                let result = try dispatch(Request(cmd: cmd, args: tokens))
                lastResult = result
                out.append("\(n) ✓ \(step) → \(result.split(separator: "\n").first ?? "")")
            } catch let amb as Ambiguous {
                // The matches are listed in full; their ids are those of the snapshot just saved, so no re-read.
                out.append("\(n) ✗ \(step) → several matches")
                out.append("stopped: steps \(n)…\(steps.count) were not run. Take over from here:")
                throw Fail(5, (out + [amb.message]).joined(separator: "\n"))
            } catch let f as Fail where f.code == 8 {
                // The step showed a warning the plan did not: it is proposed on its own.
                out.append("\(n) ⚠ \(step) needs its own approval: it shows something the plan did not")
                out.append(f.message)
                out.append("stopped: steps \(n)…\(steps.count) were not run. Approve or confirm this step, then take over from step \(n + 1).")
                throw Fail(8, out.joined(separator: "\n"))
            } catch let f as Fail {
                out.append("\(n) ✗ \(step) → \(f.message.split(separator: "\n").first ?? "")")
                out.append("stopped: steps \(n)…\(steps.count) were not run. Take over from here:")
                throw Fail(f.code, (out + [handBack()]).joined(separator: "\n"))
            }
        }
        if let learned = Routes.learn(from: note, model: Store.model) { out.append(learned) }
        out.append("done · if anything needed fixing, update \(note.path)")
        return out.joined(separator: "\n")
    }

    /// The command of a `sh: …` step, or nil for a screen step.
    /// The part of a step the gate words are matched against: nothing for a step that only looks or
    /// scrolls, the menu path for `menu`, the elements' names where it names them, else the whole step.
    /// A post's text in `scroll --in #text "…an update…"` is not an irreversible step.
    static func gateText(_ step: String) -> String {
        let body = String(step.drop { $0 == "`" }.prefix { $0 != "`" })
        guard let words = try? tokenize(body), let cmd = words.first else { return step }
        if ["scroll", "browse", "hover", "wait-for", "read", "look", "shot", "ocr", "find"].contains(cmd) { return "" }
        if cmd == "menu" { return words.dropFirst().joined(separator: " ") }
        let names = words.indices.dropFirst().filter { words[$0 - 1].hasPrefix("#") }.map { words[$0] }
        return names.isEmpty ? body : names.joined(separator: " ")
    }

    static func shellCommand(_ step: String) -> String? {
        guard step.hasPrefix("`sh:") else { return nil }
        return String(step.dropFirst(4).prefix { $0 != "`" }).trimmingCharacters(in: .whitespaces)
    }

    /// Runs one step in the user's login shell, in their home folder, for at most `[flow] sh_timeout_s` (two minutes by default).
    static func runShell(_ command: String) -> (code: Int32, out: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", command]
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        proc.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return (127, "\(error)") }
        let timer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + Config.current.flowShellSeconds, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        timer.cancel()
        return (proc.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
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
    /// It is a read: a page that changed without apprentice (the exit 2 that stopped the flow) is taken in
    /// and shown, so the caller decides on what is there now instead of getting no screen back.
    private static func screen() throws -> String {
        Approvals.request = Request(cmd: "read")
        let (_, target, _) = try prepare()
        let snap = readSnapshot(target)
        SnapStore.save(snap)
        return "<screen>\n" + snap.elements.prefix(40).map(\.line).joined(separator: "\n") + "\n</screen>"
    }

    /// Several elements fit a `#label "name"`: the caller picks one, from the list in `message`.
    private struct Ambiguous: Error { let message: String }

    /// `#button` followed by a name becomes the id of the one such element on screen now.
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
                // Exact names first, then names that contain the words. Several matches are the caller's
                // choice, never a guess, as with `click --on`: they come back to pick from.
                let exact = same.filter { $0.name.lowercased() == name }
                let hits = exact.isEmpty ? same.filter { !name.isEmpty && $0.name.lowercased().contains(name) } : exact
                if hits.count > 1 {
                    throw Ambiguous(message: "\(hits.count) elements match \(label) \"\(tokens[i + 1])\", so the step was not run. Pick one by id:\n"
                        + hits.prefix(12).map(\.line).joined(separator: "\n"))
                }
                guard let hit = hits.first else {
                    throw Fail(5, "no \(label) \"\(tokens[i + 1])\" on screen")
                }
                // A near match must not do more than the step says: "Save" never becomes "Save and send".
                guard Gate.wordsIn(hit.name).isSubset(of: Gate.wordsIn(name)) else {
                    throw Fail(5, "no \(label) \"\(tokens[i + 1])\" on screen; the closest, \(label) \"\(hit.name)\", may do more than the step says")
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

    static func fill(_ step: String, _ vars: [String: String], _ missing: inout Set<String>,
                     onlyKnown: Bool = false, hide: Bool = false) -> String {
        var s = step
        var skip = 0  // characters already passed over (braces that are not placeholders)
        // A value that brings its own placeholder back would substitute for ever and wedge the
        // daemon; the count bounds that, and anything left stays visible as a marker.
        for _ in 0..<200 {
            guard let open = s.range(of: "{", range: s.index(s.startIndex, offsetBy: min(skip, s.count))..<s.endIndex),
                  let close = s.range(of: "}", range: open.upperBound..<s.endIndex) else { break }
            let key = s[open.upperBound..<close.lowerBound].lowercased().replacingOccurrences(of: " ", with: "-")
            let dollar = open.lowerBound > s.startIndex && s[s.index(before: open.lowerBound)] == "$"
            guard let value = vars[key], !dollar else {
                // A brace the caller gave no value for is shell text in an `sh:` step, a missing variable elsewhere.
                if onlyKnown || dollar { skip = s.distance(from: s.startIndex, to: close.upperBound); continue }
                missing.insert(key)
                s.replaceSubrange(open.lowerBound..<close.upperBound, with: "‹\(key)›")
                continue
            }
            let secret = hide && ["password", "token", "secret"].contains { key.contains($0) }
            s.replaceSubrange(open.lowerBound..<close.upperBound, with: secret ? "‹hidden›" : value)
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
