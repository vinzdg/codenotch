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
    /// `interactive` is whether this read may raise the password dialogue.
    /// Only a person clicking "Allow access…" passes true — see
    /// `ClaudeKeychain.askAgain`. Everything on a timer passes false.
    static func read(services: [String], interactive: Bool = false) throws -> ClaudeCredentials {
        guard let winner = KeychainItem.newest(services: services) else {
            Log.usage.error("keychain read failed: no item under \(services.joined(separator: ", "), privacy: .public)")
            throw UsageProviderError.needsAuth
        }

        // Never prompts unless a person asked — see `KeychainSecret.read`. A
        // refusal is retried through `/usr/bin/security` under the account
        // Claude Code files these items with, which is this user's.
        let (status, item) = KeychainSecret.read(
            query: [
                kSecClass: kSecClassGenericPassword,
                kSecValuePersistentRef: winner.persistentRef,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne
            ],
            interactive: interactive,
            rescue: (service: winner.service, account: NSUserName())
        )

        guard status == errSecSuccess, let data = item else {
            // The status matters: "not found" means the item was deleted
            // between enumeration and this read — Claude Code rotating at the
            // exact wrong instant — whereas -25308 (interaction not allowed) or
            // -128 (user cancelled) mean it is there and this app is not on its
            // access list. Those need very different advice, so record which.
            Log.usage.error("keychain read of \(services.joined(separator: ", "), privacy: .public) failed: OSStatus \(status) (\(Self.explain(status), privacy: .public))")
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

        return try decode(data, services: services)
    }

    /// Turn the stored JSON into a credential. Shared by both readers, so a
    /// rescued read is judged exactly as a direct one is — and by the remote
    /// reader, for which the SSH output is the same document over a wire.
    static func decode(_ data: Data, services: [String]) throws -> ClaudeCredentials {
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
            Log.usage.error("\(services.joined(separator: ", "), privacy: .public) holds an emptied credential — needs a fresh sign-in")
            throw UsageProviderError.signedOutByOwner
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

    /// A read that failed for a reason with nothing to do with the account.
    ///
    /// -25320, "in dark wake, no UI possible", is what a Mac answers for a
    /// short window right after waking from sleep — the keychain will not
    /// raise a dialogue while the display is still off, whether or not one
    /// would be needed. Security doesn't export a named constant for it, so
    /// the raw value is what there is to check.
    static func wasTransient(_ status: OSStatus) -> Bool {
        status == -25320       // errSecInDarkWake
            // errAuthorizationInternal. What a refusal looks like when macOS
            // decided a prompt was needed and there was no way to show one —
            // observed five seconds before a clamshell sleep. The credential is
            // untouched, so this is "not right now", not "signed out"; left to
            // fall through it read as `needsAuth` and showed a valid account
            // as signed out for 2h42m.
            || status == -60008
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
    let services: [String]

    /// Read once, then held until the token expires — see `CredentialCache`.
    /// Claude Code rotates this roughly hourly, so this is about one keychain
    /// read an hour instead of two a minute.
    ///
    /// Only `.accessDenied` is permanent — a real "Deny" on the ACL prompt.
    /// Everything else `ClaudeCredentials.read` can throw, `needsAuth`
    /// included, gets retried after the cache's own backoff even while the
    /// item's `mdat` has not moved: found on a real machine, a single keychain
    /// read landing during `errSecInDarkWake` — the Mac in a brief low-power
    /// wake with no UI possible, nothing to do with the credential at all —
    /// was cached as `needsAuth` and replayed for the next three hours, since
    /// nothing else ever touched the item again once it held a valid token.
    private let cache = CredentialCache<ClaudeCredentials>(
        isPermanentFailure: { if case UsageProviderError.accessDenied = $0 { return true }; return false },
        isExpired: { $0.isExpired }
    )

    private let reader: (_ services: [String], _ interactive: Bool) throws -> ClaudeCredentials
    private let prompt: PromptPermission
    private let refusal: KeychainRefusal

    /// How long an unanswered "Allow access…" stays good for.
    static let promptWindow = PromptPermission.window

    init(services: [String],
         now: @escaping () -> Date = Date.init,
         refusals: UserDefaults? = nil,
         reader: @escaping (_ services: [String], _ interactive: Bool) throws -> ClaudeCredentials
            = { try ClaudeCredentials.read(services: $0, interactive: $1) }) {
        self.services = services
        self.prompt = PromptPermission(now: now)
        self.refusal = KeychainRefusal(key: services.first ?? "claude", defaults: refusals)
        self.reader = reader
    }

    /// The app's preferences in the app. Under test the host *is* the
    /// installed app, so its real answer would decide what the tests read.
    convenience init(profile: ClaudeProfile) {
        self.init(services: profile.keychainServices,
                  refusals: Runtime.isUnderTest ? nil : .standard)
    }

    /// The person said no to this login and has not asked again. While true,
    /// nothing reads it — not the keychain, not the security tool, and not the
    /// sources that never needed the keychain either; see `ClaudeOAuthProvider`.
    var isRefused: Bool { refusal.isRefused && !prompt.isOwed }

    /// "Allow access…" was clicked and its read has not happened yet.
    var isAskingAgain: Bool { prompt.isOwed }

    /// The default profile's reader, shared so that every caller that predates
    /// profiles keeps sharing one cache — and so one prompt. Uses the default
    /// profile's full candidate list, so it finds the token whether Claude Code
    /// filed it under the bare name or the suffixed one.
    static let `default` = ClaudeKeychain(services: ClaudeProfile.default().keychainServices)

    /// Reads whatever is stored, expired or not. Judging expiry is the caller's
    /// job, because "signed out" and "the token has aged out overnight" call for
    /// different behaviour and only one of them is worth alarming anyone about.
    func load() throws -> ClaudeCredentials {
        if isRefused { throw UsageProviderError.accessDenied }
        return try cache.value(
            itemModifiedAt: { KeychainItem.modifiedAt(services: services) },
            reload: { [self] in
                let interactive = prompt.take()
                do {
                    let credentials = try reader(services, interactive)
                    // Answered with Allow: the earlier no no longer stands.
                    if interactive { refusal.set(false) }
                    return credentials
                } catch UsageProviderError.accessDenied where interactive {
                    // Only the dialogue's own answer is recorded. A background
                    // read refused without asking is not anyone saying no.
                    refusal.set(true)
                    throw UsageProviderError.accessDenied
                }
            }
        )
    }

    /// Forget the held copy. Call when the server rejects it: signing into a
    /// different account replaces the keychain item, and the copy in hand is
    /// then wrong despite not having expired.
    func forgetCached() { cache.forget() }

    /// A person asked macOS for this login again: let the next read show the
    /// dialogue. The only caller that may — `forgetCached` is also what the
    /// server rejecting a token and the token refresher call, and neither of
    /// those is someone clicking a button.
    func askAgain() {
        prompt.grant()
        cache.forget()
    }
}
