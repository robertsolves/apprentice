import AppKit
import SwiftUI

/// Settings ▸ Agents: the named agents pipelines use, for everything (`project` nil) or for one project, which
/// shows what it inherits, marked Global, This project or Changed here. Every change goes through `agents`, so the
/// window and the CLI write the same file, and nobody ever types the file by hand.
struct AgentsPanel: View {
    @ObservedObject var model: AppModel
    let project: Projects.Info?
    @State private var agents: [NamedAgents.Named] = []
    @State private var defaults = NamedAgents.Defaults()
    @State private var editing: AgentDraft?
    @State private var testing: String?
    @State private var results: [String: String] = [:]
    @State private var installed: Set<String> = []
    @State private var output = ""

    struct AgentDraft: Identifiable {
        var id = UUID()
        var name = ""
        var cli = AgentCLIs.agents().first { !$0.shell }?.id ?? ""
        var model = ""
        var effort = ""
        var permissions = "edit"
        var isNew = true
    }

    private var folder: URL? { project?.folder }
    private var scopeArgs: [String] { project.map { ["--project", $0.folder.path] } ?? [] }
    private var names: [String] { agents.map(\.name) }

    var body: some View {
        Panel(title: "Agents", note: "\(agents.count)") {
            Text(project == nil
                 ? "A named agent is one of your agent programs with its model, effort and permissions. Pipelines use them by name. Projects get all of these and can change them."
                 : "Everything this project can use. Change one just for this project, or add one only it has.")
                .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(agents, id: \.name) { row($0) }
            HStack(spacing: Theme.s2) {
                IconButton("New agent", "plus") { editing = AgentDraft() }
                Spacer()
            }
            .controlSize(.small)
            Divider()
            choice("Chooses branches", value: defaults.interpreter ?? "", key: "interpreter")
            Text("Which step comes next, when a step has several to choose from.").font(Theme.caption).foregroundStyle(.tertiary)
            choice("Writes summaries and notes", value: defaults.scribe.first ?? "", key: "scribe")
            Text("It reads each finished step and writes what the next steps need, and a note when a run ends.").font(Theme.caption).foregroundStyle(.tertiary)
            Divider()
            Text("Priority: if an agent runs out of tokens or stalls, the next one here takes over.").font(Theme.caption).foregroundStyle(.secondary)
            ForEach(Array(defaults.priority.enumerated()), id: \.offset) { i, name in
                HStack(spacing: Theme.s2) {
                    Text("\(i + 1)").font(Theme.monoSmall).foregroundStyle(.tertiary).frame(width: 16)
                    Text(name).font(Theme.body)
                    Spacer()
                    Button { movePriority(i, by: -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).disabled(i == 0)
                    Button { movePriority(i, by: 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless).disabled(i == defaults.priority.count - 1)
                    Button { var p = defaults.priority; p.remove(at: i); setPriority(p) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            let rest = names.filter { !defaults.priority.contains($0) }
            if !rest.isEmpty {
                Menu("Add to the list") {
                    ForEach(rest, id: \.self) { n in Button(n) { setPriority(defaults.priority + [n]) } }
                }
                .controlSize(.small).fixedSize()
            }
            if project == nil { installRows }
            if !output.isEmpty { Output(text: output) }
        }
        .onAppear(perform: load)
        .sheet(item: $editing) { draft in
            AgentForm(draft: draft, project: project) { args in
                editing = nil
                guard let args else { return }
                run(["agents", "set"] + args + scopeArgs)
            }
        }
    }

    private func row(_ n: NamedAgents.Named) -> some View {
        VStack(alignment: .leading, spacing: Theme.s1) {
            HStack(spacing: Theme.s2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(n.name).font(Theme.body)
                    Text([AgentCLIs.label(n.agent), n.model, n.effort.map { "effort \($0)" }, n.permissions].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if project != nil { StatusPill(text: n.originLabel, tint: n.origin == .global ? .secondary : Theme.accent) }
                Spacer()
                Button(testing == n.name ? "Testing…" : "Test") { test(n) }
                    .controlSize(.small).disabled(testing != nil)
                    .help("Sends one tiny real prompt, which spends a few tokens, so a wrong model name shows before a run.")
                Button(project != nil && n.origin == .global ? "Customise" : "Change") {
                    editing = AgentDraft(name: n.name, cli: n.agent, model: n.model ?? "", effort: n.effort ?? "", permissions: n.permissions ?? "", isNew: false)
                }
                .controlSize(.small)
                if project == nil || n.origin != .global {
                    Button(project != nil && n.origin == .changedHere ? "Reset to global" : "Remove") { run(["agents", "rm", n.name] + scopeArgs) }.controlSize(.small)
                }
            }
            if let r = results[n.name] { Text(r).font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled) }
            ForEach(NamedAgents.problems(n), id: \.self) { Text($0).font(Theme.caption).foregroundStyle(Theme.warn) }
        }
    }

    private func choice(_ title: String, value: String, key: String) -> some View {
        LabeledField(title) {
            Picker("", selection: Binding(get: { value }, set: { new in
                run(["agents", "defaults"] + (new.isEmpty ? ["--no-\(key)"] : ["--\(key)", new]) + scopeArgs)
            })) {
                Text(project == nil ? "Not chosen" : "As set for everything").tag("")
                ForEach(names, id: \.self) { Text($0).tag($0) }
                if !value.isEmpty, !names.contains(value) { Text(value).tag(value) }
            }
            .labelsHidden().pickerStyle(.menu).frame(maxWidth: 280, alignment: .leading)
        }
    }

    /// One-click install: types the CLI's own install line into a shell tab, where the person sees it run.
    @ViewBuilder private var installRows: some View {
        let missing = AgentCLIs.agents().filter { !$0.shell && !$0.detect.isEmpty && !installed.contains($0.id) }
        if !missing.isEmpty, !installed.isEmpty {
            Divider()
            Text("Not on this Mac yet").font(Theme.caption).foregroundStyle(.secondary)
            ForEach(missing) { cli in
                HStack(spacing: Theme.s2) {
                    Text(cli.label).font(Theme.body)
                    Spacer()
                    if let line = cli.installCommand, let p = model.workProject ?? model.projects.first {
                        Button("Install") { model.newTab(title: "Install \(cli.label)", command: line + "; echo; exec \"$SHELL\" -l", project: p) }.controlSize(.small).help(line)
                    } else if let url = cli.install.flatMap(URL.init(string:)) {
                        Button("Get it") { NSWorkspace.shared.open(url) }.controlSize(.small)
                    }
                }
            }
        }
    }

    private func load() {
        agents = NamedAgents.all(project: folder)
        defaults = NamedAgents.defaults(project: folder)
        DispatchQueue.global(qos: .utility).async {
            let found = AgentCLIs.installed()
            DispatchQueue.main.async { installed = found }
        }
    }

    private func run(_ argv: [String]) {
        model.runCLI(argv) { code, out in
            output = code == 0 ? "" : out
            load()
        }
    }

    private func movePriority(_ i: Int, by offset: Int) {
        var p = defaults.priority
        guard p.indices.contains(i + offset) else { return }
        p.swapAt(i, i + offset)
        setPriority(p)
    }

    private func setPriority(_ p: [String]) {
        run(["agents", "defaults"] + (p.isEmpty ? ["--no-priority"] : ["--priority", p.joined(separator: ",")]) + scopeArgs)
    }

    private func test(_ n: NamedAgents.Named) {
        testing = n.name
        results[n.name] = nil
        model.runCLI(["agents", "test", n.name] + scopeArgs) { _, out in
            testing = nil
            results[n.name] = out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// New or change one agent: a name, a CLI, and only the settings that CLI can really apply.
struct AgentForm: View {
    @State var draft: AgentsPanel.AgentDraft
    let project: Projects.Info?
    let done: ([String]?) -> Void
    private let started: AgentsPanel.AgentDraft

    init(draft: AgentsPanel.AgentDraft, project: Projects.Info?, done: @escaping ([String]?) -> Void) {
        _draft = State(initialValue: draft)
        started = draft
        self.project = project
        self.done = done
    }

    private var clis: [AgentCLIs.CLI] { AgentCLIs.agents().filter { !$0.shell && !$0.run.isEmpty } }
    private var cli: AgentCLIs.CLI? { AgentCLIs.find(draft.cli) }

    var body: some View {
        SheetFrame(title: draft.isNew ? "New agent" : draft.name, subtitle: "Pipelines use it by this name.", idealHeight: 380) {
            Panel(title: "Agent") {
                LabeledField("Name") {
                    TextField("Joseph", text: $draft.name).disabled(!draft.isNew)
                }
                if !draft.name.isEmpty, !NamedAgents.validName(draft.name) {
                    LabeledField("") { Text("Letters, digits and _ only.").font(Theme.caption).foregroundStyle(Theme.warn) }
                }
                LabeledField("Program") {
                    Picker("", selection: $draft.cli) {
                        ForEach(clis) { Text($0.label).tag($0.id) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(maxWidth: 240, alignment: .leading)
                }
                LabeledField("Model") {
                    if cli?.modelFlags.isEmpty == false { TextField("its default", text: $draft.model).font(Theme.mono) }
                    else { Text("\(cli?.label ?? "This program") has no model setting.").font(Theme.caption).foregroundStyle(.secondary) }
                }
                LabeledField("Effort") {
                    if cli?.effortFlags.isEmpty == false { TextField("its default", text: $draft.effort).font(Theme.mono) }
                    else { Text("\(cli?.label ?? "This program") has no effort setting.").font(Theme.caption).foregroundStyle(.secondary) }
                }
                LabeledField("Permissions") {
                    if cli?.levels.isEmpty == false {
                        Picker("", selection: $draft.permissions) {
                            Text("As the program starts").tag("")
                            ForEach(cli?.levels ?? [], id: \.self) { Text(label($0)).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.menu).frame(maxWidth: 280, alignment: .leading)
                    } else {
                        Text("\(cli?.label ?? "This program") cannot enforce a level.").font(Theme.caption).foregroundStyle(.secondary)
                    }
                }
                if cli?.sealed.contains(draft.permissions) == true {
                    LabeledField("") {
                        Text("At this level its sandbox stops apprentice's commands: it can read the board, but not post on it or ask you anything.")
                            .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } buttons: {
            Spacer()
            Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
            Button("Save") {
                // Only what changed: a project's copy of a global agent should go on following the rest of it.
                var args = [draft.name]
                if draft.isNew || draft.cli != started.cli { args += ["--agent", draft.cli] }
                if draft.isNew || draft.model != started.model { args += draft.model.isEmpty ? ["--no-model"] : ["--model", draft.model] }
                if draft.isNew || draft.effort != started.effort { args += draft.effort.isEmpty ? ["--no-effort"] : ["--effort", draft.effort] }
                if draft.isNew || draft.permissions != started.permissions { args += draft.permissions.isEmpty ? ["--no-permissions"] : ["--permissions", draft.permissions] }
                done(args.count > 1 ? args : nil)
            }
            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            .disabled(!NamedAgents.validName(draft.name))
        }
    }

    private func label(_ level: String) -> String {
        switch level {
        case "read-only": return "Read only"
        case "edit": return "Edit this project's files"
        default: return "Everything, with no sandbox"
        }
    }
}

/// Settings ▸ Storage: what agents' sessions and apprentice's own run caches take up.
struct StoragePanel: View {
    @ObservedObject var model: AppModel
    @State private var report = ""
    @State private var working = false

    var body: some View {
        Panel(title: "Storage") {
            Text("Every pipeline step is a session in its agent's program. Apprentice removes the ones it started as soon as they are done, and old run output after a while. Your own sessions are yours: it only shows how much they take up.")
                .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.s2) {
                IconButton(report.isEmpty ? "Show what is stored" : "Refresh", "externaldrive") { run(["tidy", "--look"]) }
                IconButton("Clean up apprentice's now", "sparkles") { run(["tidy", "--report"]) }
                if working { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
            if !report.isEmpty { Output(text: report) }
        }
    }

    private func run(_ argv: [String]) {
        working = true
        model.runCLI(argv) { _, out in
            report = out
            working = false
        }
    }
}

/// Settings ▸ Pipelines: the time limits and how long a run's traces stay.
struct PipelineSettingsPanel: View {
    @ObservedObject var model: AppModel
    @State private var stall = ""
    @State private var total = ""
    @State private var outputs = ""
    @State private var sessions = ""

    var body: some View {
        Panel(title: "Pipelines") {
            field("Stalled after (min)", $stall, key: "stall_min", fallback: "10", help: "No output and no file change for this long: the next agent takes over. Waiting for you does not count.")
            field("Stopped after (min)", $total, key: "step_max_min", fallback: "60", help: "The longest one step may run.")
            field("Keep run output (days)", $outputs, key: "keep_outputs_days", fallback: "30", help: "Notes are kept for good.")
            field("Keep agents' sessions (days)", $sessions, key: "keep_sessions_days", fallback: "0", help: "0 removes each session when its step ends. Keep them longer to debug with an agent's own resume.")
        }
        .onAppear {
            stall = PipelineSettings.value("stall_min", project: nil) ?? ""
            total = PipelineSettings.value("step_max_min", project: nil) ?? ""
            outputs = PipelineSettings.value("keep_outputs_days", project: nil) ?? ""
            sessions = PipelineSettings.value("keep_sessions_days", project: nil) ?? ""
        }
    }

    private func field(_ title: String, _ value: Binding<String>, key: String, fallback: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledField(title) {
                TextField(fallback, text: value).frame(maxWidth: 80)
                    .onSubmit { write(key, value.wrappedValue) }
                    .onChange(of: value.wrappedValue) { _, v in write(key, v) }
            }
            Text(help).font(Theme.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func write(_ key: String, _ value: String) {
        let t = value.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { Toml.remove(Config.path, "pipelines", key) }
        else if let n = Double(t), n >= 0 { Toml.set(Config.path, "pipelines", key, t.contains(".") ? "\(n)" : "\(Int(n))") }
    }
}
