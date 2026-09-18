import XCTest
@testable import Codenotch

/// A second Claude Code login kept under `~/.claude-<slug>` is its own account,
/// with its own token, its own limits and its own sessions. Reading only
/// `~/.claude` showed one of them and was blind to the rest.
final class ClaudeProfileTests: XCTestCase {
    private func home(_ layout: [String: [String]]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeProfileTests.\(UUID().uuidString)")
        for (directory, files) in layout {
            let url = root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for file in files {
                FileManager.default.createFile(atPath: url.appendingPathComponent(file).path,
                                               contents: Data())
            }
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// Discovery asks whether Claude Code ever filed a token for the directory.
    /// Every test below that is about the *filename* rules says yes, so the two
    /// conditions stay separately testable.
    private let signedIn: (ClaudeProfile) -> Bool = { _ in true }

    /// Nothing in the home directory has a token.
    private let signedOut: (ClaudeProfile) -> Bool = { _ in false }

    // MARK: - Identity

    /// The default keeps the id it has always had, so archived readings and
    /// connection choices survive the update.
    func testTheDefaultProfileIsUnchanged() {
        let profile = ClaudeProfile.default(home: URL(fileURLWithPath: "/Users/vinz"))
        XCTAssertNil(profile.slug)
        XCTAssertEqual(profile.id, "claude")
        XCTAssertEqual(profile.displayName, "Claude")
        XCTAssertEqual(profile.sessionsDirectory.path, "/Users/vinz/.claude/sessions")
        XCTAssertEqual(profile.sourceName, "Claude Code")
        XCTAssertEqual(profile.signInCommand, "claude")
    }

    func testAProfileIsNamedAfterItsSlug() {
        let profile = ClaudeProfile(slug: "work",
                                    configDirectory: URL(fileURLWithPath: "/Users/vinz/.claude-work"))
        XCTAssertEqual(profile.id, "claude-work")
        XCTAssertEqual(profile.displayName, "Claude (work)")
        XCTAssertEqual(profile.sessionsDirectory.path, "/Users/vinz/.claude-work/sessions")
    }

    /// Claude Code files a non-default profile's token under the service name
    /// plus the first eight hex digits of the SHA-256 of the directory path.
    /// Getting this wrong means "sign in" on a ring for an account that is
    /// signed in.
    func testTheKeychainServiceCarriesClaudeCodesHashOfThePath() {
        let profile = ClaudeProfile(slug: "work",
                                    configDirectory: URL(fileURLWithPath: "/Users/vinz/.claude-work"))
        // `shasum -a 256` of the path, no trailing slash, no newline.
        XCTAssertEqual(profile.keychainService, "Claude Code-credentials-19914660")
    }

    /// The path is hashed as Claude Code sees it, and Claude Code does not see
    /// a trailing slash.
    func testATrailingSlashDoesNotChangeTheHash() {
        let slashed = ClaudeProfile(slug: "work",
                                    configDirectory: URL(fileURLWithPath: "/Users/vinz/.claude-work/"))
        XCTAssertEqual(slashed.keychainService, "Claude Code-credentials-19914660")
    }

    /// The default profile offers both service names — the suffix Claude Code
    /// uses when `CLAUDE_CONFIG_DIR` is exported (even at the default path) and
    /// the bare name older versions use — suffixed first so a current token
    /// wins, bare kept so a legacy login still reads. Reading only the bare
    /// name is what left the ring stuck on "Waiting for the first reading…".
    func testTheDefaultProfileOffersBothTheSuffixedAndBareServices() {
        let profile = ClaudeProfile.default(home: URL(fileURLWithPath: "/Users/vinz"))
        // `shasum -a 256` of "/Users/vinz/.claude", first eight hex digits.
        XCTAssertEqual(profile.keychainServices,
                       ["Claude Code-credentials-337ba600", "Claude Code-credentials"])
    }

    /// A named profile is only ever written suffixed, so it offers exactly the
    /// one service — no bare fallback that could shadow another account.
    func testANamedProfileOffersOnlyItsSuffixedService() {
        let profile = ClaudeProfile(slug: "work",
                                    configDirectory: URL(fileURLWithPath: "/Users/vinz/.claude-work"))
        XCTAssertEqual(profile.keychainServices, ["Claude Code-credentials-19914660"])
    }

    func testProviderIDsAreRecognised() {
        XCTAssertTrue(ClaudeProfile.isClaude(providerID: "claude"))
        XCTAssertTrue(ClaudeProfile.isClaude(providerID: "claude-work"))
        XCTAssertFalse(ClaudeProfile.isClaude(providerID: "claudex"))
        XCTAssertFalse(ClaudeProfile.isClaude(providerID: "cursor"))
        XCTAssertEqual(ClaudeProfile.slug(fromProviderID: "claude-work"), "work")
        XCTAssertNil(ClaudeProfile.slug(fromProviderID: "claude"))
        XCTAssertNil(ClaudeProfile.slug(fromProviderID: "claude-"))
    }

    // MARK: - Discovery

    func testDirectoryNamesAreParsedStrictly() {
        XCTAssertEqual(ClaudeProfile.slug(fromDirectoryName: ".claude-work"), "work")
        XCTAssertEqual(ClaudeProfile.slug(fromDirectoryName: ".claude-client-a"), "client-a")
        XCTAssertNil(ClaudeProfile.slug(fromDirectoryName: ".claude"), "the default is not a slug")
        XCTAssertNil(ClaudeProfile.slug(fromDirectoryName: ".claude-"), "an empty slug is no profile")
        XCTAssertNil(ClaudeProfile.slug(fromDirectoryName: ".claude.json"), "a file beside the default")
        XCTAssertNil(ClaudeProfile.slug(fromDirectoryName: ".claudette"))
        XCTAssertNil(ClaudeProfile.slug(fromDirectoryName: "claude-work"), "not hidden, not ours")
    }

    /// The default comes first, then the rest by slug, so the rings keep their
    /// places from one launch to the next.
    func testDiscoveryFindsEveryUsedProfileInAStableOrder() throws {
        let home = try home([
            ".claude": ["settings.json"],
            ".claude-work": ["settings.json"],
            ".claude-alpha": ["history.jsonl"]
        ])
        let found = ClaudeProfile.discover(home: home, hasCredential: signedIn)
        XCTAssertEqual(found.map(\.id), ["claude", "claude-alpha", "claude-work"])
        XCTAssertEqual(found[2].configDirectory.path, home.appendingPathComponent(".claude-work").path)
    }

    /// An empty directory is not a profile: a permanent "sign in" ring for an
    /// account that does not exist is worse than no ring.
    func testDirectoriesClaudeCodeHasNeverUsedAreIgnored() throws {
        let home = try home([
            ".claude": ["settings.json"],
            ".claude-empty": [],
            ".claude-notes": ["README.md"]
        ])
        XCTAssertEqual(ClaudeProfile.discover(home: home, hasCredential: signedIn).map(\.id), ["claude"])
    }

    /// Any one of the files Claude Code writes on first run is enough — they
    /// are not all present on every version.
    func testAnyFirstRunMarkerCounts() throws {
        let home = try home([
            ".claude-a": ["sessions"],
            ".claude-b": ["projects"],
            ".claude-c": [".claude.json"]
        ])
        XCTAssertEqual(ClaudeProfile.discover(home: home, hasCredential: signedIn).map(\.id),
                       ["claude", "claude-a", "claude-b", "claude-c"])
    }

    /// A file named like a profile is not one, and must not crash discovery.
    func testAFileNamedLikeAProfileIsIgnored() throws {
        let home = try home([".claude": ["settings.json"]])
        FileManager.default.createFile(atPath: home.appendingPathComponent(".claude-work").path,
                                       contents: Data("not a directory".utf8))
        XCTAssertEqual(ClaudeProfile.discover(home: home, hasCredential: signedIn).map(\.id), ["claude"])
    }

    /// `~/.claude` has always been read whether or not it exists yet, and a
    /// fresh Mac with no Claude Code still gets the ring that says so.
    func testTheDefaultIsAlwaysPresent() throws {
        let home = try home([:])
        XCTAssertEqual(ClaudeProfile.discover(home: home, hasCredential: signedIn).map(\.id), ["claude"])
    }

    /// A plugin is not an account. `claude-mem` keeps its state in
    /// `~/.claude-mem` and writes the same first-run names Claude Code does,
    /// so the filename rules pass it and it drew a permanent "sign in to
    /// ~/.claude-mem" ring for a limit that does not exist. No token under the
    /// directory's own service name, no ring.
    func testADirectoryWithNoTokenIsNotAnAccount() throws {
        let home = try home([
            ".claude": ["settings.json"],
            ".claude-mem": ["sessions", "settings.json"]
        ])
        XCTAssertEqual(ClaudeProfile.discover(home: home, hasCredential: signedOut).map(\.id),
                       ["claude"])
        XCTAssertEqual(ClaudeProfile.discover(home: home, hasCredential: signedIn).map(\.id),
                       ["claude", "claude-mem"],
                       "the filename rules are unchanged — only the credential decides")
    }

    /// The default is read whether or not it has a token: it is the one ring
    /// that has always been there to say "sign in".
    func testTheDefaultSurvivesHavingNoToken() throws {
        let home = try home([".claude": ["settings.json"]])
        XCTAssertEqual(ClaudeProfile.discover(home: home, hasCredential: signedOut).map(\.id),
                       ["claude"])
    }

    // MARK: - One ring per organization

    /// Stand-ins for the two organizations one login can front. Any non-empty
    /// string does: `organizationID()` hands back the uuid Claude Code wrote
    /// and nothing here parses it. Synthetic on purpose, so the fixtures carry
    /// nobody's real organization.
    private let teamOrganization = "11111111-2222-4333-8444-555555555555"
    private let personalOrganization = "66666666-7777-4888-8999-000000000000"

    /// Writes Claude Code's account record for a profile that discovery has not
    /// produced yet, at the path `accountFileURL` will look for it: beside the
    /// directory for the default, inside it for a named one.
    private func writeAccount(organization: String, in home: URL, slug: String?) throws {
        let profile = slug.map {
            ClaudeProfile(slug: $0,
                          configDirectory: home.appendingPathComponent(".claude-\($0)"))
        } ?? .default(home: home)
        let url = profile.accountFileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try #"{"oauthAccount":{"organizationUuid":"\#(organization)"}}"#
            .write(to: url, atomically: true, encoding: .utf8)
    }

    /// The unit a limit belongs to is the organization, not the folder somebody
    /// aliased a login to. Two directories signed into one organization report
    /// the same numbers by construction — drawing both spends a ring on a
    /// duplicate and, worse, lets a person read two rings as two accounts
    /// covered when a third organization has no ring at all.
    func testTwoDirectoriesOnOneOrganizationAreOneRing() throws {
        let home = try home([
            ".claude": ["settings.json"],
            ".claude-vcore": ["settings.json"]
        ])
        try writeAccount(organization: teamOrganization, in: home, slug: nil)
        try writeAccount(organization: teamOrganization, in: home, slug: "vcore")
        XCTAssertEqual(ClaudeProfile.discover(home: home, hasCredential: signedIn).map(\.id),
                       ["claude"])
    }

    /// The default is the one that survives a collision. Its id is the one
    /// archived readings, connection choices and hover-band keys are filed
    /// under, and a merge that dropped it would orphan all three.
    func testACollisionKeepsTheDefaultsID() throws {
        let home = try home([
            ".claude": ["settings.json"],
            ".claude-aaa": ["settings.json"]
        ])
        try writeAccount(organization: teamOrganization, in: home, slug: nil)
        try writeAccount(organization: teamOrganization, in: home, slug: "aaa")
        let found = try XCTUnwrap(ClaudeProfile.discover(home: home, hasCredential: signedIn).first)
        XCTAssertNil(found.slug, "the default outranks a slug that sorts before it")
        XCTAssertEqual(found.id, "claude")
    }

    /// Between two named directories the earlier slug wins, so the surviving
    /// ring does not swap places — and so its id — between launches.
    func testTwoNamedDirectoriesOnOneOrganizationKeepTheEarlierSlug() throws {
        let home = try home([
            ".claude-work": ["settings.json"],
            ".claude-alpha": ["settings.json"]
        ])
        try writeAccount(organization: personalOrganization, in: home, slug: "work")
        try writeAccount(organization: personalOrganization, in: home, slug: "alpha")
        XCTAssertEqual(ClaudeProfile.discover(home: home, hasCredential: signedIn).map(\.id),
                       ["claude", "claude-alpha"])
    }

    /// The point of the whole thing: one login fronting a personal organization
    /// and a Team one is two sets of limits, and they get a ring each.
    func testDifferentOrganizationsAreDifferentRings() throws {
        let home = try home([
            ".claude": ["settings.json"],
            ".claude-vcore": ["settings.json"]
        ])
        try writeAccount(organization: personalOrganization, in: home, slug: nil)
        try writeAccount(organization: teamOrganization, in: home, slug: "vcore")
        XCTAssertEqual(ClaudeProfile.discover(home: home, hasCredential: signedIn).map(\.id),
                       ["claude", "claude-vcore"])
    }

    /// An organization that cannot be read is not evidence of a collision.
    /// Merging on a missing uuid would silently drop a real account whose
    /// Claude Code is too old to record one, so an unreadable organization
    /// merges with nothing — not even with another unreadable one.
    func testProfilesWithNoReadableOrganizationAreNeverMerged() throws {
        let home = try home([
            ".claude": ["settings.json"],
            ".claude-a": ["settings.json"],
            ".claude-b": ["settings.json"]
        ])
        XCTAssertEqual(ClaudeProfile.discover(home: home, hasCredential: signedIn).map(\.id),
                       ["claude", "claude-a", "claude-b"])
    }

    /// A readable organization and an unreadable one are two rings: nothing
    /// says they are the same account.
    func testAnUnreadableOrganizationDoesNotMergeIntoAReadableOne() throws {
        let home = try home([
            ".claude": ["settings.json"],
            ".claude-vcore": ["settings.json"]
        ])
        try writeAccount(organization: teamOrganization, in: home, slug: nil)
        XCTAssertEqual(ClaudeProfile.discover(home: home, hasCredential: signedIn).map(\.id),
                       ["claude", "claude-vcore"])
    }

    /// The default's account file can outlive its token: signing out leaves
    /// `~/.claude.json` behind with the organization still in it. Preferring it
    /// there would merge a working login into a dead one and leave a ring that
    /// can never refresh, so a profile that can actually fetch outranks the
    /// default's id stability — which is worth nothing on a ring with no token.
    func testACollisionPrefersTheProfileThatCanStillFetch() throws {
        let home = try home([
            ".claude": ["settings.json"],
            ".claude-vcore": ["settings.json"]
        ])
        try writeAccount(organization: teamOrganization, in: home, slug: nil)
        try writeAccount(organization: teamOrganization, in: home, slug: "vcore")
        let onlyVCore: (ClaudeProfile) -> Bool = { $0.slug == "vcore" }
        XCTAssertEqual(ClaudeProfile.discover(home: home, hasCredential: onlyVCore).map(\.id),
                       ["claude-vcore"])
    }

    /// The merge cannot simply forget the directory it dropped: Claude Code is
    /// still running in it, and those sessions are the surviving ring's — the
    /// two are the same organization. `AppDelegate` watches every directory in
    /// the group and registers them under the one id.
    func testAMergedDirectoryIsKeptForItsSessions() throws {
        let home = try home([
            ".claude": ["settings.json"],
            ".claude-vcore": ["settings.json"]
        ])
        try writeAccount(organization: teamOrganization, in: home, slug: nil)
        try writeAccount(organization: teamOrganization, in: home, slug: "vcore")
        let groups = ClaudeProfile.discoverGrouped(home: home, hasCredential: signedIn)
        XCTAssertEqual(groups.map(\.profile.id), ["claude"])
        XCTAssertEqual(groups.first?.merged.map(\.id), ["claude-vcore"])
        XCTAssertEqual(groups.first?.allProfiles.map(\.sessionsDirectory.path),
                       [home.appendingPathComponent(".claude/sessions").path,
                        home.appendingPathComponent(".claude-vcore/sessions").path])
    }

    /// A ring with no duplicate behind it carries no extra directories, so the
    /// ordinary install keeps exactly the one monitor it always had.
    func testARingWithNoDuplicateCarriesNothingExtra() throws {
        let home = try home([
            ".claude": ["settings.json"],
            ".claude-vcore": ["settings.json"]
        ])
        try writeAccount(organization: personalOrganization, in: home, slug: nil)
        try writeAccount(organization: teamOrganization, in: home, slug: "vcore")
        let groups = ClaudeProfile.discoverGrouped(home: home, hasCredential: signedIn)
        XCTAssertEqual(groups.map(\.profile.id), ["claude", "claude-vcore"])
        XCTAssertEqual(groups.map(\.merged.count), [0, 0])
    }

    /// Three directories on one organization collapse to one ring that still
    /// watches all three.
    func testEveryDuplicateIsKeptForItsSessions() throws {
        let home = try home([
            ".claude": ["settings.json"],
            ".claude-a": ["settings.json"],
            ".claude-b": ["settings.json"]
        ])
        for slug in [nil, "a", "b"] as [String?] {
            try writeAccount(organization: teamOrganization, in: home, slug: slug)
        }
        let groups = ClaudeProfile.discoverGrouped(home: home, hasCredential: signedIn)
        XCTAssertEqual(groups.map(\.profile.id), ["claude"])
        XCTAssertEqual(groups.first?.merged.map(\.id), ["claude-a", "claude-b"])
    }

    // MARK: - What the rest of the app derives from the id

    /// The tooltip's sign-in prompt has to name the directory, because plain
    /// `claude` signs the default profile in, not this one.
    func testTheSignInPromptNamesTheDirectory() {
        let snapshot = ProviderSnapshot(
            id: "claude-work", displayName: "Claude (work)", glyph: .claude,
            fidelity: .official, status: .needsAuth, windows: []
        )
        XCTAssertEqual(snapshot.statusMessage,
                       "Sign in to Claude Code in ~/.claude-work to read your usage")
    }

    /// Every profile's token is a keychain item, so every profile can be
    /// refused and needs the "Allow access…" button.
    func testEveryProfileUsesTheKeychain() {
        let summary = ProviderSummary(id: "claude-work", name: "Claude (work)", glyph: .claude,
                                      account: nil, signIn: .guidance("x"))
        XCTAssertTrue(summary.usesKeychain)
    }

    /// The rate limit is per account. A penalty on the work profile must not
    /// hold the personal one back, and the default keeps its old key so a
    /// penalty in progress survives the update.
    func testBackoffIsRememberedPerProfile() throws {
        let name = "ClaudeProfileTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        let archive = UsageArchive(defaults: defaults)

        let until = Date().addingTimeInterval(300)
        archive.saveBackoffUntil(until, providerID: "claude-work")
        XCTAssertNil(archive.loadBackoffUntil(providerID: "claude"))
        XCTAssertNil(archive.loadBackoffUntil(), "the no-argument form is the default profile")
        XCTAssertNotNil(archive.loadBackoffUntil(providerID: "claude-work"))

        archive.saveBackoffUntil(until)
        XCTAssertNotNil(defaults.object(forKey: "backoffUntil"), "the default's key is unchanged")
        archive.saveBackoffUntil(nil, providerID: "claude-work")
        XCTAssertNil(archive.loadBackoffUntil(providerID: "claude-work"))
        XCTAssertNotNil(archive.loadBackoffUntil(providerID: "claude"))
    }

    /// Stands in for the keychain so the test below cannot reach it.
    ///
    /// Two profiles on a fictional `/Users/vinz` still resolve to the *real*
    /// service name for the default one, so building them for real used to read
    /// the login keychain — and on a test host rebuilt with a fresh ad-hoc
    /// signature that means an authorization prompt, which hung the entire
    /// suite on `providerSummaries`. What the test is about is naming and
    /// ordering; the credential has nothing to do with it.
    private static let noCredential: @Sendable () throws -> ClaudeCredentials = {
        throw UsageProviderError.needsAuth
    }

    /// Two providers, one id each, both drawn: the store has no idea they are
    /// the same tool and must not collapse them.
    @MainActor
    func testTwoProfilesAreTwoCells() {
        let name = "ClaudeProfileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let home = URL(fileURLWithPath: "/Users/vinz")
        let store = UsageStore(
            providers: [
                // `cli: nil` throughout: this is about two profiles being two
                // cells, and finding the machine's own Claude Code would make
                // it about what the developer has installed. `noCredential`
                // for the same reason on the other side — neither the CLI nor
                // the keychain gets to decide what this test sees.
                ClaudeOAuthProvider(profile: .default(home: home),
                                    archive: UsageArchive(defaults: defaults),
                                    loadCredentials: Self.noCredential,
                                    cli: nil),
                ClaudeOAuthProvider(profile: ClaudeProfile(slug: "work",
                                                           configDirectory: home.appendingPathComponent(".claude-work")),
                                    archive: UsageArchive(defaults: defaults),
                                    loadCredentials: Self.noCredential,
                                    cli: nil)
            ],
            archive: UsageArchive(defaults: defaults)
        )
        XCTAssertEqual(store.snapshots.map(\.id), ["claude", "claude-work"])
        XCTAssertEqual(store.snapshots.map(\.displayName), ["Claude", "Claude (work)"])
        XCTAssertEqual(store.providerSummaries.map(\.name), ["Claude", "Claude (work)"])
    }
}
