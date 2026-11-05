import Foundation

/// Which account a session the Claude desktop app hosts actually belongs to.
///
/// Claude Code files its session registry inside whatever `CLAUDE_CONFIG_DIR`
/// names, and the desktop app leaves that variable unset — so every session the
/// app hosts lands in `~/.claude/sessions`, the *default* profile's directory,
/// whichever account the app is signed in to. Switching account inside the app
/// changes the credential and changes nothing about where the file goes. That
/// is why a second profile's work spun the default profile's ring: the registry
/// entry is filed by directory, and the directory is not the account.
///
/// Nothing in the registry entry names the account either. But the desktop app
/// keeps its own record of every session it has hosted, one directory per
/// account:
///
///     ~/Library/Application Support/Claude/claude-code-sessions/
///         <accountUuid>/<organizationUuid>/<hostSessionId>.json
///
/// and the registry entry carries that `hostSessionId`. So the two join on it,
/// entirely locally: no network, no keychain, nothing sent anywhere. The uuid
/// on our side is `ClaudeProfile.accountID()`, read from the same `.claude.json`
/// the Settings row's address comes from.
///
/// Not a general directory index on purpose. A session is asked about by id,
/// and the answer is a handful of `stat` calls down two shallow levels — far
/// less than enumerating every session the app has ever hosted on a machine
/// that has been in use for a year.
@MainActor
final class ClaudeDesktopSessionIndex {
    /// `homeDirectoryForCurrentUser`, as `ClaudeDesktopUsageCache` uses for the
    /// app's cache beside this.
    static let defaultRoot = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions",
                                isDirectory: true)

    private let root: URL
    private let fileManager: FileManager

    /// Held for good once found. Which account hosted a session is decided when
    /// the session is created and cannot change under us, so re-reading it
    /// could only ever produce the same answer — the reasoning `CredentialCache`
    /// states outright and `AccountFileCache` gates on.
    private var resolved: [String: String] = [:]

    /// A miss is deliberately *not* cached. The app writes its record a moment
    /// after Claude Code registers the session, so the first look can legitimately
    /// find nothing, and remembering "unknown" would mean never looking again —
    /// the session would spend its whole life on the wrong ring.
    init(root: URL = ClaudeDesktopSessionIndex.defaultRoot,
         fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    /// The account uuid that hosts this session, or nil while it cannot be told.
    func account(forHostSession id: String) -> String? {
        if let held = resolved[id] { return held }
        guard let found = search(id) else { return nil }
        resolved[id] = found
        return found
    }

    /// The accounts the app has hosted Claude Code sessions for that none of
    /// `profiles` is signed in to.
    ///
    /// Such an account has no `~/.claude-<slug>` and so no ring of its own
    /// (#509). It is still worth knowing about: with one in use, a lone ring
    /// is no longer the only Claude account on the Mac, and has to say which
    /// one it is. See `ClaudeProfile.displayNames(for:anotherAccountInUse:)`.
    ///
    /// One directory listing, read once at launch. A profile whose
    /// `.claude.json` names no account cannot be matched, so its account is
    /// counted here too: the cost of that is a ring named after its address,
    /// which is never wrong.
    func untrackedAccounts(among profiles: [ClaudeProfile]) -> [String] {
        let tracked = Set(profiles.compactMap { $0.accountID() })
        return children(of: root).filter { !tracked.contains($0) }
    }

    private func search(_ id: String) -> String? {
        // A path component from a file written by another program: a `..` or a
        // slash in it would walk out of the directory being searched, so the id
        // is checked rather than trusted.
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { return nil }
        let file = id + ".json"

        for account in children(of: root) {
            let accountURL = root.appendingPathComponent(account)
            for project in children(of: accountURL) {
                let candidate = accountURL
                    .appendingPathComponent(project)
                    .appendingPathComponent(file)
                if fileManager.fileExists(atPath: candidate.path) { return account }
            }
        }
        return nil
    }

    /// Visible subdirectory names, sorted so a machine with two accounts is
    /// searched in the same order every time and a log line means the same
    /// thing twice.
    private func children(of directory: URL) -> [String] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }
}
