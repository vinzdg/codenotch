import Foundation

/// The local provider families that support multiple side-by-side accounts on
/// one Mac through isolated configuration directories (`~/.claude-<slug>`,
/// `~/.codex-<slug>`, `~/.gemini/antigravity-<slug>`, `~/.commandcode-<slug>`).
enum ProfileFamily: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case antigravity
    case commandCode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude:      return "Claude"
        case .codex:       return "Codex"
        case .antigravity: return "Antigravity"
        case .commandCode: return "Command Code"
        }
    }

    var glyph: ProviderGlyph {
        switch self {
        case .claude:      return .claude
        case .codex:       return .openai
        case .antigravity: return .antigravity
        case .commandCode: return .commandcode
        }
    }

    var defaultID: String {
        switch self {
        case .claude:      return ClaudeProfile.defaultID
        case .codex:       return CodexProfile.defaultID
        case .antigravity: return AntigravityProfile.defaultID
        case .commandCode: return CommandCodeProfile.defaultID
        }
    }

    func providerID(forSlug slug: String) -> String {
        switch self {
        case .claude:      return "claude-\(slug)"
        case .codex:       return "codex-\(slug)"
        case .antigravity: return "antigravity-\(slug)"
        case .commandCode: return "commandcode-\(slug)"
        }
    }

    func displayName(forSlug slug: String) -> String {
        "\(title) (\(slug))"
    }

    func configDirectory(forSlug slug: String,
                         home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        switch self {
        case .claude:      return home.appendingPathComponent(".claude-\(slug)")
        case .codex:       return home.appendingPathComponent(".codex-\(slug)")
        case .antigravity: return home.appendingPathComponent(".gemini/antigravity-\(slug)")
        case .commandCode: return home.appendingPathComponent(".commandcode-\(slug)")
        }
    }

    func displayPath(forSlug slug: String) -> String {
        switch self {
        case .claude:      return "~/.claude-\(slug)"
        case .codex:       return "~/.codex-\(slug)"
        case .antigravity: return "~/.gemini/antigravity-\(slug)"
        case .commandCode: return "~/.commandcode-\(slug)"
        }
    }

    /// Normalizes a user-supplied profile label or path fragment into a safe
    /// directory slug (for example `"Work"` or `"~/.claude-work"` -> `"work"`).
    /// Returns `nil` when nothing valid remains or when the slug is reserved.
    func normalizeSlug(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }

        // Strip common path or provider prefixes if someone pasted a directory
        // name instead of just the slug.
        let prefixes = [
            "~/.gemini/antigravity-", ".gemini/antigravity-",
            "~/.claude-", ".claude-", "claude-",
            "~/.codex-", ".codex-", "codex-",
            "~/.commandcode-", ".commandcode-", "commandcode-",
            "antigravity-"
        ]
        for prefix in prefixes where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }

        // Turn runs of spaces into hyphens and keep only safe filename characters.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var normalized = ""
        var previousWasHyphen = false
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespaces.contains(scalar) || scalar == "-" {
                if !normalized.isEmpty && !previousWasHyphen {
                    normalized.append("-")
                    previousWasHyphen = true
                }
            } else if allowed.contains(scalar) {
                normalized.unicodeScalars.append(scalar)
                previousWasHyphen = false
            }
        }
        while normalized.hasSuffix("-") {
            normalized.removeLast()
        }
        guard !normalized.isEmpty else { return nil }

        if self == .antigravity {
            // Antigravity reserves internal flavours (`ide`, `cli`, `backup`, `api`).
            guard AntigravityProfile.slug(fromDirectoryName: "antigravity-\(normalized)") != nil else {
                return nil
            }
        }
        return normalized
    }

    /// Which local multi-profile family `id` belongs to, if any. Remote SSH
    /// hosts have their own pane and lifecycle and are excluded here.
    static func family(forProviderID id: String) -> ProfileFamily? {
        if ClaudeProfile.isClaude(providerID: id) && !RemoteHost.isRemoteClaude(providerID: id) {
            return .claude
        }
        if CodexProfile.isCodex(providerID: id) && !RemoteHost.isRemoteCodex(providerID: id) {
            return .codex
        }
        if AntigravityProfile.isAntigravity(providerID: id) {
            return .antigravity
        }
        if CommandCodeProfile.isCommandCode(providerID: id) {
            return .commandCode
        }
        return nil
    }

    /// The profile slug for a named extra profile, or `nil` for a default
    /// profile or non-profile provider.
    static func slug(forProviderID id: String) -> String? {
        guard let family = family(forProviderID: id) else { return nil }
        switch family {
        case .claude:      return ClaudeProfile.slug(fromProviderID: id)
        case .codex:       return CodexProfile.slug(fromProviderID: id)
        case .antigravity: return AntigravityProfile.slug(fromProviderID: id)
        case .commandCode: return CommandCodeProfile.slug(fromProviderID: id)
        }
    }

    /// True when `id` is a named secondary profile (`claude-work`, `codex-work`,
    /// `antigravity-work`, `commandcode-work`) rather than the default seat.
    static func isExtraProfile(providerID id: String) -> Bool {
        slug(forProviderID: id) != nil
    }
}

/// A secondary account profile explicitly added in Settings so Codenotch can
/// list its row and offer one-click sign-in before the CLI has written its
/// first credential to disk or the keychain.
struct ConfiguredProfile: Codable, Identifiable, Equatable, Hashable, Sendable {
    var family: ProfileFamily
    var slug: String

    var id: String { family.providerID(forSlug: slug) }
    var displayName: String { family.displayName(forSlug: slug) }
    var displayPath: String { family.displayPath(forSlug: slug) }

    func configDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        family.configDirectory(forSlug: slug, home: home)
    }

    /// Creates the profile's configuration directory on disk so the CLI login
    /// command (`codex login`, `claude auth login`, `commandcode login`) finds
    /// the target folder ready without manual `mkdir -p` in Terminal.
    func ensureDirectoryExists(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let dir = configDirectory(home: home)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if family == .commandCode {
            // `HOME=~/.commandcode-<slug> commandcode login` writes under `.commandcode/`.
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(".commandcode"),
                withIntermediateDirectories: true
            )
        }
    }
}
