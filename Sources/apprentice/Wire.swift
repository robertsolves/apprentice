import Foundation
import Darwin
import AppKit

struct Request: Codable {
    var cmd: String
    var args: [String] = []
}

struct Response: Codable {
    var code: Int32 = 0
    var out: String = ""
    var data: [String: String]?
}

enum Wire {
    static func json<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data()
    }

    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        // strncpy returns its destination, so an over-long path must be rejected before copying.
        guard path.utf8.count < maxLen else { return nil }
        path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                    _ = strncpy(dst, src, maxLen - 1)
                }
            }
        }
        return addr
    }

    static func connect() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard var addr = address(Store.socketPath) else { close(fd); return nil }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bindPtr in
                Darwin.connect(fd, bindPtr, size)
            }
        }
        if result != 0 {
            close(fd)
            return nil
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func readAll(_ fd: Int32) -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            out.append(buffer, count: n)
            if out.count > 8 * 1024 * 1024 { break }
        }
        return out
    }

    static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    /// Sends one request line on `fd`, reads the whole reply and closes the socket.
    private static func roundTrip(_ fd: Int32, _ req: Request) -> Data {
        defer { close(fd) }
        var data = json(req)
        data.append(0x0A)
        writeAll(fd, data)
        shutdown(fd, SHUT_WR)
        return readAll(fd)
    }

    static func send(_ req: Request) throws -> Response {
        var fd = connect()
        if fd == nil {
            try startDaemon()
            fd = connect()
        }
        guard let fd else { throw Fail(5, "daemon did not start: run `apprentice serve` to see why") }
        let reply = roundTrip(fd, req)
        guard !reply.isEmpty else { throw Fail(5, "daemon closed the connection") }
        guard let resp = try? JSONDecoder().decode(Response.self, from: reply) else {
            throw Fail(5, "bad reply from daemon")
        }
        return resp
    }

    static func ping() -> Bool {
        guard let fd = connect() else { return false }
        return !roundTrip(fd, Request(cmd: "ping")).isEmpty
    }

    static func binaryPath() -> String {
        if let path = Bundle.main.executablePath { return path }
        return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    }

    static func startDaemon() throws {
        if ping() { return }
        let logPath = Store.dir.appendingPathComponent("daemon.err")
        FileManager.default.createFile(atPath: logPath.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logPath)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath())
        proc.arguments = ["serve", "--background"]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = log ?? FileHandle.nullDevice
        proc.standardError = log ?? FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            throw Fail(5, "cannot start daemon: \(error.localizedDescription)")
        }
        let started = poll(timeout: 10, interval: 0.12) { ping() ? true : nil } != nil
        try? log?.close()
        if started {
            try? FileManager.default.removeItem(at: logPath)
            return
        }
        let detail = (try? String(contentsOf: logPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hint = detail.isEmpty ? "" : ": \(detail)"
        throw Fail(7, "daemon did not start\(hint)")
    }

    static func stopDaemon() {
        if let fd = connect() {
            _ = roundTrip(fd, Request(cmd: "stop"))
            return
        }
        if let raw = try? String(contentsOfFile: Store.pidPath, encoding: .utf8),
           let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGTERM)
        }
        unlink(Store.socketPath)
        try? FileManager.default.removeItem(atPath: Store.pidPath)
    }
}

final class UnixServer {
    private let path: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let handler: (Request) -> (Response, Bool)
    private var stopping = false

    init(path: String, handler: @escaping (Request) -> (Response, Bool)) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Fail(5, "socket: \(String(cString: strerror(errno)))") }

        guard var addr = Wire.address(path) else { throw Fail(5, "socket path too long: \(path)") }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) }
        }
        guard bound == 0 else { throw Fail(5, "bind \(path): \(String(cString: strerror(errno)))") }
        guard listen(fd, 16) == 0 else { throw Fail(5, "listen: \(String(cString: strerror(errno)))") }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.acceptReady() }
        src.resume()
        source = src
    }

    private func acceptReady() {
        while true {
            var addr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let cfd = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) }
            }
            if cfd < 0 { break }
            var one: Int32 = 1
            setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.serve(cfd)
            }
        }
    }

    private func serve(_ cfd: Int32) {
        // Accepted sockets can inherit O_NONBLOCK on Darwin; read must block until the caller sends.
        let flags = fcntl(cfd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(cfd, F_SETFL, flags & ~O_NONBLOCK) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(cfd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
            if data.contains(0x0A) { break }
            if data.count > 4 * 1024 * 1024 { break }
        }
        var stop = false
        let response: Response
        if let line = data.split(separator: 0x0A).first,
           let req = try? JSONDecoder().decode(Request.self, from: Data(line)) {
            // Not the main queue: the kill switch and Borrow's monitors run there and must fire mid-command.
            let result = Daemon.queue.sync { handler(req) }
            response = result.0
            stop = result.1
        } else {
            response = Response(code: 5, out: "bad request")
        }
        var payload = Wire.json(response)
        payload.append(0x0A)
        Wire.writeAll(cfd, payload)
        close(cfd)
        if stop {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.stop() }
        }
    }

    func stop() {
        guard !stopping else { return }
        stopping = true

        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
        unlink(path)
        try? FileManager.default.removeItem(atPath: Store.pidPath)
        NSApplication.shared.terminate(nil)
    }
}
