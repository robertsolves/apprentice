import Foundation

/// A project is one piece of work the user starts in the window or with `project new`: a folder on this
/// Mac with its own notes for agents, its pipelines and, if it has one, its VM. The folder is the project:
/// open it in any agent and it knows (its `AGENTS.md`, and `CLAUDE.md` and `GEMINI.md`, say so), save it with git, put it on
/// GitHub, clone it back on another Mac. apprentice only keeps a list of where the folders are
/// (`projects.json`); forgetting one never deletes it.
///
/// Inside a project folder:
///   .apprentice/project.toml   name and VM (the site counts and caps of `Project` live beside it)
///   .apprentice/commands.txt   commands a click types into its terminal
///   .apprentice/skills/        skills for this project only, shown before anyone else's (`Skills`)
///   AGENTS.md                  what an agent needs to know; CLAUDE.md and GEMINI.md point at it
///   pipelines/                 the project's pipelines (`Pipelines`)
enum Projects {
    struct Entry: Codable, Equatable {
        var name: String
        /// Saved as `~/…` under the home folder, so the list reads the same on another Mac.
        var path: String
        /// The repo `Sync` sends it to (`https://github.com/<login>/<slug>.git`), so a new Mac can clone it.
        var remote: String?
    }

    struct Info {
        var name: String
        var folder: URL
        var vm: String?

        /// The git remote the project saves to, if any (a git call: not for every command).
        var remote: String? {
            let r = Repo.run("git", ["remote", "get-url", "origin"], in: folder)
            return r.code == 0 && !r.out.isEmpty ? r.out : nil
        }

        var slug: String { Playbooks.slugify(name) }
    }

    static var listFile: URL { Store.dir.appendingPathComponent("projects.json") }
    /// Where new projects go unless the user picks another folder.
    static var defaultRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Apprentice") }

    /// True for the notes of General, the catch-all project older versions made. A project the user
    /// named General themselves has other notes.
    static func wasGeneral(notes: String) -> Bool {
        notes.contains("Anything that is not part of another project yet: quick questions, a shell, trying something out.")
    }

    /// Takes the old General off the list. Like any forgotten project, its folder and repository stay.
    static func retireGeneral() {
        let folder = defaultRoot.appendingPathComponent("general")
        guard entries().contains(where: { $0.path == folder.path }),
              let notes = try? String(contentsOf: folder.appendingPathComponent("AGENTS.md"), encoding: .utf8),
              wasGeneral(notes: notes) else { return }
        saveEntries(entries().filter { $0.path != folder.path })
    }

    /// The order the window lists projects in: by name.
    static func ordered(_ list: [Info]) -> [Info] {
        list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - the list

    static func entries() -> [Entry] {
        let list = (try? Data(contentsOf: listFile)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        return list.map { var e = $0; e.path = (e.path as NSString).expandingTildeInPath; return e }
    }

    private static func saveEntries(_ list: [Entry]) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let saved = list.map { e -> Entry in
            var e = e
            if e.path == home || e.path.hasPrefix(home + "/") { e.path = "~" + e.path.dropFirst(home.count) }
            return e
        }
        try? Wire.json(saved).write(to: listFile, options: .atomic)
    }

    /// Records where a project's folder is sent, once it is.
    static func setRemote(_ folder: URL, _ remote: String) {
        var list = entries()
        guard let i = list.firstIndex(where: { $0.path == folder.path }), list[i].remote != remote else { return }
        list[i].remote = remote
        saveEntries(list)
    }

    /// Every listed project whose folder is still there, read from its own settings.
    static func all() -> [Info] {
        entries().compactMap { info(URL(fileURLWithPath: $0.path)) }
    }

    static func info(_ folder: URL) -> Info? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        let v = Toml.load(settingsFile(folder))["project"] ?? [:]
        func text(_ key: String) -> String? { v[key].map(Toml.unquote).flatMap { $0.isEmpty ? nil : $0 } }
        // The VM as its daemon names itself (`Store.cleanVM`): a hand-written "Shop" matches the VM shop, and a
        // project.toml from someone else's repository cannot put shell syntax into the window's commands.
        return Info(name: text("name") ?? folder.lastPathComponent, folder: folder, vm: text("vm").flatMap(Store.cleanVM))
    }

    static func settingsFile(_ folder: URL) -> URL { folder.appendingPathComponent(".apprentice/project.toml") }

    /// The project with this name or slug, or the one whose folder holds `cwd`.
    static func find(_ name: String?) -> Info? {
        if let name, !name.isEmpty {
            let key = name.lowercased()
            return all().first { $0.name.lowercased() == key || $0.slug == Playbooks.slugify(name) }
                ?? (name.contains("/") ? info(URL(fileURLWithPath: (name as NSString).expandingTildeInPath)) : nil)
        }
        return here()
    }

    /// The project folder the caller is in: the nearest folder above it with `.apprentice/project.toml`.
    static func here(from start: String = FileManager.default.currentDirectoryPath) -> Info? {
        guard let dot = Project.find(from: start) else { return nil }
        let folder = dot.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: settingsFile(folder).path) else { return nil }
        return info(folder)
    }

    static func remember(_ p: Info) {
        var list = entries()
        let remote = list.first { $0.path == p.folder.path }?.remote
        list.removeAll { $0.path == p.folder.path }
        list.append(Entry(name: p.name, path: p.folder.path, remote: remote))
        saveEntries(list)
    }

    // MARK: - making one

    /// Writes the project's settings and agent notes into `folder`, keeping any the folder already has.
    static func scaffold(_ folder: URL, name: String, vm: String?, about: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder.appendingPathComponent(".apprentice"), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appendingPathComponent("pipelines"), withIntermediateDirectories: true)
        let settings = settingsFile(folder)
        var lines = ["# This folder is an apprentice project. `apprentice project` reads this file.", "[project]",
                     "name = \(quote(name))"]
        if let vm { lines.append("vm = \(quote(vm))") }
        // A cloned project keeps the name it was saved with (`new` then sets its VM: this Mac's choice).
        if !fm.fileExists(atPath: settings.path) { try (lines.joined(separator: "\n") + "\n").write(to: settings, atomically: true, encoding: .utf8) }
        // The counts are this Mac's; everything else in the project travels with it.
        let ignore = folder.appendingPathComponent(".apprentice/.gitignore")
        if !fm.fileExists(atPath: ignore.path) { try "limits.json\nlimits.json.lock\n".write(to: ignore, atomically: true, encoding: .utf8) }
        let commands = commandsFile(folder)
        if !fm.fileExists(atPath: commands.path) { try commandsTemplate.write(to: commands, atomically: true, encoding: .utf8) }
        let agents = folder.appendingPathComponent("AGENTS.md")
        if !fm.fileExists(atPath: agents.path) {
            try notes(name: name, vm: vm, about: about).write(to: agents, atomically: true, encoding: .utf8)
        }
        // Codex, opencode and Kilo read AGENTS.md; Claude Code and Gemini CLI read their own file, which imports it.
        for own in ["CLAUDE.md", "GEMINI.md"] {
            let file = folder.appendingPathComponent(own)
            if !fm.fileExists(atPath: file.path) { try "@AGENTS.md\n".write(to: file, atomically: true, encoding: .utf8) }
        }
    }

    /// The project's commands: one a line, each a button above its terminal that types the line and presses Return,
    /// so they work in any agent or a plain shell, and travel with the folder.
    static func commandsFile(_ folder: URL) -> URL { folder.appendingPathComponent(".apprentice/commands.txt") }

    static let commandsTemplate = """
        # This project's commands. Each line is a button above its terminal: a click types the line
        # into the tab and presses Return, for whatever is running there. Lines starting with # are skipped.
        #
        # /review
        # npm test

        """

    /// The lines that become buttons. A button shows exactly what it types, so a line holding control
    /// characters, which could hide or do more than it shows, is left out, as is one too long to read.
    static func commands(_ text: String) -> [String] {
        var out: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), line.count <= 200, !out.contains(line),
                  !line.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { continue }
            out.append(line)
        }
        return out
    }

    static func commands(in folder: URL) -> [String] {
        commands((try? String(contentsOf: commandsFile(folder), encoding: .utf8)) ?? "")
    }

    /// What any agent opened in the folder reads first.
    static func notes(name: String, vm: String?, about: String) -> String {
        let place = vm.map { "Websites and Linux apps for this project run in the VM `\($0)`: `APPRENTICE_VM=\($0)` is set in its tabs, and `apprentice --vm \($0) …` reaches it from anywhere." }
            ?? "It runs on this Mac (no VM)."
        let aboutText = about.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        # \(name)

        This folder is an apprentice project. Use apprentice (`apprentice session`, `apprentice --help`) for anything \
        that must happen on screen, and the shell for everything else.

        - \(place)
        - This project's work runs as pipelines (prompts that run one after another), kept in `pipelines/`; one with \
        a single step is a simple task: `apprentice pipeline task "what to do"`, `apprentice pipeline list`, \
        `apprentice pipeline run <name>`.
        - Keep files for this work in this folder. `apprentice project save` commits them.
        - Skills for this project only go in `.apprentice/skills/` (Markdown, same format as apprentice's \
        playbooks); `apprentice session` shows the ones that match, before anyone else's.

        ## About this project

        \(aboutText.isEmpty ? "(What this project is for, in the user's words.)" : aboutText)

        """
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A folder name from what the user called the project.
    static func folderName(_ name: String) -> String {
        let slug = Playbooks.slugify(name)
        return slug.isEmpty ? "project" : slug
    }

    // MARK: - CLI

    static let usage = "project new <name> [--dir <folder>] [--from <git url>] [--vm <name> | --no-vm] [--about \"…\"] · list · open [name] · set [name] [--vm <name> | --no-vm] [--name \"…\"] · save [name] [--message \"…\"] [--push] · add <folder> · forget <name> · init · status"

    static func command(_ a: Args) throws -> String {
        switch a.pos.first ?? "status" {
        case "new": return try new(a)
        case "list": return list()
        case "open", "path":
            guard let p = find(a.pos.dropFirst().first) else { throw Fail(5, "no such project · apprentice project list") }
            return "\(p.folder.path)\ncd \(VM.shellQuoted(p.folder.path))" + (p.vm.map { " && export APPRENTICE_VM=\($0)" } ?? "")
        case "save": return try save(a)
        case "set": return try set(a)
        case "add":
            guard let raw = a.pos.dropFirst().first else { throw Fail(5, "project add <folder>") }
            let folder = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: folder.path) else { throw Fail(5, "no folder \(folder.path)") }
            if !FileManager.default.fileExists(atPath: settingsFile(folder).path) {
                try scaffold(folder, name: a.value("name") ?? folder.lastPathComponent, vm: a.value("vm").flatMap(vmName), about: "")
            }
            guard let p = info(folder) else { throw Fail(5, "could not read \(folder.path)") }
            remember(p)
            return "added \(p.name) · \(folder.path)"
        case "forget":
            guard let p = find(a.pos.dropFirst().first) else { throw Fail(5, "no such project · apprentice project list") }
            saveEntries(entries().filter { $0.path != p.folder.path })
            return "forgot \(p.name); its folder stays at \(p.folder.path)"
        default:
            throw Fail(5, usage)
        }
    }

    static func list() -> String {
        let all = all()
        guard !all.isEmpty else { return "no projects yet · apprentice project new \"name\"" }
        return all.map { p in
            "\(p.name) · \(p.folder.path) · " + (p.vm.map { "VM \($0)" } ?? "this Mac")
                + " · \(Pipelines.inFolder(p.folder).count) pipelines" + (p.remote.map { " · \($0)" } ?? "")
        }.joined(separator: "\n")
    }

    private static func new(_ a: Args) throws -> String {
        guard let name = a.pos.dropFirst().first?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { throw Fail(5, usage) }
        // Each project works in its own VM unless told otherwise: its accounts stay apart from every other project's.
        let vm = a.has("no-vm") ? nil : vmName(a.value("vm") ?? folderName(name))
        let folder = a.value("dir").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
            ?? defaultRoot.appendingPathComponent(folderName(name))
        var out: [String] = []
        if let source = a.value("from") {
            guard !FileManager.default.fileExists(atPath: folder.path) else { throw Fail(5, "\(folder.path) already exists; choose another folder with --dir") }
            try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            let r = Repo.run("git", ["clone", source, folder.path], in: folder.deletingLastPathComponent())
            guard r.code == 0 else { throw Fail(5, "could not clone \(source): \(r.out)") }
            out.append("cloned \(source)")
        } else if FileManager.default.fileExists(atPath: settingsFile(folder).path) {
            throw Fail(5, "\(folder.path) is already a project · apprentice project add \(folder.path)")
        }
        try scaffold(folder, name: name, vm: vm, about: a.value("about") ?? "")
        if a.value("from") != nil {
            // Where it runs is this Mac's choice, never the repository's: a project.toml from someone else could
            // name a VM of the user's that is signed in to their own accounts.
            let file = settingsFile(folder)
            if let vm { Toml.set(file, "project", "vm", quote(vm)) } else { Toml.remove(file, "project", "vm") }
        }
        guard let p = info(folder) else { throw Fail(5, "could not read \(folder.path)") }
        remember(p)
        out.append("project \(name) · \(folder.path) · " + (vm.map { "VM \($0)" } ?? "this Mac"))
        if let vm, !VM.exists(vm) { out.append("the VM \(vm) is not set up yet: apprentice --vm \(vm) vm setup") }
        out.append("open it: cd \(VM.shellQuoted(folder.path))" + (vm.map { " && export APPRENTICE_VM=\($0)" } ?? ""))
        return out.joined(separator: "\n")
    }

    /// A VM name from what the user typed: lower case ASCII letters, digits and dashes, since it becomes a Tart
    /// VM's name, a folder and a socket path. A project's name in another script ("Café", "日本") keeps what is left,
    /// else `vm`.
    static func vmName(_ raw: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        var ascii = ""
        ascii.unicodeScalars.append(contentsOf: raw.lowercased().unicodeScalars.filter { allowed.contains($0) }.prefix(40))
        let n = ascii.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if !n.isEmpty { return n }
        // Nothing ASCII in it: a name from its first characters' code points, so two such projects still differ.
        let letters = raw.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard !letters.isEmpty else { return nil }
        return "vm-" + letters.prefix(4).map { String($0.value, radix: 16) }.joined(separator: "-")
    }

    /// The VM a project gets of its own unless told otherwise: named after its folder.
    static func ownVM(_ name: String) -> String? { vmName(folderName(name)) }

    /// The VM a new project gets: the name typed, else the one suggested from the project's.
    static func vmFor(typed: String, project: String) -> String? { vmName(typed) ?? ownVM(project) }

    /// Changes how a project runs: its VM (or none), its name. The rest of `project.toml` stays as written.
    private static func set(_ a: Args) throws -> String {
        guard let p = find(a.pos.dropFirst().first) else { throw Fail(5, "no such project · apprentice project list") }
        let file = settingsFile(p.folder)
        var out: [String] = []
        if let name = a.value("name")?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            Toml.set(file, "project", "name", quote(name))
            out.append("named \(name)")
        }
        if a.has("no-vm") {
            Toml.remove(file, "project", "vm")
            out.append("runs on this Mac")
        } else if let raw = a.value("vm") {
            guard let vm = vmName(raw) else { throw Fail(6, "--vm takes a name: letters, digits and dashes") }
            Toml.set(file, "project", "vm", quote(vm))
            out.append("runs in the VM \(vm)" + (VM.exists(vm) ? "" : "; it is not set up yet: apprentice --vm \(vm) vm setup"))
        }
        guard !out.isEmpty else { throw Fail(5, usage) }
        if let changed = info(p.folder) { remember(changed) }
        return "\(p.name): " + out.joined(separator: "; ")
    }

    /// Commits everything in the project folder; `--push` also sends it to its remote, or, with none yet and
    /// GitHub's `gh` signed in, makes a private repository for it first.
    private static func save(_ a: Args) throws -> String {
        guard let p = find(a.pos.dropFirst().first) else { throw Fail(5, "not in a project folder · apprentice project save <name>") }
        let dir = p.folder
        if Repo.run("git", ["rev-parse", "--is-inside-work-tree"], in: dir).out != "true" {
            let r = Repo.run("git", ["init", "-q"], in: dir)
            guard r.code == 0 else { throw Fail(5, "git init failed: \(r.out)") }
        }
        // Only this folder, even when it sits inside a bigger repo: its other changes are not ours to commit.
        Repo.run("git", ["add", "-A", "--", "."], in: dir)
        var out: [String] = []
        if Repo.run("git", ["diff", "--cached", "--quiet", "--", "."], in: dir).code != 0 {
            let message = a.value("message") ?? "Save \(p.name) · \(Schedules.stamp(Date()))"
            let r = Repo.run("git", ["commit", "-q", "-m", message, "--", "."], in: dir)
            guard r.code == 0 else { throw Fail(5, "commit failed: \(r.out)") }
            out.append("saved \(p.name): \(Repo.run("git", ["rev-parse", "--short", "HEAD"], in: dir).out)")
        } else {
            out.append("\(p.name): nothing new to save")
        }
        guard a.has("push") else { return out.joined(separator: "\n") }
        let remote = p.remote
        if remote == nil {
            guard Repo.run("gh", ["auth", "status"], in: dir).code == 0 else {
                throw Fail(5, out.joined(separator: "\n") + "\nno GitHub remote yet, and the GitHub CLI is not signed in: `gh auth login`, or `git remote add origin <url>` in \(dir.path)")
            }
            let r = Repo.run("gh", ["repo", "create", folderName(p.name), "--private", "--source", ".", "--remote", "origin", "--push"], in: dir)
            guard r.code == 0 else { throw Fail(5, "could not make a GitHub repository: \(r.out)") }
            let made = Repo.run("git", ["remote", "get-url", "origin"], in: dir).out
            // Recorded here too, not only by `Sync`, which skips this with sync off (F7).
            if !made.isEmpty { setRemote(dir, made) }
            out.append("made a private GitHub repository and pushed: \(made)")
        } else {
            let branch = Repo.run("git", ["rev-parse", "--abbrev-ref", "HEAD"], in: dir).out
            let r = Repo.run("git", ["push", "-u", "origin", branch], in: dir)
            guard r.code == 0 else { throw Fail(5, "push failed: \(r.out)") }
            if let remote { setRemote(dir, remote) }
            out.append("pushed to \(remote ?? "origin")")
        }
        return out.joined(separator: "\n")
    }
}
