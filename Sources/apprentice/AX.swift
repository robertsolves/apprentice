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

    var actionNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(self, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

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
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
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

func appElement(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

/// Chrome and Electron build their web accessibility tree only when asked.
func enableWebAccessibility(_ app: AXUIElement) {
    app.set("AXManualAccessibility", kCFBooleanTrue)
    app.set("AXEnhancedUserInterface", kCFBooleanTrue)
}

func windows(of app: AXUIElement) -> [AXUIElement] {
    app.attr(kAXWindowsAttribute) as? [AXUIElement] ?? []
}

/// Breadth-first search, bounded so a huge tree can't stall the caller.
func findFirst(_ root: AXUIElement, limit: Int = 4000, where match: (Info) -> Bool) -> AXUIElement? {
    var queue = [root]
    var seen = 0
    while !queue.isEmpty, seen < limit {
        let el = queue.removeFirst()
        seen += 1
        let i = info(el)
        if match(i) { return el }
        queue.append(contentsOf: i.children)
    }
    return nil
}
