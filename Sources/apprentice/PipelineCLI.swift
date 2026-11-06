import Foundation

/// The commands around a run: `pipeline check | audit | status | answer | resume | stop | notes`.
enum PipelineCLI {
    static func check(_ p: Pipelines.Pipeline) throws -> String {
        let report = PipelineGraph(p).check()
        let warnings = report.warnings.map { "note: \($0)" }
        guard report.ok else {
            throw Fail(5, (["\(p.ref) does not check:"] + report.errors.map { "  - \($0)" } + warnings).joined(separator: "\n"))
        }
        let agents = Set(p.steps.compactMap(\.use)).count
        return (["\(p.ref) checks: \(p.steps.count) step\(p.steps.count == 1 ? "" : "s"), \(agents) named agent\(agents == 1 ? "" : "s")"] + warnings).joined(separator: "\n")
    }

    /// The agents a step could use, in order, as `pipeline audit` shows them.
    private static func whoRuns(_ p: Pipelines.Pipeline) -> String {
        let defaults = NamedAgents.defaults(project: p.project)
        let list = NamedAgents.all(project: p.project)
        func line(_ name: String) -> String {
            NamedAgents.find(name, project: p.project, list: list).map(NamedAgents.describe) ?? "\(name): no such agent"
        }
        var out = p.steps.map { s -> String in
            let first = s.use ?? (p.agent.isEmpty ? nil : p.agent) ?? defaults.priority.first ?? "the first installed CLI"
            return "- \(s.id)\(s.ui ? " [screen]" : "")\(s.needs.map { " needs \($0)" } ?? ""): \(line(first))"
        }
        out.append("- interpreter: " + line(p.interpreter ?? defaults.interpreter ?? defaults.priority.first ?? p.agent))
        let scribes = p.scribes.isEmpty ? defaults.scribe : p.scribes
        out.append("- scribe: " + (scribes.isEmpty ? "none chosen" : scribes.map(line).joined(separator: "; then ")))
        out.append("- priority list: " + (defaults.priority.isEmpty ? "none set" : defaults.priority.joined(separator: ", ")))
        return out.joined(separator: "\n")
    }

    static func runSummary(_ dir: URL, _ s: RunState) -> String {
        var out = ["Run \(s.run): \(s.status)" + (s.reason.map { ", \($0)" } ?? "") + " · path: " + s.path.joined(separator: " → ")]
        for id in s.path.reduce(into: [String](), { if !$0.contains($1) { $0.append($1) } }) {
            let st = s.steps[id]
            out.append("- \(id): \(s.shownStatus(id) ?? "?")" + (st?.agent.map { ", \($0)" } ?? "") + (st?.reason.map { ": \($0)" } ?? ""))
            if let result = (try? Data(contentsOf: dir.appendingPathComponent("nodes/\(id)/result.json"))).flatMap({ try? JSONDecoder().decode(StepResult.self, from: $0) }), result.tries.count > 1 {
                out.append("  tried: " + result.tries.map { "\($0.agent) \($0.limit == nil ? $0.outcome : "out of usage")" }.joined(separator: ", "))
            }
        }
        return out.joined(separator: "\n")
    }

    /// Writes the brief; spends nothing. The check's failure is part of the brief, not an error here.
    static func audit(_ p: Pipelines.Pipeline) throws -> String {
        let report = PipelineGraph(p).check()
        let check = report.errors.map { "ERROR: \($0)" } + report.warnings.map { "note: \($0)" }
        let last = Runs.all(project: p.project, slug: p.slug).first
        let memoryFile = p.project?.appendingPathComponent("pipelines/\(p.slug).memory.md")
        let memory = memoryFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let notes = pastNotes(p)
        let text = PipelineText.fill("audit", [
            "name": p.slug, "file": p.url?.path ?? "(no file)", "check": check.isEmpty ? "Passes." : check.joined(separator: "\n"), "agents": whoRuns(p),
            "lastrun": last.map { runSummary($0.dir, $0.state) } ?? "It has not run yet.",
            "notes": notes.isEmpty ? "None yet." : notes.prefix(5).map { "- \($0.url.path)\($0.stale ? " (may be out of date)" : "")" }.joined(separator: "\n"),
            "memory": memory.map { "\($0)\n(\(memoryFile?.path ?? ""))" } ?? "None.",
        ])
        let file = Runs.cache(project: p.project).appendingPathComponent("audit/\(p.slug).md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        if let project = p.project { ProjectFiles.ensureIgnored(project) }
        return file.path + "\n" + insertLine(p)
    }

    /// What the Audit button types into the shell tab.
    static func insertLine(_ p: Pipelines.Pipeline) -> String {
        "Read .apprentice/cache/audit/\(p.slug).md, then review this pipeline with me."
    }

    /// One run in full: its steps, what each parked one waits for, and how to answer it.
    private static func runDetail(_ dir: URL, _ s: RunState) -> String {
        var out = runSummary(dir, s)
        for (id, st) in s.steps.sorted(by: { $0.key < $1.key }) where st.status == "parked" {
            out += "\n\(id) waits: \(st.question?.text ?? st.reason ?? "")"
            if let choices = st.question?.choices, !choices.isEmpty { out += "\n  choices: \(choices.joined(separator: " | "))" }
            if let q = st.question, RunQuestion.userOnly.contains(q.kind) { out += "\n  the user has been asked this: only they can allow it" }
            out += "\n  apprentice pipeline answer \(s.run) \(id) \"…\""
        }
        return out + "\neach step's work: \(dir.appendingPathComponent("nodes").path)/<step>/output.log and summary.md"
    }

    /// What changing means to someone watching a run.
    private static func signature(_ s: RunState) -> String {
        ([s.status] + s.steps.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.status)" }).joined(separator: " ")
    }

    private static func ended(_ s: RunState) -> Bool { ["done", "failed", "stopped"].contains(s.status) }

    /// `status --wait`: blocks until a step finishes or parks or the run ends, so watching a run spends nothing while it
    /// works. It remembers what it last showed, so a step still waiting on the user does not wake the caller again.
    private static func wait(_ ref: String?, _ a: Args) throws -> String {
        let (dir, start) = try Runs.find(ref ?? "", project: Runs.project(a))
        let seen = dir.appendingPathComponent("seen")
        let last = (try? String(contentsOf: seen, encoding: .utf8)) ?? ""
        let end = Date().addingTimeInterval(Board.seconds(a.value("for")) ?? 90)
        var now = start
        while signature(now) == last, !ended(now), now.status != "running" || Runs.alive(now.pid) || now.pid == nil, Date() < end {
            Thread.sleep(forTimeInterval: 1)
            now = Runs.load(dir) ?? now
        }
        let changed = signature(now) != last
        try? signature(now).write(to: seen, atomically: true, encoding: .utf8)
        let died = now.status == "running" && now.pid != nil && !Runs.alive(now.pid) ? "\nits process died: apprentice pipeline resume \(now.run) --copy" : ""
        return (changed || ended(now) ? "" : "nothing has changed yet: wait again\n") + runDetail(dir, now) + died
    }

    /// What the window's Run types into an agent's tab: plain words, so it works in every CLI.
    static func directLine(_ run: Int) -> String { "Run `apprentice pipeline direct \(run)` in the shell, then do what it prints." }

    /// `direct <run>`, or `direct <pipeline>` to start one first: the brief for the agent the user opened, who watches the
    /// headless steps and steers them. It starts nothing an agent could not start by hand and raises no one's access.
    static func direct(_ ref: String?, _ a: Args) throws -> String {
        var number = ref.flatMap { Int($0.split(separator: "#").last ?? "") }
        var project = Runs.project(a)
        var line: String? = nil
        if number == nil, let ref, !ref.isEmpty {
            let p = try Pipelines.find(ref)
            line = try PipelineEngine.startInBackground(p, options: Options(fresh: a.has("fresh"), first: a.value("first"), last: a.value("last"), directed: true))
            project = p.project
            number = Runs.all(project: project, slug: p.slug).first?.state.run
        }
        let (dir, s) = try Runs.find(number.map(String.init) ?? "", project: project)
        FileManager.default.createFile(atPath: Runs.directedFile(dir).path, contents: nil)
        let text = (try? String(contentsOf: dir.appendingPathComponent("pipeline.md"), encoding: .utf8)) ?? ""
        let p = Pipelines.parse(text, url: s.file.map { URL(fileURLWithPath: $0) }, project: s.project.map { URL(fileURLWithPath: $0) })
        return ([line].compactMap { $0 } + [PipelineText.fill("director", [
            "run": "\(s.run)", "name": s.name, "goal": p.goal ?? "(none written)", "map": PipelineGraph(p).map(here: nil), "status": runDetail(dir, s),
            "file": s.file ?? "(a one-off task)", "copy": dir.appendingPathComponent("pipeline.md").path, "nodes": dir.appendingPathComponent("nodes").path,
        ])]).joined(separator: "\n")
    }

    static func status(_ ref: String?, _ a: Args) throws -> String {
        let project = Runs.project(a)
        if a.has("wait") { return try wait(ref, a) }
        if let here = PipelineStep.current, ref == nil, let s = Runs.load(here.run) { return runSummary(here.run, s) }
        if let ref, Int(ref.split(separator: "#").last ?? "") != nil {
            let (dir, s) = try Runs.find(ref, project: project)
            return runDetail(dir, s)
        }
        let slug = ref.flatMap { try? Pipelines.find($0) }?.slug
        let runs = Runs.all(project: project, slug: slug)
        guard !runs.isEmpty else { return "no runs here yet" }
        return runs.prefix(15).map { r in
            let live = r.state.status == "running" && !Runs.alive(r.state.pid) ? "died (resume it)" : r.state.status
            let at = Date(timeIntervalSince1970: r.state.started).formatted(date: .abbreviated, time: .shortened)
            return "\(r.state.run) · \(r.state.slug) · \(live) · \(at) · " + r.state.path.joined(separator: " → ")
        }.joined(separator: "\n")
    }

    /// `pipeline answer`: anyone at a terminal, and that includes an agent, so what gives access goes through the little
    /// window and only the user's click there counts. Exit 7 when they did not say yes there.
    static func answer(_ a: Args) throws -> String {
        guard a.pos.count >= 4 else { throw Fail(5, "pipeline answer <run> <step> \"answer\"") }
        let (dir, s) = try Runs.find(a.pos[1], project: Runs.project(a))
        let step = Pipelines.slug(a.pos[2])
        let text = a.pos.dropFirst(3).joined(separator: " ")
        try checkAnswer(s, step, text)
        if let q = s.steps[step]?.question, q.grants(text), !userSaysYes(q, text) {
            throw Fail(7, "only the user can allow this, and they have not. It stays open for them on the run's page: tell them what it is waiting for, and carry on with what you can.")
        }
        return deliver(dir, s, step, text)
    }

    /// The window's own buttons: the user's click, so it needs no second one.
    static func answerAsUser(run: Int, step: String, text: String, project: URL?) throws -> String {
        let (dir, s) = try Runs.find("\(run)", project: project)
        try checkAnswer(s, step, text)
        return deliver(dir, s, step, text)
    }

    private static func checkAnswer(_ s: RunState, _ step: String, _ text: String) throws {
        guard let st = s.steps[step], st.status == "parked" else { throw Fail(5, "\(step) is not waiting for an answer: apprentice pipeline status \(s.run)") }
        if let q = st.question, q.kind != "question", !q.choices.isEmpty, !q.choices.contains(where: { $0.caseInsensitiveCompare(text.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }) {
            throw Fail(5, "that is not one of the answers: " + q.choices.joined(separator: " · "))
        }
    }

    private static func userSaysYes(_ q: RunQuestion, _ text: String) -> Bool {
        guard ProcessInfo.processInfo.environment["APPRENTICE_PIPELINE_NO_ASK"] != "1" else { return false }
        let args = ["Something at a terminal answered this for you: \(text). Is that your answer?\n\n\(q.text)", "--choices", "\(text)|No"]
        guard let r = try? Wire.send(Request(cmd: "ask", args: args)), r.code == 0 else { return false }
        return r.out.components(separatedBy: "\n").contains("user chose: \(text)")
    }

    /// Whether the file says something other than the run's copy, leaving out the steps typed for this run.
    static func fileChanged(_ dir: URL, _ s: RunState) -> Bool {
        let copy = (try? String(contentsOf: dir.appendingPathComponent("pipeline.md"), encoding: .utf8)) ?? ""
        let named = s.file.map { URL(fileURLWithPath: $0) }
        guard let named, let edited = try? String(contentsOf: named, encoding: .utf8) else { return false }
        return Pipelines.render(Pipelines.forRun(Pipelines.parse(edited, url: named), first: s.first, last: s.last)) != Pipelines.render(Pipelines.parse(copy, url: named))
    }

    /// Records the answer. A live run picks it up; otherwise a new process carries the run on in the background.
    private static func deliver(_ dir: URL, _ s: RunState, _ step: String, _ text: String) -> String {
        guard let st = s.steps[step] else { return "" }
        let file = Runs.answers(dir).appendingPathComponent("\(step).txt")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: file, atomically: true, encoding: .utf8)
        // So a parallel step does not ask the same thing.
        if st.question?.kind == "question" {
            try? Board.post(.init(at: Date().timeIntervalSince1970, from: "you", agent: nil, to: nil, text: String("\(step) asked: \(st.question?.text ?? "")\nthe user: \(text)".prefix(Board.maxLength))), run: dir)
        }
        if Runs.alive(s.pid) { return "answered: run \(s.run) picks it up" }
        spawnResume(s, dir: dir)
        return "answered: run \(s.run) carries on in the background · apprentice pipeline status \(s.run)"
    }

    /// `pipeline resume` as its own process, its output kept in the run's folder.
    static func spawnResume(_ s: RunState, dir: URL) {
        let p = Process()
        // nohup: closing the tab or the window it was started from must not end a run in the background.
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        p.arguments = [Wire.binaryPath(), "pipeline", "resume", "\(s.run)", "--copy"] + (s.project.map { ["--project", $0] } ?? [])
        if let folder = s.project { p.currentDirectoryURL = URL(fileURLWithPath: folder) }
        let log = dir.appendingPathComponent("engine.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: log) {
            _ = try? h.seekToEnd()
            p.standardOutput = h
            p.standardError = h
        }
        p.standardInput = FileHandle.nullDevice
        try? p.run()
    }

    static func resume(_ ref: String?, _ a: Args) throws -> String {
        let (dir, s) = try Runs.find(ref ?? "", project: Runs.project(a))
        guard s.status != "done" else { throw Fail(5, "run \(s.run) finished: start a new one with apprentice pipeline run \(s.slug)") }
        if fileChanged(dir, s), !a.has("copy"), !a.has("file") {
            throw Fail(5, "the pipeline's file changed since this run began. Say which to follow: apprentice pipeline resume \(s.run) --copy (the run's own copy) or --file (the edited file)")
        }
        return try PipelineEngine.resume(dir, s, useFile: a.has("file"))
    }

    /// Asks the run's process to stop; one that has died is simply marked.
    static func stop(_ ref: String?, _ a: Args) throws -> String {
        let (dir, s) = try Runs.find(ref ?? "", project: Runs.project(a))
        guard s.status == "running" || s.status == "parked" else { return "run \(s.run) has already \(s.status == "done" ? "finished" : s.status)" }
        if Runs.alive(s.pid) {
            FileManager.default.createFile(atPath: dir.appendingPathComponent("stop").path, contents: nil)
            return "stopping run \(s.run): its steps are told to stop now"
        }
        try PipelineEngine.stopWithoutProcess(dir, s)
        return "stopped run \(s.run)"
    }

    struct Note {
        var url: URL
        var text: String
        var stale: Bool
    }

    /// Past-run notes, newest first. One whose commit no longer matches the files it names may be out of date.
    static func pastNotes(_ p: Pipelines.Pipeline) -> [Note] {
        Runs.restoreNotes(project: p.project, slug: p.slug)
        let folder = Runs.past(project: p.project, slug: p.slug)
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "md" }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
        return dated.sorted { $0.1 > $1.1 }.compactMap { url, _ in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return Note(url: url, text: text, stale: isStale(text, in: p.folder))
        }
    }

    static func isStale(_ note: String, in folder: URL) -> Bool {
        var commit: String?, names: [String] = []
        for line in note.components(separatedBy: "\n").prefix(12) {
            if line.hasPrefix("commit: ") { commit = String(line.dropFirst(8)) }
            if line.hasPrefix("files: ") { names = line.dropFirst(7).components(separatedBy: ", ") }
        }
        guard let commit, !names.isEmpty else { return false }
        let r = Repo.run("git", ["diff", "--name-only", commit, "HEAD", "--"] + names, in: folder)
        return r.code == 0 ? !r.out.isEmpty : true
    }

    static func notes(_ ref: String?, _ a: Args) throws -> String {
        let p = try Pipelines.find(ref ?? "")
        let found = pastNotes(p)
        guard !found.isEmpty else { return "no notes for \(p.ref) yet" }
        return found.prefix(a.int("limit", 5)).map { ($0.stale ? "(may be out of date) " : "") + $0.url.path + "\n" + $0.text }.joined(separator: "\n\n")
    }
}
