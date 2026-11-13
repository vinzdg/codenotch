import Foundation

/// Finder does not inherit a shell's CODEX_HOME. Discover the same directory
/// convention as Claude instead, keeping each account's credentials and activity together,
/// or multi-account registries managed by `codex-auth`.
struct CodexProfile: Equatable, Hashable {
    static let defaultID = "codex"
    static let directoryPrefix = ".codex"

    let slug: String?
    let configDirectory: URL
    let authAccount: CodexAuthAccount?

    static var homeDirectory: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    init(slug: String?, configDirectory: URL, authAccount: CodexAuthAccount? = nil) {
        self.slug = slug
        self.configDirectory = configDirectory
        self.authAccount = authAccount
    }

    static func `default`(home: URL = homeDirectory) -> CodexProfile {
        CodexProfile(slug: nil, configDirectory: home.appendingPathComponent(directoryPrefix))
    }

    static func discover(home: URL = homeDirectory,
                         fileManager: FileManager = .default,
                         authAccountsLoader: ((URL) -> [CodexAuthAccount]?)? = nil) -> [CodexProfile] {
        let defaultDir = home.appendingPathComponent(directoryPrefix)
        let codexAuthAccounts: [CodexAuthAccount] = authAccountsLoader?(defaultDir)
            ?? CodexAuthRegistry.readAccounts(from: defaultDir, fileManager: fileManager)
            ?? []

        let names = (try? fileManager.contentsOfDirectory(atPath: home.path)) ?? []
        let extras = names.compactMap { name -> CodexProfile? in
            guard let slug = slug(fromDirectoryName: name) else { return nil }
            let directory = home.appendingPathComponent(name)
            guard isProfileDirectory(directory, fileManager: fileManager) else { return nil }
            return CodexProfile(slug: slug, configDirectory: directory)
        }

        var results: [CodexProfile] = []
        if !codexAuthAccounts.isEmpty {
            var existingSlugs = Set<String>()
            for account in codexAuthAccounts {
                let slug = CodexAuthRegistry.preferredSlug(for: account, existingSlugs: existingSlugs)
                existingSlugs.insert(slug)
                results.append(CodexProfile(slug: slug, configDirectory: defaultDir, authAccount: account))
            }
        } else {
            results.append(.default(home: home))
        }

        let existingSlugs = Set(results.compactMap(\.slug))
        let filteredExtras = extras.filter { !existingSlugs.contains($0.slug!) }

        return (results + filteredExtras).sorted {
            ($0.slug ?? "") < ($1.slug ?? "")
        }
    }

    static func slug(fromDirectoryName name: String) -> String? {
        let prefix = directoryPrefix + "-"
        guard name.hasPrefix(prefix) else { return nil }
        let slug = String(name.dropFirst(prefix.count))
        return slug.isEmpty ? nil : slug
    }

    static func isProfileDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        // A signed-out profile can still have settings or sessions. Keep its
        // row so it can explain how to sign that account back in.
        return ["auth.json", "config.toml", "sessions", "history.jsonl", "state_5.sqlite",
                "sqlite/codex-dev.db", "registry.json"].contains {
            fileManager.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }

    // Preserve the default id so existing readings and preferences survive.
    var id: String { slug.map { "\(Self.defaultID)-\($0)" } ?? Self.defaultID }

    /// Whether a provider id names a Codex profile, default or otherwise.
    static func isCodex(providerID: String) -> Bool {
        providerID == defaultID || providerID.hasPrefix(defaultID + "-")
    }

    var isCodexAuth: Bool { authAccount != nil }

    var isCurrentlyActive: Bool {
        guard let authAccount else { return true }
        if let registry = try? CodexAuthRegistry.load(from: registryURL),
           let found = registry.accounts.first(where: { $0.accountKey == authAccount.accountKey }) {
            return found.active
        }
        return authAccount.active
    }

    var displayName: String {
        if let authAccount {
            if let alias = authAccount.alias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
                return "Codex (\(alias))"
            }
            if let email = authAccount.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
                return "Codex (\(email))"
            }
        }
        return slug.map { "Codex (\($0))" } ?? "Codex"
    }

    static func slug(fromProviderID id: String) -> String? {
        let prefix = defaultID + "-"
        guard id.hasPrefix(prefix) else { return nil }
        let slug = String(id.dropFirst(prefix.count))
        return slug.isEmpty ? nil : slug
    }

    var authURL: URL { configDirectory.appendingPathComponent("auth.json") }
    var registryURL: URL { configDirectory.appendingPathComponent("registry.json") }
    var stateURL: URL { configDirectory.appendingPathComponent("state_5.sqlite") }
    var desktopStoreURL: URL { configDirectory.appendingPathComponent("sqlite/codex-dev.db") }

    var displayPath: String {
        let home = NSHomeDirectory()
        let path = configDirectory.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    var sourceName: String {
        if let authAccount {
            let label = authAccount.alias ?? authAccount.email ?? authAccount.accountKey
            return "Codex (\(label))"
        }
        return slug == nil ? "Codex" : "Codex in \(displayPath)"
    }

    var signInCommand: String {
        if let authAccount {
            let target = authAccount.alias ?? authAccount.accountKey
            let escaped = target.replacingOccurrences(of: "'", with: "'\"'\"'")
            return "codex-auth switch '\(escaped)'"
        }
        guard slug != nil else { return "codex login" }
        // Quote the actual path, including spaces and apostrophes. A quoted ~
        // would not expand, and an unquoted slug could become shell syntax.
        let path = "'" + configDirectory.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        return "CODEX_HOME=\(path) codex -c 'cli_auth_credentials_store=\"file\"' login"
    }
}
