import Foundation
import Security

/// Who is on the other end of the socket. A request's `user` flag (the app's own click, which approves
/// `[gate] user_only` steps) is honoured only from the app bundle itself: anything else that writes
/// `"user": true` to `~/.apprentice/sock`, an agent included, is treated as an agent.
///
/// The peer is named by its audit token (never a pid, which can be reused), and its running code must be
/// valid, carry the app's identifier, and be signed like this daemon: the same certificate when apprentice is
/// signed with an identity, else the exact code of the installed bundle (ad hoc, which a same-user process
/// could re-sign, so `kit.sh` signs with an identity where there is one).
enum Peer {
    private static let localPeerToken: Int32 = 0x006  // LOCAL_PEERTOKEN in <sys/un.h>

    /// True when the process on `fd` is the signed Apprentice.app.
    static func isApp(_ fd: Int32) -> Bool {
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, localPeerToken, &token, &len) == 0 else { return false }
        let data = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess,
              let code, SecCodeCheckValidity(code, [], nil) == errSecSuccess, startedAsWindow(token),
              let info = signing(code), info[kSecCodeInfoIdentifier as String] as? String == AppBundle.identifier else { return false }
        if let mine = leaf(selfInfo()) { return leaf(info) == mine }
        // Ad hoc: only the code of the bundle `apprentice app` installed.
        var bundle: SecStaticCode?
        guard SecStaticCodeCreateWithPath(AppBundle.path as CFURL, [], &bundle) == errSecSuccess, let bundle,
              let installed = staticSigning(bundle)?[kSecCodeInfoUnique as String] as? Data else { return false }
        return info[kSecCodeInfoUnique as String] as? Data == installed
    }

    /// The window and the CLI are one executable, so the identity alone no longer says which one this is:
    /// the window is the copy started with no arguments, as the Dock and Spotlight start it.
    private static func startedAsWindow(_ token: audit_token_t) -> Bool {
        let pid = Int32(bitPattern: token.val.5)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size >= MemoryLayout<Int32>.size else { return false }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size >= MemoryLayout<Int32>.size else { return false }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        return argc <= 1
    }

    private static func signing(_ code: SecCode) -> [String: Any]? {
        var stat: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &stat) == errSecSuccess, let stat else { return nil }
        return staticSigning(stat)
    }

    private static func staticSigning(_ code: SecStaticCode) -> [String: Any]? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return info as? [String: Any]
    }

    private static func selfInfo() -> [String: Any]? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        return signing(me)
    }

    /// The signing certificate's bytes, or nil for ad hoc code.
    private static func leaf(_ info: [String: Any]?) -> Data? {
        guard let certs = info?[kSecCodeInfoCertificates as String] as? [SecCertificate], let first = certs.first else { return nil }
        return SecCertificateCopyData(first) as Data
    }
}
