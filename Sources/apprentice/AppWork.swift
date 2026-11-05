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
        .task {
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
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

    /// The project's run that is waiting for the user, else its latest, one line, with a way to its page.
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
            if let q = parked.first?.value.question, !Runs.directed(run.dir) || RunQuestion.userOnly.contains(q.kind) {
                Text(q.text.components(separatedBy: .newlines).first ?? "").font(Theme.caption).foregroundStyle(.primary).lineLimit(1).help(q.text)
            }
            Spacer(minLength: Theme.s2)
            Button(parked.isEmpty ? "See it" : "Answer") { if let p = s.file.flatMap({ try? Pipelines.find($0) }) { model.editPipeline(p) } }
                .buttonStyle(.borderless)
        }
    }

    private func reload() {
        // What is waiting for the user comes before whatever ran last.
        let waiting = model.waitingRuns.first { $0.project.standardizedFileURL.path == project.id }?.run
        latest = (waiting ?? Runs.numbers(project: project.folder).last).flatMap { n in
            let dir = Runs.root(project: project.folder).appendingPathComponent("\(n)")
            return Runs.load(dir).map { (dir, $0) }
        }
    }

    private func start() {
        problem = ""
        // A command typed into these boxes is the user's own.
        for text in [draft.wrappedValue.first, draft.wrappedValue.last] {
            if let command = Pipelines.Step(title: "", prompt: text).shell { NamedAgents.approveShell(command, project: project.folder) }
        }
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

#if DEBUG
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

/// `APPRENTICE_APP_UIDRIVE=<folder>`, debug builds only: testing the window from inside it, one command at a time,
/// without the person's cursor. A line written to `<folder>/in` runs, and its answer lands in `<folder>/out`. Never in a
/// release build: it would let anything on this Mac press the window's Allow, which is why apprentice's own commands
/// refuse this window as a target.
///
///     tree [filter]   the window's controls, numbered, with their frames
///     press <n>       the control's own press
///     click <x> <y>   a click, in the window's points from its top-left
///     text <words>    types into whatever has the keyboard
///     key <name>      return | cmd+return | escape | tab
///     focus <n>       gives the control the keyboard
///     term <words>    types into the terminal on screen, then Return
///     screen          the terminal's lines
enum UIDrive {
    private static var nodes: [NSAccessibilityProtocol] = []
    private static var keep: Timer?

    private static var target: NSWindow? {
        NSApp.modalWindow ?? NSApp.keyWindow?.attachedSheet ?? NSApp.mainWindow?.attachedSheet ?? NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
    }

    static func run(model: AppModel, folder: String) {
        let input = URL(fileURLWithPath: folder).appendingPathComponent("in")
        let output = URL(fileURLWithPath: folder).appendingPathComponent("out")
        let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
            guard let line = try? String(contentsOf: input, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(at: input)
            let answer = handle(line.trimmingCharacters(in: .whitespacesAndNewlines), model: model)
            try? answer.write(to: output, atomically: true, encoding: .utf8)
        }
        // Common modes: the timer has to go on firing while an alert or a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        keep = timer
    }

    private static func walk(_ node: Any, depth: Int, into out: inout [String], filter: String?) {
        guard let e = node as? NSAccessibilityProtocol, depth < 40 else { return }
        let role = e.accessibilityRole()?.rawValue.replacingOccurrences(of: "AX", with: "") ?? "?"
        let label = [e.accessibilityLabel(), e.accessibilityTitle(), e.accessibilityValue().flatMap { $0 as? String }, e.accessibilityHelp()]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " | ")
        let plain = ["Group", "ScrollArea", "SplitGroup", "Unknown", "Window", "?", "Layout Area"].contains(role) && label.isEmpty
        if !plain {
            nodes.append(e)
            let f = e.accessibilityFrame()
            let w = target?.frame ?? .zero
            let line = "\(nodes.count - 1) \(role) \"\(String(label.prefix(90)))\" @\(Int(f.minX - w.minX)),\(Int(w.maxY - f.maxY)) \(Int(f.width))x\(Int(f.height))" + (e.isAccessibilityEnabled() ? "" : " disabled")
            if filter == nil || line.lowercased().contains(filter!) { out.append(line) }
        }
        for child in e.accessibilityChildren() ?? [] { walk(child, depth: depth + 1, into: &out, filter: filter) }
    }

    private static func keyEvent(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) {
        guard let w = target else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                                        characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) { NSApp.sendEvent(e) }
        }
    }

    private static func handle(_ line: String, model: AppModel) -> String {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let rest = parts.count > 1 ? parts[1] : ""
        guard let w = target else { return "no window" }
        switch parts.first ?? "" {
        case "tree":
            nodes = []
            var out = ["window \"\(w.title)\" \(Int(w.frame.width))x\(Int(w.frame.height))" + (NSApp.modalWindow != nil ? " modal" : "") + (w.isSheet ? " sheet" : "")]
            walk(w, depth: 0, into: &out, filter: rest.isEmpty ? nil : rest.lowercased())
            return out.joined(separator: "\n")
        case "press":
            guard let n = Int(rest), nodes.indices.contains(n) else { return "no such control" }
            DispatchQueue.main.async { _ = nodes[n].accessibilityPerformPress() }
            return "pressed \(n)"
        case "focus":
            guard let n = Int(rest), nodes.indices.contains(n) else { return "no such control" }
            nodes[n].setAccessibilityFocused(true)
            return "focused \(n), responder \(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")"
        case "click":
            let xy = rest.split(separator: " ").compactMap { Double($0) }
            guard xy.count == 2 else { return "click x y" }
            let p = NSPoint(x: xy[0], y: w.frame.height - xy[1])
            func mouse(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            // The release is queued first: a button's press waits for it, and sending it afterwards would never be reached.
            if let up = mouse(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
            if let down = mouse(.leftMouseDown) { NSApp.sendEvent(down) }
            return "clicked \(xy), hit \(w.contentView?.hitTest(p).map { String(describing: type(of: $0)) } ?? "nil"), responder \(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")"
        case "text":
            if let view = w.firstResponder as? NSTextView { view.insertText(rest, replacementRange: view.selectedRange()); return "typed into \(type(of: view))" }
            for ch in rest { keyEvent(0, String(ch)) }
            return "sent keys to \(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")"
        case "key":
            switch rest {
            case "return": keyEvent(36, "\r")
            case "cmd+return": keyEvent(36, "\r", .command)
            case "escape": keyEvent(53, "\u{1b}")
            case "tab": keyEvent(48, "\t")
            default: return "unknown key"
            }
            return "key \(rest)"
        case "term":
            guard let tab = model.selectedSession else { return "no tab" }
            tab.send(rest)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { tab.send("\r") }
            return "sent to \(tab.title)"
        case "screen":
            guard let tab = model.selectedSession else { return "no tab" }
            let rows = (0..<tab.screen.rows).map { tab.screen.rowText($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return "tab \(tab.title) · \(tab.frontDescription)\n" + rows.joined(separator: "\n")
        default:
            return "unknown command"
        }
    }
}
#endif
