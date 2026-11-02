import AppKit
import SwiftUI

/// `~/.apprentice/Apprentice.app`: the same binary in a real bundle, so the window opens from the Dock or
/// Spotlight, the menu-bar item can open it, and notifications carry apprentice's icon. `kit.sh` signs it
/// with the local identity, so the Accessibility and Screen Recording grants stay with it across rebuilds.
enum AppBundle {
    static let identifier = "com.apprentice.app"
    /// The release app in /Applications when that is what runs, else the bundle `kit.sh` builds.
    static var path: URL { Release.bundle ?? Store.dir.appendingPathComponent("Apprentice.app") }
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
        // A release app is signed as it shipped; only the bundle built here is signed here.
        if Release.bundle == nil { sign() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", path.path]
        return (try? p.run()) != nil
    }

    /// `apprentice app --install`, from kit.sh: builds the bundle and signs it, without opening a window.
    static func install() -> Int32 {
        guard Notify.appBundleExecutable() != nil else { return 1 }
        sign()
        return 0
    }


    /// Makes the bundle at `app` from the binary at `source`: the icon, Info.plist and an ad hoc signature
    /// (`sign` re-signs with an identity). `release` marks the DMG's bundle (`Release.bundle`).
    static func build(at app: URL, from source: String, release: Bool = false) -> Bool {
        let fm = FileManager.default
        let exe = app.appendingPathComponent("Contents/MacOS/apprentice")
        let res = app.appendingPathComponent("Contents/Resources")
        let iconset = fm.temporaryDirectory.appendingPathComponent("apprentice-\(getpid()).iconset")
        do {
            try? fm.removeItem(at: app)
            try fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: res, withIntermediateDirectories: true)
            try fm.copyItem(atPath: source, toPath: exe.path)
            try? fm.removeItem(at: iconset)
            try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
            for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                               ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                               ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                      let ctx = NSGraphicsContext(bitmapImageRep: rep) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = ctx
                Ask.icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
                NSGraphicsContext.restoreGraphicsState()
                try rep.representation(using: .png, properties: [:])?.write(to: iconset.appendingPathComponent(name + ".png"))
            }
            let util = Process()
            util.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
            util.arguments = ["-c", "icns", iconset.path, "-o", res.appendingPathComponent("AppIcon.icns").path]
            try util.run()
            util.waitUntilExit()
            try? fm.removeItem(at: iconset)
            // One bundle for everything: the window (`apprentice app`, opened from the Dock) and
            // notifications, so `UNUserNotificationCenter` works and the grants stay with the binary.
            let plist: [String: Any] = ["CFBundleIdentifier": AppBundle.identifier, "CFBundleName": "apprentice",
                                        "CFBundleDisplayName": "apprentice",
                                        "CFBundleExecutable": "apprentice", "CFBundleIconFile": "AppIcon", "CFBundlePackageType": "APPL",
                                        "CFBundleShortVersionString": Build.number, "CFBundleVersion": Build.number,
                                        "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": true,
                                        "LSUIElement": false, "ApprenticeRelease": release]
            try (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            // Hardened runtime, so no library can be injected into the one process whose clicks count as the user's.
            sign.arguments = ["--force", "--deep", "--options", "runtime", "-s", "-", app.path]
            sign.standardOutput = FileHandle.nullDevice
            sign.standardError = FileHandle.nullDevice
            try sign.run()
            sign.waitUntilExit()
            return sign.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Signs the bundle with the local identity where there is one, so its grants survive a rebuild.
    static func sign() {
        let identities = Repo.run("security", ["find-identity", "-p", "codesigning"]).out
        let identity = ProcessInfo.processInfo.environment["APPRENTICE_SIGN_IDENTITY"]
            ?? (identities.contains("\"apprentice\"") ? "apprentice" : "-")
        _ = Repo.run("codesign", ["--force", "--deep", "--options", "runtime", "-s", identity, path.path])
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
        app.appearance = nil
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
        NSApp.activate(ignoringOtherApps: true)
        let model = AppModel()
        let root = RootView(model: model)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "apprentice"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
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

// MARK: - Design system

/// One visual language for the window: the spacing scale, the corner radius, the card surface and the
/// section tints. Everything on screen uses these, so the nine screens read as one app rather than nine.
enum Theme {
    static let accent = Color(red: 0.32, green: 0.56, blue: 0.98)
    static let green = Color(red: 0.22, green: 0.66, blue: 0.42)
    static let orange = Color(red: 0.93, green: 0.55, blue: 0.16)
    static let red = Color(red: 0.86, green: 0.30, blue: 0.30)
    static let teal = Color(red: 0.17, green: 0.63, blue: 0.64)
    static let indigo = Color(red: 0.40, green: 0.42, blue: 0.86)
    static let plum = Color(red: 0.63, green: 0.36, blue: 0.74)
    static let slate = Color(red: 0.42, green: 0.47, blue: 0.56)

    /// 4-pt scale: 4, 8, 12, 16, 20, 24.
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 20
    static let s6: CGFloat = 24

    static let radius: CGFloat = 12
    static let radiusSmall: CGFloat = 8
    static let page = EdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24)

    static var canvas: Color { Color(nsColor: .windowBackgroundColor) }
    static var surface: Color { Color(nsColor: .controlBackgroundColor) }
    static var hairline: Color { Color.primary.opacity(0.08) }

    static func title(_ size: CGFloat = 20) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static var sectionTitle: Font { .system(size: 11, weight: .semibold, design: .rounded) }
    static var mono: Font { .system(size: 11.5, design: .monospaced) }
}

extension View {
    /// A raised surface: a material card with a hairline and a soft shadow, used for every group on screen.
    func card(_ padding: CGFloat = Theme.s3) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.hairline)
            )
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    func sectionLabel() -> some View {
        self.font(Theme.sectionTitle)
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

/// A rounded tile behind an SF Symbol, the app's one icon treatment.
struct IconTile: View {
    let symbol: String
    var tint: Color = Theme.accent
    var size: CGFloat = 30
    var solid = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(solid ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                    .fill(solid
                          ? AnyShapeStyle(LinearGradient(colors: [tint.opacity(0.92), tint], startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(tint.opacity(0.13)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                    .strokeBorder(tint.opacity(solid ? 0 : 0.18))
            )
            .accessibilityHidden(true)
    }
}

/// A small state chip: `on`, `paused`, `needs you`, a run result.
struct StatusPill: View {
    let text: String
    var tint: Color = Theme.slate
    var dot = true

    var body: some View {
        HStack(spacing: 4) {
            if dot {
                Circle().fill(tint).frame(width: 5, height: 5)
            }
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .foregroundStyle(tint)
        .background(Capsule().fill(tint.opacity(0.13)))
    }
}

/// A labelled value in a card: the small key above, its value below.
struct FieldRow: View {
    let label: String
    let value: String
    var mono = false
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).sectionLabel()
            Text(value)
                .font(mono ? Theme.mono : .callout)
                .foregroundStyle(tint ?? .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A titled group of rows inside a card, with the icon and tint of what it belongs to.
struct CardSection<Content: View>: View {
    let title: String
    let symbol: String
    var tint: Color = Theme.accent
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            HStack(spacing: Theme.s2) {
                IconTile(symbol: symbol, tint: tint, size: 22)
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
            }
            content()
        }
        .card(Theme.s4)
    }
}

/// The header every screen starts with: an icon, a title, one line of context, and the screen's actions.
struct ScreenHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    var tint: Color = Theme.accent
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: Theme.s3) {
            IconTile(symbol: icon, tint: tint, size: 38, solid: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.title(21))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.s3)
            actions()
        }
    }
}

extension ScreenHeader where Actions == EmptyView {
    init(title: String, subtitle: String = "", icon: String, tint: Color = Theme.accent) {
        self.init(title: title, subtitle: subtitle, icon: icon, tint: tint, actions: { EmptyView() })
    }
}

/// A page: the header, then its cards, on a soft wash of the section's tint at the top.
struct ScreenPage<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    var tint: Color = Theme.accent
    @ViewBuilder var actions: () -> AnyView
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [tint.opacity(0.10), tint.opacity(0.0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 150)
                .allowsHitTesting(false)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s4) {
                    ScreenHeader(title: title, subtitle: subtitle, icon: icon, tint: tint, actions: actions)
                    content()
                }
                .padding(Theme.page)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.canvas)
    }
}

// MARK: - Model

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
    /// A newer release for the DMG's app (`Release.available`), and how far its install has got.
    @Published var update: Release.Latest?
    @Published var updateStep = ""
    /// The GitHub account signed in on this Mac (`account.json`; the token stays in the Keychain).
    @Published var account: Account.Profile?

    let home = FileManager.default.homeDirectoryForCurrentUser

    init() {
        refresh()
        checkRelease()
        newTab(preset: "Shell", command: nil)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    // MARK: - reads

    func refresh() {
        let vms = (try? FileManager.default.contentsOfDirectory(atPath: Store.dir.appendingPathComponent("vms").path)) ?? []
        let pendingFiles: [(vm: String?, url: URL)] = [(nil, Store.url("pending.json"))]
            + vms.map { ($0, Store.dir.appendingPathComponent("vms/\($0)/pending.json")) }
        var found: [Approvals.Pending] = []
        var owners: [String: String] = [:]
        for (vm, file) in pendingFiles {
            guard let data = try? Data(contentsOf: file) else { continue }
            let list = (try? JSONDecoder().decode([Approvals.Pending].self, from: data))
                ?? (try? JSONDecoder().decode(Approvals.Pending.self, from: data)).map { [$0] } ?? []
            let now = Date().timeIntervalSince1970
            let open = list.filter { now < $0.expires }
            if let vm { for p in open { owners[p.token] = vm } }
            found += open
        }
        vmOf = owners
        pending = found.sorted { $0.at < $1.at }
        schedules = Schedules.all()
        awayTasks = Away.all()
        awayOn = Away.mode
        session = Session.stored
        update = Release.available
        account = Account.profile
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
        if !daemonUp { return "daemon stopped" }
        return busy ? "working" : "idle"
    }

    var statusTint: Color {
        if !pending.isEmpty { return Theme.orange }
        if !daemonUp { return Theme.slate }
        return busy ? Theme.accent : Theme.green
    }

    // MARK: - acts

    /// The file as it was before a form writes it: `<file>.bak`, replaced each time, so it is the last copy.
    static func backup(_ path: URL) {
        let bak = path.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: bak)
        try? FileManager.default.copyItem(at: path, to: bak)
    }

    /// The commands `main.swift` runs in the CLI process: the daemon does not know them, so the app runs
    /// the installed CLI for these instead of sending them over the socket.
    static let inClient: Set<String> = ["route", "playbooks", "notes", "prefs", "remember", "forget", "learn", "bug",
                                        "commit", "update", "settings", "repo", "policy", "budget", "activity", "flag",
                                        "grow", "sessions", "project", "doctor", "tour", "pr", "run", "replay", "vm",
                                        "phone", "selftest", "version", "account"]

    /// Every button: the same request the CLI sends, marked as the user's own. It blocks, so it never runs
    /// on the main thread: `run(_:_:then:)` and `act` call it from a background queue.
    private func send(_ cmd: String, _ args: [String]) -> (code: Int32, out: String) {
        if Self.inClient.contains(cmd) { return cli([cmd] + args) }
        guard let response = try? Wire.send(Request(cmd: cmd, args: args, user: true)) else {
            return (5, "daemon did not answer: run `apprentice serve` to see why")
        }
        return (response.code, response.out)
    }

    private func cli(_ argv: [String]) -> (code: Int32, out: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Wire.binaryPath())
        proc.arguments = argv
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() } catch { return (5, "could not run apprentice: \(error.localizedDescription)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Runs a command off the main thread and hands its result back on it, so a busy daemon never freezes
    /// the window.
    func run(_ cmd: String, _ args: [String] = [], then: @escaping (Int32, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let (code, out) = self.send(cmd, args)
            DispatchQueue.main.async { then(code, out) }
        }
    }

    func act(_ cmd: String, _ args: [String] = []) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let (code, out) = self.send(cmd, args)
            DispatchQueue.main.async {
                self.busy = false
                self.output = (code == 0 ? "" : "exit \(code): ") + out
                self.refresh()
            }
        }
    }

    // MARK: - release updates

    /// At launch: the release app's first-run set-up (CLI link, playbooks, agents) and a fresh look at the
    /// latest release; `force` skips the set-up and the six-hour cache.
    func checkRelease(force: Bool = false) {
        guard Release.isRelease else { return }
        DispatchQueue.global(qos: .utility).async {
            let notes = force ? [] : Release.setUp()
            let latest = Release.check(force: force)
            DispatchQueue.main.async {
                self.update = Release.available
                if !notes.isEmpty { self.output = notes.joined(separator: "\n") }
                if force { self.output = self.update.map { "apprentice \($0.version) is available" }
                    ?? (latest == nil ? "could not reach GitHub releases" : "up to date: \(Build.number) is the latest release") }
            }
        }
    }

    /// Downloads, verifies and swaps in the new app, stops the daemon (the next command starts the new one)
    /// and relaunches the window. Not while a step waits for approval.
    func installUpdate() {
        guard let latest = update, updateStep.isEmpty else { return }
        guard pending.isEmpty else { output = "answer the waiting approval first, then install the update"; return }
        updateStep = "starting…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try Release.install(latest) { step in DispatchQueue.main.async { self.updateStep = step } }
                _ = Wire.stopDaemon()
                DispatchQueue.main.async { self.relaunch() }
            } catch {
                let message = (error as? Fail)?.message ?? error.localizedDescription
                DispatchQueue.main.async { self.updateStep = ""; self.output = "update failed: " + message }
            }
        }
    }

    private func relaunch() {
        guard let bundle = Release.bundle else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", bundle.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// A VM's proposal is answered by that VM's daemon (`vms/<name>/pending.json`).
    func approve(_ p: Approvals.Pending) { answer("approve", p) }
    func deny(_ p: Approvals.Pending) { answer("deny", p) }

    private func answer(_ cmd: String, _ p: Approvals.Pending) {
        guard let vm = vmOf[p.token] else { return act(cmd, [p.token]) }
        // The user flag goes only to the Mac's socket; a VM daemon gets the same request with --vm.
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let req = Request(cmd: cmd, args: [p.token], user: true)
            let r = (try? Wire.send(req, vm: vm)).map { ($0.code, $0.out) } ?? (5, "the \(vm) daemon did not answer")
            DispatchQueue.main.async {
                self.busy = false
                self.output = (r.0 == 0 ? "" : "exit \(r.0): ") + r.1
                self.refresh()
            }
        }
    }

    /// Which VM each open proposal came from; the Mac's own are absent.
    private var vmOf: [String: String] = [:]

    /// Pause is the daemon's (`Pause.on` is a marker file it reads), so the window and the overlay agree.
    func togglePause() {
        Pause.on.toggle()
        output = Pause.on ? "paused: new actions wait" : "running"
        revision += 1
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

    static var exampleConfig: URL { Repo.resources.appendingPathComponent("agent/config.example.toml") }
}

// MARK: - Navigation

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
        case .schedules: return "clock.badge.checkmark"
        case .approvals: return "hand.raised"
        case .activity: return "waveform.path.ecg"
        case .sites: return "globe"
        case .settings: return "slider.horizontal.3"
        case .playbooks: return "book.closed"
        case .vms: return "desktopcomputer"
        case .health: return "heart.text.square"
        }
    }

    var tint: Color {
        switch self {
        case .terminal: return Theme.accent
        case .schedules: return Theme.indigo
        case .approvals: return Theme.orange
        case .activity: return Theme.teal
        case .sites: return Theme.green
        case .settings: return Theme.slate
        case .playbooks: return Theme.plum
        case .vms: return Theme.teal
        case .health: return Theme.red
        }
    }

    var subtitle: String {
        switch self {
        case .terminal: return "Run agents and shells in tabs, with apprentice already wired in"
        case .schedules: return "Prompts, runs and flows later or again"
        case .approvals: return "Everything waiting on you, from every daemon"
        case .activity: return "What is happening now, and what was learned"
        case .sites: return "Pace, quiet hours, budgets and policy notes per site"
        case .settings: return "config.toml, projects, routes and the phone"
        case .playbooks: return "What was learned about apps, sites and flows"
        case .vms: return "The browser VMs and their screens"
        case .health: return "Updates, permissions and the clone"
        }
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 188, ideal: 206, max: 250)
        } detail: {
            detail
                .frame(minWidth: 660, minHeight: 460)
                .safeAreaInset(edge: .top) {
                    if let latest = model.update { UpdateBanner(model: model, latest: latest) }
                }
                .toolbar { toolbar }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Theme.accent)
        .sheet(isPresented: $model.paletteOpen) {
            CommandPalette(model: model)
        }
        .background(shortcuts)
        .onAppear { model.refresh() }
    }

    private var sidebar: some View {
        List(Section.allCases, selection: Binding(
            get: { model.section },
            set: { if let s = $0 { model.section = s } })) { section in
            HStack(spacing: Theme.s2 + 2) {
                IconTile(symbol: section.symbol, tint: section.tint, size: 24,
                         solid: section == model.section)
                Text(section.rawValue)
                    .font(.system(size: 12.5, weight: section == model.section ? .semibold : .regular))
                Spacer(minLength: 0)
                if section == .approvals, !model.pending.isEmpty {
                    Text("\(model.pending.count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Theme.orange))
                }
            }
            .padding(.vertical, 1)
            .tag(section)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top) {
            VStack(alignment: .leading, spacing: Theme.s3) {
                HStack(spacing: Theme.s2) {
                    IconTile(symbol: "hand.point.up.left", tint: Theme.accent, size: 26, solid: true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("apprentice").font(.system(size: 13, weight: .bold, design: .rounded))
                        Text("v\(Build.version)").font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Divider()
            }
            .padding(.horizontal, Theme.s3)
            .padding(.top, Theme.s2)
            .background(.thinMaterial)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.s2) {
                Divider()
                HStack(spacing: Theme.s2) {
                    StatusPill(text: model.status, tint: model.statusTint)
                    if model.awayOn { StatusPill(text: "away", tint: Theme.teal) }
                    if Pause.on { StatusPill(text: "paused", tint: Theme.orange) }
                }
                if let account = model.account {
                    Button { model.section = .settings } label: {
                        Label("@\(account.login)", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Signed in to GitHub · Settings ▸ GitHub account")
                }
                Text("kill switch  ⌃⌥⌘.")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.s3)
            .padding(.bottom, Theme.s2)
            .background(.thinMaterial)
        }
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
            HStack(spacing: Theme.s2) {
                StatusPill(text: model.status, tint: model.statusTint)
                if let session = model.session, let url = session.url, let host = URL(string: url)?.host {
                    Text(host)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
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
            Divider().opacity(0.6)
            if let session = model.selectedSession {
                ZStack(alignment: .bottom) {
                    TerminalPane(term: session, font: font, locked: pendingForSelected != nil)
                        .id(session.id)
                        .padding(Theme.s3)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                                .fill(Theme.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                                .strokeBorder(Theme.hairline)
                        )
                        .padding(.horizontal, Theme.s4)
                        .padding(.bottom, Theme.s2)
                    if let pending = pendingForSelected {
                        ApprovalBanner(model: model, pending: pending)
                            .padding(.horizontal, Theme.s4)
                            .padding(.bottom, Theme.s4)
                    }
                }
                footer(session)
            } else {
                ContentUnavailableView {
                    Label("No tab", systemImage: "apple.terminal")
                } description: {
                    Text("⌘T opens a shell; the + menu has Claude Code, Codex and your presets")
                }
            }
        }
        .background(Theme.canvas)
    }

    private var font: NSFont {
        NSFont(name: Config.current.appFont, size: Config.current.appFontSize)
            ?? NSFont.monospacedSystemFont(ofSize: Config.current.appFontSize, weight: .regular)
    }

    private var tabBar: some View {
        HStack(spacing: Theme.s2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.tabs) { tab in
                        TabChip(tab: tab, selected: tab.id == model.selectedTab,
                                close: { model.closeTab(tab.id) },
                                select: { model.selectedTab = tab.id })
                    }
                }
                .padding(.horizontal, Theme.s4)
                .padding(.vertical, Theme.s2 + 2)
            }
            Menu {
                Button { model.newTab(preset: "Shell", command: nil) } label: {
                    Label("Shell", systemImage: "apple.terminal")
                }
                Button { model.newTab(preset: "Claude Code", command: "claude") } label: {
                    Label("Claude Code", systemImage: "sparkles")
                }
                Button { model.newTab(preset: "Codex", command: "codex") } label: {
                    Label("Codex", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Button { model.newTab(preset: "opencode", command: "opencode") } label: {
                    Label("opencode", systemImage: "curlybraces")
                }
                Button { model.newTab(preset: "Kilo", command: "kilo") } label: {
                    Label("Kilo", systemImage: "k.circle")
                }
                Button { model.openLogTab() } label: {
                    Label("Log (following)", systemImage: "list.bullet.rectangle")
                }
                if !Config.current.tabPresets.isEmpty {
                    Divider()
                    ForEach(Config.current.tabPresets.keys.sorted(), id: \.self) { name in
                        Button(name) { model.newTab(preset: name, command: nil) }
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.accent.opacity(0.12)))
                    .foregroundStyle(Theme.accent)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New tab (⌘T)")
            .padding(.trailing, Theme.s4)
        }
        .background(.bar)
    }

    private func footer(_ session: TermSession) -> some View {
        HStack(spacing: Theme.s3) {
            Label(session.title, systemImage: "terminal")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            if !session.subtitle.isEmpty {
                Text(session.subtitle).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            Spacer()
            if let bound = model.session {
                StatusPill(text: bound.app, tint: Theme.slate)
                if let dir = Project.dir?.deletingLastPathComponent().lastPathComponent {
                    StatusPill(text: "project \(dir)", tint: Theme.plum)
                }
                StatusPill(text: "model \(Config.current.runModel)", tint: Theme.indigo)
            } else {
                StatusPill(text: "no bound app session", tint: Theme.slate)
            }
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s2)
        .background(.bar)
    }
}

private struct TabChip: View {
    @ObservedObject var tab: TermSession
    let selected: Bool
    let close: () -> Void
    let select: () -> Void
    @State private var hovering = false

    private var symbol: String {
        switch tab.title.lowercased() {
        case let t where t.contains("claude"): return "sparkles"
        case let t where t.contains("codex"): return "chevron.left.forwardslash.chevron.right"
        case let t where t.contains("log"): return "list.bullet.rectangle"
        case let t where t.contains("vm"): return "desktopcomputer"
        default: return "apple.terminal"
        }
    }

    private var tint: Color {
        tab.hasApproval ? Theme.orange : (tab.exited == nil ? (selected ? Theme.accent : Theme.slate) : Theme.red)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(tab.title)
                .font(.system(size: 11, weight: selected ? .semibold : .medium, design: .rounded))
                .lineLimit(1)
            if tab.hasApproval {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.orange)
            } else if let code = tab.exited {
                Text("\(code)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(code == 0 ? .secondary : Theme.red)
            }
            if hovering || selected {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help("Close tab (⌘W)")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.14) : (hovering ? Color.primary.opacity(0.06) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .strokeBorder(selected ? Theme.accent.opacity(0.35) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(tab.subtitle.isEmpty ? tab.title : tab.subtitle)
    }
}

struct ApprovalBanner: View {
    @ObservedObject var model: AppModel
    let pending: Approvals.Pending

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            HStack(alignment: .top, spacing: Theme.s2) {
                IconTile(symbol: "exclamationmark.triangle.fill", tint: Theme.orange, size: 26, solid: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Needs your approval")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.orange)
                        .textCase(.uppercase)
                    Text(pending.summary)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            if let warnings = pending.warnings, !warnings.isEmpty {
                FlowChips(items: warnings.map { "⚠ \($0)" }, tint: Theme.orange)
            }
            // No default key: Allow takes a click, so a stray Return (or a script's keystroke) never approves.
            HStack(spacing: Theme.s2) {
                Spacer()
                Button("Deny", role: .destructive) { model.deny(pending) }
                    .controlSize(.small)
                Button { model.approve(pending) } label: {
                    Label("Allow", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.orange)
                .controlSize(.small)
            }
            Text("Same as `apprentice approve \(pending.token)` · tab \(pending.tab ?? "—") · expires \(Date(timeIntervalSince1970: pending.expires).formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(Theme.s3 + 2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.orange.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 14, y: 4)
    }
}

/// Chips that wrap onto more than one line, for warnings and tags.
struct FlowChips: View {
    let items: [String]
    var tint: Color = Theme.slate

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { index in
                HStack(spacing: 4) {
                    ForEach(items[index..<min(index + 2, items.count)], id: \.self) { item in
                        Text(item)
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundStyle(tint)
                            .background(Capsule().fill(tint.opacity(0.12)))
                    }
                }
            }
        }
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
            VStack(spacing: 0) {
                HStack {
                    Text("\(model.schedules.count) schedule\(model.schedules.count == 1 ? "" : "s")")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        adding = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, Theme.s3)
                .padding(.vertical, Theme.s2 + 2)
                Divider()
                if model.schedules.isEmpty {
                    ContentUnavailableView {
                        Label("No schedules", systemImage: "clock")
                    } description: {
                        Text("Run a prompt, a task or a flow later or again")
                    }
                } else {
                    List(selection: $selected) {
                        ForEach(model.schedules) { schedule in
                            ScheduleRow(schedule: schedule)
                                .tag(schedule.id)
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(minWidth: 250, idealWidth: 285)

            Group {
                if let id = selected, let schedule = model.schedules.first(where: { $0.id == id }) {
                    ScheduleDetail(model: model, schedule: schedule)
                } else {
                    ScreenPage(title: "Schedules",
                         subtitle: "Prompts, `apprentice run` tasks and playbook flows that run later or again: the daemon owns the timer, so they fire with nothing else open.",
                         icon: "clock.badge.checkmark", tint: Theme.indigo) {
                        AnyView(
                            HStack(spacing: Theme.s2) {
                                Button {
                                    adding = true
                                } label: { Label("New schedule", systemImage: "plus") }
                                    .buttonStyle(.borderedProminent)
                                Button {
                                    model.act("schedule", ["agent", "on"])
                                } label: { Label("Start at login", systemImage: "power") }
                            }
                        )
                    } content: {
                        HStack(spacing: Theme.s3) {
                            FeatureCard(symbol: "sparkles", tint: Theme.plum, title: "An agent prompt",
                                        detail: "`claude -p \"…\"` or `codex exec \"…\"` in a folder")
                            FeatureCard(symbol: "play.circle", tint: Theme.accent, title: "A run",
                                        detail: "`apprentice run \"task\"` with its model")
                            FeatureCard(symbol: "book.closed", tint: Theme.green, title: "A flow",
                                        detail: "`apprentice do <flow>` with its plan")
                        }
                    }
                }
            }
            .frame(minWidth: 420)
        }
        .background(Theme.canvas)
        .sheet(isPresented: $adding) {
            ScheduleEditor(model: model, existing: nil) { adding = false }
        }
    }
}

struct FeatureCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            IconTile(symbol: symbol, tint: tint, size: 28)
            Text(title).font(.system(size: 12.5, weight: .semibold, design: .rounded))
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card(Theme.s3)
    }
}

private struct ScheduleRow: View {
    let schedule: Schedules.Schedule

    private var tint: Color {
        switch schedule.kind {
        case .prompt: return Theme.plum
        case .run: return Theme.accent
        case .flow: return Theme.green
        case .sh: return Theme.slate
        }
    }

    private var symbol: String {
        switch schedule.kind {
        case .prompt: return "sparkles"
        case .run: return "play.circle"
        case .flow: return "book.closed"
        case .sh: return "terminal"
        }
    }

    var body: some View {
        HStack(spacing: Theme.s2 + 2) {
            IconTile(symbol: symbol, tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(schedule.name)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    if !schedule.enabled { StatusPill(text: "paused", tint: Theme.slate, dot: false) }
                }
                Text(schedule.when_ + (schedule.jitter > 0 ? "  ±\(schedule.jitter)m" : ""))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let next = schedule.next, schedule.enabled {
                    Text("next \(next.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(tint)
                } else if let result = schedule.lastResult {
                    Text(result).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

struct ScheduleDetail: View {
    @ObservedObject var model: AppModel
    let schedule: Schedules.Schedule
    @State private var editing = false
    @State private var runs: [(name: String, url: URL)] = []

    private var tint: Color {
        switch schedule.kind {
        case .prompt: return Theme.plum
        case .run: return Theme.accent
        case .flow: return Theme.green
        case .sh: return Theme.slate
        }
    }

    var body: some View {
        ScreenPage(title: schedule.name,
             subtitle: "\(schedule.kind.label) · \(schedule.when_)" + (schedule.jitter > 0 ? " ±\(schedule.jitter) min" : ""),
             icon: schedule.kind == .flow ? "book.closed" : schedule.kind == .prompt ? "sparkles" : "clock.badge.checkmark",
             tint: tint) {
            AnyView(
                HStack(spacing: Theme.s2) {
                    Toggle("Enabled", isOn: Binding(get: { schedule.enabled }, set: { on in
                        model.act("schedule", [on ? "resume" : "pause", schedule.id])
                    }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    Button { model.act("schedule", ["now", schedule.id]) } label: {
                        Label("Run now", systemImage: "play.fill")
                    }
                    .controlSize(.small)
                    Button { editing = true } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .controlSize(.small)
                    Button(role: .destructive) {
                        model.act("schedule", ["rm", schedule.id])
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .controlSize(.small)
                }
            )
        } content: {
            HStack(alignment: .top, spacing: Theme.s3) {
                CardSection(title: "What runs", symbol: "text.bubble", tint: tint) {
                    FieldRow(label: schedule.kind.label, value: schedule.target, mono: true)
                    if let dir = schedule.dir {
                        FieldRow(label: "Folder", value: dir, mono: true, tint: .secondary)
                    }
                    if let vm = schedule.vm {
                        FieldRow(label: "VM", value: vm, mono: true, tint: .secondary)
                    }
                }
                CardSection(title: "Next run", symbol: "clock", tint: tint) {
                    if let next = schedule.next, schedule.enabled {
                        HStack(spacing: Theme.s2) {
                            Image(systemName: "arrow.forward.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(tint)
                            Text(next.formatted(date: .complete, time: .shortened))
                                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        }
                    } else {
                        Text(schedule.enabled ? "not scheduled" : "paused")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if Schedules.quietHours(schedule).from >= 0 {
                        Text("quiet hours \(Int(Schedules.quietHours(schedule).from)):00–\(Int(Schedules.quietHours(schedule).to) % 24):00; a run there moves to the end")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    if let result = schedule.lastResult {
                        StatusPill(text: "last: \(result)", tint: result.hasPrefix("ok") ? Theme.green : Theme.orange)
                    }
                }
            }
            CardSection(title: "Next five runs", symbol: "calendar", tint: tint) {
                let preview = Schedules.preview(schedule)
                if preview.isEmpty {
                    Text("nothing ahead").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(preview.enumerated()), id: \.offset) { index, date in
                        HStack(spacing: Theme.s2) {
                            Circle()
                                .fill(tint.opacity(index == 0 ? 1 : 0.35))
                                .frame(width: 6, height: 6)
                            Text(date.formatted(date: .abbreviated, time: .standard))
                                .font(Theme.mono)
                                .foregroundStyle(index == 0 ? .primary : .secondary)
                            Spacer()
                            if index == 0 { StatusPill(text: "next", tint: tint) }
                        }
                    }
                }
            }
            CardSection(title: "Runs", symbol: "doc.text", tint: Theme.slate) {
                if runs.isEmpty {
                    Text("no runs yet").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(runs, id: \.name) { run in
                        Button {
                            NSWorkspace.shared.open(run.url)
                        } label: {
                            HStack(spacing: Theme.s2) {
                                Image(systemName: "doc.text").foregroundStyle(Theme.slate)
                                Text(run.name).font(Theme.mono)
                                Spacer()
                                Image(systemName: "arrow.up.forward.app").foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
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
        VStack(alignment: .leading, spacing: Theme.s4) {
            HStack(spacing: Theme.s2) {
                IconTile(symbol: "clock.badge.checkmark", tint: Theme.indigo, size: 30, solid: true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(existing == nil ? "New schedule" : "Edit schedule")
                        .font(Theme.title(17))
                    Text("It runs through the same commands, budgets and gate as anything else")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s3) {
                    CardSection(title: "What", symbol: "text.bubble", tint: Theme.accent) {
                        LabeledField("Name") { TextField("say what it does", text: $name) }
                        LabeledField("Runs") {
                            Picker("", selection: $kind) {
                                Text("an agent CLI prompt").tag("prompt")
                                Text("apprentice run").tag("run")
                                Text("a playbook flow").tag("do")
                                Text("a shell command").tag("sh")
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                        if kind == "prompt" {
                            LabeledField("Agent CLI") { TextField("claude, codex, opencode…", text: $agent) }
                        }
                        LabeledField(kind == "prompt" ? "Prompt" : kind == "run" ? "Task" : kind == "do" ? "Flow" : "Command") {
                            TextField("what should it do", text: $target)
                                .font(Theme.mono)
                        }
                    }
                    CardSection(title: "When", symbol: "calendar.badge.clock", tint: Theme.indigo) {
                        LabeledField("Repeat") {
                            Picker("", selection: $trigger) {
                                Text("once, at a date and time").tag("at")
                                Text("every N minutes").tag("every")
                                Text("daily").tag("daily")
                                Text("on chosen weekdays").tag("weekly")
                                Text("a cron line").tag("cron")
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                        switch trigger {
                        case "at": LabeledField("At") { TextField("2026-11-05T09:00:00", text: $at) }
                        case "every": LabeledField("Minutes") { TextField("60", text: $every) }
                        case "daily": LabeledField("Time") { TextField("09:00", text: $daily) }
                        case "weekly": LabeledField("Days and time") { TextField("mon,wed 09:00", text: $weekly) }
                        default: LabeledField("Cron") { TextField("0 9 * * 1-5", text: $cron).font(Theme.mono) }
                        }
                        LabeledField("Jitter") { TextField("± minutes", text: $jitter) }
                    }
                    CardSection(title: "Where", symbol: "folder", tint: Theme.slate) {
                        LabeledField("Folder") { TextField("empty: home", text: $dir) }
                        LabeledField("VM") { TextField("empty: this Mac", text: $vm) }
                        LabeledField("Model") { TextField("empty: the agent's own", text: $model_) }
                        LabeledField("Site quiet hours") { TextField("optional domain", text: $site) }
                    }
                }
            }
            .frame(maxHeight: 420)
            HStack {
                Text("Adding or changing one from an agent needs your approval; here it is yours.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { done() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.s5)
        .frame(width: 560)
        .background(Theme.canvas)
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

/// A form row: a label of fixed width, then the control, so every sheet lines up.
struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.s3) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .trailing)
            content()
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Approvals

extension Approvals.Pending: Identifiable {
    public var id: String { token }
}

struct ApprovalsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScreenPage(title: "Waiting on you",
             subtitle: model.pending.isEmpty
                ? "Nothing needs you. Pending ⚠ steps from every daemon and open questions appear here."
                : "\(model.pending.count) step\(model.pending.count == 1 ? "" : "s") from every daemon, in one list.",
             icon: "hand.raised.fill", tint: Theme.orange) {
            AnyView(
                Button { model.refresh() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            )
        } content: {
            if model.pending.isEmpty {
                VStack(spacing: Theme.s3) {
                    IconTile(symbol: "checkmark.seal.fill", tint: Theme.green, size: 44, solid: true)
                    Text("Nothing needs you").font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text("An agent's ⚠ step, a question, or a challenge waiting for a check shows up here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.s6)
                .card(Theme.s5)
            } else {
                ForEach(model.pending) { pending in
                    ApprovalCard(model: model, pending: pending)
                }
            }
        }
    }
}

private struct ApprovalCard: View {
    @ObservedObject var model: AppModel
    let pending: Approvals.Pending

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            HStack(alignment: .top, spacing: Theme.s3) {
                IconTile(symbol: "exclamationmark.triangle.fill", tint: Theme.orange, size: 28, solid: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pending.summary)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(pending.cmd) · tab \(pending.tab ?? "—") · \(Date(timeIntervalSince1970: pending.at).formatted(date: .omitted, time: .standard))")
                        .font(Theme.mono)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                StatusPill(text: pending.token, tint: Theme.slate, dot: false)
            }
            if let warnings = pending.warnings, !warnings.isEmpty {
                FlowChips(items: warnings.map { "⚠ \($0)" }, tint: Theme.orange)
            }
            HStack {
                Spacer()
                Button("Deny", role: .destructive) { model.deny(pending) }
                    .controlSize(.small)
                Button { model.approve(pending) } label: {
                    Label("Allow", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.orange)
                .controlSize(.small)
            }
        }
        .card(Theme.s4)
    }
}

// MARK: - Activity

struct ActivityView: View {
    @ObservedObject var model: AppModel
    @State private var part = 0
    @State private var text = ""

    private var tint: Color { [Theme.teal, Theme.plum, Theme.accent, Theme.orange][min(part, 3)] }

    var body: some View {
        ScreenPage(title: "Activity",
             subtitle: "What each daemon is doing now, what was learned, and what happened on a site.",
             icon: "waveform.path.ecg", tint: Theme.teal) {
            AnyView(
                HStack(spacing: Theme.s2) {
                    Button { load() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .controlSize(.small)
                    Button {
                        model.newTab(preset: "Claude Code", command: "claude")
                    } label: {
                        Label("Work on this", systemImage: "sparkles")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            )
        } content: {
            HStack(spacing: Theme.s2) {
                ForEach(Array(["Now", "Grow", "Sessions", "Events"].enumerated()), id: \.offset) { index, title in
                    Button {
                        part = index
                        load()
                    } label: {
                        Text(title)
                            .font(.system(size: 11, weight: part == index ? .semibold : .regular, design: .rounded))
                            .padding(.horizontal, Theme.s3)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(part == index ? tint.opacity(0.16) : Color.primary.opacity(0.05))
                            )
                            .foregroundStyle(part == index ? tint : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            CardSection(title: part == 0 ? "Now" : part == 1 ? "Growth" : part == 2 ? "Sessions" : "Events",
                        symbol: part == 0 ? "dot.radiowaves.left.and.right" : part == 1 ? "chart.line.uptrend.xyaxis" : part == 2 ? "list.bullet.rectangle" : "bolt",
                        tint: tint) {
                Text(text.isEmpty ? "…" : text)
                    .font(Theme.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        switch part {
        case 0:
            let s = model.session
            let sessionLine: String = s.map { (s: Session) -> String in
                "session \(s.id ?? "-") · \(s.app) · window \(s.wid)" + (s.url.map { " · \($0)" } ?? "")
            } ?? "no session bound"
            let bits: [String] = [
                "daemon: \(model.daemonUp ? "running" : "not running") · \(model.status)",
                sessionLine,
                "pending approvals: \(model.pending.count)",
                "away: \(model.awayOn ? "on" : "off") · queued \(model.awayTasks.filter { $0.state == .queued }.count)",
            ]
            text = bits.joined(separator: "\n")
            model.run("budget") { _, budget in
                model.run("cool") { _, cool in text = (bits + ["", budget, "", cool]).joined(separator: "\n") }
            }
        case 1: text = "…"; model.run("grow", ["--days", "14"]) { _, out in text = out }
        case 2: text = "…"; model.run("sessions", ["--limit", "25"]) { _, out in text = out }
        default:
            let host = model.session?.url.flatMap { URL(string: $0)?.host } ?? ""
            if host.isEmpty { text = "open a session to see one site's events" }
            else { text = "…"; model.run("activity", [host, "--days", "14"]) { _, out in text = out } }
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
            VStack(spacing: 0) {
                HStack {
                    Text("\(sites.count) site\(sites.count == 1 ? "" : "s")")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { wizard = true } label: { Label("New", systemImage: "plus") }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, Theme.s3)
                .padding(.vertical, Theme.s2 + 2)
                Divider()
                List(selection: $site) {
                    ForEach(sites, id: \.self) { name in
                        HStack(spacing: Theme.s2) {
                            IconTile(symbol: icon(for: name), tint: tint(for: name), size: 22)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(name).font(.system(size: 11.5, weight: .medium, design: .rounded))
                                if Config.socialSites.contains(name) {
                                    Text("careful").font(.system(size: 9)).foregroundStyle(Theme.orange)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .tag(name)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .frame(minWidth: 220, idealWidth: 250)
            .onChange(of: site) { _, _ in load() }

            Group {
                if site.isEmpty {
                    ScreenPage(title: "Sites", subtitle: "Choose a site for its pace, quiet hours, budgets, policy notes and any cooldown or challenge.", icon: "globe", tint: Theme.green) {
                        AnyView(EmptyView())
                    } content: {
                        HStack(spacing: Theme.s3) {
                            FeatureCard(symbol: "timer", tint: Theme.indigo, title: "Pace",
                                        detail: "Timing, quiet hours, a sitting's length and a daily cap")
                            FeatureCard(symbol: "chart.bar", tint: Theme.green, title: "Budgets",
                                        detail: "What is left today and this hour, per action")
                            FeatureCard(symbol: "checkmark.shield", tint: Theme.orange, title: "Cooldowns",
                                        detail: "A rate limit or a challenge, and clearing it once checked")
                        }
                    }
                } else {
                    ScreenPage(title: site,
                         subtitle: Config.socialSites.contains(site) ? "A social site: the careful style and a person's day apply" : "Pace, budgets and notes for this site",
                         icon: "globe", tint: tint(for: site)) {
                        AnyView(
                            Button { model.act("cool", ["--clear", site]) } label: {
                                Label("I checked it", systemImage: "checkmark.shield")
                            }
                            .controlSize(.small)
                        )
                    } content: {
                        CardSection(title: "Pace", symbol: "timer", tint: Theme.indigo) {
                            LabeledField("Quiet hours") { TextField("2,6 (empty: none)", text: $quiet) }
                            LabeledField("Actions per day") { TextField("empty: off", text: $perDay) }
                            LabeledField("Sitting, minutes") { TextField("empty: off", text: $sitting) }
                            HStack {
                                Spacer()
                                Button("Save to config.toml") { savePace() }
                                    .controlSize(.small)
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        CardSection(title: "What is left today", symbol: "chart.bar", tint: Theme.green) {
                            Text(usage.isEmpty ? "…" : usage)
                                .font(Theme.mono)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        CardSection(title: "Policy notes", symbol: "text.quote", tint: Theme.slate) {
                            TextField("what the site's terms allow", text: $note, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(2...5)
                                .font(.callout)
                            HStack {
                                Text("Shown with the site's hints; never used to refuse it.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Save to routes.toml") { saveNote() }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 420)
        }
        .background(Theme.canvas)
        .sheet(isPresented: $wizard) {
            NewSiteWizard(model: model) { wizard = false }
        }
        .onAppear(perform: load)
    }

    private func icon(for site: String) -> String {
        if Config.socialSites.contains(site) { return "person.2" }
        return "globe"
    }

    private func tint(for site: String) -> Color {
        Config.socialSites.contains(site) ? Theme.orange : Theme.green
    }

    private func load() {
        guard !site.isEmpty else { return }
        model.run("budget", [site]) { _, out in usage = out }
        let pace = Config.current.profiles[site] ?? Config.current.defaultPace
        quiet = pace.quietFrom >= 0 ? "\(Int(pace.quietFrom)),\(Int(pace.quietTo))" : ""
        perDay = pace.actionsPerDay > 0 ? "\(Int(pace.actionsPerDay))" : ""
        sitting = pace.sittingMax > 0 ? "\(Int(pace.sittingMax))" : ""
        note = Policies.find(site)?.notes ?? ""
    }

    private func savePace() {
        let path = Config.path
        AppModel.backup(path)
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
        AppModel.backup(path)
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
        VStack(alignment: .leading, spacing: Theme.s4) {
            HStack(spacing: Theme.s2) {
                IconTile(symbol: "globe.badge.chevron.backward", tint: Theme.green, size: 30, solid: true)
                Text("New site").font(Theme.title(17))
            }
            CardSection(title: "The site", symbol: "globe", tint: Theme.green) {
                LabeledField("Domain") { TextField("example.com", text: $domain) }
                LabeledField("Pace") {
                    HStack {
                        Text(style).font(.callout.weight(.medium))
                        Text(style == "careful" ? "· a social site" : "· a web page")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledField("Quiet hours") { TextField("2,6", text: $quiet) }
                LabeledField("Actions per day") { TextField("400", text: $perDay) }
            }
            Text("Adds [pace.\"\(domain)\"] to config.toml, with the \(style) style as its base.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { done() }
                Button("Add") {
                    let path = Config.path
                    AppModel.backup(path)
                    let section = "pace.\"\(domain)\""
                    Toml.set(path, section, "style", "\"\(style)\"")
                    let parts = quiet.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    if parts.count == 2 { Toml.set(path, section, "quiet_hours", "[\(parts[0]), \(parts[1])]") }
                    Toml.set(path, section, "actions_per_day", perDay)
                    Config.reloadIfChanged()
                    done()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(domain.isEmpty)
            }
        }
        .padding(Theme.s5)
        .frame(width: 480)
        .background(Theme.canvas)
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
    @State private var projects = "…"

    private func icon(for section: String) -> String {
        switch section {
        case "agent": return "person.crop.circle"
        case "run": return "cpu"
        case "sites": return "globe"
        case "gate": return "hand.raised"
        case "session": return "rectangle.on.rectangle"
        case "update": return "arrow.triangle.2.circlepath"
        case "storage": return "externaldrive"
        case "schedules": return "clock"
        case "away": return "moon"
        case "app": return "macwindow"
        default: return section.hasPrefix("pace") ? "timer" : "gearshape"
        }
    }

    var body: some View {
        ScreenPage(title: "Settings",
             subtitle: "config.toml, written the way you wrote it: the form edits a key in place, and the raw view never overwrites a file that does not parse.",
             icon: "slider.horizontal.3", tint: Theme.slate) {
            AnyView(
                HStack(spacing: Theme.s2) {
                    Picker("", selection: $raw) {
                        Text("Form").tag(false)
                        Text("Raw TOML").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                    Button {
                        NSWorkspace.shared.selectFile(Config.path.path, inFileViewerRootedAtPath: Settings.dir.path)
                    } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                    .controlSize(.small)
                }
            )
        } content: {
            AccountCard(model: model)
            if raw {
                CardSection(title: "config.toml", symbol: "doc.plaintext", tint: Theme.slate) {
                    TextEditor(text: $text)
                        .font(Theme.mono)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 420)
                        .padding(Theme.s2)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                }
            } else {
                ForEach(sections, id: \.self) { section in
                    CardSection(title: section.isEmpty ? "top" : section, symbol: icon(for: section),
                                tint: section.hasPrefix("pace") ? Theme.indigo : Theme.accent) {
                        ForEach(fields.filter { $0.section == section }, id: \.self) { field in
                            SettingFieldRow(field: field, value: Binding(
                                get: { edits[field.id] ?? field.value },
                                set: { edits[field.id] = $0 }))
                        }
                    }
                }
                CardSection(title: "Projects, routes and phone", symbol: "point.3.connected.trianglepath.dotted", tint: Theme.teal) {
                    FieldRow(label: "Projects", value: projects)
                        .onAppear { model.run("project", ["status"]) { _, out in projects = out } }
                    HStack(spacing: Theme.s2) {
                        Button {
                            NSWorkspace.shared.open(Settings.dir.appendingPathComponent("routes.toml"))
                        } label: { Label("Routes", systemImage: "arrow.triangle.branch") }
                        Button { model.act("phone", []) } label: { Label("Phone setup", systemImage: "iphone.radiowaves.left.and.right") }
                        Spacer()
                    }
                    .controlSize(.small)
                }
            }
            HStack(spacing: Theme.s2) {
                if !status.isEmpty {
                    StatusPill(text: status, tint: status.hasPrefix("not saved") ? Theme.red : Theme.green)
                }
                Text(Config.path.path)
                    .font(Theme.mono)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(raw ? "Save raw TOML" : "Save changes") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.top, Theme.s1)
        }
        .onAppear(perform: load)
        .onChange(of: raw) { _, _ in load() }
    }

    private var sections: [String] {
        var seen: [String] = []
        for field in fields where !seen.contains(field.section) { seen.append(field.section) }
        return seen
    }

    private func load() {
        fields = ConfigField.parse(example: AppModel.exampleConfig, live: Config.path)
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
            let problems = Toml.problems(text)
            guard problems.isEmpty else {
                status = "not saved: " + problems.prefix(3).joined(separator: "; ")
                return
            }
            try? text.write(to: path, atomically: true, encoding: .utf8)
        } else {
            for (key, value) in edits {
                guard let field = fields.first(where: { $0.id == key }) else { continue }
                Toml.set(path, field.header.isEmpty ? field.section : field.header, field.key, field.literal(value))
            }
        }
        Config.reloadIfChanged()
        edits.removeAll()
        load()
        status = "saved · a .bak is beside it"
    }
}

/// The GitHub account on this Mac. Every button runs `account`, as a script would: `login --start` for the
/// code, `login --wait` until it is entered on GitHub, `--cancel`, `status` and `logout`. The token never
/// reaches the window, only the login it belongs to.
struct AccountCard: View {
    @ObservedObject var model: AppModel
    @State private var code: String?
    @State private var url: URL?
    @State private var note = ""

    var body: some View {
        CardSection(title: "GitHub account", symbol: "person.crop.circle.badge.checkmark", tint: Theme.indigo) {
            if let account = model.account {
                FieldRow(label: "signed in as", value: "@\(account.login)" + (account.name.map { " · \($0)" } ?? ""), mono: true)
                FieldRow(label: "since", value: Date(timeIntervalSince1970: account.since).formatted(date: .abbreviated, time: .omitted),
                         tint: .secondary)
            } else if let code {
                VStack(alignment: .leading, spacing: Theme.s2) {
                    Text("Enter this code on GitHub, then come back here.")
                        .font(.callout)
                    HStack(spacing: Theme.s3) {
                        Text(code)
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        } label: { Label("Copy", systemImage: "doc.on.doc") }
                        if let url {
                            Button { NSWorkspace.shared.open(url) } label: { Label("Open GitHub", systemImage: "arrow.up.forward.app") }
                        }
                    }
                    .controlSize(.small)
                    HStack(spacing: Theme.s2) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for GitHub…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Sign in with GitHub. The token stays in your Keychain on this Mac, and agents never see it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !note.isEmpty {
                Text(note)
                    .font(Theme.mono)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.s2) {
                if model.account != nil {
                    Button { model.run("account", ["status"]) { _, out in note = out } } label: {
                        Label("Check", systemImage: "checkmark.shield")
                    }
                    Button(role: .destructive) {
                        model.run("account", ["logout"]) { _, out in note = out; model.refresh() }
                    } label: { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") }
                } else if code != nil {
                    Button { model.run("account", ["login", "--cancel"]) { _, _ in } } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                } else {
                    Button { signIn() } label: { Label("Sign in with GitHub", systemImage: "person.badge.key") }
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
            .controlSize(.small)
        }
    }

    private func signIn() {
        note = ""
        model.run("account", ["login", "--start"]) { status, out in
            guard status == 0, let start = Account.parseStart(out) else {
                note = out
                return
            }
            code = start.code
            url = URL(string: start.url)
            if let url { NSWorkspace.shared.open(url) }
            model.run("account", ["login", "--wait"]) { _, out in
                code = nil
                url = nil
                note = out
                model.refresh()
            }
        }
    }
}

private struct SettingFieldRow: View {
    let field: ConfigField
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(field.key)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Spacer()
                if field.value == "true" || field.value == "false" {
                    Toggle("", isOn: Binding(
                        get: { value == "true" },
                        set: { value = $0 ? "true" : "false" }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
                }
            }
            if !field.comment.isEmpty {
                Text(field.comment)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if field.value != "true" && field.value != "false" {
                TextField(field.example, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(Theme.mono)
            }
        }
    }
}

/// One editable key, read from `agent/config.example.toml` (its comment is the help text) and valued from
/// the live `config.toml`.
struct ConfigField: Hashable {
    var section: String
    /// The header as the example writes it, quotes kept (`pace."github.com"`), so a section added to the
    /// live file is valid TOML.
    var header = ""
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
        var header = ""
        var comment: [String] = []
        for raw in exampleText.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                comment.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
                continue
            }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                header = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                section = header.replacingOccurrences(of: "\"", with: "")
                comment = []
                continue
            }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.hasPrefix("#") else { continue }
            let current = liveTable[section]?[key].map { _ in
                Config.loadedLiteral(section: section, key: key, raw: liveTable[section]?[key] ?? "")
            } ?? value
            out.append(ConfigField(section: section, header: header, key: key, comment: comment.suffix(3).joined(separator: " "),
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
        ScreenPage(title: "Playbooks",
             subtitle: "What was learned about apps, sites and flows; shared, so they stay free of personal details.",
             icon: "book.closed.fill", tint: Theme.plum) {
            AnyView(
                HStack(spacing: Theme.s2) {
                    Button { model.run("playbooks", ["--check"]) { _, out in check = out } } label: {
                        Label("Check", systemImage: "checkmark.shield")
                    }
                    .controlSize(.small)
                    Button { NSWorkspace.shared.open(Playbooks.dir) } label: {
                        Label("Folder", systemImage: "folder")
                    }
                    .controlSize(.small)
                }
            )
        } content: {
            HStack(spacing: Theme.s2) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search playbooks", text: $query)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Theme.s3)
            .padding(.vertical, Theme.s2)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))

            if books.isEmpty {
                Text("no playbook matches").font(.callout).foregroundStyle(.secondary).card()
            } else {
                ForEach(books, id: \.path) { book in
                    VStack(alignment: .leading, spacing: Theme.s2) {
                        HStack(spacing: Theme.s2) {
                            IconTile(symbol: "doc.text", tint: Theme.plum, size: 22)
                            Text(book.title).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            Spacer()
                            Text(book.path).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                        ForEach(book.keyFacts.prefix(3), id: \.self) { fact in
                            HStack(alignment: .top, spacing: 6) {
                                Circle().fill(Theme.plum.opacity(0.5)).frame(width: 4, height: 4).padding(.top, 5)
                                Text(fact).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: Theme.s3) {
                            Button { NSWorkspace.shared.open(book.url) } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .buttonStyle(.link).font(.system(size: 10.5))
                            Button { model.run("do", ["--explain", book.title]) { _, out in check = out } } label: {
                                Label("Which flow a task picks", systemImage: "arrow.triangle.branch")
                            }
                            .buttonStyle(.link).font(.system(size: 10.5))
                            Spacer()
                        }
                    }
                    .card(Theme.s3 + 2)
                }
            }
            if !check.isEmpty {
                CardSection(title: "Result", symbol: "terminal", tint: Theme.slate) {
                    Text(check)
                        .font(Theme.mono)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - VMs

struct VMsView: View {
    @ObservedObject var model: AppModel
    @State private var text = ""

    private let actions: [(String, String)] = [
        ("up", "play.fill"), ("down", "stop.fill"), ("on", "power"),
        ("off", "poweroff"), ("look", "eye"), ("status", "info.circle"), ("list", "list.bullet"),
    ]

    var body: some View {
        ScreenPage(title: "VMs",
             subtitle: "A small Linux VM with its own screen, cursor and keyboard, so browser work never borrows yours.",
             icon: "desktopcomputer", tint: Theme.teal) {
            AnyView(
                Button {
                    model.newTab(preset: "VM shell", command: "apprentice vm shell")
                } label: {
                    Label("Shell tab", systemImage: "terminal")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            )
        } content: {
            HStack(spacing: Theme.s2) {
                ForEach(actions, id: \.0) { action, icon in
                    Button {
                        text = "…"
                        model.run("vm", [action]) { _, out in text = out }
                    } label: {
                        Label(action, systemImage: icon)
                    }
                    .controlSize(.small)
                }
                Spacer()
            }
            CardSection(title: "State", symbol: "server.rack", tint: Theme.teal) {
                Text(text.isEmpty ? "…" : text)
                    .font(Theme.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { model.run("vm", ["list"]) { _, out in text = out } }
    }
}

// MARK: - Updates and health

/// The one-line notice across the top of the window when the DMG's app has a newer release.
struct UpdateBanner: View {
    @ObservedObject var model: AppModel
    let latest: Release.Latest

    var body: some View {
        HStack(spacing: Theme.s2) {
            Image(systemName: "arrow.down.app.fill")
                .foregroundStyle(Theme.accent)
            Text("apprentice \(latest.version) is available")
                .font(.callout.weight(.semibold))
            Text("you have \(Build.number)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if model.updateStep.isEmpty {
                if let page = latest.page.flatMap(URL.init(string:)) {
                    Button("What's new") { NSWorkspace.shared.open(page) }
                        .buttonStyle(.link)
                }
                Button { model.installUpdate() } label: { Label("Install and relaunch", systemImage: "arrow.down.circle") }
                    .buttonStyle(.borderedProminent)
            } else {
                ProgressView().controlSize(.small)
                Text(model.updateStep).font(.callout).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s2)
        .background(Theme.accent.opacity(0.10))
    }
}

struct HealthView: View {
    @ObservedObject var model: AppModel
    @State private var checks = ""
    @State private var version = ""

    var body: some View {
        ScreenPage(title: "Updates & health",
             subtitle: "The installed commit, the checks a first run needs, and how to offer a fix upstream.",
             icon: "heart.text.square.fill", tint: Theme.red) {
            AnyView(
                Button { load() } label: { Label("Check again", systemImage: "arrow.clockwise") }
                    .controlSize(.small)
            )
        } content: {
            CardSection(title: "Installed", symbol: "shippingbox", tint: Theme.accent) {
                FieldRow(label: "version", value: version, mono: true)
                if Release.isRelease, !Release.cloneInstalled {
                    FieldRow(label: "app", value: Release.bundle?.path ?? "", mono: true, tint: .secondary)
                    FieldRow(label: "updates", value: model.update.map { "\($0.version) is available" } ?? "from GitHub releases (\(Release.repo))",
                             mono: true, tint: model.update == nil ? .secondary : Theme.orange)
                    HStack(spacing: Theme.s2) {
                        if model.update != nil {
                            Button { model.installUpdate() } label: { Label("Install and relaunch", systemImage: "arrow.down.circle") }
                                .buttonStyle(.borderedProminent)
                                .disabled(!model.updateStep.isEmpty)
                        }
                        Button { model.checkRelease(force: true) } label: {
                            Label("Check for updates", systemImage: "arrow.triangle.2.circlepath")
                        }
                        Button {
                            checks = "connecting…"
                            DispatchQueue.global(qos: .userInitiated).async {
                                let note = Release.connectAgents() ?? "nothing to connect"
                                DispatchQueue.main.async { checks = note }
                            }
                        } label: { Label("Connect agents", systemImage: "point.3.connected.trianglepath.dotted") }
                        Spacer()
                    }
                    .controlSize(.small)
                } else {
                if let install = Build.install {
                    FieldRow(label: "clone", value: install.clone, mono: true, tint: .secondary)
                    FieldRow(label: "built", value: install.built ?? "?", mono: true, tint: .secondary)
                }
                HStack(spacing: Theme.s2) {
                    Button { checks = "updating…"; model.run("update") { _, out in checks = out } } label: {
                        Label("Update now", systemImage: "arrow.down.circle")
                    }
                    Button { model.run("update", ["--check"]) { _, out in checks = out } } label: {
                        Label("Check upstream", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button { model.run("pr", ["--local"]) { _, out in checks = out } } label: {
                        Label("Share my fixes", systemImage: "arrow.up.forward.square")
                    }
                    Spacer()
                }
                .controlSize(.small)
                }
            }
            CardSection(title: "doctor", symbol: "stethoscope", tint: Theme.green) {
                Text(checks.isEmpty ? "…" : checks)
                    .font(Theme.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.s2) {
                    Button { model.run("doctor", ["--fix"]) { _, out in checks = out } } label: {
                        Label("Fix permissions", systemImage: "wrench.and.screwdriver")
                    }
                    Button { checks = "running…"; model.run("selftest") { _, out in checks = out } } label: {
                        Label("Self-test", systemImage: "checkmark.seal")
                    }
                    Spacer()
                }
                .controlSize(.small)
            }
            HStack(alignment: .top, spacing: Theme.s3) {
                CardSection(title: "Bugs", symbol: "ladybug", tint: Theme.orange) {
                    Text("\(bugCount()) open items in BUGS.md")
                        .font(.callout)
                    Button { NSWorkspace.shared.open(Repo.root.appendingPathComponent("BUGS.md")) } label: {
                        Label("Open BUGS.md", systemImage: "arrow.up.forward.app")
                    }
                    .controlSize(.small)
                }
                CardSection(title: "Todo", symbol: "checklist", tint: Theme.indigo) {
                    Text("\(todoCount()) items in TODO.md")
                        .font(.callout)
                    Button { NSWorkspace.shared.open(Repo.root.appendingPathComponent("TODO.md")) } label: {
                        Label("Open TODO.md", systemImage: "arrow.up.forward.app")
                    }
                    .controlSize(.small)
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        version = Build.version
        model.run("doctor") { _, out in checks = out }
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
        VStack(alignment: .leading, spacing: Theme.s3) {
            HStack(spacing: Theme.s2) {
                IconTile(symbol: "command", tint: Theme.accent, size: 26, solid: true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Run a command").font(Theme.title(15))
                    Text("Same commands and exit codes as the CLI")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: Theme.s2) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
                TextField("schedule list", text: $model.paletteText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit(run)
            }
            .padding(.horizontal, Theme.s3)
            .padding(.vertical, Theme.s2 + 2)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.hairline))
            ScrollView {
                Text(output.isEmpty ? "output appears here" : output)
                    .font(Theme.mono)
                    .foregroundStyle(output.isEmpty ? .tertiary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.s3)
            }
            .frame(height: 230)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.hairline))
            HStack {
                Text("⌘K to open · Return to run")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Close") { model.paletteOpen = false }
                Button("Run", action: run)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.s5)
        .frame(width: 600)
        .background(Theme.canvas)
    }

    private func run() {
        // Quoted words stay one argument, as in a flow step: `schedule add "daily check" …`.
        guard let words = try? Commands.tokenize(model.paletteText), let cmd = words.first else { return }
        output = "running…"
        model.run(cmd, Array(words.dropFirst())) { code, out in
            output = (code == 0 ? "" : "exit \(code)\n") + out
            model.refresh()
        }
    }
}
