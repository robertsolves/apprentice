import AppKit
import CryptoKit
import Foundation
import Security

/// The release channel: apprentice installed from the DMG, as `Apprentice.app` in /Applications. The bundle
/// carries everything a clone would: the window (`Contents/MacOS`), the CLI and daemon (`Contents/Helpers`),
/// and the playbooks, skills and agent docs (`Contents/Resources/share`, laid out as in the repo). It has no
/// git and no Swift toolchain, so it updates from GitHub releases instead: the daemon checks the latest
/// release every `[update] check_hours`, `session` says one is waiting, and the window installs it.
///
/// A clone install (`install.sh`, `kit.sh`) keeps updating from git; when both are on the Mac, the clone is
/// in charge and the app only opens its window.
enum Release {
    static let defaultRepo = "robertsolves/apprentice"
    /// `[update] repo = "owner/name"`, for a fork that publishes its own releases.
    static var repo: String { Repo.settings["repo"].map(Toml.unquote).flatMap { $0.isEmpty ? nil : $0 } ?? defaultRepo }
    static let dmgName = "apprentice-macos.dmg"
    static let sumsName = "SHA256SUMS.txt"

    /// The release bundle this binary runs from: the nearest `.app` above it whose Info.plist says
    /// `ApprenticeRelease`. Nil for a clone build and for the bundle `kit.sh` makes in `~/.apprentice`.
    static let bundle: URL? = {
        guard var url = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            guard url.pathExtension == "app" else { continue }
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
            return (info?["ApprenticeRelease"] as? Bool) == true ? url : nil
        }
        return nil
    }()

    static var isRelease: Bool { bundle != nil }
    /// The repo's `agent/`, `skills/` and `playbooks/` inside the bundle.
    static var share: URL? { bundle?.appendingPathComponent("Contents/Resources/share") }
    static var cli: URL? { bundle?.appendingPathComponent("Contents/Helpers/apprentice") }
    static var link: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/apprentice") }

    /// A clone install on this Mac, which stays in charge of the CLI, the playbooks and updates.
    static var cloneInstalled: Bool {
        guard let i = Build.install, i.channel != "release", !i.clone.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: i.clone + "/.git")
    }

    // MARK: - first launch of a version

    /// Run by the window at launch: links the CLI onto PATH, brings in the bundle's playbooks, connects the
    /// coding agents when the version is new, and records the install. Returns what the user should know.
    @discardableResult
    static func setUp() -> [String] {
        guard let bundle, let cli, let share else { return [] }
        // Opened from the DMG, or a quarantined copy macOS runs from a random path: nothing to link to yet.
        if bundle.path.hasPrefix("/Volumes/") || bundle.path.contains("/AppTranslocation/") {
            return ["drag Apprentice to Applications and open it from there: it sets itself up then"]
        }
        if cloneInstalled { return ["a clone install (\(Build.install?.clone ?? "")) is in charge: updates come from git"] }
        var out: [String] = []
        let fm = FileManager.default
        try? fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            if dest != cli.path { try? fm.removeItem(at: link); try? fm.createSymbolicLink(at: link, withDestinationURL: cli) }
        } else if fm.fileExists(atPath: link.path) {
            out.append("\(link.path) is another apprentice build; left as it is")
        } else {
            try? fm.createSymbolicLink(at: link, withDestinationURL: cli)
            out.append("linked \(link.path) → the app's CLI")
        }
        let copied = syncPlaybooks(from: share.appendingPathComponent("playbooks"))
        if copied > 0 { out.append("\(copied) playbook\(copied == 1 ? "" : "s") brought in from \(Build.number)") }
        let previous = Build.install
        if previous?.commit != Build.number || previous?.channel != "release" {
            Store.save(Build.Install(clone: "", commit: Build.number, built: ISO8601DateFormatter().string(from: Date()),
                                     bin: cli.path, channel: "release"), "install.json")
            if let note = connectAgents() { out.append(note) }
        }
        return out
    }

    /// The bundle's playbooks copied into `~/.apprentice/playbooks`, a real folder that `learn` writes to (the
    /// bundle is signed and never written). A file the user changed since the last copy is kept; one they
    /// never touched follows the new version. Returns how many files were written.
    @discardableResult
    static func syncPlaybooks(from source: URL, into target: URL = Playbooks.dir) -> Int {
        let fm = FileManager.default
        // A link left by an old clone install would send `learn` into a folder that may be gone.
        if (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil { try? fm.removeItem(at: target) }
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        var copiedFrom = Store.load([String: String].self, "playbooks-release.json") ?? [:]
        var written = 0
        let files = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey])?.compactMap { $0 as? URL } ?? []
        for file in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let rel = String(file.resolvingSymlinksInPath().path.dropFirst(source.resolvingSymlinksInPath().path.count + 1))
            guard let data = try? Data(contentsOf: file) else { continue }
            let dest = target.appendingPathComponent(rel)
            let have = (try? Data(contentsOf: dest)).map(digest)
            let fresh = digest(data)
            guard have != fresh else { copiedFrom[rel] = fresh; continue }
            // Never over the user's own edit: only a file that is missing or still the last copy.
            guard have == nil || have == copiedFrom[rel] else { continue }
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? data.write(to: dest, options: .atomic)) != nil { copiedFrom[rel] = fresh; written += 1 }
        }
        Store.save(copiedFrom, "playbooks-release.json")
        return written
    }

    /// `agent/connect.py` from the bundle: every coding agent gets the skill, its rules and the MCP server.
    /// python3 is a stub that offers to install the developer tools when they are missing; never trigger it.
    static func connectAgents() -> String? {
        guard let share else { return nil }
        guard Repo.run("/usr/bin/xcode-select", ["-p"]).code == 0 else {
            return "coding agents not connected yet: that needs python3 from the Xcode command-line tools (`xcode-select --install`), then Updates & health ▸ Connect agents"
        }
        let r = Repo.run("/usr/bin/python3", [share.appendingPathComponent("agent/connect.py").path, link.path])
        return r.code == 0 ? "connected the coding agents" : "connecting the coding agents failed: \(r.out.split(separator: "\n").last ?? "")"
    }

    // MARK: - the latest release

    struct Latest: Codable {
        var version: String
        var checked: Double
        var dmg: String?
        var sums: String?
        var page: String?
    }

    static var cached: Latest? { Store.load(Latest.self, "release.json") }

    /// The newest release, from GitHub at most every `[update] check_hours` unless forced. Blocks: never on
    /// the main thread.
    @discardableResult
    static func check(force: Bool = false) -> Latest? {
        if !force, let c = cached, Date().timeIntervalSince1970 - c.checked < Repo.checkSeconds { return c }
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return cached }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("apprentice/\(Build.number)", forHTTPHeaderField: "User-Agent")
        guard let data = fetch(req), let latest = parse(data) else { return cached }
        Store.save(latest, "release.json")
        return latest
    }

    /// Pure: a GitHub `releases/latest` reply as the version and its DMG and checksum links.
    static func parse(_ data: Data, now: Date = Date()) -> Latest? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, json["draft"] as? Bool != true else { return nil }
        let assets = (json["assets"] as? [[String: Any]]) ?? []
        func asset(_ name: String) -> String? {
            assets.first { $0["name"] as? String == name }?["browser_download_url"] as? String
        }
        return Latest(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, checked: now.timeIntervalSince1970,
                      dmg: asset(dmgName), sums: asset(sumsName), page: json["html_url"] as? String)
    }

    /// Pure: `a` is a later version than `b` (`0.10.0` after `0.9.1`; `1.0.0` after `1.0.0-rc1`).
    static func newer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> (nums: [Int], pre: String?) {
            let split = v.split(separator: "-", maxSplits: 1).map(String.init)
            let core = split[0].split(separator: "+").first.map(String.init) ?? split[0]
            return (core.split(separator: ".").map { Int($0) ?? 0 }, split.count > 1 ? split[1] : nil)
        }
        let (x, y) = (parts(a), parts(b))
        for i in 0..<max(x.nums.count, y.nums.count) {
            let (p, q) = (i < x.nums.count ? x.nums[i] : 0, i < y.nums.count ? y.nums[i] : 0)
            if p != q { return p > q }
        }
        switch (x.pre, y.pre) {
        case (nil, .some): return true
        case (.some(let p), .some(let q)): return p.compare(q, options: .numeric) == .orderedDescending
        default: return false
        }
    }

    /// The release waiting to be installed, if any.
    static var available: Latest? {
        guard isRelease, !cloneInstalled, let c = cached, newer(c.version, than: Build.number) else { return nil }
        return c
    }

    /// What `session` prints: one line, so the agent tells the user.
    static var line: String? {
        available.map { "apprentice \($0.version) is available (this is \(Build.number)): tell the user; the window's Updates & health installs it" }
    }

    private static var checking = false
    private static let lock = NSLock()

    /// The daemon's check, off the command queue.
    static func checkInBackground() {
        guard isRelease, !cloneInstalled else { return }
        lock.lock()
        if checking { lock.unlock(); return }
        checking = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let had = available?.version
            let latest = check()
            lock.lock(); checking = false; lock.unlock()
            if let latest, latest.version != had, newer(latest.version, than: Build.number) {
                Store.log(["update": "release \(latest.version) available"])
            }
        }
    }

    // MARK: - installing one

    /// `apprentice update [--check]` in the DMG's app: the same check and install the window does.
    static func updateCommand(_ a: Args) throws -> String {
        guard let latest = check(force: true) else { throw Fail(5, "could not reach GitHub releases for \(repo)") }
        guard newer(latest.version, than: Build.number) else { return "up to date: \(Build.number) is the latest release" }
        if a.has("check") { return "apprentice \(latest.version) is available (this is \(Build.number))" + (latest.page.map { " · \($0)" } ?? "") }
        guard Approvals.all.isEmpty else { throw Fail(5, "a step is waiting for approval: answer it, then update") }
        try install(latest) { print($0) }
        _ = Wire.stopDaemon()
        return "installed apprentice \(latest.version): the next command starts the new daemon; reopen the window if it is open"
    }

    /// Downloads the release's DMG, checks it against the release's SHA256SUMS, checks the new app's
    /// signature (the same team as this one when this one has a team), and swaps the bundle in place. The
    /// caller restarts the daemon and the window. Blocks.
    static func install(_ latest: Latest, step: (String) -> Void) throws {
        guard let bundle else { throw Fail(5, "this is not a release install; update a clone with `apprentice update`") }
        guard let dmg = latest.dmg.flatMap(URL.init(string:)), let sums = latest.sums.flatMap(URL.init(string:)) else {
            throw Fail(5, "release \(latest.version) has no \(dmgName) or \(sumsName)")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("apprentice-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        step("downloading \(latest.version)…")
        guard let image = fetch(URLRequest(url: dmg, timeoutInterval: 600)), let list = fetch(URLRequest(url: sums, timeoutInterval: 30)) else {
            throw Fail(5, "could not download release \(latest.version)")
        }
        guard let want = expectedDigest(String(decoding: list, as: UTF8.self), name: dmgName), want == digest(image) else {
            throw Fail(5, "the download does not match the release's \(sumsName); nothing was changed")
        }
        let file = work.appendingPathComponent(dmgName)
        try image.write(to: file)

        step("checking the new app…")
        let mount = work.appendingPathComponent("mnt")
        let attach = Repo.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, file.path])
        guard attach.code == 0 else { throw Fail(5, "could not open the DMG: \(attach.out)") }
        defer { Repo.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }
        let fresh = mount.appendingPathComponent(bundle.lastPathComponent)
        let app = FileManager.default.fileExists(atPath: fresh.path) ? fresh : mount.appendingPathComponent("Apprentice.app")
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == AppBundle.identifier, (info?["ApprenticeRelease"] as? Bool) == true,
              info?["CFBundleShortVersionString"] as? String == latest.version else {
            throw Fail(5, "the DMG does not hold apprentice \(latest.version)")
        }
        guard Repo.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).code == 0 else {
            throw Fail(5, "the new app's signature does not verify; nothing was changed")
        }
        if let mine = team(bundle), team(app) != mine {
            throw Fail(5, "the new app is not signed by the same developer (\(mine)); nothing was changed")
        }

        step("installing…")
        let staged = bundle.deletingLastPathComponent().appendingPathComponent(".\(bundle.lastPathComponent).new")
        try? FileManager.default.removeItem(at: staged)
        let copy = Repo.run("/usr/bin/ditto", [app.path, staged.path])
        guard copy.code == 0 else { throw Fail(5, "could not copy the new app next to \(bundle.path): \(copy.out)") }
        _ = try FileManager.default.replaceItemAt(bundle, withItemAt: staged)
        Store.log(["update": "installed release \(latest.version)", "from": Build.number])
    }

    /// Pure: the digest `SHA256SUMS.txt` lists for `name` (`<hex>  <name>` lines).
    static func expectedDigest(_ sums: String, name: String) -> String? {
        for line in sums.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2, parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == name { return String(parts[0]).lowercased() }
        }
        return nil
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The signing team of a bundle on disk, or nil for ad hoc or unsigned code.
    static func team(_ app: URL) -> String? {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func fetch(_ req: URLRequest) -> Data? {
        let done = DispatchSemaphore(value: 0)
        var out: Data?
        URLSession.shared.dataTask(with: req) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { out = data }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + req.timeoutInterval + 5)
        return out
    }
}
