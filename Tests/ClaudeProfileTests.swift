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
    func testTheDefaultProfileIsUnchanged() throws {
        // A home that cannot be anybody's. `/Users/vinz` was standing in for a
        // synthetic one, which it is on CI and is not on the machine this was
        // written on: once `displayName` began reading `.claude.json`, the test
        // started naming the developer's own account.
        let home = try home([:])
        let profile = ClaudeProfile.default(home: home)
        XCTAssertNil(profile.slug)
        XCTAssertEqual(profile.id, "claude")
        XCTAssertEqual(profile.displayName, "Claude")
        XCTAssertEqual(profile.sessionsDirectory.path, home.appendingPathComponent(".claude/sessions").path)
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
    func testTwoProfilesAreTwoCells() throws {
        let name = "ClaudeProfileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        // Signed out, so the names come from the directories rather than from
        // whichever account happens to be signed in on this machine.
        let home = try home([:])
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

    // MARK: - Reading the account file

    /// `.claude.json` is where `signedInAddress()` and `organizationID()` come
    /// from, and on a machine with a long history it is a very large file:
    /// Claude Code keeps per-project prompt history in it. `organizationID()` is
    /// asked on every usage refresh, so decoding the document each time pinned a
    /// core. A file whose modification date and size have not moved cannot have
    /// a different answer in it, and is not read again.
    func testTheAccountFileIsNotDecodedAgainWhileItIsUnchanged() throws {
        let home = try accountHome(address: "one@example.com")
        let profile = ClaudeProfile.default(home: home)
        XCTAssertEqual(profile.signedInAddress(), "one@example.com")

        // Same length, same stamp, different contents. Nothing outside a test
        // can produce that; it is how this asks "did you read it again?"
        // without reaching inside the cache.
        try rewrite(home, address: "two@example.com", keepingItsStamp: true)

        XCTAssertEqual(profile.signedInAddress(), "one@example.com",
                       "the file was decoded a second time")
    }

    /// The other half, and the one that matters for correctness: switching
    /// account in Claude Code rewrites this file, and the ring has to follow it.
    /// Nothing is held past the version it was read from.
    func testAChangedAccountFileIsDecodedAgain() throws {
        let home = try accountHome(address: "one@example.com", organization: "org-one")
        let profile = ClaudeProfile.default(home: home)
        XCTAssertEqual(profile.signedInAddress(), "one@example.com")
        XCTAssertEqual(profile.organizationID(), "org-one")

        try rewrite(home, address: "two@example.com", organization: "org-two",
                    modified: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertEqual(profile.signedInAddress(), "two@example.com")
        XCTAssertEqual(profile.organizationID(), "org-two")
    }

    /// Signing out removes the file. The held answer goes with it rather than
    /// outliving the account it described.
    func testAnAccountFileThatGoesAwayIsNotStillAnswered() throws {
        let home = try accountHome(address: "one@example.com")
        let profile = ClaudeProfile.default(home: home)
        XCTAssertEqual(profile.signedInAddress(), "one@example.com")

        try FileManager.default.removeItem(at: home.appendingPathComponent(".claude.json"))

        XCTAssertNil(profile.signedInAddress())
        XCTAssertNil(profile.organizationID())
    }

    /// A home directory with `.claude/` and a `.claude.json` beside it, as the
    /// default profile expects them.
    private func accountHome(address: String,
                             organization: String = "org-one") throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeProfileTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"),
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        try rewrite(home, address: address, organization: organization,
                    modified: Date(timeIntervalSince1970: 1_700_000_000))
        return home
    }

    /// Writes `.claude.json` and then sets its modification date — to the one
    /// given, or back to the one the file already had, which is what makes a
    /// rewrite invisible to the stamp.
    ///
    /// Every address passed here is fifteen characters and every organization
    /// seven, so the file is the same length whatever is in it and the stamp is
    /// the only thing that can differ between two of them.
    private func rewrite(_ home: URL,
                         address: String,
                         organization: String = "org-one",
                         modified: Date? = nil,
                         keepingItsStamp: Bool = false) throws {
        let url = home.appendingPathComponent(".claude.json")

        var stamp = modified
        if keepingItsStamp {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            stamp = attributes[.modificationDate] as? Date
        }

        let json = #"{"oauthAccount":{"emailAddress":"\#(address)","organizationUuid":"\#(organization)"}}"#
        try Data(json.utf8).write(to: url)

        if let stamp {
            try FileManager.default.setAttributes([.modificationDate: stamp],
                                                  ofItemAtPath: url.path)
        }
    }
}


/// A Claude ring named after the account it is for, rather than after the
/// directory that account happens to live in.
///
/// The directory could never answer the question two rings raise. The default
/// profile is always `~/.claude`, so the account most people use every day was
/// the one ring with no name on it at all — just "Claude" — and a second login
/// was named for its folder, `Claude (work)`, whoever was actually signed in to
/// it. The address Claude Code already writes into `.claude.json` is the real
/// answer, and reading it costs no keychain prompt.
final class ClaudeAccountNameTests: XCTestCase {

    // MARK: - The label itself

    func testTheDomainNamesTheAccount() {
        XCTAssertEqual(ClaudeProfile.accountLabel(forAddress: "someone@gmail.com"), "Gmail")
        XCTAssertEqual(ClaudeProfile.accountLabel(forAddress: "someone@hotmail.com"), "Hotmail")
        XCTAssertEqual(ClaudeProfile.accountLabel(forAddress: "vinz@acme.co.uk"), "Acme")
    }

    /// The local part is the same word on every account one person owns; the
    /// domain is what tells a personal login from a work one.
    func testTheLocalPartIsNotTheLabel() {
        XCTAssertEqual(ClaudeProfile.accountLabel(forAddress: "gmail@acme.com"), "Acme")
    }

    /// An address with more than one `@` is not ours to reject — take the last
    /// one, as every mail system does.
    func testTheLastAtWins() {
        XCTAssertEqual(ClaudeProfile.accountLabel(forAddress: "a@b@acme.com"), "Acme")
    }

    /// Capitalisation only, never a rewrite: a domain written in caps stays
    /// readable rather than being lowercased into something it is not.
    func testOnlyTheFirstLetterIsTouched() {
        XCTAssertEqual(ClaudeProfile.accountLabel(forAddress: "someone@IBM.com"), "IBM")
        XCTAssertEqual(ClaudeProfile.accountLabel(forAddress: "someone@McMail.com"), "McMail")
    }

    /// Every way there is no label to give. `Claude` alone beats `Claude 1`.
    func testNoLabelRatherThanANonsenseOne() {
        XCTAssertNil(ClaudeProfile.accountLabel(forAddress: nil))
        XCTAssertNil(ClaudeProfile.accountLabel(forAddress: ""))
        XCTAssertNil(ClaudeProfile.accountLabel(forAddress: "no-at-sign"))
        XCTAssertNil(ClaudeProfile.accountLabel(forAddress: "someone@"))
        XCTAssertNil(ClaudeProfile.accountLabel(forAddress: "someone@.com"))
        XCTAssertNil(ClaudeProfile.accountLabel(forAddress: "someone@123.45"))
    }

    // MARK: - The name a ring is drawn with

    func testTheDefaultProfileIsNamedForItsAccount() throws {
        let home = try home(default: "paulo@gmail.com")
        XCTAssertEqual(ClaudeProfile.default(home: home).displayName, "Claude Gmail")
    }

    func testANamedProfileIsNamedForItsAccountToo() throws {
        let home = try home(default: "paulo@gmail.com", work: "paulo@hotmail.com")
        XCTAssertEqual(profile(slug: "work", in: home).displayName, "Claude Hotmail")
    }

    /// The old spelling is the fallback, not a thing of the past: a profile
    /// signed out, or one Claude Code has not written `.claude.json` for yet,
    /// still has to be called something.
    func testWithoutAnAccountFileTheDirectoryStillNamesIt() throws {
        let home = try home()
        XCTAssertEqual(ClaudeProfile.default(home: home).displayName, "Claude")
        XCTAssertEqual(profile(slug: "work", in: home).displayName, "Claude (work)")
    }

    // MARK: - One account, with nothing to tell it from

    /// The label tells rings apart. A machine with one Claude account has one
    /// ring, and `Claude Gmail Usage` over the only Claude card named a product
    /// that does not exist.
    func testALoneAccountIsJustClaude() throws {
        let home = try home(default: "paulo@gmail.com")
        let profiles = [ClaudeProfile.default(home: home)]

        let names = ClaudeProfile.displayNames(for: profiles)

        XCTAssertEqual(names, ["claude": "Claude"])
    }

    // MARK: - Two accounts that would be called the same thing

    /// Two gmail logins would both derive `Claude Gmail`, which is worse than
    /// the directory names this replaced. Only a caller holding every profile
    /// can see the clash, so only it can settle it.
    func testTwoAccountsOnOneProviderFallBackToTheAddress() throws {
        let home = try home(default: "paulo@gmail.com", work: "eureka@gmail.com")
        let profiles = [ClaudeProfile.default(home: home), profile(slug: "work", in: home)]

        let names = ClaudeProfile.displayNames(for: profiles)

        XCTAssertEqual(names["claude"], "Claude paulo@gmail.com")
        XCTAssertEqual(names["claude-work"], "Claude eureka@gmail.com")
    }

    /// And the profiles that do not clash keep the short name — nobody pays
    /// for somebody else's collision.
    func testDistinctAccountsKeepTheShortName() throws {
        let home = try home(default: "paulo@gmail.com", work: "paulo@hotmail.com")
        let profiles = [ClaudeProfile.default(home: home), profile(slug: "work", in: home)]

        let names = ClaudeProfile.displayNames(for: profiles)

        XCTAssertEqual(names["claude"], "Claude Gmail")
        XCTAssertEqual(names["claude-work"], "Claude Hotmail")
    }

    /// A clash between two profiles that have no address to fall back to — two
    /// directories called the same thing cannot happen, so this only asks that
    /// nothing is dropped.
    func testEveryProfileIsNamedEvenWithNothingToReadFrom() throws {
        let home = try home()
        let profiles = [ClaudeProfile.default(home: home), profile(slug: "work", in: home)]

        let names = ClaudeProfile.displayNames(for: profiles)

        XCTAssertEqual(names.count, 2)
        XCTAssertEqual(names["claude"], "Claude")
        XCTAssertEqual(names["claude-work"], "Claude (work)")
    }

    // MARK: -

    /// A home with `~/.claude`, `~/.claude-work`, and an account file for
    /// whichever of them was given an address. The default profile's file sits
    /// *beside* its directory and a named profile's sits *inside* it, which is
    /// Claude Code's own rule — see `ClaudeProfile.accountFileURL`.
    private func home(default defaultAddress: String? = nil,
                      work workAddress: String? = nil) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeAccountNameTests.\(UUID().uuidString)",
                                    isDirectory: true)
        for directory in [".claude", ".claude-work"] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }

        if let defaultAddress {
            try write(defaultAddress, to: home.appendingPathComponent(".claude.json"))
        }
        if let workAddress {
            try write(workAddress, to: home.appendingPathComponent(".claude-work/.claude.json"))
        }
        return home
    }

    private func profile(slug: String, in home: URL) -> ClaudeProfile {
        ClaudeProfile(slug: slug,
                      configDirectory: home.appendingPathComponent(".claude-\(slug)"))
    }

    private func write(_ address: String, to url: URL) throws {
        let json = #"{"oauthAccount":{"emailAddress":"\#(address)","organizationUuid":"org"}}"#
        try Data(json.utf8).write(to: url)
    }
}
