import AppKit
import SwiftUI

/// The Skills screen: what agents know, in three groups a person can tell apart at a glance. Yours (written
/// here), learned by apprentice (written as it works, unreviewed) and built in (shipped, read-only: a copy of
/// one becomes yours and takes its place).
struct SkillItem: Identifiable, Equatable {
    var id: String { url.path }
    var title: String
    var detail: String
    var origin: Skills.Origin
    var url: URL
    /// The path inside its kind's folder (`web/instagram.com.md`), which a copy of yours keeps.
    var path: String

    static func load() -> [SkillItem] {
        let skills = Playbooks.skills()
        // Each judgement skill is listed once, from wherever it won.
        let shown = Set(skills.map { $0.url.standardizedFileURL.path })
        let files = Playbooks.all().filter { !shown.contains($0.url.standardizedFileURL.path) }.map {
            SkillItem(title: $0.title, detail: kindLabel($0), origin: $0.origin, url: $0.url, path: $0.path)
        }
        let judgement = skills.map { s -> SkillItem in
            let own = s.url.path.hasPrefix(Skills.yoursDir.path)
            return SkillItem(title: s.note.meta["name"].map(prettyName) ?? prettyName(s.name), detail: "how a person behaves there",
                             origin: own ? .yours : .builtIn, url: s.url, path: s.note.path)
        }
        return files + judgement
    }

    static func prettyName(_ name: String) -> String {
        let bare = name.hasPrefix("apprentice-") ? String(name.dropFirst("apprentice-".count)) : name
        return bare.prefix(1).uppercased() + bare.dropFirst()
    }

    static func kindLabel(_ p: Playbooks.Playbook) -> String {
        switch p.meta["scope"] ?? "" {
        case "site": return "website · " + p.match.joined(separator: ", ")
        case "app": return "Mac app · " + p.match.joined(separator: ", ")
        case "flow": return "saved steps"
        case "topic": return "a kind of task"
        case "system": return p.match.contains("*") ? "everywhere" : "the system"
        default: return p.path
        }
    }

    var icon: String {
        switch origin {
        case .project: return "folder.fill"
        case .yours: return "person.fill"
        case .learned: return "sparkles"
        case .builtIn: return "shippingbox.fill"
        }
    }
}

struct SkillsView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var selected: String?
    @State private var adding = false
    @State private var items: [SkillItem] = []

    private var shown: [SkillItem] {
        guard !query.isEmpty else { return items }
        let needle = query.lowercased()
        return items.filter { $0.title.lowercased().contains(needle) || $0.detail.lowercased().contains(needle) || $0.path.lowercased().contains(needle) }
    }

    var body: some View {
        SplitPane(id: "skills", help: .skills) {
            VStack(spacing: 0) {
                HStack(spacing: Theme.s2) {
                    TextField("Search", text: $query).textFieldStyle(.roundedBorder).controlSize(.small)
                    Button { adding = true } label: { Label("New", systemImage: "plus") }.controlSize(.small)
                }
                .padding(.horizontal, Theme.s3)
                .padding(.vertical, Theme.s2)
                Divider()
                List(selection: $selected) {
                    ForEach(Skills.Origin.allCases, id: \.self) { origin in
                        let group = shown.filter { $0.origin == origin }
                        if !group.isEmpty {
                            SwiftUI.Section(header: Text(groupTitle(origin)).eyebrow()) {
                                ForEach(group) { item in IconRow(icon: item.icon, title: item.title, detail: item.detail).tag(item.id) }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        } right: {
            if let id = selected, let item = items.first(where: { $0.id == id }) {
                SkillEditor(model: model, item: item) { reload(select: $0) }.id(item.id)
            } else {
                ScreenPage(title: Section.skills.label, subtitle: "") {
                    AnyView(HStack(spacing: Theme.s2) {
                        IconButton("Show the folders", "folder") { NSWorkspace.shared.open(Skills.root) }
                        IconButton("New skill", "plus", prominent: true) { adding = true }
                    })
                } content: {
                    Explainer.skills
                    Panel(title: "How apprentice learns") {
                        Text("When a task works, apprentice saves its steps; when saved steps break and the agent finishes by hand, it saves the repaired steps; and an agent can save one-line facts about a site or app. Each learned skill is small: at most \(Skills.maxFacts) facts or \(Skills.maxSteps) steps, and at most \(Skills.maxLearned) learned skills in all, the least used removed first.")
                            .font(Theme.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .background(Theme.canvas)
        .onAppear { reload() }
        .onChange(of: model.revision) { _, _ in if items.isEmpty { reload() } }
        .sheet(isPresented: $adding) {
            NewPlaybookSheet(model: model) { created in
                adding = false
                if let created { reload(select: Skills.yoursDir.appendingPathComponent(created).path) }
            }
        }
    }

    private func groupTitle(_ origin: Skills.Origin) -> String {
        switch origin {
        case .project: return "This project's"
        case .yours: return "Yours"
        case .learned: return "Learned by apprentice"
        case .builtIn: return "Built in"
        }
    }

    private func reload(select: String? = nil) {
        items = SkillItem.load()
        if let select { selected = select }
        else if let s = selected, !items.contains(where: { $0.id == s }) { selected = nil }
    }
}

/// One skill's text. Built in: read-only, with a copy that becomes yours. Learned and yours: edited in place,
/// and a learned one can be forgotten.
struct SkillEditor: View {
    @ObservedObject var model: AppModel
    let item: SkillItem
    var changed: (String?) -> Void
    @State private var text = ""
    @State private var saved = ""
    @State private var status = ""

    private var editable: Bool { item.origin != .builtIn }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            HStack(alignment: .top, spacing: Theme.s3) {
                Image(systemName: item.icon).font(.system(size: 20)).foregroundStyle(Theme.accent).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(Theme.title(17))
                    HStack(spacing: Theme.s2) {
                        StatusPill(text: item.origin.label, tint: Theme.accent, icon: item.icon)
                        Text(item.detail).font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if !status.isEmpty {
                    Text(status).font(Theme.caption).foregroundStyle(status.hasPrefix("not saved") ? Theme.danger : .secondary)
                }
            }
            Text(note).font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(Theme.mono)
                .scrollContentBackground(.hidden)
                .padding(Theme.s2)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline))
                .disabled(!editable)
            HStack(spacing: Theme.s2) {
                IconButton("Open in editor", "square.and.pencil") { NSWorkspace.shared.open(item.url) }
                Spacer()
                switch item.origin {
                case .builtIn:
                    IconButton("Make my own copy", "doc.on.doc", prominent: true) { copy() }
                case .learned:
                    IconButton("Forget it", "trash") { forget() }
                    IconButton("Save", "checkmark", prominent: true) { save() }
                        .keyboardShortcut("s", modifiers: .command).disabled(text == saved)
                case .yours, .project:
                    IconButton("Move to Trash", "trash") { forget() }
                    IconButton("Save", "checkmark", prominent: true) { save() }
                        .keyboardShortcut("s", modifiers: .command).disabled(text == saved)
                }
            }
            .controlSize(.small)
        }
        .padding(Theme.page)
        .background(Theme.canvas)
        .onAppear {
            saved = (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
            text = saved
        }
    }

    private var note: String {
        switch item.origin {
        case .builtIn: return "Comes with apprentice and is read-only here. Make my own copy to change it: your copy is used instead of this one."
        case .learned: return "apprentice wrote this while working, from what it did and saw. Agents use it as a hint. Tidy it, or forget it if it is wrong."
        case .yours: return "Written by you. Agents follow it. Keep names, handles and anything personal out."
        case .project: return "Kept in the project's folder and used only for that project's work. Agents follow it."
        }
    }

    private func save() {
        let leaks = Playbooks.leaks(text)
        guard leaks.isEmpty else {
            status = "not saved: looks personal (\(leaks.prefix(2).joined(separator: "; "))). Use {placeholders}."
            return
        }
        do {
            try text.write(to: item.url, atomically: true, encoding: .utf8)
            saved = text
            status = "saved"
        } catch {
            status = "not saved: \(error.localizedDescription)"
        }
    }

    private func copy() {
        // A judgement skill keeps its folder name, so the copy is found the same way.
        let target = Skills.yoursDir.appendingPathComponent(item.path.hasPrefix("skills/") ? String(item.path.dropFirst("skills/".count)) : item.path)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: target.path) { try text.write(to: target, atomically: true, encoding: .utf8) }
            changed(target.path)
        } catch {
            status = "not copied: \(error.localizedDescription)"
        }
    }

    private func forget() {
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            changed(nil)
        } catch {
            status = "not removed: \(error.localizedDescription)"
        }
    }
}

/// Two panes with a divider you drag; the width is kept per screen (`split.<id>`), so it stays when you pick
/// another item, change screens or relaunch. (SwiftUI's own split view put it back whenever the right pane
/// changed.)
struct SplitPane<Left: View, Right: View>: View {
    @AppStorage private var width: Double
    @State private var start: Double?
    @State private var helping = false
    let help: Explainer?
    let left: () -> Left
    let right: () -> Right

    init(id: String, ideal: Double = 290, help: Explainer? = nil, @ViewBuilder left: @escaping () -> Left, @ViewBuilder right: @escaping () -> Right) {
        _width = AppStorage(wrappedValue: ideal, "split.\(id)")
        self.help = help
        self.left = left
        self.right = right
    }

    var body: some View {
        HStack(spacing: 0) {
            left().frame(width: width).frame(maxHeight: .infinity)
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1)
                .overlay(
                    Color.clear
                        .frame(width: 9)
                        .contentShape(Rectangle())
                        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                if start == nil { start = width }
                                width = min(max((start ?? width) + drag.translation.width, 200), 560)
                            }
                            .onEnded { _ in start = nil })
                )
            right().frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    if let help {
                        Button { helping.toggle() } label: { Image(systemName: "questionmark.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("What is this?")
                            .padding(Theme.s3)
                            .popover(isPresented: $helping, arrowEdge: .bottom) { help.frame(width: 380).padding(Theme.s2) }
                    }
                }
        }
    }
}
