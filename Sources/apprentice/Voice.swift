import AppKit

/// `~/.apprentice/voice.md`: how the user wants posts, comments, replies and messages written in their
/// name, and what they prefer per site or tool. The top is theirs to write; the `## Answers` parts
/// apprentice keeps from short optional questions, everywhere and per scope (`## Answers · x.com`), with
/// what it assumed for any nobody answered. `pref` looks a preference up: the scope's own, else everywhere,
/// else other scopes, then an optional question, then the assumption. Only for writing to people: code,
/// commands, issues and docs follow the task. It stays in `~/.apprentice`, never in the repo or a
/// playbook, which are shared.
enum Voice {
    static let file = "voice.md"
    static var url: URL { Store.dir.appendingPathComponent(file) }

    /// One optional question: choices (radio buttons, or checkboxes with `multi`). Optional questions never
    /// need typing; an answer that does is critical, and goes to a real `ask --text`.
    struct Question {
        var id: String
        var text: String
        var choices: [String]
        var multi = false
        /// What is written, marked as assumed, while it is not answered.
        var assume: String
    }

    static let questions: [Question] = [
        Question(id: "tone", text: "When apprentice writes a comment or reply for you, how should it sound?",
                 choices: ["Warm and casual", "Short and to the point", "Professional", "Match the thread"], assume: "Match the thread"),
        Question(id: "length", text: "How long are your comments usually?",
                 choices: ["One line", "A few sentences", "Longer when it matters"], assume: "A few sentences"),
        Question(id: "emoji", text: "Emoji in what you post?", choices: ["Never", "Now and then", "Often"], assume: "Never"),
        Question(id: "style", text: "In casual replies, do you write…", choices: ["Proper sentences", "Relaxed, lowercase is fine"],
                 assume: "Proper sentences"),
        Question(id: "never", text: "Never in your name (tick any):",
                 choices: ["Hashtags", "Exclamation marks", "Self-promotion", "Buzzwords", "Over-apologising", "Asking for likes or follows"],
                 multi: true, assume: "Self-promotion, Asking for likes or follows"),
        Question(id: "language", text: "Which language do you comment in?", choices: ["English", "The thread's language"],
                 assume: "The thread's language"),
    ]

    static let template = """
        # Voice

        How I want posts, comments, replies and messages written in my name, and what I prefer on each
        site or tool. Only for writing to people and choosing for me: code, commands, issues and docs
        follow the task, not this file.

        ## In my own words

        (Optional. Tone, phrases I use, what I never say, anything per site.)

        ## Answers

        <!-- apprentice keeps the Answers parts: what I chose in its optional questions, everywhere and per
             site or tool (`## Answers · linkedin.com`), and what it assumed until I answer -->

        """

    // MARK: The file

    static func read() -> String? { try? String(contentsOf: url, encoding: .utf8) }

    static let assumedMark = "(assumed: not answered yet)"
    static let heading = "## Answers"

    /// The section a scope's answers live in: `## Answers` for everywhere, `## Answers · linkedin.com` for one.
    static func header(_ scope: String?) -> String { scope.map { "\(heading) · \($0)" } ?? heading }

    /// Every answer, by scope (nil for everywhere) and then id: the value and whether it is only assumed.
    static func all(_ text: String) -> [String?: [String: (value: String, assumed: Bool)]] {
        var out: [String?: [String: (value: String, assumed: Bool)]] = [:]
        var scope: String??
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                if line == heading { scope = .some(nil) }
                else if line.hasPrefix(heading + " · ") { scope = .some(String(line.dropFirst(heading.count + 3)).trimmingCharacters(in: .whitespaces)) }
                else { scope = nil }
                continue
            }
            guard let current = scope, line.hasPrefix("- ") else { continue }
            let body = line.dropFirst(2)
            guard let colon = body.firstIndex(of: ":") else { continue }
            let id = body[..<colon].trimmingCharacters(in: .whitespaces)
            var value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let assumed = value.hasSuffix(assumedMark)
            if assumed { value = String(value.dropLast(assumedMark.count)).trimmingCharacters(in: .whitespaces) }
            out[current, default: [:]][id] = (value, assumed)
        }
        return out
    }

    static func answers(_ text: String, _ scope: String? = nil) -> [String: (value: String, assumed: Bool)] { all(text)[scope] ?? [:] }

    /// `text` with one answer set in its scope's section (added at the end when missing); the rest untouched.
    static func setting(_ text: String, _ id: String, _ value: String, assumed: Bool, scope: String? = nil) -> String {
        let head = header(scope)
        var lines = text.components(separatedBy: "\n")
        if !lines.contains(head) {
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            lines += ["", head]
        }
        let line = "- \(id): \(value)" + (assumed ? " " + assumedMark : "")
        let start = lines.firstIndex(of: head)!
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.count
        if let i = lines[start..<end].firstIndex(where: { $0.hasPrefix("- \(id):") }) {
            lines[i] = line
        } else {
            // After the section's last line with text, so its answers stay together.
            let last = lines[start..<end].lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? start
            lines.insert(line, at: last + 1)
        }
        let out = lines.joined(separator: "\n")
        return out.hasSuffix("\n") ? out : out + "\n"
    }

    static func save(_ id: String, _ value: String, assumed: Bool, scope: String? = nil) {
        let text = setting(read() ?? template, id, value, assumed: assumed, scope: scope)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        Store.log(["voice": id, "assumed": assumed, "scoped": scope != nil])
    }

    /// Where an answer came from when there is none for the scope itself.
    enum Source: Equatable { case here, everywhere, elsewhere(String), guess }

    /// The answer for `id` in `scope`: the scope's own real answer; else the one for everywhere; else the
    /// one most other scopes chose; else nil. An assumed answer in the scope counts only when nothing real is found.
    static func resolve(_ text: String, _ id: String, scope: String?) -> (value: String, source: Source, assumedHere: Bool)? {
        let every = all(text)
        let here = every[scope]?[id]
        if let here, !here.assumed { return (here.value, .here, false) }
        if scope != nil, let e = every[nil]?[id], !e.assumed { return (e.value, .everywhere, here != nil) }
        let others = every.compactMap { key, v -> (String, String)? in
            guard let key, key != scope, let a = v[id], !a.assumed else { return nil }
            return (key, a.value)
        }
        let counts = Dictionary(grouping: others, by: \.1)
        if let top = counts.max(by: { $0.value.count < $1.value.count || ($0.value.count == $1.value.count && $0.key > $1.key) }) {
            return (top.key, .elsewhere(top.value.map(\.0).sorted().joined(separator: ", ")), here != nil)
        }
        if let here { return (here.value, .guess, true) }
        return nil
    }

    /// The line `session` prints, so agents read the file before writing for the user.
    static var sessionLine: String? {
        guard read() != nil else { return nil }
        return "voice: before writing a post, comment, reply or message for the user, read `apprentice voice` and write that way (not for code, commands or docs); for a preference, `apprentice pref <key> --choices \"A|B\"`"
    }

    /// The scope a preference is for when none is given: the session's site, else its app.
    static var currentScope: String? {
        guard let s = Session.stored else { return nil }
        if let host = s.url.flatMap({ URL(string: $0)?.host }) { return Site.domain(host) }
        return s.app.lowercased()
    }

    /// `voice [show | init | ask]`.
    static func command(_ a: Args) throws -> String {
        switch a.pos.first ?? "show" {
        case "show":
            guard let text = read() else {
                return "voice: none yet · apprentice asks a few optional questions now and then and writes \(url.path); `voice init` starts it now, `voice suggest` writes questions from what you use apprentice for, `voice ask` asks one now"
            }
            return text
        case "init":
            if read() == nil { try? template.write(to: url, atomically: true, encoding: .utf8) }
            for q in questions where answers(read() ?? "")[q.id] == nil { save(q.id, q.assume, assumed: true) }
            return "voice: \(url.path) · edit the top in your own words; the answers fill in as you answer the optional questions"
        case "ask":
            if let o = waiting(Store.load(Asked.self, askedFile) ?? Asked()) {
                let reply = OptionalAsk.wait(o.question, choices: o.choices, multi: o.multi, assume: o.assume, timeout: Config.current.optionalWaitSeconds)
                noteAsked(o.key, o.scope, question: o.question, choices: o.choices, multi: o.multi, assume: o.assume, answered: reply != nil)
                guard let reply else { return "voice: no answer; assumed \(o.key) = \(o.assume)" }
                let value = reply.isEmpty ? "none" : reply.joined(separator: ", ")
                save(o.key, value, assumed: false, scope: o.scope)
                return "voice: \(o.key) = \(value)"
            }
            guard let q = next(force: true) else { return "voice: every question is answered" }
            let reply = OptionalAsk.wait(q.text, choices: q.choices, multi: q.multi, assume: q.assume, timeout: Config.current.optionalWaitSeconds)
            record(q, reply)
            return reply.map { "voice: \(q.id) = \($0.joined(separator: ", "))" } ?? "voice: no answer; assumed \(q.id) = \(q.assume)"
        default:
            throw Fail(5, "voice [show | init | ask | suggest]")
        }
    }

    /// `pref <key> [--for site|app|task] [--choices "A|B|C" [--multi]] [--assume A] [--question "…"]`: what the
    /// user prefers here. Their answer for this site or tool if they gave one; else what they chose
    /// everywhere or elsewhere, as an assumption; then, with choices, an optional question with that
    /// assumption filled in. Unanswered, the assumption stands and is saved for this scope, marked
    /// assumed, to be asked again later. Exit 0 either way: an agent never waits on it for long.
    static func pref(_ a: Args) throws -> String {
        guard let key = a.pos.first?.lowercased(), key.range(of: "^[a-z0-9_.-]{1,40}$", options: .regularExpression) != nil else {
            throw Fail(5, "pref <key> [--for site|app|task] [--choices \"A|B|C\" [--multi]] [--assume A] [--question \"…\"]")
        }
        let scope = (a.value("for") ?? currentScope)?.lowercased()
        let label = scope ?? "everywhere"
        let choices = (a.value("choices") ?? "").split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let found = resolve(read() ?? "", key, scope: scope)
        if let found, found.source == .here { return "pref \(key) = \(found.value) · the user's choice for \(label)" }
        let guess = found?.value ?? a.value("assume") ?? choices.first
        let from: String
        switch found?.source {
        case .everywhere: from = "their choice everywhere"
        case .elsewhere(let where_): from = "their choice on \(where_)"
        case .guess: from = "assumed earlier"
        default: from = a.value("assume") != nil ? "your assumption" : "the first choice"
        }
        if !choices.isEmpty, shouldAsk(key, scope) {
            let question = a.value("question") ?? "Your preference for \(key.replacingOccurrences(of: "_", with: " ")) on \(label)?"
            let reply = OptionalAsk.wait(question, choices: choices, multi: a.has("multi"), assume: guess ?? choices[0],
                                      timeout: min(a.value("timeout").flatMap(Double.init) ?? Config.current.optionalWaitSeconds, 600))
            noteAsked(key, scope, question: question, choices: choices, multi: a.has("multi"), assume: guess ?? choices[0], answered: reply != nil)
            if let reply {
                let value = reply.isEmpty ? "none" : reply.joined(separator: ", ")
                save(key, value, assumed: false, scope: scope)
                return "pref \(key) = \(value) · the user just chose it for \(label); saved for next time"
            }
        }
        guard let guess else { return "pref \(key): nothing known for \(label) and no choices to ask; make your best guess and say so" }
        if found?.source != .guess { save(key, guess, assumed: true, scope: scope) }
        return "pref \(key) = \(guess) · assumed (\(from)) for \(label); the user did not answer, so carry on with it"
    }

    // MARK: Asking now and then

    /// How often each question was put to the user, and the scoped ones still assumed, so the idle
    /// timer can ask them again later. An ignored question is asked at most three times.
    struct Asked: Codable {
        var counts: [String: Int] = [:]
        var last: Date?
        var lastBy: [String: Date]?
        var open: [String: Open]?
        /// When the user's agent last wrote questions, and from which sites, apps, tasks and projects.
        var suggested: Date?
        var suggestedFrom: [String]?
    }
    struct Open: Codable { var key: String; var scope: String?; var question: String; var choices: [String]; var multi: Bool; var assume: String }
    static let askedFile = "voice-asked.json"

    static func slot(_ key: String, _ scope: String?) -> String { (scope ?? "*") + "|" + key }

    /// At most three times per key and scope, and not twice within 12 hours.
    static func shouldAsk(_ key: String, _ scope: String?) -> Bool {
        let asked = Store.load(Asked.self, askedFile) ?? Asked()
        let k = slot(key, scope)
        if asked.counts[k, default: 0] >= 3 { return false }
        return asked.lastBy?[k].map { Date().timeIntervalSince($0) > 12 * 3600 } ?? true
    }

    static func noteAsked(_ key: String, _ scope: String?, question: String, choices: [String], multi: Bool, assume: String, answered: Bool) {
        var asked = Store.load(Asked.self, askedFile) ?? Asked()
        let k = slot(key, scope)
        asked.counts[k, default: 0] += 1
        asked.lastBy = (asked.lastBy ?? [:]).merging([k: Date()]) { $1 }
        var open = asked.open ?? [:]
        open[k] = answered ? nil : Open(key: key, scope: scope, question: question, choices: choices, multi: multi, assume: assume)
        asked.open = open
        Store.save(asked, askedFile)
    }

    /// The next waiting question, in a steady order.
    static func waiting(_ asked: Asked) -> Open? {
        (asked.open ?? [:]).sorted { $0.key < $1.key }.first { shouldAsk($0.value.key, $0.value.scope) }?.value
    }

    /// The next built-in question with no real answer that has not been asked three times; any one when forced.
    static func next(force: Bool = false) -> Question? {
        let have = answers(read() ?? "")
        let asked = Store.load(Asked.self, askedFile) ?? Asked()
        return questions.first { q in
            have[q.id].map { $0.assumed } ?? true && (force || asked.counts[q.id, default: 0] < 3)
        }
    }

    static func record(_ q: Question, _ reply: [String]?) {
        var asked = Store.load(Asked.self, askedFile) ?? Asked()
        asked.counts[q.id, default: 0] += 1
        asked.last = Date()
        Store.save(asked, askedFile)
        if let reply {
            save(q.id, reply.isEmpty ? "none" : reply.joined(separator: ", "), assumed: false)
        } else if answers(read() ?? "")[q.id] == nil {
            save(q.id, q.assume, assumed: true)
        }
    }

    // MARK: Questions from what the user does

    /// What apprentice has been used for, from the logs: names only, never URLs, screen text or typed text.
    struct Usage {
        var sites: [String] = []
        var apps: [String] = []
        var tasks: [String] = []
        var projects: [String] = []

        var names: [String] { sites + apps + tasks + projects }
        var scopes: Set<String> { Set((sites + apps).map { $0.lowercased() }) }
        var text: String {
            [("Websites, most used first", sites), ("Apps, most used first", apps), ("Tasks they gave", tasks), ("Their projects", projects)]
                .filter { !$0.1.isEmpty }
                .map { "\($0.0): \($0.1.joined(separator: "; "))" }
                .joined(separator: "\n")
        }
    }

    static func usage(_ rows: [[String: Any]], projects: [String] = []) -> Usage {
        var sites: [String: Int] = [:], apps: [String: Int] = [:]
        var tasks: [String] = []
        for r in rows {
            if let h = (r["host"] as? String) ?? hostOf(r["url"] as? String), h.contains(".") { sites[Site.domain(h), default: 0] += 1 }
            if r["cmd"] as? String == "session", let a = r["app"] as? String, a.lowercased() != "apprentice" { apps[a, default: 0] += 1 }
            if let t = (r["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !tasks.contains(t) { tasks.append(t) }
        }
        func top(_ d: [String: Int], _ n: Int) -> [String] {
            d.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(n).map(\.key)
        }
        let oneLine = tasks.suffix(15).map { String($0.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(120)) }
        return Usage(sites: top(sites, 15), apps: top(apps, 10), tasks: oneLine, projects: projects)
    }

    /// The questions in an agent's reply worth asking: well formed, about the usage it was given, and not
    /// known yet. The reply is an LLM's, so nothing in it is trusted beyond being shown as a choice.
    static func suggestions(_ reply: String, usage: Usage, known: Set<String>, limit: Int = 5) -> [Open] {
        guard let from = reply.firstIndex(of: "["), let to = reply.lastIndex(of: "]"), from < to,
              let list = (try? JSONSerialization.jsonObject(with: Data(reply[from...to].utf8))) as? [[String: Any]] else { return [] }
        var seen = known
        var out: [Open] = []
        for q in list where out.count < limit {
            guard let key = (q["key"] as? String)?.lowercased(), key.range(of: "^[a-z0-9_.-]{1,40}$", options: .regularExpression) != nil,
                  !seen.contains(key), let question = q["question"] as? String, !question.isEmpty, question.count <= 200, !question.contains("\n"),
                  let choices = q["choices"] as? [String], (2...5).contains(choices.count),
                  choices.allSatisfy({ !$0.isEmpty && $0.count <= 60 && !$0.contains("\n") }), Set(choices).count == choices.count else { continue }
            let scope = (q["scope"] as? String)?.lowercased()
            if let scope, !usage.scopes.contains(scope) { continue }
            let assume = q["assume"] as? String
            seen.insert(key)
            out.append(Open(key: key, scope: scope, question: question, choices: choices, multi: q["multi"] as? Bool ?? false,
                            assume: assume.flatMap { choices.contains($0) ? $0 : nil } ?? choices[0]))
        }
        return out
    }

    /// The keys with a real answer, or a question still waiting, which a new question must not repeat.
    static func knownKeys(_ text: String, _ asked: Asked) -> Set<String> {
        let real = all(text).values.flatMap { $0.filter { !$0.value.assumed }.keys }
        return Set(real).union((asked.open ?? [:]).values.map(\.key))
    }

    /// The real answers an agent should use here: this scope's, then those for everywhere.
    static func knownLine(_ text: String, scope: String?) -> String? {
        let every = all(text)
        var answers = (every[nil] ?? [:]).filter { !$0.value.assumed }
        if let scope { answers.merge((every[scope] ?? [:]).filter { !$0.value.assumed }) { $1 } }
        guard !answers.isEmpty else { return nil }
        return "prefs (the user's answers, use them): " + answers.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value.value)" }.joined(separator: "; ")
    }

    /// One prompt to an installed agent; its reply, or nil when none ran or it took over three minutes.
    private static func askAgent(_ prompt: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "exec \"$@\"", "zsh"] + Schedules.agentArgv(AgentCLIs.runnable(), prompt)
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// Asks the user's own agent for questions about what apprentice has been used for, and queues them for
    /// the idle timer. Blocks while the agent answers. Sends names of sites, apps, tasks and projects only.
    @discardableResult
    static func suggest() -> [Open] {
        var projects = Projects.all().filter { !$0.isGeneral }.map(\.name)
        projects = Array(projects.prefix(10))
        let use = usage(Sessions.folders().flatMap(Sessions.rows), projects: projects)
        var asked = Store.load(Asked.self, askedFile) ?? Asked()
        asked.suggested = Date()
        asked.suggestedFrom = use.names
        Store.save(asked, askedFile)
        let file = Repo.resources.appendingPathComponent("agent/preference-questions.md")
        guard !use.names.isEmpty, let template = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let text = read() ?? ""
        let knownNow = knownKeys(text, asked)
        let prompt = template.replacingOccurrences(of: "{known}", with: knownNow.isEmpty ? "(none)" : knownNow.sorted().joined(separator: ", "))
            .replacingOccurrences(of: "{count}", with: "5")
            .replacingOccurrences(of: "{usage}", with: use.text)
        guard let reply = askAgent(prompt) else { return [] }
        let found = suggestions(reply, usage: use, known: knownNow)
        // Read again: a question may have been answered while the agent thought.
        var latest = Store.load(Asked.self, askedFile) ?? asked
        var open = latest.open ?? [:]
        for q in found where open[slot(q.key, q.scope)] == nil { open[slot(q.key, q.scope)] = q }
        latest.open = open
        Store.save(latest, askedFile)
        Store.log(["voice_suggested": found.count, "sites": use.sites.count, "apps": use.apps.count])
        return found
    }

    /// `voice suggest`: the same, now, printing what it queued.
    static func suggestNow() -> String {
        let found = suggest()
        guard !found.isEmpty else { return "voice: no new questions" }
        return (["voice: \(found.count) new question\(found.count == 1 ? "" : "s"), asked when apprentice is idle (`voice ask` asks one now):"]
            + found.map { "- \($0.scope.map { "[\($0)] " } ?? "")\($0.question) (\($0.choices.joined(separator: " | ")))" }).joined(separator: "\n")
    }

    private static var suggesting = false

    /// Whether the agent may be asked again: not within `optional_suggest_h`, and only for something new.
    private static func suggestInBackground(_ asked: Asked, every hours: Double) {
        guard !suggesting, asked.suggested.map({ Date().timeIntervalSince($0) > hours * 3600 }) ?? true else { return }
        suggesting = true
        DispatchQueue.global(qos: .utility).async {
            let use = usage(Sessions.folders().flatMap(Sessions.rows), projects: Projects.all().filter { !$0.isGeneral }.map(\.name))
            if !Set(use.names).isSubset(of: Set(asked.suggestedFrom ?? [])) { suggest() }
            DispatchQueue.main.async { suggesting = false }
        }
    }

    /// Every minute: when apprentice has been idle for two minutes, nothing is waiting on the user and
    /// the last optional question is `[agent] optional_every_h` old, it asks one waiting question: a site's
    /// preference still only assumed, or one the user's agent wrote from what apprentice is used for
    /// (`suggest`, when none is waiting). Main daemon only.
    static func install() {
        guard Store.vmName == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            let c = Config.current
            guard c.optionalQuestions, !Ask.away, !OptionalAsk.showing, !Borrow.active, Approvals.all.isEmpty,
                  Date().timeIntervalSince(Commands.lastAt) > 120 else { return }
            var asked = Store.load(Asked.self, askedFile) ?? Asked()
            if let last = asked.last, Date().timeIntervalSince(last) < c.optionalEveryHours * 3600 { return }
            guard let o = waiting(asked) else { return suggestInBackground(asked, every: c.optionalSuggestHours) }
            asked.last = Date()
            Store.save(asked, askedFile)
            OptionalAsk.present(o.question, choices: o.choices, multi: o.multi, assume: o.assume, timeout: c.optionalWaitSeconds) { reply in
                noteAsked(o.key, o.scope, question: o.question, choices: o.choices, multi: o.multi, assume: o.assume, answered: reply != nil)
                if let reply { save(o.key, reply.isEmpty ? "none" : reply.joined(separator: ", "), assumed: false, scope: o.scope) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}

/// A question the user may answer or leave: a small window that never takes focus from what they are
/// doing, with radio buttons (one click answers) or checkboxes (and Save). After `timeout` it closes and
/// the caller carries on with its assumption. Off with `[agent] optional_questions = false`, and skipped
/// while the user is away.
enum OptionalAsk {
    static var showing = false
    private static var panel: NSPanel?
    private static var handler: Handler?

    /// For a command: waits up to `timeout` for the answer, off the main thread. Nil when nobody answered.
    static func wait(_ question: String, choices: [String], multi: Bool, assume: String, timeout: Double) -> [String]? {
        guard Config.current.optionalQuestions, !Ask.away, !choices.isEmpty else { return nil }
        let done = DispatchSemaphore(value: 0)
        var reply: [String]?
        DispatchQueue.main.async {
            present(question, choices: choices, multi: multi, assume: assume, timeout: timeout) { reply = $0; done.signal() }
        }
        _ = done.wait(timeout: .now() + timeout + 5)
        return reply
    }

    /// `ask --optional "question" --choices "A|B" [--multi] [--assume A] [--timeout 60]`: returns at once
    /// with the answer, or after the timeout with the assumption, exit 0 either way. Never goes to the chat.
    static func ask(_ a: Args) throws -> String {
        let question = a.pos.joined(separator: " ")
        let choices = (a.value("choices") ?? "").split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !question.isEmpty, !choices.isEmpty else {
            throw Fail(5, "ask --optional \"question\" --choices \"A|B|C\" [--multi] [--assume A] [--timeout 60]: optional questions are choices; when the answer needs typing it is critical, so use `ask \"question\" --text` (it waits for the user)")
        }
        let assume = a.value("assume") ?? choices[0]
        let timeout = min(a.value("timeout").flatMap(Double.init) ?? Config.current.optionalWaitSeconds, 600)
        Store.log(["ask_optional": question])
        if let reply = wait(question, choices: choices, multi: a.has("multi"), assume: assume, timeout: timeout) {
            return "user chose: " + (reply.isEmpty ? "none of them" : reply.joined(separator: "; "))
        }
        let why = !Config.current.optionalQuestions ? "optional questions are off" : Ask.away ? "the user is away" : "no answer in \(Int(timeout)) s"
        return "\(why): carry on assuming \(assume)"
    }

    /// On the main thread. `done` gets the choices, or nil when skipped or timed out.
    static func present(_ question: String, choices: [String], multi: Bool, assume: String, timeout: Double,
                        done: @escaping ([String]?) -> Void) {
        guard !showing else { return done(nil) }
        showing = true
        let width: CGFloat = 400
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 160),
                        styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        p.title = "apprentice · optional"
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        Ask.blue(p)

        let h = Handler()
        h.finish = { reply in
            p.orderOut(nil)
            panel = nil
            handler = nil
            showing = false
            done(reply)
        }
        let label = NSTextField(wrappingLabelWithString: question)
        label.preferredMaxLayoutWidth = width - 48 - 56
        let note = NSTextField(wrappingLabelWithString: "Optional. Closes in \(Int(timeout)) s and assumes: \(assume)")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        var rows: [NSView] = [Ask.header(label)]
        let boxes: [NSButton] = choices.map { c in
            multi ? NSButton(checkboxWithTitle: c, target: nil, action: nil)
                  : NSButton(radioButtonWithTitle: c, target: h, action: #selector(Handler.picked(_:)))
        }
        rows += boxes
        let skip = NSButton(title: "Skip", target: h, action: #selector(Handler.skip))
        var buttons: [NSView] = [note, NSView(), skip]
        if multi {
            h.boxes = boxes
            buttons.append(NSButton(title: "Save", target: h, action: #selector(Handler.save)))
        }
        let row = NSStackView(views: buttons)
        row.spacing = 10
        rows.append(row)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        row.widthAnchor.constraint(equalToConstant: width - 48).isActive = true
        p.contentView = stack
        p.setContentSize(stack.fittingSize)
        Ask.place(p)
        // In front, but not key and not activating: the user's typing stays where it was.
        p.orderFrontRegardless()
        panel = p
        handler = h
        Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
            if handler === h { h.finish?(nil) }
        }
    }

    private final class Handler: NSObject {
        var finish: (([String]?) -> Void)?
        var boxes: [NSButton] = []
        @objc func picked(_ sender: NSButton) { finish?([sender.title]) }
        @objc func save() { finish?(boxes.filter { $0.state == .on }.map(\.title)) }
        @objc func skip() { finish?(nil) }
    }
}
