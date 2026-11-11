import Foundation

struct KreaCredentialSources {
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var credentialsURL: URL = KreaCredentials.credentialsURL
    var settingsToken: () -> String? = KreaCredentials.cachedSettingsToken
    var settingsPresent: () -> Bool = KreaCredentials.isSettingsTokenPresent
    var deleteSettingsToken: () -> Void = KreaCredentials.deleteSettingsToken
    var locateBinary: () -> URL? = { KreaCLI.locateBinary() }
    var forgetCached: () -> Void = KreaCredentials.forgetCached
}

enum KreaCredentials {
    static let keychainService = "krea-api-key"
    static let keychainAccount = "codenotch"

    static var credentialsURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("krea/credentials.json")
        if let appSupport, FileManager.default.fileExists(atPath: appSupport.path) {
            return appSupport
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/krea/credentials.json")
    }

    static let environmentKeys = ["KREA_API_KEY", "KREA_APP_BUILDER_API_KEY", "KREA_TOKEN", "KREA_API_TOKEN"]

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

    static func isPresent(_ sources: KreaCredentialSources = KreaCredentialSources()) -> Bool {
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

    static func load(_ sources: KreaCredentialSources = KreaCredentialSources()) throws -> Credential {
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
        // 3. Credentials file (~/.config/krea/credentials.json)
        if let data = try? Data(contentsOf: sources.credentialsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let candidate = json["api_key"] as? String
                ?? json["apiKey"] as? String
                ?? json["access_token"] as? String
                ?? json["accessToken"] as? String
                ?? json["token"] as? String
                ?? json["key"] as? String
            if let token = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                return Credential(token: token, source: .credentialsFile)
            }
        }
        throw UsageProviderError.needsAuth
    }
}
