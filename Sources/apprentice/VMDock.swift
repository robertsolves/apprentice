import AppKit
import SwiftUI

/// A VM detached from the window: a small app of its own ("apprentice VM", with the VM's name when it is not the default),
/// with its own Dock icon showing that VM's state and a window on its screen. It is the apprentice binary in a bundle of
/// its own (`Dock/` in the state folder), started with `open`; `Store.vmName` reaches it through the bundle's environment.
/// Closing its window attaches the VM again: the VMs screen has shown it all along.
enum VMDock {
    static let prefix = "com.apprentice.vm."

    /// How a VM's row and its Dock icon name its state.
    enum Level: Equatable {
        case stopped, waiting, running, needsYou

        var color: NSColor {
            switch self {
            case .stopped, .waiting: return .systemGray
            case .running: return .systemGreen
            case .needsYou: return .systemOrange
            }
        }
    }

    /// What the daemon's row says the VM is doing, as a level. A VM that is off has nothing to say.
    static func level(head: String?, on: Bool) -> Level {
        guard on else { return .stopped }
        switch head {
        case "Needs approval", "Waiting for you", "Stopped", "Agent stopped", "Paused": return .needsYou
        case "Working", "Yours": return .running
        default: return .waiting
        }
    }

    /// A VM's key in the daemons' rows.
    static func key(_ name: String) -> String { name.isEmpty ? "mac" : name }

    static func level(of name: String, on: Bool) -> Level {
        level(head: Overlay.liveRows().first { $0.key == key(name) && $0.inVM }?.head, on: on)
    }

    /// What the status box says for this VM, in words: `Done · www.facebook.com`. Nil when its daemon has nothing to say.
    static func status(of name: String) -> String? {
        Overlay.liveRows().first { $0.key == key(name) && $0.inVM }.map { statusLine(head: $0.head, sub: $0.sub) }
    }

    static func statusLine(head: String, sub: String) -> String { sub.isEmpty ? head : "\(head) · \(sub)" }

    /// A detached VM's window title: which VM, then what the status box says about it.
    static func title(_ name: String, status: String?) -> String {
        "VM " + (name.isEmpty ? "default" : name) + (status.map { " — \($0)" } ?? "")
    }

    static func label(_ name: String) -> String { "apprentice VM" + (name.isEmpty ? "" : " \(name)") }

    static func running(_ name: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: prefix + key(name)).first
    }

    // MARK: - opening it

    /// Opens (making it first when needed) this VM's app, or brings it forward. The binary comes from whatever is running.
    static func open() throws {
        let name = Store.vmName ?? ""
        if let running = running(name) { running.activate(); return }
        guard let exe = Bundle.main.executablePath else { throw Fail(5, "could not find apprentice's own binary") }
        let real = URL(fileURLWithPath: exe).resolvingSymlinksInPath().path
        let app = Store.dir.appendingPathComponent("Dock/\(label(name)).app")
        let inside = app.appendingPathComponent("Contents/MacOS/apprentice").path
        let made = (try? FileManager.default.attributesOfItem(atPath: inside))?[.modificationDate] as? Date
        let built = (try? FileManager.default.attributesOfItem(atPath: real))?[.modificationDate] as? Date
        // Made again only when the binary is newer; signed as the app is, so a rebuild asks the user for nothing again.
        if made == nil || (built.map { $0 > made! } ?? false) {
            try? FileManager.default.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
            let env = Store.vmName.map { ["APPRENTICE_VM": $0] } ?? [:]
            guard AppBundle.build(at: app, from: real, identifier: prefix + key(name), name: label(name), environment: env) else {
                throw Fail(5, "could not make the VM's own app")
            }
            AppBundle.signStably(app)
        }
        let done = DispatchSemaphore(value: 0)
        var problem: Error?
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            problem = error
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
        if let problem { throw Fail(5, "could not open the VM's own app: \(problem.localizedDescription)") }
    }

    // MARK: - the app itself

    private static var window: NSWindow?
    private static var shown: Level?

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
        let name = Store.vmName ?? ""
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title(name, status: status(of: name))
        w.isReleasedWhenClosed = false
        // The screen fills the window, and the window keeps its shape.
        let view = NSHostingView(rootView: VMScreen(name: name, fills: true))
        view.sizingOptions = []
        w.contentView = view
        w.contentAspectRatio = NSSize(width: 1280, height: 800)
        w.setContentSize(NSSize(width: 1120, height: 700))
        w.center()
        w.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        window = w
        paint(name)
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            paint(name)
            let now = title(name, status: status(of: name))
            if window?.title != now { window?.title = now }
        }
        RunLoop.main.add(t, forMode: .common)
        app.run()
        exit(0)
    }

    /// The Dock icon: the apprentice mark with a dot for this VM's state. Grey waiting, green running, orange needs you.
    private static func paint(_ name: String) {
        let level = level(of: name, on: VM.running)
        guard level != shown else { return }
        shown = level
        NSApp.applicationIconImage = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            Ask.icon.draw(in: rect.insetBy(dx: 6, dy: 6))
            let dot = NSRect(x: 84, y: 8, width: 36, height: 36)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: dot.insetBy(dx: -4, dy: -4)).fill()
            level.color.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        NSApp.dockTile.badgeLabel = "VM"
    }
}
