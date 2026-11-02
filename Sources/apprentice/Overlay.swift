import AppKit

/// The user can hold apprentice still from the overlay: new actions wait here until they resume.
enum Pause {
    static var on = false

    /// Blocks an action about to start until the person resumes; the kill switch or a stop ends the wait.
    static func wait() {
        while on && !KillSwitch.tripped { Thread.sleep(forTimeInterval: 0.2) }
    }
}

/// A short system sound for each thing that happens, so the person hears it without looking.
/// `[agent] sounds = false` silences them all (`ask_sound` still sets the question ping).
enum Sound {
    private static var playing: [String: NSSound] = [:]
    private static var last: [String: Date] = [:]

    /// From any thread. The same sound is not repeated inside 0.25 s.
    static func play(_ name: String) {
        guard Config.current.sounds else { return }
        DispatchQueue.main.async {
            if let t = last[name], Date().timeIntervalSince(t) < 0.25 { return }
            last[name] = Date()
            // Held in a static: a sound released right after play() stops before it is heard.
            playing[name] = NSSound(named: NSSound.Name(name))
            playing[name]?.play()
        }
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
    private static var lastHead = ""
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
        let mark = NSImageView(image: Ask.icon)
        mark.setAccessibilityLabel("apprentice")
        mark.widthAnchor.constraint(equalToConstant: 32).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let row = NSStackView(views: [mark, dot, text, pauseButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        p.contentView = row
        row.layoutSubtreeIfNeeded()
        p.setContentSize(NSSize(width: max(row.fittingSize.width, 300), height: max(row.fittingSize.height, 52)))
        place(p)
        p.orderFrontRegardless()
        panel = p
        render()
        let t = Timer(timeInterval: 0.25, repeats: true) { _ in render() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Top right of the main screen, fully inside its visible area.
    private static func place(_ p: NSPanel) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        p.setFrameTopLeftPoint(NSPoint(x: screen.maxX - p.frame.width - 16, y: screen.maxY - 12))
    }

    /// One sound for each change of state, so a hand-off or a pause is heard as well as seen.
    private static func chime(_ head: String) {
        defer { lastHead = head }
        guard !lastHead.isEmpty, head != lastHead else { return }
        switch head {
        case "Yours": Sound.play("Funk")
        case "Paused": Sound.play("Morse")
        case "Stopped": Sound.play("Basso")
        case "Needs approval": Sound.play("Sosumi")
        case "Working" where lastHead == "Yours": Sound.play("Glass")
        case "Ready" where lastHead == "Yours": Sound.play("Glass")
        default: if lastHead == "Paused" { Sound.play("Hero") }
        }
    }

    private static func render() {
        let (color, head, sub, label) = status()
        chime(head)
        dot.textColor = color
        title.stringValue = head
        detail.stringValue = sub
        pauseButton.title = label
        if let p = panel {
            // Back on screen if a display went away or the window was dragged off.
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(p.frame) }) { place(p) }
            p.orderFrontRegardless()
        }
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
            Ask.blue(alert.window)
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
