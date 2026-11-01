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
    var short: String { "\(id) \(label) \"\(name)\"" }

    var line: String {
        var s = short
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

    func walk(_ el: AXUIElement, path: [Int], depth: Int, fieldValue: String? = nil) {
        visited += 1
        guard visited < 40000, depth < 90 else { return }
        let i = info(el)
        // Text inside a field that repeats its value; anything else in there (suggestions) is kept.
        if let fieldValue, i.role == "AXStaticText", let t = i.value.flatMap(stringify) ?? i.title,
           fieldValue.contains(t) { return }
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
            // A named button or link owns its subtree: its text is already in its name. Fields and
            // popups do not, since suggestion lists and menus can hang off them as children.
            if kind != .input, label != "popup", label != "menubutton" { return }
        }
        // Skip subtrees whose box lies wholly outside the view.
        if !includeOffscreen, let f = i.frame, f.width > 0, f.height > 0, !f.intersects(bounds) { return }
        let value = classify(i.role, i.subrole)?.kind == .input ? (i.value.flatMap(stringify) ?? "") : fieldValue
        for (n, child) in i.children.enumerated() { walk(child, path: path + [n], depth: depth + 1, fieldValue: value) }
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
    // A fresh daemon must turn Chrome's web accessibility back on before it lists its windows.
    let find = { windows(of: app).first(where: { $0.windowID == session.wid }) }
    var found = find()
    if found == nil {
        // After a daemon restart Chrome lists no windows until web accessibility is back on and it is active.
        enableWebAccessibility(app)
        NSRunningApplication(processIdentifier: session.pid)?.activate()
        found = poll(timeout: 2, find)
    }
    guard let window = found else {
        throw Fail(5, "window \(session.wid) not found: it may be closed, minimised or on another Space. Run `apprentice session` again")
    }
    let title = window.string(kAXTitleAttribute) ?? ""
    let wframe = window.frame ?? .zero
    // A modal sheet (save or open panel, alert) covers the page, so it is what a person sees and acts on.
    // Nested sheets, such as Go to Folder inside a file picker, win over their parent.
    if wanted != "window", var sheet = window.children.first(where: { $0.string(kAXRoleAttribute) == "AXSheet" }) {
        while let inner = sheet.children.first(where: { $0.string(kAXRoleAttribute) == "AXSheet" }) { sheet = inner }
        return Target(pid: session.pid, app: app, window: window, root: sheet, scope: "sheet",
                      bounds: sheet.frame ?? wframe, url: nil, title: title)
    }
    // A browser page still loading may not expose its web area yet; give it a moment, so its URL
    // (and the allowlist check on it) is not missed (B11).
    let webArea = findFirst(window, where: { $0.role == "AXWebArea" })
        ?? (session.isBrowser && wanted != "window" ? poll(timeout: 1.5) { findFirst(window, where: { $0.role == "AXWebArea" }) } : nil)
    if wanted != "window", let web = webArea {
        let wb = web.frame.map { $0.intersection(wframe) } ?? wframe
        return Target(pid: session.pid, app: app, window: window, root: web, scope: "web",
                      bounds: wb.isNull ? wframe : wb, url: web.string("AXURL"), title: title)
    }
    return Target(pid: session.pid, app: app, window: window, root: window, scope: "window",
                  bounds: wframe, url: nil, title: title)
}

enum SnapshotCache {
    static var wid: CGWindowID = 0
    static var at = Date.distantPast
    static var snap: Snapshot?

    static func take(_ wid: CGWindowID) -> Snapshot? {
        guard let snap, wid == self.wid, Date().timeIntervalSince(at) < 0.3 else { return nil }
        return snap
    }

    static func put(_ wid: CGWindowID, _ snapshot: Snapshot) {
        self.wid = wid
        snap = snapshot
        at = Date()
    }

    static func invalidate() { snap = nil }
}

/// Owns snap.json. The daemon is its only writer, so the last snapshot stays in memory.
enum SnapStore {
    private static var loaded = false
    private static var last: Snapshot?
    private static var counter = 0

    static var current: Snapshot? {
        if !loaded {
            last = Store.load(Snapshot.self, "snap.json")
            counter = last?.snap ?? 0
            loaded = true
        }
        return last
    }

    static func next() -> Int {
        _ = current
        return counter + 1
    }

    /// Callers that also want the snapshot cached put it back after saving.
    static func save(_ snapshot: Snapshot) {
        Store.save(snapshot, "snap.json")
        (last, counter, loaded) = (snapshot, snapshot.snap, true)
        SnapshotCache.invalidate()
    }

    static func clear() {
        Store.remove("snap.json")
        (last, counter, loaded) = (nil, 0, true)
        SnapshotCache.invalidate()
    }
}

func readSnapshotCached(_ t: Target, wid: CGWindowID) -> Snapshot {
    if let cached = SnapshotCache.take(wid) { return cached }
    let snapshot = readSnapshot(t)
    SnapStore.save(snapshot)
    SnapshotCache.put(wid, snapshot)
    return snapshot
}

func readSnapshot(_ t: Target, includeOffscreen: Bool = false) -> Snapshot {
    let walker = Walker(bounds: t.bounds, includeOffscreen: includeOffscreen)
    walker.walk(t.root, path: [], depth: 0)
    var elements = walker.out
    for n in elements.indices { elements[n].id = n + 1 }
    return Snapshot(snap: SnapStore.next(), scope: t.scope, url: t.url, title: t.title, total: elements.count, elements: elements)
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
func resolve(_ id: Int, _ t: Target) throws -> (AXUIElement?, Element) {
    guard let snap = SnapStore.current else { throw Fail(2, "stale: no snapshot, run `apprentice read`") }
    guard let e = snap.elements.first(where: { $0.id == id }) else { throw Fail(5, "no element \(id) in snap \(snap.snap)") }
    // OCR elements have no AX path; the caller clicks their box directly.
    if e.path.isEmpty { return (nil, e) }
    if let el = walkPath(t.root, e.path) {
        let i = info(el)
        if let (label, kind) = classify(i.role, i.subrole), label == e.label, elementName(i, kind) == e.name {
            // Take the live frame: a page that scrolled or reflowed since the read would otherwise
            // be clicked at its old coordinates.
            var live = e
            if let f = i.frame { live.frame = [f.minX, f.minY, f.width, f.height].map(Double.init) }
            return (el, live)
        }
    }
    let fresh = Walker(bounds: t.bounds, includeOffscreen: true)
    fresh.walk(t.root, path: [], depth: 0)
    let matches = fresh.out.filter { $0.key == e.key && !$0.path.isEmpty }
    if matches.count == 1, let el = walkPath(t.root, matches[0].path) {
        var moved = matches[0]
        moved.id = e.id
        return (el, moved)
    }
    throw Fail(2, "stale: element \(e.short) changed, re-read")
}

func header(_ s: Snapshot, app: String, shown: Int) -> String {
    let place = s.url.map { $0.replacingOccurrences(of: "https://", with: "") } ?? s.title
    return "snap \(s.snap) · \(app) · \(clip(place, 80)) · \(shown) of \(s.total) shown"
}

/// Waits for the tree to stop changing, then returns the new snapshot.
func settle(_ t: Target, maxWait: Double = 4) -> Snapshot {
    let start = Date()
    Pace.sleep(0.1)
    var last = readSnapshot(t)
    while Date().timeIntervalSince(start) < maxWait {
        Pace.sleep(0.15)
        let next = readSnapshot(t)
        // Values count too: a field still filling in or a counter still moving is not settled (B15).
        if next.elements.map({ $0.key + "|" + ($0.value ?? "") }) == last.elements.map({ $0.key + "|" + ($0.value ?? "") }) { return next }
        last = next
    }
    return last
}

struct DiffResult {
    var added: [String] = []
    var removed: [String] = []
    var changed: [String] = []
    var summary: String { "+\(added.count) -\(removed.count) ~\(changed.count)" }
    var lines: [String] { added.map { "+ " + $0 } + removed.map { "- " + $0 } + changed.map { "~ " + $0 } }
}

func diff(_ old: Snapshot?, _ new: Snapshot) -> DiffResult {
    var buckets: [String: [Element]] = [:]
    for e in old?.elements ?? [] { buckets[e.key, default: []].append(e) }
    var out = DiffResult()
    for e in new.elements {
        if var list = buckets[e.key], !list.isEmpty {
            let previous = list.removeFirst()
            buckets[e.key] = list
            var notes: [String] = []
            if previous.value != e.value {
                notes.append(e.value.map { "value=\"\($0)\"" } ?? "value cleared")
            }
            if previous.gated != e.gated { notes.append(e.gated ? "[gated]" : "not gated") }
            if previous.offscreen != e.offscreen { notes.append(e.offscreen ? "offscreen" : "onscreen") }
            if !notes.isEmpty { out.changed.append("\(e.id) \(e.label) \"\(e.name)\" \(notes.joined(separator: " "))") }
        } else {
            out.added.append(e.line)
        }
    }
    // Leftovers in the old snapshot's order, so the same change always prints the same way (B22).
    for e in old?.elements ?? [] where !(buckets[e.key] ?? []).isEmpty {
        buckets[e.key]?.removeFirst()
        out.removed.append("\(e.label) \"\(e.name)\"")
    }
    return out
}
