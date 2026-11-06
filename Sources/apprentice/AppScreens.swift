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
            Text("What this project needs is written in these two files. They run \(project.vm.map { "in its VM, \($0)," } ?? "on this Mac") only when you press the button.")
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
        let shown = text == nil ? "It has nothing in it yet." : (project.vm.map { "It runs in the VM \($0), from a copy of this project's folder." } ?? "It runs on this Mac, with your access to it.") + " Run it only if you trust where this project came from.\n\n\(lines)\(more)"
        guard AppModel.confirm("Run \(kind).sh?", shown, kind == "install" ? "Install" : "Uninstall") else { return }
        let line = project.vm == nil ? "sh \(VM.shellQuoted(file.path))" : "apprentice project \(kind) \(VM.shellQuoted(project.folder.path))"
        model.newTab(title: kind.capitalized, command: "\(line); echo; exec \"$SHELL\" -l", dir: project.folder, vm: project.vm, project: project)
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

    @State private var tasks: [Pipelines.Pipeline] = []

    private var pipelines: [Pipelines.Pipeline] { model.pipelinesIn(project) }

    private var blank: Pipelines.Pipeline { Pipelines.Pipeline(name: "", project: project.folder) }

    /// The pipeline open in the editor, when it is one of this screen's (or a new one for this project).
    private var draft: Pipelines.Pipeline? {
        guard let d = model.pipelineDraft else { return nil }
        if d.url == nil { return d.project?.standardizedFileURL.path == project.id ? d : nil }
        return (pipelines + tasks).contains { $0.id == d.id } ? d : nil
    }

    private func row(_ p: Pipelines.Pipeline, icon: String) -> some View {
        IconRow(icon: icon, title: p.name, detail: "\(p.steps.count) step\(p.steps.count == 1 ? "" : "s")")
            .tag(p.id)
            .contextMenu { Button("Move to Trash") { model.trashPipeline(p) } }
    }

    /// The list, or an open pipeline with the whole of the room: it is a diagram, and needs it.
    @ViewBuilder private var page: some View {
        if let draft {
            PipelineEditor(model: model, original: draft).id(draft.id + "\(model.pipelineEdits)")
        } else {
            SplitPane(id: "pipelines", help: .pipelines) {
                ListColumn(count: "\(pipelines.count) pipeline\(pipelines.count == 1 ? "" : "s")", newTitle: "New",
                           new: { model.editPipeline(blank) }) {
                    if pipelines.isEmpty && tasks.isEmpty {
                        Text("No pipelines yet").font(Theme.caption).foregroundStyle(.secondary)
                            .padding(Theme.s4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        List(selection: Binding(get: { draft?.id }, set: { id in
                            if let p = (pipelines + tasks).first(where: { $0.id == id }) { model.editPipeline(p) }
                        })) {
                            ForEach(pipelines) { row($0, icon: "list.number") }
                            if !tasks.isEmpty {
                                SwiftUI.Section("Just once") {
                                    ForEach(tasks.prefix(15)) { row($0, icon: "text.bubble") }
                                }
                            }
                        }
                        .listStyle(.sidebar)
                        .scrollContentBackground(.hidden)
                    }
                }
            } right: {
                ScreenPage(title: Section.pipelines.label, subtitle: "") {
                    AnyView(IconButton("New pipeline", "plus", prominent: true) { model.editPipeline(blank) })
                } content: {
                    Explainer.pipelines
                }
            }
        }
    }

    var body: some View {
        page
        .background(Theme.canvas)
        .onAppear { tasks = Pipelines.tasks(project.folder) }
        .onChange(of: model.revision) { _, _ in
            let now = Pipelines.tasks(project.folder)
            if now.map(\.id) != tasks.map(\.id) { tasks = now }
        }
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
        /// On a step with an OR after it: what decides which branch runs.
        var choose = ""
        var needs = ""
        var ui = false
        /// The name the wires to it use: it follows the title, but not through a moment the title is blank or taken.
        var wireId = ""
        /// Named by the app so far, so its words name it as they are written.
        var autoNamed = false
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
    /// The step chosen on the canvas, whose words and settings show under it.
    @State private var selected: String?
    /// Where each card sits, by step name.
    @State private var positions: [String: CGPoint] = [:]
    /// The OR or AND node chosen, by the step it follows.
    @State private var selectedGate: String?
    @State private var tab = Tab.thisRun
    @AppStorage("pipeline.panel") private var panelOpen = true

    private enum Tab: String, CaseIterable, Identifiable {
        case chosen = "Selected", thisRun = "This run", settings = "Settings", runs = "Runs"
        var id: String { rawValue }
    }

    /// The file as this page last read or wrote it, and the page's own contents at that moment.
    @State private var onDisk: String?
    @State private var baseline = ""
    /// The file changed while this page had changes of its own: the person says which to keep.
    @State private var changedOutside = false

    private var pageText: String {
        var p = draftPipeline
        p.name = name
        p.agent = agent
        p.vm = vm.isEmpty ? nil : vm
        return Pipelines.render(p)
    }
    private var unsaved: Bool { pageText != baseline }
    private var diskText: String? { original.url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } }

    /// The page starts again from the file. Its pipeline, for a caller that was about to use it.
    @discardableResult
    private func followFile() -> Pipelines.Pipeline? {
        guard let url = original.url, let text = diskText else { return nil }
        let p = Pipelines.parse(text, url: url, project: original.project)
        changedOutside = false
        problem = ""
        model.pipelineDraft = p
        model.pipelineEdits += 1
        return p
    }

    /// An agent, a text editor or a sync can change the file while the page is open. Nothing unsaved here: follow it.
    private func noticeFile() {
        guard let now = diskText, let seen = onDisk, now != seen, !changedOutside else { return }
        if unsaved { changedOutside = true } else { followFile() }
    }

    /// The steps as they stand, for the check and the UI tick.
    private var draftPipeline: Pipelines.Pipeline {
        var p = original
        p.steps = steps.map { s in
            var step = Pipelines.Step(title: s.title, prompt: s.prompt.isEmpty ? "x" : s.prompt)
            step.use = s.use.isEmpty ? nil : s.use
            step.next = s.next.isEmpty ? nil : s.next
            step.when = s.when.isEmpty ? nil : s.when
            step.choose = s.choose.isEmpty ? nil : s.choose
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

    /// The CLIs on this Mac, looked up once: it asks the login shell, so not on the main thread.
    @State private var installed: Set<String> = []

    private var agentChoices: [(id: String, label: String)] { NamedAgents.choices(project: original.project, installed: installed) }

    private var isNew: Bool { original.url == nil }

    /// A run of this pipeline is waiting for the user, so its page opens on the question and not below the steps.
    private var waiting: Bool { model.waitingRuns.contains { $0.file == original.url?.path } }

    /// A one-off task from the Work tab, not yet one of the project's pipelines.
    private var isTask: Bool { original.url?.path.contains("/.apprentice/cache/tasks/") == true }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.6)
            ForEach(check.errors, id: \.self) { line in
                Text(line).font(Theme.caption).foregroundStyle(Theme.danger).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.s3).padding(.vertical, 2)
            }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    tools
                    Divider().opacity(0.6)
                    PipelineCanvas(cards: cards, graph: PipelineGraph(draftPipeline), positions: $positions, selected: $selected, selectedGate: $selectedGate,
                                   firstThisRun: runDraft.wrappedValue.first, lastThisRun: runDraft.wrappedValue.last, openThisRun: { panelOpen = true; tab = .thisRun },
                                   wire: { wire($0, to: $1) }, unwire: { unwire($0, from: $1) }, rewire: { rewire($0, from: $1, to: $2) },
                                   moved: { Pipelines.saveLayout(positions, of: original.url) })
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if panelOpen {
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                    panel.frame(width: 380)
                }
            }
        }
        .background(Theme.canvas)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                noticeFile()
            }
        }
        .onAppear {
            load()
            if waiting || model.pipelineOpensRuns { tab = .runs }
            model.pipelineOpensRuns = false
            DispatchQueue.global().async {
                let found = AgentCLIs.installed()
                DispatchQueue.main.async { installed = found }
            }
        }
        .onChange(of: selected) { _, new in if new != nil { selectedGate = nil; tab = .chosen; panelOpen = true } }
        .onChange(of: selectedGate) { _, new in if new != nil { selected = nil; tab = .chosen; panelOpen = true } }
        .sheet(isPresented: $scheduling) {
            ScheduleEditor(model: model, existing: nil, presetKind: "pipeline", presetTarget: currentRef, presetName: name) { scheduling = false }
        }
    }

    private var topBar: some View {
        HStack(spacing: Theme.s2) {
            Button { model.pipelineDraft = nil; model.pipelineEdits += 1 } label: { Label("All pipelines", systemImage: "chevron.left") }
                .buttonStyle(.borderless)
            TextField("Name this pipeline", text: $name).textFieldStyle(.plain).font(Theme.heading).frame(minWidth: 140, maxWidth: 320)
            if changedOutside {
                Text("Its file changed while you were editing here.").font(Theme.caption).foregroundStyle(Theme.warn).lineLimit(1)
                Button("Use the file") { followFile() }.controlSize(.small)
                Button("Keep mine") {
                    onDisk = diskText
                    changedOutside = false
                    _ = save()
                }
                .controlSize(.small)
            } else if !problem.isEmpty { Text(problem).font(Theme.caption).foregroundStyle(Theme.danger).lineLimit(2) }
            else if !saved.isEmpty { Text(saved).font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: Theme.s2)
            HStack(spacing: Theme.s2) {
                if !isNew {
                    IconButton("Audit", "checklist") { if let p = save() { model.auditPipeline(p) } }
                        .help("Writes a brief for reviewing this pipeline, which spends nothing, and opens a shell to tweak it with any agent")
                    IconButton("Schedule", "calendar.badge.plus") { if save() != nil { scheduling = true } }
                    if carry {
                        IconButton("Run fresh", "arrow.clockwise") { if let p = save() { model.runPipeline(p, fresh: true) } }
                            .help("Runs it without the summary carried from earlier runs")
                    }
                    IconButton("Run", "play.fill") { if let p = save() { model.prepareRun(p) } }
                        .help("Goes to Work with this chosen, to press Run with your agent open")
                    if isTask {
                        IconButton("Keep as a pipeline", "tray.and.arrow.down") { keep() }
                    }
                    IconButton("Move to Trash", "trash") { model.trashPipeline(original) }
                }
                IconButton("Save", "checkmark", prominent: true) { _ = save() }
                    .keyboardShortcut("s", modifiers: .command)
                Button { panelOpen.toggle() } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(.borderless).help(panelOpen ? "Hide the panel, for more room" : "Show the panel")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.s3)
        .padding(.vertical, Theme.s2)
        .background(.bar)
    }

    private var tools: some View {
        HStack(spacing: Theme.s2) {
            IconButton("Add a step", "plus.circle") { addStep(gate: nil) }
            IconButton("OR after it", "arrow.triangle.branch") { addStep(gate: .or) }
                .disabled(selected == nil && selectedGate == nil)
                .help("One of the steps after it runs, chosen by what you say decides it. Add as many branches and ORs as you need")
            IconButton("AND after it", "arrow.triangle.merge") { addStep(gate: .and) }
                .disabled(selected == nil && selectedGate == nil)
                .help("All of the steps after it run at once")
            Spacer(minLength: Theme.s2)
            Text("Drag cards and nodes to place them. Drag from a card's dot to wire it, and a wire's end away to disconnect it.")
                .font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.s3)
        .padding(.vertical, Theme.s1)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).padding(Theme.s2)
            Divider().opacity(0.6)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s3) {
                    switch tab {
                    case .chosen: chosenPanel
                    case .thisRun: thisRunPanel
                    case .settings: settingsPanel
                    case .runs:
                        if isNew { Text("It has not run yet.").font(Theme.caption).foregroundStyle(.secondary) }
                        else { PipelineRunsPanel(model: model, pipeline: original) }
                    }
                }
                .padding(Theme.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.canvas)
    }

    @ViewBuilder private var chosenPanel: some View {
        if let id = selectedGate, let i = steps.firstIndex(where: { $0.wireId == id }) {
            gatePanel(i)
        } else if let i = steps.firstIndex(where: { $0.wireId == selected }) {
            stepPanel(i, steps[i])
        } else {
            Text("Choose a card or a node on the canvas.").font(Theme.caption).foregroundStyle(.secondary)
        }
    }

    /// What the Run bar holds for this project: the same two boxes, whichever screen they are typed on.
    private var runDraft: Binding<RunDraft> {
        let key = original.project?.standardizedFileURL.path ?? ""
        return Binding(get: { model.runDrafts[key] ?? RunDraft() }, set: { value in
            var d = value
            d.pipeline = original.id
            model.runDrafts[key] = d
        })
    }

    private func box(_ title: String, _ hint: String, _ text: Binding<String>, height: CGFloat = 150) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.caption).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: text).font(Theme.body).scrollContentBackground(.hidden)
                if text.wrappedValue.isEmpty {
                    Text(hint).font(Theme.body).foregroundStyle(.tertiary).padding(.horizontal, 5).allowsHitTesting(false)
                }
            }
            .padding(Theme.s1)
            .frame(minHeight: height)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    private var thisRunPanel: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            Text("What is different this time. These run only in the next run, and the pipeline does not change.")
                .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            box("First, before every step", "What to do first, this time only.", Binding(get: { runDraft.wrappedValue.first }, set: { runDraft.wrappedValue.first = $0 }))
            box("Last, after every step", "What to do once they have all finished, this time only.", Binding(get: { runDraft.wrappedValue.last }, set: { runDraft.wrappedValue.last = $0 }))
            if !isNew {
                IconButton("Go to Run", "play.fill", prominent: true) { if let p = save() { model.prepareRun(p) } }
                    .controlSize(.small)
                    .help("Goes to Work with this chosen, to press Run with your agent open")
            }
        }
    }

    @ViewBuilder private var settingsPanel: some View {
        LabeledField("Goal") { TextField("What the whole thing is for; every step is told", text: $goal, axis: .vertical).lineLimit(1...4) }
        LabeledField("Runs on") {
            Picker("", selection: $vm) {
                Text(projectVM.map { "The project's VM (\($0))" } ?? "This Mac").tag("")
                ForEach(model.machines.filter { !$0.name.isEmpty }) { Text("The VM \($0.name)").tag($0.name) }
            }
            .labelsHidden().pickerStyle(.menu)
        }
        LabeledField("Chooses at ORs") { agentPicker($interpreter, blank: "The usual one") }
        LabeledField("Writes summaries") { agentPicker($scribe, blank: "The usual one") }
        Toggle("Carry a short summary from run to run", isOn: $carry).toggleStyle(.checkbox).font(Theme.caption)
        if let path = original.url.map({ ($0.path as NSString).abbreviatingWithTildeInPath }) {
            Text(path).font(Theme.monoSmall).foregroundStyle(.tertiary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(check.warnings, id: \.self) { Text($0).font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    }

    /// An OR or AND node: which it is, and for an OR, how it decides.
    @ViewBuilder private func gatePanel(_ i: Int) -> some View {
        let id = steps[i].wireId
        let next = PipelineGraph(draftPipeline).next(id)
        let branches = PipelineWires.targets(next)
        let isOr: Bool = { if case .choice = next { return true } else { return false } }()
        Text("After \(steps[i].title)").font(Theme.heading)
        Picker("", selection: Binding(get: { isOr }, set: { wantOr in if wantOr != isOr, let line = PipelineWires.switched(next) { steps[i].next = line; recheck() } })) {
            Text("OR: one of these").tag(true)
            Text("AND: all at once").tag(false)
        }
        .labelsHidden().pickerStyle(.segmented)
        if isOr {
            box("What decides it", "The question or rule that picks the next step, such as: did the report describe a real bug?", binding(steps[i].id, \.choose), height: 110)
            Text("An agent reads this after the step before it finishes, with what each branch says below, and picks one. Settings says which agent.")
                .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("All of these start together, each in its own copy of the folder, and their work comes back together where their wires meet.")
                .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(branches, id: \.self) { target in
            if let b = steps.first(where: { $0.wireId == target }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.title).font(Theme.body)
                    if isOr {
                        TextField("Choose it when…", text: binding(b.id, \.when), axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...3)
                    }
                }
            }
        }
        IconButton("Add a branch", "plus.circle") { addStep(gate: isOr ? .or : .and) }.controlSize(.small)
    }

    private func stepPanel(_ index: Int, _ step: EditStep) -> some View {
        let graph = PipelineGraph(draftPipeline)
        let holder = graph.uiHolder(blocking: step.wireId)
        return VStack(alignment: .leading, spacing: Theme.s3) {
            HStack(spacing: Theme.s2) {
                TextField("What this step does, in a few words", text: titleBinding(step.id)).textFieldStyle(.plain).font(Theme.heading)
                if index > 0 {
                    IconButton("Start here", "flag") { makeStart(step.id) }.controlSize(.small).help("The run begins with this step")
                }
                Button { removeStep(step.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Remove this step")
            }
            box("What it does", agent == "shell" ? "a command, e.g. ./export.sh" : "Tell the agent what to do, as you would in a chat.", promptBinding(step.id), height: 240)
            LabeledField("Agent") {
                agentPicker(binding(step.id, \.use), blank: agent.isEmpty ? "First on the list" : "\(AgentCLIs.label(agent)), as this pipeline says")
            }
            LabeledField("Needs") {
                Picker("", selection: binding(step.id, \.needs)) {
                    Text("Anything").tag("")
                    ForEach(NamedAgents.levels, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu)
            }
            Toggle("Uses the screen", isOn: Binding(get: { step.ui }, set: { v in setUI(step.id, v) }))
                .toggleStyle(.checkbox).font(Theme.caption)
                .disabled(holder != nil && !step.ui)
                .help(holder.map { "\($0) is using the screen: one step of a parallel group at a time" } ?? "Only a step with this on may use the screen")
            if let holder, !step.ui { Text("\(holder) is using the screen").font(Theme.caption).foregroundStyle(.tertiary) }
            if chosenByParent(step.wireId) {
                LabeledField("Choose it when") {
                    TextField("what the OR before it reads", text: binding(step.id, \.when), axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...3)
                }
            }
        }
    }

    private func keep() {
        guard let p = save() else { return }
        do {
            let target = try Pipelines.keep(p)
            model.refresh()
            model.editPipeline(Pipelines.parse((try? String(contentsOf: target, encoding: .utf8)) ?? "", url: target, project: p.project))
        } catch {
            problem = error.localizedDescription
        }
    }

    private var projectVM: String? { original.project.flatMap { Projects.info($0)?.vm } }

    private var currentRef: String {
        var p = original
        p.name = name
        return p.ref
    }

    private func chosenByParent(_ id: String) -> Bool {
        let g = PipelineGraph(draftPipeline)
        return g.ids.contains { if case .choice(let a) = g.next($0) { return a.contains(id) } else { return false } }
    }

    private func agentPicker(_ value: Binding<String>, blank: String) -> some View {
        Picker("", selection: value) {
            Text(blank).tag("")
            ForEach(agentChoices, id: \.id) { Text($0.label).tag($0.id) }
            if !value.wrappedValue.isEmpty, !agentChoices.contains(where: { $0.id == value.wrappedValue }) { Text(value.wrappedValue).tag(value.wrappedValue) }
        }
        .labelsHidden().pickerStyle(.menu)
    }

    private var cards: [CanvasCard] {
        let draft = draftPipeline
        return steps.enumerated().map { i, s in
            let line = s.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let who = agentChoices.first { $0.id == s.use }?.label ?? (s.use.isEmpty ? (agent.isEmpty ? "The usual agent" : AgentCLIs.label(agent)) : s.use)
            return CanvasCard(id: s.wireId, title: s.title.isEmpty ? "Untitled" : s.title, agent: who, prompt: line.isEmpty ? "Choose it to say what it does" : line,
                              screen: draft.steps.indices.contains(i) && Pipelines.hasScreen(draft.steps[i], in: draft), first: i == 0)
        }
    }

    /// A step's title, keeping the wires to it as it changes.
    private func titleBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { steps.first { $0.id == id }?.title ?? "" }, set: { value in
            guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
            steps[i].autoNamed = false
            rename(i, to: value)
        })
    }

    /// A step's words, which name it for as long as nobody has named it.
    private func promptBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { steps.first { $0.id == id }?.prompt ?? "" }, set: { value in
            guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
            steps[i].prompt = value
            if steps[i].autoNamed, let name = PipelineWires.name(from: value, taken: Set(steps.indices.filter { $0 != i }.map { steps[$0].wireId })) { rename(i, to: name) }
            recheck()
        })
    }

    private func rename(_ i: Int, to value: String) {
        steps[i].title = value
        let old = steps[i].wireId, new = Pipelines.slug(value)
        let free = !steps.indices.contains { $0 != i && steps[$0].wireId == new }
        if !value.trimmingCharacters(in: .whitespaces).isEmpty, new != old, free {
            for j in steps.indices { steps[j].next = PipelineWires.renaming(old, to: new, in: steps[j].next) }
            steps[i].wireId = new
            for key in [old, "gate:\(old)"] {
                if let spot = positions.removeValue(forKey: key) { positions[key == old ? new : "gate:\(new)"] = spot }
            }
            if selected == old { selected = new }
        }
        recheck()
    }

    private func rewire(_ from: String, from old: String, to new: String) {
        guard let i = steps.firstIndex(where: { $0.wireId == from }) else { return }
        steps[i].next = PipelineWires.replacing(old, with: new, in: PipelineGraph(draftPipeline).next(from))
        recheck()
    }

    /// The run begins with the first step in the file, so that step moves to the top. Every wire is said aloud first,
    /// because a step with no `next:` follows whichever heading comes after it.
    private func makeStart(_ id: UUID) {
        let graph = PipelineGraph(draftPipeline)
        for i in steps.indices where steps[i].next.isEmpty { steps[i].next = PipelineWires.explicit(graph.next(steps[i].wireId)) }
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps.insert(steps.remove(at: i), at: 0)
        recheck()
    }

    private func wire(_ from: String, to: String) {
        guard let i = steps.firstIndex(where: { $0.wireId == from }) else { return }
        steps[i].next = PipelineWires.adding(to, to: PipelineGraph(draftPipeline).next(from))
        recheck()
    }

    private func unwire(_ from: String, from target: String) {
        guard let i = steps.firstIndex(where: { $0.wireId == from }) else { return }
        steps[i].next = PipelineWires.removing(target, from: PipelineGraph(draftPipeline).next(from))
        recheck()
    }

    /// A new step. With nothing chosen, or the last step chosen and no node asked for, it follows on. Otherwise it is wired
    /// after the chosen step, through the node asked for, and a node with nothing after it yet gets two branches to fill in.
    private func addStep(gate: PipelineWires.Gate?) {
        let source = selectedGate ?? selected ?? steps.last?.wireId
        let graph = PipelineGraph(draftPipeline)
        let current = source.map { graph.next($0) } ?? .stop
        let followsOn = gate == nil && (source == steps.last?.wireId || source == nil) && current == .stop
        // A step with no `next:` follows the next heading, so the last one must say it ends before anything is added below it.
        if !followsOn, let last = steps.indices.last, steps[last].next.isEmpty { steps[last].next = "end" }
        let count = gate != nil && current == .stop ? 2 : 1
        var made: [String] = []
        for _ in 0..<count {
            var step = EditStep(title: PipelineWires.newName(taken: Set(steps.map(\.wireId))), prompt: "")
            step.wireId = Pipelines.slug(step.title)
            step.autoNamed = true
            if !followsOn { step.next = "end" }
            steps.append(step)
            made.append(step.wireId)
            positions[step.wireId] = freeSpot(after: source)
        }
        if !followsOn, let source, let i = steps.firstIndex(where: { $0.wireId == source }) {
            let targets = PipelineWires.targets(current) + made
            if let gate, targets.count > 1 { steps[i].next = PipelineWires.line(targets, gate) } else {
                var next = current
                for id in made { steps[i].next = PipelineWires.adding(id, to: next); next = PipelineGraph(draftPipeline).next(source) }
            }
        }
        selected = made.first
        selectedGate = nil
        recheck()
    }

    /// To the right of a card, below whatever is already there.
    private func freeSpot(after source: String?) -> CGPoint {
        let origin = source.flatMap { positions[$0] } ?? CGPoint(x: 110, y: 70)
        var spot = CGPoint(x: source == nil ? origin.x : origin.x + 290, y: origin.y)
        while positions.values.contains(where: { abs($0.x - spot.x) < 150 && abs($0.y - spot.y) < 90 }) { spot.y += 112 }
        return spot
    }

    /// Takes a step away and the wires to it. A step that followed it by the next heading follows the one after.
    private func removeStep(_ id: UUID) {
        guard let step = steps.first(where: { $0.id == id }) else { return }
        let graph = PipelineGraph(draftPipeline)
        for i in steps.indices where steps[i].id != id && !steps[i].next.isEmpty && PipelineWires.targets(graph.next(steps[i].wireId)).contains(step.wireId) {
            steps[i].next = PipelineWires.removing(step.wireId, from: graph.next(steps[i].wireId))
        }
        positions[step.wireId] = nil
        steps.removeAll { $0.id == id }
        if selected == step.wireId { selected = steps.first?.wireId }
        recheck()
    }

    private func setUI(_ id: UUID, _ on: Bool) {
        if let i = steps.firstIndex(where: { $0.id == id }) { steps[i].ui = on }
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

    private func load() {
        name = original.name
        agent = original.agent
        vm = original.vm ?? ""
        steps = original.steps.map { EditStep(title: $0.title, prompt: $0.prompt, use: $0.use ?? "", next: $0.next ?? "", when: $0.when ?? "", choose: $0.choose ?? "", needs: $0.needs ?? "", ui: $0.ui) }
        if steps.isEmpty { steps = [EditStep(title: "New step", prompt: "", autoNamed: true)] }
        for i in steps.indices {
            if steps[i].title.trimmingCharacters(in: .whitespaces).isEmpty {
                steps[i].title = PipelineWires.newName(taken: Set(steps.prefix(i).map { Pipelines.slug($0.title) }))
                steps[i].autoNamed = true
            }
            // A name that only ever said where it stood, from before steps could be moved around.
            if steps[i].title.range(of: #"^(Step \d+|New step( \d+)?)$"#, options: .regularExpression) != nil { steps[i].autoNamed = true }
            steps[i].wireId = Pipelines.slug(steps[i].title)
        }
        goal = original.goal ?? ""
        interpreter = original.interpreter ?? ""
        scribe = original.scribes.joined(separator: ", ")
        carry = original.carry
        // Only what is still there: a step that has gone would keep the canvas wide for nothing.
        let names = Set(steps.map(\.wireId))
        let kept = Pipelines.layout(of: original.url).filter { names.contains($0.key.hasPrefix("gate:") ? String($0.key.dropFirst(5)) : $0.key) }
        positions = PipelineWires.layout(PipelineGraph(draftPipeline)).merging(kept) { $1 }
        recheck()
        onDisk = diskText
        baseline = pageText
    }

    /// Writes the file; nil (and a line saying why) when something is missing.
    @discardableResult
    private func save() -> Pipelines.Pipeline? {
        problem = ""
        // Never over a change this page has not seen: nothing of its own to save means the file is the pipeline.
        if let now = diskText, let seen = onDisk, now != seen {
            if unsaved {
                changedOutside = true
                return nil
            }
            return followFile()
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { problem = "Give it a name."; return nil }
        let kept = steps
        // A card with nothing in it would be dropped from the file, and the wires to it would point at nothing.
        if let empty = steps.first(where: { $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            selected = empty.wireId
            problem = "Say what \(empty.title.isEmpty ? "this step" : empty.title) does, or remove it."
            return nil
        }
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
            var step = Pipelines.Step(title: s.title.trimmingCharacters(in: .whitespaces).isEmpty ? (s.wireId.isEmpty ? PipelineWires.newName(taken: Set(steps.prefix(i).map(\.wireId))) : s.wireId) : s.title, prompt: s.prompt)
            func clean(_ v: String) -> String? {
                let t = v.trimmingCharacters(in: CharacterSet(charactersIn: " |&"))
                return t.isEmpty ? nil : v.trimmingCharacters(in: .whitespaces)
            }
            step.use = clean(s.use)
            step.next = clean(s.next)
            step.when = clean(s.when)
            step.choose = clean(s.choose.replacingOccurrences(of: "\n", with: " "))
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
            onDisk = p.url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            baseline = pageText
            Pipelines.saveLayout(positions, of: p.url)
            // A command typed here is the user's. One that was already in the file is not made so by pressing Save or Run.
            let already = Set(original.steps.compactMap(\.shell))
            for command in p.steps.compactMap(\.shell) where !already.contains(command) { NamedAgents.approveShell(command, project: p.project) }
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

