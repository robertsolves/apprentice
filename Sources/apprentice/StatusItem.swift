import AppKit

/// The menu-bar item, so an agent at work, one waiting for the user and one holding a proposal no longer
/// all look like an idle Mac. Its menu shows the session, approves or denies the pending step, opens the
/// session's log and stops apprentice. `[agent] menu_bar = false` turns it off.
enum StatusItem {
    enum State: String {
        case idle = "idle"
        case working = "working"
        case waiting = "waiting for you"
        case approval = "needs approval"
    }

    private static var item: NSStatusItem?
    private static var working = false
    private static var questions = 0
    private static let menu = Menu()

    /// On the main thread, once the daemon starts.
    static func install() {
        guard Config.current.menuBar else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = NSMenu()
        item.menu?.delegate = menu
        self.item = item
        item.button?.imagePosition = .imageLeading
        render()
    }

    /// From any thread: a command started or finished.
    static func busy(_ on: Bool) {
        DispatchQueue.main.async {
            working = on
            render()
        }
    }

    /// On the main thread: a question window opened or closed.
    static func asking(_ on: Bool) {
        questions = max(0, questions + (on ? 1 : -1))
        render()
    }

    static var state: State {
        if questions > 0 { return .waiting }
        if Approvals.pending != nil { return .approval }
        return working ? .working : .idle
    }

    /// The apprentice mark as a line drawing in the menu bar's own text colour (so it suits light and dark bars),
    /// with a small dot for the state: grey idle, green working, yellow waiting for you, orange needs approval.
    private static func tray(_ state: State) -> NSImage {
        NSImage(size: NSSize(width: 20, height: 18), flipped: true) { _ in
            let s: CGFloat = 16 / 64
            let a = NSBezierPath()
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: 1 + x * s, y: 1 + y * s) }
            a.move(to: p(45.5, 20))
            a.curve(to: p(27, 44), controlPoint1: p(42, 32), controlPoint2: p(37.5, 44))
            a.curve(to: p(16.5, 33), controlPoint1: p(20.5, 44), controlPoint2: p(16.5, 39))
            a.curve(to: p(27, 22), controlPoint1: p(16.5, 27), controlPoint2: p(20.5, 22))
            a.curve(to: p(45.5, 44), controlPoint1: p(37.5, 22), controlPoint2: p(42, 34))
            a.lineWidth = 2.1
            a.lineCapStyle = .round
            a.lineJoinStyle = .round
            NSColor.labelColor.setStroke()
            a.stroke()
            let color: NSColor = switch state {
            case .idle: .systemGray
            case .working: .systemGreen
            case .waiting: .systemYellow
            case .approval: .systemOrange
            }
            let dot = NSRect(x: 12.5, y: 11, width: 6, height: 6)
            color.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
    }

    private static func render() {
        guard let button = item?.button else { return }
        button.image = tray(state)
        let marks: [State: String] = [.idle: "", .working: "", .waiting: "", .approval: ""]
        button.title = (Store.vmName.map { " \($0)" } ?? "") + (marks[state] ?? "")
        button.toolTip = "apprentice: \(state.rawValue)"
        button.setAccessibilityLabel("apprentice, \(state.rawValue)")
    }

    private final class Menu: NSObject, NSMenuDelegate {
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            var where_ = ""
            if let s = Session.stored { where_ = " · " + (hostOf(s.url) ?? s.app) }
            menu.addItem(info("apprentice \(Build.version)\(Store.vmName.map { " · VM \($0)" } ?? "") · \(StatusItem.state.rawValue)\(where_)"))
            if let p = Approvals.pending {
                menu.addItem(.separator())
                menu.addItem(info("pending: \(clip(p.summary, 70))"))
                menu.addItem(action("Approve", #selector(approve), p.token))
                menu.addItem(action("Deny", #selector(deny), p.token))
            }
            if KillSwitch.halted {
                menu.addItem(.separator())
                menu.addItem(info("Stopped by the kill switch"))
                menu.addItem(action("Resume", #selector(resume), nil))
            }
            menu.addItem(.separator())
            menu.addItem(action("Open this session's log", #selector(openLog), nil))
            menu.addItem(action("Open apprentice…", #selector(openApp), nil))
            if let n = Store.load(Repo.Notice.self, "update.json") { menu.addItem(info(clip(n.text, 90))) }
            let mute = action("Mute sounds", #selector(toggleMute), nil)
            mute.state = Sound.muted ? .on : .off
            menu.addItem(mute)
            menu.addItem(info("Kill switch: ctrl+opt+cmd+."))
            menu.addItem(action("Stop apprentice", #selector(stop), nil))
        }

        private func info(_ text: String) -> NSMenuItem {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }

        private func action(_ title: String, _ selector: Selector, _ token: String?) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.representedObject = token
            return item
        }

        /// The user's own click, like `confirm`: it runs the step on the command queue.
        @objc func approve(_ sender: NSMenuItem) { decide(sender, "approve") }
        @objc func deny(_ sender: NSMenuItem) { decide(sender, "deny") }

        private func decide(_ sender: NSMenuItem, _ cmd: String) {
            guard let token = sender.representedObject as? String else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                Store.log(["confirm": cmd, "by": "user", "via": "menu", "token": token])
                _ = try? Daemon.command(Request(cmd: cmd, args: [token]), byUser: true)
                StatusItem.busy(false)
            }
        }

        @objc func resume() {
            DispatchQueue.global(qos: .userInitiated).async { _ = try? Daemon.command(Request(cmd: "resume")) }
        }

        /// The quickest way to the window: the menu bar is always there.
        @objc func openApp() { _ = AppBundle.open() }

        @objc func toggleMute() { Sound.muted.toggle() }

        @objc func openLog() {
            let folder = Store.runFolder()
            NSWorkspace.shared.open(FileManager.default.fileExists(atPath: folder.path) ? folder : Store.dir.appendingPathComponent("runs"))
        }

        @objc func stop() {
            DispatchQueue.global().async { Wire.stopVMDaemons(); _ = Wire.stopDaemon() }
        }
    }
}

/// The daemon's Dock icon stands in for the window: while `Apprentice.app` is open the window's icon is
/// enough, so the daemon's hides, and it comes back when the window closes.
enum DockIcon {
    static var windowOpen: Bool { AppBundle.runningInstance != nil }

    /// On the main thread, once the daemon starts: follows the window's launches and exits.
    static func watch() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == AppBundle.identifier else { return }
                apply()
            }
        }
    }

    /// The setting as the file says it now: the Settings window is another process, so the daemon looks.
    static var wanted: Bool {
        (Toml.load(Config.path)["agent"]?["dock_icon"]).map { Toml.unquote($0) != "false" } ?? Config.current.dockIcon
    }

    private static var timer: Timer?

    static func apply() {
        let on = wanted
        NSApp.setActivationPolicy(on && !windowOpen ? .regular : .accessory)
        if on { NSApp.applicationIconImage = Ask.icon }
    }

    /// Follows the setting while the daemon runs, so turning the icon on or off takes effect at once.
    static func follow() {
        guard timer == nil else { return }
        var last = wanted
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            let now = wanted
            if now != last { last = now; apply() }
        }
    }
}
