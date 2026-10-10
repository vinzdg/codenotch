import XCTest
@testable import Codenotch

/// The token path of `ClaudeOAuthProvider`.
///
/// It had no tests at all — only the pure helpers (`backoff`, `retryAfter`) were
/// covered — which is how a back-off that re-stamped itself on every failed tick
/// shipped and locked the provider until the app was restarted.
///
/// Every assertion here is about one question: **after a failure, does the next
/// tick actually go and ask again?** Hence the counters. Asserting on the returned
/// error is not enough — the broken version returned exactly the right error while
/// never touching the keychain or the network.
final class ClaudeOAuthProviderTests: XCTestCase {

    // MARK: - Back-off against the refresh tick

    /// A window that opens in 15ms is open. Refusing it does not delay the
    /// fetch by 15ms — the caller is a timer, so it delays it by a whole
    /// refresh interval, and the server's 60s penalty becomes 120s.
    func testAWindowAboutToOpenCountsAsOpen() {
        let now = Date()
        XCTAssertFalse(ClaudeOAuthProvider.shouldHoldOff(
            until: now.addingTimeInterval(0.015), slack: 1, now: now))
        XCTAssertFalse(ClaudeOAuthProvider.shouldHoldOff(
            until: now.addingTimeInterval(0.42), slack: 1, now: now))
    }

    func testARealPenaltyIsStillHonoured() {
        let now = Date()
        XCTAssertTrue(ClaudeOAuthProvider.shouldHoldOff(
            until: now.addingTimeInterval(45), slack: 1, now: now))
    }

    func testNoPenaltyMeansNoHoldOff() {
        XCTAssertFalse(ClaudeOAuthProvider.shouldHoldOff(until: nil, slack: 1))
    }

    override func tearDown() {
        StubEndpoint.reset([])
        super.tearDown()
    }

    /// A 401 must not stop the next tick from trying.
    ///
    /// The endpoint rejects the token and then starts answering again — a token
    /// rotated behind the app's back. This is the manual repro (a local server
    /// switched from 401 to 200) reduced to a test.
    func testA401DoesNotStopTheNextTickFromTrying() async throws {
        StubEndpoint.reset([
            .init(status: 401),                       // the tick's first attempt
            .init(status: 401),                       // its one retry on unauthorized
            .init(status: 200, body: Self.usagePayload)
        ])
        let source = CredentialSource(readable: true)
        let provider = makeProvider(source: source)

        await assertNeedsAuth(from: provider)
        XCTAssertEqual(StubEndpoint.requestCount, 2, "the retry on 401 did not happen")

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(StubEndpoint.requestCount, 3,
                       "the next tick never reached the endpoint")
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.windows.first?.id, "session")
    }

    /// A keychain read that failed must not stop the next tick from reading again.
    ///
    /// This is what happened in the field: the Mac was in dark wake, the keychain
    /// answered `-25320` ("no UI possible"), and that fell through to `needsAuth`.
    /// The credential was readable again seconds later; the provider never looked.
    func testAKeychainFailureDoesNotStopTheNextTickFromReading() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
        let source = CredentialSource(readable: false)
        let provider = makeProvider(source: source)

        await assertNeedsAuth(from: provider)
        XCTAssertEqual(source.reads, 1)
        XCTAssertEqual(StubEndpoint.requestCount, 0,
                       "it went to the network without a token")

        source.makeReadable()   // the machine woke up

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(source.reads, 2, "the next tick never went back to the keychain")
        XCTAssertEqual(snapshot.status, .ok)
    }

    /// Failing repeatedly must not become failing silently.
    ///
    /// The bug's signature was a request count frozen at two while the poll kept
    /// firing every 60 seconds. Three ticks against a rejecting endpoint have to
    /// produce three attempts, not one.
    func testItKeepsAskingWhileTheEndpointKeepsRejecting() async {
        StubEndpoint.reset(Array(repeating: .init(status: 401), count: 6))
        let provider = makeProvider(source: CredentialSource(readable: true))

        for _ in 0..<3 { await assertNeedsAuth(from: provider) }

        XCTAssertEqual(StubEndpoint.requestCount, 6,
                       "the provider stopped asking after the first failure")
    }

    func testEndpointReusesWithinEveryFreshnessFloor() async throws {
        for freshness: UsageFreshness in [.standard, .live, .fromSource] {
            StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
            let provider = makeProvider(source: CredentialSource(readable: true),
                                        endpointIntervals: (300, 120))
            for _ in 0..<10 {
                let snapshot = try await provider.fetchSnapshot(freshness: freshness)
                XCTAssertEqual(snapshot.usedFraction, 0.42)
            }
            XCTAssertEqual(StubEndpoint.requestCount, 1)
            let url = try XCTUnwrap(StubEndpoint.requestURLs.first)
            XCTAssertEqual(url.path, "/api/oauth/usage")
            XCTAssertNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        }
    }

    func testLiveEndpointFloorCanBeShorterThanStandard() async throws {
        StubEndpoint.reset(Array(repeating: .init(status: 200, body: Self.usagePayload), count: 2))
        let provider = makeProvider(source: CredentialSource(readable: true), endpointIntervals: (300, 0))
        _ = try await provider.fetchSnapshot()
        _ = try await provider.fetchSnapshot()
        XCTAssertEqual(StubEndpoint.requestCount, 1)
        _ = try await provider.fetchSnapshot(freshness: .live)
        XCTAssertEqual(StubEndpoint.requestCount, 2)
    }

    func testExpiredEndpointWindowIsNotReused() async throws {
        let expired = Data(#"{"limits":[{"kind":"session","percent":80,"resets_at":"2000-01-01T00:00:00Z"}]}"#.utf8)
        StubEndpoint.reset([.init(status: 200, body: expired), .init(status: 200, body: Self.usagePayload)])
        let provider = makeProvider(source: CredentialSource(readable: true), endpointIntervals: (300, 120))
        _ = try await provider.fetchSnapshot()
        let next = try await provider.fetchSnapshot()
        XCTAssertEqual(next.usedFraction, 0.42)
        XCTAssertEqual(StubEndpoint.requestCount, 2)
    }

    func testAskingForPermissionReadsCredentialsButDoesNotBypassEndpointFloor() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
        let source = CredentialSource(readable: true)
        let provider = makeProvider(source: source, endpointIntervals: (300, 120))
        _ = try await provider.fetchSnapshot()
        provider.forgetCachedCredential()
        _ = try await provider.fetchSnapshot(freshness: .fromSource)
        XCTAssertEqual(source.reads, 2)
        XCTAssertEqual(StubEndpoint.requestCount, 1)
    }

    func testChangedTokenDoesNotReusePreviousAccountReading() async throws {
        StubEndpoint.reset(Array(repeating: .init(status: 200, body: Self.usagePayload), count: 2))
        let source = CredentialSource(readable: true)
        let provider = makeProvider(source: source, endpointIntervals: (300, 120))
        _ = try await provider.fetchSnapshot()
        source.setToken("new-token")
        _ = await provider.reloadTokenExpiry()
        _ = try await provider.fetchSnapshot()
        XCTAssertEqual(StubEndpoint.requestCount, 2)
    }

    func testEndpointCacheIsPerProvider() async throws {
        StubEndpoint.reset(Array(repeating: .init(status: 200, body: Self.usagePayload), count: 2))
        let first = makeProvider(source: CredentialSource(readable: true), endpointIntervals: (300, 120))
        let second = makeProvider(source: CredentialSource(readable: true), endpointIntervals: (300, 120))
        _ = try await first.fetchSnapshot()
        _ = try await second.fetchSnapshot()
        _ = try await first.fetchSnapshot()
        _ = try await second.fetchSnapshot()
        XCTAssertEqual(StubEndpoint.requestCount, 2)
    }

    func testBackoffWinsOverCachedEndpointReading() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload), .init(status: 429)])
        let provider = makeProvider(source: CredentialSource(readable: true), endpointIntervals: (300, 0))
        _ = try await provider.fetchSnapshot()
        for freshness: UsageFreshness in [.live, .standard] {
            do {
                _ = try await provider.fetchSnapshot(freshness: freshness)
                XCTFail("the endpoint penalty must take precedence over reuse")
            } catch UsageProviderError.rateLimited { }
        }
        XCTAssertEqual(StubEndpoint.requestCount, 2)
    }


    // MARK: - Helpers

    func testOAuthResetCreditsReachTheSnapshotAndDisappearAfterUse() async throws {
        let spent = String(decoding: ClaudeResetFixture.futureUsage, as: UTF8.self)
            .replacingOccurrences(of: "\"resets_left\":1", with: "\"resets_left\":0")
        StubEndpoint.reset([
            .init(status: 200, body: ClaudeResetFixture.futureUsage),
            .init(status: 200, body: Data(spent.utf8))
        ])
        let provider = makeProvider(source: CredentialSource(readable: true))
        let available = try await provider.fetchSnapshot()
        XCTAssertEqual(available.resetCredits?.availableCount, 1)
        XCTAssertTrue(available.hasAvailableResetCredits)
        let used = try await provider.fetchSnapshot()
        XCTAssertFalse(used.hasAvailableResetCredits)
    }

    func testDesktopResetCreditsReachTheSnapshotWithoutReadingCredentials() async throws {
        let directory = makeCacheDirectory()
        writeResetEntry(into: directory, body: ClaudeResetFixture.availableCacheBody)
        let source = CredentialSource(readable: false)
        let provider = makeProvider(source: source, profile: desktopProfile(),
                                    desktopCache: ClaudeDesktopUsageCache(directory: directory))
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.resetCredits?.availableCount, 1)
        XCTAssertEqual(snapshot.windows.first?.usedFraction, 0.08)
        XCTAssertEqual(source.reads, 0)
        XCTAssertEqual(StubEndpoint.requestCount, 0)

        writeResetEntry(into: directory, body: ClaudeResetFixture.spentCacheBody)
        let spent = try await provider.fetchSnapshot()
        XCTAssertFalse(spent.hasAvailableResetCredits)
    }

    func testExpiredDesktopWindowsStillEnrichTheCLIFallbackWithFreshResets() async throws {
        let directory = makeCacheDirectory()
        writeResetEntry(into: directory, body: ClaudeResetFixture.expiredWindowsCacheBody)
        let source = CredentialSource(readable: false)
        let provider = makeProvider(source: source, cli: Self.cli { Self.cliUsage },
                                    profile: desktopProfile(),
                                    desktopCache: ClaudeDesktopUsageCache(directory: directory))
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.windows.first?.usedFraction, 0.38)
        XCTAssertEqual(snapshot.resetCredits?.availableCount, 1)
        XCTAssertEqual(source.reads, 0)
    }

    func testUnsupportedOAuthSurfaceKeepsDatedDesktopResetsWhenUsageIsStale() async throws {
        let payload = Data(#"{"limits":[{"kind":"session","percent":42,"resets_at":"2099-01-01T00:00:00Z"}],"cedar_ember":{"eligible":false,"ineligible_reason":"surface","grants":[]}}"#.utf8)
        for age: TimeInterval in [0, 3 * 3600] {
            StubEndpoint.reset([.init(status: 200, body: payload)])
            let directory = makeCacheDirectory()
            writeResetEntry(into: directory, body: ClaudeResetFixture.expiredWindowsCacheBody, age: age)
            let provider = makeProvider(source: CredentialSource(readable: true), profile: desktopProfile(),
                                        desktopCache: ClaudeDesktopUsageCache(directory: directory))
            let snapshot = try await provider.fetchSnapshot()
            XCTAssertEqual(snapshot.windows.first?.usedFraction, 0.42)
            XCTAssertEqual(snapshot.resetCredits?.availableCount, 1)
            XCTAssertEqual(Date().timeIntervalSince(try XCTUnwrap(snapshot.resetCredits?.checkedAt)),
                           age, accuracy: 3)
        }
    }

    private func writeResetEntry(into directory: URL, body: Data, age: TimeInterval = 0) {
        var entry = ClaudeDesktopUsageCacheTests.Entry()
        entry.body = body
        entry.responseDate = nil
        entry.key += "&cedar_ember=1"
        let file = directory.appendingPathComponent("resets_0")
        try? entry.data().write(to: file)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)],
                                             ofItemAtPath: file.path)
    }

    private static let usagePayload = Data("""
    {"limits":[{"kind":"session","percent":42,"resets_at":"2099-01-01T00:00:00Z"}]}
    """.utf8)

    private func makeProvider(source: CredentialSource,
                              cli: ClaudeUsageCLI? = nil,
                              cliRefreshInterval: TimeInterval = 5 * 60,
                              liveCLIRefreshInterval: TimeInterval = 90,
                              profile: ClaudeProfile = .default(),
                              desktopCache: ClaudeDesktopUsageCache? = nil,
                              desktopFreshness: TimeInterval = 30 * 60,
                              liveDesktopFreshness: TimeInterval = 2 * 60,
                              desktopRescanInterval: TimeInterval = 5 * 60,
                              endpointIntervals: (standard: TimeInterval, live: TimeInterval) = (0, 0)) -> ClaudeOAuthProvider {
        // A private defaults suite per test: the archive persists the 429 back-off
        // deadline, and a leaked one would silently skip fetches in the next test.
        let name = "ClaudeOAuthProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        // No CLI, because these are the token path's tests. Left to find one,
        // the provider would answer off `claude "/usage"` on a machine that has
        // Claude Code installed and off the endpoint on one that does not, and
        // every assertion below about retries and back-off would depend on the
        // developer's own setup rather than on the code.
        // No desktop cache by default, for exactly the reason there is no CLI by
        // default: left to find the real one, these tests would answer off
        // whatever Claude Desktop happened to have cached on the machine running
        // them, and every assertion about retries and back-off would depend on
        // the developer's own setup rather than on the code.
        return ClaudeOAuthProvider(profile: profile,
                                   session: StubEndpoint.session(),
                                   archive: UsageArchive(defaults: defaults),
                                   loadCredentials: { try source.read() },
                                   cli: cli,
                                   cliRefreshInterval: cliRefreshInterval,
                                   liveCLIRefreshInterval: liveCLIRefreshInterval,
                                   desktopCache: desktopCache,
                                   desktopFreshness: desktopFreshness,
                                   liveDesktopFreshness: liveDesktopFreshness,
                                   desktopRescanInterval: desktopRescanInterval,
                                   minEndpointInterval: endpointIntervals.standard,
                                   liveMinEndpointInterval: endpointIntervals.live)
    }

    /// #178: a signed-in account whose answer names no limit gets a message,
    /// not an empty reading that waits for the first reading forever.
    func testAnAnswerWithNoLimitsSaysSoRatherThanWaiting() async throws {
        StubEndpoint.reset([.init(status: 200, body: Data(#"{"extra_usage":null}"#.utf8))])
        let provider = makeProvider(source: CredentialSource(readable: true))
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("an answer with no limit windows must not be a reading")
        } catch UsageProviderError.nothingMetered(let why) {
            XCTAssertTrue(why.contains("no usage limits"), why)
        }
    }

    // MARK: - The CLI path

    /// The point of the whole thing: when `claude "/usage"` answers, nothing
    /// asks macOS for a credential and nothing calls the endpoint.
    ///
    /// Counting is the only way to know. A provider that read the keychain and
    /// then threw the result away would return exactly the same snapshot, and
    /// the keychain prompt this exists to avoid would still have appeared.
    func testAWorkingCLIMeansNoKeychainReadAndNoRequest() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
        let source = CredentialSource(readable: true)
        let provider = makeProvider(source: source, cli: Self.cli(answering: Self.cliUsage))

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.windows.map(\.id), ["session", "weekly_all"])
        XCTAssertEqual(source.reads, 0, "the keychain was read even though the CLI answered")
        XCTAssertEqual(StubEndpoint.requestCount, 0, "the endpoint was called even though the CLI answered")
    }

    /// A CLI that cannot answer is a reason to ask the endpoint, never a reason
    /// to fail the refresh — otherwise installing Claude Code and signing out
    /// of it would take the ring down on a machine whose token is fine.
    func testAFailingCLIFallsBackToTheToken() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
        let source = CredentialSource(readable: true)
        let provider = makeProvider(source: source,
                                    cli: Self.cli(answering: "Please run /login first"))

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.windows.first?.id, "session")
        XCTAssertEqual(source.reads, 1, "the token path was not reached")
        XCTAssertEqual(StubEndpoint.requestCount, 1)
    }

    /// `UsageStore` polls twice a minute while a session is busy, and each ask
    /// is a subprocess. The windows do not move enough in half a minute to be
    /// worth one.
    func testTheCLIIsNotSpawnedOnEveryTick() async throws {
        let spawns = Counter()
        let provider = makeProvider(source: CredentialSource(readable: true),
                                    cli: Self.cli { spawns.increment(); return Self.cliUsage })

        _ = try await provider.fetchSnapshot()
        _ = try await provider.fetchSnapshot()
        _ = try await provider.fetchSnapshot()

        XCTAssertEqual(spawns.value, 1, "the CLI was spawned again inside its own interval")
    }

    /// And it is asked again once the interval has passed, or the ring would
    /// show one reading for the rest of the session.
    func testTheCLIIsAskedAgainOnceTheIntervalPasses() async throws {
        let spawns = Counter()
        let provider = makeProvider(source: CredentialSource(readable: true),
                                    cli: Self.cli { spawns.increment(); return Self.cliUsage },
                                    cliRefreshInterval: 0)

        _ = try await provider.fetchSnapshot()
        _ = try await provider.fetchSnapshot()

        XCTAssertEqual(spawns.value, 2)
    }

    /// A CLI that is signed out fails with `needsAuth`. It should fall back to the token
    /// and throttle subsequent spawns for `cliRefreshInterval`, rather than spawning a
    /// subprocess on every tick.
    func testASignedOutCLIDoesNotSpawnOnEveryTick() async throws {
        StubEndpoint.reset(Array(repeating: .init(status: 200, body: Self.usagePayload), count: 3))
        let source = CredentialSource(readable: true)
        let spawns = Counter()
        let provider = makeProvider(source: source,
                                    cli: Self.cli {
                                        spawns.increment()
                                        throw UsageProviderError.needsAuth
                                    })

        _ = try await provider.fetchSnapshot()
        _ = try await provider.fetchSnapshot()
        _ = try await provider.fetchSnapshot()

        XCTAssertEqual(spawns.value, 1, "a signed-out CLI was spawned repeatedly")
        XCTAssertEqual(StubEndpoint.requestCount, 3, "fallback to endpoint did not occur on each tick")
    }

    /// A transient CLI failure (e.g. unparseable output or unexpected error) falls back
    /// to the token on that tick, but must not lock out the CLI for 5 minutes.
    func testATransientCLIFailureAllowsImmediateRetryOnNextTick() async throws {
        StubEndpoint.reset(Array(repeating: .init(status: 200, body: Self.usagePayload), count: 2))
        let source = CredentialSource(readable: true)
        let shouldFail = Counter()
        let spawns = Counter()
        let provider = makeProvider(source: source,
                                    cli: Self.cli {
                                        spawns.increment()
                                        if shouldFail.value == 0 {
                                            shouldFail.increment()
                                            return "Temporary blip: retry later"
                                        }
                                        return Self.cliUsage
                                    })

        // First tick: transient CLI failure, falls back to token path.
        let first = try await provider.fetchSnapshot()
        XCTAssertEqual(first.windows.first?.id, "session")
        XCTAssertEqual(source.reads, 1)
        XCTAssertEqual(spawns.value, 1)

        // Second tick: CLI is asked again immediately and succeeds without keychain read.
        let second = try await provider.fetchSnapshot()
        XCTAssertEqual(second.usedFraction, 0.38)
        XCTAssertEqual(source.reads, 1, "the second tick should have used CLI instead of reading keychain")
        XCTAssertEqual(spawns.value, 2)
    }

    /// When Desktop cache is stale and CLI is available, usage must be read via
    /// CLI without touching the keychain or endpoint.
    func testAStaleDesktopSnapshotUsesCLIWhenAvailableWithoutKeychainRead() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
        let source = CredentialSource(readable: true)
        let provider = makeProvider(source: source,
                                    cli: Self.cli(answering: Self.cliUsage),
                                    profile: desktopProfile(),
                                    desktopCache: desktopCache(age: 4 * 3600))

        let snapshot = try await provider.fetchSnapshot()

        // 38% is CLI's session window; 42% would be the endpoint fixture.
        XCTAssertEqual(snapshot.usedFraction, 0.38)
        XCTAssertEqual(source.reads, 0, "the keychain was read even though CLI was available")
        XCTAssertEqual(StubEndpoint.requestCount, 0, "the endpoint was called even though CLI was available")
    }


    // MARK: - The Claude Desktop cache path

    /// Why the whole source exists. On this machine `claude "/usage"` prints a
    /// cost summary and no windows at all, and the keychain token has not been
    /// re-minted since Claude Code last ran — so both existing paths fail while
    /// Claude Desktop sits there displaying the real numbers. Reading its cache
    /// has to be enough on its own, without a keychain read and without a request.
    func testAFreshDesktopSnapshotNeedsNoKeychainAndNoRequest() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
        let source = CredentialSource(readable: true)
        let provider = makeProvider(source: source, profile: desktopProfile(),
                                    desktopCache: desktopCache(age: 0))

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.windows.map(\.id), ["session", "weekly_all"])
        XCTAssertEqual(snapshot.usedFraction, 0.30, "the headline is not Desktop's session window")
        XCTAssertEqual(source.reads, 0, "the keychain was read even though the cache answered")
        XCTAssertEqual(StubEndpoint.requestCount, 0,
                       "the endpoint was called even though the cache answered")
    }

    /// Desktop is preferred over the CLI, not merely over the token: it is the
    /// cheaper of the two and cannot be refused, and on the machine this was
    /// written for the CLI is the source that lies by omission.
    func testDesktopIsPreferredOverTheCLI() async throws {
        let spawns = Counter()
        let provider = makeProvider(source: CredentialSource(readable: true),
                                    cli: Self.cli { spawns.increment(); return Self.cliUsage },
                                    profile: desktopProfile(),
                                    desktopCache: desktopCache(age: 0))

        let snapshot = try await provider.fetchSnapshot()

        // 30% is Desktop's; 38% would be the CLI's.
        XCTAssertEqual(snapshot.usedFraction, 0.30)
        XCTAssertEqual(spawns.value, 0, "a subprocess was spawned even though the cache answered")
    }

    /// The honesty requirement. Once Desktop stops updating, its numbers may not
    /// keep being presented as live — so a snapshot past the window is not
    /// returned at all, and the existing sources take over. Whatever the last
    /// good reading was is then `UsageStore`'s to re-show, dimmed and dated.
    func testAStaleDesktopSnapshotFallsThroughToTheExistingSources() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
        let source = CredentialSource(readable: true)
        let provider = makeProvider(source: source, profile: desktopProfile(),
                                    desktopCache: desktopCache(age: 4 * 3600))

        let snapshot = try await provider.fetchSnapshot()

        // The endpoint's fixture is 42%; Desktop's stale one is 30%.
        XCTAssertEqual(snapshot.usedFraction, 0.42, "a stale cache reading was shown as live")
        XCTAssertEqual(source.reads, 1, "the token path was not reached")
        XCTAssertEqual(StubEndpoint.requestCount, 1)
    }

    // MARK: - What a live fetch will accept

    /// Ten minutes is comfortably inside the thirty an idle ring may show, and
    /// comfortably outside the two a watched one may. The same cache, the same
    /// provider, two answers — which is the whole point of `UsageFreshness`.
    func testALiveFetchWillNotServeACacheAnIdleOneWould() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
        let source = CredentialSource(readable: true)
        let provider = makeProvider(source: source, profile: desktopProfile(),
                                    desktopCache: desktopCache(age: 10 * 60))

        // 30% is Desktop's cached reading; 42% is what the endpoint answers now.
        let standard = try await provider.fetchSnapshot(freshness: .standard)
        XCTAssertEqual(standard.usedFraction, 0.30)
        XCTAssertEqual(StubEndpoint.requestCount, 0)

        let live = try await provider.fetchSnapshot(freshness: .live)
        XCTAssertEqual(live.usedFraction, 0.42, "a ten-minute-old cache answered a live fetch")
        XCTAssertEqual(StubEndpoint.requestCount, 1)
    }

    /// A cache written seconds ago is the best answer there is to either
    /// question: free, unrefusable, and current. `.live` must not spend a
    /// request to be told the same number.
    func testALiveFetchStillTakesACacheThatIsActuallyCurrent() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
        let source = CredentialSource(readable: true)
        let provider = makeProvider(source: source, profile: desktopProfile(),
                                    desktopCache: desktopCache(age: 5))

        let snapshot = try await provider.fetchSnapshot(freshness: .live)

        XCTAssertEqual(snapshot.usedFraction, 0.30)
        XCTAssertEqual(source.reads, 0)
        XCTAssertEqual(StubEndpoint.requestCount, 0)
    }

    /// The CLI's own reuse window shortens the same way. Five minutes of one
    /// answer is right for a ring nobody is watching; it is most of a session
    /// window's movement for one somebody is.
    func testALiveFetchAsksTheCLIAgainInsideItsOrdinaryInterval() async throws {
        let spawns = Counter()
        let provider = makeProvider(source: CredentialSource(readable: true),
                                    cli: Self.cli { spawns.increment(); return Self.cliUsage },
                                    cliRefreshInterval: 5 * 60,
                                    liveCLIRefreshInterval: 0)

        _ = try await provider.fetchSnapshot(freshness: .standard)
        _ = try await provider.fetchSnapshot(freshness: .standard)
        XCTAssertEqual(spawns.value, 1, "the ordinary interval stopped holding its answer")

        _ = try await provider.fetchSnapshot(freshness: .live)
        XCTAssertEqual(spawns.value, 2, "a live fetch reused an answer from the ordinary interval")
    }

    /// And a live fetch is still not licence to spawn one per poll: inside its
    /// own interval it reuses, like everything else here.
    func testALiveFetchReusesTheCLIInsideItsOwnInterval() async throws {
        let spawns = Counter()
        let provider = makeProvider(source: CredentialSource(readable: true),
                                    cli: Self.cli { spawns.increment(); return Self.cliUsage },
                                    liveCLIRefreshInterval: 90)

        _ = try await provider.fetchSnapshot(freshness: .live)
        _ = try await provider.fetchSnapshot(freshness: .live)

        XCTAssertEqual(spawns.value, 1, "a live fetch spawned a subprocess per call")
    }

    // MARK: - Ask the provider every time you look

    /// `.fromSource` skips a cache written seconds ago — the one thing `.live`
    /// deliberately does not do. That is the setting's whole point: the figure
    /// comes from the account, not from a file, however current the file is.
    func testFromSourceSkipsEvenACacheWrittenSecondsAgo() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
        let source = CredentialSource(readable: true)
        let provider = makeProvider(source: source, profile: desktopProfile(),
                                    desktopCache: desktopCache(age: 5))

        let snapshot = try await provider.fetchSnapshot(freshness: .fromSource)

        XCTAssertEqual(snapshot.usedFraction, 0.42, "a cached reading answered .fromSource")
        XCTAssertEqual(StubEndpoint.requestCount, 1)
    }

    /// And it may not leave the ring emptier than not asking would have. On a
    /// Mac with Claude Desktop and no usable token — no Claude Code, an expired
    /// keychain item, or a 429 — the cache is the only source there is, and
    /// skipping it must not turn a filled ring into a failed refresh.
    func testFromSourceFallsBackToTheCacheWhenNoLiveSourceCanAnswer() async throws {
        StubEndpoint.reset([.init(status: 429)])
        let source = CredentialSource(readable: true)
        let provider = makeProvider(source: source, profile: desktopProfile(),
                                    desktopCache: desktopCache(age: 60))

        let snapshot = try await provider.fetchSnapshot(freshness: .fromSource)

        XCTAssertEqual(snapshot.usedFraction, 0.30, "the held reading was thrown away with the request")
        XCTAssertEqual(StubEndpoint.requestCount, 1, "the source was not asked first")
    }

    /// A cache past the ordinary thirty minutes is not resurrected by the
    /// fallback: it was not showable before the request and it is not showable
    /// after it. The store re-shows the last good reading, dimmed and dated.
    func testTheFallbackDoesNotResurrectACacheTooOldToShow() async {
        StubEndpoint.reset([.init(status: 429)])
        let provider = makeProvider(source: CredentialSource(readable: true),
                                    profile: desktopProfile(),
                                    desktopCache: desktopCache(age: 4 * 3600))

        do {
            let snapshot = try await provider.fetchSnapshot(freshness: .fromSource)
            XCTFail("a four-hour-old cache was shown as a reading: \(snapshot.usedFraction ?? -1)")
        } catch UsageProviderError.rateLimited {
            // The honest outcome: nothing live answered, and nothing held was
            // fit to stand in.
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    /// Skipping the cache is not the same as missing it. Counting it as a miss
    /// armed the rescan throttle, which then stopped the cache being read at all
    /// for five minutes — so one look with the setting on would have taken the
    /// Desktop source away from every poll after it.
    func testSkippingTheCacheDoesNotSuppressTheNextScan() async throws {
        StubEndpoint.reset(Array(repeating: .init(status: 200, body: Self.usagePayload), count: 2))
        let provider = makeProvider(source: CredentialSource(readable: true),
                                    profile: desktopProfile(),
                                    desktopCache: desktopCache(age: 30))

        _ = try await provider.fetchSnapshot(freshness: .fromSource)
        let next = try await provider.fetchSnapshot(freshness: .standard)

        XCTAssertEqual(next.usedFraction, 0.30, "the cache was no longer being read")
    }

    /// Claude Desktop is signed into one account; Codenotch draws a ring per
    /// Claude Code profile. A profile whose organization does not match the
    /// cached URL gets nothing from Desktop — the alternative is the personal
    /// account's session percentage on the work ring.
    func testACacheForAnotherOrganizationIsNotUsed() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
        let source = CredentialSource(readable: true)
        let provider = makeProvider(
            source: source,
            profile: desktopProfile(organization: "99999999-8888-7777-6666-555555555555"),
            desktopCache: desktopCache(age: 0))

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.usedFraction, 0.42, "another account's reading reached this ring")
        XCTAssertEqual(source.reads, 1)
    }

    /// A profile Claude Code has never signed in to has no organization to match
    /// on, and must not fall back to "whatever is in the cache".
    func testAProfileWithNoRecordedOrganizationIsNotMatched() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
        let source = CredentialSource(readable: true)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codenotch-nohome-\(UUID().uuidString)", isDirectory: true)
        let provider = makeProvider(source: source, profile: .default(home: home),
                                    desktopCache: desktopCache(age: 0))

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.usedFraction, 0.42)
        XCTAssertEqual(source.reads, 1)
    }

    /// With no Claude Desktop at all — no directory, nothing cached — the
    /// provider behaves exactly as it did before this source existed.
    func testNoDesktopCacheLeavesTheOldBehaviourIntact() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
        let source = CredentialSource(readable: true)
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("codenotch-absent-\(UUID().uuidString)", isDirectory: true)
        let provider = makeProvider(source: source, profile: desktopProfile(),
                                    desktopCache: ClaudeDesktopUsageCache(directory: absent))

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.usedFraction, 0.42)
        XCTAssertEqual(source.reads, 1)
        XCTAssertEqual(StubEndpoint.requestCount, 1)
    }

    /// `UsageStore` polls twice a minute while a session is busy, and a miss
    /// means a scan of a few thousand directory entries. Missing once must not mean
    /// scanning on every tick afterwards.
    ///
    /// Asserted by behaviour rather than by counting: an entry that appears
    /// during the interval is not picked up, which is only true if no scan
    /// happened. It is also the cost of the throttle, stated plainly — a Desktop
    /// that has just started writing again waits out one interval.
    func testAMissSuppressesTheNextScan() async throws {
        StubEndpoint.reset(Array(repeating: .init(status: 200, body: Self.usagePayload), count: 3))
        let directory = makeCacheDirectory()
        let provider = makeProvider(source: CredentialSource(readable: true),
                                    profile: desktopProfile(),
                                    desktopCache: ClaudeDesktopUsageCache(directory: directory))

        // Nothing cached yet: a miss, which arms the throttle.
        _ = try await provider.fetchSnapshot()
        writeUsageEntry(into: directory, age: 0)

        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.usedFraction, 0.42, "the cache was rescanned inside the interval")
    }

    /// And the scan does happen once the interval has passed, or a Desktop that
    /// comes back would never be noticed.
    func testTheScanHappensAgainOnceTheIntervalPasses() async throws {
        StubEndpoint.reset(Array(repeating: .init(status: 200, body: Self.usagePayload), count: 3))
        let directory = makeCacheDirectory()
        let provider = makeProvider(source: CredentialSource(readable: true),
                                    profile: desktopProfile(),
                                    desktopCache: ClaudeDesktopUsageCache(directory: directory),
                                    desktopRescanInterval: 0)

        _ = try await provider.fetchSnapshot()
        writeUsageEntry(into: directory, age: 0)

        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.usedFraction, 0.30, "the cache was never looked at again")
    }

    // MARK: - Desktop helpers

    /// A profile whose `.claude.json` records `organization`, so the provider has
    /// something to match a cache entry against. Nothing else about it is real.
    private func desktopProfile(
        organization: String = ClaudeDesktopUsageCacheTests.organization
    ) -> ClaudeProfile {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codenotch-home-\(UUID().uuidString)", isDirectory: true)
        let config = home.appendingPathComponent(".claude")
        try? FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let json = #"{"oauthAccount":{"emailAddress":"someone@example.com","organizationUuid":"\#(organization)"}}"#
        try? Data(json.utf8).write(to: home.appendingPathComponent(".claude.json"))
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return .default(home: home)
    }

    /// A cache directory holding one usage entry, written `age` seconds ago.
    private func desktopCache(age: TimeInterval) -> ClaudeDesktopUsageCache {
        let directory = makeCacheDirectory()
        writeUsageEntry(into: directory, age: age)
        return ClaudeDesktopUsageCache(directory: directory)
    }

    /// An empty throwaway directory shaped like `Cache_Data`.
    private func makeCacheDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codenotch-cache-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func writeUsageEntry(into directory: URL, age: TimeInterval) {
        var entry = ClaudeDesktopUsageCacheTests.Entry()
        // No `Date:` header, so the entry's modification time is what dates it —
        // which is the half a test can control.
        entry.responseDate = nil
        let file = directory.appendingPathComponent("entry_0")
        try? entry.data().write(to: file)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
    }

    /// A reading of two windows that are both still running.
    ///
    /// Dated from the clock rather than pinned, because a reading whose window
    /// has already rolled over is deliberately *not* reused — that is what
    /// stops a reset from staying hidden behind a cached number — and a fixed
    /// date would quietly turn these into tests of that instead.
    private static var cliUsage: String {
        let now = Date()
        return """
        Current session: 38% used · resets \(jakarta(now.addingTimeInterval(3 * 3600))) (Asia/Jakarta)
        Current week (all models): 4% used · resets \(jakarta(now.addingTimeInterval(6 * 86_400))) (Asia/Jakarta)
        """
    }

    /// The wording `claude "/usage"` prints, in the zone the line names.
    private static func jakarta(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Jakarta")
        formatter.dateFormat = "MMM d 'at' h:mma"
        return formatter.string(from: date).replacingOccurrences(of: "AM", with: "am")
            .replacingOccurrences(of: "PM", with: "pm")
    }

    private static func cli(answering text: String) -> ClaudeUsageCLI {
        cli { text }
    }

    private static func cli(_ answer: @escaping @Sendable () throws -> String) -> ClaudeUsageCLI {
        // The path is never run — `output` is what the provider reaches.
        ClaudeUsageCLI(binary: URL(fileURLWithPath: "/nonexistent/claude")) { _ in try answer() }
    }

    private func assertNeedsAuth(from provider: ClaudeOAuthProvider,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) async {
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected needsAuth, got a snapshot", file: file, line: line)
        } catch UsageProviderError.needsAuth {
            // expected
        } catch {
            XCTFail("expected needsAuth, got \(error)", file: file, line: line)
        }
    }
}

/// How many times the CLI was actually asked. "Did it spawn again?" is the
/// question the throttle exists to answer, and only a count answers it.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

/// Stands in for the keychain, and counts reads.
///
/// "Did it go back and ask?" is the whole question, and only a counter answers it.
private final class CredentialSource: @unchecked Sendable {
    private let lock = NSLock()
    private var readable: Bool
    private var readCount = 0
    private var token = "token"

    func setToken(_ token: String) {
        lock.lock(); self.token = token; lock.unlock()
    }

    init(readable: Bool) { self.readable = readable }

    var reads: Int {
        lock.lock(); defer { lock.unlock() }
        return readCount
    }

    func makeReadable() {
        lock.lock(); readable = true; lock.unlock()
    }

    func read() throws -> ClaudeCredentials {
        lock.lock()
        readCount += 1
        let allowed = readable
        let token = self.token
        lock.unlock()

        // The shape a dark-wake or not-found read takes by the time it leaves
        // `ClaudeCredentials.read()`.
        guard allowed else { throw UsageProviderError.needsAuth }
        return ClaudeCredentials(accessToken: token,
                                 expiresAt: .distantFuture,
                                 subscriptionType: "max")
    }
}

/// Canned answers for the usage endpoint, and a count of how many requests
/// actually arrived. The repo had no URL stubbing, which is why nothing above
/// `retryAfter(from:)` was ever tested.
private final class StubEndpoint: URLProtocol {
    struct Answer {
        let status: Int
        var body: Data = Data()
    }

    private static let lock = NSLock()
    private static var queued: [Answer] = []
    private static var served = 0
    private static var urls: [URL] = []

    static var requestURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return urls
    }

    static func reset(_ answers: [Answer]) {
        lock.lock(); queued = answers; served = 0; urls = []; lock.unlock()
    }

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return served
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubEndpoint.self]
        return URLSession(configuration: configuration)
    }

    private static func next(for request: URLRequest) -> Answer {
        lock.lock(); defer { lock.unlock() }
        served += 1
        if let url = request.url { urls.append(url) }
        // Running dry is a test bug, and a 500 says so more clearly than a crash
        // inside URLSession's callback would.
        return queued.isEmpty ? Answer(status: 500) : queued.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let answer = Self.next(for: request)
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: answer.status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// `account()` must read through the injected credential source, like every
/// other read here.
///
/// It used to call the keychain directly, which made it impossible for a test
/// to build a real provider without touching the login keychain. On a test host
/// rebuilt with a fresh ad-hoc signature that means an authorization prompt,
/// and a prompt nobody answers hangs the whole suite — which is exactly what it
/// did, on `providerSummaries`.
final class ClaudeAccountSourceTests: XCTestCase {
    private func provider(_ load: @escaping @Sendable () throws -> ClaudeCredentials)
        -> ClaudeOAuthProvider {
        let name = "ClaudeAccountSourceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        // `cli: nil` as well as the injected source: `account()` answers from
        // Claude Code's own config where it can find it, so without this the
        // answer would come from whatever the developer has installed rather
        // than from the credential this test handed it.
        return ClaudeOAuthProvider(archive: UsageArchive(defaults: defaults),
                                   loadCredentials: load,
                                   cli: nil)
    }

    func testTheAccountComesFromTheInjectedSource() throws {
        var reads = 0
        let account = provider {
            reads += 1
            return ClaudeCredentials(accessToken: "t", expiresAt: .distantFuture,
                                     subscriptionType: "team")
        }.account()

        XCTAssertEqual(reads, 1, "the keychain must not be consulted behind our back")
        XCTAssertEqual(account?.plan, "team")
    }

    /// A source that has nothing is no account, and no crash.
    func testNoCredentialIsNoAccount() {
        XCTAssertNil(provider { throw UsageProviderError.needsAuth }.account())
    }
}

/// Only a person asking may raise the keychain dialogue.
///
/// Claude Code recreates its keychain item on every token rotation, and a new
/// item admits only Apple's own tools, so an app that is let in once is
/// refused again an hour later. Reading from a poll therefore raised the
/// password dialogue on a timer. Background reads must never prompt; the one
/// read that may is the one somebody clicked "Allow access…" for.
final class ClaudeKeychainPromptTests: XCTestCase {
    private final class Reads: @unchecked Sendable {
        var interactive: [Bool] = []
        var fails = false
    }

    private func keychain(_ reads: Reads) -> ClaudeKeychain {
        ClaudeKeychain(services: ["codenotch-test-\(UUID().uuidString)"]) { _, interactive in
            reads.interactive.append(interactive)
            if reads.fails { throw UsageProviderError.accessDenied }
            return ClaudeCredentials(accessToken: "t", expiresAt: .distantFuture,
                                     subscriptionType: nil)
        }
    }

    func testABackgroundReadNeverPrompts() throws {
        let reads = Reads()
        _ = try keychain(reads).load()
        XCTAssertEqual(reads.interactive, [false])
    }

    /// The server rejecting a token, and the token refresher checking its
    /// work, both drop the cache too — and neither is a person.
    func testDroppingTheCacheOnItsOwnDoesNotPrompt() throws {
        let reads = Reads(), k = keychain(reads)
        _ = try k.load()
        k.forgetCached()
        _ = try k.load()
        XCTAssertEqual(reads.interactive, [false, false])
    }

    func testAskingAgainPromptsForTheNextReadOnly() throws {
        let reads = Reads(), k = keychain(reads)
        _ = try k.load()
        k.askAgain()
        _ = try k.load()
        k.forgetCached()
        _ = try k.load()
        XCTAssertEqual(reads.interactive, [false, true, false])
    }

    /// A Deny must not leave the permission lying around for the next poll to
    /// spend: the dialogue would then appear on a timer, which is the bug.
    /// Since #98 the next poll does not read at all.
    func testADeniedPromptDoesNotLeaveTheNextPollAllowedToPrompt() {
        let reads = Reads(), k = keychain(reads)
        reads.fails = true
        k.askAgain()
        XCTAssertThrowsError(try k.load())
        k.forgetCached()
        XCTAssertThrowsError(try k.load())
        XCTAssertEqual(reads.interactive, [true])
    }

    /// #98: Deny is an answer, not an obstacle. Background reads used to get
    /// the secret anyway through the security tool; now nothing reads it —
    /// not after the cache is dropped, not after the item changes — until the
    /// person asks again.
    func testADenyStopsEveryBackgroundReadUntilAskedAgain() throws {
        let reads = Reads(), k = keychain(reads)
        reads.fails = true
        k.askAgain()
        XCTAssertThrowsError(try k.load())
        XCTAssertTrue(k.isRefused)

        reads.fails = false
        for _ in 0..<3 {
            k.forgetCached()
            XCTAssertThrowsError(try k.load()) { error in
                guard case UsageProviderError.accessDenied = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertEqual(reads.interactive, [true], "a refused login must not be read in the background")

        k.askAgain()
        XCTAssertFalse(k.isRefused, "asking again lifts it for that one read")
        _ = try k.load()
        XCTAssertFalse(k.isRefused, "answering Allow clears the refusal")
        k.forgetCached()
        _ = try k.load()
        XCTAssertEqual(reads.interactive, [true, true, false])
    }

    /// Only the dialogue's own answer counts. A background read macOS refused
    /// without asking anyone is not a person saying no.
    func testARefusalWithoutADialogueIsNotRecorded() {
        let reads = Reads(), k = keychain(reads)
        reads.fails = true
        XCTAssertThrowsError(try k.load())
        XCTAssertFalse(k.isRefused)
    }

    /// Kept in preferences, so relaunching does not quietly undo a Deny.
    func testARefusalSurvivesARelaunch() {
        let suite = "ClaudeKeychainRefusal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = "codenotch-test-\(UUID().uuidString)"
        let first = ClaudeKeychain(services: [service], refusals: defaults) { _, _ in
            throw UsageProviderError.accessDenied
        }
        first.askAgain()
        XCTAssertThrowsError(try first.load())

        var readAgain = false
        let relaunched = ClaudeKeychain(services: [service], refusals: defaults) { _, _ in
            readAgain = true
            return ClaudeCredentials(accessToken: "t", expiresAt: .distantFuture, subscriptionType: nil)
        }
        XCTAssertTrue(relaunched.isRefused)
        XCTAssertThrowsError(try relaunched.load())
        XCTAssertFalse(readAgain)
    }
}

extension ClaudeKeychainPromptTests {
    /// An "Allow access…" whose refresh never reached the keychain — the CLI
    /// answered instead — must not be spent by a poll much later.
    func testAnUnspentPermissionExpires() throws {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000) }
        let clock = Clock()
        var interactive: [Bool] = []
        let k = ClaudeKeychain(services: ["codenotch-test-\(UUID().uuidString)"],
                               now: { clock.now }) { _, flag in
            interactive.append(flag)
            return ClaudeCredentials(accessToken: "t", expiresAt: .distantFuture, subscriptionType: nil)
        }
        k.askAgain()
        clock.now = clock.now.addingTimeInterval(ClaudeKeychain.promptWindow + 1)
        _ = try k.load()
        XCTAssertEqual(interactive, [false])
    }
}

/// A cached reading can be minutes old and still be wrong in the one way that
/// matters: the window it describes has already rolled over. Claude Desktop's
/// entry is considered live for half an hour, which is long enough to hide a
/// reset completely.
final class ClaudeExpiredWindowTests: XCTestCase {
    private func window(resetsAt: Date?) -> LimitWindow {
        LimitWindow(id: "session", label: "5-hour limit", usedFraction: 0.8, resetsAt: resetsAt)
    }

    func testAWindowPastItsResetIsExpired() {
        let now = Date()
        XCTAssertTrue(ClaudeOAuthProvider.hasExpiredWindow(
            [window(resetsAt: now.addingTimeInterval(-1))], at: now))
    }

    func testAWindowStillRunningIsNotExpired() {
        let now = Date()
        XCTAssertFalse(ClaudeOAuthProvider.hasExpiredWindow(
            [window(resetsAt: now.addingTimeInterval(60))], at: now))
    }

    /// Plenty of providers never say when the window turns over. Silence is not
    /// a reason to throw the reading away.
    func testAWindowWithoutAResetTimeIsNotExpired() {
        XCTAssertFalse(ClaudeOAuthProvider.hasExpiredWindow([window(resetsAt: nil)], at: Date()))
        XCTAssertFalse(ClaudeOAuthProvider.hasExpiredWindow([], at: Date()))
    }

    /// One stale window is enough: the reading is written in one pass, so a
    /// rolled-over session window dates the weekly one beside it too.
    func testOneExpiredWindowDatesTheWholeReading() {
        let now = Date()
        XCTAssertTrue(ClaudeOAuthProvider.hasExpiredWindow([
            window(resetsAt: now.addingTimeInterval(86_400)),
            window(resetsAt: now.addingTimeInterval(-30))
        ], at: now))
    }
}

/// `claude /usage` answers for the whole machine, whatever CLAUDE_CONFIG_DIR
/// says, so it can only stand in for a ring while there is one login for it
/// to describe. With two, each ring has to read its own token.
final class ClaudeCLIEstimateScopeTests: XCTestCase {
    func testTheOnlyLoginMayUseTheEstimate() {
        XCTAssertTrue(ClaudeOAuthProvider.cliEstimateApplies(slug: nil, loginCount: 1))
    }

    func testANamedProfileNeverDoes() {
        XCTAssertFalse(ClaudeOAuthProvider.cliEstimateApplies(slug: "work", loginCount: 1))
        XCTAssertFalse(ClaudeOAuthProvider.cliEstimateApplies(slug: "work", loginCount: 2))
    }

    func testTheDefaultLoginStopsUsingItOnceThereIsASecondOne() {
        XCTAssertFalse(ClaudeOAuthProvider.cliEstimateApplies(slug: nil, loginCount: 2))
    }
}
