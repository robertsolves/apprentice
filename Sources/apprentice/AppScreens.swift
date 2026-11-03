import AppKit
import SwiftUI

/// The window's Projects, Pipelines and VMs screens, and the explanation every screen opens with. Each
/// button runs the same command a person would type (`project`, `pipeline`, `vm`), or writes the same file.

extension Projects.Info: Identifiable { var id: String { folder.path } }
extension Pipelines.Pipeline: Identifiable { var id: String { url?.path ?? ref } }

/// What a screen is for, in plain words, at the top of it: a blue icon, a line or two, and how to use it.
struct Explainer: View {
    let icon: String
    let title: String
    let text: String
    var points: [String] = []

    var body: some View {
        HStack(alignment: .top, spacing: Theme.s4) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Theme.accent)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: Theme.s2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(text)
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !points.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(points, id: \.self) { point in
                            HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Theme.accent)
                                Text(point).font(Theme.body).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(Theme.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.accent.opacity(0.25)))
    }
}

/// A button with a blue SF Symbol before its title.
struct IconButton: View {
    let title: String
    let icon: String
    var prominent = false
    let action: () -> Void

    init(_ title: String, _ icon: String, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        if prominent {
            Button(action: action) { Label(title, systemImage: icon) }
                .buttonStyle(.borderedProminent)
        } else {
            Button(action: action) {
                Label { Text(title) } icon: { Image(systemName: icon).foregroundStyle(Theme.accent) }
            }
        }
    }
}

/// A list row: a blue icon, a name and a quieter line under it.
struct IconRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: Theme.s3) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Theme.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(detail).font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

/// The list column of a two-pane screen: a count, a New button, and the rows.
struct ListColumn<Rows: View>: View {
    let count: String
    let newTitle: String
    let new: () -> Void
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(count).font(Theme.monoSmall).foregroundStyle(.secondary)
                Spacer()
                Button(action: new) { Label(newTitle, systemImage: "plus") }.controlSize(.small)
            }
            .padding(.horizontal, Theme.s3)
            .padding(.vertical, Theme.s2)
            Divider()
            rows()
        }
    }
}

/// The agent CLI a project or pipeline names, as a tab's start command (nil: a plain shell).
enum AgentChoice {

    static func command(_ agent: String) -> String? { AgentCLIs.find(agent).map(\.open) ?? agent }
    static func label(_ agent: String) -> String { AgentCLIs.label(agent) }
}

// MARK: - Projects

/// A project's Settings tab: how it runs, its notes for agents, and saving it.
struct ProjectDetail: View {
    @ObservedObject var model: AppModel
    let project: Projects.Info
    @State private var output = ""
    @State private var remote: String?

    private var pipelines: [Pipelines.Pipeline] {
        model.pipelines.filter { $0.project?.standardizedFileURL.path == project.folder.standardizedFileURL.path }
    }

    var body: some View {
        ScreenPage(title: "Settings", subtitle: (project.folder.path as NSString).abbreviatingWithTildeInPath) {
            AnyView(IconButton("Open", "play.fill", prominent: true) { model.openProject(project) })
        } content: {
            Panel(title: "How it runs") {
                LabeledField("Agent") {
                    Picker("", selection: Binding(get: { project.agent }, set: { change(["--agent", $0]) })) {
                        ForEach(model.agentChoices(keeping: project.agent), id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(maxWidth: 280)
                }
                LabeledField("Runs on") {
                    Picker("", selection: Binding(get: { project.vm ?? "" }, set: { change($0.isEmpty ? ["--no-vm"] : ["--vm", $0]) })) {
                        Text("This Mac").tag("")
                        Text("Its own VM (\(Projects.folderName(project.name)))").tag(Projects.folderName(project.name))
                        ForEach(model.machines.filter { !$0.name.isEmpty && $0.name != Projects.folderName(project.name) }) { Text("Share the VM \($0.name)").tag($0.name) }
                        if let vm = project.vm, vm != Projects.folderName(project.name), !model.machines.contains(where: { $0.name == vm }) {
                            Text("The VM \(vm)").tag(vm)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(maxWidth: 280)
                }
                if let vm = project.vm {
                    let shared = model.projects.filter { $0.vm == vm && $0.id != project.id }.map(\.name)
                    if !shared.isEmpty {
                        LabeledField("") {
                            Text("Shared with \(shared.joined(separator: ", ")): one agent at a time works in it.")
                                .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text("Open starts \(AgentChoice.label(project.agent)) in this folder\(project.vm.map { ", working in the VM \($0)" } ?? ""). Projects on their own VMs work at the same time.")
                    .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.s2) {
                    IconButton("Notes for agents", "doc.text") { NSWorkspace.shared.open(project.folder.appendingPathComponent("AGENTS.md")) }
                    IconButton("Settings file", "slider.horizontal.3") { NSWorkspace.shared.open(Projects.settingsFile(project.folder)) }
                }
                .controlSize(.small)
            }
            Panel(title: "Pipelines", note: "\(pipelines.count)") {
                if pipelines.isEmpty {
                    Text("None yet. A pipeline is a list of prompts that run one after another.")
                        .font(Theme.caption).foregroundStyle(.secondary)
                }
                ForEach(pipelines) { p in
                    HStack(spacing: Theme.s2) {
                        IconRow(icon: "list.number", title: p.name, detail: "\(p.steps.count) step\(p.steps.count == 1 ? "" : "s")")
                        Spacer()
                        IconButton("Run", "play") { model.runPipeline(p) }.controlSize(.small)
                    }
                }
                IconButton("New pipeline", "plus") { model.editPipeline(Pipelines.Pipeline(name: "", agent: project.agent, project: project.folder)) }
                    .controlSize(.small)
            }
            Panel(title: "Save") {
                Text(remote.map { "Saved versions go to \($0)." } ?? "Save keeps a version of everything in the folder on this Mac. Save to GitHub also puts it in a private GitHub repository.")
                    .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.s2) {
                    IconButton("Save a version", "square.and.arrow.down") { save(push: false) }
                    IconButton("Save to GitHub", "icloud.and.arrow.up") { save(push: true) }
                }
                .controlSize(.small)
                if !output.isEmpty { Output(text: output) }
            }
            if !project.isGeneral { HStack {
                Spacer()
                Button("Remove from this list") {
                    model.runCLI(["project", "forget", project.folder.path]) { _, out in output = out; model.refresh() }
                }
                .controlSize(.small)
                .help("The folder stays where it is")
            } }
        }
        .onAppear {
            let folder = project.folder
            DispatchQueue.global(qos: .utility).async {
                let r = Projects.info(folder)?.remote
                DispatchQueue.main.async { remote = r }
            }
        }
    }

    /// Changes the project's agent or VM through `project set`, so the window and the CLI write the same file.
    private func change(_ args: [String]) {
        output = "…"
        model.runCLI(["project", "set", project.folder.path] + args) { code, out in
            output = (code == 0 ? "" : "exit \(code)\n") + out
            model.refresh()
        }
    }

    private func save(push: Bool) {
        output = "saving…"
        model.runCLI(["project", "save", project.folder.path] + (push ? ["--push"] : [])) { code, out in
            output = (code == 0 ? "" : "exit \(code)\n") + out
            remote = Projects.info(project.folder)?.remote
        }
    }
}

/// New project: a name, where it lives, what it starts from, which agent and where it runs.
struct NewProjectSheet: View {
    enum Start: Identifiable { case empty, github; var id: Int { self == .empty ? 0 : 1 } }

    @ObservedObject var model: AppModel
    let start: Start
    @State private var name = ""
    @State private var fromGitHub = false
    @State private var source = ""
    @State private var parent = (Projects.defaultRoot.path as NSString).abbreviatingWithTildeInPath
    @State private var agent = AgentCLIs.defaultID
    /// Where it runs: its own new VM (the default, so each project's accounts stay apart), this Mac, or a VM
    /// another project already uses.
    @State private var place = "+new"
    @State private var newVM = ""
    @State private var about = ""
    @State private var problem = ""
    @State private var working = false

    private var vm: String? {
        if place == "+new" { let n = newVM.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }; return n.isEmpty ? nil : n }
        return place.isEmpty ? nil : place
    }

    private var folder: String { (parent as NSString).appendingPathComponent(Projects.folderName(name)) }

    var body: some View {
        SheetFrame(title: fromGitHub ? "Open a project from GitHub" : "New project",
                   subtitle: "A folder for one piece of work. Agents opened in it read its notes and use its VM.", idealHeight: 640) {
            Panel(title: "Project") {
                LabeledField("Name") { TextField("Shop socials", text: $name) }
                LabeledField("Start from") {
                    Picker("", selection: $fromGitHub) {
                        Text("An empty folder").tag(false)
                        Text("A GitHub repository").tag(true)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 320)
                }
                if fromGitHub {
                    LabeledField("Repository") { TextField("https://github.com/you/shop-socials", text: $source).font(Theme.mono) }
                }
                LabeledField("Inside") { FolderField(path: $parent) }
                if !name.isEmpty {
                    LabeledField("") { Text(folder).font(Theme.monoSmall).foregroundStyle(.tertiary) }
                }
            }
            Panel(title: "How it runs") {
                LabeledField("Agent") {
                    Picker("", selection: $agent) {
                        ForEach(model.agentChoices(keeping: agent), id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .labelsHidden().pickerStyle(.segmented)
                }
                LabeledField("Runs on") {
                    Picker("", selection: $place) {
                        Text("Its own VM").tag("+new")
                        Text("This Mac").tag("")
                        let others = model.machines.filter { !$0.name.isEmpty }
                        if !others.isEmpty {
                            Divider()
                            ForEach(others) { Text("Share the VM \($0.name)").tag($0.name) }
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(maxWidth: 280)
                }
                if place == "+new" {
                    LabeledField("VM name") { TextField(Projects.folderName(name.isEmpty ? "shop" : name), text: $newVM) }
                    LabeledField("") {
                        Text("Its own Linux computer inside this Mac. Making it downloads under 1 GB and takes a few minutes; you can watch in the tab that opens.")
                            .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Panel(title: "What it is for", note: "agents read this") {
                TextField("For example: run the shop's Instagram and answer customers by email. Be brief.", text: $about, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(4...12)
                    .font(Theme.body)
            }
            if !problem.isEmpty { Text(problem).font(Theme.caption).foregroundStyle(Theme.danger).textSelection(.enabled) }
        } buttons: {
            if working { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancel") { model.newProject = nil }.keyboardShortcut(.cancelAction)
            Button(fromGitHub ? "Open" : "Create") { create() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty || (fromGitHub && source.isEmpty) || (place == "+new" && vm == nil))
        }
        .onAppear {
            fromGitHub = start == .github
            if place.isEmpty, newVM.isEmpty { newVM = "" }
        }
        .onChange(of: name) { _, value in if place == "+new", newVM.isEmpty { newVM = Projects.folderName(value) } }
        .onChange(of: place) { _, value in if value == "+new", newVM.isEmpty { newVM = Projects.folderName(name) } }
    }

    private func create() {
        problem = ""
        working = true
        let dir = (folder as NSString).expandingTildeInPath
        var argv = ["project", "new", name.trimmingCharacters(in: .whitespaces), "--dir", dir, "--agent", agent]
        if fromGitHub { argv += ["--from", source.trimmingCharacters(in: .whitespaces)] }
        if let vm { argv += ["--vm", vm] } else { argv.append("--no-vm") }
        if !about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { argv += ["--about", about] }
        let makeVM = place == "+new" ? vm : nil
        model.runCLI(argv) { code, out in
            working = false
            guard code == 0 else { problem = out; return }
            model.refresh()
            model.newProject = nil
            guard let project = Projects.info(URL(fileURLWithPath: dir)) else { return }
            model.openProject(project, setUpVM: makeVM)
        }
    }
}

// MARK: - Pipelines

struct PipelinesView: View {
    @ObservedObject var model: AppModel
    /// Only this project's pipelines; new ones are made in its folder.
    var project: Projects.Info? = nil

    private var pipelines: [Pipelines.Pipeline] { project.map { model.pipelinesIn($0) } ?? model.pipelines }

    private var blank: Pipelines.Pipeline {
        guard let project else { return Pipelines.Pipeline(name: "") }
        return Pipelines.Pipeline(name: "", agent: project.agent, project: project.folder)
    }

    /// The pipeline open in the editor, when it is one of this screen's (or a new one for this project).
    private var draft: Pipelines.Pipeline? {
        guard let d = model.pipelineDraft else { return nil }
        guard let project else { return d }
        if d.url == nil { return (d.project?.standardizedFileURL.path ?? (project.isGeneral ? project.id : nil)) == project.id ? d : nil }
        return pipelines.contains { $0.id == d.id } ? d : nil
    }

    var body: some View {
        SplitPane(id: "pipelines", help: .pipelines) {
            ListColumn(count: "\(pipelines.count) pipeline\(pipelines.count == 1 ? "" : "s")", newTitle: "New",
                       new: { model.editPipeline(blank) }) {
                if pipelines.isEmpty {
                    Text("No pipelines yet").font(Theme.caption).foregroundStyle(.secondary)
                        .padding(Theme.s4).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: Binding(get: { draft?.id }, set: { id in
                        if let p = pipelines.first(where: { $0.id == id }) { model.editPipeline(p) }
                    })) {
                        ForEach(pipelines) { p in
                            IconRow(icon: "list.number", title: p.name,
                                    detail: (project == nil ? "\(p.project.map { Projects.info($0)?.name ?? $0.lastPathComponent } ?? "no project") · " : "")
                                        + "\(p.steps.count) step\(p.steps.count == 1 ? "" : "s")")
                                .tag(p.id)
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            }
        } right: {
            Group {
                if let draft {
                    PipelineEditor(model: model, original: draft).id(draft.id + "\(model.pipelineEdits)")
                } else {
                    ScreenPage(title: Section.pipelines.label, subtitle: "") {
                        AnyView(IconButton("New pipeline", "plus", prominent: true) { model.editPipeline(blank) })
                    } content: {
                        Explainer.pipelines
                    }
                }
            }
        }
        .background(Theme.canvas)
    }
}

/// One pipeline: its name, where it runs, and its steps as cards you can add, move and remove.
struct PipelineEditor: View {
    @ObservedObject var model: AppModel
    let original: Pipelines.Pipeline

    struct EditStep: Identifiable { let id = UUID(); var title: String; var prompt: String }

    @State private var name = ""
    @State private var agent = AgentCLIs.defaultID
    @State private var project = ""
    @State private var vm = ""
    @State private var steps: [EditStep] = []
    @State private var problem = ""
    @State private var saved = ""
    @State private var scheduling = false

    private var isNew: Bool { original.url == nil }

    var body: some View {
        ScreenPage(title: isNew ? "New pipeline" : original.name, subtitle: original.url.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Prompts that run one after another") {
            AnyView(HStack(spacing: Theme.s2) {
                if !isNew {
                    IconButton("Schedule", "calendar.badge.plus") { if save() != nil { scheduling = true } }
                    IconButton("Run now", "play.fill") { if let p = save() { model.runPipeline(p) } }
                }
                IconButton("Save", "checkmark", prominent: true) { _ = save() }
                    .keyboardShortcut("s", modifiers: .command)
            })
        } content: {
            Panel(title: "Pipeline") {
                LabeledField("Name") { TextField("Morning round", text: $name) }
                if isNew {
                    LabeledField("Project") {
                        Picker("", selection: $project) {
                            Text("None").tag("")
                            ForEach(model.projects) { Text($0.name).tag($0.folder.path) }
                        }
                        .labelsHidden().pickerStyle(.menu).frame(maxWidth: 280)
                    }
                }
                LabeledField("Agent") {
                    Picker("", selection: $agent) {
                        ForEach(model.agentChoices(keeping: agent), id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .labelsHidden().pickerStyle(.segmented)
                }
                LabeledField("Runs on") {
                    Picker("", selection: $vm) {
                        Text(projectVM.map { "The project's VM (\($0))" } ?? "This Mac").tag("")
                        ForEach(model.machines.filter { !$0.name.isEmpty }) { Text("The VM \($0.name)").tag($0.name) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(maxWidth: 280)
                }
                if agent == "shell" {
                    LabeledField("") {
                        Text("With Shell, each step is a command, not a prompt.").font(Theme.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                stepCard(index, step)
            }
            HStack {
                IconButton("Add a step", "plus.circle") { steps.append(EditStep(title: "", prompt: "")) }
                Spacer()
                if !isNew {
                    Button("Move to Trash") {
                        model.runCLI(["pipeline", "rm", original.url?.path ?? original.ref]) { _, out in
                            model.output = out
                            model.pipelineDraft = nil
                            model.refresh()
                        }
                    }
                    .controlSize(.small)
                }
            }
            if !problem.isEmpty { Text(problem).font(Theme.caption).foregroundStyle(Theme.danger) }
            if !saved.isEmpty { Text(saved).font(Theme.monoSmall).foregroundStyle(.secondary) }
        }
        .onAppear(perform: load)
        .sheet(isPresented: $scheduling) {
            ScheduleEditor(model: model, existing: nil, presetKind: "pipeline", presetTarget: currentRef, presetName: name) { scheduling = false }
        }
    }

    private var projectVM: String? {
        let folder = isNew ? (project.isEmpty ? nil : URL(fileURLWithPath: project)) : original.project
        return folder.flatMap { Projects.info($0)?.vm }
    }

    private var currentRef: String {
        var p = original
        p.name = name
        return p.ref
    }

    private func stepCard(_ index: Int, _ step: EditStep) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(spacing: Theme.s2) {
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Theme.accent))
                TextField("What this step does, in a few words", text: binding(step.id, \.title))
                    .textFieldStyle(.plain)
                    .font(Theme.heading)
                Spacer()
                Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless).disabled(index == 0).help("Move up")
                Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(.borderless).disabled(index == steps.count - 1).help("Move down")
                Button { steps.removeAll { $0.id == step.id } } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Remove this step")
            }
            .foregroundStyle(Theme.accent)
            TextField(agent == "shell" ? "a command, e.g. ./export.sh" : "Tell the agent what to do, as you would in a chat.",
                      text: binding(step.id, \.prompt), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(4...14)
                .font(agent == "shell" ? Theme.mono : Theme.body)
        }
        .panel()
    }

    private func binding(_ id: UUID, _ key: WritableKeyPath<EditStep, String>) -> Binding<String> {
        Binding(get: { steps.first { $0.id == id }?[keyPath: key] ?? "" },
                set: { value in if let i = steps.firstIndex(where: { $0.id == id }) { steps[i][keyPath: key] = value } })
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard steps.indices.contains(target) else { return }
        steps.swapAt(index, target)
    }

    private func load() {
        name = original.name
        agent = original.agent
        project = original.project?.path ?? ""
        vm = original.vm ?? ""
        steps = original.steps.map { EditStep(title: $0.title, prompt: $0.prompt) }
        if steps.isEmpty { steps = [EditStep(title: "", prompt: "")] }
    }

    /// Writes the file; nil (and a line saying why) when something is missing.
    @discardableResult
    private func save() -> Pipelines.Pipeline? {
        problem = ""
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { problem = "Give it a name."; return nil }
        let kept = steps.filter { !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !kept.isEmpty else { problem = "Write at least one step."; return nil }
        var p = original
        p.name = trimmed
        p.agent = agent
        p.vm = vm.isEmpty ? nil : vm
        if isNew {
            p.project = project.isEmpty ? nil : URL(fileURLWithPath: project)
            let url = (p.project.map { $0.appendingPathComponent("pipelines") } ?? Pipelines.homeDir).appendingPathComponent(Pipelines.slug(trimmed) + ".md")
            guard !FileManager.default.fileExists(atPath: url.path) else { problem = "There is already a pipeline called \(trimmed) there."; return nil }
            p.url = url
        }
        p.steps = kept.enumerated().map { i, s in
            Pipelines.Step(title: s.title.trimmingCharacters(in: .whitespaces).isEmpty ? "Step \(i + 1)" : s.title, prompt: s.prompt)
        }
        do {
            _ = try Pipelines.write(p)
            saved = "saved \(Date().formatted(date: .omitted, time: .shortened))"
            model.refresh()
            // The page's title and the list follow a rename; an existing pipeline keeps its editor (same id).
            model.pipelineDraft = p
            return p
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }
}

// MARK: - VMs

/// Settings ▸ VMs: every VM on this Mac and the projects that work in it. A VM no project uses can become a
/// project in one click; each project's own VM is started, stopped and watched on the project's screen.
struct VMsPanel: View {
    @ObservedObject var model: AppModel
    @State private var output = ""

    var body: some View {
        Panel(title: "VMs", note: "\(model.machines.count)") {
            Text("Each project works in its own VM, a Linux computer inside this Mac, and starts and stops it from its own screen. Projects on their own VMs work at the same time.")
                .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(model.machines) { m in
                let users = model.projects.filter { $0.vm == m.name }
                HStack(spacing: Theme.s2) {
                    IconRow(icon: m.host == nil ? "server.rack" : "network", title: m.label,
                            detail: (m.host ?? m.state) + " · " + (users.isEmpty ? (m.name.isEmpty ? "websites outside a project" : "not in a project") : users.map(\.name).joined(separator: ", ")))
                    Spacer()
                    if let p = users.first {
                        IconButton("Show", "arrow.right.circle") { model.show(project: p, tab: .work) }.controlSize(.small)
                    } else if !m.name.isEmpty {
                        IconButton("Make a project for it", "folder.badge.plus") { adopt(m.name) }.controlSize(.small)
                    }
                }
            }
            Divider()
            Text("When an agent opens a website outside a project's VM, it uses the default VM if this is on, else this Mac.")
                .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.s2) {
                IconButton("Use the default VM", "server.rack") { vm(["vm", "on"]) }
                IconButton("Use this Mac", "laptopcomputer") { vm(["vm", "off"]) }
            }
            .controlSize(.small)
            if !output.isEmpty { Output(text: output) }
        }
        .onAppear { model.refreshMachines() }
    }

    /// A project named after the VM, working in it.
    private func adopt(_ name: String) {
        output = "…"
        model.runCLI(["project", "new", name, "--vm", name]) { code, out in
            output = code == 0 ? "" : "exit \(code)\n\(out)"
            model.refresh()
            if code == 0, let p = model.projects.first(where: { $0.vm == name }) { model.show(project: p, tab: .work) }
        }
    }

    private func vm(_ args: [String]) {
        output = "…"
        model.runCLI(args) { code, out in
            output = (code == 0 ? "" : "exit \(code)\n") + out
            model.refreshMachines()
        }
    }
}
