import AppKit
import ApplicationServices

// Private but stable since 10.x; maps an AX window to its CGWindowID. Used by most window managers.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    func attr(_ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ name: String) -> String? {
        guard let value = attr(name) else { return nil }
        return stringify(value)
    }

    var children: [AXUIElement] { attr(kAXChildrenAttribute) as? [AXUIElement] ?? [] }

    var frame: CGRect? {
        guard let p = attr(kAXPositionAttribute), let s = attr(kAXSizeAttribute) else { return nil }
        return makeFrame(p, s)
    }

    @discardableResult
    func set(_ name: String, _ value: AnyObject) -> AXError {
        AXUIElementSetAttributeValue(self, name as CFString, value)
    }

    @discardableResult
    func perform(_ action: String) -> AXError {
        AXUIElementPerformAction(self, action as CFString)
    }

    var windowID: CGWindowID? {
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(self, &wid) == .success ? wid : nil
    }

    var pid: pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(self, &p)
        return p
    }
}

func stringify(_ value: AnyObject) -> String? {
    if let s = value as? String { return s }
    if CFGetTypeID(value) == CFURLGetTypeID() { return (value as! URL).absoluteString }
    if CFGetTypeID(value) == CFBooleanGetTypeID() { return CFBooleanGetValue((value as! CFBoolean)) ? "1" : "0" }
    if let n = value as? NSNumber { return n.stringValue }
    if let a = value as? NSAttributedString { return a.string }
    return nil
}

func makeFrame(_ p: AnyObject, _ s: AnyObject) -> CGRect? {
    guard CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    // A value of another kind would leave (0,0) and a click in the screen's corner: no frame instead (H3).
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}

/// Everything the reader needs from one element, fetched in a single IPC round trip.
struct Info {
    var role = ""
    var subrole: String?
    var title: String?
    var desc: String?
    var value: AnyObject?
    var placeholder: String?
    var frame: CGRect?
    var children: [AXUIElement] = []
}

private let infoNames = [
    kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
    kAXValueAttribute, "AXPlaceholderValue", kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute,
] as CFArray

func info(_ el: AXUIElement) -> Info {
    var out: CFArray?
    AXUIElementCopyMultipleAttributeValues(el, infoNames, AXCopyMultipleAttributeOptions(rawValue: 0), &out)
    let values = out as? [AnyObject] ?? []
    func get(_ i: Int) -> AnyObject? {
        guard i < values.count else { return nil }
        let v = values[i]
        if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
        return v
    }
    var i = Info()
    i.role = get(0) as? String ?? ""
    i.subrole = get(1) as? String
    i.title = get(2) as? String
    i.desc = get(3) as? String
    i.value = get(4)
    i.placeholder = get(5) as? String
    if let p = get(6), let s = get(7) { i.frame = makeFrame(p, s) }
    i.children = get(8) as? [AXUIElement] ?? []
    return i
}

private let searchNames = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXChildrenAttribute] as CFArray

/// Only what `findFirst` matches on, so a search doesn't copy every value (a text area's whole document) or frame.
private func searchInfo(_ el: AXUIElement) -> Info {
    var out: CFArray?
    AXUIElementCopyMultipleAttributeValues(el, searchNames, AXCopyMultipleAttributeOptions(rawValue: 0), &out)
    let values = out as? [AnyObject] ?? []
    func get(_ i: Int) -> AnyObject? { i < values.count ? values[i] : nil }
    var i = Info()
    i.role = get(0) as? String ?? ""
    i.subrole = get(1) as? String
    i.title = get(2) as? String
    i.children = get(3) as? [AXUIElement] ?? []
    return i
}

func appElement(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

/// Chrome and Electron build their web accessibility tree only when asked. Asked only of apps that
/// show web content: a browser, or an app built on Chromium or Electron. A native app reads without it,
/// and forcing it on there is a flag the app can see for no gain (BOT_DETECTION A3).
func enableWebAccessibility(_ app: AXUIElement, pid: pid_t) {
    guard showsWeb(pid) else { return }
    app.set("AXManualAccessibility", kCFBooleanTrue)
    app.set("AXEnhancedUserInterface", kCFBooleanTrue)
}

/// A browser, or an app that bundles Chromium or Electron. Unknown apps count, so nothing goes unread.
func showsWeb(_ pid: pid_t) -> Bool {
    guard let running = NSRunningApplication(processIdentifier: pid), let url = running.bundleURL else { return true }
    if let bundle = running.bundleIdentifier, Session.handlesWeb(bundle) { return true }
    let frameworks = (try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("Contents/Frameworks").path)) ?? []
    return frameworks.contains { $0.contains("Electron") || $0.contains("Chromium") || $0.contains("Chrome") || $0.contains("CEF") }
}

func windows(of app: AXUIElement) -> [AXUIElement] {
    app.attr(kAXWindowsAttribute) as? [AXUIElement] ?? []
}

/// Breadth-first search on role, subrole and title, bounded so a huge tree can't stall the caller.
func findFirst(_ root: AXUIElement, limit: Int = 4000, where match: (Info) -> Bool) -> AXUIElement? {
    // An index into the queue, not removeFirst, which made the search quadratic (B21).
    var queue = [root]
    var head = 0
    var seen = 0
    while head < queue.count, seen < limit {
        let el = queue[head]
        head += 1
        seen += 1
        let i = searchInfo(el)
        if match(i) { return el }
        queue.append(contentsOf: i.children)
    }
    return nil
}
