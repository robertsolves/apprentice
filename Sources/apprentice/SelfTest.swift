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
        approvals()
        limits()
        sites()
        budgets()
        policies()
        gate()
        allowlist()
        flows()
        notes()
        prefs()
        learning()
        projects()
        updates()
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
        check(Site.matches("api.example.com", "example.com") && Site.matches("Example.com", "example.com"), "subdomains and case match")
        check(!Site.matches("badexample.com", "example.com") && !Site.matches("example.com.evil.io", "example.com"), "look-alike hosts do not match")
        check(Budgets.kind("button \"Unfollow\"", gated: true) == "unfollow", "unfollow is not a follow")
        check(Budgets.kind("button \"Add friend\"", gated: true) == "friend_request", "add friend is a friend request")
        check(Budgets.kind("button \"Unlike\"", gated: false) == nil && Budgets.kind("button \"Following\"", gated: false) == nil,
              "whole words only")
        check(Budgets.kind("button \"Archive\"", gated: true) == "default" && Budgets.kind("link \"Home\"", gated: false) == nil,
              "any other gated action counts as default, an ungated one not at all")
        check(Budgets.plural("friend_request") == "friend requests" && Budgets.plural("default") == "gated actions", "plurals")
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
    }

    /// Meta and TikTok are forbidden whatever the subdomain; routes.toml sets the rest.
    private static func policies() {
        func allowed(_ host: String?, _ cmd: String) -> Bool { (try? Policies.check(host, cmd: cmd)) != nil }
        check(!allowed("www.instagram.com", "read") && !allowed("m.facebook.com", "click"), "built-in forbidden sites refuse every command")
        check(allowed("notinstagram.com", "click") && allowed(nil, "click"), "other sites and no page are not refused")
        let path = Routes.customPath
        defer { try? FileManager.default.removeItem(at: path) }
        try? """
        [policy."news.example"]
        automation = "read-only"
        [policy."tiktok.com"]
        automation = "allowed"
        """.write(to: path, atomically: true, encoding: .utf8)
        check(allowed("www.news.example", "read") && allowed("news.example", "scroll"), "a read-only site can be read")
        check(!allowed("news.example", "click") && !allowed("news.example", "type"), "a read-only site refuses changes")
        check(allowed("tiktok.com", "click"), "a routes.toml entry replaces a built-in one")
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
        var missing = Set<String>()
        let filled = Commands.fill("type 3 \"{First Name} {city}\"", ["first-name": "Ada"], &missing)
        check(filled == "type 3 \"Ada ‹city›\"" && missing == ["city"], "placeholders fill, a missing one is marked and reported")
        var loop = Set<String>()
        check(!Commands.fill("{a}", ["a": "{a}"], &loop).isEmpty, "a value that brings its placeholder back does not loop for ever")
    }

    /// Notes: front matter, key facts, steps, and which session sees which note.
    private static func notes() {
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
        let n = Notes.parse(text, url: URL(fileURLWithPath: "/x/new-folder.md"), path: "flows/new-folder.md")
        check(n.meta["scope"] == "flow" && n.title == "New folder" && n.match == ["finder"], "front matter and title")
        check(n.keyFacts == ["one", "two"], "key facts are the bullets under their heading")
        check(Notes.steps(n) == ["`menu \"File > New Folder\"`", "Pick the row by hand."], "steps are the numbered lines under Steps")
        check(Notes.parse("# T\nbody", url: URL(fileURLWithPath: "/x/a.md"), path: "a.md").meta.isEmpty, "no front matter is fine")
        check(Notes.slugify("Post a job: LinkedIn (draft)!") == "post-a-job-linkedin-draft", "slugs")

        let root = Store.dir.appendingPathComponent("notes-test")
        defer { try? FileManager.default.removeItem(at: root); unsetenv("APPRENTICE_NOTES") }
        func write(_ name: String, _ meta: String) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? "---\n\(meta)\n---\n# \(name)\n".write(to: root.appendingPathComponent(name + ".md"), atomically: true, encoding: .utf8)
        }
        write("mac", "scope: system\nmatch: *\nsystem: macos")
        write("linux", "scope: system\nmatch: *\nsystem: linux")
        write("site", "scope: site\nmatch: example.com")
        write("flow", "scope: flow\nmatch: *")
        setenv("APPRENTICE_NOTES", root.path, 1)
        func seen(_ host: String?, _ system: String) -> [String] {
            Notes.matching(app: "Chromium", bundle: nil, host: host, system: system).map(\.title).sorted()
        }
        check(seen("www.example.com", "linux") == ["linux", "site"], "the VM sees its own notes and the site's, not the Mac's")
        check(seen("badexample.com", "macos") == ["mac"], "a look-alike host gets no site note, and flows never show")
    }

    /// What makes the next run faster: flows ranked per model, `do --explain`, the scrubbed session copy,
    /// learned routes and the PR helpers.
    private static func learning() {
        let root = Store.dir.appendingPathComponent("learning-test")
        defer { try? FileManager.default.removeItem(at: root); unsetenv("APPRENTICE_NOTES") }
        func write(_ name: String, _ meta: String) {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent("flows"), withIntermediateDirectories: true)
            try? "---\nscope: flow\n\(meta)\n---\n# \(name)\n## Steps\n1. `key cmd+n`\n".write(to: root.appendingPathComponent("flows/\(name).md"), atomically: true, encoding: .utf8)
        }
        write("draft-m1", "match: example.com\ntags: post, draft\nmodel: m1")
        write("draft-any", "match: example.com\ntags: post, draft")
        write("unrelated", "match: example.com\ntags: invoice")
        setenv("APPRENTICE_NOTES", root.path, 1)
        let m1 = Notes.rank(task: "post a draft", model: "m1", session: nil).map { $0.note.url.deletingPathExtension().lastPathComponent }
        check(m1 == ["draft-m1", "draft-any"], "a flow learned by this model ranks first, unrelated flows are left out")
        let m2 = Notes.rank(task: "post a draft", model: "m2", session: nil).map { $0.note.url.deletingPathExtension().lastPathComponent }
        check(m2 == ["draft-any"], "another model's flow is left out unless it says any")
        check(Notes.explain("post a draft", model: "m1", session: nil).contains("→ "), "do --explain names the pick and its score")
        check(Notes.context(task: "post a draft", session: nil, model: "m1", budget: 50).count < 120, "the run loop's notes stay under their budget")

        let row: [String: Any] = ["cmd": "click", "label": "button", "name": "Send to Sam", "url": "https://mail.example.com/inbox?q=sam",
                                  "error": "no button \"Send to Sam\" at https://x.example/a", "api_key": "sk-1", "ms": 10]
        let scrubbed = Sessions.scrub(row, mode: "scrubbed") ?? [:]
        check(scrubbed["host"] as? String == "mail.example.com" && scrubbed["url"] == nil && scrubbed["name"] == nil,
              "a scrubbed row keeps the host, not the URL or the element's name")
        check((scrubbed["error"] as? String).map { !$0.contains("Sam") && !$0.contains("https") } == true, "a scrubbed error loses quoted text and URLs")
        check(Sessions.scrub(row, mode: "full")?["api_key"] == nil && scrubbed["api_key"] == nil, "no mode keeps a secret")

        let flow = Notes.parse("---\nscope: flow\nmatch: example.com\ntags: post, draft\n---\n# Draft\n", url: root.appendingPathComponent("flows/draft-any.md"), path: "flows/draft-any.md")
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
        let seen = Prefs.merge([(.vm, ["gym": p("vm-gym.com")]), (.mac, ["gym": p("mac-gym.com"), "linkedin": p("in/sam")])])
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
        let config = Layers.overlay(["pace.default": ["min": "1", "max": "2"], "agent": ["ui_only": "false"]],
                                    ["pace.default": ["max": "3"]])
        check(config["pace.default"] == ["min": "1", "max": "3"] && config["agent"]?["ui_only"] == "false",
              "a VM's config.toml overrides key by key and inherits the rest")
    }
}
