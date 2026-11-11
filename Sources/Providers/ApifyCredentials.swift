import Foundation
import Security

/// Everywhere an Apify token can come from on this Mac, as closures so a test
/// can stand each one in without a keychain or a home directory.
struct ApifyCredentialSources {
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var settingsToken: () -> String? = ApifyCredentials.cachedSettingsToken
    var settingsPresent: () -> Bool = ApifyCredentials.isSettingsTokenPresent
    var deleteSettingsToken: () -> Void = ApifyCredentials.deleteSettingsToken
    var authURL: URL = ApifyCredentials.authURL
    var cliKeychain: () throws -> String = ApifyCLIKeychain.load
    var cliKeychainPresent: () -> Bool = ApifyCLIKeychain.isPresent
    var forgetCached: () -> Void = ApifyCredentials.forgetCached
}

/// The Apify token, wherever the Mac already has one.
///
/// Four places, in order:
///
/// 1. `APIFY_TOKEN` in the environment — the name the Apify SDKs and CLI read.
/// 2. A token pasted in Settings, filed in the login keychain under a service
///    name no other app uses. Codenotch owns this one, so switching the
///    provider off deletes it.
/// 3. `~/.apify/auth.json`, where `apify login` keeps its login. Older CLIs,
///    and any CLI run with `APIFY_DISABLE_KEYRING=1`, write the token into
///    the file itself.
/// 4. The CLI's own keychain item, which is where the current CLI puts the
///    token by default, leaving only the account's metadata in `auth.json`.
///    Reading another app's item can put a prompt in front of someone, so it
///    comes last, is held behind a `CredentialCache`, and is never reached
///    while an explicit token exists.
///
/// The explicit sources win over the borrowed ones on purpose: pasting a token
/// is a choice made in Codenotch, and a choice should not be overruled by
/// whichever account happens to be logged into the CLI.
enum ApifyCredentials {
    static let environmentKey = "APIFY_TOKEN"
    static let keychainService = "apify-api-token"
    static let keychainAccount = "codenotch"

    static var authURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".apify/auth.json")
    }

    struct Credential: Equatable {
        enum Source: Equatable {
            case environment, settings, cliFile, cliKeychain
        }
        let token: String
        let source: Source
    }

    /// What `auth.json` says about the login, secret aside. The CLI spreads
    /// the `/users/me` answer into the file, so the address and plan are
    /// there whichever backend holds the token.
    struct Login: Equatable {
        let token: String?
        let email: String?
        let username: String?
        let plan: String?
    }

    /// Nil when there is no file: nobody has run `apify login` here. A file
    /// that cannot be read is a different thing — a login that was made and
    /// then damaged — and is reported as such rather than as a sign-out.
    static func login(from url: URL) throws -> Login? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            throw unreadable
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw unreadable
        }
        return Login(
            token: nonEmpty(root["token"] as? String),
            email: nonEmpty(root["email"] as? String),
            username: nonEmpty(root["username"] as? String),
            // Apify's plan ids are shouted — `SCALE`, `STARTER` — and the
            // card prints this under the title as it is, so it is tamed here
            // once rather than at every reader.
            plan: nonEmpty((root["plan"] as? [String: Any])?["id"] as? String)?.capitalized
        )
    }

    private static var unreadable: UsageProviderError {
        .apiError(L10n.t("~/.apify/auth.json is not readable — run apify login again"))
    }

    static func load(_ sources: ApifyCredentialSources = ApifyCredentialSources()) throws -> Credential {
        if let token = nonEmpty(sources.environment[environmentKey]) {
            return Credential(token: token, source: .environment)
        }
        if let token = nonEmpty(sources.settingsToken()) {
            return Credential(token: token, source: .settings)
        }
        // No file, no login: the keychain is not asked, so a Mac that has
        // never run the CLI never sees a dialogue on its account.
        guard let login = try login(from: sources.authURL) else {
            throw UsageProviderError.needsAuth
        }
        if let token = login.token {
            return Credential(token: token, source: .cliFile)
        }
        guard let token = nonEmpty(try sources.cliKeychain()) else {
            throw UsageProviderError.needsAuth
        }
        return Credential(token: token, source: .cliKeychain)
    }

    /// Whose readings these are, judged without a data read — the settings
    /// row is rebuilt on every render and must not raise a prompt to print a
    /// name.
    ///
    /// An exported or pasted token belongs to whatever account issued it,
    /// which nothing on this Mac can name; the CLI's file must not lend its
    /// address to a reading that may be someone else's.
    static func account(_ sources: ApifyCredentialSources = ApifyCredentialSources()) -> ProviderAccount? {
        let billing = URL(string: "https://console.apify.com/billing")
        if nonEmpty(sources.environment[environmentKey]) != nil || sources.settingsPresent() {
            return ProviderAccount(label: nil, plan: nil, source: "Apify", manageURL: billing)
        }
        guard let login = try? login(from: sources.authURL),
              login.token != nil || sources.cliKeychainPresent()
        else { return nil }
        return ProviderAccount(
            label: login.email ?? login.username,
            plan: login.plan,
            source: L10n.t("Apify CLI"),
            manageURL: billing
        )
    }

    // MARK: - The token Codenotch holds itself

    /// Held until the item moves, for the reason spelled out in
    /// `CredentialCache`: a data read can prompt, and usage polling reaches
    /// this every minute. A stored token never expires on its own.
    private static let settingsCache = CredentialCache<String> { _ in false }

    static func cachedSettingsToken() -> String? {
        try? settingsCache.value(
            itemModifiedAt: { KeychainItem.modifiedAt(service: keychainService, account: keychainAccount) },
            reload: {
                guard let token = KeychainItem.read(service: keychainService, account: keychainAccount) else {
                    throw UsageProviderError.needsAuth
                }
                return token
            }
        )
    }

    /// Attributes only, never the cache: a `store` or `delete` that just
    /// happened has to show at once.
    static func isSettingsTokenPresent() -> Bool {
        KeychainItem.modifiedAt(service: keychainService, account: keychainAccount) != nil
    }

    static func storeSettingsToken(_ token: String) {
        guard let trimmed = nonEmpty(token) else { return }
        settingsCache.forget()
        _ = KeychainItem.store(service: keychainService, account: keychainAccount, value: trimmed)
    }

    static func deleteSettingsToken() {
        settingsCache.forget()
        KeychainItem.delete(service: keychainService, account: keychainAccount)
    }

    static func forgetCached() {
        settingsCache.forget()
        ApifyCLIKeychain.forgetCached()
    }

    /// Non-empty after trim: an empty token is worse than a missing one, it is
    /// a request that cannot succeed being sent all the same.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// The token `apify login` files in the login keychain — the CLI's default
/// since it grew a keyring backend. Named in apify-cli's `credentials.ts`.
///
/// Held until the item moves, for the reason spelled out in `CredentialCache`.
/// A refusal counts as a verdict on that version of the item: the same one is
/// never put to macOS again until "Allow access…" forgets it or the CLI
/// writes a new token. Refreshing is the CLI's job.
enum ApifyCLIKeychain {
    static let service = "com.apify.cli"
    static let account = "token"

    private static let cache = CredentialCache<String>(isPermanentFailure: { error in
        if case UsageProviderError.accessDenied = error { return true }
        return false
    }) { _ in false }

    /// Attributes are free to ask about; only the data can prompt.
    static func isPresent() -> Bool {
        KeychainItem.modifiedAt(service: service, account: account) != nil
    }

    static func load() throws -> String {
        try cache.value(
            itemModifiedAt: { KeychainItem.modifiedAt(service: service, account: account) },
            reload: read
        )
    }

    static func forgetCached() { cache.forget() }

    /// Newest item under this service and account, then a targeted data read.
    /// Same two-step as Claude Code's and cursor-agent's: attributes are
    /// free, the secret is not.
    static func read() throws -> String {
        guard let winner = KeychainItem.newest(service: service, account: account) else {
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
            Log.usage.error("apify keychain read failed: OSStatus \(status)")
            if ClaudeCredentials.wasTransient(status) { throw UsageProviderError.credentialExpired }
            throw ClaudeCredentials.wasRefused(status)
                ? UsageProviderError.accessDenied
                : UsageProviderError.needsAuth
        }
        guard let token = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { throw UsageProviderError.needsAuth }
        return token
    }
}
