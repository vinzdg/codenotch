import CryptoKit
import Foundation

/// One Claude Code configuration directory, and so one account.
///
/// Claude Code keeps everything for an account under a single directory:
/// `~/.claude` by default, or wherever `CLAUDE_CONFIG_DIR` points. People who
/// keep a personal and a work login apart do it by aliasing the second one to
/// `~/.claude-work`, `~/.claude-client`, and so on — each with its own token in
/// the keychain and its own `sessions` folder. Reading only `~/.claude` showed
/// one of those accounts and was blind to the others: a work session never
/// spun the ring, and the work limit was never drawn at all.
///
/// A profile is the *convention* `~/.claude-<slug>`, not the environment
/// variable: the app is launched from Finder, so the alias's variable never
/// reaches it, and the directories are the only trace the profiles leave.
struct ClaudeProfile: Equatable, Hashable {
    /// The provider id the default profile has always had. Kept so archived
    /// readings, connection choices and the hover-band keys survive the change.
    static let defaultID = "claude"
    /// What every profile directory starts with.
    static let directoryPrefix = ".claude"

    /// Nil for `~/.claude`; the part after `.claude-` otherwise.
    let slug: String?
    let configDirectory: URL

    /// `~/.claude`, whether or not it exists — the app has always read it.
    static func `default`(home: URL = homeDirectory) -> ClaudeProfile {
        ClaudeProfile(slug: nil,
                      configDirectory: home.appendingPathComponent(directoryPrefix))
    }

    static var homeDirectory: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    /// The default profile followed by every `~/.claude-<slug>` that Claude
    /// Code has actually used, slugs in alphabetical order so the rings never
    /// swap places between launches.
    ///
    /// "Actually used" is judged twice over. The files Claude Code writes on
    /// its first run rule out an empty directory or a stray one someone made
    /// by hand; a token filed under the directory's own service name rules out
    /// everything else that has learned to live at `~/.claude-<slug>`.
    ///
    /// The second test is what keeps plugins out. `claude-mem` keeps its state
    /// in `~/.claude-mem` and writes every one of the first-run names above, so
    /// the filename rules pass it and it is not an account: Claude Code has
    /// never signed in there and never will, so the ring could only ever read
    /// "Sign in to Claude Code in ~/.claude-mem to read your usage" — advice
    /// that cannot be followed, for a limit that does not exist. Filenames
    /// alone cannot tell the two apart, and a denylist of plugin names would
    /// only postpone the next one. The credential can: no token, no account,
    /// no ring.
    ///
    /// `hasCredential` is injected so discovery stays testable — the real one
    /// reads the login keychain, which a test has no business touching. It only
    /// enumerates attributes and takes a persistent reference, neither of which
    /// needs authorization, so this costs no extra prompt per candidate.
    static func discover(home: URL = homeDirectory,
                         fileManager: FileManager = .default,
                         hasCredential: (ClaudeProfile) -> Bool = Self.hasKeychainCredential)
    -> [ClaudeProfile] {
        let names = (try? fileManager.contentsOfDirectory(atPath: home.path)) ?? []
        let extras = names.compactMap { name -> ClaudeProfile? in
            guard let slug = slug(fromDirectoryName: name) else { return nil }
            let directory = home.appendingPathComponent(name)
            guard isProfileDirectory(directory, fileManager: fileManager) else { return nil }
            let candidate = ClaudeProfile(slug: slug, configDirectory: directory)
            guard hasCredential(candidate) else {
                Log.usage.debug("ignoring \(candidate.displayPath, privacy: .public): looks like a profile but has no token under \(candidate.keychainService, privacy: .public)")
                return nil
            }
            return candidate
        }
        return [ClaudeProfile.default(home: home)]
            + extras.sorted { $0.slug! < $1.slug! }
    }

    /// Whether Claude Code has ever filed a token for this profile's directory.
    ///
    /// Asks across `keychainServices` rather than the primary name alone, so a
    /// profile whose token was written under either spelling still counts.
    ///
    /// Deliberately not a check on whether that token is *valid*. An expired
    /// one still means the account exists and the ring is worth drawing — the
    /// provider degrades it to `credentialExpired` and shows the last reading
    /// with its age, which is the right answer for a profile that has not been
    /// used since the token last rotated.
    static func hasKeychainCredential(_ profile: ClaudeProfile) -> Bool {
        KeychainItem.newest(services: profile.keychainServices) != nil
    }

    /// `.claude-work` → `work`; anything else → nil. The bare `.claude` is the
    /// default and is handled separately; `.claude.json` is a file that lives
    /// beside it and is not a profile at all.
    static func slug(fromDirectoryName name: String) -> String? {
        let prefix = directoryPrefix + "-"
        guard name.hasPrefix(prefix) else { return nil }
        let slug = String(name.dropFirst(prefix.count))
        return slug.isEmpty ? nil : slug
    }

    /// Any of the files Claude Code creates the first time it runs against a
    /// directory. One is enough: they are not all present on every version.
    private static let markers = ["sessions", "projects", "settings.json",
                                  "history.jsonl", ".claude.json"]

    static func isProfileDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return markers.contains {
            fileManager.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }

    // MARK: - Identity

    /// `claude` for the default, `claude-<slug>` for the rest. Doubles as the
    /// usage provider id and the activity monitor key, so a profile's sessions
    /// land in its own ring.
    var id: String { slug.map { "\(Self.defaultID)-\($0)" } ?? Self.defaultID }

    /// `Claude Gmail`, `Claude Acme` — the account's own name where Claude Code
    /// records one — and `Claude` or `Claude (work)` where it does not.
    ///
    /// The directory name was the only thing here before, and it cannot say
    /// what a person actually wants to read. The default profile is always
    /// `~/.claude`, so the account most people use every day was the one ring
    /// with no name on it at all, and a second login could only be told apart
    /// by whatever its directory happened to be called — `Claude (work)` for a
    /// directory named `.claude-work`, whoever is signed in to it. The address
    /// Claude Code has already written down is the real answer, it is read here
    /// anyway for the Settings row, and it costs no keychain prompt. See
    /// `signedInAddress()`.
    ///
    /// The old spelling is kept as the fallback rather than dropped: a profile
    /// whose `.claude.json` has not been written yet, or was signed out, still
    /// has to be named something, and the directory is all there is then.
    ///
    /// This is the name that tells a profile apart. Whether it needs telling
    /// apart at all is for `displayNames(for:)`, which sees every profile.
    var displayName: String {
        guard let label = accountLabel() else {
            return slug.map { "Claude (\($0))" } ?? "Claude"
        }
        return "Claude \(label)"
    }

    /// The one word that names this account: `Gmail` for a gmail.com address,
    /// `Hotmail` for hotmail.com, `Acme` for someone@acme.co.uk.
    ///
    /// The domain rather than the local part, on purpose. A person's local part
    /// is usually the same word on every account they own — it is the domain
    /// that separates the personal login from the work one at a glance, which
    /// is the question two Claude rings actually raise.
    func accountLabel() -> String? {
        Self.accountLabel(forAddress: signedInAddress())
    }

    /// Kept static and separate from the file it comes from so the rule can be
    /// tested without a `.claude.json` on disk.
    static func accountLabel(forAddress address: String?) -> String? {
        guard let address, let at = address.lastIndex(of: "@") else { return nil }
        let domain = address[address.index(after: at)...]
        // Empty pieces kept, so a domain that starts with a dot is malformed
        // rather than silently read as the piece after it.
        guard let first = domain.split(separator: ".", omittingEmptySubsequences: false)
                  .first.map(String.init),
              !first.isEmpty,
              // An address can be anything; a label that is punctuation or a
              // lone digit names nothing, and `Claude` alone beats `Claude 1`.
              first.rangeOfCharacter(from: .letters) != nil
        else { return nil }
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    /// A name per profile id, with the whole address standing in wherever two
    /// accounts would otherwise be called the same thing.
    ///
    /// Two logins on the same provider — two gmail.com accounts, or two on one
    /// company domain — would draw two rings with identical names, which is
    /// worse than the directory names this replaced. Only the profiles that
    /// actually collide pay the longer name.
    ///
    /// And a lone account is just `Claude`. The label is there to tell one ring
    /// from another; with nothing to tell it from, `Claude Gmail Usage` over
    /// the only Claude card reads as a product that does not exist.
    static func displayNames(for profiles: [ClaudeProfile]) -> [String: String] {
        if profiles.count == 1, let only = profiles.first {
            return [only.id: "Claude"]
        }

        var sharing: [String: Int] = [:]
        for profile in profiles { sharing[profile.displayName, default: 0] += 1 }

        var names: [String: String] = [:]
        for profile in profiles {
            let name = profile.displayName
            guard sharing[name, default: 0] > 1,
                  let address = profile.signedInAddress()
            else { names[profile.id] = name; continue }
            names[profile.id] = "Claude \(address)"
        }
        return names
    }

    /// Whether a provider id names a Claude profile, default or otherwise.
    static func isClaude(providerID: String) -> Bool {
        providerID == defaultID || providerID.hasPrefix(defaultID + "-")
    }

    /// The slug back out of a provider id, for code that only has the id.
    static func slug(fromProviderID id: String) -> String? {
        guard id.hasPrefix(defaultID + "-") else { return nil }
        let slug = String(id.dropFirst(defaultID.count + 1))
        return slug.isEmpty ? nil : slug
    }

    /// The directory as a person would type it.
    var displayPath: String {
        Self.tilde(configDirectory.path)
    }

    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    // MARK: - What Claude Code keeps where

    /// Where Claude Code writes one file per running process.
    var sessionsDirectory: URL { configDirectory.appendingPathComponent("sessions") }

    /// Where it writes each session's transcript, one directory per working
    /// directory. The registry says which sessions exist; this says what they
    /// are doing — see `ClaudeTranscript`.
    var projectsDirectory: URL { configDirectory.appendingPathComponent("projects") }

    /// Claude Code's own settings file, which carries the signed-in address.
    ///
    /// The default profile keeps it *beside* the directory, at `~/.claude.json`;
    /// a profile reached through `CLAUDE_CONFIG_DIR` keeps it *inside* its own
    /// directory. Reading the wrong one shows the personal account against the
    /// work ring, so the distinction matters more than it looks.
    var accountFileURL: URL {
        slug == nil
            ? configDirectory.deletingLastPathComponent().appendingPathComponent(".claude.json")
            : configDirectory.appendingPathComponent(".claude.json")
    }

    /// As much of Claude Code's own record of the account as is read here.
    ///
    /// `fileprivate` rather than `private` so `AccountFileCache`, at the foot of
    /// this file, can hold one.
    fileprivate struct AccountFile: Decodable {
        struct Account: Decodable {
            let emailAddress: String?
            let organizationUuid: String?
            /// The account itself, as distinct from the organization it belongs
            /// to. This is the uuid the Claude desktop app files its own
            /// sessions under — see `ClaudeDesktopSessionIndex`.
            let accountUuid: String?
        }
        let oauthAccount: Account?
    }

    /// Claude Code's record of who is signed in for this profile, or nil.
    ///
    /// Readable without a keychain prompt, which is the whole point of asking
    /// here rather than of the token.
    ///
    /// Decoded at most once per version of the file — see `AccountFileCache`,
    /// which is where the reason this matters lives.
    private func account() -> AccountFile.Account? {
        AccountFileCache.shared.account(at: accountFileURL)
    }

    /// Who is signed in, read from that file.
    ///
    /// Worth having because the keychain token does not carry an address, so
    /// until now the settings row could not say *which* account a ring was for
    /// — the one question two Claude rings actually raise. It is also readable
    /// without a keychain prompt, which is the whole point of asking here.
    func signedInAddress() -> String? {
        guard let address = account()?.emailAddress, !address.isEmpty else { return nil }
        return address
    }

    /// Which Anthropic organization this profile's account belongs to.
    ///
    /// The one thing that can tie a Claude *Desktop* cache entry to a Claude
    /// *Code* profile: the cached usage URL is `/api/organizations/<uuid>/usage`,
    /// and this is the same uuid. Without it, Desktop's numbers would be handed
    /// to whichever ring asked first — the personal account's session percentage
    /// drawn on the work ring. See `ClaudeDesktopUsageCache`.
    func organizationID() -> String? {
        guard let uuid = account()?.organizationUuid, !uuid.isEmpty else { return nil }
        return uuid
    }

    /// Which Anthropic *account* this profile is signed in to.
    ///
    /// The thing that ties a session the Claude desktop app hosts back to the
    /// profile it really belongs to. The app leaves `CLAUDE_CONFIG_DIR` unset,
    /// so Claude Code files every desktop session under the default profile's
    /// `sessions` directory whichever account the app is signed in to — and the
    /// app records the truth one directory per account uuid. This is the uuid
    /// on our side of that join. See `ClaudeDesktopSessionIndex`.
    func accountID() -> String? {
        guard let uuid = account()?.accountUuid, !uuid.isEmpty else { return nil }
        return uuid
    }

    /// Every keychain service a profile's token might be filed under, in the
    /// order to prefer them — newest wins across the lot at read time.
    ///
    /// A profile's token is filed under the bare name plus a suffix: the first
    /// eight hex digits of the SHA-256 of the directory's absolute path, no
    /// trailing slash. That is Claude Code's rule, not ours. The subtlety is
    /// *when* Claude Code applies it to the default directory: it suffixes
    /// whenever `CLAUDE_CONFIG_DIR` is set in the shell it runs from, and a
    /// shell that exports the variable exports it even when it points at the
    /// default `~/.claude` — so the default profile's live token can sit under
    /// `Claude Code-credentials-<hash of ~/.claude>` rather than the bare name.
    /// Older Claude Code, and an unset variable, keep the bare name for the
    /// default. Reading only the bare name therefore finds a stale, months-old
    /// duplicate on such a machine and the ring waits for a first reading that
    /// never comes, while a current token sits one service name away.
    ///
    /// So the default profile offers both, suffixed first; a named profile is
    /// only ever written suffixed. `KeychainItem.newest(services:)` picks the
    /// most recently written item across them.
    var keychainServices: [String] {
        let suffixed = "\(Self.defaultKeychainService)-\(Self.keychainSuffix(forPath: configDirectory.path))"
        return slug == nil ? [suffixed, Self.defaultKeychainService] : [suffixed]
    }

    /// The primary service — the first candidate. Retained for callers and
    /// tests that name a single service.
    var keychainService: String { keychainServices.first! }

    static let defaultKeychainService = "Claude Code-credentials"

    static func keychainSuffix(forPath path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    // MARK: - Copy

    /// Which tool the credential is borrowed from, said so that two Claude rows
    /// in Settings can be told apart.
    var sourceName: String {
        slug == nil ? "Claude Code" : "Claude Code in \(displayPath)"
    }

    /// The command that signs this profile in, for the row that has no button.
    var signInCommand: String {
        slug == nil ? "claude" : "CLAUDE_CONFIG_DIR=\(displayPath) claude"
    }
}

/// One decode of a profile's `.claude.json`, held until the file changes.
///
/// Worth a type of its own because that file is not a small one. Claude Code
/// keeps per-project prompt history in it, so on a machine with a long history
/// it runs to tens or hundreds of megabytes — and `ClaudeProfile.account()` is
/// on the polling path: `ClaudeOAuthProvider.desktopReading()` asks for the
/// organization on every refresh, which is every sixty seconds for as long as
/// any session is busy, once per profile. Reading and decoding the whole
/// document each time to pull two strings out of it is the kind of cost that
/// does not show up on the machine it was written on and pins a core on a
/// machine with real history behind it.
///
/// The gate is the one the rest of the app already uses: modification date and
/// size, exactly as `ClaudeTranscriptReader` gates a transcript tail, resting on
/// the same fact `CredentialCache` states outright — re-reading an unchanged
/// item cannot produce a different answer. So nothing here decides when an
/// answer is *too old*, and no caller has to trust a held copy: a file that has
/// been rewritten is read again on the very next call, which is what keeps
/// switching account in Claude Code visible as quickly as it was before.
///
/// Both halves of the stamp, because a rewrite inside the same second happens —
/// and `.claude.json` is rewritten by a process that has no idea anyone is
/// watching it.
private final class AccountFileCache: @unchecked Sendable {
    static let shared = AccountFileCache()

    private struct Entry {
        let modified: Date
        let size: UInt64
        let account: ClaudeProfile.AccountFile.Account?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// The account recorded in one `.claude.json`, or nil for every way that can
    /// fail: no file, no permission, not JSON, or no `oauthAccount` in it.
    ///
    /// A nil is cached too, and deliberately. Failing to find an account is the
    /// case that costs a full decode to learn nothing, and nothing about it can
    /// change until the file does.
    func account(at url: URL,
                 fileManager: FileManager = .default) -> ClaudeProfile.AccountFile.Account? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date
        else {
            // No file at all: signed out, or never signed in. Forget whatever
            // was held rather than going on answering from a file that is gone.
            lock.lock()
            entries.removeValue(forKey: url.path)
            lock.unlock()
            return nil
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0

        lock.lock()
        let held = entries[url.path]
        lock.unlock()
        if let held, held.modified == modified, held.size == size { return held.account }

        // Decoded outside the lock. It is the slow call in here, and holding the
        // lock across it would queue every other profile behind whichever one
        // reached it first — on a machine where the decode is slow enough to
        // matter, which is the only machine this exists for.
        let account = Self.decode(url)

        lock.lock()
        // Two threads that stamped different versions can finish in either
        // order, so the entry can end up holding an older decode under a newer
        // stamp. Self-correcting: the stamps no longer match, and the next call
        // reads the file again.
        entries[url.path] = Entry(modified: modified, size: size, account: account)
        lock.unlock()
        return account
    }

    private static func decode(_ url: URL) -> ClaudeProfile.AccountFile.Account? {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(ClaudeProfile.AccountFile.self, from: data)
        else { return nil }
        return config.oauthAccount
    }
}
