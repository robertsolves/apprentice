import AppKit
import SwiftUI

/// The VM lives inside the window: the VMs screen shows each running VM's screen with its pointer and what its
/// agent is doing, and `VMDock` detaches one into a window and Dock icon of its own. The daemons open the window on
/// that VM (`AppShow.vm`), and the picture comes from a child process per VM shown (`vm frames`), which talks to the
/// guest over its own connection, so watching never slows the agent. To click or type in the VM, `apprentice vm look`
/// opens Screen Sharing.
enum AppShow {
    static let note = Notification.Name("com.apprentice.app.show")
    /// What the window should show next: written before the window opens or is told, read and removed by it.
    static var file: URL { Store.dir.appendingPathComponent("app-show.json") }

    struct Request: Codable {
        var section: String
        /// The VM's name as the VMs screen lists it: "" is the default VM.
        var vm: String?
        var activate: Bool
    }

    /// This process's VM: "" for this Mac's daemon (the default VM), else `APPRENTICE_VM`.
    static var ownVM: String { Store.vmName ?? "" }

    /// Opens the window on the VMs screen with `name` chosen. `activate: false` leaves it behind the person's work,
    /// and `ifClosed` does nothing when the window is already open, so a session start never moves its screen.
    /// `sync` waits for the window to be opened (the CLI, which exits as soon as this returns); otherwise a call on the
    /// main thread (the daemon's buttons) opens it from another queue.
    static func vm(_ name: String = ownVM, activate: Bool = true, ifClosed: Bool = false, sync: Bool = false) {
        let running = AppBundle.runningInstance
        if ifClosed, running != nil { return }
        let request = Request(section: "vms", vm: name, activate: activate)
        try? FileManager.default.createDirectory(at: Store.dir, withIntermediateDirectories: true)
        try? Wire.json(request).write(to: file)
        if let running {
            DistributedNotificationCenter.default().postNotificationName(note, object: nil, userInfo: nil, deliverImmediately: true)
            if activate { running.activate() }
            return
        }
        // `AppBundle.open` may rebuild and sign the bundle first, which must not hold the daemon's main thread.
        let work = { _ = AppBundle.open(activate: activate) }
        if Thread.isMainThread, !sync { DispatchQueue.global().async(execute: work) } else { work() }
    }

    /// The window's side: the request left for it, if any, read once.
    static func take() -> Request? {
        guard let d = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.removeItem(at: file)
        return try? JSONDecoder().decode(Request.self, from: d)
    }
}

// MARK: - the child process: `apprentice [--vm <name>] vm frames`

enum VMFrames {
    /// Writes the guest's screen and pointer to stdout until stdin closes (the window went away): a JSON line
    /// `{"w","h","x","y","n"}` and then `n` bytes of JPEG, `n` 0 when the screen did not change, or a line with
    /// `"error"` while the VM cannot be reached.
    static func run() -> Never {
        DispatchQueue.global().async {
            _ = FileHandle.standardInput.readDataToEndOfFile()
            exit(0)
        }
        let out = FileHandle.standardOutput
        var last = Data()
        while true {
            var record = Data()
            var wait = 0.8
            autoreleasepool {
                do {
                    let frame = try Remote.screen()
                    let c = try? Remote.query(["op": "cursor"])
                    let x = (c?["x"] as? Double) ?? Remote.cursor.x, y = (c?["y"] as? Double) ?? Remote.cursor.y
                    let jpeg = NSBitmapImageRep(cgImage: frame).representation(using: .jpeg, properties: [.compressionFactor: 0.7]) ?? Data()
                    let body = jpeg == last ? Data() : jpeg
                    if !body.isEmpty { last = jpeg }
                    let head: [String: Any] = ["w": frame.width, "h": frame.height, "x": x, "y": y, "n": body.count]
                    record = ((try? JSONSerialization.data(withJSONObject: head)) ?? Data()) + Data([0x0A]) + body
                } catch {
                    last = Data()
                    wait = 2
                    let message = (error as? Fail)?.message ?? "\(error)"
                    record = ((try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()) + Data([0x0A])
                }
            }
            do { try out.write(contentsOf: record) } catch { exit(0) }
            Thread.sleep(forTimeInterval: wait)
        }
    }
}

// MARK: - the window's side

/// One VM's live picture, while its panel is on screen: starts `vm frames` for it and stops it when hidden.
final class VMFeed: ObservableObject {
    @Published var image: NSImage?
    @Published var problem: String?
    /// What that VM's agent is doing, from the daemons' rows (`Overlay.liveRows`).
    @Published var state: String?
    @Published var tone: Color = .secondary

    private var proc: Process?
    private var input: Pipe?
    private var timer: Timer?
    private var name = ""
    private var frame: CGImage?

    func start(_ vm: String) {
        if proc?.isRunning == true, vm == name { return }
        stop()
        name = vm
        image = nil
        problem = nil
        frame = nil
        guard let exe = Bundle.main.executablePath else { problem = "apprentice's own binary was not found"; return }
        let p = Process(), out = Pipe(), inp = Pipe()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = (vm.isEmpty ? [] : ["--vm", vm]) + ["vm", "frames"]
        // Its own folder, never a project's (which would choose that project's VM for the default one).
        p.currentDirectoryURL = Store.dir
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "APPRENTICE_VM")
        p.environment = env
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { problem = "could not start the VM's picture: \(error.localizedDescription)"; return }
        proc = p
        input = inp
        let reader = out.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.read(reader) }
        readState()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.readState() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        try? input?.fileHandleForWriting.close()
        if proc?.isRunning == true { proc?.terminate() }
        proc = nil
        input = nil
    }

    deinit { stop() }

    private func readState() {
        let key = name.isEmpty ? "mac" : name
        let row = Overlay.liveRows().first { $0.key == key && $0.inVM }
        state = row?.head
        switch row?.head {
        case "Needs approval", "Waiting for you", "Stopped", "Agent stopped", "Paused": tone = Theme.warn
        case "Working", "Yours": tone = Theme.accent
        default: tone = .secondary
        }
    }

    private func read(_ handle: FileHandle) {
        var buffer = Data()
        func need(_ count: Int) -> Bool {
            while buffer.count < count {
                let more = handle.availableData
                if more.isEmpty { return false }
                buffer.append(more)
            }
            return true
        }
        while true {
            var line: Data?
            while line == nil {
                if let nl = buffer.firstIndex(of: 0x0A) {
                    line = buffer[buffer.startIndex..<nl]
                    buffer = Data(buffer[(nl + 1)...])
                } else if !need(buffer.count + 1) { return }
            }
            guard let head = (try? JSONSerialization.jsonObject(with: line ?? Data())) as? [String: Any] else { continue }
            if let error = head["error"] as? String {
                DispatchQueue.main.async { self.problem = error }
                continue
            }
            let n = head["n"] as? Int ?? 0
            guard need(n) else { return }
            let body = buffer.prefix(n)
            buffer = Data(buffer.dropFirst(n))
            let point = CGPoint(x: head["x"] as? Double ?? 0, y: head["y"] as? Double ?? 0)
            DispatchQueue.main.async {
                if n > 0, let rep = NSBitmapImageRep(data: body), let cg = rep.cgImage { self.frame = cg }
                guard let frame = self.frame else { return }
                self.problem = nil
                self.image = VMFeed.draw(frame, point)
            }
        }
    }

    /// The frame with a blue arrow and a soft ring at the pointer, easy to follow.
    static func draw(_ frame: CGImage, _ p: CGPoint) -> NSImage {
        NSImage(size: NSSize(width: frame.width, height: frame.height), flipped: true) { rect in
            NSGraphicsContext.current?.cgContext.saveGState()
            NSGraphicsContext.current?.cgContext.translateBy(x: 0, y: rect.height)
            NSGraphicsContext.current?.cgContext.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current?.cgContext.draw(frame, in: rect)
            NSGraphicsContext.current?.cgContext.restoreGState()
            NSColor.systemBlue.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 20, y: p.y - 20, width: 40, height: 40)).fill()
            let arrow = NSBezierPath()
            arrow.move(to: p)
            for (dx, dy) in [(0.0, 24.0), (6, 18), (12, 30), (17, 27), (11, 16), (19, 16)] { arrow.line(to: NSPoint(x: p.x + dx, y: p.y + dy)) }
            arrow.close()
            NSColor.white.setStroke()
            arrow.lineWidth = 3
            arrow.stroke()
            NSColor.systemBlue.setFill()
            arrow.fill()
            return true
        }
    }
}

/// The VM's screen and nothing else: no heading, caption or frame. `fills` takes all the room it is given, as the VMs
/// screen and a detached window do, with the picture as large as fits. What its agent is doing is the tooltip.
struct VMScreen: View {
    let name: String
    var fills = false
    @StateObject private var feed = VMFeed()

    private var picture: some View {
        ZStack {
            Color.black
            if let image = feed.image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Text(feed.problem ?? "Connecting to the VM…").font(Theme.caption).foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center).padding(Theme.s4)
            }
        }
    }

    var body: some View {
        Group {
            if fills {
                picture.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                picture.aspectRatio(1280.0 / 800.0, contentMode: .fit).frame(maxWidth: .infinity)
            }
        }
        .help(feed.state ?? "No agent working")
        .onAppear { feed.start(name) }
        .onChange(of: name) { _, new in feed.start(new) }
        .onDisappear { feed.stop() }
    }
}
