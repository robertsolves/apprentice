import AppKit
import ApplicationServices

struct Element: Codable {
    var id: Int
    var path: [Int]
    var label: String
    var name: String
    var value: String?
    var frame: [Double]
    var offscreen: Bool
    var gated: Bool

    var rect: CGRect { CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]) }
    var key: String { "\(label)|\(name)" }

    var line: String {
        var s = "\(id) \(label) \"\(name)\""
        if let value { s += " value=\"\(value)\"" }
        if offscreen { s += " (off)" }
        if gated { s += " [gated]" }
        return s
    }
}

struct Snapshot: Codable {
    var snap: Int
    var scope: String
    var url: String?
    var title: String
    var total: Int
    var elements: [Element]
}

enum Kind { case input, control, text, heading, image }

func classify(_ role: String, _ subrole: String?) -> (label: String, kind: Kind)? {
    switch role {
    case "AXButton": return ("button", .control)
    case "AXLink": return ("link", .control)
    case "AXTextField":
        if subrole == "AXSearchField" { return ("searchbox", .input) }
        if subrole == "AXSecureTextField" { return ("password", .input) }
        return ("textbox", .input)
    case "AXTextArea": return ("textarea", .input)
    case "AXComboBox": return ("combobox", .input)
    case "AXCheckBox": return ("checkbox", .control)
    case "AXRadioButton": return (subrole == "AXTabButton" ? "tab" : "radio", .control)
    case "AXPopUpButton": return ("popup", .control)
    case "AXMenuButton": return ("menubutton", .control)
    case "AXMenuItem": return ("menuitem", .control)
    case "AXDisclosureTriangle": return ("disclosure", .control)
    case "AXSlider": return ("slider", .control)
    case "AXHeading": return ("heading", .heading)
    case "AXImage": return ("image", .image)
    case "AXStaticText": return ("text", .text)
    default: return nil
    }
}

func clip(_ s: String, _ n: Int) -> String {
    let flat = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "'")
        .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    return flat.count > n ? String(flat.prefix(n)) + "…" : flat
}

/// Text of an element's descendants, for links and buttons that carry no name of their own.
func deepText(_ children: [AXUIElement], budget: Int = 10) -> String {
    var words: [String] = []
    var stack = Array(children.reversed())
    var seen = 0
    while let el = stack.popLast(), words.count < budget, seen < 200 {
        seen += 1
        let i = info(el)
        if i.role == "AXStaticText", let v = i.value.flatMap(stringify) ?? i.title {
            words += v.split(separator: " ").map(String.init)
        } else if i.role == "AXImage", let d = i.desc, !d.isEmpty {
            words.append(d)
        } else {
            stack.append(contentsOf: i.children.reversed())
        }
    }
    return words.prefix(budget).joined(separator: " ")
}

func elementName(_ i: Info, _ kind: Kind) -> String {
    let candidates: [String?]
    switch kind {
    case .text: candidates = [i.value.flatMap(stringify), i.title]
    case .input: candidates = [i.title, i.desc, i.placeholder]
    default: candidates = [i.title, i.desc]
    }
    var name = candidates.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    if name.isEmpty, kind == .control || kind == .heading { name = deepText(i.children) }
    return clip(name, kind == .text ? 100 : 60)
}

final class Walker {
    let bounds: CGRect
    let includeOffscreen: Bool
    var out: [Element] = []
    var visited = 0

    init(bounds: CGRect, includeOffscreen: Bool) {
        self.bounds = bounds
        self.includeOffscreen = includeOffscreen
    }

    func walk(_ el: AXUIElement, path: [Int], depth: Int) {
        visited += 1
        guard visited < 40000, depth < 90 else { return }
        let i = info(el)
        let onscreen = i.frame.map { $0.width > 0 && $0.height > 0 && $0.intersects(bounds) } ?? false
        if let (label, kind) = classify(i.role, i.subrole) {
            let name = elementName(i, kind)
            let keep = !name.isEmpty || kind == .input
            if keep, onscreen || includeOffscreen, let f = i.frame {
                var value: String?
                if kind == .input, label != "password" { value = clip(i.value.flatMap(stringify) ?? "", 40) }
                if label == "checkbox" || label == "radio" || label == "tab" {
                    value = i.value.flatMap(stringify) == "1" ? "on" : "off"
                }
                out.append(Element(
                    id: 0, path: path, label: label, name: name, value: value,
                    frame: [f.minX, f.minY, f.width, f.height].map { Double($0) },
                    offscreen: !onscreen, gated: kind == .control && Gate.matches(name)))
            }
            return  // a named control owns its subtree; its text is already in its name
        }
        // Skip subtrees whose box lies wholly outside the view.
        if !includeOffscreen, let f = i.frame, f.width > 0, f.height > 0, !f.intersects(bounds) { return }
        for (n, child) in i.children.enumerated() { walk(child, path: path + [n], depth: depth + 1) }
    }
}

struct Target {
    let pid: pid_t
    let app: AXUIElement
    let window: AXUIElement
    let root: AXUIElement
    let scope: String
    let bounds: CGRect
    let url: String?
    let title: String
}

func locate(_ session: Session, scope wanted: String? = nil) throws -> Target {
    let app = appElement(session.pid)
    guard let window = windows(of: app).first(where: { $0.windowID == session.wid }) else {
        throw Fail(5, "window \(session.wid) not found: it may be closed, minimised or on another Space. Run `deskkontrol session` again")
    }
    let title = window.string(kAXTitleAttribute) ?? ""
    let wframe = window.frame ?? .zero
    if wanted != "window", let web = findFirst(window, where: { $0.role == "AXWebArea" }) {
        let wb = web.frame.map { $0.intersection(wframe) } ?? wframe
        return Target(pid: session.pid, app: app, window: window, root: web, scope: "web",
                      bounds: wb.isNull ? wframe : wb, url: web.string("AXURL"), title: title)
    }
    return Target(pid: session.pid, app: app, window: window, root: window, scope: "window",
                  bounds: wframe, url: nil, title: title)
}

func readSnapshot(_ t: Target, includeOffscreen: Bool = false) -> Snapshot {
    let walker = Walker(bounds: t.bounds, includeOffscreen: includeOffscreen)
    walker.walk(t.root, path: [], depth: 0)
    var elements = walker.out
    for n in elements.indices { elements[n].id = n + 1 }
    let next = (Store.load(Snapshot.self, "snap.json")?.snap ?? 0) + 1
    return Snapshot(snap: next, scope: t.scope, url: t.url, title: t.title, total: elements.count, elements: elements)
}

func walkPath(_ root: AXUIElement, _ path: [Int]) -> AXUIElement? {
    var cur = root
    for n in path {
        let kids = cur.children
        guard n < kids.count else { return nil }
        cur = kids[n]
    }
    return cur
}

/// Finds a snapshot element again; falls back to a unique role+name match if the tree shifted.
func resolve(_ id: Int, _ t: Target) throws -> (AXUIElement, Element) {
    guard let snap = Store.load(Snapshot.self, "snap.json") else { throw Fail(2, "stale: no snapshot, run `deskkontrol read`") }
    guard let e = snap.elements.first(where: { $0.id == id }) else { throw Fail(5, "no element \(id) in snap \(snap.snap)") }
    if let el = walkPath(t.root, e.path) {
        let i = info(el)
        if let (label, kind) = classify(i.role, i.subrole), label == e.label, elementName(i, kind) == e.name {
            return (el, e)
        }
    }
    let fresh = Walker(bounds: t.bounds, includeOffscreen: true)
    fresh.walk(t.root, path: [], depth: 0)
    let matches = fresh.out.filter { $0.key == e.key }
    if matches.count == 1, let el = walkPath(t.root, matches[0].path) {
        var moved = matches[0]
        moved.id = e.id
        return (el, moved)
    }
    throw Fail(2, "stale: element \(id) \(e.label) \"\(e.name)\" changed, re-read")
}

func header(_ s: Snapshot, app: String, shown: Int) -> String {
    let place = s.url.map { $0.replacingOccurrences(of: "https://", with: "") } ?? s.title
    return "snap \(s.snap) · \(app) · \(clip(place, 80)) · \(shown) of \(s.total) shown"
}

/// Waits for the tree to stop changing, then returns the new snapshot.
func settle(_ t: Target, maxWait: Double = 4) -> Snapshot {
    let start = Date()
    usleep(350_000)
    var last = readSnapshot(t)
    while Date().timeIntervalSince(start) < maxWait {
        usleep(300_000)
        let next = readSnapshot(t)
        if next.elements.map(\.key) == last.elements.map(\.key) { return next }
        last = next
    }
    return last
}

func diff(_ old: Snapshot?, _ new: Snapshot, limit: Int = 25) -> [String] {
    var before: [String: Int] = [:]
    for e in old?.elements ?? [] { before[e.key, default: 0] += 1 }
    var after: [String: Int] = [:]
    for e in new.elements { after[e.key, default: 0] += 1 }
    var lines: [String] = []
    var seen: [String: Int] = [:]
    for e in new.elements {
        seen[e.key, default: 0] += 1
        if seen[e.key]! > (before[e.key] ?? 0) { lines.append("+ " + e.line) }
    }
    var removed: [String: Int] = [:]
    for e in old?.elements ?? [] {
        removed[e.key, default: 0] += 1
        if removed[e.key]! > (after[e.key] ?? 0) { lines.append("- \(e.label) \"\(e.name)\"") }
    }
    if lines.count > limit { return Array(lines.prefix(limit)) + ["… \(lines.count - limit) more, run `deskkontrol read`"] }
    return lines
}
