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

    /// The namespace every plugin id lives in. No built-in will ever be
    /// called `plugin-…`, so a plugin cannot take an id a later built-in
    /// wants — and the ids join ordering, connection state, archives and
    /// notifications, where such a collision would be permanent.
    static let idPrefix = "plugin-"

    /// `plugin-` followed by a slug in the built-ins' character set:
    /// `^plugin-[a-z0-9][a-z0-9-]*$`, at most `idLengthLimit` in all.
    /// Written on bytes so no Unicode lookalike squeezes through a
    /// character-class check.
    static func isValidID(_ id: String) -> Bool {
        guard (1...idLengthLimit).contains(id.count), id.hasPrefix(idPrefix) else { return false }
        let slug = id.dropFirst(idPrefix.count)
        guard !slug.isEmpty else { return false }
        for (index, byte) in slug.utf8.enumerated() {
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
        /// A user-owned executable outside the plugin directory: not covered
        /// by the content hash, so not something an approval could pin.
        case execOutsidePluginDirectory(String)
        /// A root-owned executable outside the plugin directory that is not
        /// on `PluginManifest.interpreterAllowlist`: `env` resolves through
        /// PATH, `zsh` sources `~/.zshenv`, `python3` imports the user site's
        /// `usercustomize` — code the hash never sees.
        case execNotAllowlisted(String)
        case glyphMissing(String)
        case glyphEscapesPluginDirectory(String)
        case signInNotAbsolute(String)
        case signInMissing(String)
        case signInNotExecutable(String)
        case signInUntrusted(String)
        case signInOutsidePluginDirectory(String)
        case signInNotAllowlisted(String)
        /// An absolute path among the arguments that leaves the plugin
        /// directory: for `/bin/sh script` that is the code, and it has to be
        /// where the hash covers it.
        case argumentOutsidePluginDirectory(String)
        case unknownActivity(String)
        /// A character outside printable ASCII in the command line — a
        /// newline that hides the rest of the command below the approval
        /// row, a bidirectional override that reverses it, a lookalike
        /// letter that names a different file than the one the row shows.
        case malformedArgument(String)
    }

    /// The root-owned executables a manifest may name from outside the plugin
    /// directory. Being root-owned keeps the binary itself out of the user's
    /// reach; what it *reads* to decide what to run has to be out of reach
    /// too, and with HOME in the child's environment most interpreters read
    /// something user-writable: zsh sources `~/.zshenv`, python3 imports the
    /// user site's `usercustomize.py`, `env` walks a PATH with Homebrew on
    /// it, `open` asks LaunchServices — whose registrations and default
    /// handlers the user's processes set — what `-a Helper` or `report.txt`
    /// means. These do not: a non-interactive `sh`/`bash` reads no startup
    /// file, and osascript loads nothing the script does not name. Anything
    /// else lives in the tree.
    static let interpreterAllowlist: Set<String> = [
        "/bin/sh", "/bin/bash", "/usr/bin/osascript",
    ]

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
        // Compared as skeletons, not strings: " claude", "Сlaude" with a
        // Cyrillic С, "Clàude", "C1aude" and "Claude!" are all the built-in
        // name to a reader. The error still names what the vendor wrote.
        let skeleton = Self.skeleton(displayName)
        guard !builtInDisplayNames.contains(where: { Self.skeleton($0) == skeleton }) else {
            throw ValidationError.impersonatesBuiltIn(displayName)
        }
        try Self.validateCommandLine([exec.path] + exec.args)
        try Self.validateExecutable(exec.path, pluginDirectory: pluginDirectory, fileManager: fileManager,
                                    notAbsolute: { ValidationError.execNotAbsolute($0) },
                                    missing: { ValidationError.execMissing($0) },
                                    notExecutable: { ValidationError.execNotExecutable($0) },
                                    untrusted: { ValidationError.execUntrusted($0) },
                                    outside: { ValidationError.execOutsidePluginDirectory($0) },
                                    notAllowlisted: { ValidationError.execNotAllowlisted($0) })
        try Self.validateArguments(exec.args, pluginDirectory: pluginDirectory)
        if let run = signIn?.run, let executable = run.first {
            try Self.validateCommandLine(run)
            try Self.validateExecutable(executable, pluginDirectory: pluginDirectory, fileManager: fileManager,
                                        notAbsolute: { ValidationError.signInNotAbsolute($0) },
                                        missing: { ValidationError.signInMissing($0) },
                                        notExecutable: { ValidationError.signInNotExecutable($0) },
                                        untrusted: { ValidationError.signInUntrusted($0) },
                                        outside: { ValidationError.signInOutsidePluginDirectory($0) },
                                        notAllowlisted: { ValidationError.signInNotAllowlisted($0) })
            try Self.validateArguments(Array(run.dropFirst()), pluginDirectory: pluginDirectory)
        }
        if let glyph {
            // Resolve `..` and symlinks before comparing prefixes: the glyph must
            // stay inside the plugin directory it was registered from.
            let location = pluginDirectory.appendingPathComponent(glyph.image)
            guard PluginTrust.isInside(location.path, directory: pluginDirectory) else {
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

    /// What a name looks like to a person, reduced to what a comparison can
    /// see: compatibility-decomposed (fullwidth and ligature forms fold to
    /// plain letters), accents and invisible format characters dropped,
    /// lowercased, the letters of other scripts that print like Latin ones
    /// mapped onto them, digits that pass for letters likewise, and only
    /// letters and digits kept. Two names with the same skeleton are the same
    /// name on screen.
    static func skeleton(_ name: String) -> String {
        var result = ""
        for scalar in name.decomposedStringWithCompatibilityMapping.lowercased().unicodeScalars {
            let category = scalar.properties.generalCategory
            switch category {
            case .nonspacingMark, .spacingMark, .enclosingMark, .format:
                continue
            default:
                break
            }
            let mapped = Self.confusables[scalar] ?? scalar
            guard mapped.properties.isAlphabetic || CharacterSet.decimalDigits.contains(mapped) else { continue }
            result.unicodeScalars.append(mapped)
        }
        return result
    }

    /// Lowercase letters from other scripts, and digits, that print as Latin
    /// letters at the notch's sizes. Not exhaustive — the built-in names are
    /// short Latin words, so this covers the letters those words use.
    private static let confusables: [Unicode.Scalar: Unicode.Scalar] = {
        let pairs: [(String, String)] = [
            // Cyrillic
            ("а", "a"), ("е", "e"), ("о", "o"), ("р", "p"), ("с", "c"), ("у", "y"), ("х", "x"),
            ("і", "i"), ("ј", "j"), ("ѕ", "s"), ("ԁ", "d"), ("ԛ", "q"), ("ԝ", "w"), ("һ", "h"),
            ("ӏ", "l"), ("ν", "v"), ("ɡ", "g"), ("ԍ", "g"), ("т", "t"), ("к", "k"), ("м", "m"),
            ("в", "b"), ("н", "h"), ("ё", "e"),
            // Greek
            ("α", "a"), ("ο", "o"), ("ε", "e"), ("ι", "i"), ("κ", "k"), ("ρ", "p"), ("τ", "t"),
            ("υ", "u"), ("χ", "x"), ("γ", "y"), ("β", "b"), ("η", "n"), ("μ", "u"),
            // Latin lookalikes and digits
            ("ı", "i"), ("ℓ", "l"), ("ꜱ", "s"), ("0", "o"), ("1", "l"), ("3", "e"), ("5", "s"),
            ("ß", "b"),
        ]
        var table: [Unicode.Scalar: Unicode.Scalar] = [:]
        for (from, to) in pairs {
            table[from.unicodeScalars.first!] = to.unicodeScalars.first!
        }
        return table
    }()

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

    /// Where an executable may live: inside the plugin directory, where the
    /// content hash covers its bytes, or anywhere root-owned, where the user's
    /// own processes cannot touch it. A user-owned binary elsewhere —
    /// `~/Downloads/tool`, a Homebrew install — is neither, and is refused
    /// rather than pinned by a hash that would not see it change.
    private static func validateExecutable(
        _ path: String,
        pluginDirectory: URL,
        fileManager: FileManager,
        notAbsolute: (String) -> ValidationError,
        missing: (String) -> ValidationError,
        notExecutable: (String) -> ValidationError,
        untrusted: (String) -> ValidationError,
        outside: (String) -> ValidationError,
        notAllowlisted: (String) -> ValidationError
    ) throws {
        guard path.hasPrefix("/") else { throw notAbsolute(path) }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { throw missing(path) }
        guard fileManager.isExecutableFile(atPath: path) else { throw notExecutable(path) }
        let url = URL(fileURLWithPath: path)
        guard PluginTrust.isTrustedExecutable(url, fileManager: fileManager)
        else { throw untrusted(path) }
        guard !PluginTrust.isInside(path, directory: pluginDirectory) else { return }
        guard PluginTrust.isOwnedByRoot(url, fileManager: fileManager) else { throw outside(path) }
        guard interpreterAllowlist.contains(path) else { throw notAllowlisted(path) }
    }

    /// Every word of a command line is printed on the approval row as the
    /// thing the user is agreeing to run, so every character in it must be
    /// one the row shows for what it is: printable ASCII. That rules out
    /// controls (a newline that hides the rest of the command below the
    /// row), format characters (a bidirectional override that reverses it)
    /// and lookalikes (`рun.sh` with a Cyrillic р, which reads as `run.sh`
    /// and is a different file). Scripts may hold any text they like; the
    /// words that name them may not.
    private static func validateCommandLine(_ words: [String]) throws {
        for word in words {
            guard word.utf8.allSatisfy({ (0x20...0x7E).contains($0) }) else {
                throw ValidationError.malformedArgument(word)
            }
        }
    }

    /// Every argument, read as a path, must stay inside the plugin directory.
    /// The child runs with the plugin directory as its working directory, so
    /// a relative argument is resolved there: `script.sh` and
    /// `<plugin dir>/script.sh` are both fine; `/Users/me/other.sh`,
    /// `../other.sh` and `lib/other.sh` through a symlink that leaves the
    /// directory are not. A script an interpreter runs is code, and code
    /// lives where the hash sees it. Words that are not paths (`-c`,
    /// `--json`) resolve to a name inside the directory and pass.
    private static func validateArguments(_ arguments: [String], pluginDirectory: URL) throws {
        for argument in arguments where !argument.isEmpty {
            let path = argument.hasPrefix("/")
                ? argument
                : pluginDirectory.appendingPathComponent(argument).path
            guard PluginTrust.isInside(path, directory: pluginDirectory) else {
                throw ValidationError.argumentOutsidePluginDirectory(argument)
            }
        }
    }
}
