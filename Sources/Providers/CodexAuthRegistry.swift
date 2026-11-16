import Foundation

/// One account record managed by `codex-auth`.
///
/// Follows the version 1 JSON API schema specification from `@loongphy/codex-auth`:
/// https://github.com/Loongphy/codex-auth/blob/main/docs/json-api.md
struct CodexAuthAccount: Codable, Equatable, Hashable, Sendable {
    let number: Int?
    let accountKey: String
    let email: String?
    let alias: String?
    let accountName: String?
    let plan: String?
    let authMode: String?
    let accessTokenExpiresAt: Double?
    let planExpiresAt: Double?
    let active: Bool

    enum CodingKeys: String, CodingKey {
        case number
        case accountKey = "account_key"
        case email
        case alias
        case accountName = "account_name"
        case plan
        case authMode = "auth_mode"
        case accessTokenExpiresAt = "access_token_expires_at"
        case planExpiresAt = "plan_expires_at"
        case active
    }

    init(
        number: Int? = nil,
        accountKey: String,
        email: String? = nil,
        alias: String? = nil,
        accountName: String? = nil,
        plan: String? = nil,
        authMode: String? = nil,
        accessTokenExpiresAt: Double? = nil,
        planExpiresAt: Double? = nil,
        active: Bool = false
    ) {
        self.number = number
        self.accountKey = accountKey
        self.email = email
        self.alias = alias
        self.accountName = accountName
        self.plan = plan
        self.authMode = authMode
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.planExpiresAt = planExpiresAt
        self.active = active
    }
}

/// The registry document or list response stored in `~/.codex/registry.json`
/// or returned by `codex-auth list --json`.
struct CodexAuthRegistry: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let command: String?
    let accounts: [CodexAuthAccount]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case command
        case accounts
    }

    init(schemaVersion: Int = currentSchemaVersion, command: String? = nil, accounts: [CodexAuthAccount]) {
        self.schemaVersion = schemaVersion
        self.command = command
        self.accounts = accounts
    }

    init(from decoder: Decoder) throws {
        // Support both structured `{ schema_version, accounts: [...] }` and bare `[...]` arrays
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? Self.currentSchemaVersion
            command = try? container.decode(String.self, forKey: .command)
            accounts = (try? container.decode([CodexAuthAccount].self, forKey: .accounts)) ?? []
        } else if let singleContainer = try? decoder.singleValueContainer(),
                  let list = try? singleContainer.decode([CodexAuthAccount].self) {
            schemaVersion = Self.currentSchemaVersion
            command = nil
            accounts = list
        } else {
            schemaVersion = Self.currentSchemaVersion
            command = nil
            accounts = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(command, forKey: .command)
        try container.encode(accounts, forKey: .accounts)
    }

    /// Loads and parses the registry from a file URL.
    static func load(from url: URL) throws -> CodexAuthRegistry {
        guard let data = try? Data(contentsOf: url) else {
            throw UsageProviderError.needsAuth
        }
        return try JSONDecoder().decode(CodexAuthRegistry.self, from: data)
    }

    /// Reads accounts from `<directory>/registry.json` if the file exists.
    static func readAccounts(from directory: URL, fileManager: FileManager = .default) -> [CodexAuthAccount]? {
        let registryURL = directory.appendingPathComponent("registry.json")
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: registryURL.path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        guard let registry = try? load(from: registryURL) else { return nil }
        return registry.accounts
    }

    /// Generates a clean URL/identifier-safe slug from an account.
    static func preferredSlug(for account: CodexAuthAccount, existingSlugs: Set<String> = []) -> String {
        if let alias = account.alias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
            let sanitized = sanitizeSlug(alias)
            if !sanitized.isEmpty && !existingSlugs.contains(sanitized) {
                return sanitized
            }
        }

        if let email = account.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            let candidate: String
            if let at = email.firstIndex(of: "@") {
                candidate = String(email[..<at])
            } else {
                candidate = email
            }
            let sanitized = sanitizeSlug(candidate)
            if !sanitized.isEmpty && !existingSlugs.contains(sanitized) {
                return sanitized
            }
        }

        let keyCandidate = sanitizeSlug(account.accountKey)
        if !keyCandidate.isEmpty && !existingSlugs.contains(keyCandidate) {
            return keyCandidate
        }

        var counter = 1
        while existingSlugs.contains("account-\(counter)") {
            counter += 1
        }
        return "account-\(counter)"
    }

    private static func sanitizeSlug(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = text.lowercased().unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }
}
