import Foundation

/// Everywhere a Mistral API key can come from on this Mac, as closures and paths
/// so tests can cover each source and precedence rule without touching the
/// keychain or the user's home directory.
struct MistralCredentialSources: Sendable {
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var settingsToken: @Sendable () -> String? = MistralCredentials.cachedSettingsToken
    var settingsPresent: @Sendable () -> Bool = MistralCredentials.isSettingsTokenPresent
    var deleteSettingsToken: @Sendable () -> Void = MistralCredentials.deleteSettingsToken
    var vibeEnvURL: URL? = MistralCredentials.vibeEnvURL()
    var openCodeAuthURL: URL = MistralCredentials.openCodeAuthURL()
    var configFileURL: URL = MistralCredentials.configFileURL
    var forgetCached: @Sendable () -> Void = MistralCredentials.forgetCached
}

/// The Mistral API key, borrowed from whichever tool already holds it or
/// saved in Settings.
///
/// Precedence order (matching the Windows adapter, with macOS Keychain for
/// keys pasted in Settings):
///
/// 1. `MISTRAL_API_KEY` environment variable.
/// 2. A key pasted in Settings (stored in the login keychain under
///    `mistral-api-key` / `codenotch`).
/// 3. Mistral Vibe CLI `$VIBE_HOME/.env` or `~/.vibe/.env` (`MISTRAL_API_KEY=...`).
/// 4. OpenCode `~/.local/share/opencode/auth.json` (`"mistral"` entry).
/// 5. Codenotch config file (`~/Library/Application Support/Codenotch/mistral.json`).
enum MistralCredentials {
    static let environmentKey = "MISTRAL_API_KEY"
    static let keychainService = "mistral-api-key"
    static let keychainAccount = "codenotch"
    static let billingURL = URL(string: "https://console.mistral.ai/billing")

    static func vibeEnvURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> URL {
        if let vibeHome = nonEmpty(environment["VIBE_HOME"]) {
            return URL(fileURLWithPath: vibeHome).appendingPathComponent(".env")
        }
        return home.appendingPathComponent(".vibe/.env")
    }

    static func openCodeAuthURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> URL {
        if let xdg = nonEmpty(environment["XDG_DATA_HOME"]) {
            return URL(fileURLWithPath: xdg).appendingPathComponent("opencode/auth.json")
        }
        return home.appendingPathComponent(".local/share/opencode/auth.json")
    }

    static var configFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("Codenotch", isDirectory: true)
            .appendingPathComponent("mistral.json")
    }

    struct Credential: Equatable, Sendable {
        enum Source: Equatable, Sendable {
            case environment
            case settings
            case vibeEnv
            case openCode
            case configFile

            var displayName: String {
                switch self {
                case .environment: return "MISTRAL_API_KEY"
                case .settings: return "Mistral"
                case .vibeEnv: return "Mistral Vibe"
                case .openCode: return "OpenCode"
                case .configFile: return "mistral.json"
                }
            }
        }

        let token: String
        let source: Source
    }

    static func load(_ sources: MistralCredentialSources = MistralCredentialSources()) throws -> Credential {
        if let token = nonEmpty(sources.environment[environmentKey]) {
            return Credential(token: token, source: .environment)
        }
        if let token = nonEmpty(sources.settingsToken()) {
            return Credential(token: token, source: .settings)
        }
        if let vibeURL = sources.vibeEnvURL,
           let text = try? String(contentsOf: vibeURL, encoding: .utf8),
           let token = parseEnvKey(text) {
            return Credential(token: token, source: .vibeEnv)
        }
        if let token = openCodeKey(at: sources.openCodeAuthURL) {
            return Credential(token: token, source: .openCode)
        }
        if let text = try? String(contentsOf: sources.configFileURL, encoding: .utf8),
           let token = parseKeyJSON(text) {
            return Credential(token: token, source: .configFile)
        }
        throw UsageProviderError.needsAuth
    }

    /// Account metadata for Settings, checked without prompting the keychain.
    static func account(
        _ sources: MistralCredentialSources = MistralCredentialSources(),
        plan: String? = nil
    ) -> ProviderAccount? {
        if nonEmpty(sources.environment[environmentKey]) != nil {
            return ProviderAccount(label: nil, plan: plan, source: "MISTRAL_API_KEY", manageURL: billingURL)
        }
        if sources.settingsPresent() {
            return ProviderAccount(label: nil, plan: plan, source: "Mistral", manageURL: billingURL)
        }
        if let vibeURL = sources.vibeEnvURL,
           let text = try? String(contentsOf: vibeURL, encoding: .utf8),
           parseEnvKey(text) != nil {
            return ProviderAccount(label: nil, plan: plan, source: "Mistral Vibe", manageURL: billingURL)
        }
        if openCodeKey(at: sources.openCodeAuthURL) != nil {
            return ProviderAccount(label: nil, plan: plan, source: "OpenCode", manageURL: billingURL)
        }
        if let text = try? String(contentsOf: sources.configFileURL, encoding: .utf8),
           parseKeyJSON(text) != nil {
            return ProviderAccount(label: nil, plan: plan, source: "mistral.json", manageURL: billingURL)
        }
        return nil
    }

    // MARK: - File Parsers

    /// Parses `MISTRAL_API_KEY=...` from a dotenv file, supporting optional
    /// `export` prefixes, single/double quotes, and trailing `#` comments.
    static func parseEnvKey(_ text: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard key == environmentKey else { continue }

            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let unquoted: String
            if value.hasPrefix("\"") {
                let rest = value.dropFirst()
                if let end = rest.firstIndex(of: "\"") {
                    unquoted = String(rest[..<end])
                } else {
                    unquoted = value
                }
            } else if value.hasPrefix("'") {
                let rest = value.dropFirst()
                if let end = rest.firstIndex(of: "'") {
                    unquoted = String(rest[..<end])
                } else {
                    unquoted = value
                }
            } else {
                unquoted = String(value.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(value))
                    .trimmingCharacters(in: .whitespaces)
            }
            if let token = nonEmpty(unquoted) {
                return token
            }
        }
        return nil
    }

    static func parseKeyJSON(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return nonEmpty(root["api_key"] as? String) ?? nonEmpty(root["apiKey"] as? String)
    }

    static func openCodeKey(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["mistral"]
        else { return nil }
        if let direct = nonEmpty(entry as? String) {
            return direct
        }
        if let dict = entry as? [String: Any] {
            for field in ["key", "apiKey", "api_key", "access", "token"] {
                if let token = nonEmpty(dict[field] as? String) {
                    return token
                }
            }
        }
        return nil
    }

    // MARK: - Settings Keychain Storage

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
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
