import CoreGraphics
import Foundation

/// `selftest`: checks of the pure parts, built into the binary so kit.sh can run the exact build it is
/// about to install. A failure keeps the old binary, which is what lets apprentice update itself safely.
/// Nothing here touches the screen, the daemon or ~/.apprentice.
enum SelfTest {
    private static var failures: [String] = []
    private static var count = 0

    private static func check(_ ok: Bool, _ what: String, line: Int = #line) {
        count += 1
        if !ok { failures.append("SelfTest.swift:\(line) \(what)") }
    }

    static func run() -> Never {
        // Several checks write and delete the live state folder: never run against anything but a throwaway one.
        guard Store.dir.path.hasPrefix(NSTemporaryDirectory()) || Store.dir.path.hasPrefix("/tmp/") || Store.dir.path.hasPrefix("/private/") else {
            print("selftest: refusing to run, state folder \(Store.dir.path) is not a temporary one")
            exit(1)
        }
        toml()
        args()
        pace()
        wire()
        routing()
        diffs()
        approvals()
        notify()
        limits()
        sites()
        budgets()
        policies()
        siteSettings()
        gate()
        login()
        account()
        forms()
        pipelines()
        skillKinds()
        oneAtATime()
        sitesScreen()
        agentList()
        prefs()
        allowlist()
        flows()
        playbooks()
        learning()
        projects()
        updates()
        schedules()
        away()
        release()
        tomlEdits()
        terminal()
        try? FileManager.default.removeItem(at: Store.dir)
        if failures.isEmpty {
            print("selftest: \(count) checks passed")
            exit(0)
        }
        print("selftest: \(failures.count) of \(count) checks failed")
        failures.forEach { print("  " + $0) }
        exit(1)
    }

    private static func toml() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("apprentice-selftest-\(getpid()).toml")
        defer { try? FileManager.default.removeItem(at: file) }
        let text = """
            top = 1
            [agent]
            ask_sound = "Ping # not a comment" # a comment
            browsers = ["a.b", "c.d"]
            [pace."linkedin.com"]
            reload_max = { count = 2, window_s = 60 }
            """
        try? text.write(to: file, atomically: true, encoding: .utf8)
        let t = Toml.load(file)
        check(t[""]?["top"] == "1", "a key before any section")
        check(t["agent"]?["ask_sound"].map(Toml.unquote) == "Ping # not a comment", "a # inside a string is kept")
        check(t["agent"]?["browsers"].flatMap(Toml.array) == ["a.b", "c.d"], "string arrays")
        check(t["pace.linkedin.com"] != nil, "quoted section names lose their quotes")
        let table = Toml.table(t["pace.linkedin.com"]?["reload_max"] ?? "")
        check(table["count"] == "2" && table["window_s"] == "60", "inline tables")
    }

    private static func args() {
        let a = Args.parse(["--right", "5"])
        check(a.pos == ["5"] && a.has("right"), "a switch never takes the next word as its value")
        let b = Args.parse(["--max=80", "--filter", "Sign in", "--enter"])
        check(b.value("max") == "80" && b.value("filter") == "Sign in" && b.has("enter"), "--k=v, --k v and a trailing switch")
        check(b.int("max", 0) == 80 && b.int("missing", 7) == 7, "int with fallback")
        check((try? Args.parse(["--max", "x"]).count("max", 1)) == nil, "a bad count is an error, not a fallback")
        check((try? Commands.scrollArgs(Args.parse(["left", "2"])))?.direction == "left"
              && (try? Commands.scrollArgs(Args.parse(["sideways"]))) == nil, "scroll takes left and right, nothing else")
        let by = Args.parse(["--by", "-200,40", "--in", "7"])
        check(by.value("by") == "-200,40" && by.value("in") == "7", "a negative offset is a value, not a flag")
        check((try? Commands.screenPoint("-200, 40", "")) == CGPoint(x: -200, y: 40)
              && (try? Commands.screenPoint("3", "")) == nil && (try? Commands.screenPoint("nan,1", "")) == nil, "x,y points parse strictly")
    }

    private static func pace() {
        let p = PaceConfig(["move_ms": "[900000, -1]", "key_ms_sigma": "nan", "actions_per_min": "0", "burst": "[5, 2]"])
        check(p.moveMin <= p.moveMax && p.moveMax <= 5 && p.moveMin >= 0.01, "move range is clamped and ordered")
        check(p.keySigma.isFinite, "a non-finite value falls back")
        check(p.actionsPerMin >= 1, "actions per minute stays positive")
        check(p.burstMin <= p.burstMax, "pairs are ordered")

        let careful = PaceConfig(["style": "\"careful\"", "move_ms": "[100, 300]"])
        check(careful.fidget > 0 && careful.dwellMax > 0 && careful.actionsPerMin <= 6, "a style sets its timing keys")
        check(careful.moveMin == 0.1 && careful.moveMax == 0.3, "a key beside a style wins")
        check(PaceConfig(["style": "\"nonsense\""]).fidget == PaceConfig().fidget, "an unknown style changes nothing")
        let feed = PaceConfig(["browse": "0.9", "browse_s": "[500, 5]"])
        check(feed.browseShare <= 0.2 && feed.browseMin <= feed.browseMax && feed.browseMax <= 120, "browse share and length are clamped and ordered")
        check(PaceConfig().browseShare == 0 && PaceConfig(["style": "\"steady\""]).browseShare == 0 && PaceConfig(["style": "\"careful\""]).browseShare > 0,
              "auto-browse is off unless a site turns it on or it is careful")
        check(PaceConfig(["fidget": "0.9", "overshoot": "2"]).fidget <= 0.5 && PaceConfig(["overshoot": "2"]).overshoot <= 1, "fidget and overshoot are clamped")
        let day = PaceConfig(["quiet_hours": "[22, 6]", "session_max_min": "30", "break_min": "[40, 10]"])
        check(day.isQuiet(hour: 23) && day.isQuiet(hour: 2) && !day.isQuiet(hour: 6) && !day.isQuiet(hour: 12), "quiet hours wrap past midnight")
        check(day.breakMin <= day.breakMax && !PaceConfig(["quiet_hours": "[5, 5]"]).isQuiet(hour: 5) && !PaceConfig().isQuiet(hour: 3),
              "break ranges are ordered; an empty or missing quiet range is off")
        check(PaceConfig(["style": "\"careful\""]).sittingMax > 0 && PaceConfig(["style": "\"careful\""]).actionsPerDay > 0
              && PaceConfig(["style": "\"steady\""]).sittingMax == 0, "careful brings a person's day; steady does not")
        var sitting = Limits()
        let start = Date().timeIntervalSince1970
        var cfg = PaceConfig()
        (cfg.sittingMax, cfg.breakMin, cfg.breakMax, cfg.actionsPerDay) = (30, 10, 10, 8)
        check(stride(from: 0, through: 25, by: 5).allSatisfy { Limits.sittingRefusal(&sitting, host: "example.com", cfg: cfg, now: start + Double($0) * 60) == nil },
              "a sitting under its length goes on")
        check(Limits.sittingRefusal(&sitting, host: "example.com", cfg: cfg, now: start + 31 * 60)?.hasPrefix("break") == true
              && Limits.sittingRefusal(&sitting, host: "example.com", cfg: cfg, now: start + 35 * 60)?.hasPrefix("break") == true,
              "a long sitting starts a break that holds")
        check(Limits.sittingRefusal(&sitting, host: "example.com", cfg: cfg, now: start + 42 * 60) == nil
              && Limits.sittingRefusal(&sitting, host: "example.com", cfg: cfg, now: start + 43 * 60) == nil
              && Limits.sittingRefusal(&sitting, host: "example.com", cfg: cfg, now: start + 44 * 60)?.hasPrefix("daily cap") == true,
              "after the break work goes on, up to the daily cap")
        let fastest = PaceConfig(["style": "\"fastest\""])
        check(fastest.moveMax < PaceConfig().moveMax && fastest.navGap == PaceConfig().navGap, "a fast style never loosens the navigation gap")
        let webOnApps = PaceConfig.preset("steady", on: fastest)
        check(webOnApps?.mode == "human" && webOnApps?.betweenMax == 2.5 && webOnApps?.keyErrorRate ?? 0 > 0,
              "web pages stay steady over apps' fastest")
        let styles = PaceStyles.moved("example.com", to: "fastest", in: ["steady": "[\"Example.com\", \"a.org\"]", "fast": "[\"b.org\"]"])
        check(styles["fastest"] == ["example.com"] && styles["steady"] == ["a.org"] && styles["fast"] == ["b.org"],
              "pace moves a site into one style's list alone")
        check(PaceStyles.moved("a.org", to: "default", in: ["steady": "[\"a.org\"]"]).values.allSatisfy { $0.isEmpty }, "pace default takes a site off every list")
        check(PaceStyles.key("https://www.Example.com/x") == "example.com" && PaceStyles.key("twitter.com") == "x.com"
              && PaceStyles.key("Safari") == "safari", "pace keys a URL by its site and an app by its name")
        check(PaceStyles.refusal("linkedin.com", "fastest") != nil && PaceStyles.refusal("linkedin.com", "steady") == nil
              && PaceStyles.refusal("example.com", "fastest") == nil, "pace never takes a social site below steady")

        Rand.seed(7)
        let first = (0..<4).map { _ in Rand.next() }
        Rand.seed(7)
        check((0..<4).map { _ in Rand.next() } == first, "a seed repeats its sequence")
        var inRange = true, sawBoth = (false, false)
        for _ in 0..<5000 {
            let d = Rand.uniform(0.25...0.5), i = Rand.uniform(3...5), r = Rand.uniform(0..<3)
            inRange = inRange && d >= 0.25 && d <= 0.5 && (3...5).contains(i) && (0..<3).contains(r)
            if i == 3 { sawBoth.0 = true }
            if i == 5 { sawBoth.1 = true }
        }
        check(inRange && sawBoth.0 && sawBoth.1, "draws stay in range and reach both ends")
        check((0..<200).allSatisfy { _ in Rand.weighted([("a", 1.0), ("b", 0)]) == "a" }, "a zero weight is never picked")
        let base = PaceConfig()
        let long = (0..<200).map { _ in Mouse.duration(2, base) }
        check(long.allSatisfy { $0 > base.moveMax && $0 <= base.moveMax * 2.5 } && Set(long).count > 150 && Mouse.duration(0.001, base) == base.moveMin,
              "long moves pass the cap without piling up on it; short ones keep the floor")
        let wild = Hand(speed: 9, side: -1, hold: .nan, holdSigma: 0, rhythm: 1, click: 1).bounded
        check(wild.speed <= 1.4 && wild.side >= 0.2 && wild.hold >= 0.05 && wild.click <= 0.16, "a hand from a bad file is bounded")
        check((0..<500).allSatisfy { _ in (0.035...0.25).contains(Pace.keyHold("a")) && (0.03...1.2).contains(Typing.interval("a", 0, "k", 40)) },
              "key holds and gaps stay in range")
        func median(_ a: Character, _ ca: CGKeyCode, _ b: Character, _ cb: CGKeyCode) -> Double {
            let s = (0..<301).map { _ in Typing.interval(a, ca, b, cb) }.sorted()
            return s[150]
        }
        // "ed" is one finger, "th" two hands: by the board alone the first is slower, and each pair keeps its lean.
        check(Typing.kind(14, 2) == .finger && Typing.kind(17, 4) == .other && Typing.kind(0, 49) == .toSpace
              && median("e", 14, "d", 2) > median("t", 17, "h", 4) * 1.2
              && Typing.lean("th", 0.14) == Typing.lean("th", 0.14) && Typing.lean("th", 0.14) != Typing.lean("ht", 0.14),
              "gaps follow the board: one finger slower than two hands, and each pair keeps its own lean")
        var recorded = Typing.Profile(recorded: Date())
        // The person types "th" at 60 ms and "ed" at 300 ms: the recording wins over the board.
        var presses: [Typing.Press] = []
        var t = 0.0
        for _ in 0..<12 {
            for (code, ch, gap) in [(CGKeyCode(17), Character("t"), 0.2), (4, "h", 0.06), (14, "e", 0.15), (2, "d", 0.3), (49, " ", 0.12)] as [(CGKeyCode, Character, Double)] {
                t += gap
                presses.append(Typing.Press(code: code, char: ch, down: t, up: t + 0.09, edit: false))
            }
        }
        presses[5].edit = true
        Typing.add(presses, to: &recorded)
        Store.save(recorded, Typing.file)
        Typing.reload()
        check(abs(median("t", 17, "h", 4) - 0.06) < 0.02 && abs(median("e", 14, "d", 2) - 0.3) < 0.08
              && recorded.pairs["th"]?.count == 11 && recorded.holds["t"]?.first == 90,
              "a recording sets each pair's own rhythm and hold; a pair beside a correction is left out")
        Store.remove(Typing.file)
        Typing.reload()
        // "teh" noticed 250 ms late and taken back two keys, then a whole word deleted on purpose (not a slip).
        var slipped = Typing.Profile(recorded: Date())
        let keys: [(CGKeyCode, Character?, Double)] = [(17, "t", 0), (14, "e", 0.1), (4, "h", 0.2), (51, nil, 0.45), (51, nil, 0.55),
                                                         (4, "h", 0.7), (14, "e", 0.8)] + (0..<6).map { (51, nil, 1.5 + Double($0) * 0.1) }
        Typing.add(keys.map { Typing.Press(code: $0.0, char: $0.1, down: $0.2, up: $0.2 + 0.08, edit: $0.1 == nil) }, to: &slipped)
        check(slipped.corrections == 1 && slipped.runs == [2] && slipped.notice == [250],
              "a slip is learned with its length and how late it was noticed; deleting a word is not a slip")
        var voice = Voice.template.replacingOccurrences(of: "(Optional. Tone, phrases I use, what I never say, anything per site.)", with: "I write like me.")
        voice = Voice.setting(voice, "tone", "Professional", assumed: false, scope: "linkedin.com")
        voice = Voice.setting(voice, "emoji", "Never", assumed: false)
        voice = Voice.setting(voice, "tone", "Warm and casual", assumed: false, scope: "x.com")
        voice = Voice.setting(voice, "tone", "Warm and casual", assumed: false, scope: "reddit.com")
        voice = Voice.setting(voice, "tone", "Match the thread", assumed: true, scope: "bsky.app")
        voice = Voice.setting(voice, "tone", "Short and to the point", assumed: false, scope: "x.com")
        check(voice.contains("I write like me.") && Voice.answers(voice, "x.com")["tone"]?.value == "Short and to the point"
              && Voice.resolve(voice, "tone", scope: "linkedin.com").map { $0.value == "Professional" && $0.source == .here } == true
              && Voice.resolve(voice, "emoji", scope: "x.com")?.source == .everywhere
              && Voice.resolve(voice, "tone", scope: "threads.net").map { $0.source != .here && $0.source != .guess } == true
              && Voice.resolve(voice, "tone", scope: "bsky.app").map { $0.source != .here && $0.assumedHere } == true
              && Voice.resolve(voice, "length", scope: "x.com") == nil,
              "a preference: the site's own answer, else everywhere, else other sites; an assumed one never wins over a real one")
        try? "# work voice\n".write(to: Voice.url, atomically: true, encoding: .utf8)
        Tour.save(Tour.Setup(name: "work", values: ["agent.ui_only": "true"]))
        try? "# home voice\n".write(to: Voice.url, atomically: true, encoding: .utf8)
        Tour.save(Tour.Setup(name: "home", values: ["agent.ui_only": "false"]))
        _ = try? Tour.use("work")
        let workConfig = (try? String(contentsOf: Config.path, encoding: .utf8)) ?? ""
        let workVoice = Voice.read() ?? ""
        _ = try? Tour.use("home")
        check(workConfig.contains("ui_only = true") && workVoice == "# work voice\n" && Voice.read() == "# home voice\n"
              && Tour.active == "home" && (try? Tour.validName("../x")) == nil,
              "named setups: each keeps its settings and voice, and pulling one up puts both in place")
        check(Keys.tag != 0x646B_6374 && Keys.tag > 0, "the event tag is drawn, not the old constant")
        check(Mouse.Speed.allCases.allSatisfy { abs(Mouse.progress($0, 1, skew: 0.8) - 1) < 1e-9 && abs(Mouse.progress($0, 0, skew: 0.8)) < 1e-9 },
              "every speed profile starts at the start and ends on the target")
        let button = CGRect(x: 5000, y: 5000, width: 40, height: 24)
        let rests = (0..<120).map { _ in Mouse.landing(in: button) } + (0..<60).map { _ in Mouse.aim(at: CGPoint(x: 5100, y: 5100)) }
            + (0..<60).map { _ in Mouse.dropBy(from: CGPoint(x: 5200, y: 5200), CGPoint(x: 300, y: 0)) }
        check(Set(rests.map(Mouse.Rest.key)).count == rests.count && rests.prefix(120).allSatisfy { button.insetBy(dx: -6, dy: -6).contains($0) }
              && rests.dropFirst(120).prefix(60).allSatisfy { hypot($0.x - 5100, $0.y - 5100) < 9 },
              "the pointer never rests on one pixel twice, and stays on its target")
        Rand.seed(UInt64.random(in: .min ... .max))
    }

    private static func wire() {
        let req = Request(cmd: "type", args: ["3", "héllo \"quoted\"", "--enter"])
        let back = try? JSONDecoder().decode(Request.self, from: Wire.json(req))
        check(back?.cmd == req.cmd && back?.args == req.args, "a request survives the wire")
        let resp = Response(code: 8, out: "approve with token", data: ["token": "ab12"])
        let r = try? JSONDecoder().decode(Response.self, from: Wire.json(resp))
        check(r?.code == 8 && r?.out == resp.out && r?.data?["token"] == "ab12", "a response survives the wire")
        let old = try? JSONDecoder().decode(Request.self, from: Data(#"{"cmd":"read","args":[]}"#.utf8))
        check(old?.cmd == "read" && old?.model == nil, "a request from an older client, with no model, still decodes")
        let m = try? JSONDecoder().decode(Request.self, from: Wire.json(Request(cmd: "read", model: "m1")))
        check(m?.model == "m1", "the model travels with the request")
    }

    private static func routing() {
        func vm(_ cmd: String, _ args: [String] = [], on: Bool = true, bound: Bool = false, vmSession: Bool = true) -> Bool {
            Remote.wants(Request(cmd: cmd, args: args), on: on, bound: bound, vmSession: vmSession)
        }
        check(!vm("session", on: false, vmSession: false) && !vm("click", ["3"], on: false, vmSession: false), "with the VM off everything is local")
        check(vm("session", vmSession: false), "a bare session goes to the VM's browser")
        check(vm("session", ["--app", "Safari"], vmSession: false), "a browser session goes to the VM")
        check(!vm("session", ["--app", "Finder"]), "a native app stays on this Mac")
        check(!vm("focus", ["Finder"]) && vm("focus", ["Google Chrome"], vmSession: false), "focus follows the app")
        check(vm("click", ["3"]) && !vm("click", ["3"], vmSession: false), "actions follow the session")
        check(vm("ocr") && vm("show"), "commands the VM cannot do yet are answered there, not run on this Mac")
        check(vm("session", ["--app", "mousepad", "--on", "linux"], on: false, vmSession: false), "--on linux binds a Linux app")
        check(vm("focus", ["xfce4-terminal", "--on", "linux"], on: false), "focus --on linux stays in the VM")
        check(!vm("session", ["--app", "Safari", "--on", "mac"]), "--on mac keeps a browser on this Mac")
        check(vm("session", ["--app", "mousepad"], on: false, bound: true, vmSession: false), "a daemon bound to a VM binds its apps")
        check(vm("menu", ["File > Save"]), "menus work in the VM")
        for cmd in ["ask", "confirm", "approve", "deny", "awake", "away", "log"] {
            check(!vm(cmd), "\(cmd) stays on this Mac")
        }
        check(VM.isBrowser("Safari") && VM.isBrowser("Brave Browser.app") && !VM.isBrowser("Finder"), "browser names")
        check(isBlankTab("chrome://newtab/") && isBlankTab("chrome://new-tab-page/") && isBlankTab(nil) && isBlankTab("about:blank")
              && !isBlankTab("https://example.com/newtab") && !isBlankTab("https://example.com/"), "blank browser tabs")
    }

    private static func notify() {
        let app = Session(app: "Safari", bundle: "com.apple.Safari", pid: 1, wid: 1, allow: [])
        check(Notify.body("Post\nthis?", session: app) == "Post this?", "a push is one line")
        check(Notify.body(String(repeating: "a", count: 400), session: app).count == 300, "a long question is cut")
        let vault = Session(app: "1Password", bundle: "com.1password.1password", pid: 1, wid: 1, allow: [])
        check(Notify.body("Approve this step? click 4 Reveal", session: vault) == "A question is waiting in the chat.",
              "a scrubbed app's question never leaves the Mac")
        let t = Notify.topic()
        check(t.hasPrefix("apprentice-") && t.count == 35 && t != Notify.topic(), "phone topics are long and random")
        check((Notify.qrText("https://ntfy.sh/\(t)")?.split(separator: "\n").count ?? 0) > 10, "the phone QR code renders")
        check(Notify.links("https://ntfy.sh/\(t)", tty: false).contains("ntfy://ntfy.sh/\(t)?display=apprentice"), "the Android one-tap link")
    }

    private static func diffs() {
        func el(_ id: Int, _ name: String, _ value: String? = nil) -> Element {
            Element(id: id, path: [id], label: "button", name: name, value: value, frame: [0, 0, 1, 1], offscreen: false, gated: false)
        }
        func snap(_ e: [Element]) -> Snapshot { Snapshot(snap: 1, scope: "window", url: nil, title: "t", total: e.count, elements: e) }
        let d = diff(snap([el(1, "Save"), el(2, "Cancel")]), snap([el(1, "Save", "on"), el(2, "Help")]))
        check(d.added.count == 1 && d.added[0].contains("Help"), "a new element is added")
        check(d.removed == ["button \"Cancel\""], "a gone element is removed")
        check(d.changed.count == 1 && d.changed[0].contains("value=\"on\""), "a changed value is a change")
        check(d.summary == "+1 -1 ~1", "the summary counts")
        check(diff(nil, snap([el(1, "A")])).added.count == 1, "everything is new against no snapshot")
        // After an action the list shifts: Save keeps its id, the new element takes one never used.
        let kept = keepIds(snap([el(1, "Menu"), el(2, "Save"), el(3, "Cancel")]), snap([el(1, "Banner"), el(2, "Menu"), el(3, "Save")]))
        check(kept.elements.map(\.id) == [4, 1, 2], "ids survive an action and new ones are fresh")
        check(keepIds(nil, snap([el(1, "A")])).elements[0].id == 1, "no old snapshot keeps the numbering")
    }

    /// The approval gate, against this run's own temporary ~/.apprentice.
    private static func approvals() {
        Approvals.granted = nil
        Approvals.request = Request(cmd: "click", args: ["3"])
        var token = ""
        do {
            try Approvals.check("click 3 button \"Post\"", details: [], warnings: [], element: "button|Post")
            check(false, "an unapproved step is proposed, not run")
        } catch let f as Fail {
            check(f.code == 8, "an unapproved step exits 8")
            token = Approvals.pending?.token ?? ""
        } catch { check(false, "an unapproved step exits 8") }
        check(Approvals.pending?.cmd == "click" && Approvals.pending?.args == ["3"], "the proposal saves the request")
        check((try? Approvals.take("zzzz")) == nil && Approvals.pending != nil, "a wrong token takes nothing")
        let p = try? Approvals.take(token)
        check(p != nil && (try? Approvals.take(token)) == nil, "a token is used once")
        Approvals.granted = p
        check((try? Approvals.check("click 3", details: [], warnings: [], element: "button|Post")) != nil, "the approved request runs")
        Approvals.request = Request(cmd: "click", args: ["4"])
        check((try? Approvals.check("click 4", details: [], warnings: [])) == nil, "an approval covers only its own request")
        Approvals.request = Request(cmd: "click", args: ["3"])
        do {
            try Approvals.check("click 3", details: [], warnings: [], element: "button|Delete")
            check(false, "an approval for another element is stale")
        } catch let f as Fail { check(f.code == 2, "an approval for another element is stale (exit 2)") } catch {}
        Approvals.granted = nil
        Store.save(Approvals.Pending(token: "old1", cmd: "click", args: ["3"], summary: "click 3", snap: nil,
                                     at: Date().timeIntervalSince1970 - Approvals.ttl - 1, element: nil), "pending.json")
        check((try? Approvals.take("old1")) == nil && Approvals.pending == nil, "an expired approval is refused and dropped")
        var tokens: [String] = []
        for id in ["5", "6"] {
            Approvals.request = Request(cmd: "click", args: [id])
            _ = try? Approvals.check("click \(id)", details: [], warnings: [])
            tokens.append(Approvals.pending?.token ?? "")
        }
        check(Approvals.find(tokens[0])?.args == ["5"] && (try? Approvals.take(tokens[1])) != nil && Approvals.pending?.token == tokens[0],
              "a new proposal keeps the one before it")
        Approvals.drop(tokens[0])
        Approvals.add(Approvals.Pending(token: "old2", cmd: "click", args: ["3"], summary: "click 3", snap: nil,
                                        at: Date().timeIntervalSince1970 - Approvals.ttl + 5, element: nil))
        Approvals.extend("old2", by: Approvals.userTTL)
        check(Approvals.find("old2").map { $0.expires > Date().timeIntervalSince1970 + 3000 } == true,
              "a step handed to the user stays open for an hour")
        Approvals.drop("old2")
        Approvals.request = Request(cmd: "type", args: ["7", "x"])
        _ = try? Approvals.check("type into 7", details: [], warnings: [Gate.credential])
        let secret = Approvals.pending?.token ?? ""
        do {
            _ = try Commands.approve(Args.parse([secret]))
            check(false, "only the user approves a password field")
        } catch let f as Fail {
            check(f.code == 8 && Approvals.find(secret) != nil, "only the user approves a password field; it stays pending")
        } catch {}
        Approvals.drop(secret)
        Approvals.planActive = true
        Approvals.planFlagged = false
        check((try? Approvals.check("click 9", details: [], warnings: [])) != nil, "a plan runs its plain steps")
        check((try? Approvals.check("click 9", details: [], warnings: ["inside a dialog"])) == nil,
              "a plan stops at a warning it did not show")
        Approvals.planFlagged = true
        check(Approvals.planCovers(["may be irreversible: button \"Save\""]) && !Approvals.planCovers([Gate.credential]),
              "a flagged step runs, a password field never does")
        Approvals.planActive = false
        Approvals.planFlagged = false
        Approvals.drop(Approvals.pending?.token ?? "")
        check(!Gate.wordsIn("Save and send").isSubset(of: Gate.wordsIn("Save")), "a near match that sends is not the step's button")
        KillSwitch.halted = true
        Approvals.request = Request(cmd: "click", args: ["8"])
        do {
            try Approvals.check("click 8", details: [], warnings: [])
            check(false, "after the kill switch nothing is proposed")
        } catch let f as Fail { check(f.code == 6 && Approvals.pending == nil, "after the kill switch nothing is proposed (exit 6)") } catch {}
        KillSwitch.halted = false
        Approvals.request = Request(cmd: "")
    }

    /// Site counts are shared by every VM's daemon; a session's own rhythm stays in pace.json.
    private static func limits() {
        Limits.update { l in
            l.lastAction = 42
            l.kinds = ["example.com": ["like": [1, 2]]]
        }
        let shared = Store.load(Limits.self, "limits.json")
        check(shared?.lastAction == 0 && shared?.kinds?["example.com"]?["like"]?.count == 2, "site counts are shared, the rhythm is not")
        check(Store.load(Limits.SessionPace.self, "pace.json")?.lastAction == 42 && Limits.stored.lastAction == 42, "the rhythm is kept per session")
    }

    /// www.linkedin.com and linkedin.com share a budget; a look-alike domain shares nothing.
    private static func sites() {
        check(Site.domain("WWW.LinkedIn.com") == "linkedin.com" && Site.domain("m.example.org") == "example.org", "www. and m. count with the site")
        check(Site.domain("www.co") == "www.co", "a prefix that is the whole name stays")
        check(Site.domain("mobile.twitter.com") == "x.com" && Site.domain("twitter.com") == "x.com", "twitter.com counts as x.com")
        check(Site.matches("api.example.com", "example.com") && Site.matches("Example.com", "example.com"), "subdomains and case match")
        check(!Site.matches("badexample.com", "example.com") && !Site.matches("example.com.evil.io", "example.com"), "look-alike hosts do not match")
        check(Budgets.kind("button \"Unfollow\"", gated: true) == "unfollow", "unfollow is not a follow")
        check(Budgets.kind("button \"Add friend\"", gated: true) == "friend_request", "add friend is a friend request")
        check(Budgets.kind("button \"Unlike\"", gated: false) == nil && Budgets.kind("button \"Following\"", gated: false) == nil,
              "whole words only")
        check(Budgets.kind("button \"Archive\"", gated: true) == "default" && Budgets.kind("link \"Home\"", gated: false) == nil,
              "any other gated action counts as default, an ungated one not at all")
        check(Budgets.plural("friend_request") == "friend requests" && Budgets.plural("default") == "gated actions", "plurals")
        check(Budgets.kind("button \"Gefällt mir\"", gated: false) == "like" && Budgets.kind("button \"J'aime\"", gated: false) == "like",
              "a like in German or French is a like")
        check(Budgets.kind("button \"いいね！\"", gated: false) == "like" && Budgets.kind("button \"关注\"", gated: false) == "follow",
              "Japanese and Chinese words match without spaces")
        check(Budgets.kind("button \"Nicht mehr folgen\"", gated: false) == "unfollow" && Budgets.kind("button \"Dejar de seguir\"", gated: false) == "unfollow",
              "a localized unfollow is not a follow")
        // A sparse page reached by navigation that says it is throttling cools the site; a long one that mentions it does not.
        let old = Snapshot(snap: 1, scope: "web", url: "https://example.com/a", title: "a", total: 0, elements: [])
        let block = Snapshot(snap: 2, scope: "web", url: "https://example.com/b", title: "Bitte später erneut versuchen", total: 0, elements: [])
        var long = block
        long.elements = (0..<80).map { Element(id: $0, path: [$0], label: "text", name: "post \($0)", value: nil, frame: [0, 0, 1, 1], offscreen: false, gated: false) }
        check(Site.softBlock("open", old, block) == "später erneut" && Site.softBlock("open", old, long) == nil,
              "a sparse block page after open is a soft block; a long page that mentions one is not")
        check(Site.softBlock("scroll", old, block) == nil, "scrolling a feed never cools a site")
    }

    /// Caps from budgets.json, counted across aliases, in this run's temporary settings.
    private static func budgets() {
        let path = Budgets.path
        defer { try? FileManager.default.removeItem(at: path) }
        let table = #"{"_note": "x", "default": {"like": {"hour": 2}, "default": {"day": 9}}, "example.com": {"post": {"day": 1}}}"#
        try? table.write(to: path, atomically: true, encoding: .utf8)
        check(Budgets.cap("example.com", "post").day == 1, "a site's own cap wins")
        check(Budgets.cap("shop.example.com", "like").hour == 2, "a subdomain falls back to the default's cap")
        check(Budgets.cap("example.com", "upvote").hour == 2, "an alias takes its kind's cap")
        check(Budgets.cap("other.org", "archive").day == 9, "an unknown kind takes the default cap")
        func runs(_ host: String, _ kind: String) -> Bool { (try? Budgets.check(host, kind, record: true)) != nil }
        check(runs("www.example.com", "like") && runs("example.com", "upvote"), "under the cap it runs")
        do {
            try Budgets.check("example.com", "like", record: true)
            check(false, "a like over the hourly cap is stopped")
        } catch let f as Fail { check(f.code == 4, "a like over the hourly cap exits 4") } catch {}
        check((try? Budgets.check("example.com", "like", record: false)) == nil, "a refused action is not counted, and checking alone still refuses")
        check(runs("example.com", "post") && !runs("example.com", "repost"), "a repost shares the post budget")
        Budgets.refund("www.example.com", "repost")
        check(runs("example.com", "post"), "a step that never ran gives its count back")
        let own = ["example.com": ["upvote": Budgets.Cap(hour: nil, day: 1, week: nil, min_gap_s: nil)]]
        check(Budgets.counter("example.com", "upvote", table: own) == "upvote" && Budgets.counter("example.com", "upvote", table: [:]) == "like",
              "a kind with a cap of its own counts apart from its alias")
    }

    /// A policy entry is a note on the site's terms: no site is ever refused, even with an old
    /// `automation = "forbidden"` line.
    private static func policies() {
        let path = Routes.customPath
        defer { try? FileManager.default.removeItem(at: path) }
        try? """
        [policy."blocked.example"]
        automation = "forbidden"
        terms_url = "https://blocked.example/terms"
        """.write(to: path, atomically: true, encoding: .utf8)
        let page = Page(url: "https://www.blocked.example/feed", title: "Feed", scope: "web")
        check((try? Site.guardPage(page, cmd: "click", read: { Snapshot(snap: 1, scope: "web", url: page.url, title: "Feed", total: 0, elements: []) })) != nil, "a policy entry never refuses a site")
        check(Policies.describe("www.blocked.example").contains("https://blocked.example/terms"), "policy prints the terms on file")
    }

    /// Every site decision comes from the config files: no budgets.json means no caps, a broken one
    /// stops work, cooldowns and challenges follow `[sites]`, and `[gate] user_only` steps need the user.
    private static func siteSettings() {
        let saved = Config.current
        defer { Config.current = saved; try? FileManager.default.removeItem(at: Budgets.path) }
        try? FileManager.default.removeItem(at: Budgets.path)
        check((0..<50).allSatisfy { _ in (try? Budgets.check("nocaps.example", "like", record: true)) != nil }, "no budgets.json, no caps")
        try? "{ not json".write(to: Budgets.path, atomically: true, encoding: .utf8)
        check((try? Budgets.check("nocaps.example", "post", record: false)) == nil, "a broken budgets.json stops budgeted actions")
        try? FileManager.default.removeItem(at: Budgets.path)

        Limits.update { $0.cooling = ["cool.example": Limits.Cooling(until: Date().timeIntervalSince1970 + 600, strikes: 1, last: 0)] }
        check((try? Cooldown.check("cool.example")) == nil && Cooldown.warning("cool.example") == nil, "on_soft_block = stop refuses a cooling site")
        Config.current.onSoftBlock = "warn"
        check((try? Cooldown.check("cool.example")) != nil && Cooldown.warning("cool.example") != nil, "on_soft_block = warn lets it run with a ⚠ line")
        Limits.update { $0.cooling = nil }

        func el(_ label: String, _ name: String) -> Element {
            Element(id: 1, path: [], label: label, name: name, value: nil, frame: [0, 0, 1, 1], offscreen: false, gated: false)
        }
        check(Gate.userOnly(el("button", "Place order")) && Gate.userOnly(el("button", "Buy now")) && !Gate.userOnly(el("button", "Buyers guide")),
              "user_only phrases match whole words")
        let shop = Page(url: "https://shop.example/cart", title: "Cart", scope: "web")
        check(Gate.warnings(el("button", "Pay"), shop).contains(Gate.userOnlyStep), "a payment step is the user's to approve")
        Config.current.userOnly = []
        check(!Gate.warnings(el("button", "Pay"), shop).contains(Gate.userOnlyStep), "an empty user_only leaves it to the agent")
    }

    /// The ⚠ lines: what a step is, never what the agent says it is.
    private static func gate() {
        func el(_ label: String, _ name: String) -> Element {
            Element(id: 1, path: [], label: label, name: name, value: nil, frame: [0, 0, 1, 1], offscreen: false, gated: false)
        }
        let page = Page(url: "https://example.com/feed", title: "Feed", scope: "web")
        check(Gate.matches("Send message") && Gate.matches("DELETE") && !Gate.matches("Sender") && !Gate.matches("Unlike"),
              "gate words match whole words in any case")
        check(Gate.warnings(el("link", "Home"), page).isEmpty, "a plain link has no warning")
        check(Gate.warnings(el("button", "Post"), page).contains { $0.hasPrefix("may be irreversible") }, "post may be irreversible")
        check(Gate.warnings(el("textbox", "Verification code"), page).contains("a password or security-code field"), "a code field always stops")
        check(Gate.warnings(el("link", "Home"), Page(url: "https://example.com/account/x", title: "", scope: "web")).count == 1,
              "account pages warn")
        check(Gate.warnings(el("link", "Home"), Page(url: nil, title: "", scope: "sheet")) == ["inside a dialog"], "dialogs warn")
        check(Gate.warnings(nil, page, force: true) == ["marked --gate"], "--gate adds a warning")
    }

    /// Signing in is off by default; on, a code prompt is a sign-in step, not a check, and sign-ins on a
    /// site are spaced out and capped a day.
    /// The device flow's answers, read without the network or the Keychain (both are the user's, never the test's).
    private static func forms() {
        check(WeekTime.weekly(days: [2, 4], minutes: 9 * 60) == "mon,wed 09:00", "weekdays and a time are written as schedule takes them")
        let parsed = WeekTime.parseWeekly("fri,sun 18:30")
        check(parsed?.days == [6, 1] && parsed?.minutes == 18 * 60 + 30, "a weekly line reads back into days and minutes")
        check(WeekTime.parseWeekly("someday 09:00") == nil, "an unknown day is refused")
        check(WeekTime.clock(5) == "00:05", "a clock is zero-padded")
        check(Set(Setting.shown.map(\.id)).count == Setting.shown.count, "every setting the window offers has its own key")
        let font = Setting.shown.first { $0.key == "font" }
        check(font?.literal("Menlo") == "\"Menlo\"", "a text setting is written quoted")
        let size = Setting.shown.first { $0.key == "font_size" }
        check(size?.literal("abc") == "12", "a number setting falls back to its default on nonsense")
        let book = NewPlaybookSheet.text(scope: "site", match: "example.com", title: "", notes: "Login is top right\n- Orders under Account", day: "2026-11-02")
        check(book.hasPrefix("---\nscope: site\nmatch: example.com\n") && book.contains("# example.com\n") && book.contains("- Login is top right\n- Orders under Account\n"),
              "a new playbook has front matter, the match as its title and one bullet per note")
    }

    private static func account() {
        let d = Account.parseDevice(["device_code": "dc", "user_code": "WDJB-MJHT", "verification_uri": "https://github.com/login/device",
                                     "expires_in": 900, "interval": 5], now: 1000)
        check(d?.userCode == "WDJB-MJHT" && d?.expires == 1900 && d?.interval == 5, "a device code is read with its expiry")
        check(Account.parseDevice(["error": "unauthorized_client"]) == nil, "a refused device code is not a sign-in")
        check(d.map { Account.parseStart(Account.describe($0))?.code == "WDJB-MJHT" } == true || d == nil,
              "the window reads the code back from login --start")
        check(Account.parseStart("code: AB-12\nurl: https://github.com/login/device\nexpires_s: 10")?.url == "https://github.com/login/device",
              "the url keeps its colon")
        check(Account.poll(["error": "authorization_pending"]) == .pending, "pending keeps polling")
        check(Account.poll(["error": "slow_down", "interval": 10]) == .slowDown(10), "slow_down waits longer")
        if case .failed = Account.poll(["error": "access_denied"]) {} else { check(false, "a cancelled sign-in stops") }
        if case .failed = Account.poll(["error": "expired_token"]) {} else { check(false, "an expired code stops") }
        let done = Account.poll(["access_token": "ghu_x", "refresh_token": "ghr_y", "expires_in": 28800, "refresh_token_expires_in": "15897600"])
        check(done == .done(Account.Tokens(access: "ghu_x", refresh: "ghr_y", expiresIn: 28800, refreshExpiresIn: 15897600)),
              "a token is read with both expiries, numbers or strings")
        check(Account.poll(["access_token": ""]) != .pending && Account.poll([:]) != .pending, "an empty answer is not a token")
    }

    private static func login() {
        let saved = Config.current
        defer { Config.current = saved }
        func el(_ label: String, _ name: String) -> Element {
            Element(id: 3, path: [], label: label, name: name, value: nil, frame: [0, 0, 1, 1], offscreen: false, gated: false)
        }
        let code = Snapshot(snap: 1, scope: "web", url: "https://example.com/signin/challenge", title: "Sign in",
                            total: 1, elements: [el("textbox", "Enter the code we sent")])
        let form = Snapshot(snap: 1, scope: "web", url: "https://example.com/authwall", title: "Sign in",
                            total: 1, elements: [el("password", "Password")])
        let captcha = Snapshot(snap: 1, scope: "web", url: "https://example.com/login", title: "Sign in",
                               total: 2, elements: [el("textbox", "Enter the code"), el("checkbox", "I'm not a robot")])
        check(!Login.allowed("example.com") && Challenge.find(code) != nil, "login is off by default and a code prompt is a check")
        Config.current.loginAuto = true
        check(Login.allowed("www.example.com") && Login.isCodePrompt(Challenge.find(code) ?? ""), "with login on a code prompt is a sign-in step")
        check(Challenge.find(form) == nil && Login.signedOut(form)?.contains("--secret password") == true, "a sign-in form is not a check")
        check(Challenge.find(captcha) == "\"i'm not a robot\"", "a CAPTCHA stays a check")
        Config.current.loginSites = ["other.org"]
        check(!Login.allowed("example.com") && Login.allowed("a.other.org"), "[login] sites limits it")
        let now = 1_000_000.0
        check((try? Login.paced("x.com", now: now, tries: [])) != nil, "a first sign-in may run")
        check((try? Login.paced("x.com", now: now, tries: [now - 600])) == nil, "a second one within gap_min stops")
        check((try? Login.paced("x.com", now: now, tries: [now - 30_000, now - 20_000, now - 10_000])) == nil, "per_day caps them")
        check((try? Login.paced("x.com", now: now, tries: [now - 90_000, now - 20_000, now - 10_000])) != nil, "yesterday's do not count")
    }

    /// An allowlist entry covers its subdomains, never a look-alike; the app's name covers pageless windows.
    private static func allowlist() {
        func s(_ allow: [String]) -> Session { Session(app: "Safari", bundle: nil, pid: 1, wid: 1, allow: allow) }
        check(s([]).allows(url: "https://anything.io"), "an empty allowlist is unrestricted")
        check(s(["example.com"]).allows(url: "https://docs.example.com/a") && s(["Example.com"]).allows(url: "https://example.com"),
              "subdomains and case are allowed")
        check(!s(["example.com"]).allows(url: "https://badexample.com") && !s(["example.com"]).allows(url: "https://example.com.evil.io"),
              "look-alike hosts are not")
        check(!s(["example.com"]).allows(url: nil) && s(["safari"]).allows(url: nil), "a window without a page needs the app's name")
        check(s(["*"]).allows(url: "https://x.y"), "* allows everything")
        check(Config.parseAllow(" a.com, b.org ,") == ["a.com", "b.org"], "the allow option is split and trimmed")
    }

    /// Flow steps: shell-like words and {placeholders}.
    private static func flows() {
        check((try? Commands.tokenize(#"type #textbox "" "Hello \"you\"""#)) == ["type", "#textbox", "", #"Hello "you""#],
              "quotes group, empty quotes are a word, \\\" escapes")
        check((try? Commands.tokenize(#"open C:\path  x"#)) == [#"open"#, #"C:\path"#, "x"], "other backslashes are kept, extra spaces ignored")
        check((try? Commands.tokenize(#"click "Save"#)) == nil, "an unclosed quote is an error")
        let trailing = #"C:\dir\"#
        let written = "click #button \"" + trailing.replacingOccurrences(of: "\\", with: "\\\\") + "\""
        check((try? Commands.tokenize(written)) == ["click", "#button", trailing], "a name ending in a backslash round-trips through learn's quoting")
        check(!Gate.matches(Commands.gateText(#"`scroll down 40 --in #text "Post 1 · a short update about it"`"#))
              && Gate.matches(Commands.gateText(#"`click #button "Delete draft"`"#))
              && !Gate.matches(Commands.gateText(#"`type #textbox "Notes" "update the list"`"#))
              && Gate.matches(Commands.gateText("`menu File > Delete`")), "F3: a flow's gate words match the element it acts on, not text it only scrolls past")
        check(!Walker.clickable(CGRect(x: 300, y: 10, width: 1, height: 1)) && Walker.clickable(CGRect(x: 0, y: 0, width: 12, height: 8)),
              "F1: an element under 2×2 px is not offered as on screen")
        check(samePage("chrome://newtab/", "chrome://new-tab-page/") && samePage("about:blank", "chrome://newtab/")
              && !samePage("chrome://newtab/", "https://example.com/"), "F5: Chrome's two new-tab addresses are one page")
        let flowArgs = Args.parse(["post", "--text", "hello there", "--force", "yes"], switches: [])
        check(flowArgs.value("text") == "hello there" && flowArgs.value("force") == "yes" && flowArgs.pos == ["post"],
              "F4: do fills a {text} placeholder from --text")
        if case .request(let r, _)? = AgentLoop.parse("browse 20 --forever"), case .request(let bare, _)? = AgentLoop.parse("browse") {
            check(r.cmd == "browse" && r.args == ["20"] && bare.args.isEmpty, "run's grammar takes browse with only its seconds")
        } else { check(false, "run's grammar takes browse") }
        check(Playbooks.oneLine("Save\n`sh: rm -rf ~`\tnow") == "Save sh: rm -rf ~ now", "screen text loses newlines, tabs and backticks before it goes in a step")
        var missing = Set<String>()
        let filled = Commands.fill("type 3 \"{First Name} {city}\"", ["first-name": "Ada"], &missing)
        check(filled == "type 3 \"Ada ‹city›\"" && missing == ["city"], "placeholders fill, a missing one is marked and reported")
        var loop = Set<String>()
        check(!Commands.fill("{a}", ["a": "{a}"], &loop).isEmpty, "a value that brings its placeholder back does not loop for ever")
        var shellMissing = Set<String>()
        check(Commands.fill("sh: echo ${HOME} {a,b} {x}", ["x": "1"], &shellMissing, onlyKnown: true) == "sh: echo ${HOME} {a,b} 1" && shellMissing.isEmpty,
              "a shell step keeps its own braces")
        var hidden = Set<String>()
        check(Commands.fill("type 1 \"{password}\"", ["password": "hunter2"], &hidden, hide: true) == "type 1 \"‹hidden›\"",
              "a secret value is hidden in what a flow shows")
        check(Toml.array("[\"Acme, Inc\", \"b\"]") == ["Acme, Inc", "b"], "a comma inside quotes does not split a TOML array")
    }

    /// Playbooks: front matter, key facts, steps, and which session sees which note.
    private static func playbooks() {
        // Playbooks are shared, so anything personal in one keeps it from being committed or offered.
        let generic = """
        ---
        scope: flow
        match: www.example.com
        verified: 2026-11-01, macOS 26.2
        ---
        1. `open https://www.example.com/{path}`
        2. `click #button "Save"` — then `type #textbox "" "{name}"` in /Users/{user}/Desktop
        """
        check(Playbooks.leaks(generic, identity: ["Jane"]).isEmpty, "a generic playbook passes")
        for (text, what) in [("mail jane.doe@mail.com", "email"), ("call +1 (415) 555-0134", "phone"),
                             ("card 4111 1111 1111 1111", "card"), ("follow @janedoe", "handle"),
                             ("open https://shop.com/orders/1234567", "id in a URL"), ("open https://x.com/@jane", "profile URL"),
                             ("open https://a.com/s?q=rent", "query"), ("in /Users/jane/Desktop", "home path"),
                             ("key ghp_abcdefghijklmnopqrstuvwx1234", "token"), ("order 8812734", "long number"),
                             ("server 10.1.2.3", "IP address"), ("ask JANE first", "own name")] {
            check(!Playbooks.leaks(text, identity: ["Jane"]).isEmpty, "a playbook with a \(what) is refused")
        }
        check(Playbooks.leaks("mail team@example.com, server 127.0.0.1", identity: []).isEmpty, "example addresses and loopback pass")
        check(Playbooks.leaks(inPatch: "+++ b/playbooks/a.md\n+call 415 555 0134\n-old@mail.com\n+++ b/playbooks/b.md\n+fine\n") == ["playbooks/a.md: a phone, card or account number: 415 555 0134"],
              "a patch is judged on the lines it adds, file by file")
        check(Playbooks.genericURL("https://www.instagram.com/janedoe/?hl=en") == "https://www.instagram.com/{path}", "learn keeps the host, not the page")
        check(Playbooks.genericURL("https://example.com") == "https://example.com/", "a bare host stays")

        let text = """
        ---
        scope: flow
        match: Finder
        ---
        # New folder

        ## Key facts
        - one
        - two
        ## Steps
        1. `menu "File > New Folder"`
        2. Pick the row by hand.
        not a step
        ## Fails
        3. not a step either
        """
        let n = Playbooks.parse(text, url: URL(fileURLWithPath: "/x/new-folder.md"), path: "flows/new-folder.md")
        check(n.meta["scope"] == "flow" && n.title == "New folder" && n.match == ["finder"], "front matter and title")
        check(n.keyFacts == ["one", "two"], "key facts are the bullets under their heading")
        check(Playbooks.steps(n) == ["`menu \"File > New Folder\"`", "Pick the row by hand."], "steps are the numbered lines under Steps")
        check(Playbooks.parse("# T\nbody", url: URL(fileURLWithPath: "/x/a.md"), path: "a.md").meta.isEmpty, "no front matter is fine")
        check(Playbooks.slugify("Post a job: LinkedIn (draft)!") == "post-a-job-linkedin-draft", "slugs")

        let root = Store.dir.appendingPathComponent("playbooks-test")
        defer { try? FileManager.default.removeItem(at: root); unsetenv("APPRENTICE_PLAYBOOKS") }
        func write(_ name: String, _ meta: String) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? "---\n\(meta)\n---\n# \(name)\n".write(to: root.appendingPathComponent(name + ".md"), atomically: true, encoding: .utf8)
        }
        write("mac", "scope: system\nmatch: *\nsystem: macos")
        write("linux", "scope: system\nmatch: *\nsystem: linux")
        write("site", "scope: site\nmatch: example.com")
        write("flow", "scope: flow\nmatch: *")
        setenv("APPRENTICE_PLAYBOOKS", root.path, 1)
        func seen(_ host: String?, _ system: String) -> [String] {
            Playbooks.matching(app: "Chromium", bundle: nil, host: host, system: system).map(\.title).sorted()
        }
        check(seen("www.example.com", "linux") == ["linux", "site"], "the VM sees its own playbooks and the site's, not the Mac's")
        check(seen("badexample.com", "macos") == ["mac"], "a look-alike host gets no site playbook, and flows never show")

        // Skills sit beside the playbooks in the repo: skills/<name>/SKILL.md, matched by `metadata: hosts:` or `system:`.
        let clone = Store.dir.appendingPathComponent("skills-test")
        defer { try? FileManager.default.removeItem(at: clone) }
        func skill(_ name: String, _ meta: String) {
            let folder = clone.appendingPathComponent("skills/\(name)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? "---\nname: \(name)\n\(meta)\n---\n# \(name)\nbody of \(name)\n".write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        try? FileManager.default.createDirectory(at: clone.appendingPathComponent("playbooks"), withIntermediateDirectories: true)
        skill("apprentice-web", "metadata:\n  hosts: \"*\"")
        skill("apprentice-site", "metadata:\n  hosts: example.com, example.org")
        skill("apprentice-macos", "metadata:\n  system: macos")
        setenv("APPRENTICE_PLAYBOOKS", clone.appendingPathComponent("playbooks").path, 1)
        func guides(_ host: String?, _ system: String) -> [String] { Playbooks.skills(host: host, system: system).map(\.name) }
        check(guides("www.example.com", "linux") == ["apprentice-web", "apprentice-site"], "a page gets the web skill, then the site's")
        check(guides("badexample.com", "macos") == ["apprentice-web"], "a look-alike host gets no site skill")
        check(guides(nil, "macos") == ["apprentice-macos"] && guides(nil, "linux").isEmpty, "an app gets its system's skill")
        check(Playbooks.search("apprentice-site").contains("body of apprentice-site"), "playbooks <skill name> prints the skill")
        check(Playbooks.hintLines(app: "Chromium", bundle: nil, host: "example.org").first?.hasPrefix("skills · apprentice-web, apprentice-site") == true, "session names the skills")
    }

    /// What makes the next run faster: flows ranked per model, `do --explain`, the scrubbed session copy,
    /// learned routes and the PR helpers.
    private static func learning() {
        let root = Store.dir.appendingPathComponent("learning-test")
        defer { try? FileManager.default.removeItem(at: root); unsetenv("APPRENTICE_PLAYBOOKS") }
        func write(_ name: String, _ meta: String) {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent("flows"), withIntermediateDirectories: true)
            try? "---\nscope: flow\n\(meta)\n---\n# \(name)\n## Steps\n1. `key cmd+n`\n".write(to: root.appendingPathComponent("flows/\(name).md"), atomically: true, encoding: .utf8)
        }
        write("draft-m1", "match: example.com\ntags: post, draft\nmodel: m1")
        write("draft-any", "match: example.com\ntags: post, draft")
        write("unrelated", "match: example.com\ntags: invoice")
        setenv("APPRENTICE_PLAYBOOKS", root.path, 1)
        let m1 = Playbooks.rank(task: "post a draft", model: "m1", session: nil).map { $0.note.url.deletingPathExtension().lastPathComponent }
        check(m1 == ["draft-m1", "draft-any"], "a flow learned by this model ranks first, unrelated flows are left out")
        let m2 = Playbooks.rank(task: "post a draft", model: "m2", session: nil).map { $0.note.url.deletingPathExtension().lastPathComponent }
        check(m2 == ["draft-any"], "another model's flow is left out unless it says any")
        check(Playbooks.explain("post a draft", model: "m1", session: nil).contains("→ "), "do --explain names the pick and its score")
        check(Playbooks.context(task: "post a draft", session: nil, model: "m1", budget: 50).count < 120, "the run loop's playbooks stay under their budget")

        let row: [String: Any] = ["cmd": "click", "label": "button", "name": "Send to Sam", "url": "https://mail.example.com/inbox?q=sam",
                                  "error": "no button \"Send to Sam\" at https://x.example/a", "api_key": "sk-1", "ms": 10]
        let scrubbed = Sessions.scrub(row, mode: "scrubbed") ?? [:]
        check(scrubbed["host"] as? String == "mail.example.com" && scrubbed["url"] == nil && scrubbed["name"] == nil,
              "a scrubbed row keeps the host, not the URL or the element's name")
        check((scrubbed["error"] as? String).map { !$0.contains("Sam") && !$0.contains("https") } == true, "a scrubbed error loses quoted text and URLs")
        check(Sessions.scrub(row, mode: "full")?["api_key"] == nil && scrubbed["api_key"] == nil, "no mode keeps a secret")
        let local = Sessions.scrub(["cmd": "menu", "menu": "File > Open Recent > taxes.pdf", "path": "/Users/sam/taxes.pdf",
                                    "error": "no file at /Users/sam/taxes.pdf or ~/Desktop/x"], mode: "scrubbed") ?? [:]
        check(local["menu"] == nil && local["path"] == nil && (local["error"] as? String).map { !$0.contains("sam") && !$0.contains("Desktop") } == true,
              "a scrubbed row drops menu titles and local paths")
        check(PR.github("git@github.com:robertsolves/apprentice.git") == PR.github("https://github.com/robertsolves/apprentice"),
              "pr knows the upstream in ssh form is the upstream, so it never pushes there")

        let flow = Playbooks.parse("---\nscope: flow\nmatch: example.com\ntags: post, draft\n---\n# Draft\n", url: root.appendingPathComponent("flows/draft-any.md"), path: "flows/draft-any.md")
        check(Routes.learn(from: flow, model: "m1") != nil && Routes.learn(from: flow, model: "m1") == nil, "a route is learned once per flow and model")
        check(Routes.all(model: "m1").first?.faster == "apprentice do draft-any", "this model's learned route comes first")
        check(!Routes.all(model: "m2").contains { $0.label == "draft-any" }, "another model does not see it")

        check(PR.github("git@github.com:you/apprentice.git") == "you/apprentice" && PR.github("https://github.com/a/b") == "a/b", "GitHub owner/name from either URL")
        let body = PR.body(["Fix F3: stale ids", "notes: finder"], files: ["Sources/a.swift"])
        check(body.contains("- Fix F3: stale ids") && body.contains("## Field reports\n- F3"), "a PR body lists the commits and the reports they name")
    }

    /// A project folder adds its own counts and caps, and never lifts the account-wide ones; the agent's
    /// model is read from its transcript.
    private static func projects() {
        let root = Store.dir.appendingPathComponent("project-test")
        let nested = root.appendingPathComponent("src/deep")
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent(".apprentice"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); Project.dir = nil }
        check(Project.find(from: nested.path)?.path == root.appendingPathComponent(".apprentice").path, "a project folder is found from a subfolder")
        try? #"{"default": {"reaction": {"hour": 1}}}"#.write(to: root.appendingPathComponent(".apprentice/budgets.json"), atomically: true, encoding: .utf8)
        Project.dir = root.appendingPathComponent(".apprentice")
        func like() -> Bool { (try? Budgets.check("project.example", "reaction", record: true)) != nil }
        check(like() && !like(), "the project's tighter cap stops the second action")
        Project.dir = nil
        check(like(), "outside the project only the account-wide cap applies")
        check(Agent.lastModel(in: #"{"model":"claude-a"} {"model":"<synthetic>"} {"model":"claude-b"} {"model":"<synthetic>"}"#) == "claude-b",
              "the agent's model is the last real one in its transcript")
    }

    /// Schedules: every trigger's next time, jitter bounds, the quiet-hours shift, catch-up and cron.
    private static func schedules() {
        let cal = Calendar.current
        let now = Date()
        var s = Schedules.Schedule(id: "t", name: "t", kind: .run, target: "true")
        s.created = now
        s.every = 60
        if let next = Schedules.baseNext(s, after: now.addingTimeInterval(90)) {
            check(abs(next.timeIntervalSince(now.addingTimeInterval(3600))) < 2, "every 60 min keeps its rhythm from when it was made")
        } else {
            check(false, "every 60 min has a next time")
        }
        var daily = s
        daily.every = nil
        daily.daily = "09:30"
        if let next = Schedules.baseNext(daily, after: now) {
            let c = cal.dateComponents([.hour, .minute], from: next)
            check(c.hour == 9 && c.minute == 30 && next > now, "a daily schedule lands on its time")
        } else {
            check(false, "a daily schedule has a next time")
        }
        var weekly = daily
        weekly.daily = nil
        weekly.weekly = "mon,wed 09:00"
        if let next = Schedules.baseNext(weekly, after: now) {
            let weekday = cal.component(.weekday, from: next)
            check(weekday == 2 || weekday == 4, "a weekly schedule lands on one of its days")
            check(next > now, "a weekly schedule is in the future")
        } else {
            check(false, "a weekly schedule has a next time")
        }
        var badWeekly = weekly
        badWeekly.weekly = "mon,funday 09:00"
        check(Schedules.baseNext(badWeekly, after: now) == nil, "a weekly schedule with a day that is not one never stands")
        check(Schedules.nextCron("0 9 * * mon", after: now).map { cal.component(.weekday, from: $0) == 2 } == true,
              "cron takes day names")
        check(Schedules.nextCron("0 0 29 2 *", after: now) != nil, "a cron line for 29 February finds a leap year")
        // Both day fields restricted only when neither starts with `*`: `*/2` with a weekday is AND.
        if let next = Schedules.nextCron("0 9 */2 * 1", after: now) {
            let c = cal.dateComponents([.day, .weekday], from: next)
            check(c.weekday == 2 && (c.day ?? 0) % 2 == 1, "a stepped day field still counts as unrestricted")
        } else {
            check(false, "a stepped cron line has a next time")
        }
        // A once schedule that fired early (jitter) is done; a daily one never reuses the base it fired on.
        var once = daily
        once.daily = nil
        once.at = now.addingTimeInterval(600)
        once.jitter = 0
        Schedules.update { $0.removeAll { $0.id == "selftest-once" || $0.id == "selftest-daily" } }
        once.id = "selftest-once"
        Schedules.update { $0.append(once) }
        Schedules.advance(once, now: now)
        check(Schedules.find("selftest-once")?.enabled == false, "a once schedule is off after it fires, even early")
        var early = daily
        early.id = "selftest-daily"
        early.jitter = 0
        let base = Schedules.baseNext(early, after: now)!
        early.base = base
        Schedules.update { $0.append(early) }
        Schedules.advance(early, now: base.addingTimeInterval(-600))
        check((Schedules.find("selftest-daily")?.base ?? base) > base.addingTimeInterval(3600),
              "a daily run fired early draws its next from the day after")
        Schedules.update { $0.removeAll { $0.id == "selftest-once" || $0.id == "selftest-daily" } }
        var tight = s
        tight.every = 10
        tight.jitter = 30
        let draws = (0..<50).compactMap { _ in Schedules.fireTime(tight, after: now)?.at }
        check(draws.allSatisfy { $0 > now }, "jitter never puts the next run in the past")
        var cron = weekly
        cron.weekly = nil
        cron.cron = "30 8 * * *"
        if let next = Schedules.nextCron("30 8 * * *", after: now) {
            let c = cal.dateComponents([.hour, .minute], from: next)
            check(c.hour == 8 && c.minute == 30 && next > now, "a cron line finds the next 08:30")
        } else {
            check(false, "a cron line has a next time")
        }
        check(Schedules.nextCron("bad", after: now) == nil, "a bad cron line has no next time")
        check(Schedules.cronField("1-5", 0, 6) == Set(1...5) && Schedules.cronField("*/15", 0, 59)?.count == 4,
              "cron ranges, steps and lists")
        check(Schedules.cronField("9", 0, 5) == nil, "a cron value out of range is refused")

        let jittered = Schedules.jittered(now, 15, draw: { 1 })
        check(abs(jittered.timeIntervalSince(now.addingTimeInterval(900))) < 1, "jitter reaches its upper bound")
        let low = Schedules.jittered(now, 15, draw: { 0 })
        check(abs(low.timeIntervalSince(now.addingTimeInterval(-900))) < 1, "jitter reaches its lower bound")
        check(Schedules.jittered(now, 0) == now, "no jitter is no shift")

        let day = cal.startOfDay(for: now)
        guard let early = cal.date(byAdding: .minute, value: 150, to: day),
              let night = cal.date(byAdding: .minute, value: 23 * 60, to: day) else {
            check(false, "today's clock times")
            return
        }
        check(cal.component(.hour, from: Schedules.outOfQuietHours(early, (2, 6))) == 6,
              "a run inside quiet hours moves to their end")
        let moved = Schedules.outOfQuietHours(night, (22, 6))
        check(cal.component(.hour, from: moved) == 6 && moved > night, "quiet hours that wrap move to the next morning")
        check(Schedules.outOfQuietHours(night, (-1, -1)) == night, "no quiet hours changes nothing")

        check(Schedules.catchUp(due: now.addingTimeInterval(-1800), now: now, minutes: 60), "half an hour late is caught up")
        check(!Schedules.catchUp(due: now.addingTimeInterval(-5400), now: now, minutes: 60), "an hour and a half late is skipped")
        check(Schedules.preview(daily, count: 5).count == 5, "five future runs are previewed")
        check(Schedules.timeOfDay("09:30") == 570 && Schedules.timeOfDay("24:00") == nil, "a clock time parses strictly")
        check(Schedules.render([s]).contains("[schedule.\"t\"]"), "schedules.toml is written as sections")
    }

    /// The DMG's update channel: reading GitHub's reply, comparing versions, the checksum file, and
    /// bringing in a new version's playbooks without overwriting the user's edits.
    private static func release() {
        let reply = Data("""
        {"tag_name":"v0.3.0","draft":false,"html_url":"https://github.com/o/r/releases/tag/v0.3.0","assets":[
         {"name":"apprentice-macos.dmg","browser_download_url":"https://x/apprentice-macos.dmg"},
         {"name":"SHA256SUMS.txt","browser_download_url":"https://x/SHA256SUMS.txt"}]}
        """.utf8)
        let latest = Release.parse(reply)
        check(latest?.version == "0.3.0" && latest?.dmg == "https://x/apprentice-macos.dmg" && latest?.sums == "https://x/SHA256SUMS.txt",
              "a release reply gives the version and its DMG and checksums")
        check(Release.parse(Data(#"{"tag_name":"v1.0.0","draft":true}"#.utf8)) == nil, "a draft release is never offered")
        check(Release.newer("0.10.0", than: "0.9.1") && !Release.newer("0.9.1", than: "0.10.0") && !Release.newer("0.2.0", than: "0.2.0"),
              "versions compare by number, not as text")
        check(Release.newer("1.0.0", than: "1.0.0-rc1") && !Release.newer("1.0.0-rc1", than: "1.0.0") && Release.newer("1.0.0-rc2", than: "1.0.0-rc1"),
              "a release is newer than its candidates")
        let sums = "abc123  apprentice-macos.zip\nDEF456  apprentice-macos.dmg\n"
        check(Release.expectedDigest(sums, name: "apprentice-macos.dmg") == "def456" && Release.expectedDigest(sums, name: "x") == nil,
              "the checksum file names the DMG's digest")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("apprentice-release-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("share/playbooks"), target = base.appendingPathComponent("playbooks")
        try? FileManager.default.createDirectory(at: source.appendingPathComponent("web"), withIntermediateDirectories: true)
        try? "v1".write(to: source.appendingPathComponent("web/a.md"), atomically: true, encoding: .utf8)
        try? "v1".write(to: source.appendingPathComponent("web/b.md"), atomically: true, encoding: .utf8)
        Store.remove("playbooks-release.json")
        check(Release.syncPlaybooks(from: source, into: target) == 2, "a first launch brings in every playbook")
        try? "mine".write(to: target.appendingPathComponent("web/b.md"), atomically: true, encoding: .utf8)
        try? "v2".write(to: source.appendingPathComponent("web/a.md"), atomically: true, encoding: .utf8)
        try? "v2".write(to: source.appendingPathComponent("web/b.md"), atomically: true, encoding: .utf8)
        _ = Release.syncPlaybooks(from: source, into: target)
        check((try? String(contentsOf: target.appendingPathComponent("web/a.md"), encoding: .utf8)) == "v2",
              "an untouched playbook follows the new version")
        check((try? String(contentsOf: target.appendingPathComponent("web/b.md"), encoding: .utf8)) == "mine",
              "a playbook the user changed is never overwritten")
        Store.remove("playbooks-release.json")
    }

    /// The away queue and the resume rule: a screen that does not match is the user's call, never a guess.
    private static func away() {
        check(Away.decide(preconditionsHold: true, cutMidway: false, alreadyHappened: false) == .proceed,
              "a matching screen continues")
        check(Away.decide(preconditionsHold: false, cutMidway: false, alreadyHappened: false) == .needsUser,
              "a changed screen goes to the user")
        check(Away.decide(preconditionsHold: true, cutMidway: true, alreadyHappened: false) == .redoUnit,
              "a unit cut off midway is undone and redone")
        check(Away.decide(preconditionsHold: true, cutMidway: true, alreadyHappened: true) == .needsUser,
              "a step that may already have happened goes to the user")
        Away.setMode(true)
        check(Away.mode, "away on is remembered")
        Away.update { $0.removeAll() }
        let task = Away.Task(id: "t1", kind: "run", target: "true", state: .queued, created: Date().timeIntervalSince1970)
        Away.add(task)
        check(Away.find("t1")?.target == "true", "an away task is queued and found")
        Away.journal(Away.Unit(task: "t1", step: "type into Message", host: "example.com", window: 7,
                               label: "Message", chars: 5, digest: Away.Unit.digest("hello"), inverse: "clear",
                               at: Date().timeIntervalSince1970))
        check(Away.leftover(task)?.contains("5 characters") == true, "the journal says what was left half-done")
        check((try? String(contentsOf: Away.journalPath, encoding: .utf8))?.contains("hello") == false,
              "the journal never holds the typed text")
        check(Away.claim("t1", from: [.queued])?.state == .running && Away.claim("t1", from: [.queued]) == nil,
              "an away task is claimed once, so two starts never launch it twice")
        let pmset = """
        Assertion status system-wide:
           PreventUserIdleDisplaySleep    1
           SoftwareUpdateTask             0
        Listed by owning process:
           pid 412(zoom.us): [0x0001] 00:12:03 PreventUserIdleDisplaySleep named: "call"
           pid 79(caffeinate): [0x0002] 00:00:10 PreventUserIdleSystemSleep named: "caffeinate"
           pid 90(apprentice): [0x0003] 00:00:10 PreventUserIdleDisplaySleep named: "awake"
        \tDetails: something
        """
        check(Away.displayHolders(pmset) == ["zoom.us"], "only a process holding the display awake counts, never the summary table")
        check(Away.displayHolders("   PreventUserIdleDisplaySleep    0\nListed by owning process:\n").isEmpty,
              "nothing holds the display when no process line says so")
        Away.update { $0.removeAll() }
        try? FileManager.default.removeItem(at: Away.journalPath)
        Away.setMode(false)
        check(!Away.mode, "away off is remembered")
        check(Away.acting.contains("type") && !Away.acting.contains("pending"), "only acting commands yield")
    }

    /// The terminal's screen model: text, colours, erase and the alternate screen a TUI runs in.
    private static func terminal() {
        let trust: [String] = ["Do you trust this folder?", "", " ❯ 1. Yes, proceed", "   2. No, exit", "", "Steps:", "1. read", "2. write"]
        let picks: [String?] = [0, 2, 3].map { TermSession.menuChoice(trust, row: $0) }
        check(picks == [nil, "1", "2"],
              "terminal: a click on a menu's numbered option types its number")
        check(TermSession.menuChoice(["Steps:", "1. read", "2. write", "> hello"], row: 1) == nil,
              "terminal: a numbered list with no chosen line is never clicked into the prompt")
        let esc = String(UnicodeScalar(27)!)
        let screen = TermScreen(cols: 20, rows: 5)
        func feed(_ s: String) { screen.feed(Data(s.utf8)) }
        feed("hello")
        check(screen.rowText(0).hasPrefix("hello"), "terminal: text lands on the screen")
        feed("\r\nworld")
        check(screen.rowText(1).hasPrefix("world"), "terminal: a newline moves to the next line")
        feed(esc + "[2J" + esc + "[H")
        check(screen.rowText(1).trimmingCharacters(in: .whitespaces).isEmpty, "terminal: erase display clears it")
        feed(esc + "[31mred")
        check(screen.grid[0].cells[0].fg == 1, "terminal: a colour sets the foreground")
        feed(esc + "[?1049h")
        check(screen.alt, "terminal: the alternate screen starts")
        check(screen.rowText(0).trimmingCharacters(in: .whitespaces).isEmpty, "terminal: the alternate screen starts blank")
        feed(esc + "[?1049l")
        check(screen.rowText(0).hasPrefix("red"), "terminal: the alternate screen comes back")
        feed(esc + "[?25l")
        check(!screen.cursorVisible, "terminal: the cursor can be hidden")
        screen.resize(cols: 10, rows: 3)
        check(screen.cols == 10 && screen.rows == 3, "terminal: a resize reflows the grid")

        // Claude Code queries the kitty keyboard with `CSI ? u`; read as a cursor restore, it drew a menu's new
        // selection on the top rows and the menu on screen never changed.
        let menu = TermScreen(cols: 20, rows: 6)
        menu.feed(Data((esc + "7" + "\r\n\r\n> one\r\n  two\r\n" + esc + "[?u" + esc + "[2A\r  one\r\n> two").utf8))
        check(menu.rowText(3).hasPrefix("> two") && menu.rowText(2).hasPrefix("  one"),
              "terminal: CSI ? u leaves the cursor where it is")
        menu.feed(Data((esc + "[?1000h" + esc + "[?1006h" + esc + "[?2004h" + esc + "[?1004h").utf8))
        check(menu.mouseTracking && menu.sgrMouse && menu.bracketedPaste && menu.focusEvents,
              "terminal: mouse, paste and focus modes are tracked")
        menu.feed(Data((esc + "[?1000l" + esc + "[?2004l").utf8))
        check(!menu.mouseTracking && !menu.bracketedPaste, "terminal: the modes turn off again")
    }

    /// One agent per screen: a second one is refused until the first is quiet or frees it.
    private static func oneAtATime() {
        defer { try? FileManager.default.removeItem(at: Device.file()) }
        try? FileManager.default.removeItem(at: Device.file())
        var a = Request(cmd: "click", args: ["3"]); a.tab = "A"
        var b = Request(cmd: "click", args: ["4"]); b.tab = "B"
        let now = Date().timeIntervalSince1970
        check((try? Device.check(a, now: now)) != nil, "device: the first agent takes the screen")
        check((try? Device.check(a, now: now + 10)) != nil, "device: and keeps using it")
        do { try Device.check(b, now: now + 20); check(false, "device: a second agent is refused") } catch let f as Fail {
            check(f.code == 4 && f.message.contains("in use by"), "device: a second agent is refused with who holds it")
        } catch { check(false, "device: a second agent is refused") }
        check((try? Device.check(Request(cmd: "log"), now: now + 20)) != nil, "device: reading the log is never refused")
        var user = Request(cmd: "click", args: ["1"]); user.user = true
        check((try? Device.check(user, now: now + 20)) != nil, "device: the user's own click is never refused")
        check((try? Device.check(b, now: now + 10 + Device.busySeconds + 1)) != nil, "device: a quiet holder lets the next agent in")
        check(Device.busy(vm: nil, for: "tab:B") == nil && Device.busy(vm: nil, for: "schedule:x") != nil, "device: schedules see who holds it")
    }

    /// The Sites screen: its spec reads cleanly, and every control writes where the commands read.
    private static func sitesScreen() {
        let fm = FileManager.default
        let files = SiteSettings.Files(config: Store.dir.appendingPathComponent("sites-test.toml"),
                                       budgets: Store.dir.appendingPathComponent("sites-test.json"))
        defer { try? fm.removeItem(at: files.config); try? fm.removeItem(at: files.budgets); try? fm.removeItem(at: Config.path) }
        let shipped = SiteSettings.specFile
        if fm.fileExists(atPath: shipped.path) {
            let spec = SiteSettings.spec(shipped)
            let problems = SiteSettings.problems(spec)
            check(problems.isEmpty && !spec.fields.isEmpty && spec.preset("instagram.com") != nil,
                  "sites: the shipped spec reads cleanly (\(problems.prefix(2).joined(separator: "; ")))")
        }
        let spec = SiteSettings.parse("""
        [group.pace]
        title = "Pace"
        [field.style]
        group = "pace"
        store = "style"
        type = "choice"
        key = "style"
        label = "Pace"
        choices = ["careful", "steady", "fast"]
        labels = ["Careful", "Steady", "Fast"]
        [field.dwell]
        group = "pace"
        store = "pace"
        type = "range"
        key = "dwell_s"
        label = "Reading"
        [field.like]
        group = "pace"
        store = "budget"
        type = "cap"
        key = "like"
        label = "Likes"
        [preset."instagram.com"]
        label = "Instagram"
        style = "careful"
        like = { hour = 20, day = 100, min_gap_s = 30 }
        """)
        check(SiteSettings.problems(spec).allSatisfy { $0.hasPrefix("text.") } && spec.text("x {n}", ["n": "1"]) == "x 1" && spec.fields.map(\.id) == ["style", "dwell", "like"], "sites: fields keep the spec's order")
        try? "# mine\n[agent]\nsounds = true\n".write(to: files.config, atomically: true, encoding: .utf8)
        let style = spec.fields[0], dwell = spec.fields[1], like = spec.fields[2]
        _ = try? SiteSettings.apply(spec.presets[0], spec: spec, files)
        let toml = Toml.load(files.config)
        check(Toml.array(toml["pace.styles"]?["careful"] ?? "") == ["instagram.com"]
              && Budgets.cap("www.instagram.com", "like", table: Budgets.table(files.budgets)).day == 100
              && SiteSettings.explicit("instagram.com", like, files) == "{ hour = 20, day = 100, min_gap_s = 30 }"
              && SiteSettings.sites(files) == ["instagram.com"], "sites: a preset writes the style list and the caps")
        check((try? SiteSettings.set("instagram.com", style, "\"fast\"", files)) == nil, "sites: a social site never goes below steady")
        try? SiteSettings.set("example.org", dwell, "[2, 9]", files)
        check(SiteSettings.explicit("example.org", dwell, files) == "[2, 9]" && SiteSettings.explicit("example.org", style, files) == nil
              && SiteSettings.usual("example.org", style, files: files) == "\"steady\"", "sites: one key for a site, the rest usual")
        try? SiteSettings.set("example.org", dwell, nil, files)
        try? SiteSettings.remove("instagram.com", files)
        let left = (try? String(contentsOf: files.config, encoding: .utf8)) ?? ""
        check(left == "# mine\n[agent]\nsounds = true\n" && SiteSettings.sites(files).isEmpty, "sites: removing a site leaves the rest of the file as it was")
        check(SiteSettings.cap("{ hour = 2, min_gap_s = 30 }").map { $0.count } == 2 && SiteSettings.cap("{}") == nil
              && SiteSettings.capLiteral(["day": 5, "hour": 1]) == "{ hour = 1, day = 5 }", "sites: caps read and write")
        let careful = PaceConfig.preset("careful", on: PaceConfig())!
        let keys = ["move_ms", "between_actions_ms", "nav_min_gap_s", "actions_per_min", "dwell_s", "key_error_rate", "browse",
                    "quiet_hours", "session_max_min", "break_min", "actions_per_day", "rest_s", "fidget"]
        check(keys.allSatisfy { k in careful.literal(k).map { PaceConfig([k: $0]).literal(k) == $0 } == true }
              && PaceConfig().literal("quiet_hours") == "[]", "sites: a pace value shown is the value the reader reads back")
        try? "[pace.\"example.org\"]\nfidget = 0.3\n".write(to: Config.path, atomically: true, encoding: .utf8)
        check(Config.load().profiles["example.org"]?.mode == "human", "a website's own pace starts from every website's, never the apps' fastest")
    }

    /// The agent CLIs come from files: order kept, the user's entry replaces the shipped one with its id.
    private static func agentList() {
        let shipped = Store.dir.appendingPathComponent("agents-test.toml"), mine = Store.dir.appendingPathComponent("agents-mine.toml")
        defer { try? FileManager.default.removeItem(at: shipped); try? FileManager.default.removeItem(at: mine) }
        try? "[agent.a]\nlabel = \"A\"\nrun = [\"a\", \"-p\", \"{prompt}\"]\naliases = [\"a-cli\"]\n[agent.sh]\nopen = \"\"\nshell = true\n"
            .write(to: shipped, atomically: true, encoding: .utf8)
        try? "[agent.a]\nlabel = \"Mine\"\nrun = [\"mine\", \"{prompt}\"]\n[agent.b]\n".write(to: mine, atomically: true, encoding: .utf8)
        let list = AgentCLIs.all([shipped, mine])
        check(list.map(\.id) == ["a", "sh", "b"] && list[0].label == "Mine" && list[1].open == nil && list[1].shell && list[2].open == "b",
              "agents: shipped order, the user's entry replaces one and adds another")
        check(AgentCLIs.argv("A", "do it", in: list) == ["mine", "do it"] && AgentCLIs.argv("zz", "x", in: list) == ["zz", "x"],
              "agents: a prompt goes where {prompt} is; an unknown agent gets it as its argument")
        if FileManager.default.fileExists(atPath: AgentCLIs.files[0].path) {
            check(AgentCLIs.all([AgentCLIs.files[0]]).allSatisfy { !$0.run.isEmpty && !$0.label.isEmpty }, "agents: every shipped agent has a label and a run line")
        }
    }

    /// Skills come in three kinds by folder; learned facts stay small, dated and deduplicated.
    private static func skillKinds() {
        let fm = FileManager.default
        let builtIn = Store.dir.appendingPathComponent("skills-test-builtin")
        defer { try? fm.removeItem(at: builtIn); try? fm.removeItem(at: Skills.root); unsetenv("APPRENTICE_PLAYBOOKS") }
        setenv("APPRENTICE_PLAYBOOKS", builtIn.path, 1)
        func put(_ dir: URL, _ path: String, _ title: String) {
            let url = dir.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "---\nscope: site\nmatch: example.com\n---\n# \(title)\n## Key facts\n- one\n".write(to: url, atomically: true, encoding: .utf8)
        }
        put(builtIn, "web/example.com.md", "shipped")
        put(Skills.learnedDir, "web/example.com.md", "learned")
        put(Skills.learnedDir, "web/other.example.md", "learned only")
        let all = Playbooks.all()
        check(all.first { $0.path == "web/example.com.md" }?.origin == .learned, "skills: a learned skill takes the place of a built-in one with its path")
        check(Playbooks.all(includeShadowed: true).filter { $0.path == "web/example.com.md" }.count == 2, "skills: the shadowed one is still there")
        put(Skills.yoursDir, "web/example.com.md", "mine")
        check(Playbooks.all().first { $0.path == "web/example.com.md" }?.origin == .yours, "skills: yours come before learned ones")
        check(Playbooks.hintLines(app: nil, bundle: nil, host: "example.com").contains { $0.contains("yours: the user's own words") },
              "skills: session says which kind each skill is")

        let target = "shop.example.org"
        for i in 1...(Skills.maxFacts + 3) { _ = try? Skills.addFact("Fact number \(i) about the shop page", for: target, day: "2026-01-0\(i % 9 + 1)") }
        let file = Skills.factFile(for: target).url
        var facts = Playbooks.parse((try? String(contentsOf: file, encoding: .utf8)) ?? "", url: file, path: "x").keyFacts
        check(facts.count == Skills.maxFacts && facts.first?.hasSuffix("Fact number \(Skills.maxFacts + 3) about the shop page") == true,
              "skills: learned facts are capped, newest first")
        _ = try? Skills.addFact("fact NUMBER 5 about the shop page", for: target, day: "2026-02-01")
        facts = Playbooks.parse((try? String(contentsOf: file, encoding: .utf8)) ?? "", url: file, path: "x").keyFacts
        check(facts.first == "2026-02-01 · fact NUMBER 5 about the shop page" && facts.filter { Skills.factKey($0) == Skills.factKey("fact number 5 about the shop page") }.count == 1,
              "skills: the same fact again moves up, dated, instead of repeating")
        check((try? Skills.addFact("Write to sam@gmail.com for refunds", for: target)) == nil, "skills: a fact that looks personal is refused")
        check(Skills.factFile(for: "Finder").url.path.hasSuffix("learned/macos/finder.md"), "skills: an app's facts go under macos/")

        let rows: [[String: Any]] = [["cmd": "click", "diff": "+1 -0 ~0"], ["cmd": "type", "diff": "+0 -0 ~1"], ["error": "x"], ["cmd": "key", "diff": "+0 -0 ~0"]]
        check(Skills.worked(rows).actions == 2 && !Skills.worked(rows).endedOnError, "skills: a session that recovered from an error still worked")
        check(Skills.worked(rows + [["error": "y"]]).endedOnError, "skills: one that ended on an error did not")
    }

    /// Pipelines are files people edit by hand: they must read back exactly, numbered headings or not.
    private static func pipelines() {
        let text = """
        ---
        name: Morning round
        agent: codex
        vm: shop   # the shop's VM
        ---
        # Morning round

        Every weekday before work.

        ## 1. Read Instagram
        Get the newest comments.
        Note the ones about prices.

        ## Answer
        sh: echo done
        """
        let p = Pipelines.parse(text)
        check(p.name == "Morning round" && p.agent == "codex" && p.vm == "shop", "pipelines: front matter is read")
        check(p.steps.count == 2 && p.steps[0].title == "Read Instagram" && p.steps[0].prompt.hasSuffix("about prices."),
              "pipelines: each ## heading is a step, its number dropped")
        check(p.steps[1].shell == "echo done" && p.steps[0].shell == nil, "pipelines: sh: makes a shell step")
        check(p.about == "Every weekday before work.", "pipelines: text before the first step is kept")
        let again = Pipelines.parse(Pipelines.render(p))
        check(again.steps == p.steps && again.name == p.name && again.vm == p.vm && again.about == p.about,
              "pipelines: render and parse round-trip")
        let prompt = Pipelines.prompt(p, step: 1, previous: String(repeating: "x", count: 9000))
        check(prompt.hasPrefix("This is step 2 of 2") && prompt.count < 6400, "pipelines: the previous output is passed, capped")
        check(Projects.notes(name: "Shop", vm: "shop", about: "").contains("APPRENTICE_VM=shop"),
              "projects: the agent notes name the project's VM")
    }

    /// The comment-preserving edit: a UI change never rewrites what a person wrote by hand.
    private static func tomlEdits() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("apprentice-toml-\(getpid()).toml")
        let text = """
            # top comment
            top = 1

            [agent]
            # keep me
            ask_sound = "Ping"   # a trailing note
            menu_bar = true

            [pace."x.com"]
            actions_per_min = 8
            """
        try? text.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        check(Toml.set(file, "agent", "ask_sound", "\"Glass\""), "a key is changed")
        let after = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        check(after.contains("# top comment") && after.contains("# keep me"), "comments survive an edit")
        check(after.contains("ask_sound = \"Glass\" # a trailing note"), "a trailing comment stays on its line")
        check(Toml.load(file)["agent"]?["ask_sound"].map(Toml.unquote) == "Glass", "the new value reads back")
        check(Toml.set(file, "agent", "sounds", "false"), "a missing key is added to its section")
        check(Toml.load(file)["agent"]?["sounds"] == "false" && Toml.load(file)["pace.x.com"]?["actions_per_min"] == "8",
              "an added key stays in its section")
        check(Toml.set(file, "app", "font", "\"Menlo\""), "a missing section is added")
        check(Toml.load(file)["app"]?["font"].map(Toml.unquote) == "Menlo", "the new section reads back")
        check(Toml.remove(file, "agent", "menu_bar") && Toml.load(file)["agent"]?["menu_bar"] == nil, "a key can be removed")
        check(Toml.set(file, "pace.x.com", "actions_per_min", "6") && Toml.set(file, "pace.\"x.com\"", "actions_per_day", "40"),
              "a quoted section is found by either spelling")
        let quoted = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        check(quoted.components(separatedBy: "[pace.").count == 2 && Toml.load(file)["pace.x.com"]?["actions_per_min"] == "6",
              "editing a quoted section never adds a second copy of it")
        let multi = ["[a]", "list = [", "  [1, 2],", "]", "x = 1", "[b]"]
        check(Toml.bounds(multi, "a").map { $0 == (1, 5) } == true, "a multi-line array does not end its section")
        check(Toml.problems("[agent]\nask_sound = \"Ping\"\nlist = [\n  1,\n]\n").isEmpty, "valid TOML has no problems")
        check(!Toml.problems("[agent]\nask_sound = \"Ping\n").isEmpty, "an unclosed string is a problem")
        check(!Toml.problems("[agent\n").isEmpty && !Toml.problems("just words\n").isEmpty && !Toml.problems("a = [1,\n").isEmpty,
              "a broken header, a bare line and an open array are problems")
    }

    /// The automatic update against throwaway git repos: a clean update, a dirty tree, a conflict and a
    /// failed build.
    private static func updates() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("apprentice-repo-\(getpid())")
        defer {
            try? FileManager.default.removeItem(at: base)
            Repo.testRoot = nil
            Repo.testBuild = nil
        }
        let up = base.appendingPathComponent("up"), clone = base.appendingPathComponent("clone")
        func sh(_ script: String, in dir: URL) -> Int32 {
            Repo.run("sh", ["-c", "git -c init.defaultBranch=main " + script], in: dir).code
        }
        try? FileManager.default.createDirectory(at: up.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        let id = "-c user.name=t -c user.email=t@t"
        guard sh("init -q && echo one > Sources/a.swift && git \(id) add -A && git \(id) commit -qm one", in: up) == 0,
              Repo.run("git", ["clone", "-q", "-o", "upstream", up.path, clone.path], in: base).code == 0 else {
            check(false, "git is needed for the update checks")
            return
        }
        Repo.git("-C", clone.path, "config", "user.name", "t")
        Repo.git("-C", clone.path, "config", "user.email", "t@t")
        Repo.testRoot = clone
        Repo.testBuild = { (0, "built") }
        func head() -> String { Repo.git("rev-parse", "HEAD").out }
        func upstreamCommit(_ text: String, _ file: String = "Sources/a.swift") {
            _ = sh("\(id) commit -qm x --allow-empty && echo '\(text)' > \(file) && git \(id) add -A && git \(id) commit -qm '\(text)'", in: up)
            Repo.git("fetch", "-q", "upstream")
        }
        upstreamCommit("two")
        let before = head()
        check(Repo.applyUpdate() && head() != before, "a clean clone updates and asks for a restart")
        upstreamCommit("three")
        try? "x".write(to: clone.appendingPathComponent("Sources/dirty.swift"), atomically: true, encoding: .utf8)
        let dirty = head()
        check(!Repo.applyUpdate() && head() == dirty, "a clone with uncommitted changes is left alone")
        try? FileManager.default.removeItem(at: clone.appendingPathComponent("Sources/dirty.swift"))
        try? "mine".write(to: clone.appendingPathComponent("Sources/a.swift"), atomically: true, encoding: .utf8)
        Repo.git("commit", "-qam", "mine")
        let mine = head()
        check(!Repo.applyUpdate() && head() == mine && Repo.git("status", "--porcelain").out.isEmpty, "a conflict changes nothing")
        Repo.git("reset", "-q", "--hard", "upstream/main")
        upstreamCommit("four", "Sources/b.swift")
        Repo.testBuild = { (1, "error: broken") }
        let good = head()
        check(!Repo.applyUpdate() && head() == good, "a failed build goes back to the old commit")
    }

    /// Prefs: the nearest device wins, only the user's words or the task's own site are saved, and lookups match words.
    private static func prefs() {
        let p = { (v: String) in Prefs.Pref(value: v, from: "you", at: "2026-11-02") }
        let seen = Prefs.merge([(.vm(nil), ["gym": p("vm-gym.com")]), (.mac, ["gym": p("mac-gym.com"), "linkedin": p("in/sam")])])
        check(seen.count == 2 && seen.first { $0.key == "gym" }?.pref.value == "vm-gym.com", "a VM's own pref wins over the Mac's")
        check(seen.first { $0.key == "linkedin" }?.place == .mac, "a pref only the Mac has is inherited")
        check(Prefs.key("My Gym!") == "my-gym" && Prefs.key("") == nil, "keys are lower case words joined by dashes")
        check(Prefs.valueProblem("a\nb") != nil && Prefs.valueProblem(String(repeating: "x", count: 201)) != nil
              && Prefs.valueProblem("bookings.gym.com") == nil, "a value is one short line")
        check(Prefs.taskValueOK("https://www.gym.com/book", url: "https://gym.com/classes", app: "Safari"), "--from task takes the session's site")
        check(!Prefs.taskValueOK("evil.com", url: "https://gym.com/classes", app: "Safari"), "--from task refuses another site")
        check(Prefs.taskValueOK("gym.com", url: "https://book.gym.com/", app: nil) && !Prefs.taskValueOK("com", url: "https://gym.com/", app: nil)
              && !Prefs.taskValueOK("notgym.com", url: "https://gym.com/", app: nil), "a subdomain is the same site, a lookalike is not")
        check(Prefs.taskValueOK("Figma", url: nil, app: "Figma"), "--from task takes the session's app")
        check(Prefs.matching(seen, "book my gym class").map(\.key) == ["gym"], "a task finds the prefs it mentions")
        check(Prefs.matching(seen, "").count == 2, "no words lists every pref")
        check(Prefs.matching(seen, Prefs.sessionText(task: nil, app: "Safari", host: "www.gym.com")).map(\.key) == ["gym"]
              && Prefs.matching(seen, Prefs.sessionText(task: nil, app: "Safari", host: "www.example.com")).isEmpty,
              "session finds prefs by the site's name, never by its .com")
        let config = Layers.overlay(["pace.default": ["min": "1", "max": "2"], "agent": ["ui_only": "false"]],
                                    ["pace.default": ["max": "3"]])
        check(config["pace.default"] == ["min": "1", "max": "3"] && config["agent"]?["ui_only"] == "false",
              "a VM's config.toml overrides key by key and inherits the rest")
        let child = Layers.childOnly(["vm": ["name": "x"], "vm.linkedin": ["host": "h"], "update": ["auto": "false"],
                                      "agent": ["menu_bar": "false", "sounds": "false"]])
        check(child == ["agent": ["sounds": "false"]], "a project or VM never changes how this Mac runs: [vm], [update], the menu bar")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apprentice-layers-\(UUID().uuidString)/.apprentice")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()); Project.dir = nil }
        Project.dir = dir
        try? Layers.write("config.toml", "[agent]\nsounds = false\n", .project(dir))
        check(Layers.chain.first == .project(dir) && Layers.chain.last == .mac, "a project's settings are read first, this Mac's last")
        check(Layers.config()["agent"]?["sounds"] == "false", "a project's own value wins over the levels above it")
        check(Layers.Place.vm(nil).folder != Layers.Place.vm("vm").folder, "the default VM's settings are never a named VM's")
    }
}
