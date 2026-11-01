import Foundation
import IOKit.pwr_mgt

/// Keep-awake mode: while a task is running, the daemon holds macOS power assertions so the display and
/// the system do not idle-sleep, and the screen does not lock on idle. They are taken when a command
/// starts and let go two minutes after the last one ends, so the LLM can think between steps; an idle
/// daemon lets the Mac sleep as usual. It cannot stop a logout, a forced restart or sleep from closing
/// a laptop lid on battery. The user turns it on; agents do not.
enum Awake {
    /// The setting: `[agent] keep_awake`, the start-up window, or `awake on|off`.
    private(set) static var enabled = false
    private static var assertions: [IOPMAssertionID] = []
    private static var lastEnd = Date.distantPast
    static let grace = 120.0

    static func set(_ wanted: Bool) {
        enabled = wanted
        if !wanted { release() }
        Store.log(["awake": wanted])
    }

    /// Runs one command with the Mac kept awake, when keep-awake is on.
    static func busy<T>(_ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        hold()
        defer {
            lastEnd = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + grace + 1) {
                Daemon.queue.async { if Date().timeIntervalSince(lastEnd) >= grace { release() } }
            }
        }
        return try body()
    }

    private static func hold() {
        guard assertions.isEmpty else { return }
        for type in [kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionTypePreventUserIdleSystemSleep] {
            var id = IOPMAssertionID(0)
            let ok = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "apprentice: a task is running" as CFString, &id)
            if ok == kIOReturnSuccess { assertions.append(id) }
        }
    }

    private static func release() {
        for id in assertions { IOPMAssertionRelease(id) }
        assertions = []
    }

    static var status: String {
        enabled ? "awake: on · the Mac will not idle-sleep or lock while a task runs, and for 2 min after the last step (a logout, restart or closed lid on battery still can)"
                : "awake: off · macOS may sleep or lock on idle"
    }

    /// `awake on|off|status`.
    static func run(_ a: Args) throws -> String {
        switch a.pos.first ?? "status" {
        case "on": set(true)
        case "off": set(false)
        case "status": break
        default: throw Fail(5, "awake on|off|status")
        }
        return status
    }
}
