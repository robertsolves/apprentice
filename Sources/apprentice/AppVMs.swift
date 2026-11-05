import AppKit
import SwiftUI

/// Every VM in one place: each with its state, the chosen one's live screen, and what can be done with it, including
/// opening it outside the window, in Screen Sharing to click and type, or as a window and Dock icon of its own.
struct VMsScreen: View {
    @ObservedObject var model: AppModel
    @State private var output = ""

    /// The VMs on this Mac, then any a project names and nobody has made yet.
    private var rows: [VM.Machine] {
        let known = model.machines.map(\.name)
        let missing = Set(model.projects.compactMap(\.vm)).subtracting(known).sorted()
        return model.machines + missing.map { VM.Machine(name: $0, tart: nil, state: "not made yet", host: nil) }
    }

    private var chosen: VM.Machine? { rows.first { $0.name == model.selectedVM } ?? rows.first }

    var body: some View {
        SplitPane(id: "vms", help: .vms) {
            ListColumn(count: "\(rows.count) VM\(rows.count == 1 ? "" : "s")", newTitle: "New", new: { model.newProject = .empty }) {
                List(selection: Binding(get: { chosen?.name }, set: { model.selectedVM = $0 })) {
                    ForEach(rows) { m in row(m).tag(m.name) }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        } right: {
            if let m = chosen {
                VMDetail(model: model, machine: m, users: model.projects.filter { $0.vm == m.name }).id(m.name)
            } else {
                ScreenPage(title: Section.vms.label, subtitle: "") { AnyView(EmptyView()) } content: { Explainer.vms }
            }
        }
        .background(Theme.canvas)
        .task {
            while !Task.isCancelled {
                model.refreshMachines()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// A VM that is on is a filled dot in its state's colour; one that is off is only a ring.
    @ViewBuilder private func stateDot(_ level: VMDock.Level) -> some View {
        if level == .stopped {
            Circle().strokeBorder(Color(nsColor: level.color), lineWidth: 1.5).frame(width: 8, height: 8)
        } else {
            Circle().fill(Color(nsColor: level.color)).frame(width: 8, height: 8)
        }
    }

    private func row(_ m: VM.Machine) -> some View {
        let users = model.projects.filter { $0.vm == m.name }.map(\.name)
        return HStack(spacing: Theme.s2) {
            stateDot(VMDock.level(of: m.name, on: m.state == "running" || m.host != nil))
            IconRow(icon: m.host == nil ? "server.rack" : "network", title: m.label,
                    detail: (m.host ?? m.state) + " · " + (users.isEmpty ? (m.name.isEmpty ? "websites outside a project" : "not in a project") : users.joined(separator: ", ")))
            if VMDock.running(m.name) != nil {
                Image(systemName: "macwindow.on.rectangle").font(.system(size: 11)).foregroundStyle(.secondary).help("It has a window of its own too")
            }
        }
    }
}

/// One VM: its live screen and everything to do with it.
struct VMDetail: View {
    @ObservedObject var model: AppModel
    let machine: VM.Machine
    let users: [Projects.Info]
    @State private var output = ""
    @State private var busy = false

    private var running: Bool { machine.state == "running" }
    private var made: Bool { machine.state != "not made yet" }
    /// Always said, the default VM as an empty name: a command run in a project's tab would otherwise take that project's VM.
    private var scope: [String] { ["--vm", machine.name] }

    var body: some View {
        if running || machine.host != nil { live } else { stopped }
    }

    /// A VM that is on is its screen: one bar, and the picture filling the rest.
    private var live: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.s2) {
                Text(machine.label).font(Theme.heading).lineLimit(1).layoutPriority(1)
                Text(VMDock.status(of: machine.name) ?? subtitle).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: Theme.s2)
                if let p = users.first {
                    IconButton("Open the project", "arrow.right.circle") { model.show(project: p, tab: .work) }
                        .fixedSize()
                }
                actions.fixedSize(horizontal: true, vertical: false)
            }
            .controlSize(.small)
            .padding(.horizontal, Theme.s3)
            .padding(.vertical, Theme.s2)
            // Clear of the help button the split pane draws in this corner.
            .padding(.trailing, Theme.s5)
            if !output.isEmpty { Output(text: output) }
            VMScreen(name: machine.name, fills: true)
        }
    }

    private var stopped: some View {
        ScreenPage(title: machine.label, subtitle: subtitle) {
            AnyView(actions.fixedSize(horizontal: true, vertical: false))
        } content: {
            Text(made ? "It is stopped. Start it to see its screen here." : "No VM called \(machine.label) on this Mac yet. Making it downloads under 1 GB and takes a few minutes; a tab shows the progress.")
                .font(Theme.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Panel(title: "Who uses it") {
                if users.isEmpty {
                    Text(machine.name.isEmpty ? "Agents use it for websites outside a project, when the choice below says so." : "No project works in it.")
                        .font(Theme.caption).foregroundStyle(.secondary)
                    if !machine.name.isEmpty, made {
                        IconButton("Make a project for it", "folder.badge.plus") { adopt() }.controlSize(.small)
                    }
                }
                ForEach(users) { p in
                    HStack(spacing: Theme.s2) {
                        Text(p.name).font(Theme.body)
                        Spacer()
                        IconButton("Open the project", "arrow.right.circle") { model.show(project: p, tab: .work) }.controlSize(.small)
                    }
                }
            }
            Panel(title: "Websites outside a project") {
                Text("When an agent opens a website outside a project's VM, it uses the default VM if this is on, else this Mac.")
                    .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.s2) {
                    IconButton("Use the default VM", "server.rack") { run(["vm", "on"]) }
                    IconButton("Use this Mac", "laptopcomputer") { run(["vm", "off"]) }
                }
                .controlSize(.small)
            }
            if !output.isEmpty { Output(text: output) }
        }
    }

    private var subtitle: String {
        (machine.host.map { "elsewhere, at \($0)" } ?? machine.state) + (users.isEmpty ? "" : " · " + users.map(\.name).joined(separator: ", "))
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: Theme.s2) {
            if !made {
                IconButton("Make it", "plus", prominent: true) { make() }
            } else if machine.host == nil, !running {
                IconButton(busy ? "Starting…" : "Start", "play.fill", prominent: true) { run(scope + ["vm", "up"]) }.disabled(busy)
            }
            if running || machine.host != nil {
                IconButton("Open a shell", "terminal") { shell() }
                IconButton("Click in it", "cursorarrow.click") { run(scope + ["vm", "look"]) }
                    .help("Opens its screen in Screen Sharing, where you can click and type")
            }
            if made {
                if VMDock.running(machine.name) == nil {
                    IconButton("Detach", "macwindow.on.rectangle") { run(scope + ["vm", "detach"]) }
                        .help("Opens its screen in a window of its own, with a Dock icon showing its state")
                } else {
                    IconButton("Attach", "rectangle.inset.filled") { VMDock.running(machine.name)?.terminate() }
                        .help("Closes its own window. Its screen stays here")
                }
            }
            if running, machine.host == nil {
                IconButton("Stop", "stop.fill") { run(scope + ["vm", "down"]) }
            }
        }
    }

    private func run(_ args: [String]) {
        output = "…"
        busy = true
        model.runCLI(args) { code, out in
            busy = false
            output = code == 0 ? "" : "exit \(code)\n\(out)"
            model.refreshMachines()
        }
    }

    private func make() {
        model.newTab(title: "VM \(machine.label)", command: (["apprentice"] + scope + ["vm", "setup"]).map(VM.shellQuoted).joined(separator: " ") + "; echo; echo 'Done. Close this tab, or keep it as a shell.'; exec \"$SHELL\" -l", project: users.first)
    }

    private func shell() {
        // When ssh ends, so does the tab: a shell after it would be this Mac's, under the VM's name.
        model.newTab(title: "VM \(machine.label)", command: (["apprentice"] + scope + ["vm", "ssh"]).map(VM.shellQuoted).joined(separator: " ") + "; code=$?; echo; echo 'That was the shell in the VM. You can close this tab.'; exit $code", project: users.first)
    }

    private func adopt() {
        output = "…"
        model.runCLI(["project", "new", machine.name, "--vm", machine.name]) { code, out in
            output = code == 0 ? "" : "exit \(code)\n\(out)"
            model.refresh()
        }
    }
}
