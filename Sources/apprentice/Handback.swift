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

    /// The overlay's "Go to agent" button: brings the agent's app and window to the front.
    static func showAgent() {
        guard let pid = agentHost, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        let el = appElement(pid)
        _ = el.set(kAXFrontmostAttribute, kCFBooleanTrue)
        if let window = pickWindow(el) {
            _ = window.set(kAXMainAttribute, kCFBooleanTrue)
            window.perform(kAXRaiseAction)
        }
        app.activate()
        Store.log(["handback": "to the agent: \(app.localizedName ?? "")"])
    }
    /// Nothing to give back until a task starts.
    private static var returned = true
    /// Seconds without a command after which the agent counts as stopped.
    static let quietAfter: TimeInterval = 120

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
