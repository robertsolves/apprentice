import Foundation

/// The board: how steps of one run talk. One JSON-lines file per run, outside the worktrees, and plain shell
/// commands, so it works the same for every agent CLI. A file lock keeps simultaneous posts whole, and each step keeps
/// its own read cursor. Messages are information from another agent, never instructions, and cannot approve anything.
enum Board {
    struct Message: Codable, Equatable {
        var at: Double
        var from: String
        var agent: String?
        var to: String?
        var text: String
        /// The sender holds the screen, so its words may have come from it.
        var fromScreen: Bool?
        /// It stops the step it is for, which then starts again with this message (`interruptNote`).
        var urgent: Bool? = nil
    }

    static let maxLength = 2000

    static func file(_ run: URL) -> URL { run.appendingPathComponent("board.jsonl") }
    private static func cursor(_ run: URL, _ step: String) -> URL { run.appendingPathComponent("board-cursors/\(step)") }

    static func messages(_ run: URL) -> [Message] {
        ((try? String(contentsOf: file(run), encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
            try? JSONDecoder().decode(Message.self, from: Data($0.utf8))
        }
    }

    static func post(_ m: Message, run: URL) throws {
        guard m.text.count <= maxLength else {
            throw Fail(5, "that is \(m.text.count) characters and a message holds \(maxLength): put it in a file and post the file's path")
        }
        guard let line = try? JSONEncoder().encode(m) else { return }
        let url = file(run)
        do {
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
            try Store.locked(at: url) {
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                let h = try FileHandle(forWritingTo: url)
                defer { try? h.close() }
                _ = try h.seekToEnd()
                try h.write(contentsOf: line + Data("\n".utf8))
            }
        } catch {
            throw Fail(7, "could not write the board (\(error.localizedDescription)): at this permission level, put what others need in what you print")
        }
    }

    /// What is for this step: to everyone or to it, not its own.
    static func isFor(_ m: Message, step: String) -> Bool { m.from != step && (m.to == nil || m.to == step) }

    static func seen(run: URL, step: String) -> Int {
        ((try? String(contentsOf: cursor(run, step), encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) ?? 0
    }

    static func markSeen(run: URL, step: String, count: Int) {
        let url = cursor(run, step)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(count)".write(to: url, atomically: true, encoding: .utf8)
    }

    static func unread(run: URL, step: String) -> [Message] {
        Array(messages(run).dropFirst(seen(run: run, step: step))).filter { isFor($0, step: step) }
    }

    static func render(_ m: Message) -> String {
        let clock = Date(timeIntervalSince1970: m.at).formatted(date: .omitted, time: .shortened)
        return "\(clock) \(m.from)\(m.agent.map { " (\($0))" } ?? "")\(m.to.map { " to \($0)" } ?? "")\(m.fromScreen == true ? " [may quote the screen]" : "")\(m.urgent == true ? " [urgent]" : ""): \(m.text)"
    }

    /// `2 unread`, for the end of every apprentice command a step runs.
    static func unreadLine(run: URL, step: String) -> String? {
        let n = unread(run: run, step: step).count
        return n == 0 ? nil : "board: \(n) unread · apprentice board read"
    }

    // MARK: - CLI

    /// Asks the engine to stop a step so it can start again with this message, which wastes what it has done so far.
    /// Nil when it is on its way; otherwise why the message goes as an ordinary one, seen at the step's next check.
    /// The user can always interrupt. Another step can only `[pipelines] urgent_max` times per step in a run, so two
    /// agents cannot keep stopping each other and spending tokens.
    static func interruptNote(run: URL, to: String, from: String) -> String? {
        guard let state = Runs.load(run), let target = state.steps[to], target.status == "running" else { return "\(to) is not running: it reads this when it does" }
        guard target.agent != nil else { return "\(to) is a shell step, so it has nobody to tell" }
        let node = run.appendingPathComponent("nodes/\(to)")
        // Starting it again could do something twice on the screen.
        if FileManager.default.fileExists(atPath: node.appendingPathComponent("acted").path) { return "\(to) has already acted on the screen, so it is not stopped: it sees this at its next check" }
        let limit = Int(PipelineSettings.number("urgent_max", 2, project: state.project.map { URL(fileURLWithPath: $0) }))
        if from != "you", (target.interrupts ?? 0) >= limit { return "\(to) was already stopped \(limit) times by other steps, so it is not stopped again: it sees this at its next check" }
        try? from.write(to: node.appendingPathComponent("interrupt"), atomically: true, encoding: .utf8)
        return nil
    }

    static let usage = "board post [--to step] [--urgent] \"message\" · read [--all] · wait --from step [--for 10m] · show <run> · summarise <run>"

    /// `10m`, `90s`, `2h`, or a number of seconds.
    static func seconds(_ raw: String?) -> Double? {
        guard var t = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty else { return nil }
        var unit = 1.0
        if let last = t.last, "smh".contains(last) {
            unit = last == "m" ? 60 : last == "h" ? 3600 : 1
            t.removeLast()
        }
        return Double(t).map { $0 * unit }
    }

    static func command(_ a: Args) throws -> String {
        let here = PipelineStep.current
        let action = a.pos.first ?? "read"
        switch action {
        case "post":
            let text = a.pos.dropFirst().joined(separator: " ")
            guard !text.isEmpty else { throw Fail(5, usage) }
            let run: URL, from: String, agent: String?
            if let here {
                (run, from, agent) = (here.run, here.step, here.agent)
            } else {
                run = try Runs.find(a.value("run") ?? "", project: Runs.project(a)).dir
                (from, agent) = ("you", nil)
            }
            let to = a.value("to").map(Pipelines.slug)
            if let to, let state = Runs.load(run), state.steps[to] == nil {
                throw Fail(5, "no step \(to) in this run: \(state.steps.keys.sorted().joined(separator: ", "))")
            }
            let urgent = a.has("urgent")
            if urgent, to == nil { throw Fail(5, "an urgent message stops the step it is for, so it goes to one: --to <step>") }
            if urgent, to == from { throw Fail(5, "a step cannot interrupt itself") }
            try post(Message(at: Date().timeIntervalSince1970, from: from, agent: agent, to: to, text: text, fromScreen: here?.hasScreen == true ? true : nil, urgent: urgent ? true : nil), run: run)
            let said = "posted" + (to.map { " to \($0)" } ?? "")
            guard urgent, let to else { return said }
            return said + (interruptNote(run: run, to: to, from: from).map { ". Not urgent after all: \($0)" } ?? ": it stops now and starts again with this")
        case "read":
            guard let here else { throw Fail(5, "board read works inside a pipeline step; for a past run: apprentice board show <run>") }
            if a.has("all") { return messages(here.run).map(render).joined(separator: "\n") }
            let all = messages(here.run)
            let new = Array(all.dropFirst(seen(run: here.run, step: here.step))).filter { isFor($0, step: here.step) }
            markSeen(run: here.run, step: here.step, count: all.count)
            return new.isEmpty ? "nothing new on the board" : new.map(render).joined(separator: "\n")
        case "wait":
            guard let here else { throw Fail(5, "board wait works inside a pipeline step") }
            guard let raw = a.value("from") else { throw Fail(5, usage) }
            let from = Pipelines.slug(raw)
            let limit = seconds(a.value("for")) ?? 600
            let end = Date().addingTimeInterval(limit)
            let waiting = here.node.appendingPathComponent("waiting")
            try? "\(getpid())".write(to: waiting, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: waiting) }
            while Date() < end {
                let all = messages(here.run)
                let new = Array(all.dropFirst(seen(run: here.run, step: here.step))).filter { isFor($0, step: here.step) }
                if new.contains(where: { $0.from == from }) {
                    markSeen(run: here.run, step: here.step, count: all.count)
                    return new.map(render).joined(separator: "\n")
                }
                // A step that has ended, or can no longer answer, ends the wait now: nobody will come.
                if let state = Runs.load(here.run), let other = state.steps[from], ["done", "failed", "skipped"].contains(other.status) {
                    throw Fail(5, "\(from) has \(other.status) without answering: carry on another way")
                }
                Thread.sleep(forTimeInterval: 1)
            }
            throw Fail(5, "no answer from \(from) in \(Int(limit)) s: carry on another way")
        case "show":
            let run = try Runs.find(a.pos.dropFirst().first ?? "", project: Runs.project(a)).dir
            let all = messages(run)
            return all.isEmpty ? "the board of this run is empty" : all.map(render).joined(separator: "\n")
        case "summarise", "summarize":
            let found = try Runs.find(a.pos.dropFirst().first ?? "", project: Runs.project(a))
            return try PipelineEngine.summariseForNextRun(found.dir, found.state)
        default:
            throw Fail(5, usage)
        }
    }
}

/// The step this process is part of, from the environment a run sets.
struct PipelineStep {
    var run: URL
    var step: String
    var agent: String?
    var hasScreen: Bool

    var node: URL { run.appendingPathComponent("nodes/\(step)") }

    static var current: PipelineStep? {
        let env = ProcessInfo.processInfo.environment
        guard let run = env["APPRENTICE_RUN_DIR"], !run.isEmpty, let step = env["APPRENTICE_STEP"], !step.isEmpty else { return nil }
        return PipelineStep(run: URL(fileURLWithPath: run), step: step, agent: env["APPRENTICE_AGENT"], hasScreen: env["APPRENTICE_STEP_SCREEN"] == "1")
    }

    /// Every apprentice command a step runs says it is alive, so a long think between commands is not a stall.
    func alive() { touch("alive") }

    func touch(_ name: String) {
        let url = node.appendingPathComponent(name)
        if !FileManager.default.createFile(atPath: url.path, contents: nil) { return }
    }

    /// `ask` inside a step: the popup names who asks; an unanswered one is saved for the Pipelines screen and the
    /// phone; an answer also goes on the board, so a parallel step does not ask again.
    func aroundAsk(_ args: [String]) throws -> (code: Int32, out: String) {
        var question = ""
        var rest: [String] = []
        var i = 0
        var choices: String?, multi = false
        while i < args.count {
            let t = args[i]
            if t == "--choices", i + 1 < args.count { choices = args[i + 1]; rest += [t, args[i + 1]]; i += 2; continue }
            if t == "--multi" { multi = true }
            if t.hasPrefix("--") {
                rest.append(t)
                if !Args.switches.contains(String(t.dropFirst(2))), !t.contains("="), i + 1 < args.count, !args[i + 1].hasPrefix("--") { rest.append(args[i + 1]); i += 1 }
            } else {
                question += (question.isEmpty ? "" : " ") + t
            }
            i += 1
        }
        let who = (agent ?? "An agent") + ", on the `\(step)` step"
        let asking = node.appendingPathComponent("asking")
        try? "\(getpid())".write(to: asking, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: asking) }
        let response = try Wire.send(Request(cmd: "ask", args: ["\(who): \(question)"] + rest))
        if response.code == 9 {
            let q = RunQuestion(kind: "question", text: question, choices: (choices ?? "").split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }, multi: multi, who: who)
            if let data = try? JSONEncoder().encode(q) { try? data.write(to: node.appendingPathComponent("question.json"), options: .atomic) }
            return (9, "the user has not answered: it stays open for them on the Pipelines screen and their phone. Write your progress to \(node.appendingPathComponent("progress.md").path) and exit now. Their answer restarts this step as a fresh run, given your progress and the answer.")
        }
        if response.code == 0 {
            try? Board.post(Board.Message(at: Date().timeIntervalSince1970, from: "you", agent: nil, to: nil,
                                          text: String("\(step) asked: \(question)\nthe user: \(response.out)".prefix(Board.maxLength))), run: run)
        }
        return (response.code, response.out)
    }
}

/// A question a parked step waits on. Apprentice words `permission` and the other kinds itself; only `question`
/// carries an agent's words.
struct RunQuestion: Codable, Equatable {
    var kind: String
    var text: String
    var choices: [String] = []
    var multi = false
    var who: String? = nil
}
