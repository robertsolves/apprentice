import AppKit

/// Where the person was working when a task began, given back when it ends. `session` notes the app and window
/// in front before it launches or raises anything. `apprentice done` (the agent says the task is finished) and
/// an agent that has gone quiet both put them back there, and the overlay says which happened: "Done", or
/// "Agent stopped".
enum Handback {
    struct Origin: Codable {
        var pid: pid_t
        var bundle: String?
        var name: String
        var wid: UInt32?
        var at: Double
    }

    /// What the overlay shows for a while after the task ends.
    struct Banner {
        var head: String
        var detail: String
        var good: Bool
        var until: Date
    }

    static var banner: Banner?
    /// The app the agent runs in (the terminal), from the latest command.
    static var agentHost: pid_t?

    /// The agent's terminal device and working folder, from its latest command.
    static var agentTTY: String?
    static var agentCwd: String?

    /// Nothing to give back until a task starts.
    private static var returned = true
    /// Seconds without a command after which the agent counts as stopped.
    static let quietAfter: TimeInterval = 120

    private static let editors: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
                                               "com.exafunction.windsurf", "com.vscodium", "dev.zed.Zed"]
    private static let generic: Set<String> = ["users", "home", "projects", "project", "desktop", "documents", "developer", "src",
                                               "code", "dev", "work", "repos", "github", "flutter", "downloads"]

    /// The overlay's "Go to agent" button: the window the agent is in, not just its app. There can be several
    /// editor windows and terminals, on several screens, so it goes from the most exact way to the least:
    /// the Terminal or iTerm tab with the agent's own terminal device, then the window whose title names the
    /// folder the agent works in (a parent folder counts, the way an editor titles its window), then an editor
    /// asked to open that project folder (it focuses the window that already has it), then the app itself.
    static func showAgent() {
        guard let pid = agentHost, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        let bundle = app.bundleIdentifier ?? ""
        var how = "app"
        if let tty = agentTTY, bundle == "com.apple.Terminal" || bundle == "com.googlecode.iterm2", selectTab(bundle, tty: tty) {
            how = "tab " + tty
        } else if let title = raiseWindowNamed(pid) {
            how = "window " + title
        } else if editors.contains(bundle), let root = projectRoot() {
            _ = Repo.run("/usr/bin/open", ["-b", bundle, root])
            how = "project " + (root as NSString).lastPathComponent
        } else {
            let el = appElement(pid)
            _ = el.set(kAXFrontmostAttribute, kCFBooleanTrue)
            if let window = pickWindow(el) { _ = window.set(kAXMainAttribute, kCFBooleanTrue); window.perform(kAXRaiseAction) }
        }
        app.activate()
        Store.log(["handback": "to the agent: \(app.localizedName ?? "") \(how)"])
    }

    /// The folders from the working folder up to just below the home folder, deepest first.
    private static func folders() -> [String] {
        guard let cwd = agentCwd else { return [] }
        let home = NSHomeDirectory()
        var out: [String] = []
        var url = URL(fileURLWithPath: cwd)
        while url.path.count > home.count, url.path != "/" { out.append(url.path); url.deleteLastPathComponent() }
        return out
    }

    /// The nearest folder with a .git, which is what an editor has open.
    private static func projectRoot() -> String? {
        folders().first { FileManager.default.fileExists(atPath: $0 + "/.git") } ?? folders().first
    }

    /// Raises the host app's window whose title names the agent's folder; the deepest folder wins.
    private static func raiseWindowNamed(_ pid: pid_t) -> String? {
        let el = appElement(pid)
        let all = windows(of: el).compactMap { w in w.string(kAXTitleAttribute).map { (w, $0) } }
        for folder in folders() {
            let name = (folder as NSString).lastPathComponent
            guard name.count > 2, !generic.contains(name.lowercased()) else { continue }
            if let hit = all.first(where: { $0.1.localizedCaseInsensitiveContains(name) }) {
                _ = el.set(kAXFrontmostAttribute, kCFBooleanTrue)
                _ = hit.0.set(kAXMainAttribute, kCFBooleanTrue)
                hit.0.perform(kAXRaiseAction)
                return name
            }
        }
        return nil
    }

    /// Terminal and iTerm answer to AppleScript, which can pick the exact tab by its terminal device and
    /// switches to its desktop. The first use asks the user to allow apprentice to control the app.
    private static func selectTab(_ bundle: String, tty: String) -> Bool {
        let script: String
        if bundle == "com.apple.Terminal" {
            script = """
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(tty)" then
                    set selected of t to true
                    set index of w to 1
                    activate
                    return "ok"
                  end if
                end repeat
              end repeat
            end tell
            return "no"
            """
        } else {
            script = """
            tell application "iTerm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(tty)" then
                      select w
                      select t
                      select s
                      activate
                      return "ok"
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            return "no"
            """
        }
        return Repo.run("/usr/bin/osascript", ["-e", script]).out.contains("ok")
    }

    static var origin: Origin? { Store.load(Origin.self, "origin.json") }

    /// At the start of `session`: the app and window in front now. A second session in the same task keeps the first place.
    static func capture() {
        if !returned, origin != nil, Date().timeIntervalSince(Commands.lastAt) < 600 { return }
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid(),
              front.bundleIdentifier != AppBundle.identifier else { return }
        let focused = appElement(front.processIdentifier).attr(kAXFocusedWindowAttribute) as! AXUIElement?
        Store.save(Origin(pid: front.processIdentifier, bundle: front.bundleIdentifier, name: front.localizedName ?? "your app",
                          wid: focused?.windowID, at: Date().timeIntervalSince1970), "origin.json")
        returned = false
        banner = nil
    }

    /// Brings the person's app and window back in front. False when there is nothing to give back or it has gone.
    @discardableResult
    static func restore() -> Bool {
        guard let o = origin, let app = NSRunningApplication(processIdentifier: o.pid), !app.isTerminated else { return false }
        let el = appElement(o.pid)
        _ = el.set(kAXFrontmostAttribute, kCFBooleanTrue)
        if let wid = o.wid, let window = windows(of: el).first(where: { $0.windowID == wid }) {
            _ = window.set(kAXMainAttribute, kCFBooleanTrue)
            window.perform(kAXRaiseAction)
        }
        returned = true
        Store.log(["handback": o.name])
        return true
    }

    /// `apprentice done ["what was done"]`: the agent finished.
    static func done(_ summary: String?) -> String {
        let name = origin?.name
        let back = restore()
        let said = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        banner = Banner(head: "Done", detail: said.isEmpty ? (back ? "Back in \(name ?? "your app")" : "Task finished") : said,
                        good: true, until: Date().addingTimeInterval(45))
        returned = true
        Awake.finish()
        Sound.play("Glass")
        return back ? "done · gave you back \(name ?? "your app")" : "done · nothing to give back"
    }

    /// From the overlay's timer, on the main thread: the agent went quiet without saying it was done.
    static func tick() {
        if let b = banner, Date() > b.until { banner = nil }
        guard !returned, Commands.lastAt != .distantPast, Date().timeIntervalSince(Commands.lastAt) > quietAfter,
              StatusItem.state == .idle, Approvals.pending == nil, !Pause.on, !KillSwitch.halted else { return }
        // Put the person back only while they are still looking at apprentice's window; if they have moved on, leave them be.
        let watching = Session.stored.flatMap { NSRunningApplication(processIdentifier: $0.pid) }?.isActive == true
        let name = origin?.name
        let back = watching && restore()
        returned = true
        Awake.finish()
        banner = Banner(head: "Agent stopped",
                        detail: "No command for \(Int(quietAfter / 60)) min" + (back ? " · back in \(name ?? "your app")" : ""),
                        good: false, until: Date().addingTimeInterval(60))
        Sound.play("Purr")
    }
}
