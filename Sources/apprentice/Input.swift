import AppKit
import ApplicationServices
import Carbon

/// The person's hand: how fast they move, which way their strokes bend, and how they type. Drawn once
/// and kept in `hand.json`, shared by every VM's daemon, so a restart or an update does not turn
/// apprentice into someone else (BOT_DETECTION P5). Delete the file to draw a new hand.
struct Hand: Codable {
    /// Cursor travel time, as a multiple of the Fitts estimate.
    var speed: Double
    /// Share of strokes that bend to the favoured side.
    var side: Double
    /// Median time a key is held down, and how much it varies.
    var hold: Double
    var holdSigma: Double
    /// The gap between keys, as a multiple of the profile's `key_ms_median`.
    var rhythm: Double
    /// Share of quick letter pairs whose second key goes down before the first comes up.
    var rollover: Double
    /// Median time a mouse button is held down.
    var click: Double

    static func draw() -> Hand {
        Hand(speed: Rand.uniform(0.85...1.2), side: Rand.uniform(0.3...0.7), hold: Rand.uniform(0.075...0.115),
             holdSigma: Rand.uniform(0.18...0.3), rhythm: Rand.uniform(0.85...1.15), rollover: Rand.uniform(0.15...0.4),
             click: Rand.uniform(0.07...0.12))
    }

    /// Values from an old or hand-edited file are kept inside the ranges `draw` uses.
    var bounded: Hand {
        func b(_ v: Double, _ r: ClosedRange<Double>) -> Double { v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : r.lowerBound }
        return Hand(speed: b(speed, 0.7...1.4), side: b(side, 0.2...0.8), hold: b(hold, 0.05...0.15), holdSigma: b(holdSigma, 0.1...0.4),
                    rhythm: b(rhythm, 0.7...1.4), rollover: b(rollover, 0...0.6), click: b(click, 0.05...0.16))
    }

    static let current: Hand = {
        if let saved = Store.load(Hand.self, "hand.json") { return saved.bounded }
        let hand = draw()
        Store.save(hand, "hand.json")
        return hand
    }()
}

enum Pace {
    static func gaussian() -> Double { Rand.gaussian() }

    /// Log-normal gap between keystrokes, median about 100 ms by default. Longer after a space or
    /// punctuation; a little shorter when the two letters fall to different hands, and a little longer
    /// when one hand types both, as typing rhythm goes.
    static func keyGap(after ch: Character?, before next: Character? = nil) -> Double {
        let p = Config.current.pace
        var gap = p.keyMedian * Hand.current.rhythm * exp(p.keySigma * gaussian())
        if let ch, ch == " " || ch.isPunctuation { gap *= 1.6 }
        if let a = ch.flatMap(handOf), let b = next.flatMap(handOf) { gap *= a == b ? 1.15 : 0.85 }
        return min(max(gap, 0.035), 0.9)
    }

    /// Which hand types a letter on a QWERTY-like board: true for the left.
    static func handOf(_ ch: Character) -> Bool? {
        guard let c = ch.lowercased().first, c.isLetter || c.isNumber, c.isASCII else { return nil }
        return "qwertasdfgzxcvb12345".contains(c)
    }

    /// How long one key stays down: log-normal around the hand's own hold, shorter for the space bar's
    /// thumb, longer for a key that needs Shift.
    static func keyHold(_ ch: Character?, shifted: Bool = false) -> Double {
        let h = Hand.current
        var hold = h.hold * exp(h.holdSigma * gaussian())
        if ch == " " { hold *= 0.85 }
        if shifted { hold *= 1.1 }
        return min(max(hold, 0.035), 0.25)
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
    private static var sequenceMap: [Character: [(CGKeyCode, CGEventFlags)]] = [:]
    private static let layoutLock = NSLock()

    static func layout() -> [Character: (CGKeyCode, Bool)] { readLayout().keys }

    /// Characters the layout types with Option, or with a dead key and then a letter (é is option+e, e
    /// on a US board): the keys a person presses for them, in order (BOT_DETECTION P2, P16).
    static func sequences() -> [Character: [(CGKeyCode, CGEventFlags)]] { readLayout().sequences }

    /// The input-source calls assert they run on the main queue, and commands run on `Daemon.queue`:
    /// read there, it trapped the daemon (a VM `type`, through `Keys.parse`).
    private static func readLayout() -> (keys: [Character: (CGKeyCode, Bool)], sequences: [Character: [(CGKeyCode, CGEventFlags)]]) {
        Thread.isMainThread ? readLayoutHere() : DispatchQueue.main.sync { readLayoutHere() }
    }

    private static func readLayoutHere() -> (keys: [Character: (CGKeyCode, Bool)], sequences: [Character: [(CGKeyCode, CGEventFlags)]]) {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return ([:], [:]) }
        // The hardware keyboard type is part of the key: UCKeyTranslate reads it, so another keyboard needs a new map.
        let id = (Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String) + "|\(LMGetKbdType())"
        layoutLock.lock()
        defer { layoutLock.unlock() }
        if id == layoutID { return (layoutMap, sequenceMap) }
        var map: [Character: (CGKeyCode, Bool)] = [:]
        var seqs: [Character: [(CGKeyCode, CGEventFlags)]] = [:]
        if let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue() as Data
            data.withUnsafeBytes { raw in
                guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
                func translate(_ code: UInt16, _ mods: UInt32, _ dead: inout UInt32, noDead: Bool) -> Character? {
                    var chars = [UniChar](repeating: 0, count: 4)
                    var length = 0
                    guard UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), (mods >> 8) & 0xFF, UInt32(LMGetKbdType()),
                                         OptionBits(noDead ? kUCKeyTranslateNoDeadKeysBit : 0), &dead, 4, &length, &chars) == noErr,
                          length == 1, let ch = String(utf16CodeUnits: chars, count: 1).first,
                          !ch.isWhitespace, !ch.isNewline else { return nil }
                    return ch
                }
                // Unshifted first, so a character on two keys keeps the plain one.
                for shift in [false, true] {
                    for code in 0..<UInt16(128) {
                        var dead: UInt32 = 0
                        guard let ch = translate(code, shift ? UInt32(shiftKey) : 0, &dead, noDead: true), map[ch] == nil else { continue }
                        map[ch] = (CGKeyCode(code), shift)
                    }
                }
                let layers: [(UInt32, CGEventFlags)] = [(UInt32(optionKey), .maskAlternate), (UInt32(optionKey | shiftKey), [.maskAlternate, .maskShift])]
                // The Option layer typed directly (ß, ©, –).
                for (mods, flags) in layers {
                    for code in 0..<UInt16(128) {
                        var dead: UInt32 = 0
                        guard let ch = translate(code, mods, &dead, noDead: true), map[ch] == nil, seqs[ch] == nil else { continue }
                        // A dead key also yields its accent alone with the no-dead-keys bit; that is not what it types.
                        var probe: UInt32 = 0
                        if translate(code, mods, &probe, noDead: false) == nil, probe != 0 { continue }
                        seqs[ch] = [(CGKeyCode(code), flags)]
                    }
                }
                // Dead keys on any layer, then a plain or shifted letter: é, ñ, ü, â.
                for (mods, flags) in [(UInt32(0), CGEventFlags()), (UInt32(shiftKey), .maskShift)] + layers {
                    for code in 0..<UInt16(128) {
                        var dead: UInt32 = 0
                        guard translate(code, mods, &dead, noDead: false) == nil, dead != 0 else { continue }
                        for (mods2, flags2) in [(UInt32(0), CGEventFlags()), (UInt32(shiftKey), CGEventFlags.maskShift)] {
                            for code2 in 0..<UInt16(128) {
                                var state = dead
                                guard let ch = translate(code2, mods2, &state, noDead: false), map[ch] == nil, seqs[ch] == nil else { continue }
                                seqs[ch] = [(CGKeyCode(code), flags), (CGKeyCode(code2), flags2)]
                            }
                        }
                    }
                }
            }
        }
        layoutID = id
        layoutMap = map
        sequenceMap = seqs
        return (map, seqs)
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

    /// The modifier keys, left-hand ones as most people use, with the device bit a real keyboard sets
    /// beside the generic flag, in the order they go down.
    static let modifierKeys: [(flag: CGEventFlags, code: CGKeyCode, device: UInt64)] = [
        (.maskControl, 59, 0x01), (.maskAlternate, 58, 0x20), (.maskShift, 56, 0x02), (.maskCommand, 55, 0x08),
    ]

    /// The flags field of an event while `held` modifiers are down, device bits included.
    static func eventFlags(_ held: CGEventFlags) -> CGEventFlags {
        var raw = held.rawValue | CGEventFlags.maskNonCoalesced.rawValue
        for m in modifierKeys where held.contains(m.flag) { raw |= m.device }
        return CGEventFlags(rawValue: raw)
    }

    /// Presses (or releases, in the reverse order) each modifier in `flags` that is not already in
    /// `held`, one flagsChanged event per key as a keyboard sends them, so a page sees Shift go down
    /// before a capital and cmd before cmd+a (BOT_DETECTION P3).
    static func modifiers(_ flags: CGEventFlags, down: Bool, held: inout CGEventFlags) {
        for m in (down ? modifierKeys : modifierKeys.reversed()) where flags.contains(m.flag) && held.contains(m.flag) != down {
            if down { held.insert(m.flag) } else { held.remove(m.flag) }
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: m.code, keyDown: down) else { continue }
            e.type = .flagsChanged
            e.flags = eventFlags(held)
            post(e)
            Pace.sleep(Rand.uniform(0.025...0.07))
        }
    }

    /// A real key press on the system keyboard stream, as from a person's keyboard: its modifiers go
    /// down first and come up after it.
    static func press(_ combo: String) throws {
        let (code, flags) = try parse(combo)
        if Remote.active { return try Remote.press(combo) }
        var held: CGEventFlags = []
        modifiers(flags, down: true, held: &held)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
            e.flags = eventFlags(held)
            post(e)
            // Held as long as a typed key: return, delete and tab land in page forms too.
            Pace.sleep(down ? Pace.keyHold(nil) : Rand.uniform(0.015...0.04))
        }
        modifiers(flags, down: false, held: &held)
    }

    /// One key of typed text: the key, the modifiers it needs, and the text it carries (nil lets the
    /// layout decide, as for the two keys of a dead-key accent).
    struct Stroke {
        var code: CGKeyCode
        var flags: CGEventFlags
        var text: [UniChar]?
    }

    /// The keys a person presses for `ch` on the current layout, or nil when no key types it (an
    /// emoji, CJK without an input method), which is then pasted instead of typed on the wrong key.
    static func strokes(for ch: Character) -> [Stroke]? {
        let units = Array(String(ch).utf16)
        if ch == " " { return [Stroke(code: codes["space"] ?? 49, flags: [], text: units)] }
        let keys = layout()
        if let (code, shift) = keys[ch] { return [Stroke(code: code, flags: shift ? .maskShift : [], text: units)] }
        if let seq = sequences()[ch] {
            // A one-key Option character carries its text; the two keys of an accent let the layout compose it.
            if seq.count == 1 { return [Stroke(code: seq[0].0, flags: seq[0].1, text: units)] }
            return seq.map { Stroke(code: $0.0, flags: $0.1, text: nil) }
        }
        // The US positions only when the layout could not be read at all; on a known layout they would
        // put the character on a key that types something else.
        guard keys.isEmpty else { return nil }
        if let base = shifted[ch], let code = codes[String(base)] { return [Stroke(code: code, flags: .maskShift, text: units)] }
        let lower = Character(ch.lowercased().count == 1 ? ch.lowercased() : String(ch))
        if let code = codes[String(lower)] { return [Stroke(code: code, flags: ch != lower ? .maskShift : [], text: units)] }
        return nil
    }

    /// One key going down or up, with the modifiers held now.
    private static func send(_ s: Stroke, down: Bool, held: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: s.code, keyDown: down) else { return }
        // Always set: an event without flags can pick up a modifier still held from a shortcut
        // just before (cmd from cmd+a), turning letters into commands.
        e.flags = eventFlags(held)
        if let text = s.text { e.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text) }
        post(e)
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
        guard let strokes = strokes(for: ch) else {
            try? paste(String(ch))
            return
        }
        var held: CGEventFlags = []
        for s in strokes {
            modifiers(held.subtracting(s.flags), down: false, held: &held)
            modifiers(s.flags, down: true, held: &held)
            send(s, down: true, held: held)
            Pace.sleep(Pace.keyHold(ch, shifted: s.flags.contains(.maskShift)))
            send(s, down: false, held: held)
            if strokes.count > 1 { Pace.sleep(Rand.uniform(0.06...0.16)) }
        }
        modifiers(held, down: false, held: &held)
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

    /// A key that is down and the time it comes up, so the next key can go down first (rollover).
    private struct Pending {
        var stroke: Stroke
        var upAt: Double
    }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    private static func wait(until t: Double) { Pace.sleep(t - now) }

    /// Types like a person, key by key. `fast` shortens the gaps; every key is still a real key.
    /// Each key is held for its own time and, for a quick pair of letters on different hands, the
    /// next key often goes down before the last one is up, as fluent typing overlaps (P1, A4). Shift
    /// is a key of its own, held across a run of capitals. Characters no key types are pasted.
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
        var pending: Pending?
        var held: CGEventFlags = []
        // Whatever stops the typing, no key and no Shift is left down.
        func release() {
            if let p = pending {
                wait(until: p.upAt)
                send(p.stroke, down: false, held: held)
                pending = nil
            }
            modifiers(held, down: false, held: &held)
        }
        defer { if !Remote.active { release() } }
        for ch in text {
            if KillSwitch.tripped || Watch.stopped {
                throw Fail(6, "interrupted after \(sent) of \(text.count) characters: you used the keyboard or mouse. Check the field before retrying")
            }
            sent += 1
            let gap = Pace.keyGap(after: prev, before: ch) * (fast ? 0.35 : 1)
            // Character(String) traps when a letter lowercases to two characters (İ): skip those.
            let lower = ch.lowercased()
            if slips < 3, rate > 0, lower.count == 1, let key = lower.first,
               Rand.chance(rate), let near = neighbours[key].flatMap({ Rand.pick(Array($0)) }) {
                slips += 1
                if !Remote.active { release() }
                typeChar(ch.isUppercase ? Character(near.uppercased()) : near)
                Pace.sleep(Rand.uniform(0.1...0.35))
                try press("delete")
                Pace.sleep(Rand.uniform(0.08...0.2))
            }
            let strokes = Remote.active || ch.isNewline ? nil : strokes(for: ch)
            if let strokes, strokes.count == 1, let s = strokes.first {
                let shifted = s.flags.contains(.maskShift)
                // The previous key's down time is `upAt - hold`; this one goes down a gap after it is up,
                // or, rolled over, while it is still down. Never across a change of modifiers.
                var downAt = (pending?.upAt ?? now) + gap
                if let p = pending, held == s.flags, !fast, prev.flatMap(Pace.handOf) != nil,
                   Pace.handOf(ch).map({ $0 != prev.flatMap(Pace.handOf) }) == true, Rand.chance(Hand.current.rollover) {
                    downAt = p.upAt - Rand.uniform(0.01...0.045)
                }
                if let p = pending, p.upAt <= downAt || held != s.flags {
                    wait(until: p.upAt)
                    send(p.stroke, down: false, held: held)
                    pending = nil
                }
                if held != s.flags {
                    modifiers(held.subtracting(s.flags), down: false, held: &held)
                    wait(until: downAt - 0.05)
                    modifiers(s.flags, down: true, held: &held)
                }
                wait(until: downAt)
                send(s, down: true, held: held)
                let upAt = now + Pace.keyHold(ch, shifted: shifted)
                if let p = pending {
                    // Rolled over: the earlier key comes up while this one is down.
                    wait(until: p.upAt)
                    send(p.stroke, down: false, held: held)
                }
                pending = Pending(stroke: s, upAt: upAt)
            } else {
                // A line break, an accent typed as two keys, a pasted character, or the VM: one at a time.
                if !Remote.active { release() }
                typeChar(ch, newline: newline)
                Pace.sleep(gap)
            }
            // A pause to think now and then, at the end of a word.
            if !fast, ch == " " || ch.isPunctuation, sent >= nextPause {
                if !Remote.active { release() }
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
        // Lazily provided types (promises, Continuity items) have no data yet: they are skipped, and an item
        // left with no type is not put back as an empty entry.
        let saved = (board.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { out, type in
                if let data = item.data(forType: type) { out[type] = data }
            }
        }.filter { !$0.isEmpty }
        // Runs on every exit, so a throw between the clear and the paste still gives the clipboard back.
        defer {
            if !saved.isEmpty {
                board.clearContents()
                board.writeObjects(saved.map { types -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in types { item.setData(data, forType: type) }
                    return item
                })
            }
        }
        board.clearContents()
        board.setString(text, forType: .string)
        Pace.sleep(0.05)
        try press("cmd+v")
        Pace.sleep(0.25)
    }

    /// Marks every event apprentice posts, so monitors can tell them from the person's own input. Drawn
    /// anew each time the daemon starts: a constant would be one value any app could look for on every
    /// install (BOT_DETECTION A1). The events are still visibly posted ones (A2); this only drops the signature.
    /// Kept inside 31 bits like the old constant: a value that needs more could come back cut short on
    /// a path that carries the field as 32 bits, and the person's own input check would see a stranger.
    static let tag: Int64 = Int64.random(in: 0x1000_0000...0x7FFF_FFFF)

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

    /// The person's hand (`Hand`), kept across restarts, so moves vary around one person's habits
    /// instead of around a fixed mean that every install shares.
    static var hand: Hand { Hand.current }

    /// How long a move of `fitts` seconds takes under the profile's `move_ms`. Above the top of the range
    /// it still grows, slowly, so long moves do not all take exactly the cap (BOT_DETECTION P4).
    static func duration(_ fitts: Double, _ p: PaceConfig) -> Double {
        guard fitts > p.moveMax else { return max(fitts, p.moveMin) }
        return min(p.moveMax * (1 + 0.35 * log(fitts / p.moveMax)) * Rand.logNormal(median: 1, sigma: 0.08), p.moveMax * 2.5)
    }

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
        let duration = duration(fitts, p)
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
        // About the rate a mouse reports at, drawn per stroke so no two share one beat.
        let steps = min(max(Int(duration.isFinite ? duration * Rand.uniform(100.0...135.0) : 8), 4), 600)
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

    /// Where the last posted move went, for the next one's deltas.
    private static var lastSample: CGPoint?

    /// A move carries how far it went since the last one, as a mouse reports it, so a page's
    /// `movementX`/`movementY` agree with the coordinates (BOT_DETECTION P19).
    private static func post(_ p: CGPoint, _ type: CGEventType = .mouseMoved) {
        if let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left) {
            let actual = Remote.active ? Remote.cursor : location
            // The cursor can trail the last posted move by one event; anything further means it moved on its own.
            let from = lastSample.flatMap { hypot($0.x - actual.x, $0.y - actual.y) <= 10 ? $0 : nil } ?? actual
            e.setIntegerValueField(.mouseEventDeltaX, value: Int64((p.x - from.x).rounded()))
            e.setIntegerValueField(.mouseEventDeltaY, value: Int64((p.y - from.y).rounded()))
            Keys.post(e)
        }
        lastSample = p
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
                // The hand's own press length, log-normal: mostly near it, now and then a long one.
                Pace.sleep(type == down ? min(max(Rand.logNormal(median: hand.click, sigma: 0.3), 0.04), 0.3) : Rand.uniform(0.015...0.04))
            }
            if double { Pace.sleep(Rand.uniform(0.07...0.13)) }
        }
    }
}

enum Borrow {
    static var active = false
    static var interrupted = false

    /// The last few posted moves, newest last.
    private static var recent: [CGPoint] = []

    /// The cursor can trail a fast stroke by a few events (a busy system delivers them late), so it may sit
    /// at any of the last few posted points. A person taking the mouse moves it well past that. A stop
    /// is logged with both points, so one nobody caused can be traced.
    static func noteMove(_ intended: CGPoint) {
        defer { recent = Array((recent + [intended]).suffix(4)) }
        guard active, !interrupted, let actual = CGEvent(source: nil)?.location else { return }
        let near = (recent + [intended]).contains { hypot(actual.x - $0.x, actual.y - $0.y) <= 14 }
        if !near {
            interrupted = true
            Store.log(["interrupt": "cursor", "intended": [Int(intended.x), Int(intended.y)], "actual": [Int(actual.x), Int(actual.y)]])
        }
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
        let data = event.cgEvent?.getIntegerValueField(.eventSourceUserData)
        if data == Keys.tag { return false }
        guard event.type != .scrollWheel || event.momentumPhase.isEmpty else { return false }
        // What stopped a command goes in the log, so a stop nobody caused can be traced to its source.
        if !interrupted {
            let pid = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? 0
            Store.log(["interrupt": "\(event.type.rawValue)", "source_pid": pid, "tagged": data.map { $0 != 0 } ?? false])
        }
        return true
    }

    static func waitIdle(_ seconds: Double = 1) throws {
        Pause.wait()
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
        // Where the cursor is now counts too: the first sample of a quick stroke can land far from it.
        recent = [CGEvent(source: nil)?.location].compactMap { $0 }
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
        // A person takes a moment to see the screen before the hand moves (BOT_DETECTION P13).
        if Config.current.pace.mode != "fast" { Pace.sleep(min(max(Rand.logNormal(median: 0.22, sigma: 0.35), 0.1), 0.9)) }
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
