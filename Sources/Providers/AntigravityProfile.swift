import Foundation

/// One Google Antigravity configuration directory, and so one account.
///
/// Discovers directories following the convention `~/.gemini/antigravity-<slug>`
/// alongside the default `~/.gemini/antigravity`, keeping each account's credentials,
/// quota polling, and activity tracking separate.
struct AntigravityProfile: Equatable, Hashable {
    /// The provider id the default profile has always had (`gemini`). Kept so archived
    /// readings, connection choices, and user preferences survive the change.
    static let defaultID = "gemini"
    /// What every profile directory under `~/.gemini` starts with.
    static let directoryPrefix = "antigravity"

    /// Internal tool flavours under `~/.gemini` that belong to the default installation
    /// rather than separate user accounts.
    static let ignoredSlugs: Set<String> = ["ide", "cli", "backup", "api"]

    /// Nil for `~/.gemini/antigravity`; the part after `antigravity-` otherwise.
    let slug: String?
    let configDirectory: URL

    static var homeDirectory: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    /// `~/.gemini/antigravity`, whether or not it exists — the app has always read it.
    static func `default`(home: URL = homeDirectory) -> AntigravityProfile {
        let dir = home.appendingPathComponent(".gemini").appendingPathComponent(directoryPrefix)
        return AntigravityProfile(slug: nil, configDirectory: dir)
    }

    /// The default profile followed by every `~/.gemini/antigravity-<slug>` that contains
    /// profile markers and valid credentials, slugs in alphabetical order.
    static func discover(home: URL = homeDirectory,
                         fileManager: FileManager = .default,
                         hasCredential: (AntigravityProfile) -> Bool = AntigravityCredentials.hasCredential) -> [AntigravityProfile] {
        let geminiDir = home.appendingPathComponent(".gemini")
        let names = (try? fileManager.contentsOfDirectory(atPath: geminiDir.path)) ?? []
        let extras = names.compactMap { name -> AntigravityProfile? in
            guard let slug = slug(fromDirectoryName: name) else { return nil }
            let directory = geminiDir.appendingPathComponent(name)
            guard isProfileDirectory(directory, fileManager: fileManager) else { return nil }
            let candidate = AntigravityProfile(slug: slug, configDirectory: directory)
            guard hasCredential(candidate) else { return nil }
            return candidate
        }
        return [.default(home: home)] + extras.sorted { $0.slug! < $1.slug! }
    }

    /// `antigravity-work` -> `work`; anything else -> nil. The bare `antigravity` is
    /// the default and is handled separately. Internal flavours (`ide`, `cli`, `backup`, `api`)
    /// are ignored unless explicit.
    static func slug(fromDirectoryName name: String) -> String? {
        let prefix = directoryPrefix + "-"
        guard name.hasPrefix(prefix) else { return nil }
        let slug = String(name.dropFirst(prefix.count))
        guard !slug.isEmpty, !ignoredSlugs.contains(slug) else { return nil }
        return slug
    }

    /// Markers identifying an Antigravity configuration/profile directory.
    private static let markers = [
        "oauth_creds.json",
        "credentials.json",
        "brain",
        "agent.db"
    ]

    static func isProfileDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return markers.contains {
            fileManager.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }

    // MARK: - Identity

    /// `gemini` for the default, `antigravity-<slug>` for the rest.
    var id: String { slug.map { "\(Self.directoryPrefix)-\($0)" } ?? Self.defaultID }

    /// `Antigravity`, or `Antigravity (work)`.
    var displayName: String { slug.map { "Antigravity (\($0))" } ?? "Antigravity" }

    /// Whether a provider id names an Antigravity profile, default or otherwise.
    static func isAntigravity(providerID: String) -> Bool {
        providerID == defaultID || (providerID.hasPrefix(directoryPrefix + "-") && slug(fromProviderID: providerID) != nil)
    }

    /// The slug back out of a provider id.
    static func slug(fromProviderID id: String) -> String? {
        let prefix = directoryPrefix + "-"
        guard id.hasPrefix(prefix) else { return nil }
        let slug = String(id.dropFirst(prefix.count))
        return slug.isEmpty ? nil : slug
    }

    var authURL: URL { configDirectory.appendingPathComponent("oauth_creds.json") }
    var brainDirectory: URL { configDirectory.appendingPathComponent("brain") }

    var keychainService: String? { slug == nil ? "gemini" : nil }
    var keychainAccount: String? { slug == nil ? "antigravity" : nil }

    var displayPath: String {
        let home = NSHomeDirectory()
        let path = configDirectory.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    var sourceName: String {
        guard let slug else { return "Antigravity" }
        return L10n.t("Antigravity in \(displayPath)")
    }

    var signInRoute: SignInRoute {
        guard let slug else {
            return .openApp(bundleID: "com.google.antigravity", name: "Antigravity")
        }
        return .guidance(L10n.t("Sign in to Antigravity in ~/.gemini/antigravity-\(slug) to read your usage"))
    }
}
