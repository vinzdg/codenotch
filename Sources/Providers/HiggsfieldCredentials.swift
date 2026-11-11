import Foundation

struct HiggsfieldCredentialSources {
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var credentialsURL: URL = HiggsfieldCredentials.credentialsURL
    var settingsToken: () -> String? = HiggsfieldCredentials.cachedSettingsToken
    var settingsPresent: () -> Bool = HiggsfieldCredentials.isSettingsTokenPresent
    var deleteSettingsToken: () -> Void = HiggsfieldCredentials.deleteSettingsToken
    var locateBinary: () -> URL? = { HiggsfieldCLI.locateBinary() }
    var forgetCached: () -> Void = HiggsfieldCredentials.forgetCached
}

enum HiggsfieldCredentials {
    static let keychainService = "higgsfield-api-key"
    static let keychainAccount = "codenotch"

    static var credentialsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/higgsfield/credentials.json")
    }

    private static var cachedToken: String?
    private static var hasCheckedCache = false
    private static let lock = NSLock()

    static func cachedSettingsToken() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if hasCheckedCache { return cachedToken }
        hasCheckedCache = true
        cachedToken = KeychainItem.read(service: keychainService, account: keychainAccount)
        return cachedToken
    }

    static func isSettingsTokenPresent() -> Bool {
        KeychainItem.modifiedAt(service: keychainService, account: keychainAccount) != nil
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
        cachedToken = nil
        hasCheckedCache = false
    }

    static func forgetCached() {
        lock.lock()
        defer { lock.unlock() }
        cachedToken = nil
        hasCheckedCache = false
    }

    /// Higgsfield's own names only. `HF_TOKEN` is Hugging Face's: read here,
    /// a Hugging Face secret would be sent to Higgsfield's gateway.
    static let environmentKeys = ["HIGGSFIELD_API_KEY", "HIGGSFIELD_TOKEN"]

    static func isPresent(_ sources: HiggsfieldCredentialSources = HiggsfieldCredentialSources()) -> Bool {
        if sources.settingsPresent() { return true }
        for key in environmentKeys {
            if let val = sources.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty {
                return true
            }
        }
        if (try? Data(contentsOf: sources.credentialsURL)) != nil { return true }
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

    static func load(_ sources: HiggsfieldCredentialSources = HiggsfieldCredentialSources()) throws -> Credential {
        // 1. Settings token
        if let token = sources.settingsToken()?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return Credential(token: token, source: .settings)
        }
        // 2. Environment variables
        for key in environmentKeys {
            if let val = sources.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty {
                return Credential(token: val, source: .environment)
            }
        }
        // 3. Credentials file (~/.config/higgsfield/credentials.json)
        if let data = try? Data(contentsOf: sources.credentialsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let candidate = json["access_token"] as? String
                ?? json["token"] as? String
                ?? json["api_key"] as? String
                ?? json["key"] as? String
            if let token = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                return Credential(token: token, source: .credentialsFile)
            }
        }
        throw UsageProviderError.needsAuth
    }
}
