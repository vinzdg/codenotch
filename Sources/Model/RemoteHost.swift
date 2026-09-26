import Foundation

/// Which account a remote host entry watches. One entry is one account: a
/// server running both Claude Code and Codex gets two entries, one per kind.
enum RemoteHostKind: String, Codable, Equatable, Sendable, CaseIterable {
    case claude
    case codex

    /// The provider-id prefix, so each kind lands in its own family: the
    /// weekly rules, the five-hour grouping and the pace overlay treat a
    /// remote login as the account it is.
    var providerPrefix: String {
        switch self {
        case .claude: return "claude-remote-"
        case .codex: return "codex-remote-"
        }
    }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// What the save-time probe looks for, in order. A file check is a
    /// `test -f`; a keychain check only runs on a Darwin far side.
    var credentialChecks: [RemoteCredentialCheck] {
        switch self {
        case .claude:
            return [.file("~/.claude/.credentials.json"),
                    .macKeychain(service: ClaudeProfile.defaultKeychainService)]
        case .codex:
            return [.file("~/.codex/auth.json")]
        }
    }

    /// The command that signs this kind in on its server, for the probe's
    /// "found nothing" guidance.
    var signInCommand: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        }
    }
}

/// One place a token can live on the far side.
enum RemoteCredentialCheck: Equatable, Sendable {
    case file(String)
    case macKeychain(service: String)

    /// How the probe names it back to the user.
    var displayPath: String {
        switch self {
        case .file(let path): return path
        case .macKeychain(let service): return "login keychain (\(service))"
        }
    }
}

/// One coding account on another machine, reached over SSH.
///
/// The account's token lives where its CLI keeps it over there, and the
/// usage endpoint answers the same bearer token from anywhere, so one SSH
/// read per token lifetime is the whole transport. Key auth only: the poll
/// runs on a timer and must never stop at a password prompt.
struct RemoteHost: Identifiable, Codable, Equatable, Sendable {
    static func isRemote(providerID: String) -> Bool {
        RemoteHostKind.allCases.contains { providerID.hasPrefix($0.providerPrefix) }
    }

    static func isRemoteClaude(providerID: String) -> Bool {
        providerID.hasPrefix(RemoteHostKind.claude.providerPrefix)
    }

    static func isRemoteCodex(providerID: String) -> Bool {
        providerID.hasPrefix(RemoteHostKind.codex.providerPrefix)
    }

    /// Stable across launches: the archive, nicknames and connection choices
    /// all key off the provider id built from it.
    var id: String
    /// Which account this entry watches. Fixed at creation: the provider id
    /// is built from it, so changing it later would orphan the old ring's
    /// archive and nicknames — a different kind is a different entry.
    var kind: RemoteHostKind
    /// What the ring and the rows call this account. Free text — the token
    /// carries no address, and a second SSH call per poll just to learn one
    /// is not worth it.
    var name: String
    var host: String
    var user: String
    var port: Int
    /// Optional `-i` path, for a key that is not the default.
    var identityFile: String?
    var isEnabled: Bool

    init(id: String = UUID().uuidString, kind: RemoteHostKind = .claude,
         name: String, host: String, user: String,
         port: Int = 22, identityFile: String? = nil, isEnabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.name = name
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.isEnabled = isEnabled
    }

    var providerID: String { kind.providerPrefix + id }

    /// `user@host`, as ssh spells it and as the copy names it.
    var destination: String { "\(user.trimmingCharacters(in: .whitespaces))@\(host.trimmingCharacters(in: .whitespaces))" }

    /// What the ring calls it when the name was left blank.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? destination : trimmed
    }

    /// Enough filled in to attempt a connection. Checked where providers are
    /// built, so a half-added row cannot produce a ring that only errors.
    var isConfigured: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && port > 0
    }

    func makeProvider() -> UsageProvider {
        switch kind {
        case .claude: return ClaudeRemoteProvider(host: self)
        case .codex: return CodexRemoteProvider(host: self)
        }
    }

    /// The `user@host` behind a provider id, for copy that only has the id.
    /// Nil when the host is gone — a removed row must not resurrect words.
    static func destination(forProviderID id: String,
                            defaults: UserDefaults = .standard) -> String? {
        Preferences.storedRemoteHosts(defaults: defaults)
            .first { $0.providerID == id }
            .map(\.destination)
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, name, host, user, port, identityFile, isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        // Entries written before kinds existed were all Claude.
        kind = try container.decodeIfPresent(RemoteHostKind.self, forKey: .kind) ?? .claude
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        user = try container.decodeIfPresent(String.self, forKey: .user) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}
