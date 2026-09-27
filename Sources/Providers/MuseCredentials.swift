import Foundation
import Security

/// Where Muse Code keeps its account and its logs. Both are read-only: the
/// notch borrows what the CLI wrote and never signs in, refreshes, or writes.
enum MuseCredentials {
    /// The login keychain item the CLI mints its API key into.
    static let keychainService = "ai.meta.dev.credentials"
    static let keychainAccount = "meta"
    static var sessionsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/muse/sessions")
    }

    static var authURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/muse/auth.json")
    }

    static func anySourceExists(sessions: URL = sessionsURL, auth: URL = authURL) -> Bool {
        let files = FileManager.default
        return files.fileExists(atPath: sessions.path) || files.fileExists(atPath: auth.path)
    }

    /// Only the display name and address are decoded — the file also holds
    /// secrets, which are never touched.
    private struct AuthFile: Decodable {
        var providers: [String: ProviderEntry]
        struct ProviderEntry: Decodable {
            var userFullName: String?
            var userEmail: String?
        }
    }

    static func account(from authURL: URL = authURL) -> ProviderAccount? {
        guard let data = try? Data(contentsOf: authURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let file = try? decoder.decode(AuthFile.self, from: data) else { return nil }
        let entry = file.providers["meta"] ?? file.providers.values.first
        guard let label = entry?.userEmail ?? entry?.userFullName else { return nil }
        return ProviderAccount(label: label, plan: nil, source: "Muse", manageURL: nil)
    }

    private struct Secret: Decodable {
        var apiKey: String?
    }

    /// The minted API key out of the keychain item's JSON. Pure, so the tests
    /// can pin it without touching the keychain: only this and `read` ever see
    /// the secret, and neither logs it.
    static func parseAPIKey(from json: String) -> String? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let key = try? decoder.decode(Secret.self, from: data).apiKey,
              !key.isEmpty else { return nil }
        return key
    }

    /// Reads the keychain item the CLI filed its login under.
    ///
    /// `MuseKeychain` decides *whether* to read; this is what happens when it
    /// does. Every failure becomes the status the UI should show.
    ///
    /// `interactive` is whether this read may raise the password dialogue.
    /// Only a person clicking "Allow access…" passes true — everything else
    /// goes through non-interactively, and a refusal there is retried through
    /// `/usr/bin/security`, which the CLI's item admits.
    static func read(interactive: Bool = false) throws -> String {
        guard let winner = KeychainItem.newest(service: keychainService,
                                               account: keychainAccount) else {
            Log.usage.error("keychain read failed: no item under \(keychainService, privacy: .public)")
            throw UsageProviderError.needsAuth
        }
        let (status, item) = KeychainSecret.read(
            query: [
                kSecClass: kSecClassGenericPassword,
                kSecValuePersistentRef: winner.persistentRef,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne,
            ],
            interactive: interactive,
            rescue: (service: keychainService, account: keychainAccount)
        )
        guard status == errSecSuccess, let data = item,
              let json = String(data: data, encoding: .utf8),
              let key = parseAPIKey(from: json) else {
            Log.usage.error("keychain read of \(keychainService, privacy: .public) failed: OSStatus \(status)")
            if ClaudeCredentials.wasTransient(status) { throw UsageProviderError.credentialExpired }
            // A present-but-unreadable secret is either a Deny or a format the
            // CLI has moved past; re-running the login heals both.
            throw ClaudeCredentials.wasRefused(status)
                ? UsageProviderError.accessDenied
                : UsageProviderError.needsAuth
        }
        return key
    }
}

/// The CLI's minted API key, read as rarely as the keychain allows.
///
/// One cache for the one item: macOS prompts once per item, and the CLI
/// re-mints into this same item, whose modification date says when the held
/// copy went stale. Only `.accessDenied` is permanent — a real "Deny".
/// Everything else is retried after the cache's own backoff even while the
/// item has not moved, for the dark-wake reason `CredentialCache` spells out.
final class MuseKeychain: @unchecked Sendable {
    private let cache = CredentialCache<String>(
        isPermanentFailure: { if case UsageProviderError.accessDenied = $0 { return true }; return false },
        isExpired: { _ in false }
    )

    private let reader: (_ interactive: Bool) throws -> String
    private let prompt: PromptPermission
    private let refusal: KeychainRefusal

    init(now: @escaping () -> Date = Date.init,
         refusals: UserDefaults? = Runtime.isUnderTest ? nil : .standard,
         reader: @escaping (_ interactive: Bool) throws -> String
            = { try MuseCredentials.read(interactive: $0) }) {
        self.prompt = PromptPermission(now: now)
        self.refusal = KeychainRefusal(key: "muse", defaults: refusals)
        self.reader = reader
    }

    /// The person said no to this login and has not asked again. While true,
    /// nothing reads it.
    var isRefused: Bool { refusal.isRefused && !prompt.isOwed }

    func load() throws -> String {
        if isRefused { throw UsageProviderError.accessDenied }
        return try cache.value(
            itemModifiedAt: {
                KeychainItem.modifiedAt(service: MuseCredentials.keychainService,
                                        account: MuseCredentials.keychainAccount)
            },
            reload: { [self] in
                let interactive = prompt.take()
                do {
                    let key = try reader(interactive)
                    // Answered with Allow: the earlier no no longer stands.
                    if interactive { refusal.set(false) }
                    return key
                } catch UsageProviderError.accessDenied where interactive {
                    // Only the dialogue's own answer is recorded. A background
                    // read refused without asking is not anyone saying no.
                    refusal.set(true)
                    throw UsageProviderError.accessDenied
                }
            }
        )
    }

    /// Forget the held copy. Call when the server rejects it: the CLI
    /// re-mints on next use, and the copy in hand is then wrong.
    func forgetCached() { cache.forget() }

    /// A person asked macOS for this login again: let the next read show the
    /// dialogue. The only caller that may — `forgetCached` is also what the
    /// server rejecting a key calls, and that is not someone clicking a button.
    func askAgain() {
        prompt.grant()
        cache.forget()
    }
}
