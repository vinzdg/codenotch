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
    /// A third test runs last and is not about directories at all: two of them
    /// signed into the same organization are one account's one limit, and get
    /// one ring between them. See `oneRingPerOrganization`.
    ///
    /// `hasCredential` is injected so discovery stays testable — the real one
    /// reads the login keychain, which a test has no business touching. It only
    /// enumerates attributes and takes a persistent reference, neither of which
    /// needs authorization, so this costs no extra prompt per candidate.
    static func discover(home: URL = homeDirectory,
                         fileManager: FileManager = .default,
                         hasCredential: (ClaudeProfile) -> Bool = Self.hasKeychainCredential)
    -> [ClaudeProfile] {
        discoverGrouped(home: home, fileManager: fileManager, hasCredential: hasCredential)
            .map(\.profile)
    }

    /// One ring, and the directories behind it.
    ///
    /// What `discover` returns, plus the thing it has to throw away to return a
    /// flat list: which *other* directories merged into each surviving profile.
    /// Only `AppDelegate` needs that, and only for one reason — sessions. A
    /// merged directory still has Claude Code running in it, and its sessions
    /// belong to the ring that absorbed it, so they have to be watched under
    /// the surviving profile's id rather than dropped with the duplicate.
    struct Discovered: Equatable {
        let profile: ClaudeProfile
        /// Empty in the ordinary case of one directory per organization.
        let merged: [ClaudeProfile]

        /// Every directory whose sessions belong to this ring, the surviving
        /// profile's own first.
        var allProfiles: [ClaudeProfile] { [profile] + merged }
    }

    static func discoverGrouped(home: URL = homeDirectory,
                                fileManager: FileManager = .default,
                                hasCredential: (ClaudeProfile) -> Bool = Self.hasKeychainCredential)
    -> [Discovered] {
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
        return oneRingPerOrganization(
            [ClaudeProfile.default(home: home)] + extras.sorted { $0.slug! < $1.slug! },
            hasCredential: hasCredential
        )
    }

    /// One ring per organization, whatever the directories say.
    ///
    /// A limit belongs to an organization, not to the folder a login happened
    /// to be aliased to. Two directories signed into the same organization
    /// report the same numbers by construction — the Desktop cache is keyed by
    /// organization, `/usage` answers for the one the profile is on, and the
    /// token is minted for it — so the second ring is a copy of the first.
    ///
    /// That is worse than redundant. One account can front a personal
    /// organization and a Team one, and two Claude rings read as both of them
    /// covered: the organization that has no directory of its own gets no ring,
    /// and its limit goes unwatched behind a duplicate of its neighbour's. This
    /// is what turns that into a missing ring somebody can notice.
    ///
    /// Only a *readable* uuid merges. An organization that cannot be read is
    /// not evidence of anything, and treating nil as a value would collapse
    /// every unreadable profile into a single ring.
    ///
    /// Which one survives is decided twice over. A profile that still has a
    /// token outranks one that does not: signing out leaves `~/.claude.json`
    /// behind with the organization still in it, and preferring that stale
    /// default would merge a working login into a ring that can never refresh.
    /// Among equals the input order stands — the default first, then slugs
    /// alphabetically — so the surviving ring keeps the id its archived
    /// readings and connection choices are filed under, and keeps it from one
    /// launch to the next.
    private static func oneRingPerOrganization(
        _ profiles: [ClaudeProfile],
        hasCredential: (ClaudeProfile) -> Bool
    ) -> [Discovered] {
        // Read once per profile. `organizationID()` opens and decodes the
        // account file, and the comparisons below would otherwise re-read every
        // candidate they touch — and could see two different answers for one
        // profile if Claude Code rewrote the file in between, which is exactly
        // what switching organization does.
        let organizations = profiles.reduce(into: [ClaudeProfile: String]()) { seen, profile in
            seen[profile] = profile.organizationID()
        }

        var winners: [String: ClaudeProfile] = [:]
        for profile in profiles {
            guard let organization = organizations[profile] else { continue }
            guard let held = winners[organization] else {
                winners[organization] = profile
                continue
            }
            // Asked only on a collision, which is rare — and it enumerates
            // keychain attributes rather than reading a secret, so it costs no
            // prompt even when it is.
            if !hasCredential(held), hasCredential(profile) {
                winners[organization] = profile
            }
        }

        // Each loser filed under the winner that absorbed it, in the order they
        // were found, so the surviving ring's session directories keep a stable
        // order too.
        var merged: [ClaudeProfile: [ClaudeProfile]] = [:]
        for profile in profiles {
            guard let organization = organizations[profile],
                  let winner = winners[organization],
                  winner != profile
            else { continue }
            merged[winner, default: []].append(profile)
            Log.usage.notice("""
                \(profile.displayPath, privacy: .public) is signed into the same organization as \
                \(winner.displayPath, privacy: .public) (\(organization, privacy: .public)) — one ring for both
                """)
        }

        return profiles.compactMap { profile in
            guard let organization = organizations[profile] else {
                return Discovered(profile: profile, merged: [])
            }
            guard winners[organization] == profile else { return nil }
            return Discovered(profile: profile, merged: merged[profile] ?? [])
        }
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

    /// `Claude`, or `Claude (work)`. The cell draws the same glyph for every
    /// profile; this is what tells them apart in the tooltip and in Settings.
    var displayName: String { slug.map { "Claude (\($0))" } ?? "Claude" }

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
    private struct AccountFile: Decodable {
        struct Account: Decodable {
            let emailAddress: String?
            let organizationUuid: String?
        }
        let oauthAccount: Account?
    }

    /// Claude Code's record of who is signed in for this profile, or nil.
    ///
    /// Readable without a keychain prompt, which is the whole point of asking
    /// here rather than of the token.
    private func account() -> AccountFile.Account? {
        guard let data = try? Data(contentsOf: accountFileURL),
              let config = try? JSONDecoder().decode(AccountFile.self, from: data)
        else { return nil }
        return config.oauthAccount
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
