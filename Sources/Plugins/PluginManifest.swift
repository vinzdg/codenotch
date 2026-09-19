import Foundation

/// A plugin's `plugin.json`, as written into
/// `~/Library/Application Support/Codenotch/Plugins/<id>/` by the vendor's own
/// installer. The manifest is the whole registration: Codenotch never meets
/// the plugin's code until it executes `exec`, and never loads any of it.
///
/// The schema is versioned by `schema`; anything this build does not
/// understand fails validation and the plugin is skipped, so a newer plugin
/// cannot produce a half-working provider on an older app.
struct PluginManifest: Codable, Equatable, Sendable {
    struct Exec: Codable, Equatable, Sendable {
        let path: String
        let args: [String]
        let timeoutSeconds: TimeInterval?

        var timeout: TimeInterval { timeoutSeconds ?? 20 }
    }

    struct Glyph: Codable, Equatable, Sendable {
        /// Image file inside the plugin directory (PNG or PDF).
        let image: String
        let opticalScale: CGFloat?
    }

    struct SignIn: Codable, Equatable, Sendable {
        /// Shown on the settings row when the provider reports `needsAuth`.
        let guidance: String
        /// Spawned detached when the user clicks Sign in on the row.
        let run: [String]?
    }

    struct Activity: Codable, Equatable, Sendable {
        /// The only kind this build knows: watch a Claude Code config
        /// directory's session registry (`<configDir>/sessions` +
        /// `<configDir>/projects`).
        let type: String
        let configDir: String

        static let claudeSessions = "claudeSessions"
    }

    let schema: Int
    let id: String
    let displayName: String
    let version: String
    let exec: Exec
    let glyph: Glyph?
    let signIn: SignIn?
    let activity: Activity?

    static let currentSchema = 1
    static let idLengthLimit = 64
    static let displayNameLengthLimit = 40

    /// Ids join ordering, connection state, archives and notifications, so
    /// they get the same character set as the built-ins' slugs:
    /// `^[a-z0-9][a-z0-9-]*$`. Written on bytes so no Unicode lookalike
    /// squeezes through a character-class check.
    static func isValidID(_ id: String) -> Bool {
        guard (1...idLengthLimit).contains(id.count) else { return false }
        for (index, byte) in id.utf8.enumerated() {
            let isLower = byte >= 97 && byte <= 122
            let isDigit = byte >= 48 && byte <= 57
            let isHyphen = byte == 45
            guard isLower || isDigit || (index > 0 && isHyphen) else { return false }
        }
        return true
    }

    enum ValidationError: Error, Equatable {
        case unsupportedSchema(Int)
        case malformedID(String)
        case collidesWithBuiltIn(String)
        case malformedDisplayName(String)
        case impersonatesBuiltIn(String)
        case execNotAbsolute(String)
        case execMissing(String)
        case execNotExecutable(String)
        case execUntrusted(String)
        case glyphMissing(String)
        case glyphEscapesPluginDirectory(String)
        case signInNotAbsolute(String)
        case signInMissing(String)
        case signInNotExecutable(String)
        case signInUntrusted(String)
        case unknownActivity(String)
    }

    /// `builtInIDs` and `builtInDisplayNames` are supplied by the caller because
    /// the built-in set lives in `AppDelegate`, and a manifest validator has no
    /// business reaching across the app for it.
    func validated(builtInIDs: Set<String>,
                   builtInDisplayNames: Set<String> = [],
                   pluginDirectory: URL,
                   fileManager: FileManager = .default) throws -> PluginManifest {
        guard schema == Self.currentSchema else {
            throw ValidationError.unsupportedSchema(schema)
        }
        guard Self.isValidID(id) else {
            throw ValidationError.malformedID(id)
        }
        guard !builtInIDs.contains(id) else {
            throw ValidationError.collidesWithBuiltIn(id)
        }
        guard Self.isValidDisplayName(displayName) else {
            throw ValidationError.malformedDisplayName(displayName)
        }
        // Trimmed and case-insensitive: " claude" is as much an impersonation
        // as "Claude". The error still names what the vendor actually wrote.
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !builtInDisplayNames.contains(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) else {
            throw ValidationError.impersonatesBuiltIn(displayName)
        }
        try Self.validateExecutable(exec.path, fileManager: fileManager,
                                    notAbsolute: { ValidationError.execNotAbsolute($0) },
                                    missing: { ValidationError.execMissing($0) },
                                    notExecutable: { ValidationError.execNotExecutable($0) },
                                    untrusted: { ValidationError.execUntrusted($0) })
        if let run = signIn?.run, let executable = run.first {
            try Self.validateExecutable(executable, fileManager: fileManager,
                                        notAbsolute: { ValidationError.signInNotAbsolute($0) },
                                        missing: { ValidationError.signInMissing($0) },
                                        notExecutable: { ValidationError.signInNotExecutable($0) },
                                        untrusted: { ValidationError.signInUntrusted($0) })
        }
        if let glyph {
            // Resolve `..` and symlinks before comparing prefixes: the glyph must
            // stay inside the plugin directory it was registered from.
            let root = pluginDirectory.standardizedFileURL.resolvingSymlinksInPath()
            let location = root.appendingPathComponent(glyph.image)
                .standardizedFileURL.resolvingSymlinksInPath()
            guard location.path.hasPrefix(root.path + "/") else {
                throw ValidationError.glyphEscapesPluginDirectory(glyph.image)
            }
            guard fileManager.fileExists(atPath: location.path) else {
                throw ValidationError.glyphMissing(glyph.image)
            }
        }
        if let activity, activity.type != Activity.claudeSessions {
            throw ValidationError.unknownActivity(activity.type)
        }
        return self
    }

    /// A name the settings sheet can print without being lied to or laid out by:
    /// short, single-line, free of control characters.
    static func isValidDisplayName(_ name: String) -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= displayNameLengthLimit
        else { return false }
        return name.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r"
        }
    }

    private static func validateExecutable(
        _ path: String,
        fileManager: FileManager,
        notAbsolute: (String) -> ValidationError,
        missing: (String) -> ValidationError,
        notExecutable: (String) -> ValidationError,
        untrusted: (String) -> ValidationError
    ) throws {
        guard path.hasPrefix("/") else { throw notAbsolute(path) }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { throw missing(path) }
        guard fileManager.isExecutableFile(atPath: path) else { throw notExecutable(path) }
        guard PluginTrust.isTrustedExecutable(URL(fileURLWithPath: path), fileManager: fileManager)
        else { throw untrusted(path) }
    }
}
