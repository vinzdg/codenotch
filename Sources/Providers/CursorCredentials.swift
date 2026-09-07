import Foundation
import Security
import SQLite3

/// The session Cursor keeps for itself — the editor's SQLite store first,
/// then the `cursor-agent` login if that store is missing or signed out.
///
/// Codenotch only ever reads it, the same bargain as Claude Code's keychain
/// token: the owning tool mints and refreshes it, we borrow the current value.
/// The editor database is opened read-only and never `immutable`, so a running
/// editor is not blocked and a rotated token is not served from a stale
/// checkpoint. The agent token lives in the login keychain; that read is
/// cached, because every data fetch can raise a prompt.
///
/// The two sessions are the same cookie. `/api/usage-summary` wants
/// `WorkosCursorSessionToken={accountID}::{accessToken}`. The editor stores
/// those two halves in SQLite; the CLI stores the JWT under
/// `cursor-access-token` and the account id in `~/.cursor/cli-config.json`.
/// A token-only cookie, or a Bearer header, is 401 — the pair is required.
struct CursorCredentials {
    let accountID: String
    let accessToken: String
    /// The web API wants the pair as one cookie.
    var sessionCookie: String { "WorkosCursorSessionToken=\(accountID)::\(accessToken)" }

    static var storeURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// Written by `cursor-agent login`. Non-secret: email and the WorkOS
    /// subject that belongs in the cookie. The JWT itself is not here.
    static var agentConfigURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cursor/cli-config.json")
    }

    /// Minted by ToDesktop, who build Cursor — stable across updates, but not
    /// across Cursor leaving ToDesktop or rebranding. Kept here beside the store
    /// path so the two facts about a Cursor installation change together: the
    /// activity monitor and the sign-in route both read this one.
    static let bundleID = "com.todesktop.230313mzl4w4u92"

    /// Identity, editor first. A machine with only `cursor-agent` has no
    /// `cachedEmail` row, so the CLI config is the address we can show.
    static func account() -> ProviderAccount? {
        account(from: storeURL) ?? agentAccount(from: agentConfigURL)
    }

    /// Identity, read from the same store as the session. Non-secret: the email
    /// and plan the editor caches for its own UI.
    static func account(from url: URL) -> ProviderAccount? {
        guard let db = SQLiteStore.open(url) else { return nil }
        defer { sqlite3_close(db) }
        func value(_ key: String) -> String? {
            SQLiteStore.rows(in: db, sql: "SELECT value FROM ItemTable WHERE key = ?", bind: key).first
        }
        guard let email = value("cursorAuth/cachedEmail"), !email.isEmpty else { return nil }
        return ProviderAccount(
            label: email,
            plan: value("cursorAuth/stripeMembershipType"),
            source: "Cursor",
            manageURL: URL(string: "https://cursor.com/dashboard")
        )
    }

    static func agentAccount(from url: URL) -> ProviderAccount? {
        guard let info = agentAuthInfo(from: url),
              info.email != nil || info.authId != nil
        else { return nil }
        return ProviderAccount(
            label: info.email,
            plan: nil,
            source: "cursor-agent",
            manageURL: URL(string: "https://cursor.com/dashboard")
        )
    }

    /// Editor first. The CLI session is only reached when the editor has
    /// nothing to borrow — otherwise a laptop with both would flip between
    /// accounts depending on which file we happened to read.
    static func load() throws -> CursorCredentials {
        do {
            return try load(from: storeURL)
        } catch UsageProviderError.needsAuth {
            return try session(fromAgentToken: try CursorAgentKeychain.load(),
                               configURL: agentConfigURL)
        }
    }

    /// Editor store only. Tests, and the combined loader above, pin the path
    /// so a missing editor cannot silently become a live keychain read.
    static func load(from url: URL) throws -> CursorCredentials {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw UsageProviderError.needsAuth
        }

        // Read-only, but *not* `immutable`. Cursor runs the database in WAL
        // mode, and `immutable=1` tells SQLite to ignore the write-ahead log —
        // so it happily returns whatever was true at the last checkpoint. That
        // is how you end up serving a token the editor has already rotated.
        guard let db = SQLiteStore.open(url) else { throw UsageProviderError.needsAuth }
        defer { sqlite3_close(db) }

        guard let token = value(forKey: "cursorAuth/accessToken", in: db),
              let account = value(forKey: "cursorAuth/stripeMembershipAuthId", in: db),
              !token.isEmpty, !account.isEmpty
        else { throw UsageProviderError.needsAuth }

        return CursorCredentials(accountID: account, accessToken: token)
    }

    /// Same precedence as `load()`, with the agent token injected so the
    /// fallback can be tested without a keychain.
    static func load(editorStore: URL, agentToken: String?, agentConfig: URL,
                     now: Date = Date()) throws -> CursorCredentials {
        do {
            return try load(from: editorStore)
        } catch UsageProviderError.needsAuth {
            guard let agentToken, !agentToken.isEmpty else { throw UsageProviderError.needsAuth }
            return try session(fromAgentToken: agentToken, configURL: agentConfig, now: now)
        }
    }

    /// Open the editor when it is installed; otherwise name the CLI command.
    /// Offering "Open Cursor" on a machine that has never had the app is a
    /// button that does nothing — worse than no button.
    static func signInRoute(editorInstalled: Bool) -> SignInRoute {
        if editorInstalled {
            return .openApp(bundleID: bundleID, name: "Cursor")
        }
        return .guidance(
            "Run `cursor-agent login` once — the notch reads that session. "
            + "The Cursor editor works the same way, if you have it."
        )
    }

    static func forgetCachedAgent() { CursorAgentKeychain.forgetCached() }

    /// The cookie's left half. `authId` is the WorkOS subject the editor
    /// itself stores as `stripeMembershipAuthId`. Numeric `userId` also works
    /// against the same endpoint, and the JWT `sub` is the last resort when
    /// someone has a token but no config file yet.
    static func agentAccountID(token: String, configURL: URL) -> String? {
        if let info = agentAuthInfo(from: configURL) {
            if let authId = info.authId { return authId }
            if let userId = info.userId { return userId }
        }
        guard let sub = claims(inJWT: token)?["sub"] as? String, !sub.isEmpty else { return nil }
        return sub
    }

    static func session(fromAgentToken token: String, configURL: URL,
                        now: Date = Date()) throws -> CursorCredentials {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw UsageProviderError.needsAuth }
        if agentTokenIsExpired(trimmed, now: now) {
            throw UsageProviderError.credentialExpired
        }
        guard let accountID = agentAccountID(token: trimmed, configURL: configURL),
              !accountID.isEmpty
        else { throw UsageProviderError.needsAuth }
        return CursorCredentials(accountID: accountID, accessToken: trimmed)
    }

    static func agentTokenIsExpired(_ token: String, now: Date = Date()) -> Bool {
        // JWT `exp` is an integer second. JSONSerialization hands it back as
        // NSNumber; `as? Double` is the wrong ask and would miss a live expiry.
        guard let exp = (claims(inJWT: token)?["exp"] as? NSNumber)?.doubleValue else { return false }
        return exp <= now.timeIntervalSince1970
    }

    /// Claims supply the subject and a local expiry hint. The server validates
    /// the token; this is only so an aged-out JWT can keep the last reading
    /// instead of looking like a sign-out.
    static func claims(inJWT token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)

        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func agentAuthInfo(from url: URL) -> AgentAuthInfo? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = root["authInfo"] as? [String: Any]
        else { return nil }

        let userId: String?
        if let number = info["userId"] as? NSNumber {
            // JSON numbers arrive as NSNumber. `as? Int` works for small
            // values and fails for the same object once it is too wide, so
            // take the string form and keep one path.
            userId = number.stringValue
        } else if let text = info["userId"] as? String, !text.isEmpty {
            userId = text
        } else {
            userId = nil
        }

        func nonempty(_ key: String) -> String? {
            guard let value = info[key] as? String, !value.isEmpty else { return nil }
            return value
        }

        return AgentAuthInfo(email: nonempty("email"), authId: nonempty("authId"), userId: userId)
    }

    private static func value(forKey key: String, in db: OpaquePointer?) -> String? {
        SQLiteStore.rows(in: db, sql: "SELECT value FROM ItemTable WHERE key = ?", bind: key).first
    }

    private struct AgentAuthInfo {
        let email: String?
        let authId: String?
        let userId: String?
    }
}

/// The JWT `cursor-agent login` files in the login keychain.
///
/// Held until the item moves, for the reason spelled out in `CredentialCache`:
/// every data read can prompt, and an unchanged item cannot produce a
/// different token. Refreshing is left to the CLI.
enum CursorAgentKeychain {
    static let service = "cursor-access-token"
    static let account = "cursor-user"

    private static let cache = CredentialCache<String> {
        CursorCredentials.agentTokenIsExpired($0)
    }

    static func load() throws -> String {
        try cache.value(
            itemModifiedAt: { KeychainItem.modifiedAt(service: service, account: account) },
            reload: read
        )
    }

    static func forgetCached() { cache.forget() }

    /// Newest item under this service and account, then a targeted data read.
    /// Same two-step as Claude Code: attributes are free, the secret is not,
    /// and `kSecMatchLimitOne` has no ordering if a rotation left duplicates.
    static func read() throws -> String {
        guard let winner = KeychainItem.newest(service: service, account: account) else {
            Log.usage.error("cursor-agent keychain read failed: no item under \(service, privacy: .public)")
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
            Log.usage.error("cursor-agent keychain read failed: OSStatus \(status)")
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
