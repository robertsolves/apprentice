import AppKit
import SwiftUI

/// The window's form controls: what a setting looks like to a person, with the TOML, the `2026-11-05T09:00`
/// and the `mon,wed 09:00` kept behind them. Every editor reads and writes the same text the file or the
/// command takes, so the form and the CLI never disagree, and nothing here asks anyone to type a bracket.

/// One setting the window offers, out of everything in config.toml: a plain label, a line of help, and the
/// key it writes. Everything else stays in the file, which the Settings screen opens.
struct Setting: Identifiable {
    enum Kind: Equatable {
        case toggle
        case number(ClosedRange<Int>)
        case choice([String])
        case text
    }

    let section: String
    let key: String
    let label: String
    let help: String
    let kind: Kind
    /// The value the file has when the key is absent, written as TOML.
    let fallback: String

    var id: String { "\(section).\(key)" }

    /// The list the Settings screen shows, in order, grouped by `section`.
    static let shown: [Setting] = [
        Setting(section: "agent", key: "notifications", label: "Desktop notifications",
                help: "A notification when a question or an approval is waiting for you.", kind: .toggle, fallback: "false"),
        Setting(section: "agent", key: "sounds", label: "Sounds",
                help: "A short sound when something happens: a hand-off to you, a pause, a failure.", kind: .toggle, fallback: "true"),
        Setting(section: "agent", key: "menu_bar", label: "Menu bar icon",
                help: "Shows whether apprentice is idle, working or waiting for you; its menu approves a step.", kind: .toggle, fallback: "true"),
        Setting(section: "agent", key: "dock_icon", label: "Dock icon while this window is closed",
                help: "The background service shows in the Dock when the window is not open.", kind: .toggle, fallback: "true"),
        Setting(section: "agent", key: "overlay", label: "Small status box on screen",
                help: "An always-on-top box that says when apprentice is working or handed back to you.", kind: .toggle, fallback: "true"),
        Setting(section: "agent", key: "keep_awake", label: "Keep the Mac awake during tasks",
                help: "No display sleep or lock while a task runs, and for two minutes after.", kind: .toggle, fallback: "false"),
        Setting(section: "agent", key: "ui_only", label: "Screen only, no shell",
                help: "Agents do everything through the screen, never with shell commands.", kind: .toggle, fallback: "false"),
        Setting(section: "agent", key: "optional_questions", label: "Occasional optional questions",
                help: "A small window you may answer or leave, so apprentice learns how you like things done.", kind: .toggle, fallback: "true"),
        Setting(section: "typing", key: "learn", label: "Learn my typing rhythm",
                help: "Timings only, never what you type, and never in password fields.", kind: .toggle, fallback: "true"),
        Setting(section: "update", key: "auto", label: "Install updates automatically",
                help: "Off: you are told, and install from the Updates screen.", kind: .toggle, fallback: "true"),
        Setting(section: "app", key: "theme", label: "Appearance", help: "", kind: .choice(["system", "light", "dark"]), fallback: "\"system\""),
        Setting(section: "app", key: "font", label: "Terminal font", help: "Any installed monospaced font.", kind: .text, fallback: "\"SF Mono\""),
        Setting(section: "app", key: "font_size", label: "Terminal font size", help: "", kind: .number(8...32), fallback: "12"),
    ]

    static func title(_ section: String) -> String {
        switch section {
        case "agent": return "While apprentice works"
        case "typing": return "Typing"
        case "update": return "Updates"
        case "app": return "This window"
        default: return section
        }
    }

    /// The TOML literal for what the editor holds.
    func literal(_ shown: String) -> String {
        switch kind {
        case .toggle: return shown == "true" ? "true" : "false"
        case .number: return String(Int(shown) ?? Int(Toml.unquote(fallback)) ?? 0)
        case .choice, .text: return "\"" + shown.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
    }
}

/// A whole number with a stepper beside it.
struct IntField: View {
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...100_000
    var step = 1
    var unit = ""

    var body: some View {
        HStack(spacing: Theme.s2) {
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
                .controlSize(.small)
            if !unit.isEmpty { Text(unit).font(Theme.caption).foregroundStyle(.secondary) }
        }
    }
}

/// A folder: the path, and a Choose… button that opens the system panel.
struct FolderField: View {
    @Binding var path: String
    var placeholder = "home folder"

    var body: some View {
        HStack(spacing: Theme.s2) {
            TextField(placeholder, text: $path)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.canCreateDirectories = true
                if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
                if panel.runModal() == .OK, let url = panel.url {
                    path = (url.path as NSString).abbreviatingWithTildeInPath
                }
            }
            .controlSize(.small)
        }
    }
}

/// Seven chips, Monday first; `Calendar` weekday numbers (Sunday is 1).
struct WeekdayPicker: View {
    @Binding var days: Set<Int>
    private let order: [(Int, String)] = [(2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat"), (1, "Sun")]

    var body: some View {
        HStack(spacing: Theme.s1) {
            ForEach(order, id: \.0) { day, name in
                let on = days.contains(day)
                Button {
                    if on { days.remove(day) } else { days.insert(day) }
                } label: {
                    Text(name)
                        .font(.system(size: 11, weight: on ? .semibold : .regular, design: .rounded))
                        .padding(.horizontal, Theme.s2)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(on ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.05)))
                        .foregroundStyle(on ? Theme.accent : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A time of day as the system's own time field; `minutes` is minutes after midnight.
struct TimeField: View {
    @Binding var minutes: Int

    private var date: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date() },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }

    var body: some View {
        DatePicker("", selection: date, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.field)
            .controlSize(.small)
    }
}

/// The weekday names and clock the `schedule` command takes: `mon,wed 09:00`.
enum WeekTime {
    static let names: [Int: String] = [1: "sun", 2: "mon", 3: "tue", 4: "wed", 5: "thu", 6: "fri", 7: "sat"]

    static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60) }

    static func weekly(days: Set<Int>, minutes: Int) -> String {
        let order = [2, 3, 4, 5, 6, 7, 1]
        return order.filter { days.contains($0) }.compactMap { names[$0] }.joined(separator: ",") + " " + clock(minutes)
    }

    static func parseWeekly(_ s: String) -> (days: Set<Int>, minutes: Int)? {
        let parts = s.split(separator: " ")
        guard parts.count == 2, let minutes = Schedules.timeOfDay(String(parts[1])), let days = Schedules.weekdays(parts[0]) else { return nil }
        return (days, minutes)
    }
}

/// The size a sheet may take: most of the window, never more than it, so a long form scrolls in a tall
/// sheet instead of a short box in the middle of a big window. Measured against the main window, never
/// the sheet itself (once a sheet is up it is the key window, and measuring it shrank the sheet on every
/// redraw), and taken once when the sheet opens (`SheetFrame`, `CommandPalette`), so it never changes size
/// while you type.
enum SheetSize {
    /// The window the sheet hangs from.
    private static var host: NSWindow? {
        let w = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.sheetParent == nil }
        return w?.sheetParent ?? w
    }

    static func height(ideal: CGFloat, min minimum: CGFloat = 380) -> CGFloat {
        let room = (host?.contentView?.bounds.height ?? 780) - 72
        return max(minimum, Swift.min(ideal, room))
    }

    static func width(ideal: CGFloat) -> CGFloat {
        let room = (host?.contentView?.bounds.width ?? 1200) - 96
        return max(440, Swift.min(ideal, room))
    }
}

/// The Help tab: an agent in the folder that holds apprentice's docs, told to answer the user's questions
/// from them and change nothing. Claude Code when it is installed; otherwise the CLI's own help.
enum HelpTab {
    static let prompt = """
    You are the help desk for apprentice, a macOS tool that lets coding agents use apps and websites through the \
    screen the way a person does. The person asking is its user, not a developer, and may know nothing about it. \
    Answer their questions about using apprentice by reading the docs in this folder (README.md, SPEC.md, FEATURES.md, \
    agent/, skills/, playbooks/) and `apprentice --help`. Give the exact command when one answers the question. \
    Keep answers short and plain, with no jargon. Never change a file and never run apprentice commands that act on \
    the screen; this is a read-only help session.
    """

    static var dir: URL { Repo.resources }

    static let command = "cd \"$APPRENTICE_HELP_DIR\" && if command -v claude >/dev/null 2>&1; then exec claude --append-system-prompt \"$APPRENTICE_HELP\"; "
        + "else echo 'Help needs Claude Code (claude) on this Mac. Meanwhile, the built-in help:'; echo; apprentice --help; exec \"$SHELL\" -l; fi"

    static var env: [String: String] { ["APPRENTICE_HELP_DIR": dir.path, "APPRENTICE_HELP": prompt] }
}
