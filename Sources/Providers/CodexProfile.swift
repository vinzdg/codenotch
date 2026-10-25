import Foundation

/// Finder does not inherit a shell's CODEX_HOME. Discover the same directory
/// convention as Claude instead, keeping each account's credentials and activity together.
struct CodexProfile: Equatable, Hashable {
    static let defaultID = "codex"
    static let directoryPrefix = ".codex"

    let slug: String?
    let configDirectory: URL

    static var homeDirectory: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    static func `default`(home: URL = homeDirectory) -> CodexProfile {
        CodexProfile(slug: nil, configDirectory: home.appendingPathComponent(directoryPrefix))
    }

    static func discover(home: URL = homeDirectory,
                         fileManager: FileManager = .default,
                         configuredSlugs: Set<String> = []) -> [CodexProfile] {
        let names = (try? fileManager.contentsOfDirectory(atPath: home.path)) ?? []
        var bySlug: [String: CodexProfile] = [:]
        for name in names {
            guard let slug = slug(fromDirectoryName: name) else { continue }
            let directory = home.appendingPathComponent(name)
            guard isProfileDirectory(directory, fileManager: fileManager) else { continue }
            bySlug[slug] = CodexProfile(slug: slug, configDirectory: directory)
        }
        for raw in configuredSlugs {
            guard let slug = ProfileFamily.codex.normalizeSlug(raw), bySlug[slug] == nil else { continue }
            let directory = home.appendingPathComponent("\(directoryPrefix)-\(slug)")
            bySlug[slug] = CodexProfile(slug: slug, configDirectory: directory)
        }
        let extras = bySlug.values.sorted { $0.slug! < $1.slug! }
        return [.default(home: home)] + extras
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
                "sqlite/codex-dev.db"].contains {
            fileManager.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }

    // Preserve the default id so existing readings and preferences survive.
    var id: String { slug.map { "\(Self.defaultID)-\($0)" } ?? Self.defaultID }

    /// Whether a provider id names a Codex profile, default or otherwise.
    static func isCodex(providerID: String) -> Bool {
        providerID == defaultID || providerID.hasPrefix(defaultID + "-")
    }
    var displayName: String { slug.map { "Codex (\($0))" } ?? "Codex" }

    static func slug(fromProviderID id: String) -> String? {
        let prefix = defaultID + "-"
        guard id.hasPrefix(prefix) else { return nil }
        let slug = String(id.dropFirst(prefix.count))
        return slug.isEmpty ? nil : slug
    }

    var authURL: URL { configDirectory.appendingPathComponent("auth.json") }
    var stateURL: URL { configDirectory.appendingPathComponent("state_5.sqlite") }
    var desktopStoreURL: URL { configDirectory.appendingPathComponent("sqlite/codex-dev.db") }

    var displayPath: String {
        let home = NSHomeDirectory()
        let path = configDirectory.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    var sourceName: String { slug == nil ? "Codex" : "Codex in \(displayPath)" }

    var signInCommand: String {
        guard slug != nil else { return "codex login" }
        // Quote the actual path, including spaces and apostrophes. A quoted ~
        // would not expand, and an unquoted slug could become shell syntax.
        let path = "'" + configDirectory.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        return "CODEX_HOME=\(path) codex -c 'cli_auth_credentials_store=\"file\"' login"
    }
}
