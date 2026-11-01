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
        toml()
        args()
        pace()
        wire()
        routing()
        diffs()
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
    }

    private static func pace() {
        let p = PaceConfig(["move_ms": "[900000, -1]", "key_ms_sigma": "nan", "actions_per_min": "0", "burst": "[5, 2]"])
        check(p.moveMin <= p.moveMax && p.moveMax <= 5 && p.moveMin >= 0.01, "move range is clamped and ordered")
        check(p.keySigma.isFinite, "a non-finite value falls back")
        check(p.actionsPerMin >= 1, "actions per minute stays positive")
        check(p.burstMin <= p.burstMax, "pairs are ordered")
    }

    private static func wire() {
        let req = Request(cmd: "type", args: ["3", "héllo \"quoted\"", "--enter"])
        let back = try? JSONDecoder().decode(Request.self, from: Wire.json(req))
        check(back?.cmd == req.cmd && back?.args == req.args, "a request survives the wire")
        let resp = Response(code: 8, out: "approve with token", data: ["token": "ab12"])
        let r = try? JSONDecoder().decode(Response.self, from: Wire.json(resp))
        check(r?.code == 8 && r?.out == resp.out && r?.data?["token"] == "ab12", "a response survives the wire")
    }

    private static func routing() {
        func place(_ cmd: String, _ args: [String] = [], on: Bool = true, target: String = "vm") -> VM.Place {
            VM.place(Request(cmd: cmd, args: args), on: on, target: target)
        }
        if case .local(nil) = place("click", ["3"], on: false) {} else { check(false, "with the VM off everything is local") }
        if case .remote(let r, true) = place("session") {
            check(r.args == ["--app", VM.browser], "a bare session goes to the VM's browser")
        } else { check(false, "a bare session goes to the VM") }
        if case .remote(_, true) = place("session", ["--app", "Safari"], target: "local") {} else { check(false, "a browser session goes to the VM") }
        if case .local("local") = place("session", ["--app", "Finder"]) {} else { check(false, "a native app stays on this Mac and takes the session back") }
        if case .local("local") = place("focus", ["Finder"]) {} else { check(false, "focusing a native app stays local") }
        if case .remote(_, true) = place("focus", ["Google Chrome"], target: "local") {} else { check(false, "focusing a browser goes to the VM") }
        if case .remote(_, false) = place("click", ["3"]) {} else { check(false, "actions follow a VM session") }
        if case .local(nil) = place("click", ["3"], target: "local") {} else { check(false, "actions follow a local session") }
        for cmd in ["ask", "awake", "away", "kill"] {
            if case .local(nil) = place(cmd) {} else { check(false, "\(cmd) stays with the user on this Mac") }
        }
        if case .confirm = place("confirm", ["ab12"]) {} else { check(false, "confirm opens on this Mac for a VM step") }
        check(VM.isBrowser("Safari") && VM.isBrowser("Brave Browser.app") && !VM.isBrowser("Finder"), "browser names")
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
    }
}
