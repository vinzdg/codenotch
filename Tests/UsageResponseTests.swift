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
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows.map(\.duration), [18000, 604800])
        XCTAssertEqual(windows[0].id, "session")
        XCTAssertEqual(windows[0].label, "Current session")
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.52, accuracy: 0.0001)
        XCTAssertEqual(windows[1].label, "All models")
        XCTAssertEqual(windows[1].usedFraction ?? -1, 0.17, accuracy: 0.0001)
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

    /// The model-scoped weekly window reads "Scoped", because that is all its
    /// kind says. The model it meters is named in the entry's own scope, and is
    /// what the tooltip row should show — the same name Claude Code's own
    /// `/usage` gives that window.
    func testTheScopedWindowIsNamedAfterItsModel() throws {
        let json = """
        { "limits": [
            { "kind": "session", "percent": 52, "resets_at": "2026-08-28T09:50:00.316290+00:00",
              "scope": null },
            { "kind": "weekly_scoped", "percent": 61,
              "resets_at": "2026-09-02T17:00:00.316321+00:00",
              "scope": { "model": { "display_name": "Fable", "id": "claude-fable-5-1" } } } ] }
        """
        let windows = try decode(json).limitWindows()
        XCTAssertEqual(windows.map(\.label), ["Current session", "Fable"])
        // The id stays the API's own kind: it keys the archive and the cell.
        XCTAssertEqual(windows.map(\.id), ["session", "weekly_scoped"])
    }

    /// Named by the kind when the response names no model — honest, if terse.
    func testAnUnscopedModelWindowFallsBackToTheKind() throws {
        let json = """
        { "limits": [ { "kind": "weekly_scoped", "percent": 61,
                        "resets_at": "2026-09-02T17:00:00.316321+00:00", "scope": null } ] }
        """
        XCTAssertEqual(try decode(json).limitWindows().map(\.label), ["Scoped"])
    }

    /// The scope is a nicer name for a reading, not the reading. If its shape
    /// changes the percentage still has to arrive.
    func testAMalformedScopeDoesNotCostTheReading() throws {
        let json = """
        { "limits": [ { "kind": "weekly_scoped", "percent": 61,
                        "resets_at": "2026-09-02T17:00:00.316321+00:00",
                        "scope": "fable" } ] }
        """
        let windows = try decode(json).limitWindows()
        XCTAssertEqual(windows.first?.usedFraction ?? -1, 0.61, accuracy: 0.0001)
        XCTAssertEqual(windows.first?.label, "Scoped")
    }

    /// Trimmed from the real response of an Enterprise seat
    /// (`enterprise_usage_based`, billed through a marketplace). Note what is
    /// *not* there: `limits` is empty and both named windows are null, so
    /// without the spend block such a seat has no reading at all.
    private let enterprise = """
    {
      "limits": [],
      "five_hour": null,
      "seven_day": null,
      "seven_day_opus": null,
      "amber_ladder": { "limit_dollars": 25000, "used_dollars": 0,
                        "remaining_dollars": 25000, "utilization": 0,
                        "resets_at": "2026-10-02T06:59:59.000000+00:00", "locked_reason": null },
      "nimbus_quill": { "limit_dollars": null, "used_dollars": null, "utilization": 0,
                        "resets_at": null, "locked_reason": null },
      "tangelo": null,
      "extra_usage": { "is_enabled": true, "currency": "USD", "monthly_limit": 20000,
                       "used_credits": 297, "utilization": 1.485, "decimal_places": 2 },
      "spend": {
        "enabled": true, "percent": 1, "severity": "normal",
        "limit": { "amount_minor": 20000, "currency": "USD", "exponent": 2 },
        "used":  { "amount_minor": 297, "currency": "USD", "exponent": 2 },
        "cap": { "credits": { "amount_minor": 20000, "exponent": 2 }, "money": null },
        "balance": null, "auto_reload": null, "can_purchase_credits": false
      }
    }
    """

    func testAnEnterpriseSeatReportsItsBalance() throws {
        let windows = try decode(enterprise).limitWindows()
        XCTAssertEqual(windows.map(\.id), ["spend"], "one ring, and only from `spend`")

        let balance = try XCTUnwrap(windows.first)
        let money = try XCTUnwrap(balance.money)
        XCTAssertEqual(money.spent, 2.97, accuracy: 0.000001)
        XCTAssertEqual(money.funded, 200, accuracy: 0.000001)
        XCTAssertEqual(money.currency, "USD")
        // 297/20000, not the `percent: 1` the response rounds it to.
        XCTAssertEqual(balance.usedFraction ?? -1, 0.01485, accuracy: 0.00001)
        XCTAssertNil(balance.resetsAt, "the block carries no reset time")
    }

    /// The ring has to *mean* the balance on a seat that reports only that.
    /// Declaring "session" there left it showing a dash beside a tooltip full
    /// of numbers — the window it named did not exist.
    func testTheBalanceIsTheHeadlineWhenThereIsNoSession() throws {
        let windows = try decode(enterprise).limitWindows()
        XCTAssertEqual(UsageResponse.headlineID(for: windows), "spend")
    }

    /// And on a plan seat nothing moves: the session leads, and a session
    /// merely missing from one response still shows a dash rather than
    /// promoting the weekly into its place.
    func testTheSessionStillLeadsWhereThereIsOne() throws {
        XCTAssertEqual(UsageResponse.headlineID(for: try decode(live).limitWindows()), "session")

        let weeklyOnly = [LimitWindow(id: "weekly_all", label: "All models", usedFraction: 0.3)]
        XCTAssertEqual(UsageResponse.headlineID(for: weeklyOnly), "session",
                       "a weekly percentage must not wear the session's place")
    }

    /// `amber_ladder`, `nimbus_quill` and friends carry `limit_dollars` and
    /// `resets_at` and look exactly like windows. They are internal codenames
    /// whose meaning is not published, and a ring drawn from one would be a
    /// number presented as a limit without anybody knowing which limit.
    func testCodenamedBlocksAreNotReadAsWindows() throws {
        let windows = try decode(enterprise).limitWindows()
        XCTAssertFalse(windows.contains { $0.id.contains("amber") || $0.id.contains("nimbus") })
        XCTAssertFalse(windows.contains { $0.money?.funded == 25000 })
    }

    /// A seat with no credit spending gets no ring rather than one reading
    /// "0 of 0", which would be an invention.
    func testASeatWithoutCreditsHasNoBalanceWindow() throws {
        let json = """
        { "limits": [], "spend": { "enabled": false,
            "limit": { "amount_minor": 0, "currency": "USD", "exponent": 2 },
            "used": { "amount_minor": 0, "currency": "USD", "exponent": 2 } } }
        """
        XCTAssertTrue(try decode(json).limitWindows().isEmpty)
    }

    /// A malformed balance must not cost a plan seat its windows: the spend
    /// block is an extra there, not the reading.
    func testAMalformedSpendBlockDoesNotCostThePlanWindows() throws {
        let json = """
        { "limits": [ { "kind": "session", "percent": 52,
                        "resets_at": "2026-08-28T09:50:00.316290+00:00" } ],
          "spend": "unexpected" }
        """
        XCTAssertEqual(try decode(json).limitWindows().map(\.id), ["session"])
    }

    /// A subscription seat's response has no `spend` block at all, and must
    /// keep reporting exactly what it did before.
    func testASubscriptionSeatIsUnaffected() throws {
        XCTAssertEqual(try decode(live).limitWindows().map(\.id), ["session", "weekly_all"])
    }

    /// On a seat that has both, the balance sorts last: it is not one of the
    /// plan's periods.
    func testTheBalanceSortsAfterThePlansWindows() throws {
        let json = """
        { "limits": [
            { "kind": "weekly_all", "percent": 17,
              "resets_at": "2026-09-02T17:00:00.316321+00:00" },
            { "kind": "session", "percent": 52,
              "resets_at": "2026-08-28T09:50:00.316290+00:00" } ],
          "spend": { "enabled": true,
            "limit": { "amount_minor": 20000, "currency": "USD", "exponent": 2 },
            "used": { "amount_minor": 297, "currency": "USD", "exponent": 2 } } }
        """
        XCTAssertEqual(try decode(json).limitWindows().map(\.id),
                       ["session", "weekly_all", "spend"])
    }

    func testUnknownKindsGetAReadableLabel() {
        XCTAssertEqual(UsageResponse.label(forKind: "weekly_opus"), "Opus")
        XCTAssertEqual(UsageResponse.label(forKind: "weekly_cowork"), "Cowork")
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

    /// A business failure the server named is shown by that name. The status is
    /// 200 either way, so a status is the one thing it cannot be shown by —
    /// which is how every one of them used to read "HTTP 0".
    @MainActor
    func testANamedBusinessFailureReadsAsItsOwnName() {
        XCTAssertEqual(
            UsageStore.statusForTesting(UsageProviderError.apiError("Bad Request")),
            .error("Bad Request")
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

    /// A remembered reading is exactly when "whose numbers are these?" is
    /// hardest to answer, so the plan is kept with it.
    func testThePlanRoundTrips() {
        let defaults = makeDefaults()
        var withPlan = reading
        withPlan.plan = "Enterprise"
        UsageArchive(defaults: defaults).save(["claude": (withPlan, Date())])

        XCTAssertEqual(UsageArchive(defaults: defaults).load()["claude"]?.snapshot.plan, "Enterprise")
    }

    func testCodexDailyUsageRoundTripsWithTheQuotaReading() {
        let defaults = makeDefaults()
        let usage = CodexTokenUsage(
            summary: .init(lifetimeTokens: 90, peakDailyTokens: 90,
                            longestRunningTurnSeconds: 3600,
                            currentStreakDays: 1, longestStreakDays: 3),
            dailyUsageBuckets: [.init(
                startDate: "2026-09-08", tokens: 90
            )]
        )
        let snapshot = ProviderSnapshot(
            id: "codex", displayName: "Codex", glyph: .openai,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "primary", label: "5h limit", usedFraction: 0.2)],
            tokenUsage: usage
        )
        UsageArchive(defaults: defaults).save(["codex": (snapshot, Date())])

        let restored = UsageArchive(defaults: defaults).load()["codex"]?.snapshot
        XCTAssertEqual(restored?.tokenUsage, usage)
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

    func testLegacyPerplexityEntryIsPrunedOnLoad() throws {
        let defaults = makeDefaults()
        let taken = Date(timeIntervalSince1970: 1_787_900_000)
        let perplexity = ProviderSnapshot(
            id: "perplexity", displayName: "Perplexity", glyph: .third,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "queries", label: "Queries", used: 2)]
        )
        struct LegacyEntry: Codable {
            let id: String
            let displayName: String
            let glyph: ProviderGlyph
            let fidelity: Fidelity
            let windows: [LimitWindow]
            let fetchedAt: Date
            let headlineID: String?
            let weeklyID: String?
            let tokenUsage: CodexTokenUsage?
            let usageDetail: ProviderUsageDetail?
            let plan: String?
        }
        let legacy = [
            LegacyEntry(id: "claude", displayName: "Claude", glyph: .claude,
                        fidelity: .official, windows: reading.windows, fetchedAt: taken,
                        headlineID: nil, weeklyID: nil, tokenUsage: nil, usageDetail: nil, plan: nil),
            LegacyEntry(id: "perplexity", displayName: "Perplexity", glyph: .third,
                        fidelity: .official, windows: perplexity.windows, fetchedAt: taken,
                        headlineID: nil, weeklyID: nil, tokenUsage: nil, usageDetail: nil, plan: nil)
        ]
        let data = try JSONEncoder().encode(legacy)
        defaults.set(data, forKey: "lastGoodReadings")

        let loaded = UsageArchive(defaults: defaults).load()
        XCTAssertNil(loaded["perplexity"], "Obsolete perplexity readings must be pruned on load")
        XCTAssertNotNil(loaded["claude"], "Active provider readings must survive")

        // The stored cache in defaults must also be cleaned up immediately
        let savedData = try XCTUnwrap(defaults.data(forKey: "lastGoodReadings"))
        let rawEntries = try JSONDecoder().decode([LegacyEntry].self, from: savedData)
        XCTAssertFalse(rawEntries.contains { $0.id == "perplexity" },
                       "Stored cache in UserDefaults must not retain obsolete perplexity entry")
        XCTAssertEqual(rawEntries.map(\.id), ["claude"])
    }

    func testPerplexityEntryIsNotSavedToArchive() throws {
        let defaults = makeDefaults()
        let taken = Date(timeIntervalSince1970: 1_787_900_000)
        let perplexity = ProviderSnapshot(
            id: "perplexity", displayName: "Perplexity", glyph: .third,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "queries", label: "Queries", used: 2)]
        )
        UsageArchive(defaults: defaults).save([
            "perplexity": (perplexity, taken),
            "claude": (reading, taken)
        ])

        let loaded = UsageArchive(defaults: defaults).load()
        XCTAssertNil(loaded["perplexity"])
        XCTAssertNotNil(loaded["claude"])
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

    /// The moment a limit window rolls over is the moment the reset alert is
    /// owed, and it lands squarely inside the idle stretch — you are not running
    /// anything precisely because you were waiting for it. Waiting out the idle
    /// interval there is what made the alert arrive minutes late.
    @MainActor
    func testARolledOverWindowPollsInsideTheIdleInterval() {
        XCTAssertTrue(UsageStore.shouldRefresh(
            isBusy: false, sinceLastAttempt: 60, idleInterval: idle, resetDue: true
        ))
        XCTAssertFalse(UsageStore.shouldRefresh(
            isBusy: false, sinceLastAttempt: 60, idleInterval: idle, resetDue: false
        ))
    }

    /// The tick is now four times a minute, so "busy" can no longer mean "fetch
    /// on every tick" — that would be four fetches a minute at a provider that
    /// answers a 429. Busy means the busy interval, and nothing shorter.
    @MainActor
    func testBusyPollsAtTheBusyIntervalRatherThanEveryTick() {
        let busy: TimeInterval = 30
        XCTAssertFalse(UsageStore.shouldRefresh(isBusy: true, sinceLastAttempt: 15,
                                                idleInterval: idle, busyInterval: busy))
        XCTAssertTrue(UsageStore.shouldRefresh(isBusy: true, sinceLastAttempt: 30,
                                               idleInterval: idle, busyInterval: busy))
        // And a reset still overrules the wait, busy or not.
        XCTAssertTrue(UsageStore.shouldRefresh(isBusy: true, sinceLastAttempt: 1,
                                               idleInterval: idle, busyInterval: busy,
                                               resetDue: true))
    }

    /// Attention is not a budget: four rings hovered in four seconds is four
    /// looks and one fetch.
    @MainActor
    func testALookIsSpacedFromTheLastFetch() {
        XCTAssertFalse(UsageStore.shouldRefreshOnEvent(sinceLastRefresh: 3, spacing: 15))
        XCTAssertTrue(UsageStore.shouldRefreshOnEvent(sinceLastRefresh: 15, spacing: 15))
        XCTAssertTrue(UsageStore.shouldRefreshOnEvent(sinceLastRefresh: .greatestFiniteMagnitude,
                                                      spacing: 15))
    }

    /// The shipped numbers, held to the shape they claim rather than to
    /// whatever they happen to be: a tick fine enough to express the busy
    /// interval, a busy interval well inside the idle one, and a look spaced by
    /// no more than the busy interval — a look that had to wait longer than the
    /// schedule already does would be worse than not asking.
    @MainActor
    func testTheShippedScheduleHangsTogether() {
        let store = UsageStore(providers: [])
        XCTAssertLessThanOrEqual(store.refreshIntervalForTesting, store.busyRefreshIntervalForTesting)
        XCTAssertLessThan(store.busyRefreshIntervalForTesting, store.idleRefreshIntervalForTesting)
        XCTAssertLessThanOrEqual(store.onLookIntervalForTesting, store.busyRefreshIntervalForTesting)
    }
}

/// What the store is prepared to be told by a cache, and when it is not.
///
/// The schedule above decides how often it asks; this decides what counts as an
/// answer. Both have to be right for a ring to follow a session that is running:
/// a fetch every thirty seconds served from a half-hour-old file is still a
/// half-hour-old number.
final class UsageFreshnessTests: XCTestCase {
    /// Answers anything, and remembers what it was asked for.
    private final class RecordingProvider: UsageProvider, @unchecked Sendable {
        let id = "recorder"
        let displayName = "Recorder"
        let glyph = ProviderGlyph.claude
        private(set) var asked: [UsageFreshness] = []

        func fetchSnapshot() async throws -> ProviderSnapshot {
            try await fetchSnapshot(freshness: .standard)
        }

        func fetchSnapshot(freshness: UsageFreshness) async throws -> ProviderSnapshot {
            asked.append(freshness)
            return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                    fidelity: .official, status: .ok,
                                    windows: [LimitWindow(id: "session", label: "Current session",
                                                          usedFraction: 0.1)])
        }
        nonisolated func account() -> ProviderAccount? { nil }
        nonisolated var signInRoute: SignInRoute { .guidance("") }
        func signOut() async {}
        func presentSignIn() {}
        nonisolated func forgetCachedCredential() {}
    }

    private func makeDefaults() -> UserDefaults {
        let name = "UsageFreshnessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @MainActor
    private func store(_ provider: RecordingProvider) -> UsageStore {
        UsageStore(providers: [provider], archive: UsageArchive(defaults: makeDefaults()))
    }

    /// Nothing is running, so nothing has moved, so a provider's own cache is
    /// the best answer available — free, and not wrong about a still number.
    @MainActor
    func testAnIdleRefreshTakesWhateverTheProviderHasCached() async {
        let provider = RecordingProvider()
        let store = store(provider)
        store.isBusy = { false }

        await store.refresh()

        XCTAssertEqual(provider.asked, [.standard])
    }

    /// Something is running, so the cached number is the one thing it cannot be:
    /// current.
    @MainActor
    func testARefreshWhileBusyWillNotTakeACachedReading() async {
        let provider = RecordingProvider()
        let store = store(provider)
        store.isBusy = { true }

        await store.refresh()

        XCTAssertEqual(provider.asked, [.live])
    }

    /// A look is the least excusable moment to answer from a cache, whether or
    /// not anything is running.
    @MainActor
    func testALookAsksForALiveReading() async {
        let provider = RecordingProvider()
        let store = store(provider)
        store.isBusy = { false }

        store.refreshBecauseSomeoneIsLooking()
        await store.settleForTesting()

        XCTAssertEqual(provider.asked, [.live])
    }

    /// And a second look a moment later is answered by the first one's fetch.
    @MainActor
    func testASecondLookInsideTheSpacingAsksForNothing() async {
        let provider = RecordingProvider()
        let store = store(provider)
        store.isBusy = { false }

        store.refreshBecauseSomeoneIsLooking()
        await store.settleForTesting()
        store.refreshBecauseSomeoneIsLooking()
        await store.settleForTesting()

        XCTAssertEqual(provider.asked.count, 1, "hovering twice cost two fetches")
    }

    /// Work stopping is the falling edge the idle schedule is about to sit on
    /// for five minutes. It gets one fetch, and it is a live one.
    @MainActor
    func testWorkFinishingAsksForALiveReadingOnce() async {
        let provider = RecordingProvider()
        let store = store(provider)

        store.refreshBecauseWorkFinished(providerID: provider.id)
        await store.settleForTesting()
        // A transcript-read session state legitimately flickers; the second edge
        // inside the spacing must not cost a second fetch.
        store.refreshBecauseWorkFinished(providerID: provider.id)
        await store.settleForTesting()

        XCTAssertEqual(provider.asked, [.live])
    }

    /// Refetching one provider is an event, not a schedule, so it asks for now.
    @MainActor
    func testRefreshingOneProviderAsksForALiveReading() async {
        let provider = RecordingProvider()
        let store = store(provider)

        await store.refresh(providerID: provider.id)?.value

        XCTAssertEqual(provider.asked, [.live])
    }

    /// And a caller that is somebody's own click — Refresh now, a ring clicked,
    /// the settings row's refresh — says so, and is answered from nothing held.
    @MainActor
    func testAClickAsksTheSourceItself() async {
        let provider = RecordingProvider()
        let store = store(provider)

        await store.refresh(providerID: provider.id, freshness: .fromSource)?.value

        XCTAssertEqual(provider.asked, [.fromSource])
    }

    // MARK: - Ask the provider every time you look

    /// The setting's whole purpose: a look stops accepting anything a provider
    /// is holding, however new, and asks the provider.
    @MainActor
    func testTheSettingMakesALookAskTheSourceItself() async {
        let provider = RecordingProvider()
        let store = store(provider)
        store.isBusy = { false }
        store.asksProviderOnLook = { true }

        store.refreshBecauseSomeoneIsLooking()
        await store.settleForTesting()

        XCTAssertEqual(provider.asked, [.fromSource])
    }

    /// Off — the shipped default — a look still asks for a live reading, which a
    /// cache newer than a couple of minutes may still answer.
    @MainActor
    func testWithoutTheSettingALookStillAsksForALiveReading() async {
        let provider = RecordingProvider()
        let store = store(provider)
        store.isBusy = { false }

        store.refreshBecauseSomeoneIsLooking()
        await store.settleForTesting()

        XCTAssertEqual(provider.asked, [.live])
    }

    /// It reaches the look and nothing else. A setting that also applied to the
    /// schedule would spend an uncached request every thirty seconds through a
    /// long session, at a provider that answers a 429 — which is how asking for
    /// fresher numbers ends up producing staler ones.
    @MainActor
    func testTheSettingDoesNotReachTheSchedule() async {
        let provider = RecordingProvider()
        let store = store(provider)
        store.isBusy = { true }
        store.asksProviderOnLook = { true }

        await store.refresh()

        XCTAssertEqual(provider.asked, [.live])
    }

    /// The switch is off until somebody turns it on, and stays where it is put.
    @MainActor
    func testTheSettingIsOffByDefaultAndPersists() throws {
        let name = "UsageFreshnessTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let preferences = Preferences(defaults: defaults)
        XCTAssertFalse(preferences.asksProviderOnLook)
        preferences.asksProviderOnLook = true
        XCTAssertTrue(Preferences(defaults: defaults).asksProviderOnLook)
    }
}

/// Which readings count as "a window just turned over". The schedule above is
/// only as prompt as this answer is.
@MainActor
final class WindowRolloverTests: XCTestCase {
    private let last = Date(timeIntervalSince1970: 1_787_900_000)
    private var now: Date { last.addingTimeInterval(60) }

    private func snapshot(resetsAt: Date?...) -> [ProviderSnapshot] {
        [ProviderSnapshot(
            id: "claude", displayName: "Claude", glyph: .claude,
            fidelity: .official, status: .ok,
            windows: resetsAt.enumerated().map { index, date in
                LimitWindow(id: "w\(index)", label: "Current session",
                            usedFraction: 0.68, resetsAt: date)
            }
        )]
    }

    func testAWindowThatTurnedOverSinceTheLastAttemptIsDue() {
        XCTAssertTrue(UsageStore.hasWindowRolledOver(
            in: snapshot(resetsAt: last.addingTimeInterval(30)), since: last, at: now))
    }

    /// The boundary is still ahead: nothing has changed yet, and polling now
    /// would spend a request to be told so.
    func testAWindowStillRunningIsNotDue() {
        XCTAssertFalse(UsageStore.hasWindowRolledOver(
            in: snapshot(resetsAt: now.addingTimeInterval(30)), since: last, at: now))
    }

    /// The one that keeps this from becoming a permanent full-rate poll: once a
    /// refresh has been attempted past the boundary, the same rollover must not
    /// ask for another.
    func testARolloverIsOnlyDueOnce() {
        let windows = snapshot(resetsAt: last.addingTimeInterval(30))
        XCTAssertTrue(UsageStore.hasWindowRolledOver(in: windows, since: last, at: now))
        XCTAssertFalse(UsageStore.hasWindowRolledOver(in: windows, since: now, at: now.addingTimeInterval(60)))
    }

    func testAWindowWithoutAResetTimeIsNeverDue() {
        XCTAssertFalse(UsageStore.hasWindowRolledOver(in: snapshot(resetsAt: nil), since: last, at: now))
    }

    /// A first run has nothing to compare against and must not read a rollover
    /// into a window it is seeing for the first time.
    func testNothingIsDueBeforeTheFirstAttempt() {
        XCTAssertFalse(UsageStore.hasWindowRolledOver(
            in: snapshot(resetsAt: last.addingTimeInterval(30)), since: nil, at: now))
    }

    /// Secondary windows count too: a weekly limit rolling over is the alert
    /// people wait for most, and it is never the headline.
    func testASecondaryWindowCountsAsWell() {
        XCTAssertTrue(UsageStore.hasWindowRolledOver(
            in: snapshot(resetsAt: now.addingTimeInterval(86_400), last.addingTimeInterval(30)),
            since: last, at: now))
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

    /// The second ring resolves the same way the headline does: by the id the
    /// provider declared, not by position.
    func testTheWeeklyRingResolvesTheDeclaredWindow() {
        let snapshot = ProviderSnapshot(
            id: "claude", displayName: "Claude", glyph: .claude,
            fidelity: .official, status: .ok,
            windows: [
                LimitWindow(id: "session", label: "Session", usedFraction: 0.12),
                LimitWindow(id: "weekly_all", label: "All models", usedFraction: 0.91)
            ],
            headlineID: "session", weeklyID: "weekly_all"
        )
        XCTAssertEqual(snapshot.weeklyWindow?.id, "weekly_all")
        XCTAssertEqual(snapshot.weeklyFraction, 0.91)
        XCTAssertEqual(snapshot.usedFraction, 0.12, "the headline is untouched")
    }

    /// A provider that picks its headline by whichever limit is tightest —
    /// Antigravity does — will sometimes land on the weekly one. Two rings
    /// reporting the same number is worse than one: it reads as a second fact
    /// that happens to agree rather than as the same fact drawn twice.
    func testNoSecondRingWhenTheHeadlineIsAlreadyTheWeekly() {
        let snapshot = ProviderSnapshot(
            id: "gemini", displayName: "Antigravity", glyph: .antigravity,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "gemini-weekly", label: "Weekly", usedFraction: 0.8)],
            headlineID: "gemini-weekly", weeklyID: "gemini-weekly"
        )
        XCTAssertNil(snapshot.weeklyWindow)
        XCTAssertNil(snapshot.weeklyFraction)
        XCTAssertEqual(snapshot.headline?.id, "gemini-weekly", "the headline still draws it")
    }

    /// Declared but absent is not an error — the provider simply did not return
    /// that window this time, and one ring is the honest answer.
    func testAMissingWeeklyWindowDrawsNoSecondRing() {
        let snapshot = ProviderSnapshot(
            id: "claude", displayName: "Claude", glyph: .claude,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.2)],
            headlineID: "session", weeklyID: "weekly_all"
        )
        XCTAssertNil(snapshot.weeklyFraction)
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
