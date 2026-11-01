import AppKit
import ApplicationServices

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

    static func sleep(_ seconds: Double) { usleep(UInt32(max(seconds, 0) * 1_000_000)) }
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
                guard let code = codes[part] else { throw Fail(5, "unknown key \"\(part)\"") }
                key = code
            }
        }
        guard let key else { throw Fail(5, "no key in \"\(combo)\"") }
        return (key, flags)
    }

    /// pid != nil sends to that app only (works in the background); nil posts to the real HID stream.
    static func press(_ combo: String, pid: pid_t?) throws {
        let (code, flags) = try parse(combo)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            post(e, pid)
            Pace.sleep(down ? Double.random(in: 0.03...0.07) : 0.02)
        }
    }

    static func typeChar(_ ch: Character, pid: pid_t?) {
        if ch == "\n" {
            try? press("return", pid: pid)
            return
        }
        let units = Array(String(ch).utf16)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
            e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            post(e, pid)
            if down { Pace.sleep(Double.random(in: 0.02...0.05)) }
        }
    }

    static func type(_ text: String, pid: pid_t?) {
        Pace.sleep(Double.random(in: 0.15...0.35))
        var prev: Character?
        for ch in text {
            if KillSwitch.tripped { return }
            typeChar(ch, pid: pid)
            Pace.sleep(Pace.keyGap(after: prev))
            prev = ch
        }
    }

    static func post(_ e: CGEvent, _ pid: pid_t?) {
        if let pid { e.postToPid(pid) } else { e.post(tap: .cghidEventTap) }
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
    static func move(to target: CGPoint, size: CGSize = CGSize(width: 20, height: 20), pid: pid_t? = nil) {
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
        let steps = max(Int(duration * 120), 8)
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
                Keys.post(e, pid)
            }
            Borrow.noteMove(p)
            Pace.sleep(duration / Double(steps))
        }
    }

    /// Throws exit 6 when the person takes over mid-drag; the drag is cancelled, not dropped where they are.
    static func drag(from start: CGPoint, to end: CGPoint) throws {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left) else { return }
        down.post(tap: .cghidEventTap)
        Pace.sleep(0.12)
        let steps = max(Int(hypot(end.x - start.x, end.y - start.y) / 6), 12)
        for n in 1...steps {
            if KillSwitch.tripped || Borrow.interrupted {
                try? Keys.press("esc", pid: nil)
                if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: start, mouseButton: .left) {
                    up.post(tap: .cghidEventTap)
                }
                throw Fail(6, "interrupted: the drag was cancelled before the drop")
            }
            let t = CGFloat(n) / CGFloat(steps)
            let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            if let move = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left) {
                move.post(tap: .cghidEventTap)
            }
            Borrow.noteMove(p)
            Pace.sleep(0.012)
        }
        Pace.sleep(0.12)
        if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) {
            up.post(tap: .cghidEventTap)
        }
    }

    static func click(at p: CGPoint, right: Bool = false, double: Bool = false, pid: pid_t? = nil) {
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) =
            right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        for n in 1...(double ? 2 : 1) {
            for type in [down, up] {
                guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { continue }
                e.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                Keys.post(e, pid)
                Pace.sleep(type == down ? Double.random(in: 0.05...0.1) : 0.02)
            }
            if double { Pace.sleep(0.08) }
        }
    }
}

enum Borrow {
    static var active = false
    static var interrupted = false

    static func noteMove(_ intended: CGPoint) {
        guard active, !interrupted, let actual = CGEvent(source: nil)?.location else { return }
        if hypot(actual.x - intended.x, actual.y - intended.y) > 10 {
            interrupted = true
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

    /// Tier 3: wait until the person is idle, bring the session window forward, act, put everything back.
    static func run<T>(_ t: Target, _ body: () throws -> T) throws -> T {
        let deadline = Date().addingTimeInterval(30)
        while idleSeconds < 2 {
            if Date() > deadline { throw Fail(6, "interrupted: you were active for 30 s, try again") }
            Pace.sleep(0.2)
        }
        let previous = NSWorkspace.shared.frontmostApplication
        let cursor = Mouse.location
        active = true
        interrupted = false
        // Monitors belong to the main run loop, which stays free while commands run on their own queue.
        // Keys only: our own posted clicks would trip a mouse-down monitor.
        let monitor = DispatchQueue.main.sync {
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ in interrupted = true }
        }
        t.app.set(kAXFrontmostAttribute, kCFBooleanTrue)
        t.window.set(kAXMainAttribute, kCFBooleanTrue)
        t.window.perform(kAXRaiseAction)
        Pace.sleep(0.3)
        defer {
            active = false
            if let monitor { DispatchQueue.main.sync { NSEvent.removeMonitor(monitor) } }
            // If the person took the pointer, it is theirs now; do not pull it back.
            if !interrupted { CGWarpMouseCursorPosition(cursor) }
            if let previous, previous.processIdentifier != t.pid {
                appElement(previous.processIdentifier).set(kAXFrontmostAttribute, kCFBooleanTrue)
            }
        }
        return try body()
    }
}
