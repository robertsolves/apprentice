import AppKit
import SwiftUI

/// Markdown colouring by hand, since the app has no package dependencies: headings, bold, lists, links, code and
/// front matter. Pure, so `selftest` can check it. Offsets are UTF-16, as `NSTextStorage` counts.
enum MarkdownStyle {
    enum Kind: Equatable { case heading, bold, list, link, code, frontMatter, section }

    struct Span: Equatable {
        var kind: Kind
        var location: Int
        var length: Int
    }

    private static let inline: [(Kind, NSRegularExpression?)] = [
        (.bold, try? NSRegularExpression(pattern: #"\*\*[^*\n]+\*\*|__[^_\n]+__"#)),
        (.code, try? NSRegularExpression(pattern: #"`[^`\n]+`"#)),
        (.link, try? NSRegularExpression(pattern: #"\[[^\]\n]+\]\([^)\n]+\)"#)),
    ]

    static func spans(_ text: String) -> [Span] {
        var out: [Span] = []
        let ns = text as NSString
        var inFront = false, inFence = false, frontOpen = true
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let line = ns.substring(with: range)
            defer { if !line.trimmingCharacters(in: .whitespaces).isEmpty { frontOpen = false } }
            if line == "---", frontOpen || inFront {
                inFront.toggle()
                out.append(Span(kind: .frontMatter, location: range.location, length: range.length))
                return
            }
            if inFront { out.append(Span(kind: .frontMatter, location: range.location, length: range.length)); return }
            if line.hasPrefix("```") {
                inFence.toggle()
                out.append(Span(kind: .code, location: range.location, length: range.length))
                return
            }
            if inFence { out.append(Span(kind: .code, location: range.location, length: range.length)); return }
            if line.hasPrefix("#") {
                let hashes = line.prefix { $0 == "#" }.count
                if hashes <= 6, line.dropFirst(hashes).first == " " {
                    out.append(Span(kind: .heading, location: range.location, length: range.length))
                    return
                }
            }
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            let indent = line.count - trimmed.count
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                out.append(Span(kind: .list, location: range.location + indent, length: 1))
            } else if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber), !trimmed[..<dot].isEmpty, trimmed[dot...].hasPrefix(". ") {
                out.append(Span(kind: .list, location: range.location + indent, length: trimmed.distance(from: trimmed.startIndex, to: dot) + 1))
            }
            for (kind, re) in inline {
                re?.enumerateMatches(in: text, range: range) { m, _, _ in
                    if let m { out.append(Span(kind: kind, location: m.range.location, length: m.range.length)) }
                }
            }
        }
        // Apprentice's own section of AGENTS.md, tinted whole.
        let start = ns.range(of: ProjectFiles.startMark), end = ns.range(of: ProjectFiles.endMark)
        if start.location != NSNotFound, end.location != NSNotFound, end.location > start.location {
            out.append(Span(kind: .section, location: start.location, length: end.location + end.length - start.location))
        }
        return out
    }

    static func apply(to storage: NSTextStorage, font: NSFont) {
        let all = NSRange(location: 0, length: storage.length)
        storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: all)
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        for span in spans(storage.string) {
            let r = NSRange(location: span.location, length: span.length)
            guard NSMaxRange(r) <= storage.length else { continue }
            switch span.kind {
            case .heading: storage.addAttributes([.font: bold, .foregroundColor: NSColor.controlAccentColor], range: r)
            case .bold: storage.addAttributes([.font: bold], range: r)
            case .list: storage.addAttributes([.foregroundColor: NSColor.systemOrange], range: r)
            case .link: storage.addAttributes([.foregroundColor: NSColor.linkColor], range: r)
            case .code: storage.addAttributes([.foregroundColor: NSColor.systemPurple], range: r)
            case .frontMatter: storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor], range: r)
            case .section: storage.addAttributes([.backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.08)], range: r)
            }
        }
    }
}

/// A plain-text editor with `MarkdownStyle` colouring.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var editable = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.isEditable = editable
        view.string = text
        context.coordinator.recolour(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        view.isEditable = editable
        if view.string != text {
            view.string = text
            context.coordinator.recolour(view)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        init(_ parent: MarkdownEditor) { self.parent = parent }

        func recolour(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            MarkdownStyle.apply(to: storage, font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        }

        func textDidChange(_ note: Notification) {
            guard let view = note.object as? NSTextView else { return }
            parent.text = view.string
            recolour(view)
        }
    }
}

/// Instructions: what agents read in this project. `AGENTS.md` and its imports can be edited, apprentice's section is
/// marked, and generated files are shown read-only with a link to their original.
struct InstructionsView: View {
    @ObservedObject var model: AppModel
    let project: Projects.Info
    @State private var selected = "AGENTS.md"
    @State private var text = ""
    @State private var original = ""
    @State private var changedOnDisk = false
    @State private var edited: [String] = []
    @State private var generated: [String] = []
    @State private var saved = ""

    private let own = ["AGENTS.md", "CLAUDE.md", "GEMINI.md"]
    private var isGenerated: Bool { generated.contains(selected) }
    private var file: URL { project.folder.appendingPathComponent(selected) }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { selected }, set: { if let v = $0 { select(v) } })) {
                SwiftUI.Section("Agents read these") {
                    ForEach(own, id: \.self) { Text($0).font(Theme.body).tag($0) }
                }
                SwiftUI.Section("Made by apprentice") {
                    ForEach(generated, id: \.self) { name in
                        Text(name).font(Theme.caption).lineLimit(1).truncationMode(.head).tag(name)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 240)
            Divider()
            VStack(alignment: .leading, spacing: Theme.s2) {
                HStack(spacing: Theme.s2) {
                    Text(selected).font(Theme.heading)
                    if isGenerated { StatusPill(text: "Read only", tint: .secondary) }
                    Spacer()
                    if !saved.isEmpty { Text(saved).font(Theme.caption).foregroundStyle(.secondary) }
                    if isGenerated {
                        IconButton("Edit the original", "arrow.right.circle") { openOriginal() }.controlSize(.small)
                    } else {
                        IconButton("Save", "checkmark", prominent: true) { save() }
                            .controlSize(.small).keyboardShortcut("s", modifiers: .command).disabled(text == original)
                    }
                }
                if selected == "AGENTS.md", ProjectFiles.split(text) != nil {
                    Text("The tinted part is apprentice's: it keeps it up to date, and the rest is yours. If you change it, apprentice asks before replacing it.")
                        .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if changedOnDisk {
                    HStack(spacing: Theme.s2) {
                        Text("This file changed on disk while you were editing it.").font(Theme.caption).foregroundStyle(Theme.warn)
                        Button("Use the file's") { select(selected) }.controlSize(.small)
                        Button("Keep mine and save") { changedOnDisk = false; write() }.controlSize(.small)
                    }
                }
                if !edited.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
                        Text("Changed by hand, so apprentice left them alone: \(edited.joined(separator: ", "))").font(Theme.caption).foregroundStyle(Theme.warn)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Keep mine") { sync("--keep-mine") }.controlSize(.small)
                        Button("Use apprentice's") { sync("--take-new") }.controlSize(.small)
                    }
                }
                MarkdownEditor(text: $text, editable: !isGenerated)
                    .id(selected)
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.hairline))
            }
            .padding(Theme.s4)
        }
        .background(Theme.canvas)
        .onAppear { refreshLists(); select(selected) }
    }

    private func refreshLists() {
        edited = ProjectFiles.edited(project.folder)
        generated = ProjectFiles.load(project.folder).files.keys.sorted()
    }

    private func select(_ name: String) {
        selected = name
        let content = (try? String(contentsOf: project.folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
        text = content
        original = content
        changedOnDisk = false
        saved = ""
    }

    private func save() {
        let now = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        // Someone or something else wrote it meanwhile: compare, never overwrite.
        guard now == original else { changedOnDisk = true; return }
        write()
    }

    private func write() {
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
            original = text
            saved = "saved \(Date().formatted(date: .omitted, time: .shortened))"
            refreshLists()
        } catch { saved = error.localizedDescription }
    }

    private func sync(_ flag: String) {
        model.runCLI(["project", "sync", project.folder.path, flag]) { _, _ in
            refreshLists()
            select(selected)
        }
    }

    /// Generated files say where their original is; the built-in ones have none to edit, so their skills folder opens.
    private func openOriginal() {
        let content = text
        var target = project.folder.appendingPathComponent(".apprentice")
        if let r = content.range(of: "from "), let end = content[r.upperBound...].range(of: ": edit that one") {
            let path = String(content[r.upperBound..<end.lowerBound])
            if path.hasPrefix(".apprentice/") { target = project.folder.appendingPathComponent(path) }
        }
        NSWorkspace.shared.open(target)
    }
}
