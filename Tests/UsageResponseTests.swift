import SQLite3
import XCTest
@testable import Codenotch

/// Guards the shape of `GET /api/oauth/usage`. It is not a published API, so
/// these are the tests that will fail first if Anthropic changes it.
final class UsageResponseTests: XCTestCase {
    private func decode(_ json: String) throws -> UsageResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = formatter.date(from: text) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: text)
                )
            }
            return date
        }
        return try decoder.decode(UsageResponse.self, from: Data(json.utf8))
    }

    /// Trimmed from a real response — the endpoint returns a long tail of
    /// null-valued keys that must not trip decoding.
    private let live = """
    {
      "five_hour": { "utilization": 52.0, "resets_at": "2026-08-28T09:50:00.316290+00:00",
                     "limit_dollars": null, "used_dollars": null },
      "seven_day": { "utilization": 17.0, "resets_at": "2026-09-02T17:00:00.316321+00:00",
                     "limit_dollars": null },
      "seven_day_opus": null,
      "nimbus_quill": { "utilization": 0.0, "resets_at": null },
      "limits": [
        { "kind": "session", "group": "session", "percent": 52, "severity": "normal",
          "resets_at": "2026-08-28T09:50:00.316290+00:00", "scope": null, "is_active": true },
        { "kind": "weekly_all", "group": "weekly", "percent": 17, "severity": "normal",
          "resets_at": "2026-09-02T17:00:00.316321+00:00", "scope": null, "is_active": false }
      ]
    }
    """

    func testDecodesTheLiveShape() throws {
        let windows = try decode(live).limitWindows()
        XCTAssertEqual(windows.map(\.id), ["session", "weekly_all", "weekly_fable"])
        XCTAssertEqual(windows[0].label, "Current session")
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.52, accuracy: 0.0001)
        XCTAssertEqual(windows[1].label, "All models")
        XCTAssertEqual(windows[1].usedFraction ?? -1, 0.17, accuracy: 0.0001)
        // Fable is in the live payload as `nimbus_quill` at 0% with no reset —
        // Claude's own panel still lists that row, so dropping it for want of
        // a countdown was the disagreement.
        XCTAssertEqual(windows[2].label, "Fable")
        XCTAssertEqual(windows[2].usedFraction ?? -1, 0, accuracy: 0.0001)
        XCTAssertNil(windows[2].resetsAt)
    }

    /// The session window always sorts above the weekly one, whatever order the
    /// endpoint lists them in — that is the order the design frame draws.
    func testSessionSortsFirst() throws {
        let reversed = """
        { "limits": [
            { "kind": "weekly_all", "percent": 17, "resets_at": "2026-09-02T17:00:00.316321+00:00" },
            { "kind": "session", "percent": 52, "resets_at": "2026-08-28T09:50:00.316290+00:00" } ] }
        """
        XCTAssertEqual(try decode(reversed).limitWindows().map(\.id), ["session", "weekly_all"])
    }

    /// A window with no reset time is not a window we can render a countdown
    /// for, so it is dropped rather than shown with a bogus date.
    func testDropsWindowsWithoutAResetTime() throws {
        let json = """
        { "limits": [ { "kind": "session", "percent": 5, "resets_at": null } ],
          "five_hour": { "utilization": 5.0, "resets_at": null } }
        """
        XCTAssertTrue(try decode(json).limitWindows().isEmpty)
    }

    /// Older responses without `limits` still render from the named windows.
    func testFallsBackToTheNamedWindows() throws {
        let json = """
        { "five_hour": { "utilization": 48.0, "resets_at": "2026-08-28T09:50:00.316290+00:00" },
          "seven_day": { "utilization": 16.0, "resets_at": "2026-09-02T17:00:00.316321+00:00" } }
        """
        let windows = try decode(json).limitWindows()
        XCTAssertEqual(windows.map(\.label), ["Current session", "All models"])
    }

    func testUnknownKindsGetAReadableLabel() {
        XCTAssertEqual(UsageResponse.label(forKind: "weekly_opus"), "Opus")
        XCTAssertEqual(UsageResponse.label(forKind: "weekly_cowork"), "Cowork")
        XCTAssertEqual(UsageResponse.label(forKind: "weekly_fable"), "Fable")
        XCTAssertEqual(UsageResponse.label(forKind: "nimbus_quill"), "Fable")
        XCTAssertEqual(UsageResponse.label(forKind: "seven_day_overage_included"), "Fable")
    }

    /// Claude Code's current name for the same Fable weekly cap.
    func testFableFromOverageIncludedNamedWindow() throws {
        let json = """
        { "seven_day_overage_included": {
            "utilization": 40.0,
            "resets_at": "2026-09-02T17:00:00.316321+00:00" } }
        """
        let windows = try decode(json).limitWindows()
        XCTAssertEqual(windows.map(\.id), ["weekly_fable"])
        XCTAssertEqual(windows[0].label, "Fable")
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.40, accuracy: 0.0001)
        XCTAssertNotNil(windows[0].resetsAt)
    }

    /// A scoped `limits[]` row is how /usage titles "Weekly · Fable", and it
    /// is drawn even before that cap has a reset time.
    func testFableFromScopedLimitsEntryEvenWithoutReset() throws {
        let json = """
        { "limits": [{
            "kind": "weekly_model", "percent": 12, "resets_at": null,
            "scope": { "model": { "display_name": "Fable" } } }] }
        """
        let windows = try decode(json).limitWindows()
        XCTAssertEqual(windows.map(\.id), ["weekly_fable"])
        XCTAssertEqual(windows[0].label, "Fable")
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.12, accuracy: 0.0001)
        XCTAssertNil(windows[0].resetsAt)
    }

    /// Two names for one cap must not become two rows.
    func testFableIsNotDuplicatedWhenNamedAndLimitsAgree() throws {
        let json = """
        { "nimbus_quill": { "utilization": 8.0, "resets_at": "2026-09-02T17:00:00.316321+00:00" },
          "seven_day_overage_included": { "utilization": 8.0,
            "resets_at": "2026-09-02T17:00:00.316321+00:00" },
          "limits": [{ "kind": "weekly_fable", "percent": 8,
                       "resets_at": "2026-09-02T17:00:00.316321+00:00" }] }
        """
        XCTAssertEqual(try decode(json).limitWindows().map(\.id), ["weekly_fable"])
    }

    func testFableSortsAfterAllModels() throws {
        let json = """
        { "limits": [
            { "kind": "weekly_opus", "percent": 3, "resets_at": "2026-09-02T17:00:00.316321+00:00" },
            { "kind": "weekly_fable", "percent": 8, "resets_at": "2026-09-02T17:00:00.316321+00:00" },
            { "kind": "weekly_all", "percent": 17, "resets_at": "2026-09-02T17:00:00.316321+00:00" },
            { "kind": "session", "percent": 52, "resets_at": "2026-08-28T09:50:00.316290+00:00" } ] }
        """
        XCTAssertEqual(try decode(json).limitWindows().map(\.id),
                       ["session", "weekly_all", "weekly_fable", "weekly_opus"])
    }

    /// A null Fable field is "not on this account", not a 0% row.
    func testANullFableNamedWindowIsOmitted() throws {
        let json = """
        { "five_hour": { "utilization": 10.0, "resets_at": "2026-08-28T09:50:00.316290+00:00" },
          "nimbus_quill": null, "seven_day_overage_included": null }
        """
        XCTAssertEqual(try decode(json).limitWindows().map(\.id), ["session"])
    }
}

/// The endpoint rate-limits, and a poll that keeps firing into a 429 is how you
/// stay rate-limited. These pin the back-off inputs.
final class RateLimitTests: XCTestCase {
    private func response(retryAfter: String?) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: retryAfter.map { ["Retry-After": $0] }
        )!
    }

    func testReadsRetryAfterInSeconds() {
        XCTAssertEqual(ClaudeOAuthProvider.retryAfter(from: response(retryAfter: "120")), 120)
    }

    func testReadsRetryAfterAsAnHTTPDate() throws {
        let future = Date().addingTimeInterval(300)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let parsed = try XCTUnwrap(
            ClaudeOAuthProvider.retryAfter(from: response(retryAfter: formatter.string(from: future)))
        )
        XCTAssertEqual(parsed, 300, accuracy: 2)
    }

    func testMissingOrUnparseableHeaderFallsBackToTheDefault() {
        XCTAssertNil(ClaudeOAuthProvider.retryAfter(from: response(retryAfter: nil)))
        XCTAssertNil(ClaudeOAuthProvider.retryAfter(from: response(retryAfter: "soon")))
    }

    func testAPastDateNeverYieldsANegativeDelay() throws {
        let delay = try XCTUnwrap(
            ClaudeOAuthProvider.retryAfter(from: response(retryAfter: "Mon, 01 Jan 2001 00:00:00 GMT"))
        )
        XCTAssertEqual(delay, 0)
    }

    /// Being told to slow down is not a broken provider: the last good reading
    /// is still roughly true, so it reads as staleness rather than an error.
    @MainActor
    func testRateLimitReadsAsStaleNotError() {
        let status = UsageStore.statusForTesting(UsageProviderError.rateLimited(retryAfter: 60))
        XCTAssertTrue(status.isStale)
    }

    @MainActor
    func testAuthFailureIsDistinctFromAnError() {
        XCTAssertEqual(UsageStore.statusForTesting(UsageProviderError.needsAuth), .needsAuth)
        XCTAssertEqual(
            UsageStore.statusForTesting(UsageProviderError.badResponse(status: 500)),
            .error("HTTP 500")
        )
    }
}

/// A cold start that cannot reach the endpoint must still show what it knew
/// last time, dated, rather than an empty ring.
final class UsageArchiveTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "UsageArchiveTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let reading = ProviderSnapshot(
        id: "claude", displayName: "Claude", glyph: .claude,
        fidelity: .official, status: .ok,
        windows: [
            LimitWindow(id: "session", label: "Current session",
                        usedFraction: 0.68, resetsAt: Date(timeIntervalSince1970: 1_787_910_000))
        ]
    )

    func testRoundTrips() {
        let defaults = makeDefaults()
        let taken = Date(timeIntervalSince1970: 1_787_900_000)
        UsageArchive(defaults: defaults).save(["claude": (reading, taken)])

        let loaded = UsageArchive(defaults: defaults).load()
        let restored = try? XCTUnwrap(loaded["claude"])
        XCTAssertEqual(restored?.snapshot.windows.first?.usedFraction, 0.68)
        XCTAssertEqual(restored?.snapshot.displayName, "Claude")
        XCTAssertEqual(restored?.fetchedAt, taken)
    }

    /// A restored reading is never presented as live.
    func testRestoredReadingsComeBackStale() throws {
        let defaults = makeDefaults()
        let taken = Date(timeIntervalSince1970: 1_787_900_000)
        UsageArchive(defaults: defaults).save(["claude": (reading, taken)])

        let restored = try XCTUnwrap(UsageArchive(defaults: defaults).load()["claude"])
        XCTAssertTrue(restored.snapshot.status.isStale)
        XCTAssertEqual(restored.snapshot.status.staleSince, taken)
    }

    func testEmptyArchiveIsNotAnError() {
        XCTAssertTrue(UsageArchive(defaults: makeDefaults()).load().isEmpty)
    }
}

/// `Retry-After: 0` is the endpoint's actual answer, and obeying it literally is
/// what keeps you rate limited.
final class BackoffTests: XCTestCase {
    func testAZeroHintStillWaitsAMinute() {
        XCTAssertEqual(ClaudeOAuthProvider.backoff(forAttempt: 0, retryAfter: 0), 60)
    }

    func testItDoublesWhileTheLimitPersists() {
        XCTAssertEqual(ClaudeOAuthProvider.backoff(forAttempt: 0, retryAfter: nil), 60)
        XCTAssertEqual(ClaudeOAuthProvider.backoff(forAttempt: 1, retryAfter: nil), 120)
        XCTAssertEqual(ClaudeOAuthProvider.backoff(forAttempt: 2, retryAfter: nil), 240)
    }

    func testItIsCappedSoItAlwaysRecovers() {
        XCTAssertEqual(ClaudeOAuthProvider.backoff(forAttempt: 99, retryAfter: nil), 15 * 60)
    }

    /// A server that asks for longer than our own schedule gets its way.
    func testAGenerousHintWins() {
        XCTAssertEqual(ClaudeOAuthProvider.backoff(forAttempt: 0, retryAfter: 600), 600)
    }
}

/// The back-off has to outlive the process, or a development loop of `make run`
/// walks into the rate limit on every launch and keeps it alive.
final class BackoffPersistenceTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "BackoffPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testRoundTrips() throws {
        let defaults = makeDefaults()
        let until = Date().addingTimeInterval(120)
        UsageArchive(defaults: defaults).saveBackoffUntil(until)

        let loaded = try XCTUnwrap(UsageArchive(defaults: defaults).loadBackoffUntil())
        XCTAssertEqual(loaded.timeIntervalSince1970, until.timeIntervalSince1970, accuracy: 0.01)
    }

    /// An expired back-off is not a back-off; it must not hold the next launch up.
    func testAnExpiredBackoffIsIgnored() {
        let defaults = makeDefaults()
        UsageArchive(defaults: defaults).saveBackoffUntil(Date().addingTimeInterval(-10))
        XCTAssertNil(UsageArchive(defaults: defaults).loadBackoffUntil())
    }

    func testClearingRemovesIt() {
        let defaults = makeDefaults()
        let archive = UsageArchive(defaults: defaults)
        archive.saveBackoffUntil(Date().addingTimeInterval(120))
        archive.saveBackoffUntil(nil)
        XCTAssertNil(archive.loadBackoffUntil())
    }
}

/// Your usage cannot move while nothing is running, so polling hard through a
/// quiet afternoon spends rate-limit budget re-reading an unchanged number.
final class RefreshScheduleTests: XCTestCase {
    private let idle: TimeInterval = 5 * 60

    @MainActor
    func testBusyAlwaysPolls() {
        XCTAssertTrue(UsageStore.shouldRefresh(isBusy: true, sinceLastAttempt: 0, idleInterval: idle))
        XCTAssertTrue(UsageStore.shouldRefresh(isBusy: true, sinceLastAttempt: 60, idleInterval: idle))
    }

    @MainActor
    func testIdleWaitsOutTheLongerInterval() {
        XCTAssertFalse(UsageStore.shouldRefresh(isBusy: false, sinceLastAttempt: 60, idleInterval: idle))
        XCTAssertFalse(UsageStore.shouldRefresh(isBusy: false, sinceLastAttempt: 299, idleInterval: idle))
        XCTAssertTrue(UsageStore.shouldRefresh(isBusy: false, sinceLastAttempt: 300, idleInterval: idle))
    }

    /// A first run has never attempted anything and must not be held back.
    @MainActor
    func testTheFirstAttemptIsNeverDeferred() {
        XCTAssertTrue(UsageStore.shouldRefresh(
            isBusy: false,
            sinceLastAttempt: .greatestFiniteMagnitude,
            idleInterval: idle
        ))
    }
}

/// Some failures say something about the account rather than about the network.
/// Dimming an old number through one of those would keep showing a figure that
/// is no longer true — and, after an endpoint change, one from a source we no
/// longer read.
final class SupersedingStatusTests: XCTestCase {
    @MainActor
    func testSignedOutAndUnmeteredDropTheRememberedReading() {
        XCTAssertTrue(UsageStore.supersedesHistory(.needsAuth))
        XCTAssertTrue(UsageStore.supersedesHistory(.unsupported("free plan")))
    }

    /// A network blip or a rate limit does not make yesterday's number false.
    @MainActor
    func testTransientFailuresKeepIt() {
        XCTAssertFalse(UsageStore.supersedesHistory(.error("HTTP 500")))
        XCTAssertFalse(UsageStore.supersedesHistory(.stale(since: Date())))
        XCTAssertFalse(UsageStore.supersedesHistory(.ok))
    }
}

/// Claude Code's own schema says a window is "present only while the API reports
/// it and its resets_at has not passed" — so the session entry vanishes from
/// `limits` the moment it rolls over. That is precisely when someone looks.
final class ResetWindowTests: XCTestCase {
    private func decode(_ json: String) throws -> UsageResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = formatter.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: text))
            }
            return date
        }
        return try decoder.decode(UsageResponse.self, from: Data(json.utf8))
    }

    /// The reported failure: with the session gone from `limits`, the weekly slid
    /// into first place and the ring quietly started meaning something else.
    func testSessionSurvivesWhenItDropsOutOfLimits() throws {
        let json = """
        { "five_hour": { "utilization": 0.0, "resets_at": "2026-08-29T18:39:59.636345+00:00" },
          "seven_day": { "utilization": 33.0, "resets_at": "2026-09-02T16:59:59.636373+00:00" },
          "limits": [ { "kind": "weekly_all", "percent": 33,
                        "resets_at": "2026-09-02T16:59:59.636373+00:00" } ] }
        """
        let windows = try decode(json).limitWindows()
        XCTAssertEqual(windows.map(\.id), ["session", "weekly_all"])
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0, accuracy: 0.0001)
    }

    /// `limits` still wins where it has the window — it carries more detail.
    func testLimitsAreNotDuplicatedByTheNamedWindows() throws {
        let json = """
        { "five_hour": { "utilization": 23.0, "resets_at": "2026-08-29T13:39:59.636345+00:00" },
          "limits": [ { "kind": "session", "percent": 23,
                        "resets_at": "2026-08-29T13:39:59.636345+00:00" } ] }
        """
        XCTAssertEqual(try decode(json).limitWindows().map(\.id), ["session"])
    }

    /// If the session is genuinely absent everywhere, the cell shows nothing
    /// rather than promoting the weekly into its place.
    func testAMissingHeadlineShowsNoReadingRatherThanAnotherWindow() {
        let snapshot = ProviderSnapshot(
            id: "claude", displayName: "Claude", glyph: .claude,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "weekly_all", label: "All models", usedFraction: 0.33)],
            headlineID: "session"
        )
        XCTAssertNil(snapshot.headline)
        XCTAssertEqual(snapshot.headlineText, "—")
        XCTAssertEqual(snapshot.windows.count, 1, "the weekly is still listed in the tooltip")
    }

    /// A provider that declares no headline keeps the old positional rule.
    func testUndeclaredHeadlineFallsBackToTheFirstWindow() {
        let snapshot = ProviderSnapshot(
            id: "x", displayName: "X", glyph: .claude,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "only", label: "Only", usedFraction: 0.5)]
        )
        XCTAssertEqual(snapshot.headline?.id, "only")
    }
}

/// Clicking one ring refetches that provider only.
@MainActor
final class SingleProviderRefreshTests: XCTestCase {
    /// A stub that records what it was asked for and how often.
    private final class CountingProvider: UsageProvider, @unchecked Sendable {
        let id: String
        let displayName = "Stub"
        let glyph = ProviderGlyph.claude
        private(set) var calls = 0

        init(id: String) { self.id = id }

        func forgetCalls() { calls = 0 }

        private(set) var signedOut = false
        func signOut() async { signedOut = true }

        func fetchSnapshot() async throws -> ProviderSnapshot {
            calls += 1
            return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                    fidelity: .official, status: .ok,
                                    windows: [LimitWindow(id: "w", label: "W", usedFraction: 0.5)])
        }
    }

    private func store(_ providers: [CountingProvider]) -> UsageStore {
        let name = "SingleProviderRefreshTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return UsageStore(providers: providers, archive: UsageArchive(defaults: defaults))
    }

    /// The whole point: refreshing one cell must not spend every other
    /// provider's rate-limit budget. Claude's in particular is easy to exhaust.
    func testOnlyTheAskedForProviderIsFetched() async {
        let a = CountingProvider(id: "a")
        let b = CountingProvider(id: "b")
        let store = store([a, b])

        store.refresh(providerID: "a")
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(a.calls, 1)
        XCTAssertEqual(b.calls, 0, "refreshing one provider fetched another")
    }

    /// The cell shows the fetch happening, so the flag has to go up immediately
    /// rather than after the round trip.
    func testTheProviderIsMarkedRefreshingStraightAway() {
        let a = CountingProvider(id: "a")
        let store = store([a])
        store.refresh(providerID: "a")
        XCTAssertTrue(store.refreshing.contains("a"))
    }

    /// Clicking repeatedly must not stack up requests.
    func testASecondClickWhileInFlightIsIgnored() async {
        let a = CountingProvider(id: "a")
        let store = store([a])
        store.refresh(providerID: "a")
        store.refresh(providerID: "a")
        store.refresh(providerID: "a")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(a.calls, 1)
    }

    func testAnUnknownProviderIsIgnored() {
        let store = store([CountingProvider(id: "a")])
        store.refresh(providerID: "nope")
        XCTAssertTrue(store.refreshing.isEmpty)
    }
}

/// Overnight the Claude token ages out, because this app deliberately does not
/// refresh a credential it does not own — Claude Code rotates it whenever it
/// next runs. What must not happen is the notch demanding a sign-in for a token
/// that is merely old.
@MainActor
final class ExpiredCredentialTests: XCTestCase {
    func testAnExpiredTokenAgesTheReadingRatherThanClearingIt() {
        let status = UsageStore.statusForTesting(UsageProviderError.credentialExpired)
        XCTAssertTrue(status.isStale, "an expired token should read as stale, not as an error")
        XCTAssertFalse(UsageStore.supersedesHistory(status),
                       "the last reading is old, not false — it must survive")
    }

    /// Being genuinely signed out is different and does clear it.
    func testBeingSignedOutStillClearsIt() {
        let status = UsageStore.statusForTesting(UsageProviderError.needsAuth)
        XCTAssertEqual(status, .needsAuth)
        XCTAssertTrue(UsageStore.supersedesHistory(status))
    }
}

/// Both Cursor and Codex keep their state in another app's SQLite database, and
/// both run it in WAL mode. How that database is opened decides whether the
/// notch works after a restart.
final class SQLiteStoreTests: XCTestCase {
    private func makeDatabase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE t (v TEXT);", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO t VALUES ('hello'), ('world');", nil, nil, nil)
        sqlite3_close(db)   // checkpoints and removes the -wal / -shm sidecars
        return url
    }

    /// The regression: a `mode=ro` open needs the `-shm` sidecar, and that only
    /// exists while the owning app is running. After a restart it is gone and a
    /// read-only open fails outright — which is how Codex came back from a
    /// reboot reporting "no threads on this machine".
    func testOpensAfterTheOwningAppHasQuit() throws {
        let url = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = SQLiteStore.open(url)
        XCTAssertNotNil(db, "could not open a checkpointed WAL database")
        XCTAssertEqual(SQLiteStore.rows(in: db, sql: "SELECT v FROM t"), ["hello", "world"])
        sqlite3_close(db)
    }

    func testAMissingFileIsNil() {
        let missing = URL(fileURLWithPath: "/tmp/nope-\(UUID().uuidString).sqlite")
        XCTAssertNil(SQLiteStore.open(missing))
    }
}

/// Switching a provider off is not hiding it. Its credential must not be read
/// at all — filtering the results afterwards would still touch the keychain.
@MainActor
final class DisconnectedProviderTests: XCTestCase {
    private final class CountingProvider: UsageProvider, @unchecked Sendable {
        let id: String
        let displayName = "Stub"
        let glyph = ProviderGlyph.claude
        private(set) var calls = 0

        init(id: String) { self.id = id }

        func forgetCalls() { calls = 0 }

        private(set) var signedOut = false
        func signOut() async { signedOut = true }

        func fetchSnapshot() async throws -> ProviderSnapshot {
            calls += 1
            return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                    fidelity: .official, status: .ok,
                                    windows: [LimitWindow(id: "w", label: "W", usedFraction: 0.5)])
        }
    }

    private func store(_ providers: [CountingProvider],
                       defaults: UserDefaults? = nil) -> UsageStore {
        let defaults = defaults ?? {
            let name = "DisconnectedProviderTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            return defaults
        }()
        return UsageStore(providers: providers, archive: UsageArchive(defaults: defaults))
    }

    private func freshDefaults() -> UserDefaults {
        let name = "DisconnectedProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testADisconnectedProviderIsNeverFetched() async {
        let a = CountingProvider(id: "a")
        let b = CountingProvider(id: "b")
        let store = store([a, b])
        store.disconnected = ["b"]
        // Setting it refreshes on its own; count only the pass we ask for.
        try? await Task.sleep(nanoseconds: 150_000_000)
        a.forgetCalls()
        b.forgetCalls()

        await store.refresh()

        XCTAssertEqual(a.calls, 1)
        XCTAssertEqual(b.calls, 0, "a disconnected provider had its credential read")
    }

    /// Asking for one by hand must respect it too — the ring is gone, but the
    /// menu's Refresh now is not.
    func testRefreshingOneByHandRespectsIt() async {
        let a = CountingProvider(id: "a")
        let store = store([a])
        store.disconnected = ["a"]

        store.refresh(providerID: "a")
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(a.calls, 0)
    }

    func testItsReadingDisappearsImmediately() async {
        let a = CountingProvider(id: "a")
        let b = CountingProvider(id: "b")
        let store = store([a, b])
        await store.refresh()
        XCTAssertEqual(store.snapshots.count, 2)

        store.disconnected = ["b"]
        XCTAssertEqual(store.snapshots.map(\.id), ["a"])
    }
}


/// Signing out is more than switching off. Switching off stops the next read;
/// signing out must also discard the reading already taken, or the account's
/// numbers come back — dimmed, but back — on the next launch.
@MainActor
final class SignOutTests: XCTestCase {
    private final class Stub: UsageProvider, @unchecked Sendable {
        let id = "a"
        let displayName = "Stub"
        let glyph = ProviderGlyph.claude
        private(set) var signedOut = false

        func fetchSnapshot() async throws -> ProviderSnapshot {
            ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                             fidelity: .official, status: .ok,
                             windows: [LimitWindow(id: "w", label: "W", usedFraction: 0.5)])
        }

        func signOut() async { signedOut = true }
    }

    private func defaults() -> UserDefaults {
        let name = "SignOutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testItTakesTheReadingOffScreen() async {
        let defaults = defaults()
        let store = UsageStore(providers: [Stub()], archive: UsageArchive(defaults: defaults))
        await store.refresh()
        XCTAssertEqual(store.snapshots.count, 1)

        store.signOut(providerID: "a")

        XCTAssertTrue(store.snapshots.isEmpty)
    }

    /// The one that a plain disconnect would fail.
    func testTheReadingDoesNotComeBackOnTheNextLaunch() async {
        let defaults = defaults()
        let first = UsageStore(providers: [Stub()], archive: UsageArchive(defaults: defaults))
        await first.refresh()
        first.signOut(providerID: "a")

        let relaunched = UsageStore(providers: [Stub()],
                                    archive: UsageArchive(defaults: defaults))

        // A forgotten provider comes back as the placeholder: no windows, and
        // dated to `.distantPast` rather than to when it was actually read.
        let reading = relaunched.snapshots[0]
        XCTAssertTrue(reading.windows.isEmpty,
                      "a signed-out account's numbers survived a relaunch")
        XCTAssertEqual(reading.status.staleSince, .distantPast)
    }

    /// Only the provider signed out of — signing out of one account must not
    /// wipe the others.
    func testItLeavesOtherProvidersRemembered() async {
        final class Other: UsageProvider, @unchecked Sendable {
            let id = "b"
            let displayName = "Other"
            let glyph = ProviderGlyph.cursor
            func fetchSnapshot() async throws -> ProviderSnapshot {
                ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                 fidelity: .official, status: .ok,
                                 windows: [LimitWindow(id: "w", label: "W", usedFraction: 0.2)])
            }
        }

        let defaults = defaults()
        let first = UsageStore(providers: [Stub(), Other()],
                               archive: UsageArchive(defaults: defaults))
        await first.refresh()
        first.signOut(providerID: "a")

        let relaunched = UsageStore(providers: [Stub(), Other()],
                                    archive: UsageArchive(defaults: defaults))
        let byID = Dictionary(uniqueKeysWithValues: relaunched.snapshots.map { ($0.id, $0) })

        XCTAssertEqual(byID["a"]?.windows.count, 0)
        XCTAssertEqual(byID["b"]?.windows.count, 1,
                       "signing out of one provider forgot another")
    }

    func testItTellsTheProviderToDiscardItsOwnSession() async {
        let stub = Stub()
        let store = UsageStore(providers: [stub], archive: UsageArchive(defaults: defaults()))

        store.signOut(providerID: "a")
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(stub.signedOut)
    }
}

/// The row has to say what signing out here does *not* reach, or someone signs
/// out expecting to be signed out of Cursor too.
final class SignOutCaveatTests: XCTestCase {
    func testItNamesTheAppThatKeepsTheSession() {
        let route = SignInRoute.openApp(bundleID: "com.example", name: "Cursor")
        XCTAssertTrue(route.signOutCaveat.contains("Cursor"))
    }

    func testGuidanceRoutesStillCarryOne() {
        XCTAssertFalse(SignInRoute.guidance("anything").signOutCaveat.isEmpty)
    }
}


/// Switching a provider on should take the user to wherever that account signs
/// in — a modal for a provider that owns its session, the owning app otherwise.
@MainActor
final class SignInRoutingTests: XCTestCase {
    private final class Stub: UsageProvider, @unchecked Sendable {
        let id = "a"
        let displayName = "Stub"
        let glyph = ProviderGlyph.claude
        var route: SignInRoute = .modal(name: "Stub")
        var stubAccount: ProviderAccount?
        private(set) var presented = 0
        private(set) var fetches = 0

        var signInRoute: SignInRoute { route }
        func account() -> ProviderAccount? { stubAccount }
        func presentSignIn() { presented += 1 }

        func fetchSnapshot() async throws -> ProviderSnapshot {
            fetches += 1
            return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                    fidelity: .official, status: .ok, windows: [])
        }
    }

    private func store(_ stub: Stub) -> UsageStore {
        let name = "SignInRoutingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return UsageStore(providers: [stub], archive: UsageArchive(defaults: defaults))
    }

    func testItOpensTheModalWhenThereIsNoCredential() {
        let stub = Stub()
        XCTAssertTrue(store(stub).signIn(providerID: "a"))
        XCTAssertEqual(stub.presented, 1)
    }

    /// Throwing a sign-in window over an account that is already readable is
    /// just noise — connecting is the whole job.
    func testItDoesNotOpenAnythingWhenTheAccountIsAlreadyReadable() {
        let stub = Stub()
        stub.stubAccount = ProviderAccount(label: "me@example.com", plan: "pro",
                                           source: "Stub", manageURL: nil)
        XCTAssertTrue(store(stub).signIn(providerID: "a"))
        XCTAssertEqual(stub.presented, 0)
    }

    /// Claude Code is a command with no window to show. Reporting that honestly
    /// is what lets the row fall back to its guidance instead of appearing to
    /// have done something.
    func testItReportsWhenThereIsNothingToOpen() {
        let stub = Stub()
        stub.route = .guidance("Run Claude Code once.")
        XCTAssertFalse(store(stub).signIn(providerID: "a"))
        XCTAssertEqual(stub.presented, 0)
    }

    func testItReportsWhenTheOwningAppIsNotInstalled() {
        let stub = Stub()
        stub.route = .openApp(bundleID: "com.example.definitely-not-installed", name: "Nope")
        XCTAssertFalse(store(stub).signIn(providerID: "a"))
    }
}

/// A provider that owns its session is the one case where signing in and out
/// are literally true, and the row should say so rather than disclaiming.
final class ModalRouteCopyTests: XCTestCase {
    func testTheModalRouteOffersToSignIn() {
        XCTAssertEqual(SignInRoute.modal(name: "Perplexity").actionTitle,
                       "Sign in to Perplexity")
    }

    func testItDoesNotClaimYouStaySignedIn() {
        let caveat = SignInRoute.modal(name: "Perplexity").signOutCaveat
        XCTAssertFalse(caveat.contains("stay signed in"),
                       "a session Codenotch owns really is ended")
    }
}

/// Changing account is something you do while already signed in, so the
/// shortcut `signIn` takes when a credential exists is exactly wrong for it.
@MainActor
final class SwitchAccountTests: XCTestCase {
    private final class Stub: UsageProvider, @unchecked Sendable {
        let id = "a"
        let displayName = "Stub"
        let glyph = ProviderGlyph.claude
        var route: SignInRoute = .modal(name: "Stub")
        var stubAccount: ProviderAccount? = ProviderAccount(
            label: "me@example.com", plan: "pro", source: "Stub", manageURL: nil
        )
        private(set) var presented = 0

        var signInRoute: SignInRoute { route }
        func account() -> ProviderAccount? { stubAccount }
        func presentSignIn() { presented += 1 }

        func fetchSnapshot() async throws -> ProviderSnapshot {
            ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                             fidelity: .official, status: .ok, windows: [])
        }
    }

    private func store(_ stub: Stub) -> UsageStore {
        let name = "SwitchAccountTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return UsageStore(providers: [stub], archive: UsageArchive(defaults: defaults))
    }

    func testItOpensTheOwnerEvenWhenAnAccountIsAlreadyThere() {
        let stub = Stub()
        XCTAssertTrue(store(stub).openAccountSource(providerID: "a"))
        XCTAssertEqual(stub.presented, 1, "switching stopped at the signed-in shortcut")
    }

    /// The distinction that makes both worth having.
    func testSigningInStillDoesNothingWhenAlreadySignedIn() {
        let stub = Stub()
        _ = store(stub).signIn(providerID: "a")
        XCTAssertEqual(stub.presented, 0)
    }

    func testEveryRouteSaysWhereToSwitch() {
        XCTAssertTrue(SignInRoute.openApp(bundleID: "x", name: "Cursor")
            .switchHint.contains("Cursor"))
        XCTAssertFalse(SignInRoute.guidance("anything").switchHint.isEmpty)
    }
}

/// Switching a provider off has to make it gone — from the notch, from memory,
/// and from the archive. Dropping it from the visible list alone left the
/// reading in `lastGood`, which is written to the archive on every fetch, so a
/// switched-off provider came back at the next launch with its old ring.
@MainActor
final class DisconnectedProviderForgetsTests: XCTestCase {
    private final class Stub: UsageProvider, @unchecked Sendable {
        let id: String
        let displayName = "Stub"
        let glyph = ProviderGlyph.claude
        init(id: String) { self.id = id }
        func fetchSnapshot() async throws -> ProviderSnapshot {
            ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                             fidelity: .official, status: .ok,
                             windows: [LimitWindow(id: "w", label: "W", usedFraction: 0.25)])
        }
    }

    private func defaults() -> UserDefaults {
        let name = "DisconnectForget.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testSwitchingOffForgetsTheArchivedReading() async {
        let defaults = defaults()
        let store = UsageStore(providers: [Stub(id: "a"), Stub(id: "b")],
                               archive: UsageArchive(defaults: defaults))
        await store.refresh()
        XCTAssertEqual(UsageArchive(defaults: defaults).load().keys.sorted(), ["a", "b"])

        store.disconnected = ["b"]

        XCTAssertEqual(UsageArchive(defaults: defaults).load().keys.sorted(), ["a"],
                       "the switched-off provider is still remembered")
    }

    /// The symptom that was reported: its ring was back after a restart.
    func testItDoesNotComeBackAtTheNextLaunch() async {
        let defaults = defaults()
        let first = UsageStore(providers: [Stub(id: "a"), Stub(id: "b")],
                               archive: UsageArchive(defaults: defaults))
        await first.refresh()
        first.disconnected = ["b"]

        let relaunched = UsageStore(providers: [Stub(id: "a"), Stub(id: "b")],
                                    archive: UsageArchive(defaults: defaults),
                                    disconnected: ["b"])
        XCTAssertEqual(relaunched.snapshots.map(\.id), ["a"],
                       "a switched-off provider was drawn again at launch")
    }

    /// Told at construction, it never draws them even for a frame — the store
    /// is built before the preference binding can deliver.
    func testItIsExcludedFromTheVeryFirstList() {
        let store = UsageStore(providers: [Stub(id: "a"), Stub(id: "b")],
                               archive: UsageArchive(defaults: defaults()),
                               disconnected: ["a"])
        XCTAssertEqual(store.snapshots.map(\.id), ["b"])
    }

    /// Switching it back on restores it, rather than leaving a permanent hole.
    func testSwitchingBackOnBringsItBack() async {
        let store = UsageStore(providers: [Stub(id: "a"), Stub(id: "b")],
                               archive: UsageArchive(defaults: defaults()),
                               disconnected: ["b"])
        store.disconnected = []
        await store.refresh()
        XCTAssertEqual(store.snapshots.map(\.id).sorted(), ["a", "b"])
    }
}

/// The archive must not carry a switched-off provider across a launch, even
/// when nothing changes to trigger the pruning in `didSet` — which is the usual
/// case, since the preference binding delivers the same value the store was
/// built with.
@MainActor
final class DisconnectedArchivePruneTests: XCTestCase {
    private final class Stub: UsageProvider, @unchecked Sendable {
        let id: String
        let displayName = "Stub"
        let glyph = ProviderGlyph.claude
        init(id: String) { self.id = id }
        func fetchSnapshot() async throws -> ProviderSnapshot {
            ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                             fidelity: .official, status: .ok,
                             windows: [LimitWindow(id: "w", label: "W", usedFraction: 0.4)])
        }
    }

    func testAnArchivedReadingIsDroppedAtLaunchWhenSwitchedOff() {
        let name = "ArchivePrune.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        // Seeded directly: what a previous session would have left behind.
        let archive = UsageArchive(defaults: defaults)
        let reading = ProviderSnapshot(id: "b", displayName: "B", glyph: .claude,
                                       fidelity: .official, status: .ok,
                                       windows: [LimitWindow(id: "w", label: "W",
                                                             usedFraction: 0.4)])
        let kept = ProviderSnapshot(id: "a", displayName: "A", glyph: .claude,
                                    fidelity: .official, status: .ok,
                                    windows: [LimitWindow(id: "w", label: "W",
                                                          usedFraction: 0.2)])
        archive.save(["a": (kept, Date()), "b": (reading, Date())])
        XCTAssertEqual(archive.load().keys.sorted(), ["a", "b"])

        // Launching with "b" switched off, and nothing else happening — which
        // is the case `didSet` cannot cover, since it guards a no-op change.
        let store = UsageStore(providers: [Stub(id: "a"), Stub(id: "b")],
                               archive: archive, disconnected: ["b"])

        XCTAssertEqual(store.snapshots.map(\.id), ["a"], "b was still drawn")
        XCTAssertEqual(archive.load().keys.sorted(), ["a"],
                       "a switched-off provider kept its archived reading")
    }

}
