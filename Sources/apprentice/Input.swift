import AppKit
import ApplicationServices
import Carbon

// TODO(/interview-code): post the modifier keys themselves (a flagsChanged press of Shift before a
// capital, of cmd before cmd+a, released after), as a real keyboard does. Today a page sees a keydown
// with shiftKey or metaKey set but never a "Shift" or "Meta" keydown before it, a keystroke tell
// (SPEC "What it does not leak" claims shiftKey matches a real keyboard). Touches every key apprentice
// sends, so it needs a run on real hardware and in the VM (Remote.typeChar) before it lands.

enum Pace {
    static func gaussian() -> Double { Rand.gaussian() }

    /// Log-normal gap between keystrokes, median about 100 ms by default.
    static func keyGap(after ch: Character?) -> Double {
        let p = Config.current.pace
        var gap = p.keyMedian * exp(p.keySigma * gaussian())
        if let ch, ch == " " || ch.isPunctuation { gap *= 1.6 }
        return min(max(gap, 0.04), 0.9)
    }

    /// The pause between two steps of a flow, which an agent's thinking time would otherwise have
    /// filled: a log-normal look around 0.9 s, about 120 ms more for each new thing on screen (at
    /// most 4 s), and one step in eight a 2–5 s hesitation. A flow never runs at one steady beat.
    static func lookGap(newLines: Int) -> Double {
        var gap = 0.9 * exp(0.45 * gaussian())
        gap += min(Double(newLines) * Rand.uniform(0.08...0.16), 4)
        if Rand.chance(1.0 / 8) { gap += Rand.uniform(2.0...5.0) }
        return min(max(gap, 0.35), 10)
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
        if Remote.active { return try Remote.press(combo) }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            post(e)
            // Held as long as a typed key (50–110 ms): return, delete and tab land in page forms too.
            Pace.sleep(down ? Rand.uniform(0.05...0.11) : 0.02)
        }
    }

    /// `newline` is the key a line break in the text is typed with: plain return in apps, or shift+return
    /// where return would send (a chat composer on a web page), so text with line breaks never goes out
    /// in pieces.
    static func typeChar(_ ch: Character, newline: String = "return") {
        if ch == "\n" || ch == "\r\n" || ch == "\r" {
            try? press(newline)
            return
        }
        if Remote.active { return Remote.typeChar(ch) }
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
            if down { Pace.sleep(Rand.uniform(0.05...0.11)) }
        }
    }

    /// Keys next to each letter on a QWERTY board, for the occasional slip that is then corrected.
    static let neighbours: [Character: String] = [
        "q": "wa", "w": "qes", "e": "wrd", "r": "etf", "t": "ryg", "y": "tuh", "u": "yij", "i": "uok", "o": "ipl",
        "p": "ol", "a": "qsz", "s": "awdx", "d": "sefc", "f": "drgv", "g": "fthb", "h": "gyjn", "j": "hukm",
        "k": "jil", "l": "ko", "z": "asx", "x": "zsc", "c": "xdv", "v": "cfb", "b": "vgn", "n": "bhm", "m": "nj",
    ]

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
    /// At the profile's `key_error_rate`, a letter is first mistyped as a neighbouring key and corrected
    /// with backspace, never in a password field (`corrections: false`) or with `fast`.
    /// Throws exit 6 when the person or the kill switch stops it partway, so nothing after it (such as
    /// a return that would send a half-typed message) runs (D8).
    static func type(_ text: String, fast: Bool = false, corrections: Bool = false, newline: String = "return") throws {
        let began = Date()
        defer { Timing.add("type", Date().timeIntervalSince(began)) }
        Pace.sleep(Rand.uniform(0.08...0.2))
        let rate = fast || !corrections ? 0 : Config.current.pace.keyErrorRate
        var prev: Character?
        var sent = 0
        var slips = 0
        var nextPause = Rand.uniform(20...40)
        for ch in text {
            if KillSwitch.tripped || Watch.stopped {
                throw Fail(6, "interrupted after \(sent) of \(text.count) characters: you used the keyboard or mouse. Check the field before retrying")
            }
            sent += 1
            // Character(String) traps when a letter lowercases to two characters (İ): skip those.
            let lower = ch.lowercased()
            if slips < 3, rate > 0, lower.count == 1, let key = lower.first,
               Rand.chance(rate), let near = neighbours[key].flatMap({ Rand.pick(Array($0)) }) {
                slips += 1
                typeChar(ch.isUppercase ? Character(near.uppercased()) : near)
                Pace.sleep(Rand.uniform(0.1...0.35))
                try press("delete")
                Pace.sleep(Rand.uniform(0.08...0.2))
            }
            typeChar(ch, newline: newline)
            Pace.sleep(Pace.keyGap(after: prev) * (fast ? 0.35 : 1))
            // A pause to think now and then, at the end of a word.
            if !fast, ch == " " || ch.isPunctuation, sent >= nextPause {
                Pace.sleep(Rand.uniform(0.5...1.8))
                nextPause = sent + Rand.uniform(20...40)
            }
            prev = ch
        }
    }

    /// Pastes `text` with a real cmd+v, then puts the clipboard back. Only for places no website can
    /// see, such as the browser's address bar and system file dialogs; text inside pages is typed.
    static func paste(_ text: String) throws {
        // The VM has no clipboard of this Mac's; its address bar is typed into quickly instead.
        if Remote.active { return try type(text, fast: true) }
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
        if Remote.active { return Remote.post(e) }
        e.setIntegerValueField(.eventSourceUserData, value: tag)
        Borrow.lastOwnPost = Date()
        e.post(tap: .cghidEventTap)
    }
}

enum Mouse {
    static var location: CGPoint { Remote.active ? Remote.cursor : CGEvent(source: nil)?.location ?? .zero }

    /// A point near the middle of the target, clustered as people's clicks are, and never within 8%
    /// of its edge.
    static func landing(in r: CGRect) -> CGPoint {
        func offset() -> CGFloat { CGFloat(min(max(Pace.gaussian() * Rand.uniform(0.12...0.18), -0.42), 0.42)) }
        return CGPoint(x: r.midX + offset() * r.width, y: r.midY + offset() * r.height)
    }

    /// This run's hand: a speed and a favoured side drawn once when the daemon starts, so moves vary
    /// around one person's habits instead of around a fixed mean that every install shares.
    static let hand = (speed: Rand.uniform(0.85...1.2), side: Rand.uniform(0.3...0.7))

    /// Fitts' law duration along a curved path. Longer moves arrive in two phases, as a hand does: a
    /// fast reach that stops a little short of or past the target (`overshoot` of the time), then a
    /// slower correction onto it, sometimes in two steps.
    static func move(to target: CGPoint, size: CGSize = CGSize(width: 20, height: 20)) {
        let began = Date()
        defer { Timing.add("move", Date().timeIntervalSince(began)) }
        let start = location
        let dx = target.x - start.x, dy = target.y - start.y
        let dist = max(hypot(dx, dy), 1)
        let width = max(min(size.width, size.height), 8)
        let p = Config.current.pace
        let fitts = (0.12 + 0.11 * log2(dist / width + 1)) * hand.speed * Rand.logNormal(median: 1, sigma: 0.12)
        let duration = min(max(fitts, p.moveMin), p.moveMax)
        guard dist > 120 else {
            stroke(from: start, to: target, duration: duration, bend: 0.5)
            return
        }
        let ux = dx / dist, uy = dy / dist
        // Past the target by 1.5–5% of the way (3–40 px), or short of it by 3–8%, a little off the line.
        let over = Rand.chance(p.overshoot)
        let along = over ? dist + min(max(dist * Rand.uniform(0.015...0.05), 3), 40) : dist * Rand.uniform(0.92...0.97)
        let off = Rand.uniform(-1.0...1.0) * min(dist * 0.02, 6)
        let reach = CGPoint(x: start.x + ux * along - uy * off, y: start.y + uy * along + ux * off)
        stroke(from: start, to: reach, duration: duration * 0.85, bend: 1)
        if KillSwitch.tripped || Borrow.interrupted { return }
        // One correction in four lands short first and nudges again.
        if over || !Rand.chance(0.25) {
            stroke(from: reach, to: target, duration: Rand.uniform(0.04...0.14), bend: 0.2)
        } else {
            let mid = CGPoint(x: reach.x + (target.x - reach.x) * Rand.uniform(0.6...0.85) + Rand.uniform(-1.5...1.5),
                              y: reach.y + (target.y - reach.y) * Rand.uniform(0.6...0.85) + Rand.uniform(-1.5...1.5))
            stroke(from: reach, to: mid, duration: Rand.uniform(0.04...0.1), bend: 0.2)
            Pace.sleep(Rand.uniform(0.02...0.08))
            stroke(from: mid, to: target, duration: Rand.uniform(0.03...0.09), bend: 0.1)
        }
    }

    /// The path a stroke follows. Picked per stroke, so no two moves share one curve family.
    enum Shape: CaseIterable { case bow, arc, wave, tremor, flat }
    /// How speed rises and falls along a stroke.
    enum Speed: CaseIterable { case skewed, minJerk, quickStart }

    /// Where along the stroke (0…1) the cursor is at time `x` (0…1).
    static func progress(_ speed: Speed, _ x: Double, skew: Double) -> Double {
        switch speed {
        case .skewed:
            let lin = pow(x, skew)
            return lin < 0.5 ? 2 * lin * lin : 1 - pow(-2 * lin + 2, 2) / 2
        case .minJerk:
            return x * x * x * (10 - 15 * x + 6 * x * x)
        case .quickStart:
            return 1 - pow(1 - x, 2.6)
        }
    }

    /// One curved stroke, with a shape and speed profile drawn for it. Speed peaks early and tails off
    /// into the end, the samples are a little uneven in time as a real mouse reports them, and a long
    /// stroke now and then hesitates once on the way.
    private static func stroke(from start: CGPoint, to end: CGPoint, duration: Double, bend: CGFloat,
                               type: CGEventType = .mouseMoved) {
        let dx = end.x - start.x, dy = end.y - start.y
        let dist = max(hypot(dx, dy), 1)
        let normal = CGPoint(x: -dy / dist, y: dx / dist)
        let shape = Rand.weighted([(Shape.bow, 4.0), (.arc, 2), (.wave, 1.5), (.tremor, 1.5), (.flat, 1)])
        let speed = Rand.weighted([(Speed.skewed, 3.0), (.minJerk, 2), (.quickStart, 1)])
        let side: CGFloat = Rand.chance(hand.side) ? 1 : -1
        var bend1 = side * dist * Rand.uniform(0.08...0.25) * bend
        var bend2 = side * dist * Rand.uniform(0.03...0.15) * bend
        switch shape {
        case .bow: break
        case .arc: bend2 = bend1 * Rand.uniform(0.8...1.1)
        case .wave: bend2 = -bend2 * Rand.uniform(0.8...1.6)
        case .tremor: break
        case .flat: bend1 *= 0.25; bend2 *= 0.25
        }
        let c1 = CGPoint(x: start.x + dx * 0.3 + normal.x * bend1, y: start.y + dy * 0.3 + normal.y * bend1)
        let c2 = CGPoint(x: start.x + dx * 0.7 + normal.x * bend2, y: start.y + dy * 0.7 + normal.y * bend2)
        let steps = min(max(Int(duration.isFinite ? duration * 120 : 8), 4), 600)
        let skew = Rand.uniform(0.75...0.9)
        // A tremor is a slow wobble across the line: 1–3 cycles of up to 2 px.
        let wobble = shape == .tremor ? (amp: Rand.uniform(0.6...2.0), cycles: Rand.uniform(1.0...3.0), phase: Rand.uniform(0.0...(2 * .pi)))
                                      : (amp: 0.0, cycles: 0.0, phase: 0.0)
        let pauseAt = dist > 300 && Rand.chance(0.06) ? Rand.uniform(steps / 3...max(steps / 3, steps * 2 / 3)) : -1
        let jitter = Rand.uniform(0.3...0.8)
        for n in 1...steps {
            if KillSwitch.tripped || Borrow.interrupted { break }
            let t = CGFloat(progress(speed, Double(n) / Double(steps), skew: skew))
            let u = 1 - t
            var p = CGPoint(
                x: u * u * u * start.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * end.x,
                y: u * u * u * start.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * end.y)
            if n < steps {
                let w = CGFloat(wobble.amp * sin(wobble.phase + 2 * .pi * wobble.cycles * Double(t)) * Double(sin(.pi * t)))
                p.x += normal.x * w + Rand.uniform(-jitter...jitter)
                p.y += normal.y * w + Rand.uniform(-jitter...jitter)
            }
            post(p, type)
            Pace.sleep(duration / Double(steps) * Rand.uniform(0.7...1.3))
            if n == pauseAt { Pace.sleep(Rand.uniform(0.06...0.2)) }
        }
    }

    private static func post(_ p: CGPoint, _ type: CGEventType = .mouseMoved) {
        if let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left) {
            Keys.post(e)
        }
        Borrow.noteMove(p)
    }

    /// The hand coming to rest over a target: 40–120 ms with a pixel or so of movement. Returns
    /// where the cursor ended, which is where the click lands.
    static func settle(at p: CGPoint) -> CGPoint {
        var at = p
        for _ in 0..<Rand.uniform(1...3) {
            Pace.sleep(Rand.uniform(0.015...0.04))
            at = CGPoint(x: p.x + Rand.uniform(-1.5...1.5), y: p.y + Rand.uniform(-1.5...1.5))
            post(at)
        }
        Pace.sleep(Rand.uniform(0.02...0.05))
        return at
    }

    /// Rests for `seconds` while a page is being read, drifting the cursor a few pixels every few
    /// seconds. It stops drifting while the person moves the mouse themselves.
    static func linger(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if KillSwitch.tripped || Watch.stopped { return }
            Pace.sleep(min(Rand.uniform(2.0...5.0), end.timeIntervalSinceNow))
            guard Date() < end, Remote.active || Borrow.humanIdle > 1 else { continue }
            drift(Rand.uniform(5.0...20.0))
        }
    }

    /// A small idle move of about `r` px in any direction.
    static func drift(_ r: Double) {
        let from = location
        let angle = Rand.uniform(0.0..<(2 * .pi))
        stroke(from: from, to: CGPoint(x: from.x + CGFloat(r * cos(angle)), y: from.y + CGFloat(r * sin(angle))),
               duration: Rand.uniform(0.12...0.3), bend: 0.3)
    }

    /// Throws exit 6 when the person takes over mid-drag; the drag is cancelled, not dropped where they are.
    /// The press is held a moment before moving, then the pointer travels one stroke with a drawn shape,
    /// speed profile and uneven samples, as `move` does: a straight line at one steady speed is a tell.
    /// Slower than a free move, since a drop target needs the pointer to arrive; nearly straight, so the
    /// path stays inside the window.
    static func drag(from start: CGPoint, to end: CGPoint) throws {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left) else { return }
        Keys.post(down)
        Pace.sleep(Rand.uniform(0.1...0.22))
        let p = Config.current.pace
        let dist = max(hypot(end.x - start.x, end.y - start.y), 1)
        let fitts = (0.12 + 0.11 * log2(dist / 20 + 1)) * hand.speed * Rand.logNormal(median: 1, sigma: 0.12) * 1.5
        let duration = min(max(fitts, p.moveMin), max(p.moveMax * 3, 1))
        stroke(from: start, to: end, duration: duration, bend: 0.1, type: .leftMouseDragged)
        if KillSwitch.tripped || Borrow.interrupted {
            try? Keys.press("esc")
            if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: start, mouseButton: .left) {
                Keys.post(up)
            }
            throw Fail(6, "interrupted: the drag was cancelled before the drop")
        }
        Pace.sleep(Rand.uniform(0.08...0.2))
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
                Pace.sleep(type == down ? Rand.uniform(0.06...0.14) : 0.02)
            }
            if double { Pace.sleep(Rand.uniform(0.07...0.13)) }
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

    /// What stops a command: the person's keys, clicks and scrolls. A scroll moves what the next click
    /// aims at, so it counts as much as a click. The tail of a trackpad flick from before the command
    /// (momentum) is not them acting now.
    static let interruptions: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]

    static func isPersons(_ event: NSEvent) -> Bool {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == Keys.tag { return false }
        return event.type != .scrollWheel || event.momentumPhase.isEmpty
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
            NSEvent.addGlobalMonitorForEvents(matching: interruptions) { event in
                if isPersons(event) { interrupted = true }
            }
        }
        // `gate` usually brought the window forward already; raising again only costs time.
        t.raise()
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
            NSEvent.addGlobalMonitorForEvents(matching: Borrow.interruptions) { event in
                if Borrow.isPersons(event) { Borrow.interrupted = true }
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
