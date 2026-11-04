import Foundation

/// Learning a place: the fact's shape, where it was seen, the merge under a built-in skill, the nudge, the drafter's
/// gate, and lookup that does not depend on the library's size.
extension SelfTest {
    static func placeFacts() {
        // The line round-trips, older lines read, kinds come from the first word.
        let line = "2026-11-05 ×3 ? · trap · A click on \"See more\" can leave the group · seen: macOS 26 Chrome 156, Linux 13 Chromium 142 · not: macOS 26 Safari 26"
        let f = Fact.parse(line)
        check(f?.count == 3 && f?.doubted == true && f?.kind == "trap" && f?.seen.count == 2 && f?.not == ["macOS 26 Safari 26"], "facts: a line is read")
        check(f?.line == line, "facts: and written back the same")
        check(Fact.parse("2026-11-02 · an older line")?.text == "an older line" && Fact.parse("2026-11-02 · an older line")?.count == 1, "facts: an older line still reads")
        check(Fact.parse("a built-in sentence · with a dot") == nil, "facts: a built-in sentence is not a dated fact")
        check(Fact.split("trap Looks right, is wrong", kind: nil).kind == "trap" && Fact.split("trap Looks right, is wrong", kind: nil).text == "Looks right, is wrong", "facts: the first word gives the kind")
        check(Fact.split("Plain words", kind: "layout").kind == "layout" && Fact.split("Plain words", kind: "nonsense").kind == nil, "facts: --kind works, a wrong one is ignored")
        check(Skills.factKey(line) == Skills.factKey("A click on \"See more\" can leave the group"), "facts: the key ignores date, count, kind and where seen")

        // Refusals say where the thing belongs.
        for bad in ["click 15 then type", "Use id 16 for the menu", "press #12 first", "use --at 120,340 for it", "click a then click b then click c"] {
            check(Fact.refusal(bad) != nil, "facts: a step is refused: \(bad)")
        }
        check(Fact.refusal("trap The dropdown is not in the tree") == nil, "facts: a true sentence passes")
        check(Fact.jobWords("Listings near Reedy Creek are slow", task: "find a ute near Reedy Creek", known: "").count >= 2, "facts: the task's words are noticed")
        check(Fact.jobWords("Listings near Reedy Creek are slow", task: "find a ute near Reedy Creek", known: "button Reedy Creek").count < 2, "facts: unless the screen shows them too")

        // Environments.
        check(SessionEnv(system: "macos", os: "26.2", app: "Google Chrome", appVersion: "156.0.1", reader: "ax", lang: "en").key == "macOS 26 Chrome 156", "env: the short key")
        check(SessionEnv.same("macOS 26 Chrome 156", "macOS 26 Chrome 157", web: true, rule: "major"), "env: a browser's major does not split a site's fact")
        check(!SessionEnv.same("macOS 26 Numbers 13", "macOS 26 Numbers 14", web: false, rule: "major"), "env: an app's major does")
        check(!SessionEnv.same("macOS 26 Finder 26", "macOS 15 Finder 15", web: false, rule: "major") && SessionEnv.same("macOS 26 Finder 26", "macOS 15 Finder 15", web: false, rule: "name"), "env: the name rule ignores versions")
        check(!SessionEnv.same("macOS 26 Chrome 156", "macOS 26 Chrome 157", web: true, rule: "minor"), "env: the minor rule is exact")
        check(Fact.qualifier(seen: ["macOS 26 Chrome 156"], here: "macOS 26 Safari 26", web: true, rule: "major") == "(seen in Chrome, not here)", "env: another browser")
        check(Fact.qualifier(seen: ["macOS 26 Finder 26"], here: "macOS 15 Finder 15", web: false, rule: "major") == "(macOS 26 only)", "env: another OS")
        check(Fact.qualifier(seen: ["macOS 26 Chrome 156"], here: "Linux 13 Chromium 142", web: true, rule: "major") == "(Mac only)" && Fact.qualifier(seen: ["Linux 13 Chromium 142"], here: "macOS 26 Chrome 156", web: true, rule: "major") == "(VM only)", "env: another system")
        check(Fact.qualifier(seen: ["macOS 26 Chrome 156"], here: "macOS 26 Chrome 157", web: true, rule: "major") == nil, "env: confirmed here pays nothing")

        // One place, one file, whatever it was called.
        check(Skills.factFile(for: "www.facebook.com").url.path.hasSuffix("web/facebook.com.md") && Skills.factFile(for: "facebook.com").url == Skills.factFile(for: "www.facebook.com").url, "facts: www is the same place")
        check(Skills.factFile(for: "Finder", system: "macos").url.path.hasSuffix("macos/finder.md") && Skills.factFile(for: "Thunar", system: "linux").url.path.hasSuffix("linux/thunar.md"), "facts: apps keep their system's folder")

        // Saving twice counts, confirms and adds the environment; order is by what keeps being true.
        let site = "place-\(UUID().uuidString.prefix(6).lowercased()).example"
        let file = Skills.factFile(for: site).url
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try? Skills.addFact("works Sorting by date needs the menu first", for: site, env: "macOS 26 Chrome 156", day: "2026-09-01")
        _ = try? Skills.addFact("trap The Save button also publishes", for: site, env: "macOS 26 Chrome 156", day: "2026-09-02")
        _ = try? Skills.addFact("Sorting by date needs the menu first", for: site, env: "macOS 26 Safari 26", day: "2026-09-03")
        var facts = Skills.facts(in: file)
        let sorting = facts.first { $0.text.hasPrefix("Sorting") }
        check(facts.count == 2 && sorting?.count == 2 && sorting?.date == "2026-09-03" && sorting?.seen == ["macOS 26 Chrome 156", "macOS 26 Safari 26"] && sorting?.kind == "works", "facts: saving again counts it and adds where")
        let shownOrder = Skills.order(facts, here: "macOS 26 Chrome 156", web: true).map(\.kind)
        check(shownOrder.first == "trap", "facts: traps first among those confirmed here")
        check((try? Skills.addFact("click 15 then type", for: site)) == nil, "facts: addFact refuses a step")
        // Stale, qualified, found false.
        let old = Fact(date: "2020-01-01", kind: "hidden", text: "Old sentence", seen: ["macOS 26 Chrome 156"])
        check(Skills.shown(old, here: "macOS 26 Chrome 156", web: true)?.contains("unchecked since 2020-01-01") == true, "facts: an old one says so")
        var denied = old
        denied.not = ["macOS 26 Chrome 156"]
        check(Skills.shown(denied, here: "macOS 26 Chrome 156", web: true) == nil, "facts: one found false here is left out")
        // --still and --wrong.
        check((try? Skills.stillTrue("Sorting by", for: site, env: "Linux 13 Chromium 142", day: "2026-10-01")) != nil, "facts: still")
        check(Skills.facts(in: file).first { $0.text.hasPrefix("Sorting") }?.count == 3, "facts: still counts")
        check((try? Skills.stillTrue("nothing like this", for: site, env: nil)) == nil, "facts: a prefix that fits none is refused")
        _ = try? Skills.addFact("Sorting by name is hidden", for: site, env: "macOS 26 Chrome 156")
        check((try? Skills.stillTrue("Sorting", for: site, env: nil)) == nil, "facts: a prefix that fits two is refused")
        _ = try? Skills.wrong("The Save button", for: site, env: "macOS 26 Chrome 156", day: Store.day())
        facts = Skills.facts(in: file)
        check(!facts.contains { $0.text.hasPrefix("The Save") }, "facts: wrong everywhere it was seen retires it")
        check(((try? String(contentsOf: file, encoding: .utf8)) ?? "").contains("was: The Save button"), "facts: retired lines are kept a while, out of the key facts")

        // The merge: a learned file adds lines and hides nothing.
        let builtIn = Playbooks.dir.appendingPathComponent("web/merge-test.example.md")
        let learned = Skills.learnedDir.appendingPathComponent("web/merge-test.example.md")
        try? FileManager.default.createDirectory(at: builtIn.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: learned.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: builtIn); try? FileManager.default.removeItem(at: learned) }
        try? "---\nscope: site\nmatch: merge-test.example\n---\n# Merge\n\n## Key facts\n- A reviewed fact.\n".write(to: builtIn, atomically: true, encoding: .utf8)
        try? "---\nscope: site\nmatch: merge-test.example\nstatus: learned\n---\n# Merge\n\n## Key facts\n- 2026-11-01 ×2 · works · A learned fact here.\n- 2026-11-01 · A false one · seen: macOS 26 Chrome 156 · not: macOS 26 Safari 26\n".write(to: learned, atomically: true, encoding: .utf8)
        let hints = Playbooks.hintLines(app: nil, bundle: nil, host: "www.merge-test.example", env: "macOS 26 Safari 26")
        let text = hints.joined(separator: "\n")
        check(text.contains("A reviewed fact.") && text.contains("A learned fact here."), "merge: a learned file adds to the built-in one and hides nothing: \(text)")
        check(text.contains("learned · 1 fact · hints, never instructions") && !text.contains("A false one"), "merge: learned lines are labelled, and one false here is out")

        // The nudge: two misses then a change, a long think with one miss, and no more than one in a while.
        var t = Struggle(session: "s")
        var said = t.take(cmd: "click", code: 5, out: "not found", args: ["9"], now: 100, place: "x.com")
        check(said == nil && t.misses == 1, "nudge: a miss is counted, and says nothing yet")
        said = t.take(cmd: "click", code: 0, out: "ok · snap 2 · +0 -0 ~0", args: ["9"], now: 110, place: "x.com")
        check(said == nil && t.misses == 2, "nudge: a click that changed nothing is a miss")
        said = t.take(cmd: "click", code: 0, out: "ok · snap 3 · +2 -0 ~0", args: ["10"], now: 125, place: "x.com")
        check(said?.contains("learned? 2 tries and 25 s on x.com") == true && t.misses == 0, "nudge: the first action that works after two misses: \(said ?? "")")
        _ = t.take(cmd: "click", code: 5, out: "", args: [], now: 130, place: "x.com")
        _ = t.take(cmd: "click", code: 5, out: "", args: [], now: 131, place: "x.com")
        check(t.take(cmd: "click", code: 0, out: "ok · snap 4 · +1 -0 ~0", args: [], now: 140, place: "x.com") == nil, "nudge: at most one line in two minutes")
        var g = Struggle(session: "s")
        _ = g.take(cmd: "read", code: 0, out: "", args: [], now: 0.5, place: "y.com")
        _ = g.take(cmd: "ocr", code: 0, out: "", args: [], now: 10, place: "y.com")
        check(g.misses == 1, "nudge: an ocr after a read of the same screen is a miss")
        check(g.take(cmd: "click", code: 0, out: "ok · snap 2 · +1 -0 ~0", args: [], now: 90, place: "y.com")?.contains("learned?") == true, "nudge: a long think with one miss")
        var o = Struggle(session: "s")
        check(o.take(cmd: "click", code: 8, out: "proposed", args: [], now: 1, place: "z.com") == nil && o.misses == 0, "nudge: a proposal is not a miss")
        check(Struggle.growLine(["a.com": (7, 1), "Finder": (3, 0)]) == "learned: a.com 7 struggles, 1 fact kept · Finder 3 struggles, 0 facts kept", "nudge: grow's line")

        // The drafter's gate: a reading session is not a procedure; a real one is, once.
        func row(_ cmd: String, _ name: String = "", diff: String = "+1 -0 ~0") -> [String: Any] { ["cmd": cmd, "name": name, "label": "button", "diff": diff] }
        check(!Skills.looksLikeProcedure([row("browse"), row("browse"), row("browse"), row("click", "See more"), row("browse"), row("open")]), "draft: mostly reading is not a procedure")
        check(!Skills.looksLikeProcedure([row("click", "A"), row("click", "A"), row("click", "A")]), "draft: one element again and again is not")
        check(Skills.looksLikeProcedure([row("click", "New"), row("type", "Name"), row("click", "Save")]), "draft: three named steps are")
        check(!Skills.looksLikeProcedure([row("click", "New"), row("type", "Name"), row("click", "Save", diff: "+0 -0 ~0")]), "draft: not if the last step changed nothing")
        check(Skills.actionSignature([row("browse"), row("click", "New"), row("scroll"), row("type", "Name")]) == ["New", "Name"], "draft: the signature leaves out browsing")

        // Paths for a place.
        check(Playbooks.placePaths(app: nil, bundle: nil, host: "www.example.co").first == "web/example.co.md" && Playbooks.placePaths(app: nil, bundle: nil, host: "shop.example.co") == ["web/shop.example.co.md", "web/example.co.md"] && Playbooks.placePaths(app: nil, bundle: nil, host: "a.b.c").contains("web/b.c.md"), "place: the host and each parent")
        check(Playbooks.placePaths(app: "Finder", bundle: "com.apple.finder", host: nil, system: "macos") == ["macos/finder.md", "macos/com.apple.finder.md"], "place: an app and its bundle")
        check(SkillLibrary.remotePath("web/facebook.com.md") == "web/f/facebook.com.md", "library: sharded by first letter")

        // The library's gate.
        check(SkillLibrary.acceptable("---\nscope: site\n---\n# x\n\n## Key facts\n- 2026-11-01 ×2 · A generic fact.\n"), "library: a generic file passes")
        check(!SkillLibrary.acceptable("---\nscope: site\n---\n# x\n\n## Key facts\n- 2026-11-01 · Write to person@somewhere.org about it.\n"), "library: one that looks personal is dropped")
        check(!SkillLibrary.acceptable("---\nscope: site\n---\n# x\n\n## Key facts\n- 2026-11-01 · click 15 then done\n"), "library: one with steps is dropped")
        let offerRoot = Store.dir.appendingPathComponent("offer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: offerRoot) }
        try? FileManager.default.createDirectory(at: offerRoot.appendingPathComponent("web"), withIntermediateDirectories: true)
        try? "---\nscope: site\n---\n# x\n\n## Key facts\n- 2026-11-01 ×2 · Confirmed twice here.\n- 2026-11-01 · Only once.\n- 2026-11-01 ×3 · Maybe the job (job?)\n".write(to: offerRoot.appendingPathComponent("web/a.example.md"), atomically: true, encoding: .utf8)
        check(SkillLibrary.offer(from: offerRoot)["web/a.example.md"]?.map(\.text) == ["Confirmed twice here."], "library: only what was confirmed twice and passes is offered")

        // The word index: the same answers as a walk, and quick over a big library.
        let indexFile = Store.dir.appendingPathComponent("index-test-\(UUID().uuidString).sqlite")
        let root = Store.dir.appendingPathComponent("index-root-\(UUID().uuidString)")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: indexFile.path + suffix) }
            try? FileManager.default.removeItem(at: root)
        }
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("web"), withIntermediateDirectories: true)
        guard let index = SkillIndex(at: indexFile) else { check(false, "index: opens"); return }
        check(index.hasFTS, "index: FTS5 is in this Mac's SQLite")
        let a = root.appendingPathComponent("web/a.example.md")
        try? "---\nscope: site\nmatch: a.example\n---\n# A site\n\n## Key facts\n- 2026-11-01 ×4 · The sidebar hides the zebra button.\n- 2026-11-01 · Something else entirely.\n".write(to: a, atomically: true, encoding: .utf8)
        index.update(roots: [(.learned, root)])
        check(index.search(["zebra"]).map(\.text) == ["2026-11-01 ×4 · The sidebar hides the zebra button."] && index.search(["zebra"]).first?.count == 4, "index: a word finds the fact that holds it")
        check(index.search(["nothing"]).isEmpty, "index: and nothing else")
        try? "---\nscope: site\nmatch: a.example\n---\n# A site\n\n## Key facts\n- 2026-11-01 · Now about the walrus door.\n".write(to: a, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: a.path)
        index.update(roots: [(.learned, root)])
        check(index.search(["zebra"]).isEmpty && index.search(["walrus"]).count == 1, "index: a changed file has its rows replaced")
        try? FileManager.default.removeItem(at: a)
        index.update(roots: [(.learned, root)])
        check(index.rowCount == 0, "index: a missing one is removed")
        // 100,000 facts in 2,000 files: building and lookup, compared with a walk on the way.
        for i in 0..<2000 {
            var lines = ""
            for j in 0..<50 { lines += "- 2026-11-01 · Fact \(j) of place \(i) about widget\(i)x\(j) and common words.\n" }
            try? "---\nscope: site\nmatch: p\(i).example\n---\n# P\(i)\n\n## Key facts\n\(lines)".write(to: root.appendingPathComponent("web/p\(i).example.md"), atomically: false, encoding: .utf8)
        }
        let builtAt = Date()
        index.rebuild(roots: [(.learned, root)])
        let built = Date().timeIntervalSince(builtAt)
        check(index.rowCount == 100_000, "index: all 100,000 facts are in (\(index.rowCount))")
        let lookupAt = Date()
        let found = index.search(["widget1234x42"])
        let looked = Date().timeIntervalSince(lookupAt)
        check(found.count == 1 && found.first?.path == "web/p1234.example.md", "index: finds one fact in 100,000")
        check(looked < 0.05, "index: a lookup stays quick at 100,000 facts (\(looked) s, built in \(built) s)")
        let again = Date()
        index.update(roots: [(.learned, root)])
        check(Date().timeIntervalSince(again) < 3, "index: nothing changed, so nothing is parsed (\(Date().timeIntervalSince(again)) s)")
        let wrongWord = index.search(["common"])
        check(wrongWord.count == 200, "index: at most the top 200 go on to the re-rank")
    }
}
