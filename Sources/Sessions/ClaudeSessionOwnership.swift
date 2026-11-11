import Foundation

/// Which Claude profile a session belongs to, on a machine with more than one.
///
/// A session registry file says nothing about the account behind it, and until
/// now nothing had to: one profile, one directory, one account. It stops being
/// true the moment the Claude desktop app is signed in to a second account.
/// The app leaves `CLAUDE_CONFIG_DIR` unset, so Claude Code files every session
/// it hosts under `~/.claude/sessions` — the *default* profile's directory —
/// whichever account the app is actually using. The work was drawn on the wrong
/// ring, and switching account inside the app did not move it.
///
/// So ownership is decided per record rather than per directory:
///
///   * a session the desktop app hosts belongs to the profile whose account
///     uuid matches the one the app filed it under (`ClaudeDesktopSessionIndex`);
///   * everything else — a terminal, VS Code, an agent — belongs to the profile
///     whose directory holds it, exactly as before, because those *do* inherit
///     the variable that chose the directory;
///   * and anything that cannot be established falls back to the directory too.
///     An unreadable index, a profile that has never written `.claude.json`, an
///     account no profile on this machine is signed in to: all of them leave
///     the session where it already was rather than dropping it. A session on
///     the wrong ring is a bug; a session on no ring at all is a worse one.
@MainActor
struct ClaudeSessionOwnership {
    /// This monitor's own `sessions` directory.
    let own: URL
    /// Every profile's `sessions` directory, this one included.
    let directories: [URL]
    /// The account uuid behind each of those directories, by directory path,
    /// for the profiles that have one. See `ClaudeProfile.accountID()`.
    let accounts: [String: String]
    /// Each directory's transcript reader, by directory path. An adopted
    /// session's transcript stays in the profile that spawned it, so reading it
    /// with this profile's reader would find nothing and quietly call a busy
    /// session idle.
    let transcripts: [String: ClaudeTranscriptReader]
    /// The join between a desktop session and its account.
    let index: ClaudeDesktopSessionIndex
    /// Whether the profile behind a `sessions` directory has its ring switched
    /// on. Read on every claim, so switching a ring on or off moves its
    /// sessions at once.
    var isShown: (URL) -> Bool = { _ in true }

    init(own: URL,
         directories: [URL],
         accounts: [String: String],
         transcripts: [String: ClaudeTranscriptReader],
         index: ClaudeDesktopSessionIndex) {
        self.own = own
        self.directories = directories
        self.accounts = accounts
        self.transcripts = transcripts
        self.index = index
    }

    /// Whether this profile is the one that should draw `record`, found in
    /// `directory`.
    func claims(_ record: ClaudeSessionRecord, foundIn directory: URL) -> Bool {
        let owner = owner(of: record, foundIn: directory)
        // Two profiles can be signed in to the *same* account — an old second
        // login left behind after the default one was switched to it. The rule
        // above then always picks the first, and if that ring is switched off
        // every session is drawn on a ring nobody can see, while the ring that
        // is on for the very same account shows none. A profile whose ring is
        // on, signed in to the same account, draws them instead.
        guard !isShown(owner), let account = accounts[owner.path],
              let stand = directories.first(where: {
                  $0.path != owner.path && accounts[$0.path] == account && isShown($0)
              })
        else { return owner.path == own.path }
        return stand.path == own.path
    }

    /// The profile a session belongs to, before anything is switched off.
    private func owner(of record: ClaudeSessionRecord, foundIn directory: URL) -> URL {
        guard record.isDesktopHosted,
              let host = record.hostSessionID,
              let account = index.account(forHostSession: host),
              let target = directories.first(where: { accounts[$0.path] == account })
        else { return directory }
        return target
    }

    func reader(for directory: URL) -> ClaudeTranscriptReader? {
        transcripts[directory.path]
    }
}
