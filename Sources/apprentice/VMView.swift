import AppKit

/// The VM's screen in a window of apprentice's own ("apprentice VM"), so the pointer and typing can be watched
/// under apprentice's Dock icon instead of another app's. A picture of the guest screen about every 0.8 s with its
/// pointer drawn on it; to type or click in the VM, `apprentice vm look` still opens Screen Sharing.
enum VMView {
    private static var window: NSWindow?
    private static let image = NSImageView()
    private static var timer: Timer?
    private static var fetching = false

    static func show(activate: Bool = true) {
        DispatchQueue.main.async {
            if window == nil {
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                                 styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
                w.title = "apprentice VM" + (Store.vmName.map { " · \($0)" } ?? "")
                w.isReleasedWhenClosed = false
                w.contentAspectRatio = NSSize(width: 1280, height: 800)
                image.imageScaling = .scaleProportionallyUpOrDown
                w.contentView = image
                w.center()
                window = w
            }
            window?.makeKeyAndOrderFront(nil)
            if activate { NSApp.activate(ignoringOtherApps: true) }
            if timer == nil {
                let t = Timer(timeInterval: 0.8, repeats: true) { _ in refresh() }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
            refresh()
        }
    }

    private static func refresh() {
        guard let w = window, w.isVisible, !fetching, !w.isMiniaturized else { return }
        fetching = true
        // On the daemon's own queue: the VM connection takes one request at a time, so a frame waits for the
        // agent's current command rather than cutting into it.
        Daemon.queue.async {
            let frame = try? Remote.screen()
            let cursor = Remote.cursor
            DispatchQueue.main.async {
                fetching = false
                guard let frame else { return }
                image.image = draw(frame, cursor: cursor)
            }
        }
    }

    private static func draw(_ frame: CGImage, cursor: CGPoint) -> NSImage {
        let size = NSSize(width: frame.width, height: frame.height)
        return NSImage(size: size, flipped: true) { rect in
            NSGraphicsContext.current?.cgContext.draw(frame, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            return true
        }.withPointer(at: cursor)
    }
}

private extension NSImage {
    /// The frame with apprentice's pointer on it: a blue arrow with a white edge and a ring, easy to follow.
    func withPointer(at p: CGPoint) -> NSImage {
        let base = self
        return NSImage(size: size, flipped: true) { rect in
            base.draw(in: rect)
            let ring = NSBezierPath(ovalIn: NSRect(x: p.x - 20, y: p.y - 20, width: 40, height: 40))
            NSColor.systemBlue.withAlphaComponent(0.35).setFill()
            ring.fill()
            let arrow = NSBezierPath()
            arrow.move(to: p)
            arrow.line(to: NSPoint(x: p.x, y: p.y + 24))
            arrow.line(to: NSPoint(x: p.x + 6, y: p.y + 18))
            arrow.line(to: NSPoint(x: p.x + 12, y: p.y + 30))
            arrow.line(to: NSPoint(x: p.x + 17, y: p.y + 27))
            arrow.line(to: NSPoint(x: p.x + 11, y: p.y + 16))
            arrow.line(to: NSPoint(x: p.x + 19, y: p.y + 16))
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
