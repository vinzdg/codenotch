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
        guard let winner = KeychainItem.newest(service: service) else {
            Log.usage.error("keychain read failed: no item under \(service, privacy: .public)")
            throw UsageProviderError.needsAuth
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecValuePersistentRef: winner.persistentRef,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &item)

        guard status == errSecSuccess, let data = item as? Data else {
            // The status matters: "not found" means the item was deleted
            // between enumeration and this read — Claude Code rotating at the
            // exact wrong instant — whereas -25308 (interaction not allowed) or
            // -128 (user cancelled) mean it is there and this app is not on its
            // access list. Those need very different advice, so record which.
            Log.usage.error("keychain read of \(service, privacy: .public) failed: OSStatus \(status) (\(Self.explain(status), privacy: .public))")
            throw Self.wasRefused(status)
                ? UsageProviderError.accessDenied
                : UsageProviderError.needsAuth
        }

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

        return ClaudeCredentials(
            accessToken: payload.claudeAiOauth.accessToken,
            expiresAt: Date(timeIntervalSince1970: payload.claudeAiOauth.expiresAt / 1000),
            subscriptionType: payload.claudeAiOauth.subscriptionType
        )
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
