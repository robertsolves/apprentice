import AppKit
import SwiftUI

/// `~/.apprentice/Apprentice.app`: the same binary in a real bundle, so the window opens from the Dock or
/// Spotlight, the menu-bar item can open it, and notifications carry apprentice's icon. `kit.sh` signs it
/// with the local identity, so the Accessibility and Screen Recording grants stay with it across rebuilds.
enum AppBundle {
    static let identifier = "com.apprentice.app"
    static var path: URL { Store.dir.appendingPathComponent("Apprentice.app") }
    static var executable: URL { path.appendingPathComponent("Contents/MacOS/apprentice") }
    /// True inside the bundle: then this process is the window, not the CLI.
    static var inBundle: Bool { Bundle.main.bundleIdentifier == identifier }

    /// A window already open, so a second `apprentice app` only brings it forward.
    static var runningInstance: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first { $0.processIdentifier != getpid() }
    }

    /// Builds the bundle if the binary changed, then opens it. False when it could not be built.
    static func open() -> Bool {
        if let running = runningInstance {
            running.activate()
            return true
        }
        guard Notify.appBundleExecutable() != nil else { return false }
        sign()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", path.path]
        return (try? p.run()) != nil
    }

    /// Signs the bundle with the local identity where there is one, so its grants survive a rebuild.
    static func sign() {
        let identities = Repo.run("security", ["find-identity", "-p", "codesigning"]).out
        let identity = ProcessInfo.processInfo.environment["APPRENTICE_SIGN_IDENTITY"]
            ?? (identities.contains("\"apprentice\"") ? "apprentice" : "-")
        _ = Repo.run("codesign", ["--force", "--deep", "-s", identity, path.path])
    }

    /// `apprentice app --install`, from kit.sh: builds the bundle and signs it, without opening a window.
    static func install() -> Int32 {
        guard Notify.appBundleExecutable() != nil else { return 1 }
        sign()
        return 0
    }

    /// `apprentice app` from a terminal: the CLI builds the bundle and opens it, so the window is its own process.
    static func launchFromCLI() -> Never {
        if inBundle { AppMain.run() }
        if open() { exit(0) }
        FileHandle.standardError.write(Data("apprentice app: could not build \(path.path)\n".utf8))
        exit(5)
    }
}

/// The window's process: its own `NSApplication`, never the daemon's, so a stuck terminal or a crashed view
/// cannot take a pending approval down with it. It talks to the daemon over the same socket as the CLI.
enum AppMain {
    static func run() -> Never {
        if !AppBundle.inBundle { AppBundle.launchFromCLI() }
        if !Wire.ping() { try? Wire.startDaemon() }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.applicationIconImage = Ask.icon
        if let icon = NSImage(contentsOfFile: Bundle.main.bundlePath + "/Contents/Resources/AppIcon.icns") {
            app.applicationIconImage = icon
        }
        app.run()
        exit(0)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Files and folders dropped on the Dock icon open a tab there.
        NSApp.activate(ignoringOtherApps: true)
        let model = AppModel()
        let root = RootView(model: model)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "apprentice"
        window.titlebarAppearsTransparent = true
        window.contentView = hosting
        window.setFrameAutosaveName("apprentice.window")
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.mainMenu = MainMenu.make()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }
}

enum MainMenu {
    /// A minimal menu bar: what a Mac app needs to copy, paste, quit and close a window.
    static func make() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About apprentice", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit apprentice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = win
        return main
    }
}

/// What the window shows and the one place it acts: every button goes through a command (`Wire.send`) or a
/// file the commands own, so nothing works here that a script could not do.
final class AppModel: ObservableObject {
    @Published var section: Section = .terminal
    @Published var tabs: [TermSession] = []
    @Published var selectedTab: String?
    @Published var pending: [Approvals.Pending] = []
    @Published var schedules: [Schedules.Schedule] = []
    @Published var awayTasks: [Away.Task] = []
    @Published var awayOn = false
    @Published var session: Session?
    @Published var daemonUp = false
    @Published var busy = false
    @Published var output = ""
    @Published var revision = 0
    @Published var paletteOpen = false
    @Published var paletteText = ""

    let home = FileManager.default.homeDirectoryForCurrentUser

    init() {
        refresh()
        newTab(preset: "Shell", command: nil)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    // MARK: - reads

    func refresh() {
        let pendingFiles = [Store.url("pending.json")]
            + ((try? FileManager.default.contentsOfDirectory(atPath: Store.dir.appendingPathComponent("vms").path)) ?? [])
            .map { Store.dir.appendingPathComponent("vms/\($0)/pending.json") }
        var found: [Approvals.Pending] = []
        for file in pendingFiles {
            guard let data = try? Data(contentsOf: file) else { continue }
            let list = (try? JSONDecoder().decode([Approvals.Pending].self, from: data))
                ?? (try? JSONDecoder().decode(Approvals.Pending.self, from: data)).map { [$0] } ?? []
            let now = Date().timeIntervalSince1970
            found += list.filter { now < $0.expires }
        }
        pending = found.sorted { $0.at < $1.at }
        schedules = Schedules.all()
        awayTasks = Away.all()
        awayOn = Away.mode
        session = Session.stored
        busy = pending.count > 0 || StatusItem.state == .working
        revision += 1
        for tab in tabs { tab.hasApproval = pending.contains { $0.tab == tab.id } }
        // The socket check runs off the main thread: a busy daemon must not freeze the window.
        DispatchQueue.global(qos: .utility).async {
            let up = Wire.ping()
            DispatchQueue.main.async { if self.daemonUp != up { self.daemonUp = up } }
        }
    }

    var status: String {
        if !pending.isEmpty { return "needs approval" }
        if !daemonUp { return "idle" }
        return busy ? "working" : "idle"
    }

    // MARK: - acts

    /// Every button: the same request the CLI sends, marked as the user's own.
    @discardableResult
    func run(_ cmd: String, _ args: [String] = []) -> (code: Int32, out: String) {
        guard let response = try? Wire.send(Request(cmd: cmd, args: args, user: true)) else {
            return (5, "daemon did not answer: run `apprentice serve` to see why")
        }
        return (response.code, response.out)
    }

    func act(_ cmd: String, _ args: [String] = []) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let (code, out) = self.run(cmd, args)
            DispatchQueue.main.async {
                self.busy = false
                self.output = (code == 0 ? "" : "exit \(code): ") + out
                self.refresh()
            }
        }
    }

    func approve(_ token: String) { act("approve", [token]) }
    func deny(_ token: String) { act("deny", [token]) }

    func togglePause() {
        Pause.on.toggle()
        output = Pause.on ? "paused: new actions wait" : "running"
    }

    // MARK: - tabs

    func newTab(preset: String, command: String?, dir: URL? = nil, vm: String? = nil) {
        let presetValues = Config.current.tabPresets[preset] ?? [:]
        let folder = dir ?? (presetValues["dir"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }) ?? home
        let cmd = command ?? presetValues["cmd"]
        let session = TermSession(title: preset, dir: folder, command: cmd, env: [:],
                                  vm: vm ?? presetValues["vm"])
        tabs.append(session)
        selectedTab = session.id
    }

    func closeTab(_ id: String) {
        tabs.first { $0.id == id }?.close()
        tabs.removeAll { $0.id == id }
        if selectedTab == id { selectedTab = tabs.last?.id }
    }

    var selectedSession: TermSession? { tabs.first { $0.id == selectedTab } }

    func openLogTab() {
        newTab(preset: "Log", command: "apprentice log --tail 50 && exec tail -f \(Sessions.runs.path)/$(ls -t \(Sessions.runs.path) | head -1)/steps.jsonl | sed 's/^{//;s/}$//'")
    }

    // MARK: - settings

    static var exampleConfig: URL { Repo.root.appendingPathComponent("agent/config.example.toml") }
}

enum Section: String, CaseIterable, Identifiable {
    case terminal = "Terminal"
    case schedules = "Schedules"
    case approvals = "Approvals"
    case activity = "Activity"
    case sites = "Sites"
    case settings = "Settings"
    case playbooks = "Playbooks"
    case vms = "VMs"
    case health = "Updates & health"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .terminal: return "apple.terminal"
        case .schedules: return "clock"
        case .approvals: return "hand.raised"
        case .activity: return "chart.bar"
        case .sites: return "globe"
        case .settings: return "slider.horizontal.3"
        case .playbooks: return "book"
        case .vms: return "desktopcomputer"
        case .health: return "heart"
        }
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: Binding(
                get: { model.section },
                set: { if let s = $0 { model.section = s } })) { section in
                Label {
                    HStack {
                        Text(section.rawValue)
                        if section == .approvals, !model.pending.isEmpty {
                            Spacer()
                            Text("\(model.pending.count)")
                                .font(.caption.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange))
                                .foregroundColor(.white)
                        }
                    }
                } icon: {
                    Image(systemName: section.symbol)
                }
                .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            detail
                .frame(minWidth: 640, minHeight: 420)
                .toolbar { toolbar }
        }
        .sheet(isPresented: $model.paletteOpen) {
            CommandPalette(model: model)
        }
        .background(shortcuts)
        .onAppear { model.refresh() }
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .terminal: TerminalWorkspace(model: model)
        case .schedules: SchedulesView(model: model)
        case .approvals: ApprovalsView(model: model)
        case .activity: ActivityView(model: model)
        case .sites: SitesView(model: model)
        case .settings: SettingsView(model: model)
        case .playbooks: PlaybooksView(model: model)
        case .vms: VMsView(model: model)
        case .health: HealthView(model: model)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .status) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.pending.isEmpty ? (model.busy ? Color.orange : Color.green) : Color.red)
                    .frame(width: 8, height: 8)
                Text(model.status)
                if let session = model.session, let url = session.url {
                    Text("· \(session.app) · \(URL(string: url)?.host ?? url)")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.togglePause()
            } label: {
                Label(Pause.on ? "Resume" : "Pause", systemImage: Pause.on ? "play.fill" : "pause.fill")
            }
            .help("Hold apprentice still: new actions wait until you resume")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.paletteOpen = true
                model.paletteText = ""
            } label: {
                Label("Command", systemImage: "command")
            }
            .keyboardShortcut("k", modifiers: .command)
            .help("Run any apprentice command (⌘K)")
        }
    }

    /// ⌘1…9 choose the sidebar sections; keyboard first, as the design asks.
    private var shortcuts: some View {
        ZStack {
            ForEach(Array(Section.allCases.enumerated()), id: \.offset) { index, section in
                Button(section.rawValue) { model.section = section }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0.01)
            }
        }
    }
}

// MARK: - Terminal

struct TerminalWorkspace: View {
    @ObservedObject var model: AppModel

    private var pendingForSelected: Approvals.Pending? {
        model.pending.first { $0.tab == model.selectedTab }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if let session = model.selectedSession {
                ZStack(alignment: .bottom) {
                    TerminalPane(term: session, font: font, locked: pendingForSelected != nil)
                        .id(session.id)
                    if let pending = pendingForSelected {
                        ApprovalBanner(model: model, pending: pending)
                            .padding(10)
                    }
                }
                footer(session)
            } else {
                ContentUnavailableView("No tab", systemImage: "terminal", description: Text("⌘T opens a shell"))
            }
        }
    }

    private var font: NSFont {
        NSFont(name: Config.current.appFont, size: Config.current.appFontSize)
            ?? NSFont.monospacedSystemFont(ofSize: Config.current.appFontSize, weight: .regular)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.tabs) { tab in
                        tabButton(tab)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            Menu {
                Button("Shell") { model.newTab(preset: "Shell", command: nil) }
                Button("Claude Code") { model.newTab(preset: "Claude Code", command: "claude") }
                Button("Codex") { model.newTab(preset: "Codex", command: "codex") }
                Button("opencode") { model.newTab(preset: "opencode", command: "opencode") }
                Button("Kilo") { model.newTab(preset: "Kilo", command: "kilo") }
                Button("Log (apprentice log, following)") { model.openLogTab() }
                if !Config.current.tabPresets.isEmpty {
                    Divider()
                    ForEach(Config.current.tabPresets.keys.sorted(), id: \.self) { name in
                        Button(name) { model.newTab(preset: name, command: nil) }
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("New tab (⌘T)")
        }
        .background(.bar)
    }

    private func tabButton(_ tab: TermSession) -> some View {
        let selected = tab.id == model.selectedTab
        return HStack(spacing: 6) {
            Text(tab.title).lineLimit(1)
            if tab.hasApproval {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if let code = tab.exited {
                Text("· \(code)").foregroundStyle(code == 0 ? Color.secondary : Color.red)
            }
            Button {
                model.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(selected ? 1 : 0.5)
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.22) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedTab = tab.id }
        .help(tab.subtitle.isEmpty ? tab.title : tab.subtitle)
    }

    private func footer(_ session: TermSession) -> some View {
        HStack(spacing: 10) {
            Text(session.title).bold()
            if !session.subtitle.isEmpty { Text(session.subtitle) }
            Spacer()
            if let session = model.session {
                Text("\(session.app) · project \(Project.find(from: FileManager.default.currentDirectoryPath)?.deletingLastPathComponent().lastPathComponent ?? "—") · model \(Config.current.runModel)")
            } else {
                Text("no bound app session")
            }
            Text("kill switch ctrl+opt+cmd+.")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }
}

struct ApprovalBanner: View {
    @ObservedObject var model: AppModel
    let pending: Approvals.Pending
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(pending.summary).font(.callout.weight(.semibold)).lineLimit(2)
            }
            ForEach(pending.warnings ?? [], id: \.self) { warning in
                Text("⚠ \(warning)").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                TextField("Your answer, if it asks one", text: $answer)
                    .textFieldStyle(.roundedBorder)
                Button("Deny") { model.deny(pending.token); answer = "" }
                Button("Allow") {
                    model.approve(pending.token)
                    answer = ""
                }
                .keyboardShortcut(.defaultAction)
            }
            Text("Same as `apprentice approve \(pending.token)` · tab \(pending.tab ?? "—") · expires \(Date(timeIntervalSince1970: pending.expires).formatted(date: .omitted, time: .shortened))")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.6)))
        .shadow(radius: 8)
    }
}

// MARK: - Schedules

extension Schedules.Schedule: Identifiable {}

struct SchedulesView: View {
    @ObservedObject var model: AppModel
    @State private var selected: String?
    @State private var adding = false

    var body: some View {
        HSplitView {
            List(selection: $selected) {
                ForEach(model.schedules) { schedule in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(schedule.name).bold()
                            if !schedule.enabled { Text("paused").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Text(schedule.when_ + (schedule.jitter > 0 ? " ±\(schedule.jitter) min" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                        if let next = schedule.next, schedule.enabled {
                            Text("next \(next.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if let result = schedule.lastResult {
                            Text("last: \(result)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(schedule.id)
                }
            }
            .frame(minWidth: 240, idealWidth: 280)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Schedules").font(.title2.bold())
                    Spacer()
                    Button {
                        adding = true
                    } label: { Label("Add", systemImage: "plus") }
                    Button {
                        model.act("schedule", ["agent", "on"])
                    } label: { Label("Start at login", systemImage: "power") }
                        .help("A LaunchAgent runs `apprentice serve` at login, so schedules fire without anything open")
                }
                .padding(12)
                Divider()
                if let id = selected, let schedule = model.schedules.first(where: { $0.id == id }) {
                    ScheduleDetail(model: model, schedule: schedule)
                } else {
                    ContentUnavailableView("No schedule chosen", systemImage: "clock",
                                           description: Text("Schedules run prompts, `apprentice run` tasks and flows later or again."))
                }
            }
        }
        .sheet(isPresented: $adding) {
            ScheduleEditor(model: model, existing: nil) { adding = false }
        }
    }
}

struct ScheduleDetail: View {
    @ObservedObject var model: AppModel
    let schedule: Schedules.Schedule
    @State private var editing = false
    @State private var runs: [(name: String, url: URL)] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Toggle("Enabled", isOn: Binding(get: { schedule.enabled }, set: { on in
                        model.act("schedule", [on ? "resume" : "pause", schedule.id])
                    }))
                    .toggleStyle(.switch)
                    Spacer()
                    Button("Run now") { model.act("schedule", ["now", schedule.id]) }
                    Button("Edit") { editing = true }
                    Button("Delete", role: .destructive) { model.act("schedule", ["rm", schedule.id]) }
                }
                GroupBox("What") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(schedule.kind.label).font(.caption).foregroundStyle(.secondary)
                        Text(schedule.target).textSelection(.enabled).font(.system(.body, design: .monospaced))
                        if let dir = schedule.dir { Text("in \(dir)").font(.caption) }
                        if let vm = schedule.vm { Text("VM \(vm)").font(.caption) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                GroupBox("When") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(schedule.when_).bold()
                        if schedule.jitter > 0 { Text("±\(schedule.jitter) min, so it never lands on the same second").font(.caption).foregroundStyle(.secondary) }
                        if let next = schedule.next { Text("next: \(next.formatted(date: .complete, time: .standard))").font(.caption) }
                        Divider()
                        Text("Next five runs").font(.caption.bold())
                        ForEach(Schedules.preview(schedule), id: \.self) { date in
                            Text(date.formatted(date: .abbreviated, time: .standard)).font(.caption).monospacedDigit()
                        }
                        if Schedules.quietHours(schedule).from >= 0 {
                            Text("quiet hours \(Int(Schedules.quietHours(schedule).from)):00–\(Int(Schedules.quietHours(schedule).to) % 24):00: a run there moves to the end")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                GroupBox("Runs") {
                    VStack(alignment: .leading, spacing: 4) {
                        if runs.isEmpty {
                            Text("no runs yet").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(runs, id: \.name) { run in
                            Button(run.name) { NSWorkspace.shared.open(run.url) }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }
            .padding(12)
        }
        .onAppear { runs = Schedules.runs(schedule.id) }
        .onChange(of: model.revision) { _, _ in runs = Schedules.runs(schedule.id) }
        .sheet(isPresented: $editing) {
            ScheduleEditor(model: model, existing: schedule) { editing = false }
        }
    }
}

struct ScheduleEditor: View {
    @ObservedObject var model: AppModel
    let existing: Schedules.Schedule?
    var done: () -> Void

    @State private var name = ""
    @State private var kind = "prompt"
    @State private var target = ""
    @State private var trigger = "daily"
    @State private var at = ""
    @State private var every = "60"
    @State private var daily = "09:00"
    @State private var weekly = "mon,wed 09:00"
    @State private var cron = "0 9 * * 1-5"
    @State private var jitter = "15"
    @State private var dir = ""
    @State private var vm = ""
    @State private var agent = "claude"
    @State private var model_ = ""
    @State private var site = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(existing == nil ? "New schedule" : "Edit schedule").font(.title3.bold())
            Form {
                TextField("Name", text: $name)
                Picker("Runs", selection: $kind) {
                    Text("an agent CLI prompt").tag("prompt")
                    Text("apprentice run").tag("run")
                    Text("a playbook flow").tag("do")
                    Text("a shell command").tag("sh")
                }
                if kind == "prompt" {
                    TextField("Agent CLI (claude, codex, opencode…)", text: $agent)
                }
                TextField("The \(kind == "prompt" ? "prompt" : kind == "run" ? "task" : kind == "do" ? "flow" : "command")", text: $target)
                Picker("When", selection: $trigger) {
                    Text("once, at a date and time").tag("at")
                    Text("every N minutes").tag("every")
                    Text("daily").tag("daily")
                    Text("on chosen weekdays").tag("weekly")
                    Text("a cron line").tag("cron")
                }
                switch trigger {
                case "at": TextField("2026-11-05T09:00:00", text: $at)
                case "every": TextField("Minutes", text: $every)
                case "daily": TextField("HH:MM", text: $daily)
                case "weekly": TextField("mon,wed 09:00", text: $weekly)
                default: TextField("m h dom mon dow", text: $cron)
                }
                TextField("Jitter (± minutes)", text: $jitter)
                TextField("Folder (empty: home)", text: $dir)
                TextField("VM (empty: this Mac)", text: $vm)
                TextField("Model (empty: the agent's own)", text: $model_)
                TextField("Site whose quiet hours apply (optional)", text: $site)
            }
            HStack {
                Spacer()
                Button("Cancel") { done() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear(perform: load)
    }

    private func load() {
        guard let s = existing else { return }
        name = s.name
        kind = s.kind == .flow ? "do" : s.kind.rawValue
        target = s.target
        agent = s.agent ?? "claude"
        if s.at != nil { trigger = "at"; at = s.at.map(Schedules.stamp) ?? "" }
        if let v = s.every { trigger = "every"; every = "\(v)" }
        if let v = s.daily { trigger = "daily"; daily = v }
        if let v = s.weekly { trigger = "weekly"; weekly = v }
        if let v = s.cron { trigger = "cron"; cron = v }
        jitter = "\(s.jitter)"
        dir = s.dir ?? ""
        vm = s.vm ?? ""
        model_ = s.model ?? ""
        site = s.site ?? ""
    }

    private func save() {
        var args = ["add", name]
        if let existing { args += ["--id", existing.id] }
        switch trigger {
        case "at": args += ["--at", at]
        case "every": args += ["--every", every]
        case "daily": args += ["--daily", daily]
        case "weekly": args += ["--weekly", weekly]
        default: args += ["--cron", cron]
        }
        args += ["--\(kind)", target]
        if kind == "prompt" { args += ["--agent", agent] }
        args += ["--jitter", jitter]
        if !dir.isEmpty { args += ["--dir", (dir as NSString).expandingTildeInPath] }
        if !vm.isEmpty { args += ["--vm", vm] }
        if !model_.isEmpty { args += ["--model", model_] }
        if !site.isEmpty { args += ["--site", site] }
        model.act("schedule", args)
        done()
    }
}

// MARK: - Approvals

extension Approvals.Pending: Identifiable {
    public var id: String { token }
}

struct ApprovalsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Waiting on you").font(.title2.bold())
                Spacer()
                Text(model.pending.isEmpty ? "nothing pending" : "\(model.pending.count) waiting")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            if model.pending.isEmpty {
                ContentUnavailableView("Nothing needs you", systemImage: "checkmark.seal",
                                       description: Text("Pending ⚠ steps from every daemon, and open questions, appear here."))
            } else {
                List(model.pending, id: \.token) { pending in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(pending.summary).font(.body.weight(.semibold))
                            Spacer()
                            Text(pending.token).font(.caption).monospaced().foregroundStyle(.secondary)
                        }
                        ForEach(pending.warnings ?? [], id: \.self) { warning in
                            Text("⚠ \(warning)").font(.caption).foregroundStyle(.orange)
                        }
                        HStack {
                            Text("\(pending.cmd) · tab \(pending.tab ?? "—") · \(Date(timeIntervalSince1970: pending.at).formatted(date: .omitted, time: .standard))")
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button("Deny", role: .destructive) { model.deny(pending.token) }
                            Button("Allow") { model.approve(pending.token) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

// MARK: - Activity

struct ActivityView: View {
    @ObservedObject var model: AppModel
    @State private var part = 0
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $part) {
                Text("Now").tag(0)
                Text("Grow").tag(1)
                Text("Sessions").tag(2)
                Text("Events").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(10)
            .onChange(of: part) { _, _ in load() }
            Divider()
            TextEditor(text: .constant(text))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
            HStack {
                Button("Refresh") { load() }
                Spacer()
                Button("Open a tab and work on this") {
                    model.newTab(preset: "Claude Code", command: "claude")
                }
            }
            .padding(8)
        }
        .onAppear(perform: load)
    }

    private func load() {
        switch part {
        case 0:
            let s = model.session
            let bits = [
                "daemon: \(model.daemonUp ? "running" : "not running") · \(model.status)",
                s.map { "session \($0.id ?? "-") · \($0.app) · window \($0.wid)" + ($0.url.map { " · \($0)" } ?? "") } ?? "no session bound",
                "pending approvals: \(model.pending.count)",
                "away: \(model.awayOn ? "on" : "off") · queued \(model.awayTasks.filter { $0.state == .queued }.count)",
                "",
                model.run("budget", []).out,
                "",
                model.run("cool", []).out,
            ]
            text = bits.joined(separator: "\n")
        case 1: text = model.run("grow", ["--days", "14"]).out
        case 2: text = model.run("sessions", ["--limit", "25"]).out
        default:
            let host = model.session?.url.flatMap { URL(string: $0)?.host } ?? ""
            text = host.isEmpty ? "open a session to see one site's events" : model.run("activity", [host, "--days", "14"]).out
        }
    }
}

// MARK: - Sites

struct SitesView: View {
    @ObservedObject var model: AppModel
    @State private var site = ""
    @State private var quiet = ""
    @State private var perDay = ""
    @State private var sitting = ""
    @State private var note = ""
    @State private var usage = ""
    @State private var wizard = false

    private var sites: [String] {
        var all = Set(Config.current.profiles.keys)
        all.formUnion(Budgets.table().keys)
        all.remove("web"); all.remove("native")
        return all.sorted()
    }

    var body: some View {
        HSplitView {
            List(selection: $site) {
                ForEach(sites, id: \.self) { name in
                    HStack {
                        Text(name)
                        if Config.socialSites.contains(name) { Text("careful").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .tag(name)
                }
            }
            .frame(minWidth: 200, idealWidth: 240)
            .onChange(of: site) { _, _ in load() }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(site.isEmpty ? "Sites" : site).font(.title2.bold())
                        Spacer()
                        Button { wizard = true } label: { Label("New site", systemImage: "plus") }
                    }
                    if site.isEmpty {
                        Text("Choose a site to see its pace, quiet hours, budgets and any cooldown or challenge.")
                            .foregroundStyle(.secondary)
                    } else {
                        GroupBox("Pace ([pace.\"\(site)\"])") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("style: \(Config.current.profiles[site].map { _ in "from config.toml" } ?? "default")")
                                    .font(.caption).foregroundStyle(.secondary)
                                TextField("Quiet hours, e.g. 2,6 (empty: none)", text: $quiet)
                                TextField("Actions per day (empty: off)", text: $perDay)
                                TextField("Longest sitting, minutes (empty: off)", text: $sitting)
                                Button("Save to config.toml") { savePace() }
                            }
                            .padding(4)
                        }
                        GroupBox("Usage") {
                            Text(usage.isEmpty ? "…" : usage)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(4)
                        }
                        GroupBox("Policy notes ([policy.\"\(site)\"])") {
                            VStack(alignment: .leading, spacing: 6) {
                                TextEditor(text: $note).frame(height: 70).font(.caption)
                                Text("Shown with the site's hints; never used to refuse it.")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Button("Save note to routes.toml") { saveNote() }
                            }
                            .padding(4)
                        }
                        GroupBox("Cooldown and challenge") {
                            HStack {
                                Button("I checked it: clear the cooldown") { model.act("cool", ["--clear", site]) }
                                Spacer()
                            }
                            .padding(4)
                        }
                    }
                }
                .padding(12)
            }
        }
        .sheet(isPresented: $wizard) {
            NewSiteWizard(model: model) { wizard = false }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !site.isEmpty else { return }
        usage = model.run("budget", [site]).out
        let pace = Config.current.profiles[site] ?? Config.current.defaultPace
        quiet = pace.quietFrom >= 0 ? "\(Int(pace.quietFrom)),\(Int(pace.quietTo))" : ""
        perDay = pace.actionsPerDay > 0 ? "\(Int(pace.actionsPerDay))" : ""
        sitting = pace.sittingMax > 0 ? "\(Int(pace.sittingMax))" : ""
        note = Policies.find(site)?.notes ?? ""
    }

    private func savePace() {
        let path = Config.path
        try? FileManager.default.copyItem(at: path, to: path.appendingPathExtension("bak"))
        let section = "pace.\"\(site)\""
        if quiet.isEmpty {
            Toml.remove(path, section, "quiet_hours")
        } else {
            let parts = quiet.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2 { Toml.set(path, section, "quiet_hours", "[\(parts[0]), \(parts[1])]") }
        }
        Toml.set(path, section, "actions_per_day", perDay.isEmpty ? "0" : perDay)
        Toml.set(path, section, "session_max_min", sitting.isEmpty ? "0" : sitting)
        Config.reloadIfChanged()
        model.act("settings", [])
    }

    private func saveNote() {
        let path = Settings.dir.appendingPathComponent("routes.toml")
        Toml.set(path, "policy.\"\(site)\"", "notes", "\"\(note.replacingOccurrences(of: "\"", with: "\\\""))\"")
        model.act("policy", [site])
    }
}

struct NewSiteWizard: View {
    @ObservedObject var model: AppModel
    var done: () -> Void
    @State private var domain = ""
    @State private var quiet = "2,6"
    @State private var perDay = "400"

    private var style: String { Config.socialSites.contains { domain.hasSuffix($0) } ? "careful" : "steady" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New site").font(.title3.bold())
            Form {
                TextField("Domain, e.g. example.com", text: $domain)
                LabeledContent("Suggested pace", value: style)
                TextField("Quiet hours (from,to)", text: $quiet)
                TextField("Actions per day", text: $perDay)
            }
            Text("It adds [pace.\"\(domain)\"] to config.toml with the \(style) style as its base.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { done() }
                Button("Add") {
                    let path = Config.path
                    try? FileManager.default.copyItem(at: path, to: path.appendingPathExtension("bak"))
                    let section = "pace.\"\(domain)\""
                    Toml.set(path, section, "style", "\"\(style)\"")
                    let parts = quiet.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    if parts.count == 2 { Toml.set(path, section, "quiet_hours", "[\(parts[0]), \(parts[1])]") }
                    Toml.set(path, section, "actions_per_day", perDay)
                    Config.reloadIfChanged()
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(domain.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var raw = false
    @State private var text = ""
    @State private var edits: [String: String] = [:]
    @State private var status = ""
    @State private var fields: [ConfigField] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $raw) {
                    Text("Form").tag(false)
                    Text("Raw TOML").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Spacer()
                Text(Config.path.path).font(.caption).foregroundStyle(.secondary)
                Button("Reveal") { NSWorkspace.shared.selectFile(Config.path.path, inFileViewerRootedAtPath: Settings.dir.path) }
            }
            .padding(10)
            Divider()
            if raw {
                TextEditor(text: $text).font(.system(.body, design: .monospaced)).padding(6)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(dictionaryKeys(fields), id: \.self) { section in
                            GroupBox(section.isEmpty ? "top" : section) {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(fields.filter { $0.section == section }, id: \.self) { field in
                                        fieldRow(field)
                                    }
                                }
                                .padding(4)
                            }
                        }
                        GroupBox("Projects, routes and phone") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Projects: \(model.run("project", ["status"]).out)").font(.caption)
                                Button("Routes: edit \(Settings.dir.path)/routes.toml") {
                                    NSWorkspace.shared.open(Settings.dir.appendingPathComponent("routes.toml"))
                                }
                                Button("Phone setup (topic, test push, QR)") { model.act("phone", []) }
                            }
                            .padding(4)
                        }
                    }
                    .padding(12)
                }
            }
            Divider()
            HStack {
                Text(status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(raw ? "Save raw TOML" : "Save changes") { save() }
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(8)
        }
        .onAppear(perform: load)
        .onChange(of: raw) { _, _ in load() }
    }

    private func dictionaryKeys(_ fields: [ConfigField]) -> [String] {
        var seen: [String] = []
        for field in fields where !seen.contains(field.section) { seen.append(field.section) }
        return seen
    }

    private func fieldRow(_ field: ConfigField) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(field.key).font(.caption.bold())
            if !field.comment.isEmpty {
                Text(field.comment).font(.caption2).foregroundStyle(.secondary)
            }
            if field.value == "true" || field.value == "false" {
                Toggle("", isOn: Binding(
                    get: { (edits[field.id] ?? field.value) == "true" },
                    set: { edits[field.id] = $0 ? "true" : "false" }))
                .labelsHidden()
            } else {
                TextField(field.example, text: Binding(
                    get: { edits[field.id] ?? field.value },
                    set: { edits[field.id] = $0 }))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            }
        }
    }

    private func load() {
        fields = ConfigField.parse(example: AppModel.exampleConfig, live: Config.path)
        raw = raw
        text = (try? String(contentsOf: Config.path, encoding: .utf8)) ?? ""
        status = ""
    }

    private func save() {
        let path = Config.path
        let backup = path.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: path, to: backup)
        if raw {
            // Never write a file that does not parse: an invalid config would leave the daemon guessing.
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("apprentice-config-\(getpid()).toml")
            try? text.write(to: temp, atomically: true, encoding: .utf8)
            let parsed = Toml.load(temp)
            try? FileManager.default.removeItem(at: temp)
            guard !parsed.isEmpty, parsed["agent"] != nil || parsed["pace.default"] != nil else {
                status = "not saved: the TOML does not parse (a .bak of the old file is beside it)"
                return
            }
            try? text.write(to: path, atomically: true, encoding: .utf8)
        } else {
            for (key, value) in edits {
                guard let field = fields.first(where: { $0.id == key }) else { continue }
                let literal = field.literal(value)
                Toml.set(path, field.section, field.key, literal)
            }
        }
        Config.reloadIfChanged()
        status = "saved · the old file is at config.toml.bak"
        edits.removeAll()
        load()
        status = "saved · the old file is at config.toml.bak"
    }
}

/// One editable key, read from `agent/config.example.toml` (its comment is the help text) and valued from
/// the live `config.toml`.
struct ConfigField: Hashable {
    var section: String
    var key: String
    var comment: String
    var value: String
    var example: String

    var id: String { "\(section).\(key)" }

    func literal(_ v: String) -> String {
        let t = v.trimmingCharacters(in: .whitespaces)
        if t == "true" || t == "false" { return t }
        if t.hasPrefix("[") || t.hasPrefix("{") { return t }
        if Double(t) != nil { return t }
        return "\"" + t.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func parse(example: URL, live: URL) -> [ConfigField] {
        let exampleText = (try? String(contentsOf: example, encoding: .utf8))
            ?? (try? String(contentsOf: Store.dir.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        let liveTable = Config.loadTable(live)
        var out: [ConfigField] = []
        var section = ""
        var comment: [String] = []
        for raw in exampleText.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                comment.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
                continue
            }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                section = trimmed.dropFirst().dropLast().replacingOccurrences(of: "\"", with: "")
                comment = []
                continue
            }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // A commented-out example is still a real setting; show it with its default.
            let cleanKey = key
            guard !cleanKey.isEmpty, !cleanKey.hasPrefix("#") else { continue }
            let current = liveTable[section]?[cleanKey].map { _ in Config.loadedLiteral(section: section, key: cleanKey, raw: liveTable[section]?[cleanKey] ?? "") } ?? value
            out.append(ConfigField(section: section, key: cleanKey, comment: comment.suffix(3).joined(separator: " "),
                                   value: current, example: value))
            comment = []
        }
        return out
    }
}

extension Config {
    /// A raw table, for the form: the live values as written.
    static func loadTable(_ path: URL) -> [String: [String: String]] { Toml.load(path) }

    /// A value as the form shows it: unquoted for strings, as written for arrays, bools and numbers.
    static func loadedLiteral(section: String, key: String, raw: String) -> String {
        if raw.hasPrefix("[") || raw.hasPrefix("{") || raw == "true" || raw == "false" || Double(raw) != nil { return raw }
        return Toml.unquote(raw)
    }
}

// MARK: - Playbooks

struct PlaybooksView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var check = ""

    private var books: [Playbooks.Playbook] {
        let all = Playbooks.all()
        guard !query.isEmpty else { return all }
        let needle = query.lowercased()
        return all.filter { $0.path.lowercased().contains(needle) || $0.title.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search playbooks", text: $query).textFieldStyle(.roundedBorder)
                Button("Check for personal details") {
                    check = model.run("playbooks", ["--check"]).out
                }
                Button("Open folder") { NSWorkspace.shared.open(Playbooks.dir) }
            }
            .padding(10)
            Divider()
            List(books, id: \.path) { book in
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title).bold()
                    Text(book.path).font(.caption2).foregroundStyle(.secondary)
                    ForEach(book.keyFacts.prefix(3), id: \.self) { fact in
                        Text("• \(fact)").font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Button("Edit") { NSWorkspace.shared.open(book.url) }
                            .buttonStyle(.link).font(.caption2)
                        Button("Explain which flow a task picks") {
                            check = model.run("do", ["--explain", book.title]).out
                        }
                        .buttonStyle(.link).font(.caption2)
                    }
                }
                .padding(.vertical, 3)
            }
            if !check.isEmpty {
                Divider()
                TextEditor(text: .constant(check))
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 120)
            }
        }
    }
}

// MARK: - VMs

struct VMsView: View {
    @ObservedObject var model: AppModel
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("VMs").font(.title2.bold())
                Spacer()
                ForEach(["up", "down", "on", "off", "look", "status", "list"], id: \.self) { action in
                    Button(action) { text = model.run("vm", [action]).out }
                        .buttonStyle(.bordered)
                }
                Button("Shell tab") {
                    model.newTab(preset: "VM shell", command: "apprentice vm shell")
                }
            }
            .padding(10)
            Divider()
            TextEditor(text: .constant(text))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
        }
        .onAppear { text = model.run("vm", ["list"]).out }
    }
}

// MARK: - Updates and health

struct HealthView: View {
    @ObservedObject var model: AppModel
    @State private var checks = ""
    @State private var version = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Updates & health").font(.title2.bold())
                    Spacer()
                    Button("Check again") { load() }
                }
                GroupBox("Installed") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(version).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        if let install = Build.install {
                            Text("clone \(install.clone) · built \(install.built ?? "?")").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Update now") { checks = model.run("update", []).out }
                            Button("Check upstream") { checks = model.run("update", ["--check"]).out }
                            Button("Share my fixes") { checks = model.run("pr", ["--local"]).out }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                GroupBox("doctor") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(checks.isEmpty ? "…" : checks)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        HStack {
                            Button("Fix permissions") { _ = model.run("doctor", ["--fix"]) }
                            Button("Self-test") { checks = model.run("selftest", []).out }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                GroupBox("Bugs and todo") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(bugCount()) open items in BUGS.md · \(todoCount()) in TODO.md")
                        Button("Open BUGS.md") { NSWorkspace.shared.open(Repo.root.appendingPathComponent("BUGS.md")) }
                        Button("Open TODO.md") { NSWorkspace.shared.open(Repo.root.appendingPathComponent("TODO.md")) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }
            .padding(12)
        }
        .onAppear(perform: load)
    }

    private func load() {
        version = Build.version
        checks = model.run("doctor", []).out
    }

    private func bugCount() -> Int {
        ((try? String(contentsOf: Repo.root.appendingPathComponent("BUGS.md"), encoding: .utf8)) ?? "")
            .components(separatedBy: "\n").filter { $0.hasPrefix("- [") || $0.hasPrefix("## ") }.count
    }

    private func todoCount() -> Int {
        ((try? String(contentsOf: Repo.root.appendingPathComponent("TODO.md"), encoding: .utf8)) ?? "")
            .components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count
    }
}

// MARK: - Command palette

struct CommandPalette: View {
    @ObservedObject var model: AppModel
    @State private var output = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run an apprentice command").font(.headline)
            TextField("schedule list", text: $model.paletteText)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(run)
            Text("Same commands and exit codes as the CLI: every screen is a client of them.")
                .font(.caption2).foregroundStyle(.secondary)
            ScrollView {
                Text(output.isEmpty ? "output appears here" : output)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
            HStack {
                Spacer()
                Button("Close") { model.paletteOpen = false }
                Button("Run", action: run).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560)
    }

    private func run() {
        let words = model.paletteText.split(separator: " ").map(String.init)
        guard let cmd = words.first else { return }
        let result = model.run(cmd, Array(words.dropFirst()))
        output = (result.code == 0 ? "" : "exit \(result.code)\n") + result.out
        model.refresh()
    }
}
