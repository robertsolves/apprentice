import AppKit

/// One small app per VM ("apprentice VM", with the VM's name when it is not the default): its own Dock icon, which
/// shows that VM's state (grey waiting, orange needs you, green running), and a window with a picture of the VM's
/// screen and its pointer. Each is the apprentice binary in a bundle of its own (`Dock/` in the state folder),
/// started with `open`; `Store.vmName` reaches it through the bundle's environment. It talks to the VM through its
/// own connection, so watching never slows the agent. To click or type in the VM, `apprentice vm look` opens
/// Screen Sharing.
enum VMDock {
    static let prefix = "com.apprentice.vm."
    private static var key: String { Store.vmName ?? "mac" }

    // MARK: - the daemon's side

    /// Opens (making it first when needed) this VM's app. `activate: false` leaves it behind the person's work.
    static func open(activate: Bool = true) {
        // `vm watch` runs in the CLI, which exits as soon as it returns: there the work is done before it does.
        let work = {
            let key = Store.vmName ?? "mac"
            let label = "apprentice VM" + (Store.vmName.map { " \($0)" } ?? "")
            let app = Store.dir.appendingPathComponent("Dock/\(label).app")
            let id = prefix + key
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first
            if running == nil, let exe = Bundle.main.executablePath {
                let real = URL(fileURLWithPath: exe).resolvingSymlinksInPath().path
                let made = (try? FileManager.default.attributesOfItem(atPath: app.appendingPathComponent("Contents/MacOS/apprentice").path))?[.modificationDate] as? Date
                let built = (try? FileManager.default.attributesOfItem(atPath: real))?[.modificationDate] as? Date
                // Made again only when the app's binary is newer; never while it runs, which would break its signature.
                if made == nil || (built.map { $0 > made! } ?? false) {
                    try? FileManager.default.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let env = Store.vmName.map { ["APPRENTICE_VM": $0] } ?? [:]
                    // Drawn on the main thread, as the icon is made with AppKit drawing.
                    let make = { _ = AppBundle.build(at: app, from: real, identifier: id, name: label, environment: env) }
                    if Thread.isMainThread { make() } else { DispatchQueue.main.sync(execute: make) }
                }
            }
            if let running { running.activate() ; return }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = activate
            let done = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: app, configuration: config) { _, _ in done.signal() }
            _ = Thread.isMainThread ? done.wait(timeout: .now() + 5) : .success
        }
        if Thread.isMainThread { work() } else { DispatchQueue.global().async(execute: work) }
    }

    // MARK: - the app's side

    private static let image = NSImageView()
    private static let queue = DispatchQueue(label: "apprentice.vmdock")
    private static var fetching = false
    private static var lastTile = ""
    private static var window: NSWindow?

    private final class Delegate: NSObject, NSApplicationDelegate {
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
        func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
            VMDock.window?.makeKeyAndOrderFront(nil)
            return true
        }
    }
    private static let delegate = Delegate()

    static func run() -> Never {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.applicationIconImage = Ask.icon
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "apprentice VM" + (Store.vmName.map { " · \($0)" } ?? "")
        w.isReleasedWhenClosed = false
        w.contentAspectRatio = NSSize(width: 1280, height: 800)
        image.imageScaling = .scaleProportionallyUpOrDown
        w.contentView = image
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        paint()
        let t = Timer(timeInterval: 0.8, repeats: true) { _ in refresh(); paint() }
        RunLoop.main.add(t, forMode: .common)
        app.run()
        exit(0)
    }

    /// The Dock icon: the apprentice mark with a dot for this VM's state, read from the daemons' rows.
    private static func paint() {
        let row = Overlay.liveRows().first { $0.key == key && $0.inVM }
        let level: Int
        switch row?.head {
        case "Needs approval", "Waiting for you", "Stopped", "Agent stopped", "Paused": level = 2
        case "Working", "Yours": level = 1
        default: level = 0
        }
        guard "\(level)" != lastTile else { return }
        lastTile = "\(level)"
        let color: NSColor = [NSColor.systemGray, .systemGreen, .systemOrange][level]
        NSApp.applicationIconImage = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            Ask.icon.draw(in: rect.insetBy(dx: 6, dy: 6))
            let dot = NSRect(x: 84, y: 8, width: 36, height: 36)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: dot.insetBy(dx: -4, dy: -4)).fill()
            color.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        NSApp.dockTile.badgeLabel = "VM"
    }

    private static func refresh() {
        guard let w = window, w.isVisible, !w.isMiniaturized, !fetching else { return }
        fetching = true
        queue.async {
            let frame = try? Remote.screen()
            let c = try? Remote.query(["op": "cursor"])
            let point = CGPoint(x: (c?["x"] as? Double) ?? Remote.cursor.x, y: (c?["y"] as? Double) ?? Remote.cursor.y)
            DispatchQueue.main.async {
                fetching = false
                guard let frame else { return }
                image.image = draw(frame, point)
            }
        }
    }

    /// The frame with a blue arrow and a soft ring at the pointer, easy to follow.
    private static func draw(_ frame: CGImage, _ p: CGPoint) -> NSImage {
        NSImage(size: NSSize(width: frame.width, height: frame.height), flipped: true) { rect in
            NSGraphicsContext.current?.cgContext.saveGState()
            NSGraphicsContext.current?.cgContext.translateBy(x: 0, y: rect.height)
            NSGraphicsContext.current?.cgContext.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current?.cgContext.draw(frame, in: rect)
            NSGraphicsContext.current?.cgContext.restoreGState()
            NSColor.systemBlue.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 20, y: p.y - 20, width: 40, height: 40)).fill()
            let arrow = NSBezierPath()
            arrow.move(to: p)
            for (dx, dy) in [(0.0, 24.0), (6, 18), (12, 30), (17, 27), (11, 16), (19, 16)] { arrow.line(to: NSPoint(x: p.x + dx, y: p.y + dy)) }
            arrow.close()
            NSColor.white.setStroke()
            arrow.lineWidth = 3
            arrow.stroke()
            NSColor.systemBlue.setFill()
            arrow.fill()
            return true
        }
    }
}
