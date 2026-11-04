import AppKit

/// The user can hold apprentice still from the overlay: new actions wait here until they resume.
enum Pause {
    /// A marker file, so the app's Pause and the overlay's are the same switch the daemon waits on. A new
    /// daemon starts unpaused (`Daemon.start` clears it).
    static var on: Bool {
        get { FileManager.default.fileExists(atPath: marker.path) }
        set {
            if newValue { FileManager.default.createFile(atPath: marker.path, contents: nil) }
            else { try? FileManager.default.removeItem(at: marker) }
        }
    }
    static var marker: URL { Store.stateDir.appendingPathComponent("paused") }

    /// Blocks an action about to start until the person resumes; the kill switch or a stop ends the wait.
    static func wait() {
        while on && !KillSwitch.tripped { Thread.sleep(forTimeInterval: 0.2) }
    }
}

/// A few soft beeps for each lasting change of state, so the person hears it without looking (see `Beep`).
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

    /// Beeps still sounding, held so they are not released (and cut off) before they are heard.
    private static var sounding: [NSSound] = []
    private static var lastCue: [String: Date] = [:]
    private static var cache: [String: Data] = [:]

    private final class Done: NSObject, NSSoundDelegate {
        func sound(_ sound: NSSound, didFinishPlaying flag: Bool) { Sound.sounding.removeAll { $0 === sound } }
    }
    private static let finisher = Done()

    /// From any thread: the soft beeps for `cue`, in the note of the system it is about (`key`: "mac" or a VM's name).
    /// Beeps from several systems overlap on purpose. The same cue for the same system is not repeated inside 0.25 s.
    static func cue(_ cue: Cue, key: String = Store.vmName ?? "mac") {
        guard Config.current.sounds, !muted else { return }
        DispatchQueue.main.async {
            let id = cue.rawValue + key
            if let last = lastCue[id], Date().timeIntervalSince(last) < 0.25 { return }
            lastCue[id] = Date()
            let data = cache[id] ?? Beep.wav(cue.notes, root: Beep.root(for: key))
            cache[id] = data
            guard let s = NSSound(data: data) else { return }
            s.delegate = finisher
            s.volume = 0.6
            sounding.append(s)
            s.play()
        }
    }
}

/// One line of the box: what one daemon (This Mac, or a VM's) is doing. Every daemon writes its row to `live/`;
/// whichever daemon owns the box shows them all.
struct LiveRow: Codable {
    var key: String
    var system: String
    var head: String
    var sub: String
    var tone: String
    var rank: Int
    var paused: Bool
    var inVM: Bool
    var stateDir: String
    var agentPid: Int32?
    var agentWid: UInt32?
    var showAgent: Bool
    var showQuick: Bool
    var quickLabel: String
    var pid: Int32
    var at: Double

    var color: NSColor {
        switch tone {
        case "green": return .systemGreen
        case "orange": return .systemOrange
        case "red": return .systemRed
        case "blue": return .systemBlue
        case "yellow": return .systemYellow
        default: return .systemGray
        }
    }
}

/// Whether the box is off the screen. The yellow button hides it and the menu bar item brings it back; it comes back
/// by itself when work starts (`[agent] overlay_open_on_work`) and goes by itself after `[agent] overlay_hide_idle_s`
/// of idling.
struct OverlayHide {
    /// What always brings it back, whatever the settings: these need the person.
    static let urgent: Set<String> = ["Waiting for you", "Needs approval", "Stopped"]
    /// How long after work the person's own hide still holds: commands in one task come seconds apart.
    static let holdFor = 20.0

    var hidden = false
    /// Hidden by hand during work: stays hidden until that work is over, not until the next command.
    var held = false
    private var idleSince: Double?
    private var wasUrgent = false

    mutating func toggle(_ heads: [String], now: Double) {
        hidden.toggle()
        held = hidden && !heads.allSatisfy { $0 == "Ready" }
        // Brought back by hand: a full idle wait before it goes again.
        if !hidden { idleSince = now }
    }

    mutating func step(_ heads: [String], now: Double, openOnWork: Bool, hideAfter: Double) {
        let urgent = heads.contains { Self.urgent.contains($0) }
        // On the way in only, so the person can still hide it while a question stays open.
        if urgent, !wasUrgent { hidden = false; held = false }
        wasUrgent = urgent
        guard heads.allSatisfy({ $0 == "Ready" }) else {
            idleSince = nil
            if heads.contains("Working"), openOnWork, !held { hidden = false }
            return
        }
        let since = idleSince ?? now
        idleSince = since
        if now - since >= Self.holdFor { held = false }
        if hideAfter > 0, now - since >= hideAfter { hidden = true }
    }
}

/// A small always-on-top box that says what apprentice is doing, on which system (This Mac or a VM): working,
/// handed to you while you move the mouse or type, taking over again once you have been still, paused, or idle.
/// It shows the most pressing task; "All" opens the list, three at a time, each with its own buttons, and
/// the icon opens the window. Closing it asks first, then stops apprentice. `[agent] overlay = false` hides it.
enum Overlay {
    /// Seconds the person must be still before apprentice takes over again (`Borrow.waitIdle`'s default).
    static var settle: Double { Borrow.settle }
    /// How long after a command the session still counts as engaged, so a move between two commands reads as a hand-off.
    private static let engagedFor: TimeInterval = 20
    private static let rowHeight: CGFloat = 78
    private static let rowGap: CGFloat = 8
    private static let contentWidth: CGFloat = 316

    private static var panel: NSPanel?
    private static var lastHead = ""
    private static var counting = false
    fileprivate static var expanded = false
    private static var rows: [String: RowView] = [:]
    fileprivate static var shown: [String] = []
    private static let handler = Handler()
    private static var timer: Timer?
    private static let scroll = NSScrollView()
    private static let list = Flipped()
    private static var scrollHeight: NSLayoutConstraint!
    private static var listHeight: NSLayoutConstraint!
    private static let count = NSTextField(labelWithString: "")
    private static let expandButton = NSButton(title: "All", target: nil, action: nil)
    private static var state = OverlayHide()
    /// The box's settings, re-read when the file changes: `Config.current` only reloads when a command runs.
    private static var hideConfig = Config.current
    private static var hideStamp = ""
    private static var hideChecked = Date.distantPast
    private static var column: NSStackView?
    fileprivate(set) static var lastRows: [LiveRow] = []
    private static var lastWrite = Date.distantPast
    private static var lastJSON = Data()

    private final class Flipped: NSView { override var isFlipped: Bool { true } }

    private final class RowView: NSView {
        let key: String
        let dot = NSTextField(labelWithString: "●")
        let title = NSTextField(labelWithString: "")
        let detail = NSTextField(labelWithString: "")
        let pause = NSButton(title: "Pause", target: nil, action: nil)
        let agent = NSButton(title: "Go to agent", target: nil, action: nil)
        let quick = NSButton(title: "Go in 5 s", target: nil, action: nil)
        let watch = NSButton(title: "Watch", target: nil, action: nil)

        init(key: String) {
            self.key = key
            super.init(frame: .zero)
            wantsLayer = true
            translatesAutoresizingMaskIntoConstraints = false
            dot.font = .systemFont(ofSize: 18)
            dot.alignment = .center
            dot.widthAnchor.constraint(equalToConstant: 16).isActive = true
            title.font = .boldSystemFont(ofSize: 13)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            for l in [title, detail] {
                l.lineBreakMode = .byTruncatingTail
                l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                l.widthAnchor.constraint(equalToConstant: 262).isActive = true
            }
            let text = NSStackView(views: [title, detail])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 1
            let top = NSStackView(views: [dot, text])
            top.orientation = .horizontal
            top.alignment = .centerY
            top.spacing = 8
            func style(_ b: NSButton, _ color: NSColor, _ action: Selector) {
                b.target = Overlay.handler
                b.action = action
                b.identifier = NSUserInterfaceItemIdentifier(key)
                b.bezelStyle = .rounded
                b.controlSize = .regular
                b.bezelColor = color
                b.contentTintColor = .white
                b.font = .boldSystemFont(ofSize: 12)
            }
            style(pause, .systemOrange, #selector(Handler.togglePause(_:)))
            style(agent, .systemBlue, #selector(Handler.goToAgent(_:)))
            style(quick, .systemBlue, #selector(Handler.goQuicker(_:)))
            style(watch, .systemTeal, #selector(Handler.watch(_:)))
            pause.widthAnchor.constraint(equalToConstant: 84).isActive = true
            let buttons = NSStackView(views: [watch, NSView(), quick, agent, pause])
            buttons.orientation = .horizontal
            buttons.alignment = .centerY
            buttons.spacing = 6
            let column = NSStackView(views: [top, buttons])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 8
            column.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            column.translatesAutoresizingMaskIntoConstraints = false
            addSubview(column)
            NSLayoutConstraint.activate([
                column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor),
                column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
                widthAnchor.constraint(equalToConstant: Overlay.contentWidth), heightAnchor.constraint(equalToConstant: Overlay.rowHeight),
                buttons.widthAnchor.constraint(equalToConstant: Overlay.contentWidth - 16)])
        }
        required init?(coder: NSCoder) { fatalError() }

        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {
            layer?.cornerRadius = 9
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        }

        func update(_ r: LiveRow) {
            dot.textColor = r.color
            title.stringValue = r.head + " · " + r.system
            detail.stringValue = r.sub
            pause.title = r.paused ? "Resume" : "Pause"
            pause.bezelColor = r.paused ? .systemGreen : .systemOrange
            agent.isHidden = !r.showAgent
            quick.title = r.quickLabel
            quick.isHidden = !r.showQuick
            watch.isHidden = !r.inVM
        }
    }

    private static var liveDir: URL { Store.dir.appendingPathComponent("live") }
    private static var myKey: String { Store.vmName ?? "mac" }

    /// On the main thread, once the daemon starts.
    static func install() {
        guard Config.current.overlay, panel == nil else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
                        styleMask: [.titled, .closable, .miniaturizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        p.title = "apprentice"
        // Minimizing takes it off the screen, not to the Dock: the menu bar item brings it back.
        p.standardWindowButton(.miniaturizeButton)?.target = handler
        p.standardWindowButton(.miniaturizeButton)?.action = #selector(Handler.toggleHide)
        p.level = .floating
        // On every Space and above a full-screen app, never taking focus from the work.
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.delegate = handler
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = list
        list.translatesAutoresizingMaskIntoConstraints = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: rowHeight)
        NSLayoutConstraint.activate([scroll.widthAnchor.constraint(equalToConstant: contentWidth), scrollHeight])

        // The icon opens the window: the box is always on screen, so it is the shortest way there.
        let mark = NSButton(image: Ask.icon, target: handler, action: #selector(Handler.openApp))
        mark.isBordered = false
        mark.imagePosition = .imageOnly
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.toolTip = "Open apprentice"
        mark.setAccessibilityLabel("Open apprentice")
        mark.widthAnchor.constraint(equalToConstant: 24).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 24).isActive = true
        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        expandButton.target = handler
        expandButton.action = #selector(Handler.toggleExpand)
        expandButton.bezelStyle = .rounded
        expandButton.controlSize = .regular
        expandButton.imagePosition = .imageTrailing
        expandButton.font = .boldSystemFont(ofSize: 12)
        let bar = NSStackView(views: [mark, count, NSView(), Sound.muteButton(), expandButton])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 8
        bar.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        let column = NSStackView(views: [scroll, bar])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 12, right: 12)
        p.contentView = column
        Overlay.column = column
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

    /// The cursor is about to land on `point` (screen coordinates, origin top left, as events use them). When the
    /// box would cover it, the click would hit the box instead of the page, so the box steps aside first: to the
    /// corner of that screen that is farthest from the point. It stays there; the person can drag it back.
    static func stepAside(for point: CGPoint) {
        guard Config.current.overlay else { return }
        DispatchQueue.main.sync {
            guard let p = panel, p.isVisible, let primary = NSScreen.screens.first else { return }
            let flipY = primary.frame.height
            func cg(_ f: NSRect) -> CGRect { CGRect(x: f.minX, y: flipY - f.maxY, width: f.width, height: f.height) }
            // A margin, so a target just beside the box is not clipped by its shadow or the pointer's size.
            guard cg(p.frame).insetBy(dx: -28, dy: -28).contains(point) else { return }
            let screen = NSScreen.screens.first { cg($0.frame).contains(point) } ?? NSScreen.main ?? primary
            let v = screen.visibleFrame, w = p.frame.width, h = p.frame.height, gap: CGFloat = 16
            let corners = [NSPoint(x: v.maxX - w - gap, y: v.maxY - h - gap), NSPoint(x: v.maxX - w - gap, y: v.minY + gap),
                           NSPoint(x: v.minX + gap, y: v.minY + gap), NSPoint(x: v.minX + gap, y: v.maxY - h - gap)]
            let free = corners.filter { !cg(NSRect(origin: $0, size: p.frame.size)).insetBy(dx: -28, dy: -28).contains(point) }
            guard let best = free.max(by: { a, b in
                hypot(a.x + w / 2 - (point.x), (flipY - (a.y + h / 2)) - point.y) < hypot(b.x + w / 2 - (point.x), (flipY - (b.y + h / 2)) - point.y)
            }) else { return }
            p.setFrameOrigin(best)
            p.orderFrontRegardless()
            Store.log(["overlay": "stepped aside"])
        }
        // The window server needs a moment before the click lands on what was under the box.
        Pace.sleep(0.15)
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
            Sound.cue(.handOff)
        case "Paused": Sound.cue(.paused)
        case "Stopped": Sound.cue(.stopped)
        case "Done", "Agent stopped": break
        case "Needs approval":
            Sound.cue(.approval)
            Notify.local("\(Handback.system): " + (Approvals.pending.map { "Approve or deny: \($0.summary)" } ?? "A step needs your approval"))
        default:
            if was == "Paused" { Sound.cue(.resumed) }
            else if was == "Yours", handedOver { handedOver = false; Sound.cue(.back) }
        }
    }

    /// Every daemon's row that is still alive (written in the last 4 s), this one's from memory.
    private static func allRows(mine: LiveRow) -> [LiveRow] {
        var out = [mine]
        let now = Date().timeIntervalSince1970
        for f in (try? FileManager.default.contentsOfDirectory(at: liveDir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f), let r = try? JSONDecoder().decode(LiveRow.self, from: d),
                  r.key != mine.key, now - r.at < 4, kill(r.pid, 0) == 0 else { continue }
            out.append(r)
        }
        return out.sorted { $0.key == "mac" ? $1.key != "mac" : ($1.key == "mac" ? false : $0.key < $1.key) }
    }

    /// Every live daemon's row, for the window's process (which has no row of its own).
    static func liveRows() -> [LiveRow] {
        var out: [LiveRow] = []
        let now = Date().timeIntervalSince1970
        for f in (try? FileManager.default.contentsOfDirectory(at: liveDir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f), let r = try? JSONDecoder().decode(LiveRow.self, from: d),
                  now - r.at < 4, kill(r.pid, 0) == 0 else { continue }
            out.append(r)
        }
        return out.sorted { $0.key < $1.key }
    }

    private static func publish(_ row: LiveRow) {
        var r = row
        r.at = 0
        let body = (try? JSONEncoder().encode(r)) ?? Data()
        // Rewritten when it changed, and every second as a sign this daemon is alive.
        guard body != lastJSON || Date().timeIntervalSince(lastWrite) > 1 else { return }
        lastJSON = body
        lastWrite = Date()
        try? FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
        r.at = Date().timeIntervalSince1970
        if let d = try? JSONEncoder().encode(r) { try? d.write(to: liveDir.appendingPathComponent("\(row.key).json"), options: .atomic) }
    }

    /// Whether the box is on screen, for the menu bar item that brings it back.
    static var isHidden: Bool { state.hidden }
    static var installed: Bool { panel != nil }

    /// The yellow button, and the menu bar item.
    static func toggleHidden() {
        state.toggle(lastRows.map(\.head), now: Date().timeIntervalSince1970)
        render()
    }

    private static func render() {
        Handback.tick()
        let s = status()
        chime(s.head)
        let row = LiveRow(key: myKey, system: Handback.system, head: s.head, sub: s.sub, tone: s.tone, rank: s.rank,
                          paused: Pause.on, inVM: Store.vmName != nil || Session.stored?.vm == true, stateDir: Store.stateDir.path,
                          agentPid: Handback.agentHost, agentWid: Handback.agentWindowID,
                          showAgent: Handback.banner != nil && Handback.agentHost != nil && !Handback.atAgent,
                          showQuick: counting && !Borrow.quick && Borrow.settle > Config.current.takeoverQuickS,
                          quickLabel: "Go in \(Int(Config.current.takeoverQuickS)) s", pid: getpid(), at: 0)
        publish(row)
        let all = allRows(mine: row)
        lastRows = all
        guard let p = panel else { return }
        // One box for everything: the daemon with the first key owns it, the others keep theirs hidden.
        guard all.first?.key == myKey else { if p.isVisible { p.orderOut(nil) }; return }
        if Date().timeIntervalSince(hideChecked) > 2 {
            hideChecked = Date()
            let stamp = Layers.stamp()
            if stamp != hideStamp { hideStamp = stamp; hideConfig = Config.load() }
        }
        // A command quicker than this timer's tick still counts as work.
        let heads = all.map(\.head) + (Date().timeIntervalSince(Commands.lastAt) < 1 ? ["Working"] : [])
        state.step(heads, now: Date().timeIntervalSince1970, openOnWork: hideConfig.overlayOpenOnWork, hideAfter: hideConfig.overlayHideIdleS)
        if state.hidden {
            if p.isVisible { p.orderOut(nil) }
            return
        }
        layout(all, p)
        // Back on screen if a display went away or the window was dragged off.
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(p.frame) }) { place(p) }
        Ask.keepOnScreen(p)
        p.orderFrontRegardless()
    }

    /// Fits the panel to its content, keeping the corner nearest the screen's edge where it is.
    private static func resize(_ p: NSPanel) {
        let onRight = p.frame.midX > (p.screen?.visibleFrame.midX ?? 0)
        let top = p.frame.maxY, left = p.frame.minX, right = p.frame.maxX
        column?.layoutSubtreeIfNeeded()
        p.setContentSize(column?.fittingSize ?? p.frame.size)
        p.setFrameTopLeftPoint(NSPoint(x: onRight ? right - p.frame.width : left, y: top))
    }

    private static func layout(_ all: [LiveRow], _ p: NSPanel) {
        let order = expanded ? all : [all.sorted { ($0.rank, $0.key) < ($1.rank, $1.key) }[0]]
        for k in rows.keys where !all.contains(where: { $0.key == k }) { rows[k]?.removeFromSuperview(); rows[k] = nil }
        for r in all {
            let v = rows[r.key] ?? RowView(key: r.key)
            rows[r.key] = v
            v.update(r)
        }
        let keys = order.map(\.key)
        if keys != shown {
            list.subviews.forEach { $0.removeFromSuperview() }
            for (i, k) in keys.enumerated() {
                guard let v = rows[k] else { continue }
                v.frame = NSRect(x: 0, y: CGFloat(i) * (rowHeight + rowGap), width: contentWidth, height: rowHeight)
                v.translatesAutoresizingMaskIntoConstraints = false
                list.addSubview(v)
                v.leadingAnchor.constraint(equalTo: list.leadingAnchor).isActive = true
                v.topAnchor.constraint(equalTo: list.topAnchor, constant: CGFloat(i) * (rowHeight + rowGap)).isActive = true
            }
            shown = keys
        }
        let total = CGFloat(keys.count) * (rowHeight + rowGap) - rowGap
        list.setFrameSize(NSSize(width: contentWidth, height: max(total, rowHeight)))
        let visible = min(CGFloat(min(keys.count, 3)), 3) * (rowHeight + rowGap) - rowGap
        count.stringValue = all.count > 1 ? (expanded ? "\(all.count) running" : "+\(all.count - 1) more") : ""
        expandButton.isHidden = all.count < 2
        expandButton.title = expanded ? "Less" : "All \(all.count)"
        expandButton.image = NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down", accessibilityDescription: nil)
        scroll.hasVerticalScroller = expanded && keys.count > 3
        if scrollHeight.constant != visible {
            scrollHeight.constant = visible
            resize(p)
        }
    }

    private static func status() -> (tone: String, head: String, sub: String, rank: Int) {
        let working = StatusItem.state == .working
        let engaged = working || Date().timeIntervalSince(Commands.lastAt) < engagedFor
        let wait = max(0, settle - Borrow.humanIdle)
        counting = false
        if Pause.on {
            return ("orange", "Paused", working ? "Finishing this step, then holding" : "Nothing will happen until you resume", 3)
        }
        if KillSwitch.halted { return ("red", "Stopped", "Kill switch pressed; answer or resume to go on", 1) }
        if let b = Handback.banner { return (b.good ? "green" : "orange", b.head, b.detail, 1) }
        switch StatusItem.state {
        case .waiting: return ("yellow", "Waiting for you", "A question is open", 0)
        case .approval: return ("yellow", "Needs approval", "Approve or deny from the menu bar", 0)
        default: break
        }
        if engaged && wait > 0 {
            counting = true
            return ("blue", "Yours", String(format: "You have control · back after %.0f s of stillness", wait.rounded(.up)), 2)
        }
        let what = Session.stored.map { s in [s.app, hostOf(s.url)].compactMap { $0 }.joined(separator: " · ") } ?? "Acting on screen"
        if working { return ("green", "Working", what, 4) }
        return ("gray", "Ready", "Waiting for the next command", 5)
    }

    private final class Handler: NSObject, NSWindowDelegate {
        private func row(_ sender: NSButton) -> String { sender.identifier?.rawValue ?? myKey }
        private func dir(_ key: String) -> URL {
            key == "mac" ? Store.dir : Store.dir.appendingPathComponent("vms/\(key)")
        }
        @objc func goQuicker(_ sender: NSButton) {
            // A marker in that daemon's state directory, so a VM's row works from this box too (`Borrow.quick`).
            FileManager.default.createFile(atPath: dir(row(sender)).appendingPathComponent("quick").path, contents: nil)
            Store.log(["overlay": "shortened the wait", "by": "user"])
            Overlay.render()
        }
        @objc func goToAgent(_ sender: NSButton) {
            let key = row(sender)
            guard let r = Overlay.lastRows.first(where: { $0.key == key }) else { return }
            Handback.showAgent(pid: r.agentPid, wid: r.agentWid)
        }
        @objc func watch(_ sender: NSButton) {
            // The row's own VM, in the window's VMs screen: "mac" is the daemon of this Mac, whose VM is the default one.
            let key = row(sender)
            AppShow.vm(key == "mac" ? "" : key)
        }
        @objc func togglePause(_ sender: NSButton) {
            let marker = dir(row(sender)).appendingPathComponent("paused")
            if FileManager.default.fileExists(atPath: marker.path) { try? FileManager.default.removeItem(at: marker) }
            else { FileManager.default.createFile(atPath: marker.path, contents: nil) }
            Store.log(["overlay": "pause toggled", "by": "user", "system": row(sender)])
            Overlay.render()
        }
        @objc func toggleHide() { Overlay.toggleHidden() }
        /// The icon: the window, in front. `AppBundle.open` may rebuild and sign the bundle first, which must not
        /// hold the daemon's main thread (see `AppShow.vm`).
        @objc func openApp() {
            Store.log(["overlay": "open app", "by": "user"])
            DispatchQueue.global().async { _ = AppBundle.open() }
        }
        @objc func toggleExpand() {
            Overlay.expanded.toggle()
            Overlay.shown = []
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
