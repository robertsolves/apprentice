import Foundation

/// `apprentice tour`: one pass through everything worth setting up, a step at a time. Each step is one
/// little window with choices (nothing in it needs typing), and every step can be skipped. It runs in the client:
/// the windows are `ask` requests to the daemon, and when they cannot show (the user is away, or
/// `ask_in = "terminal"`) the same choices are asked here in the terminal. It ends with what it set and
/// the command that changes each one later. Running it again is safe: it only sets what is chosen.
///
/// What it sets is saved as a named setup (`~/.apprentice/setups/<name>.json`, with a copy of `voice.md`),
/// so there can be several (work, personal, a client) and any one can be pulled up again or updated:
/// `tour [name]` runs it for that setup (starting from it when it exists), `tour list`, `tour use <name>`,
/// `tour show <name>`, `tour rm <name>`. The setup the tour ran for, or the one used last, is active.
enum Tour {
    struct Setup: Codable {
        var name: String
        /// "section.key" → the TOML value written to `config.toml`.
        var values: [String: String] = [:]
        var updated = Date()
    }

    static var dir: URL { Store.dir.appendingPathComponent("setups") }
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    static func url(_ name: String) -> URL { dir.appendingPathComponent(name + ".json") }
    static func voiceCopy(_ name: String) -> URL { dir.appendingPathComponent(name + ".voice.md") }
    static var activeURL: URL { dir.appendingPathComponent("active") }

    static var active: String? {
        (try? String(contentsOf: activeURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func load(_ name: String) -> Setup? {
        (try? Data(contentsOf: url(name))).flatMap { try? decoder.decode(Setup.self, from: $0) }
    }

    static func save(_ setup: Setup) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? encoder.encode(setup) { try? data.write(to: url(setup.name), options: .atomic) }
        // The voice goes with the setup: comments for a client need not sound like personal ones.
        try? FileManager.default.removeItem(at: voiceCopy(setup.name))
        try? FileManager.default.copyItem(at: Voice.url, to: voiceCopy(setup.name))
        try? setup.name.write(to: activeURL, atomically: true, encoding: .utf8)
    }

    static func validName(_ raw: String) throws -> String {
        let name = raw.lowercased()
        guard name.range(of: "^[a-z0-9][a-z0-9-]{0,29}$", options: .regularExpression) != nil else {
            throw Fail(5, "a setup name is letters, digits and dashes, like work or client-a")
        }
        return name
    }

    /// Writes a setup's settings and voice into place and makes it active. The active setup's current
    /// voice is kept in its own copy first, so switching never loses an answer.
    static func use(_ name: String) throws -> String {
        guard let setup = load(name) else { throw Fail(5, "no setup named \(name): `tour list` shows them, `tour \(name)` makes it") }
        if let current = active, current != name, var old = load(current) {
            old.updated = Date()
            save(old)
        }
        for (path, value) in setup.values.sorted(by: { $0.key < $1.key }) {
            let parts = path.split(separator: ".", maxSplits: 1).map(String.init)
            if parts.count == 2 { Config.remember(parts[0], parts[1], value) }
        }
        if FileManager.default.fileExists(atPath: voiceCopy(name).path) {
            try? FileManager.default.removeItem(at: Voice.url)
            try? FileManager.default.copyItem(at: voiceCopy(name), to: Voice.url)
        }
        try? name.write(to: activeURL, atomically: true, encoding: .utf8)
        Store.log(["setup": "use"])
        return "setup \(name): in use · " + describe(setup)
    }

    static func describe(_ s: Setup) -> String {
        s.values.isEmpty ? "no settings yet" : s.values.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator: " · ")
    }

    static func list() -> String {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
        guard !names.isEmpty else { return "setups: none yet · `apprentice tour` makes the first (`tour work` names it)" }
        return (["setups:"] + names.map { n in
            "\(n == active ? "*" : " ") \(n)" + (load(n).map { " · updated \(ISO8601DateFormatter().string(from: $0.updated).prefix(10))" } ?? "")
        } + ["`tour use <name>` pulls one up, `tour <name>` updates it"]).joined(separator: "\n")
    }

    /// `tour [name] | list | use <name> | show <name> | rm <name>`.
    static func command(_ a: Args) throws -> String {
        switch a.pos.first {
        case "list": return list()
        case "use": return try use(validName(a.pos.dropFirst().first ?? ""))
        case "show":
            let name = try validName(a.pos.dropFirst().first ?? active ?? "")
            guard let s = load(name) else { throw Fail(5, "no setup named \(name)") }
            return "setup \(name)\(name == active ? " (in use)" : "") · " + describe(s)
        case "rm":
            let name = try validName(a.pos.dropFirst().first ?? "")
            guard load(name) != nil else { throw Fail(5, "no setup named \(name)") }
            guard name != active else { throw Fail(5, "\(name) is in use: `tour use <another>` first") }
            try? FileManager.default.removeItem(at: url(name))
            try? FileManager.default.removeItem(at: voiceCopy(name))
            return "setup \(name): removed"
        default:
            let name = try validName(a.pos.first ?? active ?? "default")
            // Updating a setup starts from it: its settings and voice go into place first.
            if load(name) != nil, name != active { _ = try use(name) }
            return try run(name)
        }
    }

    static let skipRest = "Skip the rest"

    /// One choice from the user: the window, else the terminal, else nil (skipped or no terminal).
    static func choose(_ question: String, _ choices: [String], multi: Bool = false) -> [String]? {
        var args = [question, "--choices", choices.joined(separator: "|")]
        if multi { args.append("--multi") }
        if let r = try? Wire.send(Request(cmd: "ask", args: args)) {
            if r.code == 0, let line = r.out.split(separator: "\n").first(where: { $0.hasPrefix("user chose: ") }) {
                return line.dropFirst("user chose: ".count).components(separatedBy: "; ")
            }
            if r.code != 9 { return nil }
        }
        guard isatty(STDIN_FILENO) == 1 else { return nil }
        print("\n" + question)
        for (i, c) in choices.enumerated() { print("  \(i + 1). \(c)") }
        print(multi ? "numbers, comma separated (empty skips): " : "number (empty skips): ", terminator: "")
        fflush(stdout)
        guard let line = readLine(), !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let picked = line.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { (1...choices.count).contains($0) }.map { choices[$0 - 1] }
        return picked.isEmpty ? nil : picked
    }

    static func run(_ name: String) throws -> String {
        var done: [String] = []
        var setup = load(name) ?? Setup(name: name)
        /// Writes a setting now and keeps it in the setup.
        func set(_ section: String, _ key: String, _ value: String) {
            Config.remember(section, key, value)
            setup.values["\(section).\(key)"] = value
        }
        let steps = 8
        func step(_ n: Int, _ text: String) -> String { "Step \(n) of \(steps) · \(text)" }
        /// Asks, and stops the tour when the user picks "Skip the rest".
        func ask(_ n: Int, _ text: String, _ choices: [String], multi: Bool = false) -> [String]?? {
            guard let reply = choose(step(n, text), choices + (multi ? [] : [skipRest]), multi: multi) else { return .some(nil) }
            return reply == [skipRest] ? nil : .some(reply)
        }
        func finish() -> String {
            setup.updated = Date()
            save(setup)
            return (["tour: setup \(name) saved and in use"] + (done.isEmpty ? ["nothing changed"] : done.map { "· " + $0 })
                + ["`tour \(name)` updates it, `tour other-name` makes another, `tour list` and `tour use <name>` switch between them"]).joined(separator: "\n")
        }

        // 1. What this is.
        guard choose("Welcome to apprentice. It drives one app or browser window with the real cursor and keyboard, for your agent.\n\n⚠ \(Commands.riskWarning)\n\nSetting up: \(name)\(load(name) == nil ? " (new)" : " (updating it)"). This tour takes about two minutes, \(steps) short steps. Every step can be skipped.",
                     ["Start the tour", "Not now"]) == ["Start the tour"] else {
            return "tour: not now · `apprentice tour` when you want it"
        }

        // 2. Permissions.
        let missing = Doctor.checks().filter { !$0.ok && $0.blocking }
        if missing.isEmpty {
            done.append("permissions: all granted")
        } else {
            guard let reply = ask(2, "apprentice is missing: \(missing.map(\.line).joined(separator: ", ")). Without it, it cannot read or act on the screen.",
                                  ["Open System Settings to grant it", "Later"]) else { return finish() }
            if reply == ["Open System Settings to grant it"] {
                print((try? Doctor.run(Args.parse(["--fix"]))) ?? "run `apprentice doctor --fix` to grant them")
                done.append("permissions: opened System Settings (`apprentice doctor` checks them)")
            } else {
                done.append("permissions: still missing; `apprentice doctor --fix` when ready")
            }
        }

        // 3. Shell or screen.
        let terminal = "Terminal first: agents use shell commands where one does the job (faster)"
        let uiOnly = "UI only: everything through the screen, as you would by hand"
        guard let how = ask(3, "How should agents do things on this Mac?", Config.current.uiOnly ? [uiOnly, terminal] : [terminal, uiOnly]) else { return finish() }
        if let how {
            let on = how == [uiOnly]
            set("agent", "ui_only", on ? "true" : "false")
            done.append(on ? "agents: UI only (`[agent] ui_only`)" : "agents: terminal first (`[agent] ui_only = false`)")
        }

        // 4. Sleep.
        guard let awake = ask(4, "Keep the Mac awake while a task runs, so a long one is not cut off by sleep?",
                              ["Yes, while tasks run", "No"]) else { return finish() }
        if let awake {
            let on = awake == ["Yes, while tasks run"]
            set("agent", "keep_awake", on ? "true" : "false")
            done.append(on ? "keep awake: on while tasks run (`apprentice awake off`)" : "keep awake: off")
        }

        // 5. Phone.
        guard let phone = ask(5, "Get a push on your phone when apprentice needs you and you are away from the Mac?",
                              ["Set it up now (a QR code in the terminal)", "Not now"]) else { return finish() }
        if phone == ["Set it up now (a QR code in the terminal)"] {
            print((try? Notify.phone(Args.parse(["on"]), tty: isatty(STDOUT_FILENO) == 1)) ?? "run `apprentice phone on`")
            done.append("phone: set up (`apprentice phone test`, `phone off`)")
        }

        // 6. Typing.
        let sample = "Type a short sample now (about a minute)"
        let background = "Learn it in the background from my own typing"
        let never = "Don't learn it"
        guard let typing = ask(6, "apprentice types the way you do: your rhythm between keys and your slips. Only timings are kept, never the text, never in password fields.",
                               [background, sample, never]) else { return finish() }
        if let typing {
            set("typing", "learn", typing == [never] ? "false" : "true")
            if typing == [sample] {
                let r = try? Wire.send(Request(cmd: "typing", args: ["learn"]))
                done.append(r?.code == 0 ? "typing: sample recorded, and learning in the background" : "typing: no sample; learning in the background")
            } else {
                done.append(typing == [never] ? "typing: not learned (`[typing] learn`)" : "typing: learning in the background (`apprentice typing show`)")
            }
        }

        // 7. Voice and preferences.
        let now = "Answer a few now (one click each)"
        let later = "Ask me now and then (optional, never in the way)"
        let off = "Don't ask; let it assume"
        guard let voice = ask(7, "When apprentice writes a comment or reply for you, or picks an option on a site, it can learn your preferences. Questions are always choices, and unanswered ones fall back to a stated assumption.",
                              [now, later, off]) else { return finish() }
        if let voice {
            set("agent", "optional_questions", voice == [off] ? "false" : "true")
            if voice == [now] {
                var answered = 0
                for q in Voice.questions {
                    guard let reply = choose(q.text, q.choices, multi: q.multi) else { continue }
                    Voice.save(q.id, reply.isEmpty ? "none" : reply.joined(separator: ", "), assumed: false)
                    answered += 1
                }
                done.append("voice: \(answered) of \(Voice.questions.count) answered (`apprentice voice`; edit the top of \(Voice.url.path) in your own words)")
            } else {
                done.append(voice == [off] ? "optional questions: off (`[agent] optional_questions`)" : "optional questions: now and then, when apprentice is idle")
            }
        }

        // 8. What keeps it safe.
        _ = choose(step(8, "How you stay in charge:\n· anything that changes something is proposed first, and you or your agent approve it\n· payments, passwords and CAPTCHAs are always yours\n· your own key or click stops what apprentice is doing\n· ctrl+opt+cmd+. stops everything until you say carry on\n· per-site budgets and cooldowns keep it at a person's pace"),
                   ["Got it"])
        Store.log(["tour": done.count])
        return finish()
    }
}
