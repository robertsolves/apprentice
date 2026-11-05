import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

// MARK: - Projects

/// A project's Settings tab: how it runs, its notes for agents, and saving it.
/// A project's install.sh and uninstall.sh: what they say is shown before either runs, and they run in a tab, so the
/// user watches it happen and can answer anything they ask.
struct InstallButtons: View {
    @ObservedObject var model: AppModel
    let project: Projects.Info
    @State private var revision = 0

    var body: some View {
        Panel(title: "Install and uninstall") {
            Text("What this project needs on a Mac is written in these two files. They run only when you press the button.")
                .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Projects.scriptKinds, id: \.self) { kind in
                HStack(spacing: Theme.s2) {
                    Text("\(kind).sh").font(Theme.mono).frame(width: 110, alignment: .leading)
                    if FileManager.default.fileExists(atPath: Projects.scriptFile(project.folder, kind).path) {
                        Button(kind == "install" ? "Install" : "Uninstall") { Self.run(model, project, kind) }.controlSize(.small)
                        Button("Open") { NSWorkspace.shared.open(Projects.scriptFile(project.folder, kind)) }.controlSize(.small)
                        if Projects.writtenScript(project.folder, kind) == nil { Text("nothing in it yet").font(Theme.caption).foregroundStyle(.tertiary) }
                    } else {
                        Button("Add it") { Projects.writeScripts(project.folder, only: kind); revision += 1 }.controlSize(.small)
                    }
                }
            }
            .id(revision)
        }
    }

    /// Asks, showing the start of what would run, then types it into a new tab.
    static func run(_ model: AppModel, _ project: Projects.Info, _ kind: String) {
        let file = Projects.scriptFile(project.folder, kind)
        let text = Projects.writtenScript(project.folder, kind)
        let lines = (text ?? "").split(separator: "\n", omittingEmptySubsequences: false).prefix(25).joined(separator: "\n")
        let more = (text ?? "").split(separator: "\n").count > 25 ? "\n… (Open shows the rest)" : ""
        let shown = text == nil ? "It has nothing in it yet." : "It runs on this Mac, with your access to it. Run it only if you trust where this project came from.\n\n\(lines)\(more)"
        guard AppModel.confirm("Run \(kind).sh?", shown, kind == "install" ? "Install" : "Uninstall") else { return }
        model.newTab(title: kind.capitalized, command: "sh \(VM.shellQuoted(file.path)); echo; exec \"$SHELL\" -l", dir: project.folder, vm: project.vm, project: project)
    }

    /// Right after an import, when it came with an install.sh of its own.
    static func offer(_ model: AppModel, _ project: Projects.Info) {
        if Projects.writtenScript(project.folder, "install") != nil { run(model, project, "install") }
    }
}

struct ProjectDetail: View {
    @ObservedObject var model: AppModel
    let project: Projects.Info
    @State private var output = ""
    @State private var remote: String?

    var body: some View {
        ScreenPage(title: "Settings", subtitle: (project.folder.path as NSString).abbreviatingWithTildeInPath) {
            AnyView(EmptyView())
        } content: {
            InstallButtons(model: model, project: project)
            Panel(title: "How it runs") {
                LabeledField("Runs on") {
                    Picker("", selection: Binding(get: { project.vm ?? "" }, set: { change($0.isEmpty ? ["--no-vm"] : ["--vm", $0]) })) {
                        Text("This Mac").tag("")
                        // The same name `project new` gives it, so the picker shows it chosen for a new project.
                        let own = Projects.ownVM(project.name) ?? "vm"
                        Text("Its own VM (\(own))").tag(own)
                        ForEach(model.machines.filter { !$0.name.isEmpty && $0.name != own }) { Text("Share the VM \($0.name)").tag($0.name) }
                        if let vm = project.vm, vm != own, !model.machines.contains(where: { $0.name == vm }) {
                            Text("The VM \(vm)").tag(vm)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(maxWidth: 280, alignment: .leading)
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
                Text("Any agent opened in this folder\(project.vm.map { " works in the VM \($0)" } ?? " works on this Mac"). Projects on their own VMs work at the same time.")
                    .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.s2) {
                    IconButton("Notes for agents", "doc.text") { NSWorkspace.shared.open(project.folder.appendingPathComponent("AGENTS.md")) }
                    IconButton("Settings file", "slider.horizontal.3") { NSWorkspace.shared.open(Projects.settingsFile(project.folder)) }
                }
                .controlSize(.small)
            }
            AgentsPanel(model: model, project: project)
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
            HStack {
                Spacer()
                Button("Remove from this list") {
                    model.runCLI(["project", "forget", project.folder.path]) { _, out in output = out; model.refresh() }
                }
                .controlSize(.small)
                .help("The folder stays where it is")
            }
        }
        .onAppear {
            let folder = project.folder
            DispatchQueue.global(qos: .utility).async {
                let r = Projects.info(folder)?.remote
                DispatchQueue.main.async { remote = r }
            }
        }
    }

    /// Changes the project's VM through `project set`, so the window and the CLI write the same file.
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

/// New project: a name, where it lives, what it starts from and where it runs.
struct NewProjectSheet: View {
    enum Start: Identifiable { case empty, github; var id: Int { self == .empty ? 0 : 1 } }
    /// Where a project's files come from.
    enum From: Hashable { case empty, github, folder, zip }

    @ObservedObject var model: AppModel
    let start: Start
    @State private var name = ""
    @State private var from = From.empty
    @State private var source = ""
    @State private var parent = (Projects.defaultRoot.path as NSString).abbreviatingWithTildeInPath
    /// Where it runs: its own new VM (the default, so each project's accounts stay apart), this Mac, or a VM
    /// another project already uses.
    @State private var place = "+new"
    @State private var newVM = ""
    @State private var problem = ""
    @State private var working = false

    private var vm: String? {
        // The name `project new` will store, so the VM made in the first tab is the one the project uses.
        if place == "+new" { return Projects.vmFor(typed: newVM, project: name) }
        return place.isEmpty ? nil : place
    }

    /// A folder stays where it is; everything else goes inside `parent`.
    private var folder: String { from == .folder ? source : (parent as NSString).appendingPathComponent(Projects.folderName(name)) }

    /// The name it would get anyway, offered once the user has said where it comes from.
    private func suggestName() {
        guard name.isEmpty, let found = try? Projects.importSource(source) else { return }
        name = Projects.importName(found)
    }

    var body: some View {
        SheetFrame(title: from == .empty ? "New project" : "Import a project",
                   subtitle: "A folder for one piece of work. Agents opened in it read its notes and use its VM.", idealHeight: 640) {
            Panel(title: "Project") {
                LabeledField("Start from") {
                    Picker("", selection: $from) {
                        Text("Empty").tag(From.empty)
                        Text("GitHub").tag(From.github)
                        Text("A folder").tag(From.folder)
                        Text("A zip file").tag(From.zip)
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                    .onChange(of: from) { _, _ in source = "" }
                }
                switch from {
                case .empty: EmptyView()
                case .github:
                    LabeledField("Repository") { TextField("https://github.com/you/shop-socials", text: $source).font(Theme.mono).onSubmit(suggestName) }
                case .folder:
                    LabeledField("Folder") { FolderField(path: $source) }
                    LabeledField("") {
                        Text("It stays where it is. Apprentice adds its own files to it.").font(Theme.caption).foregroundStyle(.secondary)
                    }
                case .zip:
                    LabeledField("Zip file") {
                        HStack(spacing: Theme.s2) {
                            Text(source.isEmpty ? "None chosen" : (source as NSString).lastPathComponent).font(Theme.mono).lineLimit(1)
                            Button("Choose…") { chooseZip() }.controlSize(.small)
                        }
                    }
                }
                LabeledField("Name") { TextField("Shop socials", text: $name) }
                if from != .folder { LabeledField("Inside") { FolderField(path: $parent) } }
                if !name.isEmpty {
                    LabeledField("") { Text(folder).font(Theme.monoSmall).foregroundStyle(.tertiary) }
                }
                if from != .empty {
                    LabeledField("") {
                        Text("Nothing from it runs when you import it. If it has an install.sh, you are shown it first.")
                            .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Panel(title: "How it runs") {
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
                    .labelsHidden().pickerStyle(.menu).frame(maxWidth: 280, alignment: .leading)
                }
                if place == "+new" {
                    LabeledField("VM name") { TextField(name.isEmpty ? "shop" : Projects.ownVM(name) ?? "shop", text: $newVM) }
                    LabeledField("") {
                        Text("Its own Linux computer inside this Mac. Making it downloads under 1 GB and takes a few minutes; you can watch in the tab that opens.")
                            .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !problem.isEmpty { Text(problem).font(Theme.caption).foregroundStyle(Theme.danger).textSelection(.enabled) }
        } buttons: {
            if working { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancel") { model.newProject = nil }.keyboardShortcut(.cancelAction)
            Button(from == .empty ? "Create" : "Import") { create() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty || (from != .empty && source.isEmpty) || (place == "+new" && vm == nil))
        }
        .onAppear {
            from = start == .github ? .github : .empty
        }
        .onChange(of: source) { _, _ in if from != .github { suggestName() } }
    }

    private func chooseZip() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.zip]
        if panel.runModal() == .OK, let url = panel.url { source = url.path }
    }

    private func create() {
        problem = ""
        working = true
        let dir = (folder as NSString).expandingTildeInPath
        var argv = from == .empty ? ["project", "new", name.trimmingCharacters(in: .whitespaces), "--dir", dir]
            : ["project", "import", source.trimmingCharacters(in: .whitespaces), "--name", name.trimmingCharacters(in: .whitespaces), "--dir", dir]
        if let vm { argv += ["--vm", vm] } else { argv.append("--no-vm") }
        let makeVM = place == "+new" ? vm : nil
        model.runCLI(argv) { code, out in
            working = false
            guard code == 0 else { problem = out; return }
            model.refresh()
            model.newProject = nil
            guard let project = Projects.info(URL(fileURLWithPath: dir)) else { return }
            model.openProject(project, setUpVM: makeVM)
            if from != .empty { InstallButtons.offer(model, project) }
        }
    }
}

// MARK: - Pipelines

struct PipelinesView: View {
    @ObservedObject var model: AppModel
    /// Only this project's pipelines; new ones are made in its folder.
    let project: Projects.Info

    private var pipelines: [Pipelines.Pipeline] { model.pipelinesIn(project) }

    private var blank: Pipelines.Pipeline { Pipelines.Pipeline(name: "", project: project.folder) }

    /// The pipeline open in the editor, when it is one of this screen's (or a new one for this project).
    private var draft: Pipelines.Pipeline? {
        guard let d = model.pipelineDraft else { return nil }
        if d.url == nil { return d.project?.standardizedFileURL.path == project.id ? d : nil }
        return pipelines.contains { $0.id == d.id } ? d : nil
    }

    var body: some View {
        SplitPane(id: "pipelines", help: .pipelines) {
            ListColumn(count: "\(pipelines.count) pipeline\(pipelines.count == 1 ? "" : "s")", newTitle: "New",
                       new: { model.editPipeline(blank) }) {
                if pipelines.isEmpty {
                    Text("No pipelines yet").font(Theme.caption).foregroundStyle(.secondary)
                        .padding(Theme.s4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    List(selection: Binding(get: { draft?.id }, set: { id in
                        if let p = pipelines.first(where: { $0.id == id }) { model.editPipeline(p) }
                    })) {
                        ForEach(pipelines) { p in
                            IconRow(icon: "list.number", title: p.name, detail: "\(p.steps.count) step\(p.steps.count == 1 ? "" : "s")")
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

    struct EditStep: Identifiable {
        let id = UUID()
        var title: String
        var prompt: String
        var use = ""
        var next = ""
        var when = ""
        var needs = ""
        var ui = false
    }

    @State private var name = ""
    @State private var agent = AgentCLIs.defaultID
    @State private var vm = ""
    @State private var steps: [EditStep] = []
    @State private var problem = ""
    @State private var saved = ""
    @State private var scheduling = false
    @State private var goal = ""
    @State private var interpreter = ""
    @State private var scribe = ""
    @State private var carry = false
    @State private var check = PipelineGraph.Report()

    /// The steps as they stand, for the check and the UI tick.
    private var draftPipeline: Pipelines.Pipeline {
        var p = original
        p.steps = steps.map { s in
            var step = Pipelines.Step(title: s.title, prompt: s.prompt.isEmpty ? "x" : s.prompt)
            step.use = s.use.isEmpty ? nil : s.use
            step.next = s.next.isEmpty ? nil : s.next
            step.when = s.when.isEmpty ? nil : s.when
            step.needs = s.needs.isEmpty ? nil : s.needs
            step.ui = s.ui
            return step
        }
        p.goal = goal.isEmpty ? nil : goal
        p.interpreter = interpreter.isEmpty ? nil : interpreter
        p.scribes = scribe.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        p.carry = carry
        return p
    }

    private var agentNames: [String] { NamedAgents.all(project: original.project).map(\.name) }

    private var isNew: Bool { original.url == nil }

    var body: some View {
        ScreenPage(title: isNew ? "New pipeline" : original.name, subtitle: original.url.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Prompts that run one after another") {
            AnyView(HStack(spacing: Theme.s2) {
                if !isNew {
                    IconButton("Audit", "checklist") { if let p = save() { model.auditPipeline(p) } }
                        .help("Writes a brief for reviewing this pipeline, which spends nothing, and opens a shell to tweak it with any agent")
                    IconButton("Schedule", "calendar.badge.plus") { if save() != nil { scheduling = true } }
                    if carry {
                        IconButton("Run fresh", "arrow.clockwise") { if let p = save() { model.runPipeline(p, fresh: true) } }
                            .help("Runs it without the summary carried from earlier runs")
                    }
                    IconButton("Run now", "play.fill") { if let p = save() { model.runPipeline(p) } }
                }
                IconButton("Save", "checkmark", prominent: true) { _ = save() }
                    .keyboardShortcut("s", modifiers: .command)
            })
        } content: {
            Panel(title: "Pipeline") {
                LabeledField("Name") { TextField("Morning round", text: $name) }
                LabeledField("Goal") { TextField("What the whole thing is for; every step is told", text: $goal) }
                LabeledField("Runs on") {
                    Picker("", selection: $vm) {
                        Text(projectVM.map { "The project's VM (\($0))" } ?? "This Mac").tag("")
                        ForEach(model.machines.filter { !$0.name.isEmpty }) { Text("The VM \($0.name)").tag($0.name) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(maxWidth: 280, alignment: .leading)
                }
                if agent == "shell" {
                    LabeledField("") {
                        Text("With Shell, each step is a command, not a prompt.").font(Theme.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledField("Chooses branches") { agentPicker($interpreter, blank: "The usual one") }
                LabeledField("Writes summaries") { agentPicker($scribe, blank: "The usual one") }
                LabeledField("") {
                    Toggle("Carry a short summary from run to run", isOn: $carry).toggleStyle(.checkbox).font(Theme.caption)
                }
            }
            if !check.errors.isEmpty || !check.warnings.isEmpty {
                Panel(title: check.errors.isEmpty ? "Worth a look" : "It will not start until these are fixed") {
                    ForEach(check.errors, id: \.self) { Text($0).font(Theme.caption).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
                    ForEach(check.warnings, id: \.self) { Text($0).font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
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
            if !isNew { PipelineRunsPanel(model: model, pipeline: original) }
        }
        .onAppear(perform: load)
        .sheet(isPresented: $scheduling) {
            ScheduleEditor(model: model, existing: nil, presetKind: "pipeline", presetTarget: currentRef, presetName: name) { scheduling = false }
        }
    }

    private var projectVM: String? { original.project.flatMap { Projects.info($0)?.vm } }

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
            stepSettings(index, step)
        }
        .panel()
    }

    /// What runs a step, what follows it, and the UI tick, which one step of a parallel group can have.
    @ViewBuilder private func stepSettings(_ index: Int, _ step: EditStep) -> some View {
        let graph = PipelineGraph(draftPipeline)
        let id = graph.ids.indices.contains(index) ? graph.ids[index] : ""
        let holder = graph.uiHolder(blocking: id)
        let others = graph.ids.filter { $0 != id }
        let parts = PipelineGraph.split(step.next)
        let chosenBy = step.next.contains("&") ? "all" : step.next.contains("|") ? "one" : step.next.isEmpty ? "next" : step.next.lowercased() == "end" ? "end" : "go"
        HStack(spacing: Theme.s3) {
            HStack(spacing: Theme.s1) {
                Text("Agent").font(Theme.caption).foregroundStyle(.secondary)
                agentPicker(binding(step.id, \.use), blank: "First on the list").frame(maxWidth: 170)
            }
            HStack(spacing: Theme.s1) {
                Text("Needs").font(Theme.caption).foregroundStyle(.secondary)
                Picker("", selection: binding(step.id, \.needs)) {
                    Text("Anything").tag("")
                    ForEach(NamedAgents.levels, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            Toggle("Uses the screen", isOn: Binding(get: { step.ui }, set: { v in setUI(step.id, v) }))
                .toggleStyle(.checkbox).font(Theme.caption)
                .disabled(holder != nil && !step.ui)
                .help(holder.map { "\($0) is using the screen: one step of a parallel group at a time" } ?? "Only a step with this on may use the screen")
            if let holder, !step.ui { Text("\(holder) is using the screen").font(Theme.caption).foregroundStyle(.tertiary).lineLimit(1) }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
            Text("After it").font(Theme.caption).foregroundStyle(.secondary)
            Picker("", selection: Binding(get: { chosenBy }, set: { mode in setMode(step.id, mode, names: parts.names) })) {
                Text("The next step").tag("next")
                Text("One step").tag("go")
                Text("One of these, chosen for it").tag("one")
                Text("All of these at once").tag("all")
                Text("The end").tag("end")
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            if ["go", "one", "all"].contains(chosenBy) {
                ForEach(others, id: \.self) { name in
                    Toggle(name, isOn: Binding(get: { parts.names.map(Pipelines.slug).contains(name) }, set: { on in
                        toggleTarget(step.id, name, on: on, mode: chosenBy, names: parts.names)
                    }))
                    .toggleStyle(.checkbox).font(Theme.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        if chosenByParent(id) {
            HStack(spacing: Theme.s2) {
                Text("Choose it when").font(Theme.caption).foregroundStyle(.secondary)
                TextField("one line the agent choosing reads", text: binding(step.id, \.when)).textFieldStyle(.roundedBorder).controlSize(.small)
            }
        }
    }

    private func chosenByParent(_ id: String) -> Bool {
        let g = PipelineGraph(draftPipeline)
        return g.ids.contains { if case .choice(let a) = g.next($0) { return a.contains(id) } else { return false } }
    }

    private func agentPicker(_ value: Binding<String>, blank: String) -> some View {
        Picker("", selection: value) {
            Text(blank).tag("")
            ForEach(agentNames, id: \.self) { Text($0).tag($0) }
            if !value.wrappedValue.isEmpty, !agentNames.contains(value.wrappedValue) { Text(value.wrappedValue).tag(value.wrappedValue) }
        }
        .labelsHidden().pickerStyle(.menu)
    }

    private func setUI(_ id: UUID, _ on: Bool) {
        if let i = steps.firstIndex(where: { $0.id == id }) { steps[i].ui = on }
        recheck()
    }

    private func setMode(_ id: UUID, _ mode: String, names: [String]) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        switch mode {
        case "next": steps[i].next = ""
        case "end": steps[i].next = "end"
        case "one": steps[i].next = names.joined(separator: " | ") + (names.count == 1 ? " |" : "")
        case "all": steps[i].next = names.joined(separator: " & ") + (names.count == 1 ? " &" : "")
        default: steps[i].next = names.first ?? " "
        }
        recheck()
    }

    private func toggleTarget(_ id: UUID, _ name: String, on: Bool, mode: String, names: [String]) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        var list = names.filter { Pipelines.slug($0) != name }
        if on { list = mode == "go" ? [name] : list + [name] }
        switch mode {
        case "one": steps[i].next = list.joined(separator: " | ") + (list.count == 1 ? " |" : "")
        case "all": steps[i].next = list.joined(separator: " & ") + (list.count == 1 ? " &" : "")
        default: steps[i].next = list.first ?? " "
        }
        recheck()
    }

    private func recheck() { check = PipelineGraph(draftPipeline).check() }

    private func binding(_ id: UUID, _ key: WritableKeyPath<EditStep, String>) -> Binding<String> {
        Binding(get: { steps.first { $0.id == id }?[keyPath: key] ?? "" },
                set: { value in
                    if let i = steps.firstIndex(where: { $0.id == id }) { steps[i][keyPath: key] = value }
                    recheck()
                })
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard steps.indices.contains(target) else { return }
        steps.swapAt(index, target)
    }

    private func load() {
        name = original.name
        agent = original.agent
        vm = original.vm ?? ""
        steps = original.steps.map { EditStep(title: $0.title, prompt: $0.prompt, use: $0.use ?? "", next: $0.next ?? "", when: $0.when ?? "", needs: $0.needs ?? "", ui: $0.ui) }
        if steps.isEmpty { steps = [EditStep(title: "", prompt: "")] }
        goal = original.goal ?? ""
        interpreter = original.interpreter ?? ""
        scribe = original.scribes.joined(separator: ", ")
        carry = original.carry
        recheck()
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
            guard let folder = p.project else { problem = "A pipeline belongs to a project."; return nil }
            let url = folder.appendingPathComponent("pipelines").appendingPathComponent(Pipelines.slug(trimmed) + ".md")
            guard !FileManager.default.fileExists(atPath: url.path) else { problem = "There is already a pipeline called \(trimmed) there."; return nil }
            p.url = url
        }
        p.steps = kept.enumerated().map { i, s in
            var step = Pipelines.Step(title: s.title.trimmingCharacters(in: .whitespaces).isEmpty ? "Step \(i + 1)" : s.title, prompt: s.prompt)
            func clean(_ v: String) -> String? {
                let t = v.trimmingCharacters(in: CharacterSet(charactersIn: " |&"))
                return t.isEmpty ? nil : v.trimmingCharacters(in: .whitespaces)
            }
            step.use = clean(s.use)
            step.next = clean(s.next)
            step.when = clean(s.when)
            step.needs = clean(s.needs)
            step.ui = s.ui
            return step
        }
        p.goal = goal.isEmpty ? nil : goal
        p.interpreter = interpreter.isEmpty ? nil : interpreter
        p.scribes = scribe.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        p.carry = carry
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

// MARK: - Outside a project

/// Settings: schedules and pipelines that no listed project owns (its folder moved or was forgotten, or an older
/// version made them), so nothing keeps running where the person cannot see it. Shown only when there are any.
struct OutsideProjectsPanel: View {
    @ObservedObject var model: AppModel

    private var schedules: [Schedules.Schedule] { model.schedules.filter { model.owner(of: $0) == nil } }
    private var pipelines: [Pipelines.Pipeline] { model.pipelines.filter { $0.project == nil } }

    var body: some View {
        if !schedules.isEmpty || !pipelines.isEmpty {
            Panel(title: "Not in a project", note: "\(schedules.count + pipelines.count)") {
                Text("These belong to no project on this list. Schedules here still run until you remove them.")
                    .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(schedules) { s in
                    HStack(spacing: Theme.s2) {
                        IconRow(icon: Section.schedules.icon, title: s.name, detail: s.when_ + (s.enabled ? "" : " · paused"))
                        Spacer()
                        Button("Remove") {
                            if AppModel.confirm("Remove \(s.name)?", "It will not run again. Its past logs stay.", "Remove") {
                                model.act("schedule", ["rm", s.id])
                            }
                        }
                        .controlSize(.small)
                    }
                }
                ForEach(pipelines) { p in
                    HStack(spacing: Theme.s2) {
                        IconRow(icon: Section.pipelines.icon, title: p.name, detail: "\(p.steps.count) step\(p.steps.count == 1 ? "" : "s")")
                        Spacer()
                        if let url = p.url {
                            IconButton("Show in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                .controlSize(.small)
                        }
                    }
                }
            }
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
                    } else {
                        if m.state == "running" || m.host != nil {
                            IconButton("Watch", "eye") { model.selectedVM = m.name }.controlSize(.small)
                        }
                        if m.state == "running", m.host == nil {
                            IconButton("Click in it", "cursorarrow.click") { vm((m.name.isEmpty ? [] : ["--vm", m.name]) + ["vm", "look"]) }.controlSize(.small)
                        }
                        if !m.name.isEmpty {
                            IconButton("Make a project for it", "folder.badge.plus") { adopt(m.name) }.controlSize(.small)
                        }
                    }
                }
            }
            // A VM no project uses (the default VM for websites outside a project, an older one) is watched here:
            // the overlay's Watch button and `vm watch` bring the window to it.
            if let chosen = model.selectedVM, !model.projects.contains(where: { $0.vm == chosen }),
               let m = model.machines.first(where: { $0.name == chosen }), m.state == "running" || m.host != nil {
                VMScreen(name: m.name)
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
