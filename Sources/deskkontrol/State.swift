import AppKit
import Foundation

struct Fail: Error {
    let code: Int32
    let message: String
    init(_ code: Int32, _ message: String) {
        self.code = code
        self.message = message
    }
}

enum Store {
    static let dir: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".deskkontrol")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    static func log(_ entry: [String: Any]) {
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let folder = dir.appendingPathComponent("runs/\(day)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("steps.jsonl")
        var e = entry
        e["ts"] = ISO8601DateFormatter().string(from: Date())
        guard var line = try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: file)
        }
    }
}

struct Session: Codable {
    var app: String
    var bundle: String?
    var pid: pid_t
    var wid: CGWindowID
    var scriptWindowID: Int?
    var allow: [String]

    var isBrowser: Bool { ["com.google.Chrome", "com.apple.Safari"].contains(bundle ?? "") }

    static func current() throws -> Session {
        guard let s = Store.load(Session.self, "session.json") else {
            throw Fail(5, "no session: run `deskkontrol session --app \"Google Chrome\"`")
        }
        guard NSRunningApplication(processIdentifier: s.pid) != nil else {
            throw Fail(5, "\(s.app) is no longer running: start a new session")
        }
        return s
    }
}

/// Per-domain navigation limits and the pause between web actions.
struct Limits: Codable {
    var navs: [String: [Double]] = [:]
    var lastURL: [String: String] = [:]
    var lastAction: Double = 0

    static let navMinGap = 5.0
    static let reloadMax = 3
    static let reloadWindow = 120.0

    static func checkNavigation(_ url: URL) throws {
        var l = Store.load(Limits.self, "limits.json") ?? Limits()
        let domain = url.host ?? "local"
        let now = Date().timeIntervalSince1970
        var times = (l.navs[domain] ?? []).filter { now - $0 < reloadWindow }
        if l.lastURL[domain] == url.absoluteString {
            let reloads = times.count
            if reloads >= reloadMax { throw Fail(4, "refresh limit: \(reloads) loads of \(url.absoluteString) in 2 min") }
        }
        if let last = times.last, now - last < navMinGap {
            let wait = navMinGap - (now - last)
            usleep(UInt32(wait * 1_000_000))
        }
        times.append(Date().timeIntervalSince1970)
        l.navs[domain] = times
        l.lastURL[domain] = url.absoluteString
        Store.save(l, "limits.json")
    }

    static func paceAction(web: Bool) {
        var l = Store.load(Limits.self, "limits.json") ?? Limits()
        let now = Date().timeIntervalSince1970
        if web {
            let gap = Double.random(in: 0.5...2.0)
            let since = now - l.lastAction
            if since < gap { usleep(UInt32((gap - since) * 1_000_000)) }
        }
        l.lastAction = Date().timeIntervalSince1970
        Store.save(l, "limits.json")
    }
}

enum Gate {
    static let words = [
        "send", "post", "publish", "like", "follow", "comment", "submit", "save", "update", "upload",
        "pay", "buy", "delete", "remove", "confirm", "create", "commit", "merge", "archive", "transfer",
    ]

    static func matches(_ text: String) -> Bool {
        let tokens = text.lowercased().split(whereSeparator: { !$0.isLetter })
        return tokens.contains { words.contains(String($0)) }
    }

    static func sensitivePage(_ url: String?) -> Bool {
        guard let u = url?.lowercased() else { return false }
        return ["/settings", "/account", "/billing", "/security"].contains { u.contains($0) }
    }

    /// Native dialog only a person can answer: deskkontrol only acts inside the session app, never on this alert.
    static func ask(_ title: String, _ detail: String) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let alert = NSAlert()
        alert.messageText = "deskkontrol wants to: \(title)"
        alert.informativeText = detail + "\n\nDenies automatically in 120 s."
        alert.addButton(withTitle: "Approve")
        alert.addButton(withTitle: "Deny")
        alert.layout()
        alert.window.level = .floating
        app.activate(ignoringOtherApps: true)
        let timer = Timer(timeInterval: 120, repeats: false) { _ in app.abortModal() }
        RunLoop.main.add(timer, forMode: .modalPanel)
        let answer = alert.runModal()
        timer.invalidate()
        Store.log(["gate": title, "approved": answer == .alertFirstButtonReturn])
        guard answer == .alertFirstButtonReturn else { throw Fail(3, "denied at the approval gate") }
    }
}
