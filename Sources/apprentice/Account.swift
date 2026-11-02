import AppKit
import Foundation
import Security

/// The user's GitHub account: `account login | status | logout`. Signing in is GitHub's device flow for a
/// GitHub App: apprentice shows a short code, the user enters it at github.com/login/device, and apprentice
/// polls until GitHub hands over a token. There is no redirect server and no client secret. The app's own
/// permissions bound what the token can do, whatever the user's account could do.
///
/// The tokens live only in the login Keychain (this device only, never iCloud); `account.json` keeps the
/// login, the id and the expiry times, never a token. Nothing prints a token: the agent never sees one.
/// A user token lasts 8 hours and its refresh token 6 months; `token()` refreshes it when it is close to
/// running out, and each refresh replaces both, so the new refresh token is saved at once.
enum Account {
    /// The GitHub App's client ID (apprentice-cli, owned by @robertsolves; a client ID is public).
    /// `[account] client_id` or `APPRENTICE_GITHUB_CLIENT_ID` points at another app, such as a fork's.
    static let defaultClientID = "Iv23lim3xCqHYBRsM23m"
    static let keychainService = "apprentice.github"
    static let deviceURL = "https://github.com/login/device/code"
    static let tokenURL = "https://github.com/login/oauth/access_token"

    static var settings: [String: String] { Toml.load(Config.path)["account"] ?? [:] }

    static var clientID: String {
        if let env = ProcessInfo.processInfo.environment["APPRENTICE_GITHUB_CLIENT_ID"], !env.isEmpty { return env }
        return settings["client_id"].map(Toml.unquote).flatMap { $0.isEmpty ? nil : $0 } ?? defaultClientID
    }

    /// Who is signed in, as `account.json` keeps it.
    struct Profile: Codable, Equatable {
        var login: String
        var id: Int
        var name: String?
        var since: Double
        /// When the access token and the refresh token run out; nil for a token that does not expire.
        var expires: Double?
        var refreshExpires: Double?
    }

    static var profile: Profile? { Store.load(Profile.self, "account.json") }

    /// A sign-in waiting for the user to enter the code: `account login --start` writes it, `--wait` polls it
    /// and `--cancel` removes it, which ends the poll.
    struct Device: Codable {
        var deviceCode: String
        var userCode: String
        var uri: String
        var interval: Int
        var expires: Double
    }

    struct Tokens: Equatable {
        var access: String
        var refresh: String?
        var expiresIn: Double?
        var refreshExpiresIn: Double?
    }

    /// One answer while polling for the token.
    enum Poll: Equatable {
        case pending
        case slowDown(Int)
        case done(Tokens)
        case failed(String)
    }

    // MARK: - the command

    static func command(_ a: Args) throws -> String {
        switch a.pos.first ?? "status" {
        case "login":
            if a.has("start") { return try describe(start()) }
            if a.has("cancel") {
                let waiting = Store.load(Device.self, "account-pending.json") != nil
                Store.remove("account-pending.json")
                return waiting ? "the sign-in was cancelled" : "no sign-in is waiting"
            }
            if a.has("wait") {
                guard let device = Store.load(Device.self, "account-pending.json") else {
                    throw Fail(5, "no sign-in is waiting: run `apprentice account login --start` first")
                }
                return try finish(device)
            }
            let device = try start()
            let copied = copy(device.userCode)
            print("open \(device.uri) and enter the code \(device.userCode)" + (copied ? " (copied to the clipboard)" : ""))
            print("waiting for GitHub… (ctrl+c to stop)")
            fflush(stdout)
            if !a.has("no-browser"), let url = URL(string: device.uri) { NSWorkspace.shared.open(url) }
            return try finish(device)
        case "status":
            return status(live: !a.has("offline"))
        case "logout":
            guard let p = profile else {
                clear()
                return "not signed in"
            }
            clear()
            return "signed out of @\(p.login) on this Mac. GitHub still lists apprentice under your authorized apps; revoke it there to end it everywhere: https://github.com/settings/apps/authorizations"
        default:
            throw Fail(5, "account login [--start | --wait | --cancel] [--no-browser] | status [--offline] | logout")
        }
    }

    static func describe(_ d: Device) -> String {
        "code: \(d.userCode)\nurl: \(d.uri)\nexpires_s: \(max(Int(d.expires - Date().timeIntervalSince1970), 0))"
    }

    /// The code, read back from `describe`, for the window.
    static func parseStart(_ out: String) -> (code: String, url: String)? {
        var fields: [String: String] = [:]
        for line in out.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let code = fields["code"], let url = fields["url"], !code.isEmpty else { return nil }
        return (code, url)
    }

    static func status(live: Bool) -> String {
        guard let p = profile, Keychain.get("access") != nil else {
            return clientID.isEmpty
                ? "not signed in · no GitHub App is set up yet: `[account] client_id` in \(Config.path.path)"
                : "not signed in: `apprentice account login`"
        }
        var out = "signed in as @\(p.login)" + (p.name.map { " (\($0))" } ?? "")
        let now = Date().timeIntervalSince1970
        if let r = p.refreshExpires, r < now { return out + " · the sign-in ran out: `apprentice account login`" }
        if live {
            switch verify() {
            case .some(true): out += " · GitHub accepts the token"
            case .some(false): return out + " · GitHub refused the token: `apprentice account login`"
            case .none: out += " · GitHub did not answer, so the token was not checked"
            }
        }
        if let r = profile?.refreshExpires {
            out += " · sign in again by \(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: r)).prefix(10))"
        }
        return out
    }

    // MARK: - device flow

    /// Asks GitHub for a code and saves the sign-in that waits on it.
    static func start() throws -> Device {
        let id = clientID
        guard !id.isEmpty else {
            throw Fail(5, "no GitHub App is set up yet: register one with device flow on, then set `[account] client_id = \"Iv1…\"` in \(Config.path.path) (or APPRENTICE_GITHUB_CLIENT_ID)")
        }
        guard let json = post(deviceURL, ["client_id": id]) else { throw Fail(5, "GitHub did not answer: check the network and try again") }
        guard let device = parseDevice(json) else {
            // An unknown client ID answers "Not Found".
            if json["error"] as? String == "Not Found" { throw Fail(5, "GitHub does not know the client ID \(id): check `[account] client_id`") }
            throw Fail(5, "GitHub refused the sign-in: " + ((json["error_description"] ?? json["error"]) as? String ?? "no reason given"))
        }
        save(device)
        return device
    }

    /// Polls until the user enters the code, says no, or the code runs out; then saves the tokens and the
    /// profile.
    static func finish(_ device: Device) throws -> String {
        var interval = max(device.interval, 1)
        while Date().timeIntervalSince1970 < device.expires {
            Thread.sleep(forTimeInterval: Double(interval))
            // `login --cancel`, or a newer sign-in started elsewhere, ends this one.
            guard Store.load(Device.self, "account-pending.json")?.deviceCode == device.deviceCode else {
                throw Fail(5, "the sign-in was cancelled; nothing was saved")
            }
            guard let json = post(tokenURL, ["client_id": clientID, "device_code": device.deviceCode,
                                             "grant_type": "urn:ietf:params:oauth:grant-type:device_code"]) else { continue }
            switch poll(json) {
            case .pending: continue
            case .slowDown(let wait): interval = max(wait, interval + 5)
            case .failed(let why):
                Store.remove("account-pending.json")
                throw Fail(5, why)
            case .done(let tokens):
                Store.remove("account-pending.json")
                guard let user = fetchUser(tokens.access) else {
                    throw Fail(5, "GitHub gave a token but would not say whose it is; nothing was saved")
                }
                try keep(tokens, user: user)
                return "signed in as @\(user.login)"
            }
        }
        Store.remove("account-pending.json")
        throw Fail(5, "the code ran out before it was entered: `apprentice account login` for a new one")
    }

    static func parseDevice(_ json: [String: Any], now: Double = Date().timeIntervalSince1970) -> Device? {
        guard let code = json["device_code"] as? String, let user = json["user_code"] as? String,
              let uri = json["verification_uri"] as? String else { return nil }
        let expiresIn = number(json["expires_in"]) ?? 900
        return Device(deviceCode: code, userCode: user, uri: uri, interval: Int(number(json["interval"]) ?? 5),
                      expires: now + expiresIn)
    }

    static func poll(_ json: [String: Any]) -> Poll {
        if let access = json["access_token"] as? String, !access.isEmpty { return .done(tokens(json, access)) }
        switch json["error"] as? String ?? "" {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown(Int(number(json["interval"]) ?? 0))
        case "expired_token": return .failed("the code ran out before it was entered: `apprentice account login` for a new one")
        case "access_denied": return .failed("the sign-in was cancelled on GitHub; nothing was saved")
        case "device_flow_disabled": return .failed("the GitHub App does not have device flow turned on (its settings ▸ Enable Device Flow)")
        case "incorrect_client_credentials": return .failed("GitHub does not know that client ID: check `[account] client_id`")
        case let other:
            return .failed("GitHub refused the sign-in: " + ((json["error_description"] as? String) ?? (other.isEmpty ? "no reason given" : other)))
        }
    }

    static func tokens(_ json: [String: Any], _ access: String) -> Tokens {
        Tokens(access: access, refresh: json["refresh_token"] as? String, expiresIn: number(json["expires_in"]),
               refreshExpiresIn: number(json["refresh_token_expires_in"]))
    }

    // MARK: - the token, for what comes next (error reports)

    /// A token that works now, refreshed first when it runs out within five minutes. Nil when nobody is
    /// signed in or the sign-in ran out. Blocks: never on the main thread.
    static func token(now: Double = Date().timeIntervalSince1970) -> String? {
        guard let p = profile, let access = Keychain.get("access") else { return nil }
        guard let expires = p.expires, expires - now < 300 else { return access }
        guard let refresh = Keychain.get("refresh"), (p.refreshExpires ?? .infinity) > now,
              let json = post(tokenURL, ["client_id": clientID, "grant_type": "refresh_token", "refresh_token": refresh]),
              case .done(let fresh) = poll(json) else { return nil }
        // The old refresh token no longer works once GitHub answered: save the new one before anything else.
        try? keep(fresh, user: User(login: p.login, id: p.id, name: p.name), since: p.since)
        return fresh.access
    }

    struct User: Equatable {
        var login: String
        var id: Int
        var name: String?
    }

    static func keep(_ t: Tokens, user: User, since: Double? = nil, now: Double = Date().timeIntervalSince1970) throws {
        guard Keychain.set("access", t.access) else { throw Fail(1, "the Keychain refused the token; nothing was saved") }
        if let r = t.refresh { _ = Keychain.set("refresh", r) } else { Keychain.delete("refresh") }
        Store.save(Profile(login: user.login, id: user.id, name: user.name, since: since ?? now,
                           expires: t.expiresIn.map { now + $0 }, refreshExpires: t.refreshExpiresIn.map { now + $0 }),
                   "account.json")
    }

    static func clear() {
        Keychain.delete("access")
        Keychain.delete("refresh")
        Store.remove("account.json")
        Store.remove("account-pending.json")
    }

    // MARK: - GitHub

    static func fetchUser(_ token: String) -> User? {
        guard let json = get("https://api.github.com/user", token: token).json,
              let login = json["login"] as? String, let id = number(json["id"]) else { return nil }
        return User(login: login, id: Int(id), name: (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// True when GitHub accepts the token, false when it refuses it, nil when it did not answer.
    static func verify() -> Bool? {
        guard let token = token() else { return false }
        let r = get("https://api.github.com/user", token: token)
        guard let code = r.code else { return nil }
        return code == 200 ? true : (code == 401 ? false : nil)
    }

    private static func post(_ url: String, _ fields: [String: String]) -> [String: Any]? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("apprentice/\(Build.number)", forHTTPHeaderField: "User-Agent")
        var form = URLComponents()
        form.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        return send(req).json
    }

    private static func get(_ url: String, token: String) -> (code: Int?, json: [String: Any]?) {
        guard let u = URL(string: url) else { return (nil, nil) }
        var req = URLRequest(url: u, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("apprentice/\(Build.number)", forHTTPHeaderField: "User-Agent")
        let r = send(req)
        return (r.code, r.code == 200 ? r.json : nil)
    }

    private static func send(_ req: URLRequest) -> (code: Int?, json: [String: Any]?) {
        let done = DispatchSemaphore(value: 0)
        var code: Int?
        var json: [String: Any]?
        URLSession.shared.dataTask(with: req) { data, response, _ in
            code = (response as? HTTPURLResponse)?.statusCode
            json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + req.timeoutInterval + 5)
        return (code, json)
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        return (v as? String).flatMap(Double.init)
    }

    private static func save(_ device: Device) {
        Store.save(device, "account-pending.json")
        // The device code is a short-lived secret of its own: this user only.
        chmod(Store.url("account-pending.json").path, 0o600)
    }

    private static func copy(_ text: String) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        return board.setString(text, forType: .string)
    }

    /// The tokens, as generic passwords in the login Keychain that stay on this device.
    enum Keychain {
        private static func query(_ account: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
             kSecAttrAccount as String: account]
        }

        static func get(_ account: String) -> String? {
            var q = query(account)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }

        static func set(_ account: String, _ value: String) -> Bool {
            delete(account)
            var item = query(account)
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel as String] = "apprentice GitHub sign-in"
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }

        static func delete(_ account: String) {
            SecItemDelete(query(account) as CFDictionary)
        }
    }
}
