import Foundation

/// Settings come in three levels, each a folder with its own `config.toml` and `prefs.json`. This Mac's
/// `~/.apprentice` is the root. Each VM has its own, kept on this Mac (`~/.apprentice/layers/vm` for the
/// default VM, `layers/vm-<name>` for a named one), so it can be changed while the VM is off. A project
/// folder has its own in its `.apprentice/`. A value is read from the lowest level first: the project,
/// then the VM it runs in, then this Mac. Some sections say how this Mac itself runs (`rootOnly`) and come
/// only from the root. Session state, budgets, routes and logs stay in `Store.dir`, since the daemon that
/// keeps them, and the site limits every VM shares, run on this Mac; a project's budgets only tighten them.
enum Layers {
    enum Place: Hashable {
        case mac
        /// A VM's own settings; nil is the default VM.
        case vm(String?)
        /// A project's `.apprentice/` folder.
        case project(URL)

        var label: String {
            switch self {
            case .mac: return "this Mac"
            case .vm(let name): return "the VM \(name ?? "default")"
            case .project(let dir):
                let folder = dir.deletingLastPathComponent()
                return "the project \(Projects.info(folder)?.name ?? folder.lastPathComponent)"
            }
        }

        var folder: URL {
            switch self {
            case .mac: return Store.dir
            case .vm(let name): return Store.dir.appendingPathComponent("layers/" + (name.map { "vm-\($0)" } ?? "vm"))
            case .project(let dir): return dir
            }
        }
    }

    /// The device the agent works on now: a named VM's daemon (`APPRENTICE_VM`), or a session bound in the VM.
    static var local: Place { Store.vmName != nil || Session.stored?.vm == true ? .vm(Store.vmName) : .mac }

    /// The caller's project, when the command runs in one (`Project.dir`).
    static var project: Place? { Project.dir.map { .project($0) } }

    /// Where values come from, lowest first: the project, the device, this Mac.
    static var chain: [Place] { [project, local == .mac ? nil : local].compactMap { $0 } + [.mac] }

    /// The levels a place falls back to, in order: a project to the VM its `project.toml` names, then this Mac.
    static func parents(of place: Place) -> [Place] {
        switch place {
        case .mac: return []
        case .vm: return [.mac]
        case .project(let dir):
            let vm = Projects.info(dir.deletingLastPathComponent())?.vm
            return (vm.map { [Place.vm($0)] } ?? []) + [.mac]
        }
    }

    /// Sections and keys that say how this Mac runs (how to reach a VM, the account, updates, the window,
    /// the menu bar): a VM or a project never changes them.
    static let rootOnly: Set<String> = ["vm", "account", "update", "app", "sync", "agent.menu_bar", "agent.dock_icon"]

    static func isRootOnly(_ section: String, _ key: String? = nil) -> Bool {
        let s = Toml.canonical(section)
        return rootOnly.contains(s) || s.hasPrefix("vm.") || key.map { rootOnly.contains("\(s).\($0)") } == true
    }

    /// A child's config without what only the root may set.
    static func childOnly(_ table: [String: [String: String]]) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        for (section, keys) in table where !isRootOnly(section) {
            let kept = keys.filter { !isRootOnly(section, $0.key) }
            if !kept.isEmpty { out[section] = kept }
        }
        return out
    }

    /// The file a place keeps; this Mac's settings files may still be in an older synced folder (`Settings.dir`).
    static func file(_ name: String, _ place: Place) -> URL {
        if place == .mac, Settings.files.contains(name) { return Settings.dir.appendingPathComponent(name) }
        return place.folder.appendingPathComponent(name)
    }

    /// A file from one level: "" when it has none yet. Never nil now that every level is on this Mac; the
    /// optional stays for callers that once reached the VM over ssh.
    static func read(_ name: String, _ place: Place) -> String? {
        if case .vm(let vm) = place { adoptGuest(vm) }
        return (try? String(contentsOf: file(name, place), encoding: .utf8)) ?? ""
    }

    /// Replaces a file in one level, atomically.
    static func write(_ name: String, _ text: String, _ place: Place) throws {
        if case .vm(let vm) = place { adoptGuest(vm) }
        let url = file(name, place)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw Fail(5, "could not save \(name) for \(place.label): \(error.localizedDescription)")
        }
    }

    /// VMs whose guest copy was looked for in this process.
    private static var adopted: Set<String> = []

    /// An older install kept a VM's settings inside the guest's `~/.apprentice`. The first time this VM's
    /// own daemon reads them and the folder on this Mac is not there yet, they are copied over once.
    private static func adoptGuest(_ vm: String?) {
        let place = Place.vm(vm)
        let key = vm ?? ""
        guard vm == Store.vmName, !adopted.contains(key),
              !FileManager.default.fileExists(atPath: place.folder.path) else { return }
        adopted.insert(key)
        guard let ip = try? VM.address() else { return }
        var copied: [String: Data] = [:]
        for name in ["config.toml", "prefs.json"] {
            let r = VM.ssh(ip, "cat ~/.apprentice/\(name) 2>/dev/null; true")
            guard r.code == 0 else { return }
            if !r.out.isEmpty { copied[name] = r.out }
        }
        try? FileManager.default.createDirectory(at: place.folder, withIntermediateDirectories: true)
        for (name, data) in copied { try? data.write(to: place.folder.appendingPathComponent(name), options: .atomic) }
    }

    /// config.toml as the caller sees it: this Mac's, then each lower level's own values over it.
    static func config() -> [String: [String: String]] {
        var out = Toml.load(Config.path)
        for place in chain.dropLast().reversed() {
            guard let text = read("config.toml", place), !text.isEmpty else { continue }
            out = overlay(out, childOnly(Toml.parse(text)))
        }
        return out
    }

    /// What `Config.reloadIfChanged` compares: each level's config.toml and when it last changed.
    static func stamp() -> String {
        ([Config.path] + chain.dropLast().map { file("config.toml", $0) }).map { url in
            let at = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return url.path + "@" + (at.map { "\($0.timeIntervalSince1970)" } ?? "-")
        }.joined(separator: "|")
    }

    /// Key by key, the local value over the parent's.
    static func overlay(_ parent: [String: [String: String]], _ local: [String: [String: String]]) -> [String: [String: String]] {
        parent.merging(local) { p, l in p.merging(l) { $1 } }
    }
}
