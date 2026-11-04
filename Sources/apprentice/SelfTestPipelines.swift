import Foundation

/// Checks for pipelines across agents. `pipelineRuns` is end to end: real processes, real git and fake agent CLIs that
/// do what their prompt's `RUN:` line says, so no tokens are spent and fallback, parking, worktrees and the board all
/// run for real.
extension SelfTest {
    static func helpBook() {
        let book = Help.parse((try? String(contentsOf: Help.file, encoding: .utf8)) ?? "")
        check(!book.entries.isEmpty && !book.about.isEmpty, "help: agent/commands.toml reads")
        let sources = Repo.shipped("Sources/apprentice")
        let spec = try? String(contentsOf: Repo.shipped("SPEC.md"), encoding: .utf8)
        let specTable = spec.flatMap { text -> String? in
            guard let at = text.range(of: "Exit codes (kept in sync") else { return nil }
            return String(text[at.lowerBound...].prefix(1800))
        }
        let docs = ["agent/SKILL.md", "agent/AGENTS.md"].compactMap { try? String(contentsOf: Repo.shipped($0), encoding: .utf8) }
        let problems = Help.problems(book, dispatched: Help.dispatched(sources: sources), spec: specTable, docs: docs)
        check(problems.isEmpty, "help: every command has an entry, every entry a command, examples parse, exit codes agree: \(problems.joined(separator: "; "))")
        check(Help.problems(Help.parse("[exit]\n0 = \"ok\"\n[command.\"x\"]\nusage = \"x\"\nsummary = \"s\"\nexample = \"apprentice y\"\nexits = [\"3: nope\"]\n"), dispatched: ["x", "z"], spec: nil, docs: []).count == 3,
              "help: a wrong example, an unknown exit and a command with no entry are all found")
        check(Help.overview(book).contains(book.about) && Help.overview(book).contains("board:"), "help: the overview opens with what apprentice is and lists commands")
        check(Help.mcpDescription("wait_for").contains("Wait") && Help.mcpDescription("playbooks").contains("playbooks"), "help: MCP tools read their descriptions from one file")
    }

    static func namedAgents() {
        let global = """
        [named.Joseph]
        agent = "claude"
        model = "m1"
        effort = "high"
        permissions = "edit"
        [named.Solo]
        agent = "codex"
        permissions = "read-only"
        [defaults]
        priority = ["Joseph", "Solo"]
        scribe = ["Solo"]
        """
        let project = """
        [named.joseph]
        effort = "max"
        [named.Reviewer]
        agent = "codex"
        permissions = "full"
        """
        let merged = NamedAgents.merge(global: global, project: project)
        let j = merged.first { $0.name == "Joseph" }
        check(j?.effort == "max" && j?.model == "m1" && j?.origin == .changedHere, "agents: a project entry changes only the fields it writes, ignoring case")
        check(merged.first { $0.name == "Reviewer" }?.origin == .project && merged.first { $0.name == "Solo" }?.origin == .global, "agents: origins are told apart")
        let clis = AgentCLIs.parse("""
        [agent.c]
        run = ["c", "-p", "{prompt}"]
        model = ["--model", "{model}"]
        effort = ["--effort", "{effort}"]
        permission_read_only = ["--ro"]
        permission_edit = ["--edit"]
        session = ["--sid", "{session}"]
        add_dir = ["--add", "{dir}"]
        ephemeral = ["--eph"]
        sealed = ["read-only"]
        """)
        let n = NamedAgents.Named(name: "N", agent: "c", model: "m", effort: "e", permissions: "edit")
        check(NamedAgents.argv(n, prompt: "hi", extras: .init(session: "s1", dir: URL(fileURLWithPath: "/d")), clis: clis)
                == ["c", "-p", "hi", "--model", "m", "--effort", "e", "--edit", "--sid", "s1", "--eph", "--add", "/d"], "agents: flags come from the CLI's spec")
        check(!NamedAgents.argv(n, prompt: "hi", extras: .init(dir: URL(fileURLWithPath: "/d"), permissions: "read-only"), clis: clis).contains("--add"), "agents: no extra folder for a sealed level")
        check(clis[0].levels == ["read-only", "edit"], "agents: only the levels a CLI can enforce are offered")
        check(!NamedAgents.problems(.init(name: "F", agent: "c", permissions: "full"), clis: clis).isEmpty, "agents: a level the CLI cannot enforce is named")
        check(NamedAgents.problems(.init(name: "U", agent: "nope"), clis: clis).first?.contains("no CLI") == true, "agents: an unknown CLI is named")
        check(NamedAgents.validName("deepseek_4_1_opencode_max") && !NamedAgents.validName("a b") && !NamedAgents.validName(""), "agents: names are letters, digits and _")

        let home = Store.dir.appendingPathComponent("agents-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try? FileManager.default.createDirectory(at: home.appendingPathComponent(".apprentice"), withIntermediateDirectories: true)
        let over = NamedAgents.Named(name: "Reviewer", agent: "codex", permissions: "full", origin: .project)
        check(NamedAgents.wants(over, project: home, globals: []) != nil, "agents: a project-only name above read-only needs the user's answer")
        check(NamedAgents.wants(.init(name: "Reviewer", agent: "codex", permissions: "read-only", origin: .project), project: home, globals: []) == nil, "agents: read-only under a project's own name does not")
        check(NamedAgents.wants(.init(name: "J", agent: "c", permissions: "edit", origin: .changedHere), project: home, globals: [.init(name: "J", agent: "c", permissions: "edit")]) == nil, "agents: the same as global needs no answer")
        NamedAgents.approve(over, project: home)
        check(NamedAgents.wants(over, project: home, globals: []) == nil, "agents: the answer is kept")
        var changed = over
        changed.permissions = "edit"
        check(NamedAgents.wants(changed, project: home, globals: []) != nil, "agents: asked again when the request changes")
    }

    static func pipelineGraph() {
        let text = """
        ---
        goal: Fix it
        interpreter: fast
        scribe: Joseph, Reviewer
        carry: summary
        visits: 4
        ---
        ## triage
        use: fast
        next: fix | reply
        Read the report.

        ## fix
        when: a real bug
        needs: edit
        next: code & tests & browser check
        Plan it.

        ## code
        next: release
        Write it.

        ## tests
        next: release
        Test it.

        ## browser check
        ui: true
        next: release
        Check it.

        ## release
        next: end
        Notes.

        ## reply
        next: end
        sh: echo hi
        """
        let p = Pipelines.parse(text)
        let g = PipelineGraph(p)
        check(Pipelines.parse("## a\nhi\n").agent.isEmpty && !Pipelines.render(Pipelines.parse("## a\nhi\n")).contains("agent:"), "pipelines: no agent: is written unless the file has one")
        check(p.goal == "Fix it" && p.interpreter == "fast" && p.scribes == ["Joseph", "Reviewer"] && p.carry && p.visits == 4, "pipelines: the new front matter is read")
        check(p.steps[0].use == "fast" && p.steps[0].next == "fix | reply" && p.steps[0].prompt == "Read the report.", "pipelines: settings at a step's top are not part of its prompt")
        check(p.steps[4].ui && p.steps[4].id == "browser-check" && p.steps[1].needs == "edit" && p.steps[1].when == "a real bug", "pipelines: step settings are read")
        check(p.steps[6].shell == "echo hi", "pipelines: sh: stays the step's text")
        let again = Pipelines.parse(Pipelines.render(p))
        check(again.steps == p.steps && again.goal == p.goal && again.scribes == p.scribes && again.carry && again.visits == 4, "pipelines: a graph round-trips")
        check(g.next("triage") == .choice(["fix", "reply"]) && g.next("fix") == .all(["code", "tests", "browser-check"]) && g.next("release") == .stop, "graph: next is read")
        check(PipelineGraph(Pipelines.parse("## a\none\n## b\ntwo\n")).next("a") == .one("b"), "graph: a blank next is the next heading")
        check(g.canReach("fix", "release") && !g.canReach("release", "fix") && !g.canReach("code", "tests"), "graph: reach follows every edge")
        let pairs = g.overlaps().map { Set([$0.0, $0.1]) }
        check(pairs.contains(Set(["code", "tests"])) && pairs.contains(Set(["tests", "browser-check"])) && !pairs.contains(Set(["code", "release"])), "graph: what can run at once")
        check(g.uiHolder(blocking: "code") == "browser-check" && g.uiHolder(blocking: "release") == nil && g.uiHolder(blocking: "browser-check") == nil, "graph: the UI tick is disabled only inside the group")
        let agents = [NamedAgents.Named(name: "fast", agent: "claude"), .init(name: "Joseph", agent: "claude", permissions: "edit"), .init(name: "Reviewer", agent: "claude")]
        func errors(_ text: String) -> [String] { PipelineGraph(Pipelines.parse(text)).check(agents: agents).errors }
        check(errors("## a\nuse: nobody\nhi\n").first?.contains("nobody") == true, "check: an unknown agent")
        check(errors("## a\nnext: b\nhi\n").first?.contains("b") == true, "check: an unknown step")
        check(errors("## a\nnext: end\nhi\n## b\nhi\n").first?.contains("nothing reaches b") == true, "check: a step nothing reaches")
        check(errors("## a\nuse: fast\nneeds: edit\nhi\n").first?.contains("needs edit") == true, "check: needs above the agent's permissions")
        check(errors("## a\nuse: Joseph\nneeds: edit\nhi\n").isEmpty, "check: needs within them")
        check(errors("## f\nnext: a & b\nhi\n## a\nui: true\nnext: j\nhi\n## b\nui: true\nnext: j\nhi\n## j\nhi\n").first?.contains("both have ui") == true, "check: two UI steps in one group")
        check(errors("## a\nui: true\nnext: b & c\nhi\n## b\nnext: d\nhi\n## c\nui: true\nnext: d\nhi\n## d\nui: true\nhi\n").isEmpty, "check: UI steps that never overlap are fine")
        check(errors("---\nvisits: 0\n---\n## a\nnext: b\nhi\n## b\nnext: a | c\nhi\n## c\nnext: end\nhi\n").contains { $0.contains("loop") }, "check: a loop with no limit")
        check(errors("## a\nnext: b | c & d\nhi\n## b\nhi\n## c\nhi\n## d\nhi\n").first?.contains("mixes") == true, "check: | and & mixed")
        check(errors("## a\nhi\n## A\nhi\n").first?.contains("two steps") == true, "check: two steps of one name")
        check(PipelineEngine.parseChoice("thinking…\n{\"next\": [\"fix\"], \"why\": \"a bug\"}\n")?.next == ["fix"], "interpreter: the answer is found at the end of what it printed")
        check(PipelineEngine.parseChoice("{\"a\": 1} then {\"next\": \"b\"}")?.next == ["b"] && PipelineEngine.parseChoice("no json") == nil, "interpreter: any object with next, or none")
        check(Pipelines.hasScreen(Pipelines.parse("## a\nhi\n").steps[0], in: Pipelines.parse("## a\nhi\n")), "screen: a file with no settings keeps it, one step at a time")
        check(!Pipelines.hasScreen(p.steps[2], in: p) && Pipelines.hasScreen(p.steps[4], in: p), "screen: a file with settings: only ui: true")
        check(AgentRun.limitEnds("try again at Nov 17th, 2099 1:16 PM.") != nil && AgentRun.limitEnds("nothing") == nil, "limits: a stated end is read")
        check(AgentRun.blockedLine("done\n`BLOCKED: write access to src`\n") == "write access to src" && AgentRun.blockedLine("all fine") == nil, "blocked: the agent's last-resort line")
        let cli = AgentCLIs.parse("[agent.j]\nrun = [\"j\"]\nsession_from = \"sessionID\"\ntext_from = \"part.text\"\nerror_from = \"error.data.message\"\n").first
        let line = AgentRun.decode(line: #"{"type":"text","sessionID":"s1","part":{"text":"ok"}}"#, cli: cli)
        check(line.text == "ok" && line.session == "s1", "agents: JSON output is decoded to its text and session")
        check(AgentRun.decode(line: #"{"error":{"data":{"message":"quota"}}}"#, cli: cli).text == "quota" && AgentRun.decode(line: #"{"type":"step_start"}"#, cli: cli).text == nil, "agents: errors are text, other events are not")
        check(AgentRun.escaped(URL(fileURLWithPath: "/usr/local/a.b")) == "-usr-local-a-b", "sessions: a folder escapes the way Claude Code names it")
        check(PipelineText.fill("restart", ["why": "{progress} stays", "progress": "P"]).contains("{progress} stays\nP"), "prompts: a value holding a placeholder is not filled again")
        check(Board.seconds("10m") == 600 && Board.seconds("90s") == 90 && Board.seconds("2h") == 7200 && Board.seconds("5") == 5, "board: durations")
    }

    static func projectFiles() {
        let folder = Store.dir.appendingPathComponent("files-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try? Projects.scaffold(folder, name: "Files", vm: nil, about: "what it is")
        func read(_ p: String) -> String { (try? String(contentsOf: folder.appendingPathComponent(p), encoding: .utf8)) ?? "" }
        let agents = read("AGENTS.md")
        check(agents.contains(ProjectFiles.startMark) && agents.contains("Running in a pipeline") && agents.contains("what it is"), "project: AGENTS.md has apprentice's section and the user's text")
        check(!read(".claude/skills/apprentice-pipeline/SKILL.md").isEmpty && !read(".agents/skills/apprentice-help/SKILL.md").isEmpty, "project: the built-in skills are in each CLI's folder")
        check(read(".claude/commands/pipeline-run.md").contains("apprentice pipeline run $ARGUMENTS"), "project: a slash command only runs its apprentice command")
        check(read(".gemini/commands/pipeline-run.toml").contains("{{args}}"), "project: Gemini's commands are in its own format")
        check(read(".apprentice/.gitignore").contains("cache/") && !read(".apprentice/worktree-links").isEmpty, "project: the cache is ignored and the links file is there")
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent(".apprentice/commands"), withIntermediateDirectories: true)
        try? "---\ndescription: Ship it\n---\nShip the release.\n".write(to: folder.appendingPathComponent(".apprentice/commands/ship.md"), atomically: true, encoding: .utf8)
        try? "# Our rules\n- Be kind.\n".write(to: folder.appendingPathComponent(".apprentice/skills-own.md"), atomically: true, encoding: .utf8)
        ProjectFiles.sync(folder)
        check(read(".claude/commands/ship.md").contains("Ship the release.") && read(".claude/commands/ship.md").contains("edit that one"), "project: the user's command is generated, and says where its original is")
        let path = ".claude/commands/ship.md"
        try? "mine\n".write(to: folder.appendingPathComponent(path), atomically: true, encoding: .utf8)
        check(ProjectFiles.edited(folder) == [path], "project: a generated copy changed by hand is noticed")
        let notes = ProjectFiles.sync(folder)
        check(read(path) == "mine\n" && notes.contains { $0.contains(path) }, "project: it is left alone, and the user told")
        ProjectFiles.sync(folder, keepMine: true)
        check(read(path) == "mine\n" && ProjectFiles.sync(folder).isEmpty, "project: keep mine stays quiet")
        ProjectFiles.sync(folder, takeNew: true)
        check(read(path).contains("Ship the release."), "project: take new overwrites")
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(".apprentice/commands/ship.md"))
        ProjectFiles.sync(folder)
        check(read(path).isEmpty, "project: a generated file whose original went goes too")
        // The section: the user's text around it stays, their edit of it is theirs until they choose.
        var text = read("AGENTS.md").replacingOccurrences(of: "## Running in a pipeline", with: "## My own heading")
        try? text.write(to: folder.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        check(ProjectFiles.edited(folder).contains("AGENTS.md") && ProjectFiles.sync(folder).contains { $0.contains("AGENTS.md") } && read("AGENTS.md").contains("My own heading"), "project: an edited section is kept until the user chooses")
        ProjectFiles.sync(folder, takeNew: true)
        check(read("AGENTS.md").contains("Running in a pipeline") && !read("AGENTS.md").contains("My own heading") && read("AGENTS.md").contains("what it is"), "project: taking apprentice's changes only its section")
        text = ""
        let own = folder.appendingPathComponent(".claude/commands/board.md")
        let leaky = Store.dir.appendingPathComponent("files-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: leaky) }
        try? FileManager.default.createDirectory(at: leaky.appendingPathComponent(".claude/commands"), withIntermediateDirectories: true)
        try? "my own board\n".write(to: leaky.appendingPathComponent(".claude/commands/board.md"), atomically: true, encoding: .utf8)
        try? Projects.scaffold(leaky, name: "Own", vm: nil, about: "")
        check((try? String(contentsOf: leaky.appendingPathComponent(".claude/commands/board.md"), encoding: .utf8)) == "my own board\n" && FileManager.default.fileExists(atPath: own.path), "project: a file of the user's own is never overwritten")
    }

    // MARK: - end to end

    private static let fakeAgent = """
    #!/bin/sh
    # A fake agent CLI: argv is <name> <prompt> [flags]. It does what the prompt's RUN: line says.
    who=$1; prompt=$2; shift 2
    while [ $# -gt 0 ]; do
      case "$1" in
        --sid) touch "$FAKE_DIR/sessions/$2.jsonl"; shift;;
        --level) printf '%s' "$2" > "$FAKE_DIR/level-$who"; shift;;
      esac
      shift
    done
    printf '%s' "$prompt" > "$FAKE_DIR/prompt-$who-${APPRENTICE_STEP:-none}"
    case "$prompt" in
      *"You are the scribe"*) echo "SCRIBE $who wrote this"; exit 0;;
      *"You choose the next step"*) cat "$FAKE_DIR/choice-$who" 2>/dev/null || cat "$FAKE_DIR/choice"; exit 0;;
    esac
    line=$(printf '%s\\n' "$prompt" | sed -n 's/^RUN-'"$who"': //p' | head -1)
    [ -n "$line" ] || line=$(printf '%s\\n' "$prompt" | sed -n 's/^RUN: //p' | head -1)
    eval "$line"
    """

    /// A throwaway project, and agent CLIs that all run `fake.sh`.
    private static func runProject() -> (folder: URL, fake: URL)? {
        let base = Store.dir.appendingPathComponent("runs-test")
        let fake = base.appendingPathComponent("fake")
        try? FileManager.default.createDirectory(at: fake.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let script = fake.appendingPathComponent("fake.sh")
        guard (try? fakeAgent.write(to: script, atomically: true, encoding: .utf8)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var clis = ""
        for name in ["one", "two", "three"] {
            clis += """
            [agent.\(name)]
            label = "\(name)"
            open = ""
            detect = []
            run = ["\(script.path)", "\(name)", "{prompt}"]
            session = ["--sid", "{session}"]
            transcript = "\(fake.path)/sessions/{session}.jsonl"
            permission_read_only = ["--level", "read-only"]
            permission_edit = ["--level", "edit"]
            permission_full = ["--level", "full"]
            limits = ["hit your usage limit"]
            refusals = ["refused by the sandbox"]

            """
        }
        try? clis.write(to: Settings.dir.appendingPathComponent("agents.toml"), atomically: true, encoding: .utf8)
        return (base, fake)
    }

    private static func newProject(_ name: String, under base: URL) -> URL {
        let folder = base.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: folder)
        try? Projects.scaffold(folder, name: name, vm: nil, about: "")
        _ = Repo.run("git", ["init", "-q"], in: folder)
        _ = Repo.run("git", ["add", "-A"], in: folder)
        _ = Repo.run("git", ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "start"], in: folder)
        return folder
    }

    private static func cli(_ args: [String], in folder: URL, fake: URL) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Wire.binaryPath())
        p.arguments = args
        p.currentDirectoryURL = folder
        var env = ProcessInfo.processInfo.environment
        env["APPRENTICE_HOME"] = Store.dir.path
        env["APPRENTICE_PIPELINE_SHELL"] = "plain"
        env["APPRENTICE_PIPELINE_NO_ASK"] = "1"
        env["FAKE_DIR"] = fake.path
        // No real agent CLI can be found from here, whatever a test gets wrong: this must never spend tokens.
        env["PATH"] = "/usr/bin:/bin"
        for key in ["APPRENTICE_RUN_DIR", "APPRENTICE_STEP", "APPRENTICE_STEP_OWNER", "APPRENTICE_STEP_SCREEN", "APPRENTICE_PROJECT", "APPRENTICE_VM"] { env[key] = nil }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (127, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func write(_ text: String, _ name: String, in folder: URL) {
        try? text.write(to: folder.appendingPathComponent("pipelines/\(name).md"), atomically: true, encoding: .utf8)
    }

    private static func waitFor(_ seconds: Double = 20, _ what: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if what() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    static func pipelineRuns() {
        guard let (base, fake) = runProject() else { check(false, "runs: could not set up"); return }
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: Settings.dir.appendingPathComponent("agents.toml"))
            try? FileManager.default.removeItem(at: Settings.dir.appendingPathComponent("named-agents.toml"))
            try? FileManager.default.removeItem(at: Store.dir.appendingPathComponent("agent-limits.json"))
        }
        func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        func state(_ folder: URL, _ n: Int) -> RunState? { Runs.load(Runs.root(project: folder).appendingPathComponent("\(n)")) }
        func node(_ folder: URL, _ n: Int, _ step: String, _ file: String) -> String {
            text(Runs.root(project: folder).appendingPathComponent("\(n)/nodes/\(step)/\(file)"))
        }
        try? """
        [named.A]
        agent = "one"
        permissions = "edit"
        [named.B]
        agent = "two"
        permissions = "edit"
        [named.C]
        agent = "three"
        permissions = "read-only"
        [defaults]
        scribe = ["C"]
        priority = ["A", "B"]
        interpreter = "C"
        """.write(to: NamedAgents.globalFile, atomically: true, encoding: .utf8)
        func sessions() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: fake.appendingPathComponent("sessions").path)) ?? [] }

        // A straight line: the scribe's summary goes forward, sessions go, the note is written apart.
        let line = newProject("line", under: base)
        write("---\ngoal: Say hello\n---\n## first\nuse: A\nRUN: echo found-a-thing; echo hi > made.txt\n\n## second\nuse: B\nRUN: echo second-done\n", "hello", in: line)
        var r = cli(["pipeline", "run", "hello"], in: line, fake: fake)
        check(r.code == 0 && r.out.contains("all 2 steps done"), "runs: a straight line runs (exit \(r.code)): \(r.out.suffix(300))")
        check(node(line, 1, "first", "output.log").contains("found-a-thing") && node(line, 1, "first", "summary.md").contains("SCRIBE three"), "runs: output and the scribe's summary are kept per step")
        check(text(fake.appendingPathComponent("prompt-two-second")).contains("SCRIBE three wrote this") && !text(fake.appendingPathComponent("prompt-two-second")).contains("found-a-thing"), "runs: the next prompt gets the summary, not the raw output")
        check(text(fake.appendingPathComponent("prompt-two-second")).contains("▶ second") && text(fake.appendingPathComponent("prompt-two-second")).contains("past runs, for reference only"), "runs: the prompt has the map and the order of trust")
        check(text(fake.appendingPathComponent("level-three")) == "read-only", "runs: the scribe runs read-only")
        check(FileManager.default.fileExists(atPath: line.appendingPathComponent("made.txt").path), "runs: a sequential step works in the project folder")
        check(sessions().isEmpty, "runs: the CLIs' sessions are removed when the step ends")
        let note = text(Runs.past(project: line, slug: "hello").appendingPathComponent("\(Store.day())-run-1.md"))
        check(note.contains("Recorded by apprentice") && note.contains("Written by the scribe") && note.contains("SCRIBE three") && note.contains("for reference only"), "runs: the past-run note keeps facts and the scribe's text apart")
        check(Repo.run("git", ["check-ignore", ".apprentice/cache/runs/1/state.json"], in: line).code == 0, "runs: the cache is gitignored")
        check(cli(["pipeline", "status", "1"], in: line, fake: fake).out.contains("Run 1: done"), "runs: status")

        // Fallback: out of usage, then a crash, then one that works, told what the last one did.
        let fall = newProject("fall", under: base)
        write("---\ngoal: g\n---\n## job\nuse: A\nRUN-one: echo You have hit your usage limit; exit 1\nRUN-two: exit 3\nRUN-three: echo took-over\n", "f", in: fall)
        try? """
        [defaults]
        priority = ["B", "T"]
        scribe = ["T"]
        [named.T]
        agent = "three"
        permissions = "edit"
        """.write(to: NamedAgents.projectFile(fall), atomically: true, encoding: .utf8)
        // The project-only agent above read-only asks once: answered ahead for this test.
        NamedAgents.approve(.init(name: "T", agent: "three", permissions: "edit", origin: .project), project: fall)
        r = cli(["pipeline", "run", "f"], in: fall, fake: fake)
        check(r.code == 0 && r.out.contains("took-over"), "runs: fallback goes down the list (exit \(r.code)): \(r.out.suffix(400))")
        check(text(fake.appendingPathComponent("prompt-three-job")).contains("You are taking over") && text(fake.appendingPathComponent("prompt-three-job")).contains("exit"), "runs: the next agent is told what the last one did")
        let tried = (try? JSONDecoder().decode(StepResult.self, from: Data(node(fall, 1, "job", "result.json").utf8)))?.tries ?? []
        check(tried.map(\.agent) == ["A", "B", "T"] && tried[0].limit != nil, "runs: result.json records every try")
        check(AgentLimits.holds("one") != nil, "runs: a CLI out of usage is skipped until its limit ends")
        r = cli(["pipeline", "run", "f"], in: fall, fake: fake)
        check((try? JSONDecoder().decode(StepResult.self, from: Data(node(fall, 2, "job", "result.json").utf8)))?.tries.first?.agent == "B", "runs: the next run skips it")
        AgentLimits.clear("one")

        // Stall: no output and no file change is a stall, and it falls back.
        let slow = newProject("slow", under: base)
        try? "[pipelines]\nstall_min = 0.02\n".write(to: slow.appendingPathComponent(".apprentice/config.toml"), atomically: true, encoding: .utf8)
        write("---\ngoal: g\n---\n## job\nuse: A\nRUN-one: sleep 30\nRUN-two: echo quick\n", "s", in: slow)
        let began = Date()
        r = cli(["pipeline", "run", "s"], in: slow, fake: fake)
        check(r.code == 0 && r.out.contains("quick") && Date().timeIntervalSince(began) < 15, "runs: a stalled agent is stopped and replaced")

        // Every agent fails: the run stops and says why, and a resume reruns only that step.
        let bad = newProject("bad", under: base)
        write("---\ngoal: g\n---\n## ok\nuse: A\nRUN: echo fine; date >> count.txt\n\n## broken\nuse: A\nRUN: test -f fixed && echo mended || exit 4\n", "b", in: bad)
        r = cli(["pipeline", "run", "b"], in: bad, fake: fake)
        check(r.code == 1 && r.out.contains("every agent failed") && state(bad, 1)?.status == "failed", "runs: all failing stops the run, with the reason (exit \(r.code))")
        check(text(Runs.past(project: bad, slug: "b").appendingPathComponent("\(Store.day())-run-1.md")).contains("failed"), "runs: a failed run's note says it failed")
        FileManager.default.createFile(atPath: bad.appendingPathComponent("fixed").path, contents: nil)
        r = cli(["pipeline", "resume", "1"], in: bad, fake: fake)
        check(r.code == 0 && r.out.contains("mended") && text(bad.appendingPathComponent("count.txt")).split(separator: "\n").count == 1, "runs: resume reruns only what failed (exit \(r.code))")

        // Routing: the interpreter chooses; a wrong answer is asked again, then the user decides.
        let route = newProject("route", under: base)
        write("---\ngoal: g\ninterpreter: C\n---\n## triage\nuse: A\nnext: fix | reply\nRUN: echo looked\n\n## fix\nuse: A\nwhen: a bug\nnext: end\nRUN: echo fixing\n\n## reply\nuse: A\nwhen: a question\nnext: end\nRUN: echo replying\n", "r", in: route)
        try? "here is my answer: {\"next\": [\"reply\"], \"why\": \"it asks\"}\n".write(to: fake.appendingPathComponent("choice"), atomically: true, encoding: .utf8)
        r = cli(["pipeline", "run", "r"], in: route, fake: fake)
        check(r.code == 0 && r.out.contains("replying") && !r.out.contains("fixing") && state(route, 1)?.path == ["triage", "reply"], "runs: the interpreter chooses a branch (exit \(r.code)): \(r.out.suffix(300))")
        try? "{\"next\": [\"nowhere\"]}\n".write(to: fake.appendingPathComponent("choice"), atomically: true, encoding: .utf8)
        r = cli(["pipeline", "run", "r"], in: route, fake: fake)
        check(r.code == 9 && state(route, 2)?.steps["triage"]?.question?.kind == "choice" && state(route, 2)?.steps["triage"]?.question?.choices.contains("fix") == true, "runs: an invalid answer ends with the user's buttons (exit \(r.code))")
        r = cli(["pipeline", "answer", "2", "triage", "fix"], in: route, fake: fake)
        check(waitFor { state(route, 2)?.status == "done" } && state(route, 2)?.path.contains("fix") == true, "runs: their choice carries the run on: \(r.out)")

        // A loop is limited.
        let loop = newProject("loop", under: base)
        write("---\ngoal: g\nvisits: 2\ninterpreter: C\n---\n## a\nuse: A\nnext: b\nRUN: echo a\n\n## b\nuse: A\nnext: a | c\nRUN: echo b\n\n## c\nuse: A\nnext: end\nRUN: echo c\n", "l", in: loop)
        try? "{\"next\": [\"a\"]}\n".write(to: fake.appendingPathComponent("choice"), atomically: true, encoding: .utf8)
        r = cli(["pipeline", "run", "l"], in: loop, fake: fake)
        check(r.code == 1 && r.out.contains("more than 2 times"), "runs: a loop stops at its limit (exit \(r.code))")

        // Parallel: worktrees, the board between them, the join gets it all, and the work lands in the folder.
        let par = newProject("par", under: base)
        try? "uncommitted\n".write(to: par.appendingPathComponent("wip.txt"), atomically: true, encoding: .utf8)
        try? "SECRET=1\n".write(to: par.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try? ".env\n".write(to: par.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        write("""
        ---
        goal: g
        ---
        ## plan
        use: A
        next: left & right
        RUN: echo planned

        ## left
        use: A
        next: join
        RUN: pwd > ../left-cwd; cat wip.txt > left.txt; cat .env >> left.txt; apprentice board post --to right "from left"; apprentice board wait --from right --for 20s

        ## right
        use: B
        next: join
        RUN: apprentice board wait --from left --for 20s > got.txt; apprentice board post --to left "from right"; apprentice board post --to join "for the join"; apprentice ask "nope" 2>/dev/null; apprentice read; echo read=$? >> got.txt; echo right > right.txt

        ## join
        use: A
        RUN: cat left.txt right.txt got.txt > joined.txt; apprentice board read > board-read.txt; echo joined
        """, "p", in: par)
        r = cli(["pipeline", "run", "p"], in: par, fake: fake)
        let pdir = Runs.root(project: par).appendingPathComponent("1")
        check(r.code == 0 && r.out.contains("joined"), "runs: parallel steps run and join (exit \(r.code)): \(r.out.suffix(600))")
        let joined = text(par.appendingPathComponent("joined.txt"))
        check(joined.contains("uncommitted"), "runs: a worktree holds the uncommitted work")
        check(joined.contains("SECRET=1"), "runs: ignored files in worktree-links are copied in")
        check(joined.contains("from left"), "runs: steps pass messages on the board")
        check(joined.contains("read=4"), "runs: a step without ui: true is refused the screen (\(joined))")
        check(text(fake.appendingPathComponent("prompt-one-join")).contains("for the join") && text(fake.appendingPathComponent("prompt-one-join")).contains("SCRIBE three"), "runs: the join gets the summaries and what is addressed to it")
        check(!text(fake.appendingPathComponent("prompt-one-join")).contains("from left"), "runs: not the whole board")
        check(text(fake.appendingPathComponent("prompt-one-left")).contains("`right`") && text(fake.appendingPathComponent("prompt-one-left")).contains("board post"), "runs: a parallel step is told who runs alongside and how to talk")
        check(text(par.appendingPathComponent("wip.txt")) == "uncommitted\n" && FileManager.default.fileExists(atPath: par.appendingPathComponent("right.txt").path), "runs: the merged work is in the folder, and the user's uncommitted file stays")
        check(Repo.run("git", ["diff", "--cached", "--name-only"], in: par).out.isEmpty && Repo.run("git", ["log", "--oneline"], in: par).out.split(separator: "\n").count == 1, "runs: nothing is committed to the user's branch")
        check(!text(par.appendingPathComponent("left-cwd")).contains("/par\n") && text(pdir.appendingPathComponent("worktrees/left-cwd")).contains("worktrees"), "runs: a parallel step works in its own worktree")
        check(Repo.run("git", ["worktree", "list"], in: par).out.split(separator: "\n").count == 1 && Repo.run("git", ["branch", "--list", "apprentice/*"], in: par).out.isEmpty, "runs: worktrees and branches go once merged")
        check(Board.messages(pdir).count >= 3, "runs: the whole board stays with the run")

        // A conflict at the join parks the run; resolving it carries on.
        let con = newProject("con", under: base)
        try? "base\n".write(to: con.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        write("---\ngoal: g\n---\n## fork\nuse: A\nnext: x & y\nRUN: echo fork\n\n## x\nuse: A\nnext: end2\nRUN: echo from-x > same.txt\n\n## y\nuse: A\nnext: end2\nRUN: echo from-y > same.txt\n\n## end2\nuse: A\nRUN: cat same.txt\n", "c", in: con)
        r = cli(["pipeline", "run", "c"], in: con, fake: fake)
        let question = state(con, 1)?.steps["end2"]?.question
        check(r.code == 9 && question?.kind == "conflict" && question?.text.contains("worktrees") == true, "runs: a conflict parks the run with where to resolve it (exit \(r.code))")
        let mergeDir = Runs.root(project: con).appendingPathComponent("1/worktrees/merge-fork-1")
        check(text(mergeDir.appendingPathComponent("same.txt")).contains("<<<<<<<"), "runs: the conflict is left in place")
        try? "resolved\n".write(to: mergeDir.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        _ = Repo.run("git", ["add", "-A"], in: mergeDir)
        _ = cli(["pipeline", "answer", "1", "end2", "I resolved it"], in: con, fake: fake)
        check(waitFor { state(con, 1)?.status == "done" } && text(con.appendingPathComponent("same.txt")) == "resolved\n", "runs: after resolving, the run carries on: \(state(con, 1)?.status ?? "?") \(state(con, 1)?.reason ?? "") \(text(Runs.root(project: con).appendingPathComponent("1/engine.log")).suffix(300))")

        // A question nobody answered in time parks the step; the answer restarts it with its progress.
        let ask = newProject("ask", under: base)
        write("---\ngoal: g\n---\n## q\nuse: A\nRUN: if grep -q 'Their answer: bl''ue' \"$FAKE_DIR/prompt-one-q\"; then echo got-blue; grep -c 'saved progress' \"$FAKE_DIR/prompt-one-q\"; else echo half done > \"$APPRENTICE_RUN_DIR/nodes/q/progress.md\"; echo '{\"kind\":\"question\",\"text\":\"Which colour?\",\"choices\":[],\"multi\":false}' > \"$APPRENTICE_RUN_DIR/nodes/q/question.json\"; fi\n", "a", in: ask)
        r = cli(["pipeline", "run", "a"], in: ask, fake: fake)
        check(r.code == 9 && r.out.contains("Which colour?") && state(ask, 1)?.steps["q"]?.status == "parked", "runs: an unanswered question parks the step (exit \(r.code))")
        _ = cli(["pipeline", "answer", "1", "q", "blue"], in: ask, fake: fake)
        check(waitFor { state(ask, 1)?.status == "done" } && node(ask, 1, "q", "output.log").contains("got-blue"), "runs: the answer restarts it with its progress and the answer")
        check(Board.messages(Runs.root(project: ask).appendingPathComponent("1")).contains { $0.text.contains("blue") }, "runs: the answer goes on the board too")

        // A permission block: apprentice words it, no fallback, and Allow raises the level for this run.
        let perm = newProject("perm", under: base)
        write("---\ngoal: g\n---\n## w\nuse: A\nRUN: if [ \"$(cat \"$FAKE_DIR/level-one\")\" = full ]; then echo wrote; else echo 'BLOCKED: write access everywhere'; fi\n", "w", in: perm)
        r = cli(["pipeline", "run", "w"], in: perm, fake: fake)
        let permQuestion = state(perm, 1)?.steps["w"]?.question
        check(r.code == 9 && permQuestion?.kind == "permission" && permQuestion?.choices.contains("Allow for this run") == true && permQuestion?.text.contains("write access") == false, "runs: a permission block parks with apprentice's own wording and no fallback (exit \(r.code))")
        check((try? JSONDecoder().decode(StepResult.self, from: Data(node(perm, 1, "w", "result.json").utf8)))?.tries.count == 1, "runs: no other agent was tried")
        _ = cli(["pipeline", "answer", "1", "w", "Allow for this run"], in: perm, fake: fake)
        check(waitFor { state(perm, 1)?.status == "done" } && node(perm, 1, "w", "output.log").contains("wrote"), "runs: Allow gives it the next level for this run")

        // A refusal the CLI prints is not an excuse to try wider agents either.
        let ref = newProject("ref", under: base)
        write("---\ngoal: g\n---\n## w\nuse: A\nRUN-one: echo refused by the sandbox; exit 1\nRUN-two: echo should-not-run\n", "w", in: ref)
        r = cli(["pipeline", "run", "w"], in: ref, fake: fake)
        check(r.code == 9 && !r.out.contains("should-not-run") && state(ref, 1)?.steps["w"]?.question?.kind == "permission", "runs: a refusal does not fall back (exit \(r.code))")

        // A UI step that already acted does not retry: it could send something twice.
        let ui = newProject("ui", under: base)
        write("---\ngoal: g\n---\n## click\nuse: A\nui: true\nRUN-one: touch \"$APPRENTICE_RUN_DIR/nodes/click/acted\"; exit 1\nRUN-two: echo second-agent-acted\n", "u", in: ui)
        r = cli(["pipeline", "run", "u"], in: ui, fake: fake)
        check(r.code == 9 && !r.out.contains("second-agent-acted") && state(ui, 1)?.steps["click"]?.question?.kind == "acted", "runs: a step that acted parks instead of retrying (exit \(r.code))")

        // First use: a project's agent asking for more parks with apprentice's question, kept outside the repo.
        let first = newProject("first", under: base)
        try? "[named.Mine]\nagent = \"one\"\npermissions = \"full\"\n".write(to: NamedAgents.projectFile(first), atomically: true, encoding: .utf8)
        write("---\ngoal: g\n---\n## s\nuse: Mine\nRUN: echo ran-with-full\n", "x", in: first)
        r = cli(["pipeline", "run", "x"], in: first, fake: fake)
        check(r.code == 9 && !r.out.contains("ran-with-full") && state(first, 1)?.steps["s"]?.question?.kind == "first-use", "runs: a project's agent asking for more asks first (exit \(r.code))")
        _ = cli(["pipeline", "answer", "1", "s", "Allow for this project"], in: first, fake: fake)
        check(waitFor { state(first, 1)?.status == "done" } && !text(NamedAgents.projectFile(first)).contains("allow"), "runs: the answer starts it, and is not kept in the repo")
        r = cli(["pipeline", "run", "x"], in: first, fake: fake)
        check(r.code == 0, "runs: and is not asked again")

        // Not started: a file that does not check, and an unknown CLI in a project's entry.
        let wrong = newProject("wrong", under: base)
        write("## a\nuse: nobody\nhi\n", "n", in: wrong)
        r = cli(["pipeline", "run", "n"], in: wrong, fake: fake)
        check(r.code == 5 && r.out.contains("nobody") && Runs.numbers(project: wrong).isEmpty, "runs: a file that does not check does not start")
        r = cli(["pipeline", "check", "n"], in: wrong, fake: fake)
        check(r.code == 5 && r.out.contains("nobody"), "check: names the problem")
        // The audit: spends nothing, writes the brief.
        r = cli(["pipeline", "audit", "n"], in: wrong, fake: fake)
        let brief = text(Runs.cache(project: wrong).appendingPathComponent("audit/n.md"))
        check(r.code == 0 && brief.contains("ERROR") && brief.contains("nobody") && r.out.contains("then review this pipeline with me"), "audit: the brief has the check's results")
        let audited = newProject("audited", under: base)
        write("---\ngoal: g\n---\n## s\nuse: A\nRUN: echo x\n", "z", in: audited)
        _ = cli(["pipeline", "run", "z"], in: audited, fake: fake)
        _ = cli(["pipeline", "audit", "z"], in: audited, fake: fake)
        let brief2 = text(Runs.cache(project: audited).appendingPathComponent("audit/z.md"))
        check(brief2.contains("Run 1: done") && brief2.contains("A · one") && brief2.contains("Passes."), "audit: who runs what, after inheritance, and the last run")

        // Carry: the rolling summary goes into the next run; Run fresh leaves it out; it can be capped.
        let carry = newProject("carry", under: base)
        write("---\ngoal: g\ncarry: summary\n---\n## s\nuse: A\nRUN: echo x\n", "m", in: carry)
        _ = cli(["pipeline", "run", "m"], in: carry, fake: fake)
        let memory = carry.appendingPathComponent("pipelines/m.memory.md")
        check(text(memory).contains("SCRIBE three"), "carry: the scribe writes the rolling summary")
        _ = cli(["pipeline", "run", "m"], in: carry, fake: fake)
        check(text(fake.appendingPathComponent("prompt-one-s")).contains("Background from earlier runs") && text(fake.appendingPathComponent("prompt-one-s")).contains("SCRIBE three") && state(carry, 2)?.memoryVersion != nil, "carry: the next run reads it as background, and records which version")
        _ = cli(["pipeline", "run", "m", "--fresh"], in: carry, fake: fake)
        check(!text(fake.appendingPathComponent("prompt-one-s")).contains("Background from earlier runs"), "carry: Run fresh ignores it")
        check(Pipelines.inFolder(carry).count == 1, "carry: the memory file is not listed as a pipeline")
        r = cli(["board", "summarise", "3"], in: carry, fake: fake)
        check(r.code == 0 && r.out.contains("SCRIBE three"), "carry: board summarise rewrites it")

        // Stop: a running run's steps are told to stop.
        let stop = newProject("stop", under: base)
        write("---\ngoal: g\n---\n## s\nuse: A\nRUN: sleep 30\n", "t", in: stop)
        let running = Process()
        running.executableURL = URL(fileURLWithPath: Wire.binaryPath())
        running.arguments = ["pipeline", "run", "t"]
        running.currentDirectoryURL = stop
        var env = ProcessInfo.processInfo.environment
        env["APPRENTICE_HOME"] = Store.dir.path; env["APPRENTICE_PIPELINE_SHELL"] = "plain"; env["FAKE_DIR"] = fake.path; env["PATH"] = "/usr/bin:/bin"
        running.environment = env
        running.standardOutput = FileHandle.nullDevice
        running.standardError = FileHandle.nullDevice
        try? running.run()
        check(waitFor { state(stop, 1)?.steps["s"]?.status == "running" }, "runs: a run shows as running")
        r = cli(["pipeline", "stop", "1"], in: stop, fake: fake)
        running.waitUntilExit()
        check(running.terminationStatus == 6 && state(stop, 1)?.status == "stopped", "runs: stop stops it (exit \(running.terminationStatus))")

        // Tidy: a session left behind is removed, nobody else's, and expired runs go while notes stay.
        let tidy = newProject("tidy", under: base)
        Projects.remember(Projects.Info(name: "tidy", folder: tidy, vm: nil))
        write("---\ngoal: g\n---\n## s\nuse: A\nRUN: echo x\n", "o", in: tidy)
        _ = cli(["pipeline", "run", "o"], in: tidy, fake: fake)
        let leftover = "leftover-session"
        let resultFile = Runs.root(project: tidy).appendingPathComponent("1/nodes/s/result.json")
        var left = (try? JSONDecoder().decode(StepResult.self, from: Data(contentsOf: resultFile))) ?? StepResult()
        left.tries[0].session = leftover
        left.tries[0].sessionRemoved = false
        try? Wire.json(left).write(to: resultFile, options: .atomic)
        FileManager.default.createFile(atPath: fake.appendingPathComponent("sessions/\(leftover).jsonl").path, contents: nil)
        FileManager.default.createFile(atPath: fake.appendingPathComponent("sessions/the-users-own.jsonl").path, contents: nil)
        let swept = Tidy.run()
        check(sessions() == ["the-users-own.jsonl"] && swept.contains("1 leftover"), "tidy: apprentice's own leftover goes, the user's stays: \(swept)")
        let future = Date().addingTimeInterval(31 * 86400)
        _ = Tidy.run(now: future)
        check(Runs.numbers(project: tidy).isEmpty && !CommandLine.arguments.isEmpty && FileManager.default.fileExists(atPath: Runs.past(project: tidy, slug: "o").appendingPathComponent("\(Store.day())-run-1.md").path), "tidy: expired runs go, notes stay")
        check(Tidy.report().contains("kept:"), "tidy: the report")
        let entries = Projects.entries().filter { $0.path != tidy.path }
        try? Wire.json(entries).write(to: Projects.listFile, options: .atomic)
    }
}
