import AppKit
import ApplicationServices
import Carbon

enum Pace {
    static func gaussian() -> Double {
        let u1 = Double.random(in: 1e-9..<1), u2 = Double.random(in: 0..<1)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }

    /// Log-normal gap between keystrokes, median about 100 ms by default.
    static func keyGap(after ch: Character?) -> Double {
        let p = Config.current.pace
        var gap = p.keyMedian * exp(p.keySigma * gaussian())
        if let ch, ch == " " || ch.isPunctuation { gap *= 1.6 }
        return min(max(gap, 0.04), 0.9)
    }

    /// Never traps: NaN, infinity and huge values from config become a bounded wait (B4, D3).
    static func sleep(_ seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        usleep(UInt32(min(seconds, 4000) * 1_000_000))
    }
}

enum Keys {
    static let codes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
        "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "backspace": 51, "delete": 51,
        "esc": 53, "escape": 53, "home": 115, "pageup": 116, "forwarddelete": 117, "end": 119,
        "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    /// Which key types each character on the keyboard layout in use, so shortcuts and typing hit the
    /// right key on any layout (cmd+a on AZERTY is not the US "a" key, which there is Q: cmd+q).
    /// Rebuilt when the input source changes; `codes` covers named keys and layouts it cannot read.
    private static var layoutID = ""
    private static var layoutMap: [Character: (CGKeyCode, Bool)] = [:]

    static func layout() -> [Character: (CGKeyCode, Bool)] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return [:] }
        let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        if id == layoutID { return layoutMap }
        var map: [Character: (CGKeyCode, Bool)] = [:]
        if let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue() as Data
            data.withUnsafeBytes { raw in
                guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
                // Unshifted first, so a character on two keys keeps the plain one.
                for shift in [false, true] {
                    for code in 0..<UInt16(128) {
                        var dead: UInt32 = 0
                        var chars = [UniChar](repeating: 0, count: 4)
                        var length = 0
                        let mods = UInt32(shift ? shiftKey >> 8 : 0) & 0xFF
                        guard UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
                                             OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars) == noErr,
                              length == 1, let ch = String(utf16CodeUnits: chars, count: 1).first,
                              !ch.isWhitespace, !ch.isNewline, map[ch] == nil else { continue }
                        map[ch] = (CGKeyCode(code), shift)
                    }
                }
            }
        }
        layoutID = id
        layoutMap = map
        return map
    }

    /// The key for a one-character key name on the current layout, else the US position.
    static func code(for name: String) -> CGKeyCode? {
        if name.count == 1, let ch = name.first, let hit = layout()[ch] { return hit.0 }
        return codes[name]
    }

    static func parse(_ combo: String) throws -> (CGKeyCode, CGEventFlags) {
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for part in combo.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "opt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default:
                guard let code = code(for: part) else { throw Fail(5, "unknown key \"\(part)\"") }
                guard key == nil else { throw Fail(5, "\"\(combo)\" names more than one key: send one combo per `key`") }
                key = code
            }
        }
        guard let key else { throw Fail(5, "no key in \"\(combo)\"") }
        return (key, flags)
    }

    /// A real key press on the system keyboard stream, as from a person's keyboard.
    static func press(_ combo: String) throws {
        let (code, flags) = try parse(combo)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            post(e)
            Pace.sleep(down ? Double.random(in: 0.03...0.07) : 0.02)
        }
    }

    static func typeChar(_ ch: Character) {
        if ch == "\n" {
            try? press("return")
            return
        }
        let units = Array(String(ch).utf16)
        // The key a person would press for it on the current layout; the Unicode string still
        // decides what is typed. Characters with no key keep code 0.
        let (code, shift) = keyFor(ch)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
            // Always set: an event without flags can pick up a modifier still held from a shortcut
            // just before (cmd from cmd+a), turning letters into commands.
            e.flags = shift ? .maskShift : []
            e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            post(e)
            if down { Pace.sleep(Double.random(in: 0.02...0.05)) }
        }
    }

    static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    static func keyFor(_ ch: Character) -> (CGKeyCode, Bool) {
        if ch == " " { return (codes["space"] ?? 49, false) }
        if let hit = layout()[ch] { return hit }
        if let base = shifted[ch], let code = codes[String(base)] { return (code, true) }
        let lower = Character(ch.lowercased())
        if let code = codes[String(lower)] { return (code, ch != lower) }
        return (0, false)
    }

    /// Types like a person, key by key. `fast` shortens the gaps; every key is still a real key.
    /// Throws exit 6 when the person or the kill switch stops it partway, so nothing after it (such as
    /// a return that would send a half-typed message) runs (D8).
    static func type(_ text: String, fast: Bool = false) throws {
        let began = Date()
        defer { Timing.add("type", Date().timeIntervalSince(began)) }
        Pace.sleep(Double.random(in: 0.08...0.2))
        var prev: Character?
        var sent = 0
        for ch in text {
            if KillSwitch.tripped || Watch.stopped {
                throw Fail(6, "interrupted after \(sent) of \(text.count) characters: you used the keyboard or mouse. Check the field before retrying")
            }
            sent += 1
            typeChar(ch)
            Pace.sleep(Pace.keyGap(after: prev) * (fast ? 0.35 : 1))
            prev = ch
        }
    }

    /// Pastes `text` with a real cmd+v, then puts the clipboard back. Only for places no website can
    /// see, such as the browser's address bar and system file dialogs; text inside pages is typed.
    static func paste(_ text: String) throws {
        let board = NSPasteboard.general
        let saved = board.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
        } ?? []
        board.clearContents()
        board.setString(text, forType: .string)
        Pace.sleep(0.05)
        try press("cmd+v")
        Pace.sleep(0.25)
        board.clearContents()
        let items = saved.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }

    /// Marks every event apprentice posts, so monitors can tell them from the person's own input.
    static let tag: Int64 = 0x646B_6374

    /// Every event goes through the system input stream, like a person's mouse and keyboard.
    static func post(_ e: CGEvent) {
        e.setIntegerValueField(.eventSourceUserData, value: tag)
        Borrow.lastOwnPost = Date()
        e.post(tap: .cghidEventTap)
    }
}

enum Mouse {
    static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// A random point in the middle 60% of the target, never on its edge.
    static func landing(in r: CGRect) -> CGPoint {
        CGPoint(x: r.midX + CGFloat.random(in: -0.3...0.3) * r.width,
                y: r.midY + CGFloat.random(in: -0.3...0.3) * r.height)
    }

    /// Cubic Bézier path, Fitts' law duration, ease-in-out speed, slight wobble.
    static func move(to target: CGPoint, size: CGSize = CGSize(width: 20, height: 20)) {
        let began = Date()
        defer { Timing.add("move", Date().timeIntervalSince(began)) }
        let start = location
        let dx = target.x - start.x, dy = target.y - start.y
        let dist = max(hypot(dx, dy), 1)
        let width = max(min(size.width, size.height), 8)
        let p = Config.current.pace
        let duration = min(max(0.12 + 0.11 * log2(dist / width + 1), p.moveMin), p.moveMax)
        let normal = CGPoint(x: -dy / dist, y: dx / dist)
        let side: CGFloat = Bool.random() ? 1 : -1
        let bend1 = side * dist * CGFloat.random(in: 0.08...0.25)
        let bend2 = side * dist * CGFloat.random(in: 0.03...0.15)
        let c1 = CGPoint(x: start.x + dx * 0.3 + normal.x * bend1, y: start.y + dy * 0.3 + normal.y * bend1)
        let c2 = CGPoint(x: start.x + dx * 0.7 + normal.x * bend2, y: start.y + dy * 0.7 + normal.y * bend2)
        let steps = min(max(Int(duration.isFinite ? duration * 120 : 8), 8), 600)
        for n in 1...steps {
            if KillSwitch.tripped || Borrow.interrupted { break }
            let lin = Double(n) / Double(steps)
            let t = CGFloat(lin < 0.5 ? 2 * lin * lin : 1 - pow(-2 * lin + 2, 2) / 2)
            let u = 1 - t
            var p = CGPoint(
                x: u * u * u * start.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * target.x,
                y: u * u * u * start.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * target.y)
            if n < steps {
                p.x += CGFloat.random(in: -0.6...0.6)
                p.y += CGFloat.random(in: -0.6...0.6)
            }
            if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) {
                Keys.post(e)
            }
            Borrow.noteMove(p)
            Pace.sleep(duration / Double(steps))
        }
    }

    /// Throws exit 6 when the person takes over mid-drag; the drag is cancelled, not dropped where they are.
    static func drag(from start: CGPoint, to end: CGPoint) throws {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left) else { return }
        Keys.post(down)
        Pace.sleep(0.12)
        let steps = max(Int(hypot(end.x - start.x, end.y - start.y) / 6), 12)
        for n in 1...steps {
            if KillSwitch.tripped || Borrow.interrupted {
                try? Keys.press("esc")
                if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: start, mouseButton: .left) {
                    Keys.post(up)
                }
                throw Fail(6, "interrupted: the drag was cancelled before the drop")
            }
            let t = CGFloat(n) / CGFloat(steps)
            let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            if let move = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left) {
                Keys.post(move)
            }
            Borrow.noteMove(p)
            Pace.sleep(0.012)
        }
        Pace.sleep(0.12)
        if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) {
            Keys.post(up)
        }
    }

    static func click(at p: CGPoint, right: Bool = false, double: Bool = false) {
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) =
            right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        for n in 1...(double ? 2 : 1) {
            for type in [down, up] {
                guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { continue }
                e.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                Keys.post(e)
                Pace.sleep(type == down ? Double.random(in: 0.05...0.1) : 0.02)
            }
            if double { Pace.sleep(0.08) }
        }
    }
}

enum Borrow {
    static var active = false
    static var interrupted = false

    private static var lastPosted: CGPoint?

    /// The cursor can trail the last posted move by one event, so it may sit at this point or the one before.
    static func noteMove(_ intended: CGPoint) {
        defer { lastPosted = intended }
        guard active, !interrupted, let actual = CGEvent(source: nil)?.location else { return }
        let near = [intended, lastPosted ?? intended].contains { hypot(actual.x - $0.x, actual.y - $0.y) <= 10 }
        if !near { interrupted = true }
    }

    /// Call before the step that commits an action: once it has happened, interruption is no longer an error.
    static func checkpoint() throws {
        if KillSwitch.tripped { throw Fail(6, "interrupted: the kill switch was pressed") }
        if interrupted { throw Fail(6, "interrupted: you moved the mouse or pressed a key, so nothing was done") }
    }

    static var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
    }

    /// When apprentice last posted an event, and when the person last pressed, clicked or moved.
    static var lastOwnPost = Date.distantPast
    static var lastHumanEvent = Date.distantPast

    /// Installed once, on the main run loop: every untagged key, click or move is the person's.
    static func watchHuman() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved, .scrollWheel,
                                           .leftMouseDragged, .rightMouseDragged]
        NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Keys.tag { lastHumanEvent = Date() }
        }
    }

    /// Seconds since the person last did anything. The system's idle counter restarts on apprentice's
    /// own events too, so when the last event was apprentice's, the monitor's record is used instead;
    /// otherwise the system's count stands, which also covers keys the monitor cannot see (secure input).
    static var humanIdle: Double {
        let idle = idleSeconds
        let sinceOwn = Date().timeIntervalSince(lastOwnPost)
        let lastWasOurs = abs(idle - sinceOwn) < 0.08
        return lastWasOurs ? Date().timeIntervalSince(lastHumanEvent) : idle
    }

    static func waitIdle(_ seconds: Double = 1) throws {
        let deadline = Date().addingTimeInterval(30)
        try Timing.measure("idle") {
            while humanIdle < seconds {
                if Date() > deadline { throw Fail(6, "interrupted: you were active for 30 s, try again") }
                Pace.sleep(0.2)
            }
        }
    }

    /// Every action runs here: wait until the person is idle, bring the session window forward, then
    /// act with the real cursor and keyboard. Like a person, it leaves the cursor where it landed.
    static func run<T>(_ t: Target, _ body: () throws -> T) throws -> T {
        try waitIdle()
        active = true
        // Under Watch, an interruption before this point still counts.
        if !Watch.on { interrupted = false }
        lastPosted = nil
        // Monitors belong to the main run loop, which stays free while commands run on their own queue.
        let monitor = DispatchQueue.main.sync {
            NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
                if event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Keys.tag { interrupted = true }
            }
        }
        // `gate` usually brought the window forward already; raising again only costs time.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != t.pid {
            t.app.set(kAXFrontmostAttribute, kCFBooleanTrue)
            t.window.set(kAXMainAttribute, kCFBooleanTrue)
            t.window.perform(kAXRaiseAction)
            Pace.sleep(0.2)
        }
        defer {
            active = false
            if let monitor { DispatchQueue.main.sync { NSEvent.removeMonitor(monitor) } }
        }
        return try body()
    }
}

/// While a command acts with the window in front, the person's own keys and clicks stop it,
/// so their typing never mixes with apprentice's. Posted events carry `Keys.tag` and are ignored.
enum Watch {
    private static var monitor: Any?
    static var on: Bool { monitor != nil }
    static var stopped: Bool { (on || Borrow.active) && Borrow.interrupted }

    /// Waits until the person has been idle for a moment, then starts watching.
    static func begin() throws {
        guard monitor == nil else { return }
        try Borrow.waitIdle(1)
        Borrow.interrupted = false
        monitor = DispatchQueue.main.sync {
            NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
                if event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Keys.tag { Borrow.interrupted = true }
            }
        }
    }

    /// Stops watching. True when the person interrupted.
    static func end() -> Bool {
        guard let m = monitor else { return false }
        DispatchQueue.main.sync { NSEvent.removeMonitor(m) }
        monitor = nil
        return Borrow.interrupted
    }
}
