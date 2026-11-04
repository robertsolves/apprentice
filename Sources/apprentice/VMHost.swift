import AppKit
import Foundation
import Virtualization

/// The Linux VMs run inside apprentice's window process, through Apple's Virtualization framework, instead of a
/// separate `tart run` per VM. Tart still downloads and clones the image (`vm setup`) and keeps it in its own
/// folder (`~/.tart/vms/<name>`: `config.json`, `disk.img`, `nvram.bin`); the window boots that same folder with
/// the same devices, MAC address and machine identifier, so a VM made before keeps its address, disk and sign-ins.
/// While one runs, the window holds the same lock on its `config.json` that `tart run` takes, so `tart list` says
/// it is running and a second `tart run` refuses to start it twice.
///
/// The daemons and the CLI ask for a start or a stop with an order file in `vmhost/orders` (and a distributed
/// notification, so an open window answers at once); the window writes each VM's state to `vmhost/<name>.json`.
/// `[vm] runner = "tart"` keeps the old way, a headless `tart run`.
enum VMHost {
    struct Status: Codable {
        /// starting, running, stopping, stopped or failed.
        var state: String
        var pid: Int32
        var error: String?
        var at: Double
    }

    struct Order: Codable {
        var op: String
        var name: String
        var bundle: String
    }

    static let note = Notification.Name("com.apprentice.vmhost")
    static var dir: URL { Store.dir.appendingPathComponent("vmhost") }
    static var ordersDir: URL { dir.appendingPathComponent("orders") }
    static func statusURL(_ name: String) -> URL { dir.appendingPathComponent("\(name).json") }

    /// The VM's own folder in Tart's store (`TART_HOME`, else `~/.tart`).
    static func bundle(_ name: String, home: String?) -> URL {
        let base = home.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tart")
        return base.appendingPathComponent("vms/\(name)")
    }

    // MARK: - the daemon's and the CLI's side

    /// The window's word on a VM, while the window that wrote it is alive. The pid must still be apprentice's
    /// window: after a crash the number can be reused by another process, which would make a dead VM look running.
    static func status(_ name: String) -> Status? {
        guard let d = try? Data(contentsOf: statusURL(name)), let s = try? JSONDecoder().decode(Status.self, from: d),
              s.pid > 0, kill(s.pid, 0) == 0 else { return nil }
        if let app = NSRunningApplication(processIdentifier: s.pid), app.bundleIdentifier != AppBundle.identifier { return nil }
        return s
    }

    static func isRunning(_ name: String) -> Bool { ["starting", "running", "stopping"].contains(status(name)?.state ?? "") }

    /// Leaves an order for the window, opening it behind the person's work when it is closed.
    static func send(_ order: Order) {
        try? FileManager.default.createDirectory(at: ordersDir, withIntermediateDirectories: true)
        try? Wire.json(order).write(to: ordersDir.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6)).json"))
        if AppBundle.runningInstance != nil {
            DistributedNotificationCenter.default().postNotificationName(note, object: nil, userInfo: nil, deliverImmediately: true)
        } else {
            _ = AppBundle.open(activate: false)
        }
    }

    /// Boots the VM in the window and waits until the framework says it runs.
    static func start(_ name: String, bundle: URL) throws {
        if isRunning(name) { return }
        guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent("config.json").path) else {
            throw Fail(5, "no VM at \(bundle.path): run `apprentice vm setup`")
        }
        try? FileManager.default.removeItem(at: statusURL(name))
        send(Order(op: "start", name: name, bundle: bundle.path))
        // The window may have to open first, and a cold app takes a few seconds.
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if let s = status(name) {
                if s.state == "running" { return }
                if s.state == "failed" || s.state == "stopped" { throw Fail(5, "the VM did not start: \(s.error ?? s.state)") }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        throw Fail(5, "apprentice's window did not start the VM within 45 s: open it (`apprentice app`) and try again")
    }

    /// Asks the guest to shut down (the power button), and stops it outright when it has not after 30 s.
    static func stop(_ name: String) throws {
        guard isRunning(name) else { return }
        send(Order(op: "stop", name: name, bundle: ""))
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            if !isRunning(name) { return }
            Thread.sleep(forTimeInterval: 0.3)
        }
        throw Fail(5, "the VM \(name) did not stop: quit apprentice's window to stop it")
    }

    /// The address the Mac's DHCP server gave the guest's MAC address, newest lease first: what `tart ip` reads.
    static func leaseIP(bundle: URL) -> String? {
        guard let d = try? Data(contentsOf: bundle.appendingPathComponent("config.json")),
              let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let mac = (json["macAddress"] as? String).flatMap(macBytes),
              let text = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8) else { return nil }
        return leaseIP(mac: mac, leases: text)
    }

    /// The parse on its own, for `selftest`.
    static func leaseIP(mac: [Int], leases: String) -> String? {
        var best: (ip: String, lease: UInt64)?
        for block in leases.components(separatedBy: "}") {
            var ip: String?, hw: [Int]?, lease: UInt64 = 0
            for raw in block.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("ip_address=") { ip = String(line.dropFirst("ip_address=".count)) }
                if line.hasPrefix("hw_address=") {
                    // `1,a:bb:…`: the hardware type, then the MAC without leading zeros.
                    hw = line.dropFirst("hw_address=".count).split(separator: ",").last.flatMap { macBytes(String($0)) }
                }
                if line.hasPrefix("lease=0x") { lease = UInt64(line.dropFirst("lease=0x".count), radix: 16) ?? 0 }
            }
            if let ip, hw == mac, lease >= (best?.lease ?? 0) { best = (ip, lease) }
        }
        return best?.ip
    }

    static func macBytes(_ s: String) -> [Int]? {
        let parts = s.split(separator: ":").map { Int($0, radix: 16) }
        guard parts.count == 6, !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    // MARK: - the window's side

    /// The VMs this window runs, by Tart name. Touched only on the main thread.
    private static var machines: [String: HostedVM] = [:]
    private static var listening = false

    static var anyRunning: Bool { !machines.isEmpty }
    static var runningNames: [String] { machines.keys.sorted() }
    /// Called on the main thread when the last VM this window runs has stopped (`AppDelegate` quits if the window is closed).
    static var allStopped: (() -> Void)?

    /// Called once when the window starts: answers orders now and as they come.
    static func listen() {
        guard !listening else { return }
        listening = true
        DistributedNotificationCenter.default().addObserver(forName: note, object: nil, queue: .main) { _ in take() }
        // A notification can be missed (the window was still starting): the folder is the source of truth.
        let t = Timer(timeInterval: 1, repeats: true) { _ in take() }
        RunLoop.main.add(t, forMode: .common)
        take()
    }

    private static func take() {
        let files = ((try? FileManager.default.contentsOfDirectory(at: ordersDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for f in files {
            let order = (try? Data(contentsOf: f)).flatMap { try? JSONDecoder().decode(Order.self, from: $0) }
            try? FileManager.default.removeItem(at: f)
            guard let order else { continue }
            switch order.op {
            case "start": boot(order.name, bundle: URL(fileURLWithPath: order.bundle))
            case "stop": machines[order.name]?.shutDown()
            default: break
            }
        }
    }

    private static func boot(_ name: String, bundle: URL) {
        // Already running here: say so again, since the caller removed the old status before it asked.
        if let running = machines[name] { running.report(); return }
        do {
            let vm = try HostedVM(name: name, bundle: bundle) { gone in
                machines[gone] = nil
                if machines.isEmpty { allStopped?() }
            }
            machines[name] = vm
            vm.start()
        } catch {
            write(name, "failed", error: (error as? Fail)?.message ?? error.localizedDescription)
            AppLog.note("vm \(name) did not start: \(error.localizedDescription)")
        }
    }

    /// Stops every VM (power button, then outright after 20 s) and calls `done` on the main thread.
    static func stopAll(_ done: @escaping () -> Void) {
        guard anyRunning else { return done() }
        for vm in machines.values { vm.shutDown(grace: 20) }
        let deadline = Date().addingTimeInterval(25)
        func wait() {
            if machines.isEmpty || Date() > deadline { return done() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: wait)
        }
        wait()
    }

    static func write(_ name: String, _ state: String, error: String? = nil) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Wire.json(Status(state: state, pid: getpid(), error: error, at: Date().timeIntervalSince1970)).write(to: statusURL(name))
    }

    /// Tart's `config.json` for this VM.
    static func readConfig(_ bundle: URL) throws -> [String: Any] {
        guard let d = try? Data(contentsOf: bundle.appendingPathComponent("config.json")),
              let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            throw Fail(5, "could not read \(bundle.appendingPathComponent("config.json").path)")
        }
        return json
    }

    /// The configuration Tart would build for this Linux VM, from its own `config.json`.
    static func configuration(_ bundle: URL, json: [String: Any], console: FileHandle?) throws -> VZVirtualMachineConfiguration {
        let fm = FileManager.default
        guard (json["os"] as? String) == "linux" else { throw Fail(5, "only Linux VMs run inside apprentice; set [vm] runner = \"tart\"") }
        let disk = bundle.appendingPathComponent("disk.img"), nvram = bundle.appendingPathComponent("nvram.bin")
        guard fm.fileExists(atPath: disk.path), fm.fileExists(atPath: nvram.path) else {
            throw Fail(5, "this VM uses a Tart disk layout apprentice cannot open (no disk.img); set [vm] runner = \"tart\"")
        }
        let c = VZVirtualMachineConfiguration()
        let cpus = json["cpuCount"] as? Int ?? 2
        c.cpuCount = min(max(cpus, VZVirtualMachineConfiguration.minimumAllowedCPUCount), VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        let memory = (json["memorySize"] as? NSNumber)?.uint64Value ?? 2 << 30
        c.memorySize = min(max(memory, VZVirtualMachineConfiguration.minimumAllowedMemorySize), VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        let boot = VZEFIBootLoader()
        boot.variableStore = VZEFIVariableStore(url: nvram)
        c.bootLoader = boot
        let platform = VZGenericPlatformConfiguration()
        if let id = json["machineIdentifier"] as? String, let raw = Data(base64Encoded: id),
           let machine = VZGenericMachineIdentifier(dataRepresentation: raw) {
            platform.machineIdentifier = machine
        }
        c.platform = platform
        let display = json["display"] as? [String: Any]
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: display?["width"] as? Int ?? 1024,
                                                                  heightInPixels: display?["height"] as? Int ?? 768)]
        c.graphicsDevices = [graphics]
        c.keyboards = [VZUSBKeyboardConfiguration()]
        c.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        // The MAC Tart gave it, so the guest keeps its DHCP lease and the address apprentice knows.
        if let mac = (json["macAddress"] as? String).flatMap(VZMACAddress.init(string:)) { net.macAddress = mac }
        c.networkDevices = [net]
        let attachment = try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false, cachingMode: .automatic, synchronizationMode: .full)
        c.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
        c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        c.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        c.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        if let console {
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: console)
            c.serialPorts = [serial]
        }
        try c.validate()
        return c
    }
}

/// One VM running in this window: the framework's machine, the Tart lock and the guest's console log.
final class HostedVM: NSObject, VZVirtualMachineDelegate {
    let name: String
    private let machine: VZVirtualMachine
    private let lock: Int32
    private let console: FileHandle?
    private let ended: (String) -> Void
    private var finished = false

    init(name: String, bundle: URL, ended: @escaping (String) -> Void) throws {
        self.name = name
        self.ended = ended
        // Read before the lock: closing any descriptor of a file drops all of this process's fcntl locks on it.
        let json = try VMHost.readConfig(bundle)
        // The lock `tart run` takes, so Tart sees this VM as running and never boots the same disk twice.
        let fd = open(bundle.appendingPathComponent("config.json").path, O_RDWR)
        guard fd >= 0 else { throw Fail(5, "could not open \(bundle.path)") }
        var fl = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        guard fcntl(fd, F_SETLK, &fl) == 0 else {
            close(fd)
            throw Fail(5, "\(name) is already running (under Tart?): stop it with `tart stop \(name)`, then try again")
        }
        lock = fd
        let logs = Store.dir.appendingPathComponent("vmhost")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = logs.appendingPathComponent("\(name).console.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        console = try? FileHandle(forWritingTo: log)
        do {
            machine = VZVirtualMachine(configuration: try VMHost.configuration(bundle, json: json, console: console))
        } catch {
            close(fd)
            throw error
        }
        super.init()
        machine.delegate = self
    }

    /// Writes the state again, for a start order that arrives while it already runs.
    func report() {
        guard !finished else { return }
        VMHost.write(name, machine.state == .running ? "running" : machine.state == .stopping ? "stopping" : "starting")
    }

    func start() {
        VMHost.write(name, "starting")
        machine.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                VMHost.write(self.name, "running")
                AppLog.note("vm \(self.name) running inside the window")
            case .failure(let error):
                self.end("failed", error.localizedDescription)
            }
        }
    }

    /// The power button first, so the guest shuts down cleanly; outright after `grace` seconds.
    func shutDown(grace: Double = 30) {
        guard !finished else { return }
        VMHost.write(name, "stopping")
        if machine.canRequestStop { try? machine.requestStop() }
        DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [weak self] in
            guard let self, !self.finished, self.machine.canStop else { return }
            self.machine.stop { [weak self] error in self?.end("stopped", error?.localizedDescription) }
        }
        if !machine.canRequestStop, machine.canStop {
            machine.stop { [weak self] error in self?.end("stopped", error?.localizedDescription) }
        }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) { end("stopped", nil) }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        end("failed", error.localizedDescription)
    }

    private func end(_ state: String, _ error: String?) {
        guard !finished else { return }
        finished = true
        VMHost.write(name, state, error: error)
        AppLog.note("vm \(name) \(state)\(error.map { ": \($0)" } ?? "")")
        try? console?.close()
        close(lock)
        ended(name)
    }
}
