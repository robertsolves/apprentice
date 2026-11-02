import AppKit

/// The user can hold apprentice still from the overlay: new actions wait here until they resume.
enum Pause {
    static var on = false

    /// Blocks an action about to start until the person resumes; the kill switch or a stop ends the wait.
    static func wait() {
        while on && !KillSwitch.tripped { Thread.sleep(forTimeInterval: 0.2) }
    }
}

/// A short system sound for each lasting change of state, so the person hears it without looking.
/// `[agent] sounds = false` silences them all (`ask_sound` still sets the question ping).
enum Sound {
    /// The person's mute, kept across restarts as a marker file; every box has a switch for it.
    private static let marker = Store.dir.appendingPathComponent("muted")
    static var muted: Bool = FileManager.default.fileExists(atPath: marker.path) {
        didSet {
            if muted { FileManager.default.createFile(atPath: marker.path, contents: Data()) }
            else { try? FileManager.default.removeItem(at: marker) }
            DispatchQueue.main.async { for b in buttons.allObjects { style(b) } }
        }
    }
    private static let buttons = NSHashTable<NSButton>.weakObjects()

    private final class Toggle: NSObject {
        @objc func flip(_ sender: NSButton) { Sound.muted.toggle() }
    }
    private static let toggle = Toggle()

    private static func style(_ b: NSButton) {
        b.title = ""
        let symbol = NSImage(systemSymbolName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", accessibilityDescription: nil)
        b.image = symbol?.withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        b.imagePosition = .imageOnly
        b.toolTip = muted ? "Muted: click to turn sounds on" : "Sounds on: click to mute"
        b.bezelColor = muted ? .systemGray : .systemTeal
        b.contentTintColor = .white
        b.setAccessibilityLabel(muted ? "Sounds are muted; press to turn them on" : "Sounds are on; press to mute")
    }

    /// A "Sound on / Muted" button for a box; all of them follow the one setting.
    static func muteButton() -> NSButton {
        let b = NSButton(title: "", target: toggle, action: #selector(Toggle.flip))
        b.bezelStyle = .rounded
        b.controlSize = .regular
        b.font = .boldSystemFont(ofSize: 12)
        b.widthAnchor.constraint(equalToConstant: 48).isActive = true
        style(b)
        buttons.add(b)
        return b
    }

    private static var playing: [String: NSSound] = [:]
    private static var lastAny = Date.distantPast

    /// From any thread. The same sound is not repeated inside 0.25 s.
    static func play(_ name: String) {
        guard Config.current.sounds, !muted else { return }
        DispatchQueue.main.async {
            // One sound at a time, and never a burst: anything inside 0.6 s of the last is dropped.
            if Date().timeIntervalSince(lastAny) < 0.6 { return }
            lastAny = Date()
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
        pauseButton.controlSize = .regular
        pauseButton.setContentHuggingPriority(.required, for: .horizontal)
                pauseButton.bezelColor = .systemOrange
        pauseButton.contentTintColor = .white
        pauseButton.font = .boldSystemFont(ofSize: 12)
        // The text column takes the slack and clips, so a long line never widens the box.
        title.lineBreakMode = .byTruncatingTail
        for label in [title, detail] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        let mute = Sound.muteButton()
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        // Fixed widths everywhere: nothing moves when the text changes, and the box never widens.
        text.widthAnchor.constraint(equalToConstant: 236).isActive = true
        title.widthAnchor.constraint(equalToConstant: 236).isActive = true
        detail.widthAnchor.constraint(equalToConstant: 236).isActive = true
        dot.alignment = .center
        dot.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let mark = NSImageView(image: Ask.icon)
        mark.setAccessibilityLabel("apprentice")
        mark.widthAnchor.constraint(equalToConstant: 32).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let top = NSStackView(views: [mark, dot, text])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 8
        // The controls get their own row at the bottom: Mute on the left, Pause on the right.
        pauseButton.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let bottom = NSStackView(views: [mute, NSView(), pauseButton])
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let column = NSStackView(views: [top, bottom])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        p.contentView = column
        column.layoutSubtreeIfNeeded()
        p.setContentSize(column.fittingSize)
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

    /// One sound for each lasting change of state. A state must hold 0.8 s before it counts (the mouse
    /// jittering or a command ending must not chatter), the way back is heard only after a hand-off was,
    /// and a hand-off is announced at most once every 10 s.
    private static var candidate = ""
    private static var candidateSince = Date()
    private static var lastHandOff = Date.distantPast
    private static var handedOver = false

    private static func chime(_ head: String) {
        let now = Date()
        if head != candidate { candidate = head; candidateSince = now }
        if lastHead.isEmpty { lastHead = head; return }
        guard head != lastHead else { return }
        let immediate = ["Paused", "Stopped", "Needs approval"].contains(head) || lastHead == "Paused"
        guard immediate || now.timeIntervalSince(candidateSince) >= 0.8 else { return }
        let was = lastHead
        lastHead = head
        switch head {
        case "Yours":
            guard now.timeIntervalSince(lastHandOff) > 10 else { return }
            lastHandOff = now
            handedOver = true
            Sound.play("Funk")
        case "Paused": Sound.play("Morse")
        case "Stopped": Sound.play("Basso")
        case "Needs approval":
            Sound.play("Sosumi")
            Notify.local(Approvals.pending.map { "Approve or deny: \($0.summary)" } ?? "A step needs your approval")
        default:
            if was == "Paused" { Sound.play("Hero") }
            else if was == "Yours", handedOver { handedOver = false; Sound.play("Glass") }
        }
    }

    private static func render() {
        let (color, head, sub, label) = status()
        chime(head)
        dot.textColor = color
        title.stringValue = head
        detail.stringValue = sub
        pauseButton.title = label
        // Orange to hold, green to go on: the one control worth finding at a glance.
        pauseButton.bezelColor = Pause.on ? .systemGreen : .systemOrange
        if let p = panel {
            // Back on screen if a display went away or the window was dragged off.
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(p.frame) }) { place(p) }
            Ask.keepOnScreen(p)
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
