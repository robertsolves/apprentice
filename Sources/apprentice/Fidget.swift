import AppKit

/// The wheel, turned as a finger turns it: flicks of a few notches, quick in the middle of a flick and
/// slower at either end, with a short rest between flicks. Used by `scroll`, `browse` and fidgets, on
/// this Mac and in the VM alike (`Keys.post` sends to the guest while `Remote.active`).
enum Wheel {
    static var stopped: Bool { KillSwitch.tripped || Watch.stopped || (!Remote.active && Borrow.interrupted) }

    /// One notch: `lines` up (positive) or down, or with `sideways` left (positive) or right.
    static func notch(_ lines: Int32, at point: CGPoint, sideways: Bool = false) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                  wheel1: sideways ? 0 : lines, wheel2: sideways ? lines : 0, wheel3: 0) else { return }
        event.location = point
        Keys.post(event)
    }

    /// Scrolls `lines` (down when `down`) under the cursor; with `sideways`, right when `down`.
    static func scroll(lines total: Int, down: Bool, sideways: Bool = false) {
        let sign: Int32 = down ? -1 : 1
        var left = total
        while left > 0, !stopped {
            let flick = min(left, Rand.uniform(3...9))
            var notches: [Int] = []
            var queued = 0
            while queued < flick {
                let n = min(flick - queued, Rand.uniform(1...3))
                notches.append(n)
                queued += n
            }
            for (i, n) in notches.enumerated() {
                if stopped { return }
                notch(sign * Int32(n), at: Mouse.location, sideways: sideways)
                let x = Double(i + 1) / Double(notches.count)
                Pace.sleep((0.025 + 0.06 * pow(2 * x - 1, 2)) * Rand.uniform(0.7...1.3))
            }
            left -= flick
            if left > 0 { Pace.sleep(Rand.uniform(0.12...0.45)) }
        }
    }

    /// `browse`: reads down a page or feed for `seconds`. Each turn scrolls 4–15 lines, then reads for
    /// a log-normal pause around 3 s with the cursor drifting; one turn in eight looks back up a little.
    /// Clicks and types nothing. Returns the lines scrolled down and back up.
    static func browse(_ seconds: Double) -> (down: Int, up: Int) {
        let end = Date().addingTimeInterval(seconds)
        var down = 0, up = 0
        func left() -> Double { max(end.timeIntervalSinceNow, 0) }
        while left() > 0, !stopped {
            let lines = Rand.uniform(4...15)
            scroll(lines: lines, down: true)
            down += lines
            Mouse.linger(min(Rand.logNormal(median: 3, sigma: 0.6), 15, left()))
            if Rand.chance(1.0 / 8), left() > 1, !stopped {
                let back = Rand.uniform(2...6)
                scroll(lines: back, down: false)
                up += back
                Mouse.linger(min(Rand.uniform(1.0...4.0), left()))
            }
        }
        return (down, up)
    }
}

/// Now and then after an action (the profile's `fidget` share, off by default), the hand does
/// something that changes nothing: glances the cursor across the window, traces a few lines as if
/// reading, rests with a drift, or on a web page scrolls down a little and back. Never a click, a key
/// or a hover held on purpose, so a fidget cannot act on anything. It runs once per command, in
/// `finish` after every step and before the re-read, so the diff the agent sees is of the screen as
/// it was left and no later step aims at a point the fidget scrolled away.
enum Fidget {
    enum Kind { case glance, trace, rest, peek }

    /// What a command ends with: nothing, a fidget, or (on a web page, the profile's `browse` share) a
    /// spell of reading down the feed. Never after `hover`, whose point is where the cursor rests, or
    /// after `browse`, which already did.
    enum Plan { case fidget, browse(Double) }

    static func plan(after command: String, web: Bool) -> Plan? {
        let p = Config.current.pace
        guard command != "hover", command != "browse", !KillSwitch.tripped else { return nil }
        if web, p.browseShare > 0, Rand.chance(p.browseShare) { return .browse(Rand.uniform(p.browseMin...p.browseMax)) }
        if p.fidget > 0, Rand.chance(p.fidget) { return .fidget }
        return nil
    }

    static func perform(_ plan: Plan, in area: CGRect, web: Bool) {
        switch plan {
        case .fidget: run(in: area, web: web)
        case .browse(let seconds): browse(seconds, in: area)
        }
    }

    /// Reads down the feed from the middle of the window, then scrolls back up as far as it went, so the
    /// agent's screen ends about where its action left it. Logged as `waits.browse`.
    static func browse(_ seconds: Double, in area: CGRect) {
        guard !Wheel.stopped, area.width > 200, area.height > 200 else { return }
        Timing.measure("browse") {
            let middle = area.insetBy(dx: area.width * 0.3, dy: area.height * 0.3)
            Mouse.move(to: Mouse.landing(in: middle), size: middle.size)
            Pace.sleep(Rand.uniform(0.15...0.4))
            let moved = Wheel.browse(seconds)
            Pace.sleep(Rand.uniform(0.4...1.2))
            if !KillSwitch.tripped { Wheel.scroll(lines: max(moved.down - moved.up, 0), down: false) }
        }
    }

    static func run(in area: CGRect, web: Bool) {
        guard !Wheel.stopped, area.width > 200, area.height > 200 else { return }
        let inner = area.insetBy(dx: area.width * 0.1, dy: area.height * 0.15)
        func point(_ fx: Double, _ fy: Double) -> CGPoint {
            CGPoint(x: inner.minX + inner.width * CGFloat(fx), y: inner.minY + inner.height * CGFloat(fy))
        }
        var kinds: [(Kind, Double)] = [(.glance, 3), (.trace, 2), (.rest, 2)]
        if web { kinds.append((.peek, 1.5)) }
        Timing.measure("fidget") {
            switch Rand.weighted(kinds) {
            case .glance:
                for _ in 0..<Rand.uniform(1...2) where !Wheel.stopped {
                    Mouse.move(to: point(Rand.unit(), Rand.unit()))
                    Pace.sleep(Rand.uniform(0.3...1.4))
                }
            case .trace:
                let x0 = Rand.uniform(0.0...0.3), width = Rand.uniform(0.3...0.6)
                var y = Rand.uniform(0.1...0.6)
                for _ in 0..<Rand.uniform(2...4) where !Wheel.stopped {
                    Mouse.move(to: point(x0 + Rand.uniform(0.0...0.03), y))
                    Mouse.move(to: point(x0 + width * Rand.uniform(0.8...1.0), y + Rand.uniform(-0.01...0.01)))
                    Pace.sleep(Rand.uniform(0.15...0.5))
                    y = min(y + Rand.uniform(0.03...0.07), 1)
                }
            case .rest:
                Mouse.linger(Rand.uniform(1.0...4.0))
            case .peek:
                let lines = Rand.uniform(3...9)
                Wheel.scroll(lines: lines, down: true)
                Mouse.linger(Rand.uniform(0.8...3.0))
                if !KillSwitch.tripped { Wheel.scroll(lines: lines, down: false) }
            }
        }
    }
}
