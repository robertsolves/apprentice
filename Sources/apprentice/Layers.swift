import Foundation

/// Each device keeps its own `.apprentice` folder and inherits from its parent. This Mac is the root. A VM
/// keeps its own `~/.apprentice` inside the guest, with its `prefs.json` and `config.toml`, and its own clone
/// of the repo, cloned from this Mac's (`VM.seedClone`). When both set the same thing, the device's own value
/// wins. Session state, budgets, routes and logs stay in `Store.dir`, since the daemon that keeps them, and
/// the site limits every VM shares, run on this Mac.
enum Layers {
    enum Place: Equatable {
        case mac, vm

        var label: String {
            switch self {
            case .mac: return "this Mac"
            case .vm: return "the VM (\(VM.name))"
            }
        }
    }

    /// The device the agent works on now: a named VM's daemon (`APPRENTICE_VM`), or a session bound in the VM.
    static var local: Place { Store.vmName != nil || Session.stored?.vm == true ? .vm : .mac }

    /// Where values come from, the device's own first.
    static var chain: [Place] { local == .vm ? [.vm, .mac] : [.mac] }

    /// Guest files read in the last 30 s; the daemon reads config.toml on every command.
    private static var cache: [String: (at: Date, text: String?)] = [:]

    /// A file from one device's `.apprentice`: "" when it has none yet, nil when the VM can't be reached.
    static func read(_ name: String, _ place: Place) -> String? {
        switch place {
        case .mac:
            return (try? String(contentsOf: Store.dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
        case .vm:
            if let c = cache[name], Date().timeIntervalSince(c.at) < 30 { return c.text }
            var text: String?
            if let ip = try? VM.address() {
                let r = VM.ssh(ip, "cat ~/.apprentice/\(name) 2>/dev/null; true")
                if r.code == 0 { text = String(decoding: r.out, as: UTF8.self) }
            }
            cache[name] = (Date(), text)
            return text
        }
    }

    /// Replaces a file in one device's `.apprentice`; in the VM it is written beside and then renamed.
    static func write(_ name: String, _ text: String, _ place: Place) throws {
        switch place {
        case .mac:
            try text.write(to: Store.dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        case .vm:
            let ip = try VM.address()
            let r = VM.ssh(ip, "umask 077 && mkdir -p ~/.apprentice && cat > ~/.apprentice/\(name).new && mv ~/.apprentice/\(name).new ~/.apprentice/\(name)",
                           input: Data(text.utf8))
            guard r.code == 0 else {
                throw Fail(5, "could not save to \(place.label): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines)). Is it up? `apprentice vm status`")
            }
            cache[name] = (Date(), text)
        }
    }

    /// config.toml as this device sees it: the Mac's, with the VM's own values over it when working in the VM.
    /// `[vm…]` always comes from the Mac, since it says how to reach the VM.
    static func config() -> [String: [String: String]] {
        let mac = Toml.load(Config.path)
        guard local == .vm, let text = read("config.toml", .vm), !text.isEmpty else { return mac }
        return overlay(mac, Toml.parse(text).filter { $0.key != "vm" && !$0.key.hasPrefix("vm.") })
    }

    /// Key by key, the local value over the parent's.
    static func overlay(_ parent: [String: [String: String]], _ local: [String: [String: String]]) -> [String: [String: String]] {
        parent.merging(local) { p, l in p.merging(l) { $1 } }
    }
}
