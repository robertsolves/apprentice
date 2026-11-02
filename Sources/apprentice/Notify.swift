import AppKit
import CoreImage

/// When a question goes to the chat (exit 9), the user is usually on a phone: `Ask.handOff` saves the
/// screen it is about, for the agent to attach, and pushes a notification so the phone buzzes.
/// `[agent] notify` is an ntfy topic URL (https://ntfy.sh/<long random topic>, or a self-hosted one);
/// any URL that takes a plain-text POST works. Only the question goes out, never a screenshot, and
/// nothing at all past "a question is waiting" for a scrubbed app.
enum Notify {
    /// The session window (or the VM's screen) as a PNG in this run's shots, or nil when there is no
    /// session, the app is scrubbed, or there is no Screen Recording grant.
    static func shot() -> String? {
        guard let session = Session.stored else { return nil }
        if session.vm != true { return Events.shot(session, "ask") }
        guard !Privacy.blocked(session), let image = try? Remote.screen() else { return nil }
        let url = Store.runFolder(session).appendingPathComponent("shots/ask-\(Int(Date().timeIntervalSince1970)).png")
        guard (try? Capture.save(image, to: url)) != nil else { return nil }
        Sessions.capShots(Store.runFolder(session))
        return url.path
    }

    /// What the notification says: the question, cut to fit, or nothing about a scrubbed app.
    static func body(_ text: String, session: Session?) -> String {
        if let session, Privacy.blocked(session) { return "A question is waiting in the chat." }
        let one = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return one.count > 300 ? String(one.prefix(299)) + "…" : one
    }

    /// Fire and forget: a failed push never holds up the question, it is only logged.
    static func send(_ text: String) {
        post(body(text, session: Session.stored), title: "apprentice needs you", wait: false)
    }

    /// Posts to `[agent] notify`; with `wait`, returns the HTTP status (0 when it did not get through).
    @discardableResult
    static func post(_ text: String, title: String, to target: String = Config.current.notify, wait: Bool) -> Int {
        guard !target.isEmpty else { return 0 }
        guard let url = URL(string: target), url.scheme == "https" || url.host == "localhost" else {
            Store.log(["notify": "skipped", "why": "[agent] notify must be an https URL"])
            return 0
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.httpBody = Data(text.utf8)
        req.setValue(title, forHTTPHeaderField: "Title")
        req.setValue("high", forHTTPHeaderField: "Priority")
        req.setValue("question", forHTTPHeaderField: "Tags")
        let done = DispatchSemaphore(value: 0)
        var status = 0
        URLSession.shared.dataTask(with: req) { _, response, error in
            status = error == nil ? (response as? HTTPURLResponse)?.statusCode ?? 0 : 0
            if !(200..<300).contains(status) { Store.log(["notify": "failed", "status": status]) }
            done.signal()
        }.resume()
        if wait { _ = done.wait(timeout: .now() + 12) }
        return status
    }
}

/// `phone [on|off|test] [--server https://ntfy.example.com]`: one-tap phone setup for the pushes. `on` makes
/// a long random topic, writes it to `[agent] notify`, sends a test push (ntfy keeps it for the phone to fetch
/// on subscribing) and prints the subscribe links and a QR code. Running it again shows the same links.
extension Notify {
    static func phone(_ a: Args, tty: Bool) throws -> String {
        let current = Config.current.notify
        switch a.pos.first ?? "on" {
        case "off":
            Config.remember("agent", "notify", "\"\"")
            return "phone: off · questions no longer push to the phone. Unsubscribe in the ntfy app."
        case "test":
            guard !current.isEmpty else { throw Fail(5, "phone: not set up. `apprentice phone` sets it up") }
            let status = post("A test from apprentice. Questions that go to the chat will buzz here.", title: "apprentice", to: current, wait: true)
            guard (200..<300).contains(status) else { throw Fail(5, "phone: the push did not get through (status \(status)) to \(current)") }
            return "phone: test push sent to \(current)"
        case "on": break
        default: throw Fail(5, "phone [on|off|test] [--server https://ntfy.example.com]")
        }
        var target = current
        if target.isEmpty {
            let server = (a.value("server") ?? "https://ntfy.sh").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard server.hasPrefix("https://") else { throw Fail(5, "phone: --server must be an https URL") }
            target = "\(server)/\(topic())"
            Config.remember("agent", "notify", "\"\(target)\"")
            Config.reloadIfChanged()
            let status = post("apprentice is connected. Questions that go to the chat will buzz here.", title: "apprentice", to: target, wait: true)
            if !(200..<300).contains(status) { Store.log(["notify": "setup push failed", "status": status]) }
        }
        return links(target, tty: tty)
    }

    /// 24 characters from the system's secure generator: the topic is the only secret ntfy.sh has.
    static func topic() -> String {
        let chars = Array("abcdefghijkmnopqrstuvwxyz23456789")
        var rng = SystemRandomNumberGenerator()
        return "apprentice-" + String((0..<24).map { _ in chars[Int(rng.next(upperBound: UInt32(chars.count)))] })
    }

    static func links(_ target: String, tty: Bool) -> String {
        guard let url = URL(string: target), let host = url.host else { return "phone: \(target)" }
        let topic = url.lastPathComponent
        let android = "ntfy://\(host)\(url.port.map { ":\($0)" } ?? "")/\(topic)?display=apprentice"
        var out = [
            "phone: on · questions that go to the chat also buzz your phone (question text only, never a screenshot)",
            "1. Install the free ntfy app (App Store or Google Play).",
            "2. On the phone, tap: Android \(android) · iPhone \(target) (or in the app: + , paste the topic \(topic))",
            "Scan the QR code with the phone's camera instead, or send the user these links in the chat.",
            "Keep the topic private: anyone who has it can read the pushes. `apprentice phone off` stops them, `phone test` sends one.",
        ]
        if let png = qr(target) {
            out.append("QR code: \(png.path)")
            if tty { NSWorkspace.shared.open(png) }
        }
        if tty, let art = qrText(target) { out.append(art) }
        return out.joined(separator: "\n")
    }

    /// The QR code's modules, true for dark, with a two-module quiet zone.
    private static func modules(_ text: String) -> [[Bool]]? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage,
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        let quiet = 2, n = rep.pixelsWide
        return (-quiet..<(n + quiet)).map { y in
            (-quiet..<(n + quiet)).map { x in
                guard x >= 0, y >= 0, x < n, y < n, let c = rep.colorAt(x: x, y: y) else { return false }
                return c.brightnessComponent < 0.5
            }
        }
    }

    /// A PNG in ~/.apprentice for the phone's camera.
    static func qr(_ text: String) -> URL? {
        guard let m = modules(text) else { return nil }
        let scale = 12, size = m.count * scale
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 1, hasAlpha: false, isPlanar: false,
                                         colorSpaceName: .deviceWhite, bytesPerRow: size, bitsPerPixel: 8),
              let data = rep.bitmapData else { return nil }
        for y in 0..<size { for x in 0..<size { data[y * size + x] = m[y / scale][x / scale] ? 0 : 255 } }
        let url = Store.dir.appendingPathComponent("phone-qr.png")
        guard let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil else { return nil }
        return url
    }

    /// The QR code in the terminal, two rows per line, black on white whatever the terminal's colours.
    static func qrText(_ text: String) -> String? {
        guard let m = modules(text) else { return nil }
        var lines: [String] = []
        for y in stride(from: 0, to: m.count, by: 2) {
            var line = ""
            for x in 0..<m.count {
                let top = m[y][x], bottom = y + 1 < m.count ? m[y + 1][x] : false
                line += "\u{1B}[\(top ? 30 : 97);\(bottom ? 40 : 107)m▀"
            }
            lines.append(line + "\u{1B}[0m")
        }
        return lines.joined(separator: "\n")
    }
}
