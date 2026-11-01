import AppKit

/// `ask "question"`: a little window at the top of the screen for when the LLM is stuck or needs a
/// decision. Free text by default; `--choices "A|B|C"` shows radio buttons, `--multi` checkboxes, and
/// `--text` adds a reply field next to the choices. The reply comes back as the command's output.
/// The LLM decides when to ask; the window is only the channel, so it is not gated.
enum Ask {
    private static var playing: NSSound?

    struct Reply {
        var chosen: [String]
        var text: String
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
        let timeout = a.value("timeout").flatMap(Double.init) ?? 600
        let previous = NSWorkspace.shared.frontmostApplication
        let reply: Reply? = DispatchQueue.main.sync {
            show(question, choices: choices, multi: multi, withText: withText, timeout: timeout)
        }
        if let previous, previous.processIdentifier != getpid() { previous.activate() }
        Store.log(["ask": question, "answered": reply != nil])
        guard let reply, !reply.chosen.isEmpty || !reply.text.isEmpty else {
            throw Fail(5, "no answer: Robert skipped the question or it timed out")
        }
        var out: [String] = []
        if !reply.chosen.isEmpty { out.append("Robert chose: " + reply.chosen.joined(separator: "; ")) }
        if !reply.text.isEmpty { out.append("Robert: " + reply.text) }
        return out.joined(separator: "\n")
    }

    /// Runs on the main thread. Nil when skipped or timed out.
    static func show(_ question: String, choices: [String], multi: Bool, withText: Bool, timeout: Double,
                     sendTitle: String = "Send", checked: Set<String> = [], placeholder: String? = nil,
                     initialText: String = "") -> Reply? {
        let width: CGFloat = 380
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 160),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "deskkontrol needs you"
        panel.level = .floating
        panel.isReleasedWhenClosed = false

        let handler = Handler()
        let label = NSTextField(wrappingLabelWithString: question)
        label.preferredMaxLayoutWidth = width - 32
        var rows: [NSView] = [label]

        // Radio buttons that share an action are grouped by AppKit, so one choice stays selected.
        let boxes: [NSButton] = choices.map { choice in
            multi ? NSButton(checkboxWithTitle: choice, target: nil, action: nil)
                  : NSButton(radioButtonWithTitle: choice, target: handler, action: #selector(Handler.picked))
        }
        for box in boxes where checked.contains(box.title) { box.state = .on }
        rows += boxes

        let field = NSTextField(string: initialText)
        field.placeholderString = placeholder ?? (choices.isEmpty ? "Your reply" : "Anything to add (optional)")
        if withText { rows.append(field) }

        let send = NSButton(title: sendTitle, target: handler, action: #selector(Handler.send))
        send.keyEquivalent = "\r"
        let skip = NSButton(title: "Skip", target: handler, action: #selector(Handler.skip))
        skip.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), skip, send])
        rows.append(buttons)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        for view in [field, buttons] where rows.contains(view) {
            view.widthAnchor.constraint(equalToConstant: width - 32).isActive = true
        }
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)

        // Top centre of the screen the person is looking at.
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.maxY - 12))
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        let sound = Config.current.askSound
        if sound.lowercased() != "none", !sound.isEmpty {
            // Held in a static: a sound released right after play() stops before it is heard.
            playing = NSSound(named: NSSound.Name(sound)) ?? NSSound(named: "Ping")
            playing?.play()
        }
        panel.makeFirstResponder(withText ? field : boxes.first ?? send)

        let timer = Timer(timeInterval: timeout, repeats: false) { _ in NSApplication.shared.stopModal(withCode: .cancel) }
        RunLoop.main.add(timer, forMode: .modalPanel)
        let response = NSApplication.shared.runModal(for: panel)
        timer.invalidate()
        panel.orderOut(nil)
        guard response == .OK else { return nil }
        // Show-me replies carry nothing but the moment Return was pressed.
        return Reply(chosen: boxes.filter { $0.state == .on }.map(\.title),
                     text: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private final class Handler: NSObject {
        @objc func picked() {}
        @objc func send() { NSApplication.shared.stopModal(withCode: .OK) }
        @objc func skip() { NSApplication.shared.stopModal(withCode: .cancel) }
    }
}

/// `show "what"`: when the LLM cannot find something, the person points the cursor at it and presses
/// Return. The reply names the element under the cursor and its id in a fresh list, so the LLM can
/// click it now and write it into the notes by name.
extension Ask {
    static func pointAt(_ a: Args) throws -> String {
        let what = a.pos.joined(separator: " ")
        guard !what.isEmpty else { throw Fail(5, "show \"what to point at\" [--timeout 600]") }
        let timeout = a.value("timeout").flatMap(Double.init) ?? 600
        let previous = NSWorkspace.shared.frontmostApplication
        let point: CGPoint? = DispatchQueue.main.sync {
            let message = "Show me: \(what)\n\nMove the cursor onto it, then press Return. Esc to skip."
            return show(message, choices: [], multi: false, withText: false, timeout: timeout, sendTitle: "Return captures") != nil
                ? Mouse.location : nil
        }
        if let previous, previous.processIdentifier != getpid() { previous.activate() }
        guard let point else { throw Fail(5, "no answer: Robert skipped or it timed out") }
        Store.log(["show": what, "x": Int(point.x), "y": Int(point.y)])

        var out = ["Robert pointed at \(Int(point.x)),\(Int(point.y))"]
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success, let hit {
            let role = (hit.string(kAXRoleAttribute) ?? "element").replacingOccurrences(of: "AX", with: "").lowercased()
            let name = hit.string(kAXTitleAttribute) ?? hit.string(kAXDescriptionAttribute)
                ?? hit.string(kAXValueAttribute) ?? ""
            out.append("under the cursor: \(role) \"\(clip(name, 80))\"")
        }
        // The smallest listed element there, in a fresh snapshot so its id is current.
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
        out.append("then add where it is to the note for this page or app, by name")
        return out.joined(separator: "\n")
    }
}

/// `confirm <token>`: puts a pending proposal in front of Robert, with Approve and Deny. Approving runs
/// it at once. Use it for risky (⚠) steps, so the LLM never approves those on his behalf.
extension Ask {
    static func confirm(_ a: Args) throws -> String {
        guard let token = a.pos.first else { throw Fail(5, "confirm <token>") }
        guard let p = Approvals.pending, p.token == token else { throw Fail(5, "no pending action \(token): run the command again") }
        let approve = "Approve", deny = "Deny"
        let why = a.value("why").map { "\n\nWhy: \($0)" } ?? ""
        let reply = DispatchQueue.main.sync {
            show("Approve this step?\n\n\(p.summary)\(why)", choices: [approve, deny], multi: false, withText: true,
                 timeout: a.value("timeout").flatMap(Double.init) ?? 600, placeholder: "Anything to add (optional)")
        }
        let note = reply.map { $0.text.isEmpty ? "" : "\nRobert: \($0.text)" } ?? ""
        guard let reply, reply.chosen.contains(approve) else {
            if reply != nil { _ = try Commands.dispatch(Request(cmd: "deny", args: [token])) }
            throw Fail(3, (reply == nil ? "no answer: nothing was done" : "Robert denied: \(p.summary)") + note)
        }
        Store.log(["confirm": p.summary, "by": "Robert"])
        return try Commands.dispatch(Request(cmd: "approve", args: [token])) + note
    }
}
