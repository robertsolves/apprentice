import Foundation

/// The structure of a pipeline: which step can follow which, what can run at the same time, and what is wrong with
/// the file. No AI anywhere in here: `pipeline check` runs before every run, and the editor asks it about the UI tick.
struct PipelineGraph {
    enum Next: Equatable {
        case stop
        /// One step, no choice.
        case one(String)
        /// One of these, chosen by the interpreter.
        case choice([String])
        /// All of these, in parallel.
        case all([String])
    }

    let pipeline: Pipelines.Pipeline
    let ids: [String]
    private let index: [String: Int]

    init(_ p: Pipelines.Pipeline) {
        pipeline = p
        ids = p.steps.map(\.id)
        var at: [String: Int] = [:]
        for (i, id) in ids.enumerated() where at[id] == nil { at[id] = i }
        index = at
    }

    func step(_ id: String) -> Pipelines.Step? { index[id].map { pipeline.steps[$0] } }

    /// The names in a `next:` line and how they join.
    static func split(_ raw: String) -> (names: [String], choice: Bool, all: Bool) {
        let choice = raw.contains("|"), all = raw.contains("&")
        let names = raw.split(whereSeparator: { $0 == "|" || $0 == "&" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (names, choice, all)
    }

    /// What follows a step: its `next:`, else the next heading, else the end. Unknown names are left out here and
    /// reported by `check`.
    func next(_ id: String) -> Next {
        guard let i = index[id] else { return .stop }
        guard let raw = pipeline.steps[i].next?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return i + 1 < ids.count ? .one(ids[i + 1]) : .stop
        }
        if raw.lowercased() == "end" { return .stop }
        let (names, choice, all) = Self.split(raw)
        let known = names.map(Pipelines.slug).filter { index[$0] != nil }
        guard !known.isEmpty else { return .stop }
        if known.count == 1 { return .one(known[0]) }
        return all && !choice ? .all(known) : .choice(known)
    }

    func successors(_ id: String) -> [String] {
        switch next(id) {
        case .stop: return []
        case .one(let a): return [a]
        case .choice(let a), .all(let a): return a
        }
    }

    /// Every step reachable from `id` by following at least one edge.
    func reach(_ id: String) -> Set<String> {
        var seen = Set<String>(), stack = successors(id)
        while let s = stack.popLast() {
            if seen.insert(s).inserted { stack += successors(s) }
        }
        return seen
    }

    func canReach(_ from: String, _ to: String) -> Bool { reach(from).contains(to) }

    var hasLoop: Bool { ids.contains { reach($0).contains($0) } }

    /// Steps that could be running at the same moment: on different branches of one `&`, past neither's join.
    func overlaps() -> [(String, String)] {
        var out: [(String, String)] = []
        for id in ids {
            guard case .all(let targets) = next(id) else { continue }
            let branches = targets.map { t -> Set<String> in reach(t).union([t]) }
            for i in branches.indices {
                for j in branches.indices where j > i {
                    for a in branches[i].subtracting(branches[j]).sorted() {
                        for b in branches[j].subtracting(branches[i]).sorted() where !out.contains(where: { $0 == (a, b) || $0 == (b, a) }) {
                            out.append((a, b))
                        }
                    }
                }
            }
        }
        return out
    }

    /// The step already holding the screen that stops `id` having it too, for the editor's disabled tick.
    func uiHolder(blocking id: String) -> String? {
        overlaps().compactMap { pair -> String? in
            let other = pair.0 == id ? pair.1 : pair.1 == id ? pair.0 : nil
            return other.flatMap { step($0)?.ui == true ? $0 : nil }
        }.first
    }

    /// Steps nothing reaches, the first aside.
    var unreached: [String] {
        guard let first = ids.first else { return [] }
        let live = reach(first).union([first])
        return ids.filter { !live.contains($0) }
    }

    /// The steps a run begins with, for a `--from` on a straight line.
    var isStraight: Bool { !pipeline.steps.contains { $0.next != nil } }

    struct Report {
        var errors: [String] = []
        var warnings: [String] = []
        var ok: Bool { errors.isEmpty }
    }

    func check(agents: [NamedAgents.Named]? = nil, clis: [AgentCLIs.CLI]? = nil) -> Report {
        var r = Report()
        let p = pipeline
        let list = clis ?? AgentCLIs.all()
        let named = agents ?? NamedAgents.all(project: p.project)
        if p.steps.isEmpty { r.errors.append("it has no steps") }
        for id in Set(ids) where ids.filter({ $0 == id }).count > 1 { r.errors.append("two steps are called \(id): a step's name must be unique") }
        func agent(_ name: String) -> NamedAgents.Named? {
            let key = name.lowercased()
            if let n = named.first(where: { $0.name.lowercased() == key }) { return n }
            guard let cli = AgentCLIs.find(key, in: list), !cli.isEditor else { return nil }
            return NamedAgents.Named(name: cli.id, agent: cli.id, origin: .cli)
        }
        func known(_ name: String, _ whose: String) {
            guard let n = agent(name) else { r.errors.append("\(whose) names \(name), which is no agent · apprentice agents list"); return }
            for line in NamedAgents.problems(n, clis: list) {
                if line.contains("no CLI") || line.contains("only opens") || line.contains("permissions is") { r.errors.append(line) } else { r.warnings.append(line) }
            }
        }
        for s in p.scribes { known(s, "scribe:") }
        if let i = p.interpreter { known(i, "interpreter:") }
        for step in p.steps {
            let id = step.id
            if let use = step.use {
                known(use, "\(id)'s use:")
                if step.shell != nil { r.warnings.append("\(id) is a shell command, so its use: does nothing") }
            }
            if let raw = step.next?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, raw.lowercased() != "end" {
                let (names, choice, all) = Self.split(raw)
                if choice && all { r.errors.append("\(id)'s next: mixes | and &: use one or the other") }
                if names.isEmpty { r.errors.append("\(id)'s next: names no step") }
                for name in names where index[Pipelines.slug(name)] == nil { r.errors.append("\(id)'s next: names \(name), which is no step") }
            }
            if let needs = step.needs {
                if !NamedAgents.levels.contains(needs) { r.errors.append("\(id)'s needs: is read-only, edit or full, not \(needs)") }
                else if step.shell == nil {
                    let cand = step.use ?? (p.agent.isEmpty ? nil : p.agent) ?? NamedAgents.defaults(project: p.project).priority.first
                    if let n = cand.flatMap(agent), NamedAgents.rank(n.permissions) < NamedAgents.rank(needs) {
                        r.errors.append("\(id) needs \(needs), and \(n.name) has \(n.permissions ?? "no permission level set")")
                    } else if cand == nil, needs != "read-only" {
                        r.errors.append("\(id) needs \(needs): name an agent that has it with use:")
                    }
                }
            }
            if step.ui, step.shell != nil { r.warnings.append("\(id) is a shell command, so ui: true does nothing") }
            if step.when != nil, !ids.contains(where: { if case .choice(let a) = next($0) { return a.contains(id) } else { return false } }) {
                r.warnings.append("\(id)'s when: is read only when a | chooses it, and none does")
            }
            if case .choice = next(id), p.interpreter == nil, NamedAgents.defaults(project: p.project).interpreter == nil,
               NamedAgents.defaults(project: p.project).priority.isEmpty, step.shell == nil {
                r.warnings.append("\(id) branches, and no interpreter is set: the pipeline's own agent will choose")
            }
        }
        for id in unreached { r.errors.append("nothing reaches \(id)") }
        for (a, b) in overlaps() where step(a)?.ui == true && step(b)?.ui == true {
            r.errors.append("\(a) and \(b) can run at the same time and both have ui: true: only one step of a parallel group may use the screen")
        }
        if hasLoop, p.visits <= 0 { r.errors.append("it has a loop and visits: sets no limit") }
        return r
    }

    /// The map a step's prompt shows: every step, what follows it, and where this one sits.
    func map(here: String?) -> String {
        ids.map { id -> String in
            let arrow: String
            switch next(id) {
            case .stop: arrow = "(end)"
            case .one(let a): arrow = "→ \(a)"
            case .choice(let a): arrow = "→ one of " + a.joined(separator: " | ")
            case .all(let a): arrow = "→ all of " + a.joined(separator: " & ")
            }
            return "\(id == here ? "▶" : "-") \(id) \(arrow)\(step(id)?.ui == true ? " [screen]" : "")"
        }.joined(separator: "\n")
    }

    /// Depth per step for the window's drawing: each step one column past the deepest step before it.
    func layers() -> [[String]] {
        var depth: [String: Int] = [:]
        func visit(_ id: String, _ d: Int, _ path: Set<String>) {
            if let known = depth[id], known >= d { return }
            depth[id] = d
            for s in successors(id) where !path.contains(s) { visit(s, d + 1, path.union([s])) }
        }
        if let first = ids.first { visit(first, 0, [first]) }
        for id in ids where depth[id] == nil { depth[id] = 0 }
        let top = depth.values.max() ?? 0
        return (0...top).map { d in ids.filter { depth[$0] == d } }.filter { !$0.isEmpty }
    }
}
