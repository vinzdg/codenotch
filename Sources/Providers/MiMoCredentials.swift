import Foundation

/// Credentials for the Xiaomi MiMo provider.
///
/// MiMo's Open Platform balance API (`/v1/platform/balance`) requires an API key,
/// which can be:
/// 1. Stored in the macOS keychain (`mimo-api-key`, account `codenotch`).
/// 2. Provided via environment variables (`MIMO_API_KEY`, `MIMOCODE_API_KEY`, or `MIMOCODE_AUTH_CONTENT`).
/// 3. Read from the official MiMo Code CLI's authentication file (`~/.local/share/mimocode/auth.json`).
enum MiMoCredentials {
    static let keychainService = "mimo-api-key"
    static let keychainAccount = "codenotch"

    private static let cache = CredentialCache<String> { _ in false }

    static var defaultAuthURL: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("mimocode/auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/mimocode/auth.json")
    }

    private static func cachedAPIKey() -> String? {
        try? cache.value(
            itemModifiedAt: { KeychainItem.modifiedAt(service: keychainService, account: keychainAccount) },
            reload: {
                guard let key = KeychainItem.read(service: keychainService, account: keychainAccount) else {
                    throw UsageProviderError.needsAuth
                }
                return key
            }
        )
    }

    static func loadAPIKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        authURL: URL = defaultAuthURL,
        keychain: () -> String? = cachedAPIKey
    ) -> String? {
        // 1. Keychain / settings
        if let key = nonEmpty(keychain()) {
            return key
        }

        // 2. Environment variables
        for key in ["MIMO_API_KEY", "MIMOCODE_API_KEY"] {
            if let val = nonEmpty(environment[key]) {
                return val
            }
        }
        if let content = nonEmpty(environment["MIMOCODE_AUTH_CONTENT"]),
           let token = extractToken(from: content) {
            return token
        }

        // 3. Official CLI auth file
        if let fileToken = loadFromAuthFile(authURL) {
            return fileToken
        }

        return nil
    }

    static func isAPIKeyPresent(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        authURL: URL = defaultAuthURL
    ) -> Bool {
        KeychainItem.modifiedAt(service: keychainService, account: keychainAccount) != nil
            || nonEmpty(environment["MIMO_API_KEY"]) != nil
            || nonEmpty(environment["MIMOCODE_API_KEY"]) != nil
            || nonEmpty(environment["MIMOCODE_AUTH_CONTENT"]) != nil
            || FileManager.default.fileExists(atPath: authURL.path)
    }

    static func isCLICredentialPresent(authURL: URL = defaultAuthURL) -> Bool {
        FileManager.default.fileExists(atPath: authURL.path)
    }

    static func storeAPIKey(_ key: String) {
        guard let trimmed = nonEmpty(key) else { return }
        cache.forget()
        _ = KeychainItem.store(service: keychainService, account: keychainAccount, value: trimmed)
    }

    static func deleteAPIKey() {
        cache.forget()
        _ = KeychainItem.delete(service: keychainService, account: keychainAccount)
    }

    static func forgetCached() {
        cache.forget()
    }

    static func loadFromAuthFile(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return extractToken(from: json)
    }

    static func extractToken(from text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return extractToken(from: json)
    }

    static func extractToken(from dict: [String: Any]) -> String? {
        for key in ["apiKey", "api_key", "token", "access_token", "key"] {
            if let val = nonEmpty(dict[key] as? String) {
                return val
            }
        }
        for provider in ["xiaomi", "mimo", "mimocode", "default"] {
            if let nested = dict[provider] as? [String: Any],
               let token = extractToken(from: nested) {
                return token
            }
        }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
