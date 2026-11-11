import Foundation

/// One Command Code home, and so one account.
///
/// Command Code keeps its login in `$HOME/.commandcode/auth.json` and has no
/// setting for a second configuration directory. The only way to hold a second
/// account is to start it with another `HOME`, so a profile directory is that
/// other home: `~/.commandcode-<slug>`, with the login inside it at
/// `.commandcode/auth.json`. A login file placed directly in the profile
/// directory is read too, for anyone who copies one there by hand.
struct CommandCodeProfile: Equatable, Hashable {
    static let defaultID = "commandcode"
    static let directoryPrefix = ".commandcode"

    let slug: String?
    let configDirectory: URL

    static var homeDirectory: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    static func `default`(home: URL = homeDirectory) -> CommandCodeProfile {
        CommandCodeProfile(slug: nil, configDirectory: home.appendingPathComponent(directoryPrefix))
    }

    static func discover(home: URL = homeDirectory,
                         fileManager: FileManager = .default) -> [CommandCodeProfile] {
        let names = (try? fileManager.contentsOfDirectory(atPath: home.path)) ?? []
        let extras = names.compactMap { name -> CommandCodeProfile? in
            guard let slug = slug(fromDirectoryName: name) else { return nil }
            let directory = home.appendingPathComponent(name)
            guard isProfileDirectory(directory, fileManager: fileManager) else { return nil }
            return CommandCodeProfile(slug: slug, configDirectory: directory)
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
        return [".commandcode/auth.json", ".commandcode/config.json", "auth.json", "config.json"].contains {
            fileManager.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }

    // Preserve the default id so existing readings and preferences survive.
    var id: String { slug.map { "\(Self.defaultID)-\($0)" } ?? Self.defaultID }

    /// Whether a provider id names a Command Code profile, default or otherwise.
    static func isCommandCode(providerID: String) -> Bool {
        providerID == defaultID || providerID.hasPrefix(defaultID + "-")
    }

    var displayName: String { slug.map { "Command Code (\($0))" } ?? "Command Code" }

    static func slug(fromProviderID id: String) -> String? {
        let prefix = defaultID + "-"
        guard id.hasPrefix(prefix) else { return nil }
        let slug = String(id.dropFirst(prefix.count))
        return slug.isEmpty ? nil : slug
    }

    /// Where this profile's login is. The default profile is the configuration
    /// directory itself. Any other profile is a home directory, so the login is
    /// one level down — unless a login file sits directly in the profile
    /// directory and the nested one does not exist.
    var authURL: URL {
        let direct = configDirectory.appendingPathComponent("auth.json")
        guard slug != nil else { return direct }
        let nested = configDirectory.appendingPathComponent(".commandcode/auth.json")
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: nested.path), fileManager.fileExists(atPath: direct.path) {
            return direct
        }
        return nested
    }

    var displayPath: String {
        let home = NSHomeDirectory()
        let path = configDirectory.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    var sourceName: String { slug == nil ? "Command Code" : "Command Code in \(displayPath)" }

    var signInCommand: String {
        guard slug != nil else { return "commandcode login" }
        // Quote the actual path, including spaces and apostrophes. A quoted ~
        // would not expand, and an unquoted slug could become shell syntax.
        let path = "'" + configDirectory.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        return "HOME=\(path) commandcode login"
    }
}
