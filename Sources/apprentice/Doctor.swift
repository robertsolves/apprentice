import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// `doctor [--fix]`: checks everything a first run needs and says what to do about each gap. `--fix` opens
/// the two Privacy panes, waits for both grants, restarts the daemon and runs a smoke test on Finder.
/// `uninstall [--all] --yes` takes apprentice off the Mac again.
enum Doctor {
    struct Check {
        var ok: Bool
        var line: String
        var fix: String?
        /// A gap that stops apprentice working, not just a warning.
        var blocking = false
    }

    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static let accessibilityPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    static let screenPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

    static func checks() -> [Check] {
        let bin = Wire.binaryPath()
        var out: [Check] = []
        out.append(Check(ok: true, line: "apprentice \(Build.version) · \(bin)"))
        out.append(Check(ok: accessibility, line: "Accessibility", fix: "System Settings → Privacy & Security → Accessibility → enable apprentice (`apprentice doctor --fix` opens it)", blocking: true))
        out.append(Check(ok: screenRecording, line: "Screen Recording (shot, ocr, click --on)", fix: "System Settings → Privacy & Security → Screen Recording → enable apprentice (`apprentice doctor --fix` opens it)", blocking: true))

        let sign = Repo.run("codesign", ["-dv", bin], in: Store.dir).out
        let adhoc = sign.contains("Signature=adhoc") || sign.contains("not signed")
        out.append(Check(ok: !adhoc, line: adhoc ? "signature: ad hoc" : "signature: a stable identity",
                         fix: adhoc ? "every rebuild drops the permission grants; run kit.sh so it signs with the local \"apprentice\" identity, or set APPRENTICE_SIGN_IDENTITY" : nil))

        let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains { URL(fileURLWithPath: String($0)).standardizedFileURL.path == URL(fileURLWithPath: bin).deletingLastPathComponent().standardizedFileURL.path }
        out.append(Check(ok: onPath, line: "on PATH", fix: "open a new terminal, or add \(URL(fileURLWithPath: bin).deletingLastPathComponent().path) to PATH in ~/.zprofile"))

        let daemon = Wire.ping()
        out.append(Check(ok: true, line: daemon ? "daemon: running" : "daemon: not running (the next command starts it)"))

        let playbooks = Playbooks.dir.resolvingSymlinksInPath()
        let playbooksOK = FileManager.default.fileExists(atPath: playbooks.path)
        out.append(Check(ok: playbooksOK, line: "playbooks: \(playbooks.path)", fix: "run kit.sh in the clone to link \(Store.dir.path)/playbooks", blocking: true))

        if Repo.isGit {
            let remote = Repo.upstream
            let url = Repo.git("remote", "get-url", remote).out
            let line = "clone: \(Repo.root.path) · \(remote) \(url) · auto-update \(Repo.auto ? "on" : "off")"
            out.append(Check(ok: !Repo.auto || Repo.trusted, line: line,
                             fix: Repo.auto && !Repo.trusted ? "auto-update runs only from an https or ssh upstream; this one is updated by hand with `apprentice update`" : nil))
        } else {
            out.append(Check(ok: false, line: "clone: \(Repo.root.path) is not a git clone", fix: "reinstall with install.sh, so fixes and updates work"))
        }

        out.append(Check(ok: FileManager.default.fileExists(atPath: Config.path.path), line: "settings: \(Config.path.path)",
                         fix: "run kit.sh to write the example config"))
        let open = worldReadable(Store.dir) || worldReadable(Config.path)
        out.append(Check(ok: !open, line: open ? "state: readable by other users" : "state: this user only",
                         fix: open ? "chmod 700 \(Store.dir.path); chmod 600 \(Config.path.path)" : nil))
        out.append(Check(ok: true, line: "sessions in the clone: \(Sessions.mode) ([storage] sessions)"))
        // Offline: doctor never waits on GitHub. `account status` checks the token itself.
        out.append(Check(ok: true, line: "github: " + Account.status(live: false)))
        out.append(Check(ok: true, line: "vm: " + (VM.tartPath == nil ? "not installed (optional; `apprentice vm setup`)" : (VM.state.on ? "browser sessions go to the VM" : "installed, off"))))
        // To a site the VM is another device, Linux with its own fingerprint (BOT_DETECTION S6, S12).
        if VM.state.on || VM.host != nil {
            out.append(Check(ok: true, line: "vm: sites see it as a separate Linux device; accounts whose standing matters are safest in this Mac's own browser ([vm] local = [\"linkedin.com\", …])"))
        }
        if VM.host != nil {
            out.append(Check(ok: false, line: "vm: a remote host reaches sites from its own network, while its time zone and language are this Mac's",
                             fix: "keep social accounts off it ([vm] local), or set the guest's zone and language to match where it is"))
        }
        return out
    }

    static func worldReadable(_ url: URL) -> Bool {
        guard let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int else { return false }
        return mode & 0o077 != 0
    }

    static func render(_ checks: [Check]) -> String {
        checks.map { c in
            (c.ok ? "✓ " : (c.blocking ? "✗ " : "! ")) + c.line + (c.ok ? "" : c.fix.map { "\n    → \($0)" } ?? "")
        }.joined(separator: "\n")
    }

    /// `doctor [--fix]`. Exit 7 while a grant is missing.
    static func run(_ a: Args) throws -> String {
        if a.has("grants") { return "accessibility=\(accessibility) screen=\(screenRecording)" }
        var list = checks()
        guard a.has("fix") else {
            let out = render(list)
            if list.contains(where: { !$0.ok && $0.blocking }) { throw Fail(7, out) }
            return out
        }
        if !accessibility || !screenRecording {
            print(render(list))
            // Asking once puts apprentice in both lists, so the user only flips the switch.
            if !accessibility {
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                NSWorkspace.shared.open(URL(string: accessibilityPane)!)
            }
            if !screenRecording {
                _ = CGRequestScreenCaptureAccess()
                if accessibility { NSWorkspace.shared.open(URL(string: screenPane)!) }
            }
            print("\nwaiting for the grants (switch apprentice on in each pane; Ctrl+C stops)…")
            fflush(stdout)
            // A grant shows in a fresh process, so each check asks a new one.
            func grants() -> String { Repo.run(Wire.binaryPath(), ["doctor", "--grants"], in: Store.dir).out }
            let both = "accessibility=true screen=true"
            var screenPaneOpen = accessibility
            let deadline = Date().addingTimeInterval(600)
            while Date() < deadline, grants() != both {
                // One pane at a time: Screen Recording once Accessibility is on.
                if !screenPaneOpen, grants().hasPrefix("accessibility=true") {
                    NSWorkspace.shared.open(URL(string: screenPane)!)
                    screenPaneOpen = true
                }
                Thread.sleep(forTimeInterval: 2)
            }
            guard grants() == both else {
                throw Fail(7, "the grants are still missing: switch apprentice on in both panes, then run `apprentice doctor --fix` again")
            }
            print("✓ both granted")
        }
        // A daemon started before the grants does not see them.
        _ = Wire.stopDaemon()
        list = checks()
        var out = [render(list), "", "smoke test:"]
        do {
            let s = try Wire.send(Request(cmd: "session", args: ["--app", "Finder", "--no-options"]))
            guard s.code == 0 else { throw Fail(s.code, s.out) }
            let r = try Wire.send(Request(cmd: "read", args: ["--max", "3"]))
            guard r.code == 0 else { throw Fail(r.code, r.out) }
            out += ["✓ session on Finder", "✓ read: " + (r.out.split(separator: "\n").dropFirst().first.map(String.init) ?? "ok"), "", "apprentice is ready."]
        } catch let f as Fail {
            out.append("✗ \(f.message.split(separator: "\n").first ?? "")")
            throw Fail(f.code, out.joined(separator: "\n"))
        }
        return out.joined(separator: "\n")
    }

    // MARK: - uninstall

    /// `uninstall [--all] [--yes]`: without --yes it only lists what it would remove. The clone stays unless
    /// --all, since it holds the user's own commits, playbooks and session copies.
    static func uninstall(_ a: Args) throws -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let bin = home + "/.local/bin/apprentice"
        let clone = Repo.root.path
        // Only a real apprentice clone is ever removed: never a folder the playbooks happen to sit in.
        let isClone = ["Package.swift", "Sources/apprentice", ".git"].allSatisfy { fm.fileExists(atPath: clone + "/" + $0) }
        guard !a.has("all") || isClone else { throw Fail(5, "\(clone) is not an apprentice clone, so --all will not remove it; run uninstall without --all") }
        let cloneInside = isClone && clone.hasPrefix(Store.dir.path + "/")
        var plan = ["stop the daemons", "\(bin)", "the agent skills, rules sections and MCP entries kit.sh added (agent/connect.py --remove)",
                    "the signing identity \"apprentice\" in the login keychain", "the PATH lines kit.sh added to ~/.zprofile or ~/.bash_profile"]
        let vms = VM.tartPath == nil ? [] : tartVMs()
        if !vms.isEmpty { plan.append("the VMs " + vms.joined(separator: ", ")) }
        plan.append(Store.dir.path + (cloneInside && !a.has("all") ? " except the clone \(clone)" : ""))
        if a.has("all"), isClone, !cloneInside { plan.append("the clone \(clone), with its local commits") }
        guard a.has("yes") else {
            return (["uninstall would remove:"] + plan.map { "  - \($0)" }
                    + [a.has("all") ? "" : "the clone \(clone) stays (your commits and playbooks); --all removes it too",
                       "run `apprentice uninstall\(a.has("all") ? " --all" : "") --yes` to do it"]).filter { !$0.isEmpty }.joined(separator: "\n")
        }
        var done: [String] = []
        Wire.stopVMDaemons()
        _ = Wire.stopDaemon()
        let connect = URL(fileURLWithPath: clone).appendingPathComponent("agent/connect.py").path
        if fm.fileExists(atPath: connect) { done.append(Repo.run("python3", [connect, bin, "--remove"], in: Store.dir).out) }
        for vm in vms { _ = VM.tart(["stop", vm]); _ = VM.tart(["delete", vm]); done.append("deleted VM \(vm)") }
        if Repo.run("security", ["delete-identity", "-c", "apprentice"], in: Store.dir).code == 0 { done.append("removed the signing identity") }
        for profile in [home + "/.zprofile", home + "/.bash_profile"] {
            guard let text = try? String(contentsOfFile: profile, encoding: .utf8) else { continue }
            let block = "\n# apprentice\nexport PATH=\"$HOME/.local/bin:$PATH\"\n"
            if text.contains(block) {
                try? text.replacingOccurrences(of: block, with: "\n").write(toFile: profile, atomically: true, encoding: .utf8)
                done.append("removed the PATH lines from \(profile)")
            }
        }
        if (try? fm.removeItem(atPath: bin)) != nil { done.append("removed \(bin)") }
        var failed: [String] = []
        let items = (try? fm.contentsOfDirectory(atPath: Store.dir.path)) ?? []
        for item in items {
            let path = Store.dir.appendingPathComponent(item).path
            if !a.has("all"), cloneInside, clone == path || clone.hasPrefix(path + "/") { continue }
            do { try fm.removeItem(atPath: path) } catch { failed.append("\(path): \(error.localizedDescription)") }
        }
        if a.has("all") || !cloneInside { try? fm.removeItem(atPath: Store.dir.path) }
        if failed.isEmpty {
            done.append("removed \(Store.dir.path)" + (cloneInside && !a.has("all") ? " except \(clone)" : ""))
        } else {
            done.append("could not remove, still in \(Store.dir.path):\n" + failed.map { "  " + $0 }.joined(separator: "\n"))
        }
        if a.has("all"), isClone, !cloneInside { try? fm.removeItem(atPath: clone); done.append("removed \(clone)") }
        done.append("Accessibility and Screen Recording entries stay in System Settings until you remove them there")
        return done.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func tartVMs() -> [String] {
        VM.tartList()
            .filter { ($0["Source"] as? String) == "local" }
            .compactMap { $0["Name"] as? String }.filter { $0.hasPrefix("apprentice-") }
    }
}
