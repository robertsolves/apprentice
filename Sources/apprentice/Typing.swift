import AppKit
import Carbon

/// How the person types, pair by pair of keys. A keystroke-timing check does not look at gaps one by
/// one: it looks for each letter pair keeping its own rhythm (a same-finger "ed" slow, a two-hand "th"
/// quick), the same from one day to the next. Gaps drawn around one mean have no such pattern.
///
/// The daemon learns it from the person's own typing, a few minutes at a time (`Sampler`), and
/// `typing learn` records it in a little window: for each pair of keys, the time from one key going down
/// to the next, and how long each key is held. Never the text. With a recording, each
/// gap is drawn around that pair's own time, or its kind's (same finger, same hand, other hand, space)
/// for a pair not recorded. Without one, the kinds come from where the keys sit on the board, and each
/// pair gets a lasting lean of its own from the hand's seed, so the rhythm is stable without a recording.
enum Typing {
    // MARK: Where keys sit

    /// A key's place on the board, by key code: the same physical key on every layout.
    struct Place { var row: Double; var col: Double; var finger: Int }

    /// Fingers 0–3 are the left pinky to index, 4–7 the right index to pinky, 8 the thumbs.
    static let places: [CGKeyCode: Place] = {
        var map: [CGKeyCode: Place] = [:]
        func finger(_ i: Int) -> Int { [0, 1, 2, 3, 3, 4, 4, 5, 6, 7][min(i, 9)] }
        let rows: [(codes: [CGKeyCode], start: Double, shift: Int)] = [
            ([50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24], 0, -1),
            ([12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30, 42], 1.5, 0),
            ([0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39], 1.75, 0),
            ([6, 7, 8, 9, 11, 45, 46, 43, 47, 44], 2.25, 0),
        ]
        for (r, row) in rows.enumerated() {
            for (i, code) in row.codes.enumerated() {
                map[code] = Place(row: Double(r), col: row.start + Double(i), finger: finger(max(i + row.shift, 0)))
            }
        }
        map[49] = Place(row: 4, col: 6, finger: 8)
        return map
    }()

    /// The kind of a pair of keys, which sets most of its gap.
    enum Kind: String, CaseIterable { case repeated, finger, hand, other, toSpace, fromSpace }

    static func kind(_ a: CGKeyCode, _ b: CGKeyCode) -> Kind? {
        guard let p = places[a], let q = places[b] else { return nil }
        if a == b { return .repeated }
        if q.finger == 8 { return .toSpace }
        if p.finger == 8 { return .fromSpace }
        if p.finger == q.finger { return .finger }
        return (p.finger < 4) == (q.finger < 4) ? .hand : .other
    }

    /// How far apart two keys sit, in key widths.
    static func distance(_ a: CGKeyCode, _ b: CGKeyCode) -> Double {
        guard let p = places[a], let q = places[b] else { return 1 }
        return hypot(p.col - q.col, p.row - q.row)
    }

    // MARK: The recording

    /// Samples in milliseconds, the newest last, at most `cap` of each.
    struct Profile: Codable {
        var recorded: Date
        var pairs: [String: [Int]] = [:]
        var kinds: [String: [Int]] = [:]
        var holds: [String: [Int]] = [:]
        /// Gaps of 0.5–4 s after a space or punctuation, and how many word ends there were.
        var pauses: [Int] = []
        var wordEnds = 0
        var keys = 0
        /// Mistakes: how many times the person went back, how many keys each time (backspaces in a row),
        /// and how long after the last key the first backspace came. Optional: older files lack them.
        var corrections: Int?
        var runs: [Int]?
        var notice: [Int]?

        static let pairCap = 40, kindCap = 400, pauseCap = 200
    }

    /// The median and the log spread of a set of samples, in seconds.
    struct Stat { var median: Double; var sigma: Double; var n: Int }

    static func stat(_ ms: [Int]?) -> Stat? {
        guard let ms, !ms.isEmpty else { return nil }
        let s = ms.map { Double($0) / 1000 }.sorted()
        let median = s[s.count / 2]
        let logs = s.map { log($0) }
        let mean = logs.reduce(0, +) / Double(logs.count)
        let sd = sqrt(logs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(logs.count - 1, 1)))
        return Stat(median: median, sigma: min(max(sd.isFinite ? sd : 0.25, 0.08), 0.6), n: s.count)
    }

    /// A recorded pair placed on the board: its keys on the current layout and its median.
    struct Known { var kind: Kind; var a: CGKeyCode; var b: CGKeyCode; var logMedian: Double; var n: Int }

    /// The recording with every statistic worked out once, when the file changes, so a keystroke only
    /// looks values up: no file read, no sorting.
    struct Learned {
        var date: Date?
        var profile: Profile?
        var pairs: [String: Stat] = [:]
        var kinds: [String: Stat] = [:]
        var holds: [String: Stat] = [:]
        var hold: Stat?
        var pause: Stat?
        var errorRate: Double?
        var runs: [Int] = []
        var notice: Stat?
        var known: [Known] = []
        var guesses: [String: Double] = [:]
    }

    private static var cached: Learned?
    private static var checked = Date.distantPast
    // Typing runs on the command queue and the sampler on main: one lock for the cache.
    private static let lock = NSLock()

    /// The saved recording, re-read when the file changes.
    static var profile: Profile? { learned().profile }

    /// Looks at the file's date at most every 2 s, and works everything out again only when it changed.
    static func learned() -> Learned {
        lock.lock()
        defer { lock.unlock() }
        if let cached, Date().timeIntervalSince(checked) < 2 { return cached }
        checked = Date()
        let date = (try? FileManager.default.attributesOfItem(atPath: Store.dir.appendingPathComponent(file).path))?[.modificationDate] as? Date
        if let cached, cached.date == date { return cached }
        var l = Learned(date: date, profile: date == nil ? nil : Store.load(Profile.self, file))
        if let p = l.profile {
            l.pairs = p.pairs.compactMapValues { stat($0) }
            l.kinds = p.kinds.compactMapValues { stat($0) }
            l.holds = p.holds.compactMapValues { stat($0) }
            l.hold = stat(p.holds.values.flatMap { $0 })
            l.pause = stat(p.pauses)
            // A rate needs a few hundred keys behind it before it says anything about the person.
            if p.keys >= 300, let c = p.corrections { l.errorRate = Double(c) / Double(p.keys) }
            l.runs = p.runs ?? []
            l.notice = stat(p.notice)
            let layout = Keys.layout()
            func code(_ c: Character) -> CGKeyCode? { c == " " ? 49 : layout[c]?.0 }
            l.known = l.pairs.compactMap { pair, st in
                let chars = Array(pair)
                guard chars.count == 2, st.n >= 3, let a = code(chars[0]), let b = code(chars[1]), let k = kind(a, b) else { return nil }
                return Known(kind: k, a: a, b: b, logMedian: log(st.median), n: st.n)
            }
        }
        cached = l
        return l
    }

    /// Forgets the worked-out recording, so the next keystroke reads the file again (after a save).
    static func reload() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    /// A pair the recording has not seen, from the ones it has: those of the same kind, weighted by how
    /// alike they sit (the distance between the keys, the fingers, the rows), as one hand's reach does.
    /// Nil when nothing recorded is near enough to go by.
    static func guess(_ pair: String, _ kind: Kind, _ a: CGKeyCode, _ b: CGKeyCode) -> Double? {
        let state = learned()
        if let seen = state.guesses[pair] { return seen }
        guard let pa = places[a], let pb = places[b] else { return nil }
        let d = distance(a, b)
        var sum = 0.0, weight = 0.0
        for k in state.known where k.kind == kind {
            guard let qa = places[k.a], let qb = places[k.b] else { continue }
            let apart = abs(distance(k.a, k.b) - d) * 0.8
                + (qa.finger == pa.finger ? 0 : 0.5) + (qb.finger == pb.finger ? 0 : 0.5)
                + abs(qa.row - pa.row) * 0.3 + abs(qb.row - pb.row) * 0.3
            let w = exp(-apart) * Double(k.n) / Double(k.n + 2)
            sum += w * k.logMedian
            weight += w
        }
        guard weight > 0.3 else { return nil }
        let median = exp(sum / weight)
        lock.lock()
        if cached?.date == state.date { cached?.guesses[pair] = median }
        lock.unlock()
        return median
    }

    static let file = "typing.json"

    /// One key as the window saw it.
    struct Press { var code: CGKeyCode; var char: Character?; var down: Double; var up: Double?; var edit: Bool }

    /// Adds a recording's presses to `p`. A pair next to a correction (backspace) is left out, and so is
    /// a gap over 4 s, which is the person looking away.
    static func add(_ presses: [Press], to p: inout Profile) {
        func push(_ list: inout [Int], _ v: Double, cap: Int) {
            list.append(Int((v * 1000).rounded()))
            if list.count > cap { list.removeFirst(list.count - cap) }
        }
        // Each run of backspaces after a typed key is one correction: its length, and how long the
        // person took to notice. A long run is a word or line taken back on purpose, not a slip.
        func deleting(_ k: Press) -> Bool { k.char == nil && (k.code == 51 || k.code == 117) }
        var i = 0
        while i < presses.count {
            guard deleting(presses[i]) else { i += 1; continue }
            var j = i
            while j < presses.count, deleting(presses[j]) { j += 1 }
            if i > 0, presses[i - 1].char != nil, j - i <= 4 {
                p.corrections = (p.corrections ?? 0) + 1
                var runs = p.runs ?? []
                runs.append(j - i)
                p.runs = Array(runs.suffix(Profile.pauseCap))
                let notice = presses[i].down - presses[i - 1].down
                if notice > 0.03, notice < 3 {
                    var list = p.notice ?? []
                    push(&list, notice, cap: Profile.pauseCap)
                    p.notice = list
                }
            }
            i = j
        }
        for (i, k) in presses.enumerated() where !k.edit {
            p.keys += 1
            if let up = k.up, let c = k.char, up - k.down > 0.015, up - k.down < 0.4 {
                push(&p.holds[String(c), default: []], up - k.down, cap: Profile.pairCap)
            }
            guard i > 0 else { continue }
            let a = presses[i - 1]
            guard !a.edit, let ca = a.char, let cb = k.char else { continue }
            let dd = k.down - a.down
            guard dd > 0.015, dd < 4 else { continue }
            let wordEnd = ca == " " || ca.isPunctuation
            if wordEnd, cb != " " { p.wordEnds += 1 }
            if dd >= 0.5 {
                if wordEnd { push(&p.pauses, dd, cap: Profile.pauseCap) }
                continue
            }
            push(&p.pairs[String([ca, cb]), default: []], dd, cap: Profile.pairCap)
            if let kind = kind(a.code, k.code) { push(&p.kinds[kind.rawValue, default: []], dd, cap: Profile.kindCap) }
        }
    }

    // MARK: Drawing gaps

    /// The time from one key going down to the next, in seconds: the recorded pair's own, else its
    /// kind's, else the board's; drawn log-normal around it each time.
    static func interval(_ a: Character?, _ codeA: CGKeyCode?, _ b: Character, _ codeB: CGKeyCode?) -> Double {
        let pace = Config.current.pace
        let l = learned()
        func low(_ c: Character) -> Character { c.lowercased().count == 1 ? Character(c.lowercased()) : c }
        let pair = a.map { String([low($0), low(b)]) }
        let kind = codeA.flatMap { x in codeB.flatMap { Typing.kind(x, $0) } }
        var median: Double, sigma: Double
        if let k = kind, let kindStat = l.kinds[k.rawValue], kindStat.n >= 8 {
            // A pair seen a few times leans toward its kind until it has samples of its own.
            if let pair, let own = l.pairs[pair], own.n >= 3 {
                let w = Double(own.n) / Double(own.n + 4)
                median = exp(w * log(own.median) + (1 - w) * log(kindStat.median))
                sigma = w * own.sigma + (1 - w) * kindStat.sigma
            } else if let pair, let a = codeA, let b = codeB, let near = guess(pair, k, a, b) {
                median = near * lean(pair, 0.06)
                sigma = kindStat.sigma
            } else {
                median = kindStat.median * board(k, codeA, codeB) / board(k, nil, nil) * lean(pair, 0.1)
                sigma = kindStat.sigma
            }
        } else {
            median = board(kind, codeA, codeB) * pace.keyMedian * Hand.current.rhythm * lean(pair, 0.14)
            sigma = pace.keySigma * 0.7
        }
        if let a, a.isPunctuation { median *= 1.3 }
        if b.isUppercase || a?.isUppercase == true { median *= 1.12 }
        return min(max(median * exp(sigma * Rand.gaussian()), 0.03), 1.2)
    }

    /// How much slower or quicker a kind of pair runs than the median gap, from where the keys sit.
    static func board(_ kind: Kind?, _ a: CGKeyCode?, _ b: CGKeyCode?) -> Double {
        let d = a.flatMap { x in b.map { distance(x, $0) } } ?? 1
        switch kind {
        case .repeated: return 0.95
        case .other: return 0.8 + 0.02 * d
        case .hand: return 1.0 + 0.06 * d
        case .finger: return 1.3 + 0.1 * d
        case .toSpace: return 0.85
        case .fromSpace: return 1.1
        case nil: return 1.1
        }
    }

    /// A lasting lean for one pair, the same every time for this hand: about ±`spread`, log-normal.
    static func lean(_ pair: String?, _ spread: Double) -> Double {
        guard let pair else { return 1 }
        var h: UInt64 = 0xcbf2_9ce4_8422_2325 ^ (Hand.current.seed ?? 0)
        for byte in pair.utf8 { h = (h ^ UInt64(byte)) &* 0x100_0000_01b3 }
        var x = h
        func mix() -> Double {
            x &+= 0x9E37_79B9_7F4A_7C15
            var z = x
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) * 0x1.0p-53
        }
        let g = sqrt(-2 * log(max(mix(), 1e-12))) * cos(2 * .pi * mix())
        return exp(spread * min(max(g, -2.5), 2.5))
    }

    /// How long one key stays down: the recorded key's own hold, else the recording's, else the hand's.
    static func hold(_ ch: Character?, shifted: Bool) -> Double? {
        let l = learned()
        guard l.profile != nil else { return nil }
        let own = ch.flatMap { l.holds[$0.lowercased()] }
        guard let s = own.flatMap({ $0.n >= 3 ? $0 : nil }) ?? l.hold else { return nil }
        return min(max(s.median * exp(s.sigma * Rand.gaussian()) * (shifted ? 1.08 : 1), 0.035), 0.3)
    }

    /// Whether this key slips, and how: `run` is how many keys go in before it is noticed (1 = at once)
    /// and come out again, `notice` the pause before the first backspace. The person's own rate (at most
    /// 6%), run lengths and notice time once learned; else `styleRate`, noticed at once.
    static func slip(styleRate: Double) -> (run: Int, notice: Double)? {
        let l = learned()
        guard Rand.chance(min(l.errorRate ?? styleRate, 0.06)) else { return nil }
        let run = min(max(Rand.pick(l.runs) ?? 1, 1), 4)
        let notice = l.notice.map { min(max($0.median * exp($0.sigma * Rand.gaussian()), 0.1), 1.5) } ?? Rand.uniform(0.1...0.35)
        return (run, notice)
    }

    /// After a word: a pause to think, at the recording's own rate and length, or nil for none.
    static func pause(_ sinceLast: Int) -> Double? {
        let l = learned()
        if let p = l.profile, p.wordEnds >= 20 {
            let rate = Double(p.pauses.count) / Double(p.wordEnds)
            guard let s = l.pause, Rand.chance(min(rate, 0.5)) else { return nil }
            return min(max(s.median * exp(s.sigma * Rand.gaussian()), 0.5), 4)
        }
        return sinceLast >= Rand.uniform(30...60) ? Rand.uniform(0.4...1.4) : nil
    }

    // MARK: The command

    static let sample = """
        The quick brown fox jumps over the lazy dog. Then she thought that the weather there was \
        nice enough to start on the long walk home, and nothing could stop them going on.
        """

    /// `typing learn | show | forget`.
    static func command(_ a: Args) throws -> String {
        switch a.pos.first ?? "show" {
        case "show":
            guard let p = profile else {
                return "typing: nothing learned yet · gaps follow the board and this hand's own lean per pair. "
                    + (Config.current.typingLearn ? "It learns from your own typing now and then; `typing learn` records it now" : "[typing] learn = false: `typing learn` records it by hand")
            }
            return summary(p)
        case "forget":
            Store.remove(file)
            reload()
            Store.log(["typing": "forget"])
            return "typing: recording removed · gaps follow the board again"
        case "learn":
            if Store.vmName != nil { throw Fail(5, "typing learn records on this Mac's keyboard; run it without APPRENTICE_VM") }
            guard let p = learn(intro: nil, timeout: 900) else {
                throw Fail(5, "no recording: type at least 40 keys, then press Return")
            }
            return summary(p) + "\nrun `typing learn` again to add more: the more pairs it has seen, the closer it types to you"
        default:
            throw Fail(5, "typing learn | show | forget")
        }
    }

    /// Opens the window and adds what it records to the saved profile. Nil when cancelled or too short.
    @discardableResult
    static func learn(intro: String?, timeout: Double) -> Profile? {
        let presses: [Press]? = DispatchQueue.main.sync { record(intro: intro, timeout: timeout) }
        guard let presses, presses.filter({ !$0.edit }).count >= 40 else { return nil }
        var p = profile ?? Profile(recorded: Date())
        p.recorded = Date()
        add(presses, to: &p)
        Store.save(p, file)
        reload()
        Store.log(["typing": "learn", "keys": presses.count])
        return p
    }

    /// Adds one key event to `presses`. Backspace and forward delete mark a correction, so the pair
    /// around it is left out; a key with cmd, ctrl or option is a shortcut, not typing.
    static func note(_ e: NSEvent, into presses: inout [Press]) {
        if e.type == .keyDown {
            guard !e.isARepeat else { return }
            if e.keyCode == 51 || e.keyCode == 117 {
                if !presses.isEmpty { presses[presses.count - 1].edit = true }
                presses.append(Press(code: e.keyCode, char: nil, down: e.timestamp, up: nil, edit: true))
            } else {
                presses.append(Press(code: e.keyCode, char: e.charactersIgnoringModifiers?.lowercased().first, down: e.timestamp, up: nil,
                                     edit: !e.modifierFlags.intersection([.command, .control, .option]).isEmpty))
            }
        } else if let i = presses.lastIndex(where: { $0.code == e.keyCode && $0.up == nil }) {
            presses[i].up = e.timestamp
        }
    }

    /// Learns from the person's own typing on this Mac without asking: now and then it listens for a few
    /// minutes (2–5), every 15–35 min while it knows little, hourly to three-hourly after 3,000 keys, and
    /// twice a day after 20,000, so it keeps up with the person without listening all the time. Only
    /// timings are kept, as `typing learn` keeps them. Never apprentice's own keys or a key while it acts,
    /// never in a password field (macOS secure input), never in a scrubbed app (`Privacy.names`).
    /// `[typing] learn = false` turns it off. On the main thread, in the main daemon only.
    enum Sampler {
        private static var monitor: Any?
        private static var presses: [Press] = []
        private static var until: Date?
        private static var nextAt = Date().addingTimeInterval(Rand.uniform(120.0...600.0))

        static func install() {
            guard Store.vmName == nil else { return }
            let timer = Timer(timeInterval: 30, repeats: true) { _ in tick() }
            RunLoop.main.add(timer, forMode: .common)
        }

        private static func tick() {
            if let until {
                if Date() >= until || !Config.current.typingLearn { stop() }
                return
            }
            guard Config.current.typingLearn, Date() >= nextAt else { return }
            presses = []
            until = Date().addingTimeInterval(Rand.uniform(120.0...300.0))
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { take($0) }
        }

        private static func take(_ e: NSEvent) {
            let app = NSWorkspace.shared.frontmostApplication
            let name = ((app?.localizedName ?? "") + " " + (app?.bundleIdentifier ?? "")).lowercased()
            if e.cgEvent?.getIntegerValueField(.eventSourceUserData) == Keys.tag || Borrow.active
                || IsSecureEventInputEnabled() || Privacy.names.contains(where: name.contains) {
                // Nothing about this key is kept, and no pair spans it.
                if !presses.isEmpty { presses[presses.count - 1].edit = true }
                return
            }
            note(e, into: &presses)
        }

        private static func stop() {
            monitor.map(NSEvent.removeMonitor)
            monitor = nil
            until = nil
            let known = profile?.keys ?? 0
            let wait: ClosedRange<Double> = known < 3000 ? 900...2100 : known < 20000 ? 3600...10800 : 21600...43200
            nextAt = Date().addingTimeInterval(Rand.uniform(wait))
            let got = presses
            presses = []
            guard got.filter({ !$0.edit }).count >= 40 else { return }
            let first = profile == nil
            var p = profile ?? Profile(recorded: Date())
            p.recorded = Date()
            add(got, to: &p)
            Store.save(p, file)
            reload()
            Store.log(["typing": "sampled", "keys": got.count])
            // Told once, with the next `session`; never over an update's own notice.
            if first, Store.load(Repo.Notice.self, "update.json") == nil {
                Repo.notice("typing: apprentice is learning your typing rhythm from short samples of your own typing (timings only, never the text, never in password fields). `apprentice typing show` shows it; `[typing] learn = false` turns it off")
            }
        }
    }

    static func summary(_ p: Profile) -> String {
        let all = stat(p.kinds.values.flatMap { $0 })
        let wpm = all.map { Int((60 / ($0.median * 5)).rounded()) }
        let held = stat(p.holds.values.flatMap { $0 })
        var out = "typing: \(p.keys) keys recorded · \(p.pairs.values.filter { $0.count >= 3 }.count) pairs with their own rhythm"
        if let wpm { out += " · about \(wpm) words a minute between pauses" }
        if let held { out += " · keys held \(Int(held.median * 1000)) ms" }
        if let c = p.corrections, p.keys > 0 {
            out += String(format: " · a correction every %d keys", max(p.keys / max(c, 1), 1))
            if let n = stat(p.notice) { out += ", noticed after \(Int(n.median * 1000)) ms" }
        }
        let kinds = Kind.allCases.compactMap { k in stat(p.kinds[k.rawValue]).map { "\(k.rawValue) \(Int($0.median * 1000)) ms" } }
        if !kinds.isEmpty { out += "\n" + kinds.joined(separator: " · ") }
        return out
    }

    /// The window: a sample to copy (or anything else), the keys' timings kept, the text thrown away.
    /// Runs on the main thread. Nil when cancelled.
    private static func record(intro: String?, timeout: Double) -> [Press]? {
        let width: CGFloat = 560
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "apprentice learns how you type"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        Ask.blue(panel)

        let label = NSTextField(wrappingLabelWithString: (intro.map { $0 + "\n\n" } ?? "")
            + "Type this the way you normally do, mistakes and all, or anything else you like. Only the time between keys and how long each is held is kept; the text is thrown away.")
        label.preferredMaxLayoutWidth = width - 48 - 56
        let text = NSTextField(wrappingLabelWithString: sample)
        text.font = .systemFont(ofSize: 15, weight: .medium)
        text.isSelectable = false
        text.preferredMaxLayoutWidth = width - 48
        let field = NSTextField(string: "")
        field.placeholderString = "Start typing"
        let count = NSTextField(labelWithString: "0 keys · aim for 150 or more")
        let handler = Handler()
        let done = NSButton(title: "Done ↩", target: handler, action: #selector(Handler.done))
        done.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel ⎋", target: handler, action: #selector(Handler.cancel))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [count, NSView(), cancel, done])
        buttons.spacing = 12
        let rows: [NSView] = [Ask.header(label), text, field, buttons]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        for view in [field, buttons] { view.widthAnchor.constraint(equalToConstant: width - 48).isActive = true }
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)

        var presses: [Press] = []
        // Return, Escape and the arrows drive the window, not the rhythm.
        let ignored: Set<UInt16> = [36, 76, 53, 123, 124, 125, 126]
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { e in
            guard e.window === panel, !ignored.contains(e.keyCode) else { return e }
            note(e, into: &presses)
            count.stringValue = "\(presses.count) keys · aim for 150 or more"
            return e
        }
        defer { monitor.map(NSEvent.removeMonitor) }

        Ask.place(panel)
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        let previous = NSWorkspace.shared.frontmostApplication
        Ask.ping()
        let timer = Timer(timeInterval: timeout, repeats: false) { _ in NSApplication.shared.stopModal(withCode: .abort) }
        RunLoop.main.add(timer, forMode: .modalPanel)
        let response = NSApplication.shared.runModal(for: panel)
        timer.invalidate()
        panel.orderOut(nil)
        field.stringValue = ""
        if let previous, previous.processIdentifier != getpid() { previous.activate() }
        return response == .OK ? presses : nil
    }

    private final class Handler: NSObject {
        @objc func done() { NSApplication.shared.stopModal(withCode: .OK) }
        @objc func cancel() { NSApplication.shared.stopModal(withCode: .cancel) }
    }
}
