import AppKit
import SwiftUI

/// What the Run bar holds for a project until it is used. It lives on the model: changing tab rebuilds the screen.
struct RunDraft {
    /// The chosen pipeline's id; empty for a task typed here.
    var pipeline = ""
    var first = ""
    var last = ""
}

/// How a project's work starts, in the order you do it: open your agent in the tab below, choose what to run and type
/// what is different this time, then Run. The steps run headless; an agent open in the tab is told to direct them.
struct RunBar: View {
    @ObservedObject var model: AppModel
    let project: Projects.Info
    /// The agent open in the tab on screen, nil for a shell.
    let agent: AgentCLIs.CLI?
    /// Types a line into that tab and presses Return.
    let type: (String) -> Void
    @AppStorage("work.runBarOpen") private var open = true
    @AppStorage("work.runBoxesBig") private var big = false
    @State private var problem = ""
    @State private var starting = false
    @State private var latest: (dir: URL, state: RunState)?
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var draft: Binding<RunDraft> {
        Binding(get: { model.runDrafts[project.id] ?? RunDraft() }, set: { model.runDrafts[project.id] = $0 })
    }

    private var chosen: Pipelines.Pipeline? { model.pipelinesIn(project).first { $0.id == draft.wrappedValue.pipeline } }

    private func typed(_ text: String) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
                number(1)
                Text(agent.map { "\($0.label) is open in the tab below. It will direct the run: watch the steps, check their work and steer them." }
                     ?? "Open your agent in the tab below, by typing its name, and it will direct the run. Without one, the run goes on its own.")
                    .font(Theme.caption).foregroundStyle(agent == nil ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.s2)
                Button { open.toggle() } label: { Image(systemName: open ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.borderless).help(open ? "Fold this away" : "Show it")
            }
            if open {
                HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
                    number(2)
                    Picker("", selection: Binding(get: { draft.wrappedValue.pipeline }, set: { draft.wrappedValue.pipeline = $0 })) {
                        Text("Just this task").tag("")
                        ForEach(model.pipelinesIn(project)) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    if let chosen { stepsLine(chosen) }
                    Spacer(minLength: 0)
                    Button(big ? "Less room" : "More room") { big.toggle() }.buttonStyle(.borderless).controlSize(.small)
                }
                boxes
                HStack(spacing: Theme.s2) {
                    number(3)
                    IconButton(starting ? "Starting…" : "Run", "play.fill", prominent: true, action: start)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(starting || (chosen == nil && !typed(draft.wrappedValue.first)))
                    if !problem.isEmpty {
                        Text(problem).font(Theme.caption).foregroundStyle(Theme.danger).lineLimit(2).textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
            }
            if let latest { runLine(latest) }
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.s3)
        .padding(.vertical, Theme.s2)
        .background(.bar)
        .onAppear(perform: reload)
        .onReceive(tick) { _ in reload() }
    }

    private func number(_ n: Int) -> some View {
        Text("\(n)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(Circle().fill(Theme.accent))
    }

    /// A pipeline's steps as this run would take them, with who runs each.
    private func stepsLine(_ p: Pipelines.Pipeline) -> some View {
        let steps = Pipelines.forRun(p, first: draft.wrappedValue.first, last: draft.wrappedValue.last).steps
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.s1) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    if i > 0 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary) }
                    Text(step.title + (step.use.map { " · \($0)" } ?? ""))
                        .font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder private var boxes: some View {
        if chosen == nil {
            box("What to do", "Tell this project what to do, as you would in a chat. It runs once, and stays out of your pipelines.", \.first)
        } else {
            HStack(alignment: .top, spacing: Theme.s2) {
                box("First, just this run (optional)", "What is different this time. It runs before every step, and the pipeline does not change.", \.first)
                box("Last, just this run (optional)", "What to do once every step has finished, this time only.", \.last)
            }
        }
    }

    private func box(_ title: String, _ hint: String, _ key: WritableKeyPath<RunDraft, String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.caption).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { draft.wrappedValue[keyPath: key] }, set: { draft.wrappedValue[keyPath: key] = $0 }))
                    .font(Theme.body)
                    .scrollContentBackground(.hidden)
                if draft.wrappedValue[keyPath: key].isEmpty {
                    Text(hint).font(Theme.body).foregroundStyle(.tertiary).padding(.horizontal, 5).allowsHitTesting(false)
                }
            }
            .padding(Theme.s1)
            .frame(height: big ? 220 : 72)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The project's latest run, one line, with a way to its page: waiting questions and each step's work are there.
    private func runLine(_ run: (dir: URL, state: RunState)) -> some View {
        let s = run.state
        let parked = s.steps.filter { $0.value.status == "parked" }
        let now = s.steps.filter { $0.value.status == "running" }.keys.sorted().joined(separator: ", ")
        let dead = s.status == "running" && s.pid != nil && !Runs.alive(s.pid)
        let label = dead ? "stopped unexpectedly" : !parked.isEmpty ? "waiting for an answer" : s.status == "running" ? "running" + (now.isEmpty ? "" : ": \(now)") : s.status
        return HStack(spacing: Theme.s2) {
            StatusPill(text: label, tint: s.status == "failed" || dead ? Theme.danger : parked.isEmpty ? Theme.accent : Theme.warn)
            Text("Run \(s.run) · \(s.name)" + (Runs.directed(run.dir) ? " · your agent is directing it" : ""))
                .font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: Theme.s2)
            Button("See it") { if let p = s.file.flatMap({ try? Pipelines.find($0) }) { model.editPipeline(p) } }
                .buttonStyle(.borderless)
        }
    }

    private func reload() {
        latest = Runs.numbers(project: project.folder).last.flatMap { n in
            let dir = Runs.root(project: project.folder).appendingPathComponent("\(n)")
            return Runs.load(dir).map { (dir, $0) }
        }
    }

    private func start() {
        problem = ""
        starting = agent != nil
        model.startRun(draft.wrappedValue, in: project, agent: agent, type: type) { trouble in
            starting = false
            problem = trouble ?? ""
            reload()
        }
    }
}

extension AppModel {
    /// Starts what the Run bar holds. With an agent open in the tab, the run goes in the background and that agent is
    /// told to direct it; without one, it shows in a tab of its own. `done` has what went wrong, if anything.
    func startRun(_ d: RunDraft, in project: Projects.Info, agent: AgentCLIs.CLI?, type: @escaping (String) -> Void, done: @escaping (String?) -> Void) {
        func typed(_ text: String) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let chosen = pipelinesIn(project).first { $0.id == d.pipeline }
        var args: [String]
        let title: String
        if let chosen {
            args = ["pipeline", "run", chosen.url?.path ?? chosen.ref]
            if typed(d.first) { args.append("--first=\(d.first)") }
            if typed(d.last) { args.append("--last=\(d.last)") }
            title = chosen.name
        } else {
            guard typed(d.first) else { done(nil); return }
            args = ["pipeline", "task", d.first, "--project", project.folder.path]
            title = Pipelines.taskName(d.first)
        }
        let vm = chosen?.effectiveVM ?? project.vm
        guard agent != nil else {
            runDrafts[project.id] = RunDraft(pipeline: d.pipeline)
            let line = (["apprentice"] + args).map(VM.shellQuoted).joined(separator: " ")
            newTab(title: title, command: line + "; echo; exec \"$SHELL\" -l", dir: project.folder, vm: vm, project: project)
            done(nil)
            return
        }
        runCLI((vm.map { ["--vm", $0] } ?? []) + args + ["--background", "--directed"]) { code, out in
            guard code == 0, let line = out.split(separator: "\n").first(where: { $0.hasPrefix("run ") && $0.contains(" started") }),
                  let n = line.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
                done(out.isEmpty ? "It did not start." : out)
                return
            }
            self.runDrafts[project.id] = RunDraft(pipeline: d.pipeline)
            type(PipelineCLI.directLine(n))
            self.refresh()
            done(nil)
        }
    }
}

/// `APPRENTICE_APP_RUNTEST=<file>` with `APPRENTICE_APP_RUNTEST_AGENT=<path>`: an agent opened in a tab and a press of
/// Run, end to end. The agent is a stand-in named like a CLI and given by its full path, because a name would be looked
/// up in the login shell and could start the real one. Writes what it saw to the file and quits.
enum RunTest {
    static func run(model: AppModel, out: String) {
        var log: [String] = []
        func finish() {
            try? log.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            exit(0)
        }
        guard let standIn = ProcessInfo.processInfo.environment["APPRENTICE_APP_RUNTEST_AGENT"], standIn.hasPrefix("/") else {
            log.append("no stand-in agent given")
            finish()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let project = model.projects.first, let pipeline = model.pipelinesIn(project).first, let tab = model.selectedSession else { log.append("no project, pipeline or tab"); finish(); return }
            let clis = AgentCLIs.agents()
            log.append("shell tab, agent: \(tab.agentInFront(among: clis)?.id ?? "none")")
            model.runDrafts[project.id] = RunDraft(pipeline: pipeline.id, first: "Do this first", last: "Do this last")
            tab.send(standIn + "\r")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let agent = tab.agentInFront(among: clis) else {
                    let rows = (0..<tab.screen.rows).map { tab.screen.rowText($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    log.append("no agent seen in the tab: \(tab.frontDescription)\n  " + rows.joined(separator: "\n  "))
                    finish()
                    return
                }
                log.append("agent tab, agent: \(agent.id)")
                model.startRun(RunDraft(pipeline: pipeline.id, first: "Do this first", last: "Do this last"), in: project, agent: agent, type: { line in
                    tab.send(line)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { tab.send("\r") }
                }) { trouble in
                    log.append("started, trouble: \(trouble ?? "none")")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                        let rows = (0..<tab.screen.rows).map { tab.screen.rowText($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        log.append("the tab shows:\n  " + rows.joined(separator: "\n  "))
                        if let n = Runs.numbers(project: project.folder).last, let s = Runs.load(Runs.root(project: project.folder).appendingPathComponent("\(n)")) {
                            log.append("run \(n): \(s.status), path \(s.path.joined(separator: " > ")), directed \(Runs.directed(Runs.root(project: project.folder).appendingPathComponent("\(n)")))")
                        }
                        finish()
                    }
                }
            }
        }
    }
}
