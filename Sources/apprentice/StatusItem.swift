import AppKit

/// The menu-bar item, so an agent at work, one waiting for the user and one holding a proposal no longer
/// all look like an idle Mac. Its menu shows the session, approves or denies the pending step, opens the
/// window and stops apprentice. `[agent] menu_bar = false` turns it off.
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
        // Pause, a stop and the quiet of a finished task do not pass through `busy`: look again every second.
        let t = Timer(timeInterval: 1, repeats: true) { _ in render() }
        RunLoop.main.add(t, forMode: .common)
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

    private static var parkedAt = Date.distantPast
    private static var parked = false

    /// A pipeline run waiting for the user, looked at every few seconds: this runs every second.
    private static var runWaiting: Bool {
        if Date().timeIntervalSince(parkedAt) > 5 {
            parkedAt = Date()
            parked = !Runs.waiting(in: Projects.all().map(\.folder)).isEmpty
        }
        return parked
    }

    static var state: State {
        if questions > 0 || runWaiting { return .waiting }
        if Approvals.pending != nil { return .approval }
        return working ? .working : .idle
    }

    private static var shownLevel = -1

    /// This Mac's runner as three colours: grey waiting, orange needs you (a question, an approval, paused, stopped),
    /// green running or in your hands. Other systems are not in it: each VM's state and screen are on the window's VMs screen (`VMScreen`).
    private static var level: Int {
        if Pause.on || KillSwitch.halted || state == .waiting || state == .approval || Handback.banner?.good == false { return 2 }
        if state == .working || Date().timeIntervalSince(Commands.lastAt) < 20 { return 1 }
        return 0
    }

    /// The apprentice icon, the same as the app's, with a dot for the state beside it, so neither covers the other.
    private static func tray(_ level: Int) -> NSImage {
        NSImage(size: NSSize(width: 27, height: 18), flipped: false) { _ in
            Ask.icon.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            let dot = NSRect(x: 20, y: 5.5, width: 7, height: 7)
            [NSColor.systemGray, .systemGreen, .systemOrange][level].setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
    }

    private static func render() {
        guard let button = item?.button else { return }
        let now = level
        if now != shownLevel { shownLevel = now; button.image = tray(now) }
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
            menu.addItem(action("Open apprentice…", #selector(openApp), nil))
            if Overlay.installed { menu.addItem(action(Overlay.isHidden ? "Show the status box" : "Hide the status box", #selector(toggleBox), nil)) }
            if let n = Store.load(Repo.Notice.self, "update.json"), n.agentsOnly != true { menu.addItem(info(clip(n.text, 90))) }
            let mute = action("Mute sounds", #selector(toggleMute), nil)
            mute.state = Sound.muted ? .on : .off
            menu.addItem(mute)
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
        @objc func toggleBox() { Overlay.toggleHidden() }

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
