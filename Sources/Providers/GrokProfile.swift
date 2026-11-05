import Foundation

/// One Grok home, and so one account.
///
/// The Grok CLI honors `GROK_HOME`: set it and `grok login` writes a second
/// account's session somewhere other than `~/.grok`. The convention this reads
/// is a directory per extra home — `~/.grok-work`, `~/.grok-alt`, and so on —
/// with the login inside it at `auth.json`, the same shape the default
/// `~/.grok` already has. Sign one in with
/// `GROK_HOME=~/.grok-work grok login`.
///
/// A profile is the directory, not the variable: the app launches from
/// Finder, so `GROK_HOME` never reaches it, and the directories are the only
/// trace the extra accounts leave.
struct GrokProfile: Equatable, Hashable {
    static let defaultID = "grok"
    static let directoryPrefix = ".grok"

    let slug: String?
    let configDirectory: URL

    static var homeDirectory: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    static func `default`(home: URL = homeDirectory) -> GrokProfile {
        GrokProfile(slug: nil, configDirectory: home.appendingPathComponent(directoryPrefix))
    }

    static func discover(home: URL = homeDirectory,
                         fileManager: FileManager = .default) -> [GrokProfile] {
        let names = (try? fileManager.contentsOfDirectory(atPath: home.path)) ?? []
        let extras = names.compactMap { name -> GrokProfile? in
            guard let slug = slug(fromDirectoryName: name) else { return nil }
            let directory = home.appendingPathComponent(name)
            guard isProfileDirectory(directory, fileManager: fileManager) else { return nil }
            return GrokProfile(slug: slug, configDirectory: directory)
        }
        return [.default(home: home)] + extras.sorted { $0.slug! < $1.slug! }
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
        // A signed-out profile still has its settings. Keep its row so it can
        // explain how to sign that account back in.
        return ["auth.json", "config.toml"].contains {
            fileManager.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }

    // Preserve the default id so existing readings and preferences survive.
    var id: String { slug.map { "\(Self.defaultID)-\($0)" } ?? Self.defaultID }

    /// Whether a provider id names a Grok profile, default or otherwise.
    static func isGrok(providerID: String) -> Bool {
        providerID == defaultID || providerID.hasPrefix(defaultID + "-")
    }

    var displayName: String { slug.map { "Grok (\($0))" } ?? "Grok" }

    static func slug(fromProviderID id: String) -> String? {
        let prefix = defaultID + "-"
        guard id.hasPrefix(prefix) else { return nil }
        let slug = String(id.dropFirst(prefix.count))
        return slug.isEmpty ? nil : slug
    }

    /// Where this profile's login is. The Grok home *is* the configuration
    /// directory: `auth.json` sits directly inside it, default or otherwise.
    var authURL: URL { configDirectory.appendingPathComponent("auth.json") }

    var displayPath: String {
        let home = NSHomeDirectory()
        let path = configDirectory.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    var sourceName: String { slug == nil ? "Grok" : "Grok in \(displayPath)" }

    var signInCommand: String {
        guard slug != nil else { return "grok login" }
        // Quote the actual path, including spaces and apostrophes. A quoted ~
        // would not expand, and an unquoted slug could become shell syntax.
        let path = "'" + configDirectory.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        return "GROK_HOME=\(path) grok login"
    }
}
