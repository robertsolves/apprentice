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
        AppLook.apply()
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
        TerminalKeys.install()
        if let out = ProcessInfo.processInfo.environment["APPRENTICE_APP_KEYTEST"] { KeyTest.run(model: model, window: window, out: out) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }
}

/// `APPRENTICE_APP_KEYTEST=<file>`: opens a tab running `cat -v`, sends keys through the app's own event path
/// (`NSApp.sendEvent`, so window key equivalents and the responder chain all take part, as with a real
/// keyboard), writes what the tab printed and who had the keyboard to the file, and quits. It is how the
/// terminal's arrow keys are checked end to end without anyone at the keyboard.
enum KeyTest {
    static func run(model: AppModel, window: NSWindow, out: String) {
        var log: [String] = []
        func note(_ s: String) { log.append(s) }
        func responder() -> String { window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil" }
        func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: chars,
                                               charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { continue }
                NSApp.sendEvent(e)
            }
        }
        /// A click at a point given from the window's top-left, in points.
        func click(_ x: CGFloat, _ fromTop: CGFloat) {
            let h = window.contentView?.bounds.height ?? 780
            let p = NSPoint(x: x, y: h - fromTop)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                NSApp.sendEvent(e)
            }
        }
        func hit(_ x: CGFloat, _ fromTop: CGFloat) -> String {
            let h = window.contentView?.bounds.height ?? 780
            let v = window.contentView?.hitTest(NSPoint(x: x, y: h - fromTop))
            return v.map { String(describing: type(of: $0)) } ?? "nil"
        }
        let arrows: NSEvent.ModifierFlags = [.function, .numericPad]
        func down() { key(125, String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!), arrows) }
        func up() { key(126, String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!), arrows) }
        func dump(_ title: String) {
            guard let term = model.selectedSession else { note("\(title): no tab"); return }
            let rows = (0..<term.screen.rows).map { term.screen.rowText($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            note("\(title) · responder \(responder())\n  " + rows.suffix(6).joined(separator: "\n  "))
        }
        let steps: [(Double, () -> Void)] = [
            (1.5, { model.newTab(preset: "keytest", command: "stty -echo; cat -v") }),
            (1.5, { dump("tab opened") }),
            (0.2, { key(0, "a"); down(); up(); key(36, "\r") }),
            (0.8, { dump("typed a, down, up, return") }),
            (4.5, { note("after the 2-second refreshes · responder \(responder())") }),
            (0.1, { model.section = .schedules }),
            (0.6, { model.section = .terminal }),
            (0.8, { note("after Schedules and back · responder \(responder())") }),
            (0.1, { model.newTab(preset: "keytest2", command: "stty -echo; cat -v") }),
            (1.2, { note("after a new tab · responder \(responder())") }),
            (0.1, { if let first = model.tabs.first(where: { $0.title == "keytest" }) { model.selectedTab = first.id } }),
            (0.8, { note("after choosing the first tab again · responder \(responder())") }),
            (0.1, { note("under the sidebar's Terminal row: \(hit(110, 128)); the tab bar: \(hit(330, 70)); the terminal: \(hit(700, 400))") }),
            (0.1, { click(110, 128) }),
            (0.6, { note("after clicking the sidebar · responder \(responder())") }),
            (0.1, { key(0, "c"); down(); key(36, "\r") }),
            (0.6, { dump("typed c, down, return after the sidebar click") }),
            (0.1, { click(700, 400) }),
            (0.6, { note("after clicking inside the terminal · responder \(responder())") }),
            (0.1, { key(0, "d"); down(); key(36, "\r") }),
            (0.6, { dump("typed d, down, return after clicking the terminal") }),
            (0.1, { click(330, 70) }),
            (0.6, { note("after clicking the tab bar · responder \(responder())") }),
            // The window's own controls had the keyboard last: the user clicked the sidebar, then the terminal.
            (0.2, { window.makeFirstResponder(nil); key(0, "b"); down(); key(36, "\r") }),
            (0.8, { dump("after the window took the keyboard: b, down, return") }),
            (0.2, {
                try? log.joined(separator: "\n\n").write(toFile: out, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }),
        ]
        var at = 0.0
        for (delay, step) in steps {
            at += delay
            DispatchQueue.main.asyncAfter(deadline: .now() + at, execute: step)
        }
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

/// One visual language for the window: one blue accent, clear SF Symbols in it for every section and
/// action, hairlines instead of shadows, monospace for anything a command would print. No gradients.
enum Theme {
    /// The accent: icons, the selected thing, live and done.
    static let accent = Color(red: 0.16, green: 0.47, blue: 0.96)
    /// Waiting on the user.
    static let warn = Color(red: 0.95, green: 0.64, blue: 0.22)
    /// Failed, denied, stopped.
    static let danger = Color(red: 0.90, green: 0.33, blue: 0.33)

    /// 4-pt scale: 4, 8, 12, 16, 20, 24.
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 20
    static let s6: CGFloat = 24

    static let radius: CGFloat = 8
    static let page = EdgeInsets(top: 24, leading: 28, bottom: 24, trailing: 28)
    /// Text reads best under about 70 characters a line; forms and panels stop here on a wide window.
    static let column: CGFloat = 760

    static var canvas: Color { Color(nsColor: .windowBackgroundColor) }
    static var surface: Color { Color(nsColor: .controlBackgroundColor) }
    static var hairline: Color { Color.primary.opacity(0.10) }

    static func title(_ size: CGFloat = 20) -> Font { .system(size: size, weight: .semibold) }
    static var heading: Font { .system(size: 13, weight: .semibold) }
    static var body: Font { .system(size: 12.5) }
    static var caption: Font { .system(size: 11) }
    static var mono: Font { .system(size: 11.5, design: .monospaced) }
    static var monoSmall: Font { .system(size: 10.5, design: .monospaced) }
    /// The small uppercase label over a value or a group.
    static var eyebrow: Font { .system(size: 10, weight: .medium, design: .monospaced) }
}

extension View {
    /// A bounded surface: a hairline and a flat fill, used for every group on screen.
    func panel(_ padding: CGFloat = Theme.s4) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline))
    }

    func eyebrow() -> some View {
        self.font(Theme.eyebrow)
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

/// A small state chip in monospace: `idle`, `working`, `needs you`, a run result.
struct StatusPill: View {
    let text: String
    var tint: Color = .secondary
    var dot = true
    /// An SF Symbol in place of the dot.
    var icon: String?

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
            } else if dot {
                Circle().fill(tint).frame(width: 7, height: 7)
            }
            Text(text).font(Theme.monoSmall).lineLimit(1)
        }
        .padding(.horizontal, Theme.s2)
        .padding(.vertical, 3)
        .foregroundStyle(dot ? .primary : tint)
        .overlay(Capsule().strokeBorder(Theme.hairline))
    }
}

/// A labelled value: the small key above, its value below.
struct FieldRow: View {
    let label: String
    let value: String
    var mono = false
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).eyebrow()
            Text(value)
                .font(mono ? Theme.mono : Theme.body)
                .foregroundStyle(tint ?? .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A titled group of rows in a panel.
struct Panel<Content: View>: View {
    let title: String
    var note = ""
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).eyebrow()
                if !note.isEmpty {
                    Spacer(minLength: Theme.s3)
                    Text(note).font(Theme.monoSmall).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            content()
        }
        .panel()
    }
}

/// The header every screen starts with: a title, one plain line under it, and the screen's actions.
struct ScreenHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.s3) {
            VStack(alignment: .leading, spacing: Theme.s1) {
                Text(title).font(Theme.title())
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.s3)
            actions().controlSize(.small)
        }
    }
}

/// A page: the header, then its panels, in one readable column.
struct ScreenPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: () -> AnyView
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s4) {
                ScreenHeader(title: title, subtitle: subtitle, actions: actions)
                content()
            }
            .frame(maxWidth: Theme.column, alignment: .leading)
            .padding(Theme.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
    }
}

/// A form row: a label of fixed width, then the control, so every form lines up.
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
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .trailing)
            content()
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Command output as the CLI printed it.
struct Output: View {
    let text: String
    var placeholder = "…"

    var body: some View {
        Text(text.isEmpty ? placeholder : text)
            .font(Theme.mono)
            .foregroundStyle(text.isEmpty ? .tertiary : .primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A sheet's frame: its title line, the form, and the buttons, sized to the window.
struct SheetFrame<Content: View, Buttons: View>: View {
    let title: String
    var subtitle = ""
    let content: () -> Content
    let buttons: () -> Buttons
    /// Taken once, when the sheet opens: it never resizes under the person's typing.
    @State private var size: CGSize

    init(title: String, subtitle: String = "", idealHeight: CGFloat = 560, idealWidth: CGFloat = 600,
         @ViewBuilder content: @escaping () -> Content, @ViewBuilder buttons: @escaping () -> Buttons) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
        self.buttons = buttons
        _size = State(initialValue: CGSize(width: SheetSize.width(ideal: idealWidth), height: SheetSize.height(ideal: idealHeight)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            VStack(alignment: .leading, spacing: Theme.s1) {
                Text(title).font(Theme.title(17))
                if !subtitle.isEmpty { Text(subtitle).font(Theme.caption).foregroundStyle(.secondary) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s3) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: Theme.s2) { buttons() }
        }
        .padding(Theme.s5)
        .frame(width: size.width, height: size.height)
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
    /// The first-run steps (GitHub, Accessibility, Screen Recording), until the user finishes them once.
    @Published var welcomeOpen = !Welcome.done
    @Published var projects: [Projects.Info] = []
    @Published var pipelines: [Pipelines.Pipeline] = []
    /// The VMs (`VM.inventory`), read off the main thread: Tart takes a moment to answer.
    @Published var machines: [VM.Machine] = []
    /// The New project sheet, open on an empty folder or a GitHub clone.
    @Published var newProject: NewProjectSheet.Start?
    /// The pipeline open in the Pipelines screen (unsaved when it has no file), and a counter that
    /// reloads the editor when another one is chosen.
    @Published var pipelineDraft: Pipelines.Pipeline?
    @Published var pipelineEdits = 0
    /// The agent CLIs and editors installed on this Mac (`AgentCLIs.installed`), read off the main thread
    /// since it starts a login shell; nil until the first read, when everything counts as installed.
    @Published var installedAgents: Set<String>?
    private var refreshes = 0

    let home = FileManager.default.homeDirectoryForCurrentUser

    init() {
        refresh()
        checkRelease()
        newTab(preset: "Shell", command: nil)
        refreshMachines()
        refreshAgents()
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
        let listed = Projects.all()
        if listed.map(\.id) != projects.map(\.id) || listed.map(\.name) != projects.map(\.name) { projects = listed }
        pipelines = Pipelines.all()
        busy = pending.count > 0 || StatusItem.state == .working
        revision += 1
        // An agent installed while the window is open shows up within a minute.
        refreshes += 1
        if refreshes % 30 == 0 { refreshAgents() }
        for tab in tabs { tab.hasApproval = pending.contains { $0.tab == tab.id } }
        // The socket check runs off the main thread: a busy daemon must not freeze the window.
        DispatchQueue.global(qos: .utility).async {
            let up = Wire.ping()
            DispatchQueue.main.async { if self.daemonUp != up { self.daemonUp = up } }
        }
    }

    var status: String {
        if !pending.isEmpty { return "needs you" }
        if !daemonUp { return "stopped" }
        return busy ? "working" : "idle"
    }

    var statusIcon: String {
        if !pending.isEmpty { return "exclamationmark.circle.fill" }
        if !daemonUp { return "stop.circle" }
        return busy ? "bolt.circle.fill" : "checkmark.circle.fill"
    }

    func refreshMachines() {
        DispatchQueue.global(qos: .utility).async {
            let list = VM.inventory()
            DispatchQueue.main.async { if list != self.machines { self.machines = list } }
        }
    }

    func refreshAgents() {
        DispatchQueue.global(qos: .utility).async {
            let found = AgentCLIs.installed()
            DispatchQueue.main.async { if self.installedAgents != found { self.installedAgents = found } }
        }
    }

    func isInstalled(_ cli: AgentCLIs.CLI) -> Bool { installedAgents?.contains(cli.id) ?? true }

    /// The terminal agents a picker offers: the installed ones, plus `keeping` (the current choice) even when
    /// it is not, so a saved choice still shows.
    func agentChoices(keeping: String? = nil) -> [AgentCLIs.CLI] {
        AgentCLIs.agents().filter { isInstalled($0) || $0.id == keeping }
    }

    /// Opens a project's folder in an editor app (`editor` in agents.toml).
    func openInEditor(_ cli: AgentCLIs.CLI, _ p: Projects.Info) {
        let argv = AgentCLIs.editorArgv(cli, folder: p.folder)
        guard let first = argv.first else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: first.hasPrefix("/") ? first : "/usr/bin/env")
        proc.arguments = first.hasPrefix("/") ? Array(argv.dropFirst()) : argv
        proc.currentDirectoryURL = p.folder
        do { try proc.run() } catch { output = "could not open \(cli.label): \(error.localizedDescription)" }
    }

    /// Opens the project's agent (or `agent`, for this tab only) in a tab in its folder, working in its VM;
    /// `setUpVM` makes that VM first, in the same tab, so the user watches it being made.
    func openProject(_ p: Projects.Info, agent: String? = nil, setUpVM: String? = nil) {
        var command = AgentChoice.command(agent ?? p.agent)
        if let vm = setUpVM {
            command = "apprentice --vm \(vm) vm setup && " + (command ?? "exec \"$SHELL\" -l")
        }
        newTab(preset: p.name, command: command, dir: p.folder, vm: p.vm)
    }

    /// Runs a pipeline in a new tab, so its output shows as it comes.
    func runPipeline(_ p: Pipelines.Pipeline) {
        let ref = p.url?.path ?? p.ref
        newTab(preset: p.name, command: "apprentice pipeline run \(VM.shellQuoted(ref)); echo; exec \"$SHELL\" -l", dir: p.folder, vm: p.effectiveVM)
    }

    /// Shows a pipeline in the Pipelines screen's editor (a new one when it has no file).
    func editPipeline(_ p: Pipelines.Pipeline) {
        pipelineDraft = p
        pipelineEdits += 1
        section = .pipelines
    }

    /// The installed CLI with these arguments, off the main thread.
    func runCLI(_ argv: [String], then: @escaping (Int32, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let (code, out) = self.cli(argv)
            DispatchQueue.main.async { then(code, out) }
        }
    }

    var statusTint: Color {
        if !pending.isEmpty { return Theme.warn }
        if !daemonUp { return .secondary }
        return Theme.accent
    }

    /// The VMs this Mac has set up, by the state folders their daemons keep.
    var vmNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: Store.dir.appendingPathComponent("vms").path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
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
                                        "phone", "selftest", "version", "account", "sync", "pipeline", "device", "skills"]

    /// Every button: the same request the CLI sends, marked as the user's own. It blocks, so it never runs
    /// on the main thread: `run(_:_:then:)` and `act` call it from a background queue.
    private func send(_ cmd: String, _ args: [String]) -> (code: Int32, out: String) {
        if Self.inClient.contains(cmd) { return cli([cmd] + args) }
        guard let response = try? Wire.send(Request(cmd: cmd, args: args, user: true)) else {
            return (5, "apprentice's background service did not answer. In a tab, `apprentice serve` shows why.")
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
            let r = (try? Wire.send(req, vm: vm)).map { ($0.code, $0.out) } ?? (5, "the \(vm) VM did not answer")
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

    func newTab(preset: String, command: String?, dir: URL? = nil, vm: String? = nil, env: [String: String] = [:]) {
        let presetValues = Config.current.tabPresets[preset] ?? [:]
        let folder = dir ?? (presetValues["dir"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }) ?? home
        let cmd = command ?? presetValues["cmd"]
        let session = TermSession(title: preset, dir: folder, command: cmd, env: env,
                                  vm: vm ?? presetValues["vm"])
        tabs.append(session)
        selectedTab = session.id
        section = .terminal
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

    /// A tab where you ask about apprentice in your own words: an agent reading the docs, changing nothing.
    func openHelpTab() {
        if let open = tabs.first(where: { $0.title == "Help" && $0.exited == nil }) {
            selectedTab = open.id
            section = .terminal
            return
        }
        newTab(preset: "Help", command: HelpTab.command, dir: HelpTab.dir, env: HelpTab.env)
    }
}

// MARK: - Navigation

/// The sidebar's sections. Each case picks a screen; its name, icon, order and explainer come from
/// `[section.<case>]` in agent/app-text.toml (`AppText`).
enum Section: String, CaseIterable, Identifiable {
    case projects, terminal, pipelines, schedules, skills, sites, vms, settings, updates

    var id: String { rawValue }
    var label: String { AppText.screen(rawValue).label }
    var icon: String { AppText.screen(rawValue).icon }

    /// The sections in the order app-text.toml lists them; one it leaves out goes last.
    static var ordered: [Section] {
        let order = AppText.screens.map(\.id)
        return allCases.sorted { (order.firstIndex(of: $0.rawValue) ?? .max) < (order.firstIndex(of: $1.rawValue) ?? .max) }
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 320)
        } detail: {
            detail
                .frame(minWidth: 680, minHeight: 480)
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
        .background(Color.clear.sheet(isPresented: $model.welcomeOpen) { WelcomeView(model: model) })
        .background(Color.clear.sheet(item: $model.newProject) { start in NewProjectSheet(model: model, start: start) })
        .background(shortcuts)
        .onAppear { model.refresh() }
    }

    private var sidebar: some View {
        List(Section.ordered, selection: Binding(
            get: { model.section },
            set: { if let s = $0 { model.section = s } })) { section in
            HStack(spacing: Theme.s3) {
                Image(systemName: section.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22)
                Text(section.label)
                    .font(.system(size: 13, weight: section == model.section ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .tag(section)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top) {
            VStack(alignment: .leading, spacing: Theme.s3) {
                HStack(alignment: .center, spacing: Theme.s2) {
                    Image(nsImage: NSApp.applicationIconImage ?? Ask.icon)
                        .resizable().interpolation(.high).frame(width: 18, height: 18)
                    Text("apprentice").font(.system(size: 13, weight: .bold)).lineLimit(1).fixedSize()
                    Text("v\(Build.version)").font(Theme.monoSmall).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                Divider()
            }
            .padding(.horizontal, Theme.s4)
            .padding(.top, Theme.s2)
            .background(.thinMaterial)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.s2) {
                Divider()
                HStack(spacing: Theme.s2) {
                    StatusPill(text: model.status, tint: model.statusTint, icon: model.statusIcon)
                    if model.awayOn { StatusPill(text: "away", tint: .secondary) }
                    if Pause.on { StatusPill(text: "paused", tint: Theme.warn) }
                }
                if !model.output.isEmpty {
                    Text(model.output)
                        .font(Theme.monoSmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                if let account = model.account {
                    Button { model.section = .settings } label: {
                        Text("@\(account.login)").font(Theme.monoSmall).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Signed in to GitHub · Settings")
                }
                Text("stop everything  ⌃⌥⌘.")
                    .font(Theme.monoSmall)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.s4)
            .padding(.bottom, Theme.s3)
            .background(.thinMaterial)
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .projects: ProjectsView(model: model)
        case .pipelines: PipelinesView(model: model)
        case .terminal: TerminalWorkspace(model: model)
        case .schedules: SchedulesView(model: model)
        case .skills: SkillsView(model: model)
        case .sites: SitesView(model: model)
        case .vms: VMsView(model: model)
        case .settings: SettingsView(model: model)
        case .updates: UpdatesView(model: model)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .status) {
            if let session = model.session, let url = session.url, let host = URL(string: url)?.host {
                Text(host).font(Theme.monoSmall).foregroundStyle(.secondary)
            } else if let session = model.session {
                Text(session.app).font(Theme.monoSmall).foregroundStyle(.secondary)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.openHelpTab() } label: { Label("Help", systemImage: "questionmark.circle") }
                .help("Ask anything about apprentice in a tab")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.togglePause() } label: { Label(Pause.on ? "Resume" : "Pause", systemImage: Pause.on ? "play.circle" : "pause.circle") }
                .help("Hold apprentice still: new actions wait until you resume")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.paletteOpen = true
                model.paletteText = ""
            } label: { Label("Command", systemImage: "command") }
            .keyboardShortcut("k", modifiers: .command)
            .help("Run any apprentice command (⌘K)")
        }
    }

    /// ⌘1…9 choose the sidebar sections; keyboard first, as the design asks.
    private var shortcuts: some View {
        ZStack {
            Button("New shell") { model.newTab(preset: "Shell", command: nil) }
                .keyboardShortcut("t", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0.01)
            ForEach(Array(Section.ordered.enumerated()), id: \.offset) { index, section in
                Button(section.label) { model.section = section }
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
                        .padding(Theme.s2)
                        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline))
                        .padding(.horizontal, Theme.s3)
                        .padding(.vertical, Theme.s3)
                    if let pending = pendingForSelected {
                        ApprovalBanner(model: model, pending: pending)
                            .padding(.horizontal, Theme.s4)
                            .padding(.bottom, Theme.s5)
                    }
                }
                footer(session)
            } else {
                ScrollView {
                    Explainer(.terminal)
                        .frame(maxWidth: Theme.column)
                        .padding(Theme.page)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Theme.canvas)
    }

    private var font: NSFont { AppLook.terminalFont }

    private var tabBar: some View {
        HStack(spacing: Theme.s2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.s1) {
                    ForEach(model.tabs) { tab in
                        TabChip(tab: tab, selected: tab.id == model.selectedTab,
                                close: { model.closeTab(tab.id) },
                                select: { model.selectedTab = tab.id })
                    }
                }
                .padding(.horizontal, Theme.s3)
                .padding(.vertical, Theme.s2)
            }
            Menu {
                // A project opens with its own agent in one click; another agent is one level down.
                if !model.projects.isEmpty {
                    SwiftUI.Section("Projects") {
                        ForEach(model.projects) { p in
                            Button("\(p.name) · \(AgentChoice.label(p.agent))") { model.openProject(p) }
                        }
                    }
                    let agents = model.agentChoices().filter { !$0.shell }
                    if agents.count > 1 {
                        Menu("Open a project with another agent") {
                            ForEach(model.projects) { p in
                                Menu(p.name) {
                                    ForEach(agents.filter { $0.id != p.agent }) { cli in
                                        Button(cli.label) { model.openProject(p, agent: cli.id) }
                                    }
                                }
                            }
                        }
                    }
                }
                Button("New project…") { model.newProject = .empty }
                Divider()
                SwiftUI.Section("Without a project") {
                    ForEach(model.agentChoices()) { cli in Button(cli.label) { model.newTab(preset: cli.label, command: cli.open) } }
                }
                let missing = AgentCLIs.all().filter { !model.isInstalled($0) && $0.install != nil }
                if !missing.isEmpty {
                    Menu("Not installed") {
                        ForEach(missing) { cli in
                            Button("Get \(cli.label)…") { if let u = cli.install.flatMap(URL.init(string:)) { NSWorkspace.shared.open(u) } }
                        }
                    }
                }
                Divider()
                Button("Help: ask about apprentice") { model.openHelpTab() }
                Button("Log (following)") { model.openLogTab() }
                if !Config.current.tabPresets.isEmpty {
                    Divider()
                    ForEach(Config.current.tabPresets.keys.sorted(), id: \.self) { name in
                        Button(name) { model.newTab(preset: name, command: nil) }
                    }
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New tab (⌘T)")
            .padding(.trailing, Theme.s3)
        }
        .background(.bar)
    }

    private func footer(_ session: TermSession) -> some View {
        HStack(spacing: Theme.s3) {
            Text(session.title).font(Theme.monoSmall).foregroundStyle(.secondary)
            if !session.subtitle.isEmpty {
                Text(session.subtitle).font(Theme.monoSmall).foregroundStyle(.tertiary)
            }
            Spacer()
            if let bound = model.session {
                StatusPill(text: bound.app, dot: false)
                if let dir = Project.dir?.deletingLastPathComponent().lastPathComponent {
                    StatusPill(text: "project \(dir)", dot: false)
                }
            } else {
                Text("no app bound").font(Theme.monoSmall).foregroundStyle(.tertiary)
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

    private var dot: Color {
        if tab.hasApproval { return Theme.warn }
        if let code = tab.exited { return code == 0 ? .secondary : Theme.danger }
        return Theme.accent
    }

    private var icon: String {
        if tab.hasApproval { return "exclamationmark.circle.fill" }
        if let code = tab.exited { return code == 0 ? "checkmark.circle" : "xmark.circle.fill" }
        return "terminal"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(dot)
            Text(tab.title)
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .lineLimit(1)
            if let code = tab.exited, !tab.hasApproval {
                Text("\(code)").font(Theme.monoSmall).foregroundStyle(code == 0 ? .secondary : Theme.danger)
            }
            if hovering || selected {
                Button(action: close) {
                    Text("×").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help("Close tab")
            }
        }
        .padding(.horizontal, Theme.s3)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(selected ? Theme.surface : (hovering ? Color.primary.opacity(0.04) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(selected ? Theme.hairline : Color.clear)
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
            HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
                Text("needs your approval").eyebrow().foregroundStyle(Theme.warn)
                Spacer(minLength: 0)
                Text("expires \(Date(timeIntervalSince1970: pending.expires).formatted(date: .omitted, time: .shortened))")
                    .font(Theme.monoSmall).foregroundStyle(.secondary)
            }
            Text(pending.summary)
                .font(Theme.heading)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let warnings = pending.warnings, !warnings.isEmpty {
                FlowChips(items: warnings.map { "⚠ \($0)" }, tint: Theme.warn)
            }
            // No default key: Allow takes a click, so a stray Return (or a script's keystroke) never approves.
            HStack(spacing: Theme.s2) {
                Text("apprentice approve \(pending.token)").font(Theme.monoSmall).foregroundStyle(.tertiary)
                Spacer()
                Button("Deny", role: .destructive) { model.deny(pending) }
                Button("Allow") { model.approve(pending) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.warn)
            }
            .controlSize(.small)
        }
        .padding(Theme.s4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.warn.opacity(0.5)))
    }
}

/// Chips that wrap onto more than one line, for warnings and tags.
struct FlowChips: View {
    let items: [String]
    var tint: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s1) {
            ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { index in
                HStack(spacing: Theme.s1) {
                    ForEach(items[index..<min(index + 2, items.count)], id: \.self) { item in
                        Text(item)
                            .font(Theme.monoSmall)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundStyle(tint)
                            .overlay(Capsule().strokeBorder(tint.opacity(0.4)))
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
        SplitPane(id: "schedules", help: .schedules) {
            VStack(spacing: 0) {
                HStack {
                    Text("\(model.schedules.count) schedule\(model.schedules.count == 1 ? "" : "s")")
                        .font(Theme.monoSmall)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { adding = true } label: { Label("New", systemImage: "plus") }
                        .controlSize(.small)
                }
                .padding(.horizontal, Theme.s3)
                .padding(.vertical, Theme.s2)
                Divider()
                if model.schedules.isEmpty {
                    VStack(spacing: Theme.s2) {
                        Text("Nothing scheduled").font(Theme.heading)
                        Text("Something that runs later, or again and again: a prompt for an agent, a task, or saved steps from a playbook.")
                            .font(Theme.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(Theme.s4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selected) {
                        ForEach(model.schedules) { schedule in
                            ScheduleRow(schedule: schedule).tag(schedule.id)
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            }
        } right: {
            Group {
                if let id = selected, let schedule = model.schedules.first(where: { $0.id == id }) {
                    ScheduleDetail(model: model, schedule: schedule)
                } else {
                    ScreenPage(title: Section.schedules.label, subtitle: "") {
                        AnyView(IconButton("New schedule", "plus", prominent: true) { adding = true })
                    } content: {
                        Explainer.schedules
                        Panel(title: "At login") {
                            Text("Schedules run from apprentice's background service. Start it at login so they run even when this window is closed.")
                                .font(Theme.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: Theme.s2) {
                                Button("Start at login") { model.act("schedule", ["agent", "on"]) }
                                Button("Stop starting at login") { model.act("schedule", ["agent", "off"]) }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .background(Theme.canvas)
        .sheet(isPresented: $adding) {
            ScheduleEditor(model: model, existing: nil) { adding = false }
        }
    }
}

private struct ScheduleRow: View {
    let schedule: Schedules.Schedule

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.s2) {
                Circle().fill(schedule.enabled ? Theme.accent : Color.secondary).frame(width: 5, height: 5)
                Text(schedule.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            }
            Text(schedule.when_ + (schedule.jitter > 0 ? "  ±\(schedule.jitter)m" : ""))
                .font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(1)
            if let next = schedule.next, schedule.enabled {
                Text("next \(next.formatted(date: .abbreviated, time: .shortened))")
                    .font(Theme.monoSmall).foregroundStyle(.tertiary)
            } else if let result = schedule.lastResult {
                Text(result).font(Theme.monoSmall).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

struct ScheduleDetail: View {
    @ObservedObject var model: AppModel
    let schedule: Schedules.Schedule
    @State private var editing = false
    @State private var runs: [(name: String, url: URL)] = []

    var body: some View {
        ScreenPage(title: schedule.name,
                   subtitle: "\(schedule.kind.label) · \(schedule.when_)" + (schedule.jitter > 0 ? " ±\(schedule.jitter) min" : "")) {
            AnyView(
                HStack(spacing: Theme.s2) {
                    Toggle("On", isOn: Binding(get: { schedule.enabled }, set: { on in
                        model.act("schedule", [on ? "resume" : "pause", schedule.id])
                    }))
                    .toggleStyle(.switch)
                    Button("Run now") { model.act("schedule", ["now", schedule.id]) }
                    Button("Edit") { editing = true }
                    Button("Delete", role: .destructive) { model.act("schedule", ["rm", schedule.id]) }
                }
            )
        } content: {
            Panel(title: "What runs") {
                FieldRow(label: schedule.kind.label, value: schedule.target, mono: true)
                if let dir = schedule.dir { FieldRow(label: "Folder", value: dir, mono: true, tint: .secondary) }
                if let vm = schedule.vm { FieldRow(label: "VM", value: vm, mono: true, tint: .secondary) }
            }
            Panel(title: "Next runs") {
                let preview = Schedules.preview(schedule)
                if !schedule.enabled {
                    Text("paused").font(Theme.body).foregroundStyle(.secondary)
                } else if preview.isEmpty {
                    Text("nothing ahead").font(Theme.body).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(preview.enumerated()), id: \.offset) { index, date in
                        Text(date.formatted(date: .complete, time: .shortened))
                            .font(Theme.mono)
                            .foregroundStyle(index == 0 ? .primary : .secondary)
                    }
                }
                if Schedules.quietHours(schedule).from >= 0 {
                    Text("Runs that fall in quiet hours (\(Int(Schedules.quietHours(schedule).from)):00–\(Int(Schedules.quietHours(schedule).to) % 24):00) move to the end of them.")
                        .font(Theme.caption).foregroundStyle(.secondary)
                }
                if let result = schedule.lastResult {
                    StatusPill(text: "last run: \(result)", tint: result.hasPrefix("ok") ? Theme.accent : Theme.warn)
                }
            }
            Panel(title: "Logs") {
                if runs.isEmpty {
                    Text("no runs yet").font(Theme.body).foregroundStyle(.secondary)
                } else {
                    ForEach(runs, id: \.name) { run in
                        Button { NSWorkspace.shared.open(run.url) } label: {
                            Text(run.name).font(Theme.mono).foregroundStyle(Theme.accent)
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

/// The editor writes exactly what `schedule add` takes; the dates, times and weekdays are chosen, not typed.
struct ScheduleEditor: View {
    @ObservedObject var model: AppModel
    let existing: Schedules.Schedule?
    /// A new schedule that starts filled in: a pipeline's Schedule button.
    var presetKind: String?
    var presetTarget: String?
    var presetName: String?
    var done: () -> Void

    @State private var name = ""
    @State private var kind = "prompt"
    @State private var target = ""
    @State private var agent = AgentCLIs.defaultID
    @State private var trigger = "daily"
    @State private var at = Date().addingTimeInterval(3600)
    @State private var every = 60
    @State private var clock = 9 * 60
    @State private var days: Set<Int> = [2, 3, 4, 5, 6]
    @State private var cron = ""
    @State private var jitter = 15
    @State private var dir = ""
    @State private var vm = ""
    @State private var problem = ""

    private var targetLabel: String {
        switch kind {
        case "prompt": return "Prompt"
        case "run": return "Task"
        case "do": return "Flow"
        case "pipeline": return "Pipeline"
        default: return "Command"
        }
    }

    var body: some View {
        SheetFrame(title: existing == nil ? "New schedule" : "Edit schedule",
                   subtitle: "Runs through the same approvals, budgets and limits as anything you start yourself.",
                   idealHeight: 640) {
            Panel(title: "What") {
                LabeledField("Name") { TextField("what it does, in a few words", text: $name) }
                LabeledField("Runs") {
                    Picker("", selection: $kind) {
                        Text("a prompt in an agent").tag("prompt")
                        Text("a pipeline").tag("pipeline")
                        Text("an apprentice task").tag("run")
                        Text("steps from a playbook").tag("do")
                        Text("a shell command").tag("sh")
                    }
                    .labelsHidden().pickerStyle(.menu).frame(maxWidth: 240)
                }
                if kind == "prompt" {
                    LabeledField("Agent") {
                        Picker("", selection: $agent) {
                            ForEach(model.agentChoices(keeping: agent).filter { !$0.shell }) { Text($0.label).tag($0.id) }
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 320)
                    }
                }
                if kind == "pipeline" {
                    LabeledField(targetLabel) {
                        Picker("", selection: $target) {
                            if model.pipelines.isEmpty { Text("no pipelines yet").tag("") }
                            ForEach(model.pipelines) { Text($0.name).tag($0.ref) }
                        }
                        .labelsHidden().pickerStyle(.menu).frame(maxWidth: 320)
                    }
                } else {
                    LabeledField(targetLabel) {
                        TextField(kind == "do" ? "the name of the steps, as the playbook lists it" : "what should it do", text: $target, axis: .vertical)
                            .lineLimit(4...14)
                            .font(kind == "prompt" ? Theme.body : Theme.mono)
                    }
                }
            }
            Panel(title: "When") {
                LabeledField("Repeat") {
                    Picker("", selection: $trigger) {
                        Text("once").tag("at")
                        Text("every few minutes").tag("every")
                        Text("every day").tag("daily")
                        Text("on chosen days").tag("weekly")
                        Text("a cron line").tag("cron")
                    }
                    .labelsHidden().pickerStyle(.menu).frame(maxWidth: 240)
                    .onChange(of: trigger) { _, now in if now == "cron", cron.isEmpty { cron = "0 9 * * 1-5" } }
                }
                switch trigger {
                case "at":
                    LabeledField("Date and time") {
                        DatePicker("", selection: $at, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden().datePickerStyle(.field)
                    }
                case "every":
                    LabeledField("Every") { IntField(value: $every, range: 1...1440, step: 5, unit: "minutes") }
                case "daily":
                    LabeledField("At") { TimeField(minutes: $clock) }
                case "weekly":
                    LabeledField("Days") { WeekdayPicker(days: $days) }
                    LabeledField("At") { TimeField(minutes: $clock) }
                default:
                    LabeledField("Cron") { TextField("m h dom mon dow", text: $cron).font(Theme.mono) }
                }
                if trigger != "at" {
                    LabeledField("Vary the time") { IntField(value: $jitter, range: 0...180, step: 5, unit: "± minutes, so it never lands on the same second") }
                }
            }
            Panel(title: "Where") {
                LabeledField("Folder") { FolderField(path: $dir) }
                if !model.vmNames.isEmpty {
                    LabeledField("Runs on") {
                        Picker("", selection: $vm) {
                            Text("this Mac").tag("")
                            ForEach(model.vmNames, id: \.self) { Text("VM \($0)").tag($0) }
                        }
                        .labelsHidden().pickerStyle(.menu).frame(maxWidth: 240)
                    }
                }
            }
            if !problem.isEmpty {
                Text(problem).font(Theme.caption).foregroundStyle(Theme.danger)
            }
        } buttons: {
            Spacer()
            Button("Cancel") { done() }.keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || target.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear(perform: load)
    }

    private func load() {
        if existing == nil, let presetKind {
            kind = presetKind
            target = presetTarget ?? ""
            name = presetName ?? ""
        }
        guard let s = existing else { return }
        name = s.name
        kind = s.kind == .flow ? "do" : s.kind.rawValue
        target = s.target
        agent = s.agent ?? AgentCLIs.defaultID
        if let d = s.at { trigger = "at"; at = d }
        if let v = s.every { trigger = "every"; every = v }
        if let v = s.daily, let m = Schedules.timeOfDay(v) { trigger = "daily"; clock = m }
        if let v = s.weekly, let parsed = WeekTime.parseWeekly(v) { trigger = "weekly"; days = parsed.days; clock = parsed.minutes }
        if let v = s.cron { trigger = "cron"; cron = v }
        jitter = s.jitter
        dir = s.dir.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
        vm = s.vm ?? ""
    }

    private func save() {
        if trigger == "weekly", days.isEmpty { problem = "choose at least one day"; return }
        var args = ["add", name]
        if let existing { args += ["--id", existing.id] }
        switch trigger {
        case "at": args += ["--at", Schedules.stamp(at)]
        case "every": args += ["--every", "\(every)"]
        case "daily": args += ["--daily", WeekTime.clock(clock)]
        case "weekly": args += ["--weekly", WeekTime.weekly(days: days, minutes: clock)]
        default: args += ["--cron", cron]
        }
        args += ["--\(kind)", target]
        if kind == "prompt" { args += ["--agent", agent] }
        args += ["--jitter", "\(trigger == "at" ? 0 : jitter)"]
        if !dir.isEmpty { args += ["--dir", (dir as NSString).expandingTildeInPath] }
        if !vm.isEmpty { args += ["--vm", vm] }
        model.act("schedule", args)
        done()
    }
}

// MARK: - Playbooks

/// A new skill of yours: a website, a Mac app, a kind of task or a rule for everywhere, and what you know
/// about it. Written in `Skills.yoursDir` in the skill format, so `session` picks it up at once.
struct NewPlaybookSheet: View {
    @ObservedObject var model: AppModel
    var done: (String?) -> Void
    @State private var scope = "site"
    @State private var match = ""
    @State private var title = ""
    @State private var notes = ""
    @State private var problem = ""

    /// What the playbook is for: where it lives, what `match` and `scope` it gets, and how agents find it.
    private struct Kind {
        let id: String
        let label: String
        let folder: String
        let scope: String
        let field: String
        let example: String
        let how: String
    }

    private static let kinds = [
        Kind(id: "site", label: "A website", folder: "web", scope: "site", field: "Website", example: "example.com",
             how: "Agents see it each time they open this website."),
        Kind(id: "app", label: "A Mac app", folder: "macos", scope: "app", field: "App", example: "Finder",
             how: "Agents see it each time they open this app."),
        Kind(id: "task", label: "A kind of task", folder: "topics", scope: "topic", field: "Task", example: "writing invoices",
             how: "Agents find it when their task mentions these words."),
        Kind(id: "everywhere", label: "Everywhere", folder: "general", scope: "system", field: "", example: "",
             how: "Every agent reads it, every time, whatever it opens."),
    ]

    private var kind: Kind { Self.kinds.first { $0.id == scope } ?? Self.kinds[0] }

    private var slug: String {
        let source = kind.field.isEmpty ? title : match
        let base = source.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
        let kept = base.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "-" }
        return String(kept).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    }

    private var path: String { kind.folder + "/" + slug + ".md" }

    var body: some View {
        SheetFrame(title: "New skill", subtitle: "What an agent should know. It stays on this Mac. No names, handles or anything personal.", idealHeight: 600) {
            Panel(title: "It is for") {
                LabeledField("Kind") {
                    Picker("", selection: $scope) {
                        ForEach(Self.kinds, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .labelsHidden().pickerStyle(.segmented)
                }
                LabeledField("") {
                    Text(kind.how).font(Theme.caption).foregroundStyle(.secondary)
                }
                if !kind.field.isEmpty {
                    LabeledField(kind.field) { TextField(kind.example, text: $match) }
                }
                LabeledField("Title") {
                    TextField(kind.id == "everywhere" ? "How I like things done" : "A few words, for the list", text: $title)
                }
            }
            Panel(title: kind.id == "everywhere" ? "Rules" : "Key facts", note: "one per line") {
                TextField(kind.id == "everywhere" ? "Always ask before posting anything public…" : "Where things are, what works, what to avoid…",
                          text: $notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(6...16)
                    .font(Theme.body)
            }
            if !problem.isEmpty { Text(problem).font(Theme.caption).foregroundStyle(Theme.danger) }
            if !slug.isEmpty {
                Text("saved as \((Skills.yoursDir.appendingPathComponent(path).path as NSString).abbreviatingWithTildeInPath)").font(Theme.monoSmall).foregroundStyle(.tertiary)
            }
        } buttons: {
            Spacer()
            Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
            Button("Create") { create() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(slug.isEmpty)
        }
    }

    static func text(scope: String, match: String, title: String, notes: String, day: String, tags: String = "") -> String {
        let facts = notes.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.map { "- " + ($0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0) }
        let heading = title.trimmingCharacters(in: .whitespaces).isEmpty ? match : title.trimmingCharacters(in: .whitespaces)
        return """
        ---
        scope: \(scope)
        match: \(match)
        tags: \(tags)
        lang: en
        verified: \(day)
        status: draft
        ---
        # \(heading)

        ## Key facts
        \(facts.joined(separator: "\n"))

        ## Works

        ## Fails

        """
    }

    private func create() {
        let typed = match.trimmingCharacters(in: .whitespaces)
        let (matchValue, tags, heading): (String, String, String) = {
            switch kind.id {
            // A task is found by its words (`playbooks "words"`), not by a window.
            case "task": return ("", Playbooks.slugify(typed).replacingOccurrences(of: "-", with: ", "), title.isEmpty ? typed : title)
            case "everywhere": return ("*", "", title)
            default: return (typed, "", title)
            }
        }()
        let body = Self.text(scope: kind.scope, match: matchValue, title: heading, notes: notes, day: Store.day(), tags: tags)
        let leaks = Playbooks.leaks(body)
        guard leaks.isEmpty else { problem = "looks personal (\(leaks.prefix(2).joined(separator: "; "))). Use {placeholders}."; return }
        let url = Skills.yoursDir.appendingPathComponent(path)
        guard !FileManager.default.fileExists(atPath: url.path) else { problem = "you already have one called \(path); choose it in the list to edit it"; return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
            done(path)
        } catch {
            problem = error.localizedDescription
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var model: AppModel
    /// Whose settings the screen shows: this Mac's (everything else falls back to them), a VM's or a project's.
    @State private var scope: Layers.Place = .mac
    /// The values set at this level, and what it would get from the levels above it, with where from.
    @State private var own: [String: String] = [:]
    @State private var inherited: [String: (value: String, from: Layers.Place)] = [:]
    @State private var status = ""

    /// Settings this level may change: a VM or a project never changes the window, updates or the menu bar.
    private var settings: [Setting] {
        scope == .mac ? Setting.shown : Setting.shown.filter { !Layers.isRootOnly($0.section, $0.key) }
    }

    private var sections: [String] {
        var seen: [String] = []
        for s in settings where !seen.contains(s.section) { seen.append(s.section) }
        return seen
    }

    /// This Mac, each VM and each project, in the order they fall back.
    private var scopes: [(place: Layers.Place, name: String)] {
        var out: [(Layers.Place, String)] = [(.mac, "This Mac, for everything")]
        if FileManager.default.fileExists(atPath: VM.key.path) { out.append((.vm(nil), "The default VM")) }
        out += model.vmNames.map { (.vm($0), "The VM \($0)") }
        out += model.projects.map { (.project($0.folder.appendingPathComponent(".apprentice")), "The project \($0.name)") }
        return out
    }

    private var file: URL { Layers.file("config.toml", scope) }

    var body: some View {
        ScreenPage(title: Section.settings.label, subtitle: "") {
            AnyView(
                HStack(spacing: Theme.s2) {
                    if !status.isEmpty { Text(status).font(Theme.caption).foregroundStyle(.secondary) }
                    IconButton("Open the settings file", "doc.text") { open() }
                }
            )
        } content: {
            Explainer(.settings)
            if scopes.count > 1 {
                Panel(title: "Settings for") {
                    Picker("", selection: $scope) {
                        ForEach(scopes, id: \.place) { Text($0.name).tag($0.place) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(maxWidth: 320, alignment: .leading)
                }
            }
            if scope == .mac { AccountCard(model: model) }
            ForEach(sections, id: \.self) { section in
                Panel(title: Setting.title(section)) {
                    let rows = settings.filter { $0.section == section }
                    ForEach(rows) { setting in
                        SettingRow(setting: setting, value: Binding(
                            get: { own[setting.id] ?? inherited[setting.id]?.value ?? Toml.unquote(setting.fallback) },
                            set: { new in write(setting, new) }),
                                   from: own[setting.id] != nil || scope == .mac ? nil : inherited[setting.id]?.from ?? .mac,
                                   reset: scope == .mac || own[setting.id] == nil ? nil : { reset(setting) },
                                   parent: Layers.parents(of: scope).first)
                        if setting.id != rows.last?.id { Divider() }
                    }
                }
            }
            Text(file.path).font(Theme.monoSmall).foregroundStyle(.tertiary)
        }
        .onAppear(perform: load)
        .onChange(of: scope) { _ in load() }
    }

    private func load() {
        let mine = Toml.parse(Layers.read("config.toml", scope) ?? "")
        var from: [String: (String, Layers.Place)] = [:]
        // The nearest level above that sets a key is the one this level gets it from.
        for place in Layers.parents(of: scope).reversed() {
            let table = Toml.parse(Layers.read("config.toml", place) ?? "")
            for s in Setting.shown { if let v = table[s.section]?[s.key] { from[s.id] = (Toml.unquote(v), place) } }
        }
        var out: [String: String] = [:]
        for s in Setting.shown { if let v = mine[s.section]?[s.key] { out[s.id] = Toml.unquote(v) } }
        own = out
        inherited = from.mapValues { (value: $0.0, from: $0.1) }
    }

    private func write(_ setting: Setting, _ shown: String) {
        if scope == .mac { AppModel.backup(file) }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = Toml.set(file, setting.section, setting.key, setting.literal(shown))
        own[setting.id] = shown
        saved()
    }

    /// Drops this level's own value, so the one above applies again.
    private func reset(_ setting: Setting) {
        Toml.remove(file, setting.section, setting.key)
        own[setting.id] = nil
        saved()
    }

    private func saved() {
        Config.reloadIfChanged()
        AppLook.apply()
        status = "saved"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if status == "saved" { status = "" } }
    }

    /// A level's file may not exist until something is set there; opening it makes it, with a line saying what it is.
    private func open() {
        if !FileManager.default.fileExists(atPath: file.path) {
            try? Layers.write("config.toml", "# Settings for \(scope.label). Anything not set here comes from the level above.\n", scope)
        }
        NSWorkspace.shared.open(file)
    }
}

private struct SettingRow: View {
    let setting: Setting
    @Binding var value: String
    /// The level the value comes from when this one does not set it.
    var from: Layers.Place?
    /// Drops this level's own value; nil when it has none, or on this Mac.
    var reset: (() -> Void)?
    var parent: Layers.Place?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.s4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(setting.label).font(Theme.body)
                if !setting.help.isEmpty {
                    Text(setting.help).font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let from {
                    Text("From \(from.label)").font(Theme.caption).foregroundStyle(.tertiary)
                } else if let reset, let parent {
                    Button("Set here · use \(parent.label)'s instead", action: reset)
                        .buttonStyle(.link).font(Theme.caption)
                }
            }
            Spacer(minLength: Theme.s3)
            control
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var control: some View {
        switch setting.kind {
        case .toggle:
            Toggle("", isOn: Binding(get: { value == "true" }, set: { value = $0 ? "true" : "false" }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
        case .number(let range):
            IntField(value: Binding(get: { Int(value) ?? range.lowerBound }, set: { value = "\($0)" }), range: range)
        case .choice(let choices):
            Picker("", selection: Binding(get: { choices.contains(value) ? value : choices[0] }, set: { value = $0 })) {
                ForEach(choices, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 200)
        case .text:
            TextField("", text: $value).textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 200)
        case .font:
            let families = AppLook.monospacedFamilies
            Picker("", selection: Binding(get: { families.contains(value) ? value : AppLook.system }, set: { value = $0 })) {
                ForEach(families, id: \.self) { Text($0).font(.custom($0, size: 12)).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 200)
        }
    }
}

/// The GitHub account on this Mac. Every button runs `account`, as a script would: `login --start` for the
/// code, `login --wait` until it is entered on GitHub, `--cancel`, `status` and `logout`. The token never
/// reaches the window, only the login it belongs to.
struct AccountCard: View {
    @ObservedObject var model: AppModel
    /// Settings and projects go to the user's own private repos (`Sync`), on by default once signed in.
    @State private var syncOn = Sync.on
    @State private var code: String?
    @State private var url: URL?
    @State private var note = ""

    var body: some View {
        Panel(title: "GitHub account") {
            if let account = model.account {
                HStack(alignment: .firstTextBaseline, spacing: Theme.s3) {
                    Text("@\(account.login)").font(Theme.mono)
                    if let name = account.name { Text(name).font(Theme.body).foregroundStyle(.secondary) }
                    Text("since \(Date(timeIntervalSince1970: account.since).formatted(date: .abbreviated, time: .omitted))")
                        .font(Theme.caption).foregroundStyle(.tertiary)
                }
            } else if let code {
                VStack(alignment: .leading, spacing: Theme.s2) {
                    Text("Enter this code on GitHub, then come back here.").font(Theme.body)
                    HStack(spacing: Theme.s3) {
                        Text(code)
                            .font(.system(size: 24, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        }
                        if let url { Button("Open GitHub") { NSWorkspace.shared.open(url) } }
                    }
                    .controlSize(.small)
                    HStack(spacing: Theme.s2) {
                        ProgressView().controlSize(.small)
                        Text("waiting for GitHub…").font(Theme.monoSmall).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Sign in with GitHub. The token stays in your Keychain on this Mac, and agents never see it.")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !note.isEmpty { Output(text: note) }
            HStack(spacing: Theme.s2) {
                if model.account != nil {
                    Toggle("Keep my settings and projects on GitHub", isOn: Binding(get: { syncOn }, set: { on in
                        syncOn = on
                        model.run("sync", [on ? "on" : "off"]) { _, out in note = out; syncOn = Sync.on }
                    }))
                    .toggleStyle(.switch)
                    Button("Sync now") { note = "syncing…"; model.run("sync", ["now"]) { _, out in note = out } }
                    Button("Check") { model.run("account", ["status"]) { _, out in note = out } }
                    Button("Sign out", role: .destructive) {
                        model.run("account", ["logout"]) { _, out in note = out; model.refresh() }
                    }
                } else if code != nil {
                    Button("Cancel") { model.run("account", ["login", "--cancel"]) { _, _ in } }
                } else {
                    Button("Sign in with GitHub") { signIn() }.buttonStyle(.borderedProminent)
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

// MARK: - Updates

/// The one-line notice across the top of the window when the DMG's app has a newer release.
struct UpdateBanner: View {
    @ObservedObject var model: AppModel
    let latest: Release.Latest

    var body: some View {
        HStack(spacing: Theme.s3) {
            Text("apprentice \(latest.version) is available").font(Theme.body.weight(.semibold))
            Text("you have \(Build.number)").font(Theme.monoSmall).foregroundStyle(.secondary)
            Spacer()
            if model.updateStep.isEmpty {
                if let page = latest.page.flatMap(URL.init(string:)) {
                    Button("What's new") { NSWorkspace.shared.open(page) }.buttonStyle(.link)
                }
                Button("Install and relaunch") { model.installUpdate() }.buttonStyle(.borderedProminent)
            } else {
                ProgressView().controlSize(.small)
                Text(model.updateStep).font(Theme.monoSmall).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s2)
        .background(Theme.accent.opacity(0.10))
    }
}

struct UpdatesView: View {
    @ObservedObject var model: AppModel
    @State private var checks = ""

    var body: some View {
        ScreenPage(title: Section.updates.label, subtitle: "") {
            AnyView(IconButton("Check again", "arrow.clockwise") { load() })
        } content: {
            Explainer(.updates)
            Panel(title: "Installed") {
                FieldRow(label: "version", value: Build.version, mono: true)
                if Release.isRelease, !Release.cloneInstalled {
                    FieldRow(label: "updates", value: model.update.map { "\($0.version) is available" } ?? "none waiting; checked against GitHub releases",
                             mono: true, tint: model.update == nil ? .secondary : Theme.warn)
                    HStack(spacing: Theme.s2) {
                        if model.update != nil {
                            Button("Install and relaunch") { model.installUpdate() }
                                .buttonStyle(.borderedProminent)
                                .disabled(!model.updateStep.isEmpty)
                        }
                        Button("Check for updates") { model.checkRelease(force: true) }
                        Button("Reconnect agents") {
                            checks = "connecting…"
                            DispatchQueue.global(qos: .userInitiated).async {
                                let note = Release.connectAgents() ?? "nothing to connect"
                                DispatchQueue.main.async { checks = note }
                            }
                        }
                    }
                    .controlSize(.small)
                } else {
                    if let install = Build.install {
                        FieldRow(label: "clone", value: install.clone, mono: true, tint: .secondary)
                        FieldRow(label: "built", value: install.built ?? "?", mono: true, tint: .secondary)
                    }
                    HStack(spacing: Theme.s2) {
                        Button("Update now") { checks = "updating…"; model.run("update") { _, out in checks = out } }
                        Button("Check for updates") { model.run("update", ["--check"]) { _, out in checks = out } }
                    }
                    .controlSize(.small)
                }
            }
            if !checks.isEmpty {
                Panel(title: "Result") { Output(text: checks) }
            }
            GrantsPanel(model: model)
        }
    }

    private func load() {
        if Release.isRelease, !Release.cloneInstalled { checks = ""; model.checkRelease(force: true) }
        else { model.run("update", ["--check"]) { _, out in checks = out } }
    }
}

/// The two macOS permissions, each with what it is for and one button while it is off. Everything else
/// `doctor` prints is for the terminal: a person can do nothing with a signature or a PATH line.
struct GrantsPanel: View {
    @ObservedObject var model: AppModel
    @State private var accessibility: Bool?
    @State private var screen: Bool?
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    /// A switch left on for an older copy of apprentice does not count for this one.
    static let staleHint = "Already on in System Settings? That switch is for an older copy: select apprentice there, remove it with −, then click Open System Settings and switch the new one on."

    var body: some View {
        Panel(title: "Permissions") {
            row("Accessibility", "Lets apprentice see a window's buttons and fields, and move the cursor and type for you.",
                on: accessibility, ask: "accessibility")
            row("Screen Recording", "For screenshots and reading text that has no label. Nothing leaves this Mac.",
                on: screen, ask: "screen")
        }
        .onAppear(perform: check)
        .onReceive(tick) { _ in if accessibility != true || screen != true { check() } }
    }

    @ViewBuilder private func row(_ title: String, _ why: String, on: Bool?, ask: String) -> some View {
        HStack(alignment: .top, spacing: Theme.s3) {
            Image(systemName: on == true ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(on == true ? Theme.accent : Theme.warn)
            VStack(alignment: .leading, spacing: 3) {
                Text(title + (on == nil ? "" : on! ? ": on" : ": off")).font(Theme.heading)
                Text(why).font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if on == false {
                    Text(GrantsPanel.staleHint).font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if on == false {
                Button("Open System Settings") { model.run("doctor", ["--ask", ask]) { _, _ in } }.controlSize(.small)
            }
        }
    }

    /// A fresh CLI process each time: a grant does not show in a process that started before it.
    private func check() {
        model.run("doctor", ["--grants"]) { _, out in
            let a = out.contains("accessibility=true"), s = out.contains("screen=true")
            // A daemon started before a grant does not see it; the next command starts a new one.
            if (accessibility == false && a) || (screen == false && s) {
                DispatchQueue.global(qos: .utility).async { _ = Wire.stopDaemon() }
            }
            accessibility = a
            screen = s
        }
    }
}

// MARK: - Welcome

/// What a first run needs, without the terminal: sign in to GitHub, then the two grants the CLI and daemon
/// need. The grants belong to the CLI (`Contents/Helpers` in the release app), not this window, so each
/// step runs `doctor --ask` through it and the check marks come from `doctor --grants`, which asks a fresh
/// process that answers for itself (`Own`): a child of this window would report the window's grant. "Later" comes back next launch; "Done" does not.
enum Welcome {
    static var done: Bool { FileManager.default.fileExists(atPath: Store.url("welcome-done").path) }
    static func finish() { FileManager.default.createFile(atPath: Store.url("welcome-done").path, contents: Data()) }
}

struct WelcomeView: View {
    @ObservedObject var model: AppModel
    @State private var accessibility = false
    @State private var screen = false
    @State private var granted: String?
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s5) {
            VStack(alignment: .leading, spacing: Theme.s1) {
                Text("Welcome to apprentice").font(Theme.title(20))
                Text("Three steps and it is ready. Each can wait: Settings and Updates have them too.")
                    .font(Theme.body).foregroundStyle(.secondary)
            }
            step(1, "Sign in with GitHub", done: model.account != nil) {
                AccountCard(model: model)
            }
            step(2, "Let apprentice read the screen", done: accessibility) {
                grant("Accessibility lets apprentice see a window's buttons and fields, and move the cursor and type for you.",
                      ask: "accessibility", done: accessibility)
            }
            step(3, "Let apprentice see what is drawn", done: screen) {
                grant("Screen Recording is for screenshots and reading text that has no label. Nothing leaves this Mac.",
                      ask: "screen", done: screen)
            }
            Text("Agents run in this window's Terminal tabs with apprentice already wired in. Help, in the toolbar, answers questions.")
                .font(Theme.caption).foregroundStyle(.secondary)
            HStack {
                Button("Later") { model.welcomeOpen = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.account != nil && accessibility && screen ? "Start" : "Done for now") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.s5)
        .frame(width: 560)
        .onAppear(perform: check)
        .onReceive(tick) { _ in check() }
    }

    private func step<Content: View>(_ n: Int, _ title: String, done: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: Theme.s3) {
            Text(done ? "✓" : "\(n)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(done ? Theme.accent : .secondary)
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(done ? Theme.accent : Theme.hairline))
            VStack(alignment: .leading, spacing: Theme.s2) {
                Text(title).font(Theme.heading)
                content()
            }
        }
    }

    @ViewBuilder private func grant(_ why: String, ask: String, done: Bool) -> some View {
        Text(why)
            .font(Theme.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if !done {
            Text(GrantsPanel.staleHint).font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") { model.run("doctor", ["--ask", ask]) { _, _ in } }
                .controlSize(.small)
        }
    }

    /// A fresh CLI process each time: a grant does not show in a process that started before it.
    private func check() {
        model.run("doctor", ["--grants"]) { _, out in
            accessibility = out.contains("accessibility=true")
            screen = out.contains("screen=true")
            if granted == nil { granted = out }
        }
    }

    private func finish() {
        Welcome.finish()
        model.welcomeOpen = false
        // A daemon started before the grants does not see them; the next command starts a new one.
        if let before = granted, before != "accessibility=\(accessibility) screen=\(screen)" {
            DispatchQueue.global(qos: .utility).async { _ = Wire.stopDaemon() }
        }
    }
}

// MARK: - Command palette

struct CommandPalette: View {
    @ObservedObject var model: AppModel
    @State private var output = ""
    /// Taken once, when it opens: it never resizes while you type.
    @State private var width = SheetSize.width(ideal: 640)

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            VStack(alignment: .leading, spacing: Theme.s1) {
                Text("Run a command").font(Theme.title(17))
                Text("Type any apprentice command, as you would in a tab.").font(Theme.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: Theme.s2) {
                Text("apprentice").font(Theme.mono).foregroundStyle(.secondary)
                TextField("schedule list", text: $model.paletteText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit(run)
            }
            .padding(.horizontal, Theme.s3)
            .padding(.vertical, Theme.s3)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.hairline))
            ScrollView {
                Output(text: output, placeholder: "output appears here")
                    .padding(Theme.s3)
            }
            .frame(height: 260)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.hairline))
            HStack {
                Text("Return runs · Esc closes").font(Theme.monoSmall).foregroundStyle(.tertiary)
                Spacer()
                Button("Close") { model.paletteOpen = false }.keyboardShortcut(.cancelAction)
                Button("Run", action: run)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.s5)
        .frame(width: width)
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
