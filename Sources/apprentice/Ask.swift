import AppKit

/// `ask "question"`: a little window at the top of the screen for when the LLM is stuck or needs a
/// decision. Free text by default; `--choices "A|B|C"` shows radio buttons, `--multi` checkboxes, and
/// `--text` adds a reply field next to the choices. The reply comes back as the command's output.
/// The LLM decides when to ask; the window is only the channel, so it is not gated.
enum Ask {
    static var playing: NSSound?

    struct Reply {
        var chosen: [String]
        var text: String
        var skipped = false
    }

    /// The user may be away from the Mac and answering in the chat instead (Claude Code remote, a phone).
    /// Then questions come back with exit 9 and the LLM asks them in the terminal.
    struct Away: Codable { var on: Bool }
    static var away: Bool { Config.current.askIn == "terminal" || (Store.load(Away.self, "away.json")?.on ?? false) }
    /// How long the window waits before the question goes to the chat instead.
    static func windowTime(_ requested: Double) -> Double {
        Config.current.askIn == "window" ? requested : min(requested, Config.current.askWindowSeconds)
    }
    /// `push` is what the phone notification says (`[agent] notify`); the screenshot is for the agent to
    /// attach to its question, since the user cannot see the Mac. A nil `push` re-words a question the daemon
    /// already handed off, which has already pushed.
    static func handOff(_ lines: [String], push: String?) -> Fail {
        if let push { Notify.send(push) }
        let shot = push == nil ? [] : Notify.shot().map { ["screenshot of the screen it is about: \($0) (attach it to your question if you can send files)"] } ?? []
        return Fail(9, (["ask the user in the chat (terminal): they are away from the Mac or did not answer the window."] + lines + shot
                        + ["Carry on with their answer as if they had answered the window."]).joined(separator: "\n"))
    }

    /// `away on|off|status`: questions go to the chat while the user is away. The LLM may set this when they
    /// says they are away or back; it only changes where questions go.
    static let callerKey = "apprentice.caller"
    /// The socket of the request being served on this thread; read it before hopping to main.
    static var caller: Int32? { Thread.current.threadDictionary[callerKey] as? Int32 }
    /// False once the caller has closed its end: the agent's command timed out or was cancelled.
    /// The probe is a space, which the reply can carry, since JSON allows leading whitespace.
    static func waiting(_ fd: Int32?) -> Bool {
        guard let fd else { return true }
        var space: UInt8 = 0x20
        return write(fd, &space, 1) == 1
    }

    static func run(_ a: Args) throws -> String {
        let question = a.pos.joined(separator: " ")
        guard !question.isEmpty else {
            throw Fail(5, "ask \"question\" [--choices \"A|B|C\" [--multi] [--text]] [--timeout 600]")
        }
        let choices = (a.value("choices") ?? "").split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let multi = a.has("multi")
        let withText = choices.isEmpty || a.has("text")
        let remote = ["question: \(question)"]
            + (choices.isEmpty ? [] : ["choices (\(multi ? "any number" : "one")): " + choices.joined(separator: " | ")])
        Store.log(["ask": question])
        if away { throw handOff(remote, push: question) }
        let timeout = windowTime(a.value("timeout").flatMap(Double.init) ?? 600)
        let previous = NSWorkspace.shared.frontmostApplication
        let caller = caller
        let reply: Reply? = DispatchQueue.main.sync {
            show(question, choices: choices, multi: multi, withText: withText, timeout: timeout, caller: caller)
        }
        if let previous, previous.processIdentifier != getpid() { previous.activate() }
        guard let reply else {
            if Config.current.askIn != "window" { throw handOff(remote, push: question) }
            throw Fail(5, "no answer: the question timed out")
        }
        guard !reply.skipped, !reply.chosen.isEmpty || !reply.text.isEmpty else {
            throw Fail(5, "no answer: The user skipped the question")
        }
        // The user answered in the window, so the agent has asked them: the kill switch's stop is lifted.
        KillSwitch.halted = false
        var out: [String] = []
        if !reply.chosen.isEmpty { out.append("user chose: " + reply.chosen.joined(separator: "; ")) }
        if !reply.text.isEmpty { out.append("user: " + reply.text) }
        return out.joined(separator: "\n")
    }

    /// Runs on the main thread. Nil when skipped or timed out. `onMac` keeps a user-only approval off the
    /// VM's screen, where anything with ssh into the guest could click it with faked input.
    static func show(_ question: String, choices: [String], multi: Bool, withText: Bool, timeout: Double,
                     sendTitle: String = "Send", checked: Set<String> = [], placeholder: String? = nil,
                     initialText: String = "", caller: Int32? = nil, secure: Bool = false, onMac: Bool = false) -> Reply? {
        Notify.local(question)
        // A session in a VM asks on the VM's screen as well as here, so the user answers on whichever they
        // are looking at; the first answer closes the other window.
        let inVM = secure || onMac ? nil : Remote.askInVM(question, choices: choices, multi: multi, withText: withText, timeout: timeout,
                                                          sendTitle: sendTitle, checked: checked, placeholder: placeholder, initialText: initialText)
        defer { inVM?.close() }
        // Wider for a long question or long choices, so neither is cut short.
        let longest = max(question.count / 3, choices.map(\.count).max() ?? 0)
        let width: CGFloat = min(max(420, CGFloat(longest) * 7), 620)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 160),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "apprentice needs you"
        panel.level = .floating
        // On every Space and above a full-screen app, so the question is never behind the work.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        blue(panel)
        StatusItem.asking(true)
        defer { StatusItem.asking(false) }

        let handler = Handler()
        let label = NSTextField(wrappingLabelWithString: question)
        label.preferredMaxLayoutWidth = width - 48 - 56
        label.setAccessibilityLabel("Question from apprentice: \(question)")
        var rows: [NSView] = [header(label)]

        // Radio buttons that share an action are grouped by AppKit, so one choice stays selected.
        let boxes: [NSButton] = choices.map { choice in
            multi ? NSButton(checkboxWithTitle: choice, target: nil, action: nil)
                  : NSButton(radioButtonWithTitle: choice, target: handler, action: #selector(Handler.picked))
        }
        for box in boxes where checked.contains(box.title) { box.state = .on }
        rows += boxes

        // A password is typed into a field that hides it.
        let field = secure ? NSSecureTextField(string: initialText) : NSTextField(string: initialText)
        field.placeholderString = placeholder ?? (choices.isEmpty ? "Your reply" : "Anything to add (optional)")
        if withText { rows.append(field) }

        // The titles say which key does what: Return sends, Escape skips.
        let send = NSButton(title: "\(sendTitle) ↩", target: handler, action: #selector(Handler.send))
        send.keyEquivalent = "\r"
        send.setAccessibilityLabel("\(sendTitle), Return")
        let skip = NSButton(title: "Skip ⎋", target: handler, action: #selector(Handler.skip))
        skip.keyEquivalent = "\u{1b}"
        skip.setAccessibilityLabel("Skip, Escape")
        // Opens the VM's screen, where the same question waits beside the work; this window stays open.
        let look = NSButton(title: Remote.openTheVM, target: handler, action: #selector(Handler.look))
        let buttons = NSStackView(views: [Sound.muteButton()] + (inVM == nil ? [] : [look]) + [NSView(), skip, send])
        buttons.spacing = 12
        buttons.alignment = .centerY
        rows.append(buttons)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.setCustomSpacing(20, after: rows[rows.count - 2])
        // A leading-aligned stack fits to its widest row and drops the right inset; hold it to the panel's width.
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        for view in [field, buttons] where rows.contains(view) {
            view.widthAnchor.constraint(equalToConstant: width - 48).isActive = true
        }
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)

        place(panel)
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        ping()
        panel.makeFirstResponder(withText ? field : boxes.first ?? send)

        let timer = Timer(timeInterval: timeout, repeats: false) { _ in NSApplication.shared.stopModal(withCode: .abort) }
        RunLoop.main.add(timer, forMode: .modalPanel)
        // Once more after 30 s, for someone at the Mac who missed the first one.
        let again = Timer(timeInterval: 30, repeats: false) { _ in ping() }
        RunLoop.main.add(again, forMode: .modalPanel)
        // The agent may stop waiting (its command timed out or was cancelled); an answer then would reach no one.
        let watch = Timer(timeInterval: 1, repeats: true) { _ in
            if !waiting(caller) { NSApplication.shared.stopModal(withCode: .stop) }
        }
        if caller != nil { RunLoop.main.add(watch, forMode: .modalPanel) }
        let vmAnswered = NSApplication.ModalResponse(rawValue: 1_001)
        let vm = Timer(timeInterval: 0.2, repeats: true) { _ in
            if inVM?.answer != nil { NSApplication.shared.stopModal(withCode: vmAnswered) }
        }
        if inVM != nil { RunLoop.main.add(vm, forMode: .modalPanel) }
        var response = NSApplication.shared.runModal(for: panel)
        timer.invalidate()
        again.invalidate()
        watch.invalidate()
        vm.invalidate()
        if response == vmAnswered, let answer = inVM?.answer {
            panel.orderOut(nil)
            return answer
        }
        if response == .stop {
            // Say so in the window rather than leave a question nobody will read the answer to.
            Store.log(["ask_abandoned": clip(question, 120)])
            label.stringValue = "The agent stopped waiting for this, so nothing was done. Ask it to try again.\n\n\(question)"
            for view in boxes + [field, skip] { view.isHidden = true }
            send.title = "OK ↩"
            send.setAccessibilityLabel("OK, Return")
            panel.setContentSize(stack.fittingSize)
            keepOnScreen(panel)
            let close = Timer(timeInterval: 20, repeats: false) { _ in NSApplication.shared.stopModal(withCode: .abort) }
            RunLoop.main.add(close, forMode: .modalPanel)
            response = NSApplication.shared.runModal(for: panel)
            close.invalidate()
            panel.orderOut(nil)
            return nil
        }
        panel.orderOut(nil)
        if response == .abort { return nil }
        guard response == .OK else { return Reply(chosen: [], text: "", skipped: true) }
        // Show-me replies carry nothing but the moment Return was pressed.
        return Reply(chosen: boxes.filter { $0.state == .on }.map(\.title),
                     text: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Top centre of the screen the cursor is on, where the person is looking.
    static func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - 12))
        }
    }

    /// Slides a panel back inside the visible screen, so a window that grew never runs off an edge.
    static func keepOnScreen(_ panel: NSWindow) {
        guard let v = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        var f = panel.frame
        f.origin.x = min(max(f.origin.x, v.minX + 8), max(v.maxX - f.width - 8, v.minX + 8))
        f.origin.y = min(max(f.origin.y, v.minY + 8), max(v.maxY - f.height - 8, v.minY + 8))
        if f != panel.frame { panel.setFrame(f, display: true) }
    }

    /// Dialogs are blue, so they stand out from the work behind them: white text on apprentice's blue.
    static func blue(_ window: NSWindow) {
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0x0A / 255, green: 0x5C / 255, blue: 0xE6 / 255, alpha: 1)
    }

    /// The apprentice mark beside the text, so it is plain who is asking.
    static func header(_ label: NSTextField) -> NSView {
        let mark = NSImageView(image: icon)
        mark.setAccessibilityLabel("apprentice")
        mark.widthAnchor.constraint(equalToConstant: 40).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let row = NSStackView(views: [mark, label])
        row.alignment = .top
        row.spacing = 16
        return row
    }

    /// `assets/icon.svg`, drawn in code: the binary has no bundle to carry an image.
    static let icon = NSImage(size: NSSize(width: 64, height: 64), flipped: true) { _ in
        let tile = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 64, height: 64), xRadius: 14, yRadius: 14)
        NSGradient(starting: NSColor(srgbRed: 0x2F / 255, green: 0x8C / 255, blue: 1, alpha: 1),
                   ending: NSColor(srgbRed: 0x0A / 255, green: 0x5C / 255, blue: 0xE6 / 255, alpha: 1))?.draw(in: tile, angle: 90)
        let rim = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 63, height: 63), xRadius: 13.5, yRadius: 13.5)
        NSColor.white.withAlphaComponent(0.18).setStroke()
        rim.stroke()
        let alpha = NSBezierPath()
        alpha.move(to: NSPoint(x: 45.5, y: 20))
        alpha.curve(to: NSPoint(x: 27, y: 44), controlPoint1: NSPoint(x: 42, y: 32), controlPoint2: NSPoint(x: 37.5, y: 44))
        alpha.curve(to: NSPoint(x: 16.5, y: 33), controlPoint1: NSPoint(x: 20.5, y: 44), controlPoint2: NSPoint(x: 16.5, y: 39))
        alpha.curve(to: NSPoint(x: 27, y: 22), controlPoint1: NSPoint(x: 16.5, y: 27), controlPoint2: NSPoint(x: 20.5, y: 22))
        alpha.curve(to: NSPoint(x: 45.5, y: 44), controlPoint1: NSPoint(x: 37.5, y: 22), controlPoint2: NSPoint(x: 42, y: 34))
        alpha.lineWidth = 6.5
        alpha.lineCapStyle = .round
        alpha.lineJoinStyle = .round
        NSColor.white.setStroke()
        alpha.stroke()
        return true
    }

    /// `[agent] ask_sound`, unless it is "none".
    static func ping() {
        let sound = Config.current.askSound
        guard sound.lowercased() != "none", !sound.isEmpty, !Sound.muted else { return }
        // Held in a static: a sound released right after play() stops before it is heard.
        playing = NSSound(named: NSSound.Name(sound)) ?? NSSound(named: "Ping")
        playing?.play()
    }

    private final class Handler: NSObject {
        @objc func picked() {}
        @objc func send() { NSApplication.shared.stopModal(withCode: .OK) }
        @objc func skip() { NSApplication.shared.stopModal(withCode: .cancel) }
        @objc func look() {
            do { try VM.openViewer() } catch { Store.log(["vm_look": "failed", "why": "\(error)"]) }
        }
    }
}

/// `show "what"`: when the LLM cannot find something, the person points at it. The window never takes
/// focus, so menus and dropdowns in the app stay open: press Start, move the cursor onto the thing and
/// hold still; after 5 s without movement the spot is captured. The reply names the element there and
/// its id in a fresh list, so the LLM can act on it now and write it into the playbook by name.
extension Ask {
    static func pointAt(_ a: Args) throws -> String {
        let what = a.pos.joined(separator: " ")
        guard !what.isEmpty else { throw Fail(5, "show \"what to point at\" [--timeout 600]") }
        let remote = ["they cannot point from afar: ask them to describe where \"\(what)\" is on the screen,",
                      "or look for it yourself with `apprentice shot` and `apprentice ocr`."]
        if away { throw handOff(remote, push: "Where is \"\(what)\"?") }
        let timeout = windowTime(a.value("timeout").flatMap(Double.init) ?? 600)
        let (found, skipped): (CGPoint?, Bool) = DispatchQueue.main.sync { watchPointer(what, timeout: timeout) }
        guard let point = found else {
            if !skipped, Config.current.askIn != "window" { throw handOff(remote, push: "Where is \"\(what)\"?") }
            throw Fail(5, skipped ? "no answer: The user skipped" : "no answer: it timed out")
        }
        Store.log(["show": what, "x": Int(point.x), "y": Int(point.y)])

        var out = ["The user pointed at \(Int(point.x)),\(Int(point.y))"]
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success, let hit {
            let role = (hit.string(kAXRoleAttribute) ?? "element").replacingOccurrences(of: "AX", with: "").lowercased()
            let name = hit.string(kAXTitleAttribute) ?? hit.string(kAXDescriptionAttribute)
                ?? hit.string(kAXValueAttribute) ?? ""
            out.append("under the cursor: \(role) \"\(clip(name, 80))\"")
        }
        // The smallest listed element there, in a fresh snapshot so its id is current; on the command
        // queue, since the window itself waited off it.
        Daemon.serial {
        if let (session, target, _) = try? prepare() {
            let snap = readSnapshot(target)
            SnapStore.save(snap)
            SnapshotCache.put(session.wid, snap)
            if let e = snap.elements.filter({ $0.rect.contains(point) }).min(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) {
                out.append("in the list: \(e.short) · act on it with its id")
            } else {
                out.append("not in the list: `click --at \(Int(point.x)),\(Int(point.y))` clicks there")
            }
        }
        }
        out.append("then add where it is to the playbook for this page or app, by name")
        return out.joined(separator: "\n")
    }

    /// Runs on the main thread. A non-activating panel, so the app under it keeps focus.
    private static func watchPointer(_ what: String, timeout: Double) -> (CGPoint?, Bool) {
        let width: CGFloat = 340
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
                            styleMask: [.titled, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "apprentice: show me"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        StatusItem.asking(true)
        defer { StatusItem.asking(false) }
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        blue(panel)

        let label = NSTextField(wrappingLabelWithString: "Show me: \(what)\n\nPress Start, move the cursor onto it, and hold still.")
        label.preferredMaxLayoutWidth = width - 48 - 56
        let status = NSTextField(labelWithString: "")
        status.textColor = .secondaryLabelColor
        let handler = PointHandler()
        let start = NSButton(title: "Start", target: handler, action: #selector(PointHandler.start))
        let skip = NSButton(title: "Skip", target: handler, action: #selector(PointHandler.skip))
        let buttons = NSStackView(views: [Sound.muteButton(), status, NSView(), skip, start])
        buttons.spacing = 12
        buttons.alignment = .centerY
        let stack = NSStackView(views: [header(label), buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        // A leading-aligned stack fits to its widest row and drops the right inset; hold it to the panel's width.
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        buttons.widthAnchor.constraint(equalToConstant: width - 48).isActive = true
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
        place(panel)
        panel.orderFrontRegardless()
        ping()
        Notify.local("Show me: \(what)")
        defer { panel.orderOut(nil) }

        // Watch only after Start; capture once the cursor has rested for 5 s (a debounce on movement).
        let deadline = Date().addingTimeInterval(timeout)
        let still = 5.0
        var last = Mouse.location
        var restingSince = Date()
        // The rest is counted from Start, not from when the window appeared: someone who reads the
        // prompt for five seconds and then presses Start must not be answered at once, with the
        // cursor still wherever it was.
        var begun = false
        while Date() < deadline, !handler.skipped {
            // Hand mouse and key events to the window; running the run loop alone leaves it frozen.
            let until = Date().addingTimeInterval(0.1)
            while let event = NSApplication.shared.nextEvent(matching: .any, until: until, inMode: .default, dequeue: true) {
                NSApplication.shared.sendEvent(event)
            }
            guard handler.started else { continue }
            if !begun {
                begun = true
                last = Mouse.location
                restingSince = Date()
                continue
            }
            let now = Mouse.location
            if hypot(now.x - last.x, now.y - last.y) > 2 {
                last = now
                restingSince = Date()
            }
            let left = still - Date().timeIntervalSince(restingSince)
            // The cursor over this window is not an answer.
            if panel.frame.contains(NSEvent.mouseLocation) {
                status.stringValue = "move onto it…"
                restingSince = Date()
                continue
            }
            if left <= 0 { return (now, false) }
            status.stringValue = "hold still: \(Int(left.rounded(.up))) s"
        }
        return (nil, handler.skipped)
    }

    private final class PointHandler: NSObject {
        var started = false
        var skipped = false
        @objc func start() { started = true }
        @objc func skip() { skipped = true }
    }
}

/// `confirm <token>`: puts a pending proposal in front of the user, with Approve and Deny. Approving runs
/// it at once. Use it for risky (⚠) steps, so the LLM never approves those on their behalf.
extension Ask {
    static func confirm(_ a: Args) throws -> String {
        guard let token = a.pos.first else { throw Fail(5, "confirm <token>") }
        guard let p = Approvals.find(token) else { throw Fail(5, "no pending action \(token): run the command again") }
        let approve = "Approve", deny = "Deny"
        let why = a.value("why").map { "\n\nWhy: \($0)" } ?? ""
        // The user decides on what the agent saw: the ⚠ lines (irreversible, a payment, a password field) go with it.
        let flags = (p.warnings ?? []).map { "⚠ \($0)" }
        let remote = p.needsUser
            ? ["question: approve this step? \(p.summary)\(why.replacingOccurrences(of: "\n\n", with: " "))"] + flags + [
               "\(p.warnings?.first(where: Gate.forUser.contains) ?? Gate.credential): only the user can approve it, at the Mac: when they are back, run `apprentice confirm \(token)` again. A yes in the chat cannot run it. The step stays open for an hour."]
            : ["question: approve this step? \(p.summary)\(why.replacingOccurrences(of: "\n\n", with: " "))"] + flags + [
               "if they say yes in the chat: `apprentice approve \(token)`; if no: `apprentice deny \(token)`. Nothing is done until then; the step stays open for an hour."]
        // The user may answer from the chat or their phone long after the usual five minutes.
        func handBack() -> Fail {
            Daemon.serial { Approvals.extend(token, by: Approvals.userTTL) }
            return handOff(remote, push: "Approve this step? \(p.summary)")
        }
        if away { throw handBack() }
        let caller = caller
        let timeout = windowTime(a.value("timeout").flatMap(Double.init) ?? 600)
        Daemon.serial { Approvals.extend(token, by: timeout + 60) }
        let reply = DispatchQueue.main.sync {
            show("Approve this step?\n\n\(([p.summary] + flags).joined(separator: "\n"))\(why)", choices: [approve, deny], multi: false, withText: true,
                 timeout: timeout, placeholder: "Anything to add (optional)", caller: caller, onMac: true)
        }
        // An approval in the second after the agent gave up would run a step nobody is watching.
        if reply?.chosen.contains(approve) == true, !waiting(caller) {
            Store.log(["confirm": p.summary, "by": "user", "dropped": "caller gone"])
            throw Fail(3, "no answer: the caller stopped waiting, nothing was done")
        }
        if reply == nil, Config.current.askIn != "window" { throw handBack() }
        let note = reply.map { $0.text.isEmpty ? "" : "\nuser: \($0.text)" } ?? ""
        guard let reply, !reply.skipped, reply.chosen.contains(approve) else {
            if reply != nil { _ = try? Daemon.command(Request(cmd: "deny", args: [token])) }
            throw Fail(3, (reply == nil ? "no answer: nothing was done" : "The user denied: \(p.summary)") + note)
        }
        Store.log(["confirm": p.summary, "by": "user"])
        return try Daemon.command(Request(cmd: "approve", args: [token]), byUser: true) + note
    }
}
