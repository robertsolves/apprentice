import Foundation

/// Operating apprentice's own window, the way an agent operates any app, without being able to answer for the user.
/// What the window shows to the user alone (Allow and Deny on an approval, a run's question about access, a script that
/// is about to run) is a control apprentice can see and not press: it takes the user's approval, as a payment does.
enum OwnWindow {
    /// Whether a running app is the window, which may be bound. The daemon's own windows (an accessory process, or this
    /// process) are not: they are where the user answers.
    static func mayBind(bundle: String?, accessory: Bool, pid: pid_t, daemon: pid_t) -> Bool {
        bundle == AppBundle.identifier && !accessory && pid != daemon
    }

    /// The window the caller runs inside, for this command: a tab, or an agent or run started in one. Nil for the person.
    static var caller: (host: pid_t?, tab: String?) = (nil, nil)

    /// Why this caller cannot operate the window, nil when it can. Whatever runs in a tab is part of what it would be
    /// operating: its keys come back to it as its own input, and its clicks can close the tab it runs in. A schedule's
    /// tab name is only a name: it runs outside the window.
    static func insideRefusal(host: pid_t?, tab: String?, window: pid_t) -> String? {
        guard host == window || (tab.map { !$0.isEmpty && !$0.hasPrefix("schedule:") } ?? false) else { return nil }
        return "this runs inside apprentice's own window, so operating that window would type into itself. Name another app (`session --app <name>`), or have an agent outside the window, or the user, do it"
    }

    /// Whether a control is one the user alone presses, by its name. `[gate] own_window_user_only` lists them.
    static func userOnly(_ e: Element?, words: [String] = SiteLists.current.ownWindowUserOnly) -> Bool {
        guard let e else { return false }
        let padded = " " + "\(e.label) \(e.name)".lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ") + " "
        return words.contains { padded.contains(" \($0) ") }
    }

    /// Why an action in the window is refused outright, nil when it may go on to the ordinary gate. A point can land on a
    /// button that is the user's, and a modal alert or panel takes any key, so neither is the agent's to use here. A sheet is
    /// a form of the window itself, operated like the rest of it, whose controls are still checked by name: only a key
    /// that presses whatever its default button is goes through its button's number instead.
    static func refusal(cmd: String, args: [String], element: Element?, otherWindowFocused: Bool, sheetFocused: Bool = false) -> String? {
        if sheetFocused, cmd == "key", ["return", "enter", "space"].contains(args.first?.lowercased() ?? "") {
            return "in a sheet of apprentice's own window, press its button by number (`apprentice read`, then `click <id>`): this key presses whichever button is the default"
        }
        if otherWindowFocused {
            return "a dialog or panel of apprentice's own window has the focus: only the user answers it. Say what it is waiting for in the chat, and carry on when they have"
        }
        let a = Args.parse(args)
        if ["click", "drag"].contains(cmd), element == nil, a.value("at") != nil || a.value("by") != nil {
            return "in apprentice's own window, click by element number (`apprentice read`, then `click <id>`): a point can land on a button that is the user's"
        }
        return nil
    }
}
