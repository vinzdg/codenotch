import Foundation

struct MimoCodeCredentialSources {
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var credentialsURLs: [URL] = MimoCodeCredentials.defaultCredentialsURLs
    var settingsToken: () -> String? = MimoCodeCredentials.cachedSettingsToken
    var settingsPresent: () -> Bool = MimoCodeCredentials.isSettingsTokenPresent
    var deleteSettingsToken: () -> Void = MimoCodeCredentials.deleteSettingsToken
    var locateBinary: () -> URL? = { MimoCodeCLI.locateBinary() }
    var forgetCached: () -> Void = MimoCodeCredentials.forgetCached
}

enum MimoCodeCredentials {
    static let keychainService = "mimocode-api-key"
    static let legacyKeychainService = "mimo-api-key"
    static let keychainAccount = "codenotch"

    static var defaultCredentialsURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".local/share/mimocode/auth.json"),
            home.appendingPathComponent(".config/mimocode/auth.json"),
            home.appendingPathComponent(".config/mimocode/credentials.json"),
            home.appendingPathComponent(".mimo/auth.json"),
            home.appendingPathComponent(".mimo/credentials.json"),
            home.appendingPathComponent(".config/mimo/credentials.json")
        ]
    }

    static let environmentKeys = [
        "MIMOCODE_API_KEY",
        "MIMO_API_KEY",
        "MIMO_TOKEN",
        "MIMOCODE_TOKEN",
        "MIMOCODE_AUTH_CONTENT"
    ]

    private static var cachedToken: String?
    private static var hasCheckedCache = false
    private static let lock = NSLock()

    static func cachedSettingsToken() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if hasCheckedCache { return cachedToken }
        hasCheckedCache = true
        cachedToken = KeychainItem.read(service: keychainService, account: keychainAccount)
            ?? KeychainItem.read(service: legacyKeychainService, account: keychainAccount)
        return cachedToken
    }

    static func isSettingsTokenPresent() -> Bool {
        KeychainItem.modifiedAt(service: keychainService, account: keychainAccount) != nil
            || KeychainItem.modifiedAt(service: legacyKeychainService, account: keychainAccount) != nil
    }

    static func store(_ token: String) {
        lock.lock()
        defer { lock.unlock() }
        _ = KeychainItem.store(service: keychainService, account: keychainAccount, value: token)
        cachedToken = token
        hasCheckedCache = true
    }

    static func deleteSettingsToken() {
        lock.lock()
        defer { lock.unlock() }
        KeychainItem.delete(service: keychainService, account: keychainAccount)
        KeychainItem.delete(service: legacyKeychainService, account: keychainAccount)
        cachedToken = nil
        hasCheckedCache = false
    }

    static func forgetCached() {
        lock.lock()
        defer { lock.unlock() }
        cachedToken = nil
        hasCheckedCache = false
    }

    static func isPresent(_ sources: MimoCodeCredentialSources = MimoCodeCredentialSources()) -> Bool {
        if sources.settingsPresent() { return true }
        for key in environmentKeys {
            if let val = sources.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty {
                return true
            }
        }
        for url in sources.credentialsURLs {
            if (try? Data(contentsOf: url)) != nil { return true }
        }
        if sources.locateBinary() != nil { return true }
        return false
    }

    struct Credential: Equatable {
        enum Source: Equatable {
            case settings, environment, credentialsFile
        }
        let token: String
        let source: Source
    }

    static func load(_ sources: MimoCodeCredentialSources = MimoCodeCredentialSources()) throws -> Credential {
        // 1. Settings token
        if let token = sources.settingsToken()?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return Credential(token: token, source: .settings)
        }

        // 2. Environment variables
        for key in environmentKeys {
            if let val = sources.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty {
                if key == "MIMOCODE_AUTH_CONTENT" {
                    if let extracted = extractToken(from: val) {
                        return Credential(token: extracted, source: .environment)
                    }
                }
                return Credential(token: val, source: .environment)
            }
        }

        // 3. Credentials / auth files
        for url in sources.credentialsURLs {
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8),
               let token = extractToken(from: text) {
                return Credential(token: token, source: .credentialsFile)
            }
        }

        throw UsageProviderError.needsAuth
    }

    static func extractToken(from content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let directKeys = ["apiKey", "api_key", "token", "access_token", "key", "secret"]
            for key in directKeys {
                if let val = json[key] as? String, !val.isEmpty {
                    return val
                }
            }

            // Nested under "auth" or "tokens" or "credentials"
            let containerKeys = ["auth", "tokens", "credentials", "mimocode", "mimo"]
            for cKey in containerKeys {
                if let nested = json[cKey] as? [String: Any] {
                    for key in directKeys {
                        if let val = nested[key] as? String, !val.isEmpty {
                            return val
                        }
                    }
                }
            }
        }

        if !trimmed.hasPrefix("{") && !trimmed.hasPrefix("[") {
            return trimmed
        }

        return nil
    }
}
