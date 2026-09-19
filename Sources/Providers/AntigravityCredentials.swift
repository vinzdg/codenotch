import Foundation
import SQLite3
import os
/// The OAuth token Antigravity holds for a Google account.
///
/// Borrowed, like every other credential here — Antigravity signs in, this only
/// reads what it stored.
struct AntigravityCredentials {
    let accessToken: String
    let expiresAt: Date
    /// `consumer` for a personal Google account; enterprise installs differ.
    let authMethod: String
    let projectId: String?
    let email: String?

    init(accessToken: String, expiresAt: Date, authMethod: String = "consumer",
         projectId: String? = nil, email: String? = nil) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.authMethod = authMethod
        self.projectId = projectId
        self.email = email
    }
    var isExpired: Bool { expiresAt <= Date() }

    static let service = "gemini"
    static let account = "antigravity"

    /// Held until it expires, for the reason spelled out in `CredentialCache`.
    private static let cache = CredentialCache<AntigravityCredentials> { $0.isExpired }
    private static let profileCachesLock = NSLock()
    private static var profileCaches: [String: CredentialCache<AntigravityCredentials>] = [:]

    private static func cache(for profile: AntigravityProfile) -> CredentialCache<AntigravityCredentials> {
        if profile.slug == nil { return cache }
        profileCachesLock.lock()
        defer { profileCachesLock.unlock() }
        if let existing = profileCaches[profile.id] {
            return existing
        }
        let newCache = CredentialCache<AntigravityCredentials> { $0.isExpired }
        profileCaches[profile.id] = newCache
        return newCache
    }

    static func forgetCached() { cache.forget() }

    static func forgetCached(for profile: AntigravityProfile) {
        cache(for: profile).forget()
    }

    private static let profilePromptsLock = NSLock()
    private static var profilePrompts: [String: PromptPermission] = [:]

    private static func prompt(for profileID: String) -> PromptPermission {
        profilePromptsLock.lock()
        defer { profilePromptsLock.unlock() }
        if let existing = profilePrompts[profileID] {
            return existing
        }
        let newPrompt = PromptPermission()
        profilePrompts[profileID] = newPrompt
        return newPrompt
    }

    /// A person asked macOS for this login again: the next read may show the
    /// dialogue. `forgetCached` grants nothing, because it is not only a click.
    static func askAgain() {
        askAgain(for: .default())
    }

    static func askAgain(for profile: AntigravityProfile) {
        prompt(for: profile.id).grant()
        cache(for: profile).forget()
    }

    /// Stands in for the keychain in tests, which have none to read.
    nonisolated(unsafe) static var readKeychainForTesting: ((_ interactive: Bool) -> (OSStatus, Data?))?

    /// Whatever a previous fetch already read, without asking macOS again.
    static var held: AntigravityCredentials? { cache.held }

    static func held(for profile: AntigravityProfile) -> AntigravityCredentials? {
        cache(for: profile).held
    }

    /// Whether Antigravity has filed a credential at all, judged from the
    /// item's attributes rather than its contents — those are not behind the
    /// access prompt the secret is, so this can be asked freely.
    static func isSignedIn() -> Bool {
        if KeychainItem.modifiedAt(service: service, account: account) != nil { return true }
        let jsonPath = ("~/.gemini/oauth_creds.json" as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: jsonPath) { return true }
        let ompDBPath = ("~/.omp/agent/agent.db" as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: ompDBPath) { return true }
        return false
    }

    static func hasCredential(for profile: AntigravityProfile) -> Bool {
        if profile.slug == nil { return isSignedIn() }
        if FileManager.default.fileExists(atPath: profile.authURL.path) { return true }
        let dbPath = profile.configDirectory.appendingPathComponent("agent.db").path
        if FileManager.default.fileExists(atPath: dbPath), readOMPCredentials(at: URL(fileURLWithPath: dbPath)) != nil {
            return true
        }
        return false
    }

    static func isSignedIn(for profile: AntigravityProfile) -> Bool {
        hasCredential(for: profile)
    }

    /// Antigravity stores through Go's `keyring` package, which base64-encodes
    /// the payload behind this marker rather than writing raw JSON the way
    /// Claude Code does. Decoding it is not optional: without stripping the
    /// prefix the value is not JSON at all.
    private static let goKeyringPrefix = "go-keyring-base64:"

    static func load() throws -> AntigravityCredentials {
        try cache.value(
            itemModifiedAt: {
                let keychainMod = KeychainItem.modifiedAt(service: service, account: account)
                let jsonPath = ("~/.gemini/oauth_creds.json" as NSString).expandingTildeInPath
                let jsonMod = (try? FileManager.default.attributesOfItem(atPath: jsonPath))?[.modificationDate] as? Date
                let ompPath = ("~/.omp/agent/agent.db" as NSString).expandingTildeInPath
                let ompMod = (try? FileManager.default.attributesOfItem(atPath: ompPath))?[.modificationDate] as? Date
                return [keychainMod, jsonMod, ompMod].compactMap { $0 }.max()
            },
            reload: read
        )
    }

    static func load(for profile: AntigravityProfile) throws -> AntigravityCredentials {
        if profile.slug == nil { return try load() }
        return try cache(for: profile).value(
            itemModifiedAt: {
                let jsonMod = (try? FileManager.default.attributesOfItem(atPath: profile.authURL.path))?[.modificationDate] as? Date
                let agentDB = profile.configDirectory.appendingPathComponent("agent.db").path
                let dbMod = (try? FileManager.default.attributesOfItem(atPath: agentDB))?[.modificationDate] as? Date
                return [jsonMod, dbMod].compactMap { $0 }.max()
            },
            reload: { try read(for: profile) }
        )
    }

    private static func read(for profile: AntigravityProfile) throws -> AntigravityCredentials {
        // 1. Check profile-specific oauth_creds.json first
        if let jsonCreds = readJSONCredentials(at: profile.authURL.path) {
            return jsonCreds
        }

        // 2. Check profile-specific agent.db
        let agentDB = profile.configDirectory.appendingPathComponent("agent.db")
        if let ompCreds = readOMPCredentials(at: agentDB) {
            return ompCreds
        }

        Log.usage.error("antigravity credentials read failed for \(profile.id, privacy: .public)")
        throw UsageProviderError.needsAuth
    }

    private static func read() throws -> AntigravityCredentials {
        var keychainCreds: AntigravityCredentials?
        var keychainStatus: OSStatus = 0

        // Never prompts on a poll. The item is written by Go's keyring through
        // `/usr/bin/security`, so it is refused the way Claude Code's is, and
        // this read used to raise the dialogue every time the cache's
        // five-minute retry came round — for a token Antigravity itself had
        // long stopped refreshing. A refusal is retried through the security
        // tool under the item's own account, which is not this user's.
        let interactive = prompt(for: AntigravityProfile.defaultID).take()
        let (status, data) = readKeychainForTesting?(interactive) ?? KeychainSecret.read(
            query: [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne
            ],
            interactive: interactive,
            rescue: (service: service, account: account)
        )
        keychainStatus = status

        if status == errSecSuccess, let data, let decoded = decode(data) {
            keychainCreds = decoded
            if !decoded.isExpired {
                return decoded
            }
        }

        // If Keychain had no unexpired token, check OMP SQLite store (active agent tokens)
        if let ompCreds = readOMPCredentials() {
            if !ompCreds.isExpired {
                return ompCreds
            }
            if keychainCreds == nil {
                keychainCreds = ompCreds
            }
        }

        // Then check ~/.gemini/oauth_creds.json
        if let jsonCreds = readJSONCredentials() {
            if !jsonCreds.isExpired {
                return jsonCreds
            }
            if keychainCreds == nil {
                keychainCreds = jsonCreds
            }
        }

        if let creds = keychainCreds {
            return creds
        }

        Log.usage.error("antigravity credentials read failed: OSStatus \(keychainStatus)")
        if ClaudeCredentials.wasTransient(keychainStatus) { throw UsageProviderError.credentialExpired }
        throw ClaudeCredentials.wasRefused(keychainStatus)
            ? UsageProviderError.accessDenied
            : UsageProviderError.needsAuth
    }

    private static func readOMPCredentials(at dbURL: URL = URL(fileURLWithPath: ("~/.omp/agent/agent.db" as NSString).expandingTildeInPath)) -> AntigravityCredentials? {
        guard let db = SQLiteStore.open(dbURL) else { return nil }
        defer { sqlite3_close(db) }

        let sql = "SELECT data FROM auth_credentials WHERE provider = 'google-antigravity' ORDER BY updated_at DESC LIMIT 1;"
        let rows = SQLiteStore.rows(in: db, sql: sql)
        guard let first = rows.first, let data = first.data(using: .utf8) else { return nil }

        struct OMPPayload: Decodable {
            let access: String?
            let expires: Double?
            let projectId: String?
            let email: String?
        }

        guard let payload = try? JSONDecoder().decode(OMPPayload.self, from: data),
              let token = payload.access else { return nil }

        let expiry = payload.expires.map { Date(timeIntervalSince1970: $0 / 1000.0) } ?? Date.distantFuture
        return AntigravityCredentials(
            accessToken: token,
            expiresAt: expiry,
            authMethod: "consumer",
            projectId: payload.projectId,
            email: payload.email
        )
    }

    private static func readJSONCredentials(at path: String = ("~/.gemini/oauth_creds.json" as NSString).expandingTildeInPath) -> AntigravityCredentials? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }

        struct JSONPayload: Decodable {
            let access_token: String?
            let expiry_date: Double?
            let email: String?
            let project_id: String?
            let projectId: String?
        }

        guard let payload = try? JSONDecoder().decode(JSONPayload.self, from: data),
              let token = payload.access_token else { return nil }

        let expiry = payload.expiry_date.map { Date(timeIntervalSince1970: $0 / 1000.0) } ?? Date.distantFuture
        return AntigravityCredentials(
            accessToken: token,
            expiresAt: expiry,
            authMethod: "consumer",
            projectId: payload.projectId ?? payload.project_id,
            email: payload.email
        )
    }

    /// Split out so the decoding can be tested against a real stored value
    /// without a keychain.
    static func decode(_ data: Data) -> AntigravityCredentials? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix(goKeyringPrefix) {
            text = String(text.dropFirst(goKeyringPrefix.count))
        }
        guard let payload = Data(base64Encoded: text) else { return nil }

        struct Stored: Decodable {
            struct Token: Decodable {
                let access_token: String
                /// RFC 3339 with fractional seconds *and an offset* —
                /// "2026-08-31T21:53:49.575961+07:00". Not UTC, and not
                /// milliseconds since the epoch like Claude's. Parsing it as
                /// either is how a token that is live reads as long expired.
                let expiry: String
            }
            let auth_method: String
            let token: Token
        }

        guard let stored = try? JSONDecoder().decode(Stored.self, from: payload),
              let expiry = parse(stored.token.expiry)
        else { return nil }

        return AntigravityCredentials(accessToken: stored.token.access_token,
                                      expiresAt: expiry,
                                      authMethod: stored.auth_method)
    }

    /// Fractional seconds are not optional in this field, but a formatter that
    /// demands them fails on a whole-second timestamp — so try both.
    static func parse(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}
