import AppKit
import SwiftUI

/// A pipeline's runs in the window: the graph and the path a run took, which agent ran each step, parked questions
/// with their buttons, the board, and past-run notes.
struct PipelineRunsPanel: View {
    @ObservedObject var model: AppModel
    let pipeline: Pipelines.Pipeline
    @State private var runs: [(dir: URL, state: RunState)] = []
    @State private var selected: Int?
    @State private var notes: [PipelineCLI.Note] = []
    @State private var reply: [String: String] = [:]
    @State private var showBoard = false
    @State private var showNotes = false
    @State private var output = ""
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var current: (dir: URL, state: RunState)? {
        runs.first { $0.state.run == selected } ?? runs.first
    }

    var body: some View {
        Panel(title: "Runs", note: runs.isEmpty ? "" : "\(runs.count)") {
            if let run = current {
                if runs.count > 1 {
                    Picker("", selection: Binding(get: { current?.state.run ?? 0 }, set: { selected = $0 })) {
                        ForEach(runs, id: \.state.run) { r in
                            Text("Run \(r.state.run) · \(label(r.state)) · \(Date(timeIntervalSince1970: r.state.started).formatted(date: .abbreviated, time: .shortened))").tag(r.state.run)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(maxWidth: 420, alignment: .leading)
                }
                detail(run)
            } else {
                Text("It has not run yet.").font(Theme.caption).foregroundStyle(.secondary)
            }
            graph(current?.state)
            if let run = current { questions(run) }
            HStack(spacing: Theme.s2) {
                if let run = current {
                    if live(run.state) {
                        IconButton("Stop", "stop.fill") { act(["pipeline", "stop", "\(run.state.run)"] + scope) }
                    } else if ["failed", "stopped"].contains(run.state.status) || (run.state.status == "running" && !Runs.alive(run.state.pid)) {
                        IconButton("Carry on", "play.fill") { resume(run) }
                    }
                    IconButton(showBoard ? "Hide the board" : "The board", "bubble.left.and.bubble.right") { showBoard.toggle() }
                }
                IconButton(showNotes ? "Hide notes" : "Past-run notes", "note.text") { showNotes.toggle(); loadNotes() }
            }
            .controlSize(.small)
            if showBoard, let run = current {
                let messages = Board.messages(run.dir)
                Output(text: messages.isEmpty ? "Nothing on the board." : messages.map(Board.render).joined(separator: "\n"))
            }
            if showNotes {
                if notes.isEmpty { Text("No notes yet.").font(Theme.caption).foregroundStyle(.secondary) }
                ForEach(notes.prefix(5), id: \.url) { n in
                    VStack(alignment: .leading, spacing: Theme.s1) {
                        Text(n.url.lastPathComponent + (n.stale ? " · may be out of date" : "")).font(Theme.caption).foregroundStyle(n.stale ? Theme.warn : .secondary)
                        Output(text: n.text)
                    }
                }
            }
            if !output.isEmpty { Output(text: output) }
        }
        .onAppear(perform: reload)
        .onReceive(tick) { _ in reload() }
    }

    private var scope: [String] { pipeline.project.map { ["--project", $0.path] } ?? [] }

    private func live(_ s: RunState) -> Bool { s.status == "running" && Runs.alive(s.pid) }

    private func label(_ s: RunState) -> String {
        if s.status == "running", !Runs.alive(s.pid) { return "stopped unexpectedly" }
        switch s.status {
        case "parked": return "waiting for you"
        case "done": return "done"
        case "failed": return "failed"
        case "stopped": return "stopped"
        default: return "running"
        }
    }

    private func detail(_ run: (dir: URL, state: RunState)) -> some View {
        VStack(alignment: .leading, spacing: Theme.s1) {
            HStack(spacing: Theme.s2) {
                StatusPill(text: label(run.state), tint: run.state.status == "failed" ? Theme.danger : run.state.status == "parked" ? Theme.warn : Theme.accent)
                if let v = run.state.memoryVersion { Text("used summary \(v)").font(Theme.monoSmall).foregroundStyle(.tertiary) }
                if run.state.fresh { Text("fresh").font(Theme.monoSmall).foregroundStyle(.tertiary) }
            }
            if let r = run.state.reason { Text(r).font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            ForEach(run.state.path.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }, id: \.self) { id in
                let st = run.state.steps[id]
                HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
                    Image(systemName: icon(st?.status)).foregroundStyle(tint(st?.status)).font(.system(size: 11))
                    Text(id).font(Theme.body)
                    if let a = st?.agent { Text(a).font(Theme.caption).foregroundStyle(.secondary) }
                    if let why = st?.why { Text(why).font(Theme.caption).foregroundStyle(.tertiary).lineLimit(1) }
                    Spacer()
                    Button("Output") { NSWorkspace.shared.open(run.dir.appendingPathComponent("nodes/\(id)/output.log")) }
                        .buttonStyle(.borderless).controlSize(.small)
                }
            }
        }
    }

    /// The pipeline's shape, a column for each depth, and the path this run took picked out.
    @ViewBuilder private func graph(_ state: RunState?) -> some View {
        let g = PipelineGraph(pipeline)
        if g.ids.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: Theme.s2) {
                    ForEach(Array(g.layers().enumerated()), id: \.offset) { i, layer in
                        if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary) }
                        VStack(alignment: .leading, spacing: Theme.s1) {
                            ForEach(layer, id: \.self) { id in
                                let st = state?.steps[id]
                                let walked = state?.path.contains(id) == true
                                HStack(spacing: 4) {
                                    if g.step(id)?.ui == true { Image(systemName: "display").font(.system(size: 9)) }
                                    Text(id).font(Theme.monoSmall)
                                }
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(walked ? tint(st?.status).opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(walked ? tint(st?.status).opacity(0.6) : Theme.hairline))
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func icon(_ status: String?) -> String {
        switch status {
        case "done": return "checkmark.circle.fill"
        case "failed": return "xmark.octagon.fill"
        case "parked": return "questionmark.circle.fill"
        case "skipped": return "arrow.turn.down.right"
        case "running": return "circle.dotted"
        default: return "circle"
        }
    }

    private func tint(_ status: String?) -> Color {
        switch status {
        case "failed": return Theme.danger
        case "parked": return Theme.warn
        case "skipped", "waiting", .none: return .secondary
        default: return Theme.accent
        }
    }

    /// What the run is waiting on: buttons where choices fit, and a reply field for a free question.
    @ViewBuilder private func questions(_ run: (dir: URL, state: RunState)) -> some View {
        let parked = run.state.steps.filter { $0.value.status == "parked" }.sorted { $0.key < $1.key }
        ForEach(parked, id: \.key) { id, st in
            if let q = st.question {
                VStack(alignment: .leading, spacing: Theme.s2) {
                    Text(q.who.map { "\($0), on \(id)" } ?? id).font(Theme.caption).foregroundStyle(.secondary)
                    Text(q.text).font(Theme.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let detail = try? String(contentsOf: run.dir.appendingPathComponent("nodes/\(id)/detail.txt"), encoding: .utf8) {
                        Text(detail).font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(8).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if q.kind == "conflict", let folder = detailFolder(run, id) {
                        IconButton("Open a shell there", "terminal") { openShell(folder) }.controlSize(.small)
                    }
                    if !q.choices.isEmpty {
                        HStack(spacing: Theme.s2) {
                            ForEach(q.choices, id: \.self) { c in Button(c) { answer(run, id, c) }.controlSize(.small) }
                        }
                    }
                    if q.choices.isEmpty || q.kind == "question" {
                        HStack(spacing: Theme.s2) {
                            TextField("Your answer", text: Binding(get: { reply[id] ?? "" }, set: { reply[id] = $0 }))
                                .textFieldStyle(.roundedBorder).controlSize(.small)
                            Button("Send") { answer(run, id, reply[id] ?? "") }.controlSize(.small).disabled((reply[id] ?? "").isEmpty)
                        }
                    }
                }
                .padding(Theme.s3)
                .background(Theme.warn.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.radius))
            }
        }
    }

    private func detailFolder(_ run: (dir: URL, state: RunState), _ id: String) -> URL? {
        let text = (try? String(contentsOf: run.dir.appendingPathComponent("nodes/\(id)/detail.txt"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").first.map { URL(fileURLWithPath: String($0)) }
    }

    private func openShell(_ folder: URL) {
        let owner = pipeline.project.flatMap { p in model.projects.first { $0.id == p.standardizedFileURL.path || $0.id == p.path } }
        model.newTab(title: "Resolve \(pipeline.name)", command: nil, dir: folder, project: owner)
    }

    private func answer(_ run: (dir: URL, state: RunState), _ step: String, _ text: String) {
        reply[step] = nil
        act(["pipeline", "answer", "\(run.state.run)", step, text] + scope)
    }

    /// The window asks instead of the CLI's two flags when the file changed since the run began.
    private func resume(_ run: (dir: URL, state: RunState)) {
        let args = ["pipeline", "resume", "\(run.state.run)"] + scope
        let copy = (try? String(contentsOf: run.dir.appendingPathComponent("pipeline.md"), encoding: .utf8)) ?? ""
        let named = run.state.file.map { URL(fileURLWithPath: $0) }
        let edited = named.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        var flag = "--copy"
        if let edited, Pipelines.render(Pipelines.parse(edited, url: named)) != Pipelines.render(Pipelines.parse(copy, url: named)) {
            flag = AppModel.confirm("The pipeline changed since this run began", "Carry on with the edited file? Otherwise it follows its own copy.", "Use the edited file") ? "--file" : "--copy"
        }
        let owner = pipeline.project.flatMap { p in model.projects.first { $0.id == p.standardizedFileURL.path || $0.id == p.path } }
        model.newTab(title: pipeline.name, command: (["apprentice"] + args + [flag]).map(VM.shellQuoted).joined(separator: " ") + "; echo; exec \"$SHELL\" -l", dir: pipeline.folder, vm: pipeline.effectiveVM, project: owner)
    }

    private func act(_ argv: [String]) {
        model.runCLI(argv) { code, out in
            output = code == 0 ? "" : out
            reload()
        }
    }

    private func reload() {
        runs = Runs.all(project: pipeline.project, slug: pipeline.slug)
    }

    private func loadNotes() { notes = PipelineCLI.pastNotes(pipeline) }
}
