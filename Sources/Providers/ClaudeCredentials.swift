import Foundation
import Security

/// The OAuth token Claude Code keeps in the login keychain.
///
/// Codenotch only ever *reads* this item. Refreshing is deliberately left to
/// Claude Code: minting a new token would mean writing a credential this app
/// does not own, so when the token expires the notch says `needsAuth` and waits
/// for Claude Code to refresh it in the ordinary course of being used.
struct ClaudeCredentials {
    let accessToken: String
    let expiresAt: Date
    /// "pro", "max", and so on — enough to show which plan the readings are for.
    let subscriptionType: String?

    var isExpired: Bool { expiresAt <= Date() }

    /// The service the default profile's token is filed under. Other profiles
    /// get a suffix — see `ClaudeProfile.keychainService`.
    static let service = ClaudeProfile.defaultKeychainService

    /// Reads the default profile. Kept for callers that predate profiles.
    static func load() throws -> ClaudeCredentials { try ClaudeKeychain.default.load() }
    static func forgetCached() { ClaudeKeychain.default.forgetCached() }

    /// The keychain read itself, for one service name.
    ///
    /// `ClaudeKeychain` decides *whether* to read; this is what happens when it
    /// does. Every failure is turned into the status the UI should show, and
    /// the raw OSStatus is logged so "not found" and "refused" stay distinct.
    ///
    /// Reads the newest item under this service, rather than asking for "one"
    /// and trusting the answer. Claude Code files a new item on every token
    /// rotation instead of updating one in place, so an account used for
    /// months accumulates several under the same service name. A plain
    /// `kSecMatchLimitOne` query gives no ordering guarantee across them, and
    /// the failure it produces is silent: the app reads an old, expired
    /// duplicate, the ring shows "Waiting for the first reading…" forever, and
    /// nothing about that message suggests a valid token is sitting right next
    /// to the one that was picked. `KeychainItem.newest` finds it via
    /// attributes and a persistent reference, neither of which needs
    /// authorization to read — only this second, targeted fetch of the
    /// winner's actual data does, which is why it costs the same single prompt
    /// as before, per profile.
    static func read(service: String) throws -> ClaudeCredentials {
        // Never raise a password dialogue from a poll. A menu-bar app on a
        // timer has no business interrupting anyone, and this particular
        // dialogue is one the user cannot get rid of: it comes from the item's
        // *partition list*, not its access list, and "Always Allow" only
        // writes the access list. Approving it buys exactly one read.
        //
        // `kSecUseAuthenticationUI` below is set for the same reason and is not
        // enough on its own — it governs the data-protection keychain, and
        // anything carrying a partition list is the old file-backed kind.
        // Legacy items honour this call instead. With only the key set, the
        // prompt still appeared once a minute.
        //
        // Process-wide, so it is restored in a `defer` on every path: leaving
        // interaction off would silently break a prompt some other part of the
        // app legitimately wants to show.
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }

        guard let winner = KeychainItem.newest(service: service) else {
            Log.usage.error("keychain read failed: no item under \(service, privacy: .public)")
            throw UsageProviderError.needsAuth
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecValuePersistentRef: winner.persistentRef,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationUI: kSecUseAuthenticationUIFail
        ] as CFDictionary, &item)

        // Refused, but the item is right there. Ask the one reader macOS never
        // refuses before giving up — see `readViaSecurityTool`.
        if Self.wasRefused(status), let rescued = Self.readViaSecurityTool(service: service) {
            Log.usage.notice("\(service, privacy: .public) read via the security tool after a partition refusal")
            return try decode(rescued, service: service)
        }

        guard status == errSecSuccess, let data = item as? Data else {
            // The status matters: "not found" means the item was deleted
            // between enumeration and this read — Claude Code rotating at the
            // exact wrong instant — whereas -25308 (interaction not allowed) or
            // -128 (user cancelled) mean it is there and this app is not on its
            // access list. Those need very different advice, so record which.
            Log.usage.error("keychain read of \(service, privacy: .public) failed: OSStatus \(status) (\(Self.explain(status), privacy: .public))")
            // A machine just woken from a long sleep answers -25320 — awake
            // enough to run background work, not awake enough to show a
            // dialogue even if one were needed. The credential is unaffected;
            // asking again in a moment succeeds on its own. `.needsAuth` is
            // the wrong answer for it: `supersedesHistory` treats a genuine
            // sign-out as reason to erase the archived reading, and reported
            // as "waiting for the first reading" what was really a few
            // seconds of "not right now" — throwing away a perfectly good
            // number for something that was never actually wrong.
            // `.credentialExpired` already means exactly this — "still true,
            // just old" — for a token that aged out overnight; reused here
            // for the same shape of problem arriving a different way.
            if Self.wasTransient(status) { throw UsageProviderError.credentialExpired }
            throw Self.wasRefused(status)
                ? UsageProviderError.accessDenied
                : UsageProviderError.needsAuth
        }

        return try decode(data, service: service)
    }

    /// Turn the stored JSON into a credential. Shared by both readers, so a
    /// rescued read is judged identically to a direct one.
    private static func decode(_ data: Data, service: String) throws -> ClaudeCredentials {
        struct Payload: Decodable {
            struct OAuth: Decodable {
                let accessToken: String
                /// Milliseconds since the epoch.
                let expiresAt: Double
                let subscriptionType: String?
            }
            let claudeAiOauth: OAuth
        }

        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(Payload.self, from: data) else {
            throw UsageProviderError.needsAuth
        }

        // A present-but-emptied credential is a real state, not a theoretical
        // one: Claude Code rewrites this item with `accessToken: ""`, no
        // refresh token and `expiresAt: 0`. It decodes perfectly and is worth
        // nothing. Left alone it becomes `Bearer ` on the wire and a puzzling
        // 401. Reporting it as `needsAuth` is worse still — that means "never
        // signed in", which makes `supersedesHistory` erase a perfectly good
        // archived reading every time the owning app does this.
        guard !payload.claudeAiOauth.accessToken.isEmpty else {
            Log.usage.error("\(service, privacy: .public) holds an emptied credential — needs a fresh sign-in")
            throw UsageProviderError.signedOutByOwner
        }

        return ClaudeCredentials(
            accessToken: payload.claudeAiOauth.accessToken,
            expiresAt: Date(timeIntervalSince1970: payload.claudeAiOauth.expiresAt / 1000),
            subscriptionType: payload.claudeAiOauth.subscriptionType
        )
    }

    /// Read the item by shelling out to `/usr/bin/security`.
    ///
    /// The last resort, and the only one that survives what actually breaks
    /// this. Claude Code does not update its keychain items, it recreates them
    /// on every token rotation, and a freshly created item's partition list
    /// contains just `apple-tool:`. Every app with a Team ID — this one
    /// included — is evicted the moment that happens, and the only way back in
    /// is the login password. `/usr/bin/security` is Apple-signed, so it *is*
    /// `apple-tool:` and is never the one refused. Claude Code writes these
    /// items through it, which is why it is always on the access list too.
    ///
    /// Not the primary path: it costs a process per read, and the direct
    /// `SecItemCopyMatching` above is both cheaper and the honest way to ask.
    /// This runs only after a refusal.
    private static func readViaSecurityTool(service: String) -> Data? {
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        // `-w` prints only the password. The account is this user, matching
        // how Claude Code files it.
        tool.arguments = ["find-generic-password", "-a", NSUserName(), "-s", service, "-w"]
        let out = Pipe()
        tool.standardOutput = out
        tool.standardError = Pipe()
        do {
            try tool.run()
        } catch {
            Log.usage.error("could not run the security tool: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // Read before waiting: a full pipe buffer with nobody draining it is a
        // deadlock, and this payload is comfortably under the limit only until
        // Claude Code adds another key to it.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        tool.waitUntilExit()
        guard tool.terminationStatus == 0 else { return nil }
        // `-w` ends its output with a newline; an empty answer has to stay
        // distinguishable from a newline-only one.
        var trimmed = data
        while trimmed.last == 0x0A || trimmed.last == 0x0D { trimmed.removeLast() }
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Which keychain refusal this was. "Not found" means Claude Code has never
    /// signed in; -25308 or -128 mean the item exists but this app is not on its
    /// access list. Those need entirely different advice, so the log says which.
    /// Whether macOS refused a credential that exists, rather than failing to
    /// find one.
    ///
    /// `errSecAuthFailed` and `userCanceled` are what Deny produces;
    /// `interactionNotAllowed` is the same refusal arriving without a prompt.
    /// All three mean the item is there and we were not let in.
    static func wasRefused(_ status: OSStatus) -> Bool {
        status == errSecAuthFailed
            || status == errSecUserCanceled
            || status == errSecInteractionNotAllowed
    }

    /// A read that failed for a reason with nothing to do with the account.
    ///
    /// -25320, "in dark wake, no UI possible", is what a Mac answers for a
    /// short window right after waking from sleep — the keychain will not
    /// raise a dialogue while the display is still off, whether or not one
    /// would be needed. Security doesn't export a named constant for it, so
    /// the raw value is what there is to check.
    static func wasTransient(_ status: OSStatus) -> Bool {
        status == -25320   // errSecInDarkWake
    }

    static func explain(_ status: OSStatus) -> String {
        switch status {
        case errSecItemNotFound:          return "no such item — Claude Code has not signed in"
        case errSecInteractionNotAllowed: return "access not permitted without interaction"
        case errSecUserCanceled:          return "the access prompt was dismissed or denied"
        case errSecAuthFailed:            return "authorisation failed"
        default:
            return (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown"
        }
    }
}

/// One profile's token, read as rarely as the keychain allows.
///
/// One of these per `ClaudeProfile`, because each profile's token is a separate
/// keychain item with its own access list: macOS prompts once per item, and a
/// cache shared between them would hand the personal token to the work ring.
final class ClaudeKeychain: @unchecked Sendable {
    let service: String

    /// Read once, then held until the token expires — see `CredentialCache`.
    /// Claude Code rotates this roughly hourly, so this is about one keychain
    /// read an hour instead of two a minute.
    private let cache = CredentialCache<ClaudeCredentials> { $0.isExpired }

    init(service: String) {
        self.service = service
    }

    convenience init(profile: ClaudeProfile) {
        self.init(service: profile.keychainService)
    }

    /// The default profile's reader, shared so that every caller that predates
    /// profiles keeps sharing one cache — and so one prompt.
    static let `default` = ClaudeKeychain(service: ClaudeProfile.defaultKeychainService)

    /// Reads whatever is stored, expired or not. Judging expiry is the caller's
    /// job, because "signed out" and "the token has aged out overnight" call for
    /// different behaviour and only one of them is worth alarming anyone about.
    func load() throws -> ClaudeCredentials {
        try cache.value(
            itemModifiedAt: { KeychainItem.modifiedAt(service: service) },
            reload: { try ClaudeCredentials.read(service: service) }
        )
    }

    /// Forget the held copy. Call when the server rejects it: signing into a
    /// different account replaces the keychain item, and the copy in hand is
    /// then wrong despite not having expired.
    func forgetCached() { cache.forget() }
}
