import AppKit

/// The user can hold apprentice still from the overlay: new actions wait here until they resume.
enum Pause {
    static var on = false

    /// Blocks an action about to start until the person resumes; the kill switch or a stop ends the wait.
    static func wait() {
        while on && !KillSwitch.tripped { Thread.sleep(forTimeInterval: 0.2) }
    }
}

/// A small always-on-top box that says what apprentice is doing: working, handed to you while you move
/// the mouse or type, taking over again once you have been still, paused, or idle. Closing it asks first,
/// then stops apprentice. `[agent] overlay = false` hides it.
enum Overlay {
    /// Seconds the person must be still before apprentice takes over again (`Borrow.waitIdle`'s default).
    static let settle = 1.0
    /// How long after a command the session still counts as engaged, so a move between two commands reads as a hand-off.
    private static let engagedFor: TimeInterval = 20

    private static var panel: NSPanel?
    private static var dot = NSTextField(labelWithString: "●")
    private static var title = NSTextField(labelWithString: "")
    private static var detail = NSTextField(labelWithString: "")
    private static let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    private static let handler = Handler()
    private static var timer: Timer?

    /// On the main thread, once the daemon starts.
    static func install() {
        guard Config.current.overlay, panel == nil else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 74),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        p.title = "apprentice" + (Store.vmName.map { " · \($0)" } ?? "")
        p.level = .floating
        // On every Space and above a full-screen app, never taking focus from the work.
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.delegate = handler
        // The close button asks first (`windowShouldClose`); the panel itself stays until apprentice stops.
        dot.font = .systemFont(ofSize: 18)
        title.font = .boldSystemFont(ofSize: 13)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        pauseButton.target = handler
        pauseButton.action = #selector(Handler.togglePause)
        pauseButton.bezelStyle = .rounded
        pauseButton.controlSize = .small
        pauseButton.setContentHuggingPriority(.required, for: .horizontal)

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [dot, text, pauseButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        p.contentView = row
        p.setContentSize(row.fittingSize.width < 280 ? NSSize(width: 280, height: row.fittingSize.height) : row.fittingSize)
        if let screen = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: screen.maxX - p.frame.width - 16, y: screen.maxY - p.frame.height - 12))
        }
        p.orderFrontRegardless()
        panel = p
        render()
        let t = Timer(timeInterval: 0.25, repeats: true) { _ in render() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static func render() {
        let (color, head, sub, label) = status()
        dot.textColor = color
        title.stringValue = head
        detail.stringValue = sub
        pauseButton.title = label
        panel?.orderFrontRegardless()
    }

    private static func status() -> (NSColor, String, String, String) {
        let working = StatusItem.state == .working
        let engaged = working || Date().timeIntervalSince(Commands.lastAt) < engagedFor
        let wait = max(0, settle - Borrow.humanIdle)
        if Pause.on {
            return (.systemOrange, "Paused", working ? "Finishing this step, then holding" : "Nothing will happen until you resume", "Resume")
        }
        if KillSwitch.halted { return (.systemRed, "Stopped", "Kill switch pressed; answer or resume to go on", "Pause") }
        switch StatusItem.state {
        case .waiting: return (.systemYellow, "Waiting for you", "A question is open", "Pause")
        case .approval: return (.systemYellow, "Needs approval", "Approve or deny from the menu bar", "Pause")
        default: break
        }
        if engaged && wait > 0 {
            return (.systemBlue, "Yours", String(format: "You have control · back after %.0f s of stillness", wait.rounded(.up)), "Pause")
        }
        if working { return (.systemGreen, "Working", Session.stored.map { hostOf($0.url) ?? $0.app } ?? "Acting on screen", "Pause") }
        return (.systemGray, "Ready", "Waiting for the next command", "Pause")
    }

    private final class Handler: NSObject, NSWindowDelegate {
        @objc func togglePause() {
            Pause.on.toggle()
            Store.log(["overlay": Pause.on ? "pause" : "resume", "by": "user"])
            Overlay.render()
        }

        /// Never closes by itself: confirms, then stops apprentice, which takes the panel with it.
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            let alert = NSAlert()
            alert.messageText = "Stop apprentice?"
            alert.informativeText = "It will end the current task and quit. Anything an agent is waiting on stops with it."
            alert.addButton(withTitle: "Stop apprentice")
            alert.addButton(withTitle: "Keep running")
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                Store.log(["overlay": "stop", "by": "user"])
                Pause.on = false
                KillSwitch.tripped = true
                DispatchQueue.global().async { Wire.stopVMDaemons(); _ = Wire.stopDaemon() }
            }
            return false
        }
    }
}
