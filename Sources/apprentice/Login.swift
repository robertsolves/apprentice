import Foundation
import Security

/// Signing in, when the user turns it on (`[login] auto = true`, off by default). `type <id> --secret
/// username|password` types the account or password saved for the page's site in the login Keychain;
/// `--secret code` asks the user for the code the site texted, emailed or shows in their authenticator
/// app (the little window, else the chat with a phone push) and types it. Secrets never pass through
/// the command line, the agent or the logs: apprentice reads them only at the moment it types.
enum Login {
    static let kinds: Set<String> = ["username", "password", "code"]

    /// What a site shows when it wants a sign-in code. With login on these are not a challenge: the
    /// agent finds the field and runs `type <id> --secret code`.
    static let codeMarkers = [
        "enter the code", "verification code", "security code", "two-factor", "2-step verification",
        "two-step verification", "one-time code", "one-time password", "authentication code", "we sent a code",
        "we texted", "sent a code", "enter code", "login code", "sign-in code", "authenticator app",
    ]

    /// Login is on for this site: `[login] auto`, and the site is in `[login] sites` when that lists any.
    static func allowed(_ host: String?) -> Bool {
        let c = Config.current
        guard c.loginAuto, let host else { return false }
        return c.loginSites.isEmpty || c.loginSites.contains { Site.matches(host, $0) }
    }

    /// A challenge marker that is a sign-in code prompt rather than a CAPTCHA or identity check.
    static func isCodePrompt(_ marker: String) -> Bool {
        let m = marker.lowercased()
        return codeMarkers.contains { m.contains($0) }
    }

    /// The step being proposed types a secret on a site where login is on. Its credential warning is
    /// then one the agent may approve: the user turned login on for the site.
    static func secretStep(_ url: String?) -> Bool {
        let r = Approvals.request
        return r.cmd == "type" && Args.parse(r.args).value("secret") != nil && allowed(hostOf(url))
    }

    /// Checks a `type --secret` request before it is proposed. Returns the gate summary.
    static func check(_ kind: String, url: String?, field: Element) throws -> String {
        guard kinds.contains(kind) else { throw Fail(5, "type <id> --secret username|password|code") }
        guard let host = hostOf(url) else { throw Fail(5, "--secret works on a web page only") }
        guard Config.current.loginAuto else {
            throw Fail(4, "signing in is off. The user can turn it on with `[login] auto = true` in ~/.apprentice/config.toml; until then they sign in themselves")
        }
        guard allowed(host) else { throw Fail(4, "signing in is off for \(Site.domain(host)): it is not in `[login] sites`") }
        let domain = Site.domain(host)
        switch kind {
        case "password":
            // A password is typed only into a password field, on an https page of the site it was saved for.
            guard URL(string: url ?? "")?.scheme == "https" else { throw Fail(4, "not typing a password into a page that is not https") }
            guard field.label == "password" else { throw Fail(5, "\(field.short) is not a password field; a saved password goes only into one") }
            try paced(domain)
            return "type the password saved for \(domain) into \(field.short)"
        case "username":
            guard field.label != "password" else { throw Fail(5, "\(field.short) is a password field; use --secret password") }
            return "type the account saved for \(domain) into \(field.short)"
        default:
            return "ask the user for the sign-in code \(domain) sent, then type it into \(field.short)"
        }
    }

    /// The text to type, read only once the step is approved. `--code` is the code the user gave in the chat.
    static func value(_ kind: String, url: String?, _ a: Args) throws -> String {
        let host = hostOf(url) ?? ""
        let domain = Site.domain(host)
        if kind == "code" {
            if let given = a.value("code")?.trimmingCharacters(in: .whitespaces), !given.isEmpty { return given }
            return try askCode(domain, a)
        }
        guard let saved = saved(host) else {
            throw Fail(5, "nothing is saved for \(domain) in the Keychain. The user can save it with `apprentice login add \(domain)`, or sign in themselves")
        }
        // Checked now, counted once the characters are in the field (`typed`), so a step that fails costs nothing.
        if kind == "password" { try paced(domain) }
        return kind == "password" ? saved.password : saved.account
    }

    /// The little window, else the chat (exit 9) with a phone push. A skip means the user entered it on
    /// the page themselves, or does not want to.
    static func askCode(_ domain: String, _ a: Args) throws -> String {
        let id = a.pos.first ?? "<id>"
        let chat = ["question: \(domain) sent a sign-in code (by text, email or the authenticator app). What is it?",
                    "Once they answer, run `apprentice type \(id) --secret code --code <their code>`; nothing was typed yet."]
        let push = "\(domain) needs the sign-in code it just sent you"
        Store.log(["ask": "sign-in code for \(domain)"])
        if Ask.away { throw Ask.handOff(chat, push: push) }
        let caller = Ask.caller
        let reply = DispatchQueue.main.sync {
            Ask.show("\(domain) wants the sign-in code it sent you (text, email or authenticator app). Type it here and apprentice enters it, or press Skip and enter it on the page yourself.",
                     choices: [], multi: false, withText: true, timeout: Ask.windowTime(300), sendTitle: "Enter",
                     placeholder: "Code", caller: caller)
        }
        guard let reply else {
            if Config.current.askIn != "window" { throw Ask.handOff(chat, push: push) }
            throw Fail(5, "no code: the question timed out. Nothing was typed")
        }
        KillSwitch.halted = false
        let code = reply.text.trimmingCharacters(in: .whitespaces)
        guard !reply.skipped, !code.isEmpty else {
            throw Fail(5, "no code typed: the user skipped. They may have entered it on the page themselves; check with `read`")
        }
        return code
    }

    // MARK: - Pacing

    /// When each site was last signed into: the password typed, shared by every VM's daemon.
    static let file = "logins.json"
    static var attempts: [String: [Double]] { Store.load([String: [Double]].self, file) ?? [:] }

    /// A site that signs the account out is signed back into, but never in a burst: a sign-in page again
    /// within `[login] gap_min` means the last one failed or the site wants a person, and more than
    /// `[login] per_day` sign-ins a day look like a bot. Either stops for the user (exit 4).
    static func paced(_ domain: String, now: Double = Date().timeIntervalSince1970, tries: [Double]? = nil) throws {
        let tries = (tries ?? attempts[domain] ?? []).filter { now - $0 < 86_400 }
        let c = Config.current
        if let last = tries.max(), now - last < c.loginGapMinutes * 60 {
            throw Fail(4, "sign-in: \(domain) was signed into at \(Site.time(last)), under \(Int(c.loginGapMinutes)) min ago. A sign-in page this soon means that one failed or the site wants a person: do not retry, tell the user")
        }
        if tries.count >= c.loginPerDay {
            throw Fail(4, "sign-in: \(domain) was signed into \(tries.count) times today ([login] per_day). Do not retry, tell the user")
        }
    }

    /// Counts a password sign-in after it was typed.
    static func typed(_ kind: String?, url: String?) {
        guard kind == "password" else { return }
        try? record(Site.domain(hostOf(url) ?? ""))
    }

    static func record(_ domain: String) throws {
        try Store.locked(file) {
            try paced(domain)
            var all = attempts
            let now = Date().timeIntervalSince1970
            all[domain] = (all[domain] ?? []).filter { now - $0 < 86_400 } + [now]
            Store.save(all, file)
        }
        Events.add(domain, "sign_in", [:])
    }

    /// The line `read` and every action add when a page of a site with login on asks for a password.
    static func signedOut(_ s: Snapshot) -> String? {
        guard let host = hostOf(s.url), allowed(host), let field = s.elements.first(where: { $0.label == "password" }) else { return nil }
        let domain = Site.domain(host)
        do { try paced(domain) } catch let stop as Fail { return stop.message } catch {}
        return "sign-in: \(domain) asks for a password (\(field.id)). If the account was signed out, sign back in: `type <account field id> --secret username`, then `type \(field.id) --secret password --enter`, then `read`; a code prompt takes `--secret code`"
    }

    // MARK: - Keychain

    /// The internet password saved for the host, its site, or www. of it, from the login Keychain.
    /// Matched by server, so a look-alike domain finds nothing.
    static func saved(_ host: String) -> (account: String, password: String)? {
        let domain = Site.domain(host)
        for server in [host, domain, "www.\(domain)"] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: server,
                kSecReturnAttributes as String: true, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var out: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let item = out as? [String: Any],
                  let data = item[kSecValueData as String] as? Data, let password = String(data: data, encoding: .utf8) else { continue }
            return (item[kSecAttrAccount as String] as? String ?? "", password)
        }
        return nil
    }

    /// `login add <domain>`: the user types the account and password into the little window, and they are
    /// saved to the login Keychain. `login remove <domain>`, `login status [domain]`.
    static func command(_ a: Args) throws -> String {
        let sub = a.pos.first ?? "status"
        let domain = a.pos.dropFirst().first.map { Site.domain($0.lowercased()) }
        switch sub {
        case "add":
            guard let domain else { throw Fail(5, "login add <domain>") }
            let caller = Ask.caller
            let account = DispatchQueue.main.sync {
                Ask.show("Save a sign-in for \(domain) in your Keychain. Your account (email or username):",
                         choices: [], multi: false, withText: true, timeout: 300, sendTitle: "Next", placeholder: "Account", caller: caller)
            }
            guard let account, !account.skipped, !account.text.isEmpty else { throw Fail(5, "nothing saved: the user skipped") }
            let password = DispatchQueue.main.sync {
                Ask.show("The password for \(account.text) on \(domain). It goes straight to your Keychain; the agent never sees it.",
                         choices: [], multi: false, withText: true, timeout: 300, sendTitle: "Save", placeholder: "Password",
                         caller: caller, secure: true)
            }
            guard let password, !password.skipped, !password.text.isEmpty else { throw Fail(5, "nothing saved: the user skipped") }
            SecItemDelete([kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: domain] as CFDictionary)
            let item: [String: Any] = [
                kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: domain,
                kSecAttrProtocol as String: kSecAttrProtocolHTTPS, kSecAttrAccount as String: account.text,
                kSecAttrLabel as String: "\(domain) (apprentice)", kSecValueData as String: Data(password.text.utf8),
            ]
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw Fail(1, "the Keychain refused it (\(status))") }
            // A new password is the user's fix for failed sign-ins: the site may be tried again.
            Store.locked(file) { var all = attempts; all[domain] = nil; Store.save(all, file) }
            Events.add(domain, "login_saved", [:])
            return "saved a sign-in for \(domain) in the login Keychain" + (allowed(domain) ? "" : ". Signing in is off there: `[login] auto = true` turns it on")
        case "remove":
            guard let domain else { throw Fail(5, "login remove <domain>") }
            let status = SecItemDelete([kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: domain] as CFDictionary)
            return status == errSecSuccess ? "removed the sign-in for \(domain)" : "nothing saved for \(domain)"
        case "status":
            let on = Config.current.loginAuto
            var out = ["login: " + (on ? "on" + (Config.current.loginSites.isEmpty ? " for every site" : " for " + Config.current.loginSites.joined(separator: ", "))
                                       : "off ([login] auto = true turns it on)")]
            if let domain { out.append("\(domain): " + (saved(domain) == nil ? "nothing saved" : "a sign-in is saved")) }
            return out.joined(separator: "\n")
        default:
            throw Fail(5, "login add|remove|status <domain>")
        }
    }
}
