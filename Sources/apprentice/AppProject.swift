import AppKit
import SwiftUI

/// One project's screen: everything for the project in one place. Work is its terminal tabs with its VM's
/// live screen beside them; Pipelines, Schedules and Skills show only the project's own; Settings is how it
/// runs and where it is saved.
struct ProjectWorkspace: View {
    @ObservedObject var model: AppModel
    let project: Projects.Info
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            switch model.projectTab {
            case .work: ProjectWork(model: model, project: project)
            case .pipelines: PipelinesView(model: model, project: project)
            case .schedules: SchedulesView(model: model, project: project)
            case .skills: ProjectSkillsView(model: model, project: project)
            case .settings: ProjectDetail(model: model, project: project)
            }
        }
        .background(Theme.canvas)
    }

    private func copyFolder() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(project.folder.path, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private var machine: VM.Machine? { project.vm.flatMap { vm in model.machines.first { $0.name == vm } } }

    private var runsOn: String {
        guard let vm = project.vm else { return "runs on this Mac" }
        guard let m = machine else { return "runs on the VM \(vm), not made yet" }
        return "runs on the VM \(vm) (\(m.host == nil ? m.state : "at \(m.host!)"))"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.s3) {
                Text(project.name).font(Theme.title(17))
                Text(runsOn)
                    .font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: Theme.s3)
                if let who = model.screenBusy(for: project) {
                    // One agent per screen: the next one here waits until it is free.
                    StatusPill(text: "\(project.vm.map { "the VM \($0)" } ?? "this Mac") is busy with \(who)", tint: Theme.warn,
                               icon: "hourglass")
                        .help("One screen, one cursor, one keyboard: an agent here waits until it is free. Projects on their own VMs run at the same time.")
                }
                HStack(spacing: Theme.s2) {
                    IconButton("Show in Finder", "folder") { NSWorkspace.shared.open(project.folder) }
                    IconButton(copied ? "Copied" : "Copy folder", copied ? "checkmark" : "doc.on.doc") { copyFolder() }
                        .help(project.folder.path)
                }
                .controlSize(.small)
            }
            Picker("", selection: $model.projectTab) {
                ForEach(ProjectTab.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented).fixedSize()
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s3)
        .background(.bar)
    }
}

/// Work: the project's terminal, and its VM's live screen beside it when it has one.
struct ProjectWork: View {
    @ObservedObject var model: AppModel
    let project: Projects.Info
    @AppStorage("project.vmShown") private var vmShown = true
    @AppStorage("project.vmWidth") private var vmWidth = 420.0
    @State private var start: Double?
    @State private var output = ""

    private var machine: VM.Machine? { project.vm.flatMap { vm in model.machines.first { $0.name == vm } } }

    var body: some View {
        HStack(spacing: 0) {
            TerminalWorkspace(model: model, project: project)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let vm = project.vm {
                if vmShown {
                    handle
                    vmPanel(vm).frame(width: vmWidth)
                } else {
                    Button { vmShown = true } label: {
                        Label("Show the VM", systemImage: "sidebar.right").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                    .help("Show the VM's screen")
                    .padding(Theme.s3)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .onAppear { model.refreshMachines() }
    }

    /// The divider you drag to make the VM's screen wider or narrower.
    private var handle: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 1)
            .overlay(
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            if start == nil { start = vmWidth }
                            vmWidth = min(max((start ?? vmWidth) - drag.translation.width, 280), 900)
                        }
                        .onEnded { _ in start = nil })
            )
    }

    private func vmPanel(_ vm: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s3) {
                HStack(spacing: Theme.s2) {
                    Text("The VM \(vm)").font(Theme.heading)
                    Spacer()
                    Button { vmShown = false } label: { Image(systemName: "sidebar.right") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Hide the VM's screen")
                }
                if let m = machine {
                    let running = m.state == "running"
                    HStack(spacing: Theme.s2) {
                        StatusPill(text: m.host == nil ? m.state : "elsewhere", tint: running ? Theme.accent : .secondary)
                        Spacer()
                        if m.host == nil {
                            if running {
                                IconButton("Click in it", "cursorarrow.click") { act(vm, "look") }
                                IconButton("Stop", "stop.fill") { act(vm, "down") }
                            } else {
                                IconButton("Start", "play.fill", prominent: true) { act(vm, "up") }
                            }
                        }
                    }
                    .controlSize(.small)
                    if running || m.host != nil { VMScreen(name: m.name) }
                } else {
                    Text("This project works in the VM \(vm), which is not made yet on this Mac. Making it downloads under 1 GB and takes a few minutes; a tab shows the progress.")
                        .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    IconButton("Make it", "plus", prominent: true) {
                        model.newTab(preset: "VM \(vm)", command: "apprentice --vm \(vm) vm setup; echo; echo 'Done. Close this tab, or keep it as a shell.'; exec \"$SHELL\" -l",
                                     project: project)
                    }
                    .controlSize(.small)
                }
                if !output.isEmpty { Output(text: output) }
            }
            .padding(Theme.s3)
        }
        .background(Theme.canvas)
    }

    private func act(_ vm: String, _ action: String) {
        output = "…"
        model.runCLI((vm.isEmpty ? [] : ["--vm", vm]) + ["vm", action]) { code, out in
            output = code == 0 ? "" : "exit \(code)\n\(out)"
            model.refreshMachines()
        }
    }
}

/// Skills: the project's own, kept in its folder (`.apprentice/skills/`). Agents working in the project read
/// them before anyone else's and follow them; they travel with the project when it is saved to GitHub.
struct ProjectSkillsView: View {
    @ObservedObject var model: AppModel
    let project: Projects.Info
    @State private var items: [SkillItem] = []
    @State private var selected: String?
    @State private var adding = false

    private var folder: URL { project.folder.appendingPathComponent(".apprentice/skills") }

    var body: some View {
        SplitPane(id: "project-skills", help: .skills) {
            ListColumn(count: "\(items.count) skill\(items.count == 1 ? "" : "s")", newTitle: "New", new: { adding = true }) {
                if items.isEmpty {
                    Text("No skills for this project yet").font(Theme.caption).foregroundStyle(.secondary)
                        .padding(Theme.s4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    List(selection: $selected) {
                        ForEach(items) { item in IconRow(icon: item.icon, title: item.title, detail: item.detail).tag(item.id) }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            }
        } right: {
            if let id = selected, let item = items.first(where: { $0.id == id }) {
                SkillEditor(model: model, item: item) { reload(select: $0) }.id(item.id)
            } else {
                ScreenPage(title: "Skills for \(project.name)", subtitle: "") {
                    AnyView(HStack(spacing: Theme.s2) {
                        IconButton("Show the folder", "folder") {
                            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(folder)
                        }
                        IconButton("New skill", "plus", prominent: true) { adding = true }
                    })
                } content: {
                    Panel(title: "Only for this project") {
                        Text("What agents should know for this project's work: how its sites and apps work, the steps it repeats, its rules. Agents working in this project read these first and follow them. They are files in the project's folder, so they are saved with it and come back when you open it on another Mac.")
                            .font(Theme.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .background(Theme.canvas)
        .onAppear { reload() }
        .sheet(isPresented: $adding) {
            NewPlaybookSheet(model: model, into: folder) { created in
                adding = false
                if let created { reload(select: folder.appendingPathComponent(created).path) }
            }
        }
    }

    private func reload(select: String? = nil) {
        items = Self.load(folder)
        if let select { selected = select }
        else if let s = selected, !items.contains(where: { $0.id == s }) { selected = nil }
    }

    /// Every skill file in the project's folder, by its title.
    static func load(_ folder: URL) -> [SkillItem] {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        // The enumerator can hand back resolved paths (`/private/var/…`, a linked ~/Apprentice), so compare like with like.
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        var out: [SkillItem] = []
        for case let url as URL in walk where url.pathExtension == "md" {
            let full = url.resolvingSymlinksInPath().standardizedFileURL.path
            let path = full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : url.lastPathComponent
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let title = text.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
                ?? url.deletingPathExtension().lastPathComponent
            out.append(SkillItem(title: title, detail: path, origin: .project, url: url, path: path))
        }
        return out.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
