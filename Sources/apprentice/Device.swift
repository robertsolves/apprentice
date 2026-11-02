import Foundation

/// One thing at a time per device. This Mac and each VM has one screen, one cursor and one keyboard, so only
/// one agent may work it at once: the first to act holds it, and another agent's screen command is refused
/// (exit 4) with who holds it, until the holder has been quiet for `[device] busy_min` minutes (5) or frees it
/// (`device free`). Several agents can still run at once on different devices: one per VM.
///
/// Who an agent is: its terminal tab (`APPRENTICE_TAB`: a window tab, `schedule:<id>`, `pipeline:<ref>`),
/// else its project folder, else its model. Two agents in plain terminals with the same model and no project
/// look like one; give each a project or a tab.
enum Device {
    struct Owner: Codable, Equatable {
        var who: String
        var label: String
        var since: Double
        var at: Double
    }

    /// The commands that use the screen, cursor or keyboard, or bind the session.
    static let screen: Set<String> = Playbooks.actions.union(["session", "focus", "read", "do", "wait-for", "ocr", "shot", "type", "menu"])

    static var busySeconds: Double {
        let raw = Toml.load(Config.path)["device"]?["busy_min"].map(Toml.unquote) ?? "5"
        return max(Double(raw) ?? 5, 0.5) * 60
    }

    /// `owner.json` for this Mac, or for a named VM's daemon.
    static func file(vm: String? = Store.vmName) -> URL {
        (vm.map { Store.dir.appendingPathComponent("vms/\($0)") } ?? Store.dir).appendingPathComponent("owner.json")
    }

    static func owner(vm: String? = Store.vmName) -> Owner? {
        (try? Data(contentsOf: file(vm: vm))).flatMap { try? JSONDecoder().decode(Owner.self, from: $0) }
    }

    /// Who is asking, and how to name them to the user.
    static func caller(_ req: Request) -> (who: String, label: String) {
        if let tab = req.tab, !tab.isEmpty {
            if tab.hasPrefix("schedule:") { return (tab, "the schedule \(tab.dropFirst("schedule:".count))") }
            if tab.hasPrefix("pipeline:") { return (tab, "the pipeline \(tab.dropFirst("pipeline:".count))") }
            return ("tab:\(tab)", "an agent in a window tab")
        }
        if let project = req.project, !project.isEmpty {
            let folder = URL(fileURLWithPath: project).deletingLastPathComponent()
            return ("project:\(folder.path)", "the project \(Projects.info(folder)?.name ?? folder.lastPathComponent)")
        }
        let model = req.model ?? "an agent"
        return ("model:\(model)", model == "an agent" ? "an agent" : "an agent (\(model))")
    }

    /// Whether `owner` still holds the device at `now`.
    static func holds(_ owner: Owner?, now: Double = Date().timeIntervalSince1970) -> Bool {
        guard let owner else { return false }
        return now - owner.at < busySeconds
    }

    /// Run before every screen command: refuses another agent while one holds the device, and records the
    /// caller as the holder otherwise. The user's own clicks in the window are never refused.
    static func check(_ req: Request, now: Double = Date().timeIntervalSince1970) throws {
        guard screen.contains(req.cmd), req.user != true else { return }
        let (who, label) = caller(req)
        let current = owner()
        if let current, current.who != who, holds(current, now: now) {
            let place = Store.vmName.map { "the VM \($0)" } ?? "this Mac"
            let quiet = Int((now - current.at) / 60)
            throw Fail(4, "blocked: \(place) is in use by \(current.label) (last action \(quiet) min ago). One screen, one cursor and one keyboard: one agent at a time. "
                + "Wait and try again, ask the user, or work in a VM (`apprentice --vm <name> …`). The user can free it with `apprentice device free`.")
        }
        let since = (current?.who == who && holds(current, now: now)) ? current!.since : now
        let next = Owner(who: who, label: label, since: since, at: now)
        try? Wire.json(next).write(to: file(), options: .atomic)
    }

    /// `device` (who holds it) and `device free`.
    static func command(_ a: Args) -> String {
        let place = Store.vmName.map { "the VM \($0)" } ?? "this Mac"
        if a.pos.first == "free" {
            try? FileManager.default.removeItem(at: file())
            return "\(place) is free"
        }
        guard let o = owner(), holds(o) else { return "\(place) is free" }
        let since = Date(timeIntervalSince1970: o.since).formatted(date: .omitted, time: .shortened)
        return "\(place) is in use by \(o.label) since \(since), last action \(Int((Date().timeIntervalSince1970 - o.at) / 60)) min ago"
    }

    /// Whether a schedule or pipeline for `vm` would be refused right now, and by whom.
    static func busy(vm: String?, for who: String) -> String? {
        guard let o = owner(vm: vm), o.who != who, holds(o) else { return nil }
        return o.label
    }
}
