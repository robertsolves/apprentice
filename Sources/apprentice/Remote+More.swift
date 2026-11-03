import AppKit
import Foundation

/// The VM's file and screen commands: uploads and downloads (files cross over ssh, and the app's own
/// file dialog is driven with real keys), screenshots and OCR of the guest's screen, waiting for text,
/// dragging, and `show`, where the user points at something in the VM's screen.
extension Remote {
    /// Where files for uploads wait in the guest. Replaced on every upload, so it never piles up.
    static let inbox = "/tmp/apprentice-uploads"

    /// `[vm] local = ["linkedin.com"]`: sites whose accounts stay on this Mac's own browser, where they
    /// are used to it (SPEC.md, Consistency). The VM refuses them, so the work moves to a Mac session.
    static func keepLocal(_ url: String?) throws {
        guard let host = hostOf(url)?.lowercased(), let list = VM.settings["local"].flatMap(Toml.array) else { return }
        if let site = list.map({ $0.lowercased() }).first(where: { host == $0 || host.hasSuffix("." + $0) }) {
            throw Fail(4, "blocked: \(site) stays on this Mac's own browser ([vm] local). Do it from an agent session without APPRENTICE_VM, with `apprentice vm off`")
        }
    }

    // MARK: - files

    /// `upload <id> <path>`: the file goes into the guest, then the element's file dialog picks it, as a
    /// person would: a real click to open the dialog, ctrl+L, the path, return.
    static func upload(_ a: Args) throws -> String {
        guard let id = a.pos.first.flatMap(Int.init), a.pos.count >= 2 else { throw Fail(5, "upload <id> <path>") }
        let path = (a.pos.dropFirst().joined(separator: " ") as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { throw Fail(5, "file not found: \(path)") }
        guard !isDir.boolValue else { throw Fail(5, "\(path) is a folder: upload takes a file") }
        let (session, page, old) = try prepare()
        let e = try resolve(id)
        try gate(session, page, e, "upload \(path) through \(e.short)", warn: ["sends a file to \(hostOf(page.url) ?? session.app)"])
        try beforeAction(session, url: page.url)
        let name = (path as NSString).lastPathComponent
        let guestPath = "\(inbox)/\(name)"
        try push(path, to: guestPath)
        try act {
            // A dialog left open, say from an earlier attempt, is used as it is.
            if !dialogOpen() {
                try Commands.realClick(e.rect)
                guard poll(timeout: 6, { dialogOpen() ? true : nil }) != nil else {
                    throw Fail(5, "no file dialog appeared after clicking \(e.short): the page may take files by drag and drop, or the control is another element")
                }
            }
            try pick(guestPath)
        }
        return try done("upload", session, page, old, extra: ["uploaded \(path)"],
                        log: ["id": id, "path": path, "label": e.label, "name": e.name])
    }

    /// Types a path into an open file dialog and confirms it. The dialog belongs to the app, not the
    /// page, so the path goes in quickly; the page only sees the file it receives.
    static func pick(_ guestPath: String) throws {
        // A dialog appears before it can take keys; typed too soon, the path would go to the page.
        guard poll(timeout: 5, { (try? query(["op": "dialog"]))?["active"] as? Bool == true ? true : nil }) != nil else {
            throw Fail(5, "the file dialog opened but did not take the keyboard; nothing was typed")
        }
        Pace.sleep(Rand.uniform(0.5...0.9))
        try Keys.press("cmd+l")
        Pace.sleep(0.2)
        try Keys.type(guestPath, fast: true)
        Pace.sleep(Rand.uniform(0.4...0.7))
        try confirmDialog(["open", "select", "upload", "choose"])
        guard poll(timeout: 5, { dialogOpen() ? nil : true }) != nil else {
            try? Keys.press("esc")
            throw Fail(5, "the file dialog did not take \(guestPath); it was closed. Check with `read`")
        }
    }

    /// Clicks the dialog's button, found on screen inside the dialog (GTK's dialog is not on the
    /// accessibility bus). Return in GTK's location box closes the dialog without passing the file on,
    /// so it is only the fallback when no button is found.
    static func confirmDialog(_ labels: [String]) throws {
        if let d = try? query(["op": "dialog"]), let f = d["frame"] as? [Double], f.count == 4,
           let image = try? screen() {
            let box = CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
            let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let button = Capture.ocr(image, windowFrame: full, merge: false)
                .filter { box.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) && labels.contains($0.text.lowercased().trimmingCharacters(in: .whitespaces)) }
                .max { $0.box.midY < $1.box.midY }
            if let button {
                try Commands.realClick(button.box.insetBy(dx: -6, dy: -4))
                return
            }
        }
        try Keys.press("return")
    }

    static func dialogOpen() -> Bool { (try? query(["op": "dialog"]))?["open"] as? Bool == true }

    /// `download <id> <path>`: a link is clicked; anything else (an image) is saved from its right-click
    /// menu (`[agent] download_menu`). The browser saves into the guest's Downloads, and the new file
    /// comes back to `path` on this Mac.
    static func download(_ a: Args) throws -> String {
        guard let id = a.pos.first.flatMap(Int.init), a.pos.count >= 2 else { throw Fail(5, "download <id> <path>") }
        var path = (a.pos.dropFirst().joined(separator: " ") as NSString).expandingTildeInPath
        let (session, page, old) = try prepare()
        let e = try resolve(id)
        try gate(session, page, e, "download \(e.short) to \(path)")
        try beforeAction(session, url: page.url)
        let before = Set(try downloads())
        try act {
            if e.label == "link" {
                try Commands.realClick(e.rect)
            } else {
                try Commands.realClick(e.rect, right: true)
                Pace.sleep(0.5)
                // Chromium's menus are often not on the accessibility bus, so the item is also looked for
                // on screen, as `click --on` does.
                let labels = Config.current.downloadMenu
                guard let item = poll(timeout: 3, { () -> CGRect? in
                    if let m = (try? snapshot())?.elements.first(where: { m in m.label == "menuitem" && labels.contains { m.name.lowercased().contains($0) } }) {
                        return m.rect
                    }
                    guard let image = try? screen() else { return nil }
                    let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                    return Capture.ocr(image, windowFrame: full, merge: false).first { line in labels.contains { line.text.lowercased().contains($0) } }?.box
                }) else {
                    try? Keys.press("esc")
                    throw Fail(5, "no download item in the right-click menu of \(e.short); add its label to [agent] download_menu")
                }
                try Commands.realClick(item)
            }
        }
        // The file arrives in Downloads, or the browser first asks where to save it (its first dialog can
        // take several seconds to appear): then its suggestion, in Downloads, is taken once.
        var answered = false
        let file = try act {
            poll(timeout: 30, interval: 0.5) { () -> String? in
                if let new = (try? downloads())?.first(where: { !before.contains($0) && !$0.hasSuffix(".crdownload") && !$0.hasSuffix(".part") }) {
                    return new
                }
                if !answered, (try? query(["op": "dialog"]))?["active"] as? Bool == true {
                    answered = true
                    Pace.sleep(Rand.uniform(0.5...0.9))
                    try? confirmDialog(["save"])
                }
                return nil
            }
        }
        guard let file else { throw Fail(5, "nothing new arrived in the VM's Downloads within 30 s; check the page with `read`") }
        // A folder (or a path ending in /) takes the file under the name the browser gave it.
        var isDir: ObjCBool = false
        if path.hasSuffix("/") || (FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue) {
            path = (path as NSString).appendingPathComponent(file)
        }
        try pull("~/Downloads/\(file)", to: path)
        return try done("download", session, page, old, extra: ["saved \(path) (from the VM's Downloads/\(file))"],
                        log: ["id": id, "path": path, "label": e.label, "name": e.name])
    }

    static func downloads() throws -> [String] {
        let r = VM.ssh(try VM.address(), "mkdir -p ~/Downloads && ls -1t ~/Downloads")
        guard r.code == 0 else { throw Fail(5, "could not list the VM's Downloads: \(r.err)") }
        return String(decoding: r.out, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    private static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func push(_ path: String, to guestPath: String) throws {
        guard let data = FileManager.default.contents(atPath: path) else { throw Fail(5, "could not read \(path)") }
        let r = VM.ssh(try VM.address(), "rm -rf \(inbox) && mkdir -p \(inbox) && cat > \(quoted(guestPath))", input: data)
        guard r.code == 0 else { throw Fail(5, "could not copy \(path) into the VM: \(r.err)") }
    }

    static func pull(_ guestPath: String, to path: String) throws {
        let source = guestPath.hasPrefix("~/") ? "~/" + quoted(String(guestPath.dropFirst(2))) : quoted(guestPath)
        let r = VM.ssh(try VM.address(), "cat \(source)")
        guard r.code == 0 else { throw Fail(5, "could not copy \(guestPath) out of the VM: \(r.err)") }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try r.out.write(to: url) } catch { throw Fail(5, "could not write \(path): \(error.localizedDescription)") }
    }

    // MARK: - the screen

    /// The guest's whole screen as an image; boxes in it are the guest's screen points.
    static func screen() throws -> CGImage {
        try connect()
        let r = try query(["op": "shot"], timeout: 20)
        guard let w = r["w"] as? Int, let h = r["h"] as? Int, let b64 = r["data"] as? String,
              let packed = Data(base64Encoded: b64),
              let raw = try? (packed as NSData).decompressed(using: .zlib) as Data, raw.count >= w * h * 4,
              let provider = CGDataProvider(data: raw as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw Fail(5, "could not read the VM's screen") }
        return image
    }

    /// `--crop id` or `--crop x,y,w,h`, in the guest's screen points.
    private static func cropped(_ image: CGImage, _ a: Args) throws -> (CGImage, CGRect) {
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let raw = a.value("crop") else { return (image, full) }
        let rect: CGRect
        if let id = Int(raw) {
            rect = try resolve(id).rect
        } else {
            let n = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard n.count == 4 else { throw Fail(5, "--crop id or --crop x,y,w,h") }
            rect = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
        }
        guard let out = Capture.crop(image, to: rect, windowFrame: full) else { throw Fail(5, "empty crop") }
        return (out, rect)
    }

    static func shot(_ a: Args) throws -> String {
        let (session, _, old) = try prepare()
        var (image, frame) = try cropped(try screen(), a)
        var marked: Snapshot?
        if a.has("marks") {
            let snap = keepIds(old, try snapshot())
            SnapStore.save(snap)
            image = Capture.mark(image, frame: frame, snap.elements)
            marked = snap
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        let url = Store.runFolder(session).appendingPathComponent("shots/vm-\(formatter.string(from: Date())).png")
        try Capture.save(image, to: url)
        Sessions.capShots(Store.runFolder(session))
        Store.log(["cmd": "shot", "vm": true, "path": url.path, "marks": marked != nil])
        return url.path + (marked.map { " · snap \($0.snap) · \($0.elements.filter { !$0.offscreen }.count) ids marked" } ?? "")
    }

    /// Text the accessibility tree leaves out, read off the guest's screen with this Mac's Vision. Its
    /// lines get ids like `read`, and `click` clicks their box.
    static func ocr(_ a: Args) throws -> String {
        let (session, page, _) = try prepare()
        let (image, frame) = try cropped(try screen(), a)
        let elements: [Element] = Capture.ocr(image, windowFrame: frame).enumerated().map { n, line in
            Element(id: n + 1, path: [], label: "text", name: clip(line.text, 100), value: nil,
                    frame: [line.box.minX, line.box.minY, line.box.width, line.box.height].map(Double.init),
                    offscreen: false, gated: Gate.matches(line.text))
        }
        let snap = Snapshot(snap: SnapStore.next(), scope: "ocr", url: page.url, title: page.title, total: elements.count, elements: elements)
        SnapStore.save(snap)
        Store.log(["cmd": "ocr", "vm": true, "snap": snap.snap, "lines": elements.count])
        return Commands.render(snap, app: session.app, lines: elements.map(\.line), max: try a.count("max", 80))
    }

    static func waitFor(_ a: Args) throws -> String {
        guard let text = a.pos.first else { throw Fail(5, "wait-for \"text\"") }
        let timeout = Double(min(try a.count("timeout", 10, min: 1), 600))
        _ = try prepare()
        let needle = text.lowercased()
        let start = Date()
        let found = poll(timeout: timeout, interval: 0.3) { () -> (Snapshot, Element)? in
            guard let snap = try? snapshot() else { return nil }
            return snap.elements.first { $0.name.lowercased().contains(needle) || ($0.value ?? "").lowercased().contains(needle) }.map { (snap, $0) }
        }
        guard let (snap, hit) = found else {
            Store.log(["cmd": "wait-for", "vm": true, "text": text, "found": false])
            throw Fail(5, "timeout: \"\(text)\" not found in \(Int(timeout)) s")
        }
        SnapStore.save(snap)
        Store.log(["cmd": "wait-for", "vm": true, "text": text, "found": true, "snap": snap.snap])
        return "found · snap \(snap.snap) · \(hit.short) (\(Int(Date().timeIntervalSince(start))) s)"
    }

    static func drag(_ a: Args) throws -> String {
        if let raw = a.value("by") { return try dragBy(raw, a) }
        guard a.pos.count >= 2, let from = Int(a.pos[0]), let to = Int(a.pos[1]) else { throw Fail(5, Commands.dragUsage) }
        let (session, page, old) = try prepare()
        let src = try resolve(from), dst = try resolve(to)
        try gate(session, page, src, "drag \(src.short) onto \(dst.short)", warn: Gate.warnings(dst, page))
        try beforeAction(session, url: page.url)
        try act {
            let start = Mouse.landing(in: src.rect)
            Mouse.move(to: start, size: src.rect.size)
            Pace.sleep(Rand.uniform(0.1...0.25))
            try Mouse.drag(from: start, to: Mouse.landing(in: dst.rect))
        }
        return try done("drag", session, page, old, extra: ["→ \(from) onto \(to)"],
                        log: ["from": from, "to": to, "label": src.label, "name": src.name, "to_label": dst.label, "to_name": dst.name])
    }

    /// `drag --by dx,dy [--in id | --at x,y]`, as `Commands.dragBy` does it on this Mac.
    private static func dragBy(_ raw: String, _ a: Args) throws -> String {
        let by = try Commands.screenPoint(raw, Commands.dragUsage)
        let (session, page, old) = try prepare()
        var rect = CGRect(x: bounds.midX - 40, y: bounds.midY - 40, width: 80, height: 80)
        var e: Element?
        if let r = a.value("in"), let id = Int(r) { e = try resolve(id); rect = e!.rect }
        let start = try a.value("at").map { Mouse.aim(at: try Commands.screenPoint($0, Commands.dragUsage)) } ?? Mouse.landing(in: rect)
        let end = Mouse.dropBy(from: start, by)
        guard bounds.contains(start), bounds.contains(end) else {
            throw Fail(4, "a drag by \(raw) from \(Int(start.x)),\(Int(start.y)) leaves the session window: drag less, or in two steps")
        }
        let what = e.map { "drag in \($0.short) by \(raw)" } ?? "drag at \(Int(start.x)),\(Int(start.y)) by \(raw)"
        try gate(session, page, e, what, force: a.has("gate"))
        try beforeAction(session, url: page.url)
        try act {
            Mouse.move(to: start, size: e == nil ? CGSize(width: 20, height: 20) : rect.size)
            Pace.sleep(Rand.uniform(0.1...0.25))
            try Mouse.drag(from: start, to: end)
        }
        var log: [String: Any] = ["by": raw]
        if let e { log["label"] = e.label; log["name"] = e.name }
        return try done("drag", session, page, old, extra: ["→ by \(raw)"], log: log)
    }

    // MARK: - the user points

    /// `show "what"`: the little window asks the user into the VM, its screen opens, and their next click
    /// there is the answer, with the listed element under it.
    static func show(_ a: Args) throws -> String {
        let what = a.pos.joined(separator: " ")
        guard !what.isEmpty else { throw Fail(5, "show \"what to point at\" [--timeout 600]") }
        if Ask.away {
            throw Ask.handOff(["they cannot point from afar: ask them to describe where \"\(what)\" is,",
                               "or look for it yourself with `apprentice shot` and `apprentice ocr`."],
                               push: "Where is \"\(what)\"?")
        }
        let open = openTheVM, later = "Later"
        let reply = DispatchQueue.main.sync {
            Ask.show("apprentice needs you in the VM: click on \(what). Its screen opens; your next click there is the answer.",
                     choices: [open, later], multi: false, withText: false, timeout: Ask.windowTime(120))
        }
        guard let reply, reply.chosen == [open] else { throw Fail(5, "no answer: the user did not open the VM") }
        try VM.openViewer()
        let timeout = a.value("timeout").flatMap(Double.init) ?? 600
        try connect()
        let r = try query(["op": "waitclick", "timeout": timeout], timeout: timeout + 10)
        guard let x = r["x"] as? Double, let y = r["y"] as? Double else { throw Fail(5, "no answer: it timed out") }
        let point = CGPoint(x: x, y: y)
        Store.log(["show": what, "vm": true, "x": Int(x), "y": Int(y)])
        var out = ["The user pointed at \(Int(x)),\(Int(y)) in the VM"]
        let snap = try snapshot()
        SnapStore.save(snap)
        if let e = snap.elements.filter({ $0.rect.contains(point) }).min(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) {
            out.append("in the list: \(e.short) · act on it with its id")
        } else {
            out.append("not in the list: `click --at \(Int(x)),\(Int(y))` clicks there")
        }
        out.append("then add where it is to the playbook for this page or app, by name")
        return out.joined(separator: "\n")
    }

    // MARK: - the little window, in the VM

    /// The choice that opens the VM's screen for the user (`show`, `vm call`).
    static let openTheVM = "Open the VM"

    /// A question for a session in the VM, open on the VM's screen (agent/vm/ask.py) while this Mac's
    /// window asks it too: the user answers on whichever screen they are looking at.
    final class VMAsk {
        private let lock = NSLock()
        private var reply: [String: Any]?
        private var finished = false
        private let done = DispatchSemaphore(value: 0)

        fileprivate init(_ request: [String: Any], timeout: Double) {
            DispatchQueue.global().async {
                let r = try? Remote.query(request, timeout: timeout + 20)
                self.lock.lock()
                self.reply = r
                self.finished = true
                self.lock.unlock()
                self.done.signal()
            }
        }

        /// The answer given in the VM, once there is one: nil while waiting, and for a timeout or a failure.
        var answer: Ask.Reply? {
            lock.lock()
            defer { lock.unlock() }
            guard finished, let reply, reply["timeout"] == nil else { return nil }
            return Ask.Reply(chosen: reply["chosen"] as? [String] ?? [], text: (reply["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                             skipped: reply["skipped"] as? Bool == true)
        }

        /// Closes the VM's window once the Mac's was answered, and waits for the helper's reply, so it is
        /// never read as the reply to the next query. Keeps the run loop turning for the kill switch.
        func close() {
            lock.lock()
            let open = !finished
            lock.unlock()
            if open, let ip = try? VM.address() { _ = VM.ssh(ip, "pkill -f '/opt/apprentice/[a]sk.py'") }
            let until = Date().addingTimeInterval(5)
            while done.wait(timeout: .now()) != .success, Date() < until {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }
    }

    /// Opens the question on the VM's screen too, for a session in the VM. Nil when the session is not
    /// in a VM or the VM cannot be reached, or when the question is the one asking to open the VM.
    static func askInVM(_ question: String, choices: [String], multi: Bool, withText: Bool, timeout: Double,
                        sendTitle: String, checked: Set<String>, placeholder: String?, initialText: String) -> VMAsk? {
        guard Session.stored?.vm == true, !choices.contains(openTheVM), (try? connect()) != nil else { return nil }
        var request: [String: Any] = ["op": "ask", "question": question, "choices": choices, "multi": multi, "withText": withText,
                                      "timeout": timeout, "sendTitle": sendTitle, "checked": Array(checked), "initialText": initialText]
        if let placeholder { request["placeholder"] = placeholder }
        return VMAsk(request, timeout: timeout)
    }
}
