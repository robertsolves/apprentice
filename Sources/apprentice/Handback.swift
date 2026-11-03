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

    /// Where the agent's window was when the user last sent it something, written by `apprentice here`.
    struct Spot: Codable {
        var pid: pid_t
        var wid: UInt32
        var at: Double
    }

    /// The window the agent is in, by window id. `here` records it at the moment the user submits a prompt, when
    /// they are certainly in that window; a task's first `session` records the host app's focused window as a fallback.
    private static var fallbackWindow: UInt32?
    private static var agentWindow: UInt32? {
        if let spot = Store.load(Spot.self, "agent.json"), spot.pid == agentHost, Date().timeIntervalSince1970 - spot.at < 43_200 {
            return spot.wid
        }
        return fallbackWindow
    }

    /// `apprentice here`, run by the agent (or a hook on every prompt) as the user sends it something: notes the
    /// window of the agent's app that is in front now. It runs in the CLI itself, so it needs no daemon and no
    /// permission: the window server lists windows front to back with their owner.
    static func here() -> String {
        guard let host = Request.callerHost else { return "here · could not tell which app the agent runs in" }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let normal = info.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
        guard let top = normal.first, (top[kCGWindowOwnerPID as String] as? Int32) == host,
              let wid = top[kCGWindowNumber as String] as? UInt32 else {
            return "here · the agent's app is not in front, so nothing was noted"
        }
        Store.save(Spot(pid: host, wid: wid, at: Date().timeIntervalSince1970), "agent.json")
        return "here · noted the agent's window"
    }

    /// Nothing to give back until a task starts.
    private static var returned = true
    /// Seconds without a command after which the agent counts as stopped.
    static let quietAfter: TimeInterval = 120

    /// True when the user is already looking at the agent: its app is in front and its window is the focused one.
    /// The overlay hides "Go to agent" then.
    static var atAgent: Bool {
        guard let pid = agentHost, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        guard let wanted = agentWindow else { return true }
        let focused = appElement(pid).attr(kAXFocusedWindowAttribute) as! AXUIElement?
        return focused?.windowID == wanted
    }

    /// The overlay's "Go to agent" button. The same for every app and it never opens anything: the window the agent
    /// was in when the task began is registered by its window id, and going back means going to that window. A
    /// window on another desktop is invisible to accessibility, so its desktop is shown first.
    static func showAgent() {
        guard let pid = agentHost, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        let el = appElement(pid)
        var how = "app"
        if let wid = agentWindow {
            var window = windows(of: el).first { $0.windowID == wid }
            if window == nil, Spaces.show(window: wid) {
                // The desktop switch takes a moment to finish.
                window = poll(timeout: 1.5, interval: 0.1) { windows(of: el).first { $0.windowID == wid } }
            }
            if let window {
                _ = el.set(kAXFrontmostAttribute, kCFBooleanTrue)
                _ = window.set(kAXMainAttribute, kCFBooleanTrue)
                window.perform(kAXRaiseAction)
                how = "its window"
            }
        }
        app.activate()
        Store.log(["handback": "to the agent: \(app.localizedName ?? "") \(how)"])
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
        // The agent's window: the focused window of its app now, while the user is most likely in it.
        fallbackWindow = agentHost.flatMap { (appElement($0).attr(kAXFocusedWindowAttribute) as! AXUIElement?)?.windowID }
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
        // Nothing was started (no `session` this task), or it was already handed back: nothing to say or give back.
        guard !returned else { return "done · no task running" }
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

/// Which desktop (Space) a window is on, and switching to it. The window server keeps this; the calls are private
/// (as `_AXUIElementGetWindow` is), so they are looked up at run time and a failure just means "not switched".
enum Spaces {
    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ name: String, as _: T.Type) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    /// Switches the display that holds `wid` to the desktop it is on. True when the window is on the active
    /// desktop already or the switch was asked for.
    static func show(window wid: UInt32) -> Bool {
        typealias Connection = @convention(c) () -> Int32
        typealias ForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
        typealias Active = @convention(c) (Int32) -> UInt64
        typealias DisplayFor = @convention(c) (Int32, UInt64) -> Unmanaged<CFString>?
        typealias SetCurrent = @convention(c) (Int32, CFString, UInt64) -> Void
        guard let connection = symbol("CGSMainConnectionID", as: Connection.self),
              let forWindows = symbol("CGSCopySpacesForWindows", as: ForWindows.self),
              let active = symbol("CGSGetActiveSpace", as: Active.self),
              let displayFor = symbol("CGSCopyManagedDisplayForSpace", as: DisplayFor.self),
              let setCurrent = symbol("CGSManagedDisplaySetCurrentSpace", as: SetCurrent.self) else { return false }
        let cid = connection()
        guard let spaces = forWindows(cid, 7, [NSNumber(value: wid)] as CFArray)?.takeRetainedValue() as? [NSNumber],
              let target = spaces.first?.uint64Value else { return false }
        if target == active(cid) { return true }
        guard let display = displayFor(cid, target)?.takeRetainedValue() else { return false }
        setCurrent(cid, display, target)
        return true
    }
}
