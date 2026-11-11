import SQLite3
import XCTest
@testable import Codenotch

final class CodexUsageTests: XCTestCase {
    private func windows(_ json: String) throws -> [LimitWindow] {
        try CodexUsage.windows(from: Data(json.utf8), now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testBothWindowsAreReadWhenBothArePresent() throws {
        let result = try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":25,"limit_window_seconds":18000,"reset_at":1800001000},
          "secondary_window":{"used_percent":10,"limit_window_seconds":604800,"reset_at":1800600000}},
         "additional_rate_limits":[{"limit_name":"Spark","rate_limit":{
          "primary_window":{"used_percent":99,"limit_window_seconds":18000}}}],
         "code_review_rate_limit":{
           "primary_window":{"used_percent":90,"limit_window_seconds":604800},
           "secondary_window":{"used_percent":15,"limit_window_seconds":18000}},
         "credits":{"balance":"100"},"model_usage":{"spark":99}}
        """)
        // Spark is 99% used and listed first in the extras, but the ring
        // follows `windows.first`, which has to stay the main primary.
        XCTAssertEqual(result.map(\.duration), [18000, 604800, 18000, 604800, 18000])
        XCTAssertEqual(result.map(\.id),
                       ["primary", "secondary", "spark", "code-review", "code-review-secondary"])
        XCTAssertEqual(result.map(\.group),
                       [nil, nil, "Spark", "Code review", "Code review"] as [String?])
        XCTAssertEqual(result.map(\.label),
                       ["5h limit", "Weekly limit", "5h limit", "Weekly limit", "5h limit"])
        XCTAssertEqual(result.map(\.usedFraction), [0.25, 0.10, 0.99, 0.90, 0.15])
        XCTAssertEqual(result.first?.id, "primary")
        XCTAssertEqual(result.first?.resetsAt, Date(timeIntervalSince1970: 1_800_001_000))
    }

    /// The reported case: a free-plan account's primary window was 30 days,
    /// not 5 hours or 7 — recorded from a live request. The old parser only
    /// recognised two fixed durations and silently dropped anything else,
    /// which on this exact account meant every window vanished and the ring
    /// reported nothing metered on an account that was genuinely 16% through
    /// a real limit.
    func testAMonthlyPrimaryWindowIsNotDropped() throws {
        let result = try windows("""
        {"rate_limit":{"primary_window":{"used_percent":16,"limit_window_seconds":2592000,
        "reset_after_seconds":1838382,"reset_at":1790585722},"secondary_window":null},
         "plan_type":"free"}
        """)
        XCTAssertEqual(result.map(\.id), ["primary"])
        XCTAssertEqual(CodexUsage.plan(from: Data("""
        {"rate_limit":{"primary_window":{"used_percent":16,"limit_window_seconds":2592000}},
         "plan_type":"free"}
        """.utf8)), "free")
        XCTAssertEqual(result.first?.label, "Monthly limit")
        XCTAssertEqual(result.first?.usedFraction ?? -1, 0.16, accuracy: 0.0001)
    }

    func testPaceUsesTheReportedCycleRegardlessOfPlanName() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for seconds in [18000, 604800, 2592000] {
            let result = try CodexUsage.windows(from: Data("""
            {"rate_limit":{"primary_window":{"used_percent":80,
            "limit_window_seconds":\(seconds),"reset_after_seconds":\(seconds / 2)}}}
            """.utf8), now: now)
            let window = try XCTUnwrap(result.first)
            XCTAssertEqual(window.duration, Double(seconds))
            XCTAssertEqual(try XCTUnwrap(window.usagePace(now: now)).percentagePoints, 30,
                           accuracy: 0.00001)
        }
    }

    /// A duration that is none of the named buckets still gets a usable label
    /// instead of being the thing that makes the fetch fail.
    func testAnUnrecognisedDurationStillGetsALabel() throws {
        let result = try windows("""
        {"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":259200}}}
        """)
        XCTAssertEqual(result.first?.label, "3d limit")
    }

    // The endpoint can put a weekly-only allowance in primary_window.
    func testANullSecondaryIsDropped() throws {
        let result = try windows("""
        {"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":604800,
        "reset_after_seconds":604119,"reset_at":1789308033},"secondary_window":null}}
        """)
        XCTAssertEqual(result.map(\.id), ["primary"])
        XCTAssertEqual(result.first?.label, "Weekly limit")
        XCTAssertEqual(result.first?.resetsAt, Date(timeIntervalSince1970: 1_789_308_033))
    }

    func testStillReadsACountdownIfABuildEmitsOne() throws {
        let result = try windows("""
        {"rate_limit":{
        "primary_window":{"used_percent":8,"limit_window_seconds":604800},
        "secondary_window":{"used_percent":0,"limit_window_seconds":18000,"reset_after_seconds":120}}}
        """)
        XCTAssertEqual(result.map(\.duration), [604800, 18000])
        XCTAssertEqual(result.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(result.first?.usedFraction, 0.08)
        XCTAssertNil(result.first?.resetsAt)
        XCTAssertEqual(result.last?.usedFraction, 0)
        XCTAssertEqual(result.last?.resetsAt, Date(timeIntervalSince1970: 1_800_000_120))
    }

    /// The reported symptom: the tooltip showed only the weekly window and the
    /// ring showed a dash. A null `used_percent` on one window threw the whole
    /// fetch away, so a good weekly window was hidden behind the bad hourly
    /// one. One malformed window is skipped, not fatal.
    func testAWindowMissingUsedPercentIsSkippedRatherThanFailing() throws {
        let result = try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":null,"limit_window_seconds":18000,"reset_at":1800001000},
          "secondary_window":{"used_percent":29,"limit_window_seconds":604800,"reset_at":1800600000}}}
        """)
        XCTAssertEqual(result.map(\.id), ["secondary"])
        XCTAssertEqual(result.first?.label, "Weekly limit")
        XCTAssertEqual(result.first?.usedFraction ?? -1, 0.29, accuracy: 0.0001)
    }

    /// A window without a duration still gets a fallback label instead of
    /// failing the decode of the whole response.
    func testAWindowMissingItsDurationStillParses() throws {
        let result = try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":8,"reset_at":1800001000},
          "secondary_window":{"used_percent":42,"limit_window_seconds":604800,"reset_at":1800600000}}}
        """)
        XCTAssertEqual(result.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(result.first?.label, "Current session")
        XCTAssertEqual(result.last?.label, "Weekly limit")
    }

    /// Both windows malformed is still an error, not an empty success — the
    /// store turns it into "waiting", not a silent 0%. A decode failure used
    /// to surface as `badResponse` instead, which looks like a broken fetch.
    func testBothWindowsMissingLeavesNothingMetered() {
        XCTAssertThrowsError(try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":null,"limit_window_seconds":18000},
          "secondary_window":null}}
        """)) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }

    /// Spark meters a 5-hour window and a weekly one, same lengths as the
    /// main pair. Both belong on the hover card, grouped together. Extras
    /// alone are still a valid reading.
    func testSparkFiveHourAndWeeklyWindowsAreRead() throws {
        let result = try windows("""
        {"additional_rate_limits":[{"limit_name":"Spark","rate_limit":{
          "primary_window":{"used_percent":40,"limit_window_seconds":18000},
          "secondary_window":{"used_percent":70,"limit_window_seconds":604800}}}]}
        """)
        XCTAssertEqual(result.map(\.id), ["spark", "spark-secondary"])
        XCTAssertEqual(result.map(\.group), ["Spark", "Spark"] as [String?])
        XCTAssertEqual(result.map(\.label), ["5h limit", "Weekly limit"])
        XCTAssertEqual(result.map(\.usedFraction), [0.40, 0.70])
    }

    /// An additional limit that is not Spark is not a window we show.
    func testAnUnknownAdditionalLimitIsIgnored() throws {
        let result = try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":25,"limit_window_seconds":18000},
          "secondary_window":{"used_percent":10,"limit_window_seconds":604800}},
         "additional_rate_limits":[{"limit_name":"Credits","rate_limit":{
          "primary_window":{"used_percent":50,"limit_window_seconds":86400}}}]}
        """)
        XCTAssertEqual(result.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(result.map(\.usedFraction), [0.25, 0.10])
    }

    /// A null `used_percent` on Spark must not fail a fetch that already has
    /// a good main pair — same skip rule as the main windows. Code review's
    /// weekly used to vanish with its 5h sibling when that object had no
    /// percent at all.
    func testANullExtraUsedPercentIsSkippedRatherThanFailing() throws {
        let result = try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":25,"limit_window_seconds":18000},
          "secondary_window":{"used_percent":10,"limit_window_seconds":604800}},
         "additional_rate_limits":[{"limit_name":"Spark","rate_limit":{
          "primary_window":{"used_percent":null,"limit_window_seconds":18000},
          "secondary_window":{"used_percent":40,"limit_window_seconds":604800}}}],
         "code_review_rate_limit":{
           "primary_window":{"limit_window_seconds":604800},
           "secondary_window":{"used_percent":8,"limit_window_seconds":18000}}}
        """)
        XCTAssertEqual(result.map(\.id),
                       ["primary", "secondary", "spark-secondary", "code-review-secondary"])
        XCTAssertEqual(result.map(\.group),
                       [nil, nil, "Spark", "Code review"] as [String?])
        XCTAssertEqual(result.map(\.label),
                       ["5h limit", "Weekly limit", "Weekly limit", "5h limit"])
        XCTAssertEqual(result.map(\.usedFraction), [0.25, 0.10, 0.40, 0.08])
    }

    /// An unreadable 5h object (string percent, not a number) used to fail
    /// the whole RateLimit decode, so code review's weekly never appeared.
    func testAMalformedCodeReviewPrimaryDoesNotDropItsSecondary() throws {
        let result = try windows("""
        {"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":18000}},
         "code_review_rate_limit":{
           "primary_window":{"used_percent":"n/a","limit_window_seconds":604800},
           "secondary_window":{"used_percent":8,"limit_window_seconds":18000}}}
        """)
        XCTAssertEqual(result.map(\.id), ["primary", "code-review-secondary"])
        XCTAssertEqual(result.last?.group, "Code review")
        XCTAssertEqual(result.last?.usedFraction ?? -1, 0.08, accuracy: 0.0001)
    }

    /// Same skip rule on the main pair: a non-numeric percent must not turn
    /// a good weekly window (or a good Spark extra) into a failed fetch.
    func testAMalformedMainWindowDoesNotFailTheRest() throws {
        let result = try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":"n/a","limit_window_seconds":18000},
          "secondary_window":{"used_percent":29,"limit_window_seconds":604800}},
         "additional_rate_limits":[{"limit_name":"Spark","rate_limit":{
          "primary_window":{"used_percent":40,"limit_window_seconds":18000}}}]}
        """)
        XCTAssertEqual(result.map(\.id), ["secondary", "spark"])
        XCTAssertEqual(result.first?.id, "secondary")
        XCTAssertEqual(result.map(\.usedFraction), [0.29, 0.40])
    }

    /// An empty additional_rate_limits array is the same as omitting it.
    func testEmptyAdditionalRateLimitsLeaveTheMainWindowsUnchanged() throws {
        let result = try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":25,"limit_window_seconds":18000},
          "secondary_window":{"used_percent":10,"limit_window_seconds":604800}},
         "additional_rate_limits":[]}
        """)
        XCTAssertEqual(result.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(result.map(\.label), ["5h limit", "Weekly limit"])
        XCTAssertEqual(result.map(\.usedFraction), [0.25, 0.10])
        XCTAssertEqual(result.map(\.group), [nil, nil] as [String?])
    }

    /// The additional limit is named after the model, not "Spark", and still
    /// maps to the spark window id — via `limit_name` or `metered_feature`.
    /// Matching only the exact word "spark" used to drop GPT-5.3-Codex-Spark.
    func testGPT53CodexSparkStillMapsToSpark() throws {
        for field in ["limit_name", "metered_feature"] {
            let result = try windows("""
            {"rate_limit":{
              "primary_window":{"used_percent":25,"limit_window_seconds":18000}},
             "additional_rate_limits":[{"\(field)":"GPT-5.3-Codex-Spark","rate_limit":{
              "primary_window":{"used_percent":99,"limit_window_seconds":18000},
              "secondary_window":{"used_percent":5,"limit_window_seconds":604800}}}]}
            """)
            XCTAssertEqual(result.map(\.id), ["primary", "spark", "spark-secondary"], field)
            XCTAssertEqual(result.map(\.group), [nil, "Spark", "Spark"] as [String?], field)
            XCTAssertEqual(result.map(\.label), ["5h limit", "5h limit", "Weekly limit"], field)
            XCTAssertEqual(result.dropFirst().map(\.usedFraction), [0.99, 0.05], field)
        }
    }

    /// Credits and `codex_other` are real extras on some accounts. Showing
    /// them as windows made the hover card grow by a row that has no home.
    func testUnknownExtrasAloneLeaveNothingMetered() {
        XCTAssertThrowsError(try windows("""
        {"additional_rate_limits":[{"limit_name":"Credits","metered_feature":"codex_other",
          "rate_limit":{"primary_window":{"used_percent":50,"limit_window_seconds":86400}}}]}
        """)) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }

    /// Code review with no main pair is still a reading, same as Spark-only.
    func testCodeReviewAloneIsStillMetered() throws {
        let result = try windows("""
        {"code_review_rate_limit":{
          "primary_window":{"used_percent":90,"limit_window_seconds":604800},
          "secondary_window":{"used_percent":15,"limit_window_seconds":18000}}}
        """)
        XCTAssertEqual(result.map(\.id), ["code-review", "code-review-secondary"])
        XCTAssertEqual(result.map(\.group), ["Code review", "Code review"] as [String?])
        XCTAssertEqual(result.map(\.usedFraction), [0.90, 0.15])
    }

    /// Extras listed first in the JSON must not become `windows.first`.
    func testSparkListedBeforeMainStillFollowsTheMainPair() throws {
        let result = try windows("""
        {"additional_rate_limits":[{"limit_name":"Spark","rate_limit":{
          "primary_window":{"used_percent":99,"limit_window_seconds":18000}}}],
         "code_review_rate_limit":{"primary_window":{"used_percent":90,"limit_window_seconds":604800}},
         "rate_limit":{"primary_window":{"used_percent":25,"limit_window_seconds":18000},
          "secondary_window":{"used_percent":10,"limit_window_seconds":604800}}}
        """)
        XCTAssertEqual(result.map(\.id), ["primary", "secondary", "spark", "code-review"])
        XCTAssertEqual(result.first?.id, "primary")
        XCTAssertEqual(result.first?.usedFraction, 0.25)
    }

    /// A payload that names Spark twice (the generic limit and the model
    /// feature) must not emit two 5h rows with the same id. Duplicate ids
    /// make the tooltip ForEach and Phone Link list explode, and the second
    /// ungrouped "5h limit" reads as another session window.
    func testTwoSparkExtrasDoNotDuplicateWindowIDs() throws {
        let result = try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":25,"limit_window_seconds":18000},
          "secondary_window":{"used_percent":10,"limit_window_seconds":604800}},
         "additional_rate_limits":[
           {"limit_name":"Spark","rate_limit":{
             "primary_window":{"used_percent":40,"limit_window_seconds":18000}}},
           {"limit_name":"GPT-5.3-Codex-Spark","metered_feature":"spark","rate_limit":{
             "primary_window":{"used_percent":99,"limit_window_seconds":18000},
             "secondary_window":{"used_percent":12,"limit_window_seconds":604800}}}
         ]}
        """)
        XCTAssertEqual(result.map(\.id), ["primary", "secondary", "spark", "spark-secondary"])
        XCTAssertEqual(Set(result.map(\.id)).count, result.count)
        XCTAssertEqual(result.map(\.group), [nil, nil, "Spark", "Spark"] as [String?])
        XCTAssertEqual(result.map(\.label), ["5h limit", "Weekly limit", "5h limit", "Weekly limit"])
        XCTAssertEqual(result.map(\.usedFraction), [0.25, 0.10, 0.40, 0.12])
    }

    /// Hiding extras must drop Spark and code review rather than leaving an
    /// empty success when those were the only windows.
    func testHidingExtrasDropsSparkAndCodeReview() throws {
        let json = """
        {"rate_limit":{
          "primary_window":{"used_percent":25,"limit_window_seconds":18000},
          "secondary_window":{"used_percent":10,"limit_window_seconds":604800}},
         "additional_rate_limits":[{"limit_name":"Spark","rate_limit":{
          "primary_window":{"used_percent":99,"limit_window_seconds":18000}}}],
         "code_review_rate_limit":{"primary_window":{"used_percent":90,"limit_window_seconds":604800}}}
        """
        let hidden = try CodexUsage.windows(
            from: Data(json.utf8), now: Date(timeIntervalSince1970: 1_800_000_000),
            includeExtras: false
        )
        XCTAssertEqual(hidden.map(\.id), ["primary", "secondary"])
        XCTAssertThrowsError(try CodexUsage.windows(
            from: Data("""
            {"additional_rate_limits":[{"limit_name":"Spark","rate_limit":{
              "primary_window":{"used_percent":40,"limit_window_seconds":18000}}}]}
            """.utf8), includeExtras: false
        ))
    }

    func testDecodesProfileTokenUsageAndBuildsAThirtyDaySeries() throws {
        let json = """
        {"profile":{"display_name":"Test"},
         "stats":{"lifetime_tokens":1200,"peak_daily_tokens":300,
         "longest_running_turn_sec":4020,"current_streak_days":2,"longest_streak_days":11,
         "daily_usage_buckets":[
           {"start_date":"2026-08-12","tokens":100},
           {"start_date":"2026-09-03","tokens":200},
           {"start_date":"2026-09-08","tokens":300}
         ]}}
        """
        let usage = try CodexUsage.profileUsage(from: Data(json.utf8))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 9))!

        XCTAssertEqual(usage.last30Days(now: now, calendar: calendar).count, 30)
        XCTAssertEqual(usage.last30Days(now: now, calendar: calendar).first?.startDate,
                       "2026-08-11")
        XCTAssertEqual(usage.usageInLast30Days(now: now, calendar: calendar), 600)
        XCTAssertEqual(usage.peakDailyTokens, 300)
        XCTAssertEqual(usage.summary?.lifetimeTokens, 1200)
        XCTAssertEqual(usage.summary?.peakDailyTokens, 300)
        XCTAssertEqual(usage.summary?.longestRunningTurnSeconds, 4020)
        XCTAssertEqual(usage.summary?.currentStreakDays, 2)
        XCTAssertEqual(usage.summary?.longestStreakDays, 11)
        XCTAssertEqual(usage.usageToday(now: now, calendar: calendar), nil,
                       "a missing current-day bucket should be shown as Pending")
    }

    /// `/wham/rate-limit-reset-credits` reports how many unused resets remain
    /// and when the next one expires. The count is its own field because the
    /// credits array can be truncated.
    func testResetCreditsReadsAvailableCountAndSoonestExpiry() throws {
        let json = """
        {"credits":[
          {"id":"later","reset_type":"rate_limit","status":"available",
           "granted_at":"2026-09-01T12:00:00Z",
           "expires_at":"2026-09-20T12:00:00.250Z",
           "title":"Reset","description":"Unused reset","extra":true},
          {"id":"spent","reset_type":"rate_limit","status":"redeemed",
           "granted_at":"2026-08-01T00:00:00Z",
           "expires_at":"2026-09-12T00:00:00Z"},
          {"id":"sooner","reset_type":"rate_limit","status":"available",
           "granted_at":"2026-09-02T00:00:00Z",
           "expires_at":"2026-09-15T08:00:00Z"}
         ],
         "available_count":2,
         "server_time":"2026-09-10T00:00:00Z"}
        """
        let result = try CodexUsage.resetCredits(from: Data(json.utf8))
        XCTAssertEqual(result.availableCount, 2)
        XCTAssertEqual(result.credits.map(\.id), ["later", "spent", "sooner"])
        XCTAssertEqual(result.available.map(\.id), ["sooner", "later"])
        XCTAssertEqual(result.nextExpiry, ISO8601DateFormatter().date(from: "2026-09-15T08:00:00Z"))

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(result.available.last?.expiresAt,
                       fractional.date(from: "2026-09-20T12:00:00.250Z"))
    }

    func testResetCreditsTrustsAvailableCountWhenTheArrayIsTruncated() throws {
        let result = try CodexUsage.resetCredits(from: Data("""
        {"available_count":3,"credits":[
          {"id":"only","status":"available","expires_at":"2026-09-18T00:00:00Z"}
        ]}
        """.utf8))
        XCTAssertEqual(result.availableCount, 3)
        XCTAssertEqual(result.credits.map(\.id), ["only"])
        XCTAssertEqual(result.available.count, 1)
        XCTAssertEqual(result.nextExpiry, ISO8601DateFormatter().date(from: "2026-09-18T00:00:00Z"))
    }

    func testResetCreditsCountsAvailableCreditsWhenThePayloadOmitsTheCount() throws {
        let result = try CodexUsage.resetCredits(from: Data("""
        {"credits":[
          {"id":"a","status":"available","expires_at":"2026-09-18T00:00:00Z"},
          {"id":"b","status":"redeemed","expires_at":"2026-09-10T00:00:00Z"}
        ]}
        """.utf8))
        XCTAssertEqual(result.availableCount, 1)
        XCTAssertEqual(result.available.map(\.id), ["a"])
    }

    /// A non-object entry is skipped; an unreadable date becomes no expiry.
    /// None of that is a reason to fail the usage fetch.
    func testResetCreditsSkipsMalformedCreditsRatherThanFailing() throws {
        let result = try CodexUsage.resetCredits(from: Data("""
        {"credits":[
          "nope",
          {"id":"ok","status":"available","expires_at":null}
        ],"available_count":1}
        """.utf8))
        XCTAssertEqual(result.credits.map(\.id), ["ok"])
        XCTAssertNil(result.credits.first?.expiresAt)
        XCTAssertEqual(result.availableCount, 1)
        XCTAssertNil(result.nextExpiry)
    }

    func testResetCreditsThrowsOnlyOnInvalidJSON() throws {
        XCTAssertThrowsError(try CodexUsage.resetCredits(from: Data("not-json".utf8))) { error in
            guard case UsageProviderError.badResponse = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
        XCTAssertEqual(try CodexUsage.resetCredits(from: Data("{}".utf8)).availableCount, 0)
        XCTAssertEqual(try CodexUsage.resetCredits(from: Data("[]".utf8)).credits, [])
    }

    func testAccountUsageCardGetsRoomForTheActivitySection() {
        let plain = NotchLayout.cardHeight(windowCount: 2)
        let withTokens = NotchLayout.cardHeight(windowCount: 2, hasTokenUsage: true)

        XCTAssertGreaterThan(withTokens, plain)
        XCTAssertEqual(
            withTokens - plain,
            NotchLayout.codexUsageTop + NotchLayout.hairline + NotchLayout.blockSpacing
                + NotchLayout.codexMetricTop + NotchLayout.codexMetricHeight
                + NotchLayout.codexMetricBottom
                + NotchLayout.hairline
                + 2 * NotchLayout.cardBodyLineHeight
                + NotchLayout.codexUsageRowGap
                + NotchLayout.codexChartTop + NotchLayout.codexChartHeight,
            accuracy: 0.001
        )
    }

}

/// The activity signal is a heuristic — a rollout written moments ago — so what
/// it will and will not claim is worth pinning down.
@MainActor
final class CodexActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    private func rollout(_ records: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodenotchCodexRollout-\(UUID().uuidString).jsonl")
        try records.joined(separator: "\n").data(using: .utf8)!.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTaskCompleteIsTheSuccessfulTerminalEvent() throws {
        let url = try rollout([
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
        ])
        XCTAssertEqual(CodexRolloutActivity.state(from: url), .success)
    }

    func testChildItemCompletionDoesNotEndTheTask() throws {
        let url = try rollout([
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed"}}"#
        ])
        XCTAssertEqual(CodexRolloutActivity.state(from: url), .busy)
    }

    func testAbortedTurnIsNotSuccessful() throws {
        let url = try rollout([
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#
        ])
        XCTAssertNil(CodexRolloutActivity.state(from: url))
    }

    /// The scan reads the rollout backwards in 256 KB windows; everything
    /// below builds files around that size on purpose.
    private static let windowBytes = 256 * 1024

    private func rollout(data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodenotchCodexRollout-\(UUID().uuidString).jsonl")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A JSONL line of exactly `bytes` that parses as a record but carries no
    /// lifecycle type — the padding the scan has to step over.
    private func filler(_ bytes: Int) -> Data {
        var data = Data(#"{"pad":""#.utf8)
        data.append(contentsOf: [UInt8](repeating: UInt8(ascii: "x"), count: bytes - 11))
        data.append(contentsOf: Data(#""}"#.utf8))
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// Explicit, even though the lifecycle tests above run on small files:
    /// nothing before the windowed scan can be allowed to skip this case.
    func testARolloutSmallerThanOneWindowIsReadWhole() throws {
        let url = try rollout([
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
        ])
        XCTAssertLessThan(
            try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? .max,
            Self.windowBytes
        )
        XCTAssertEqual(CodexRolloutActivity.state(from: url), .success)
    }

    /// The newest 256 KB is all filler; the only lifecycle event sits an
    /// entire window back and still has to be reached.
    func testAnEventInAnEarlierWindowIsStillFound() throws {
        var data = Data(#"{"type":"event_msg","payload":{"type":"task_complete"}}"#.utf8)
        data.append(UInt8(ascii: "\n"))
        data.append(filler(Self.windowBytes + 10_000))
        let url = try rollout(data: data)
        XCTAssertEqual(CodexRolloutActivity.state(from: url), .success)
    }

    /// The window boundary cuts a line in half; the fragment is carried into
    /// the earlier window, where the rest of the line lives. Without the
    /// carry this event is silently lost.
    func testALifecycleLineCutByTheWindowBoundaryIsReassembled() throws {
        let event = Data(#"{"type":"event_msg","payload":{"type":"task_complete"}}"#.utf8)
        var data = filler(970)              // the event starts at offset 970
        data.append(event)
        data.append(UInt8(ascii: "\n"))
        data.append(filler(Self.windowBytes + 1000 - data.count))

        let boundary = data.count - Self.windowBytes
        XCTAssertTrue(970 < boundary && boundary < 970 + event.count,
                      "the fixture must place the event across the boundary")

        let url = try rollout(data: data)
        XCTAssertEqual(CodexRolloutActivity.state(from: url), .success)
    }

    /// The boundary falls exactly on a newline: the window's first line is
    /// whole, and the earlier window's last line ends without its newline.
    /// Carrying that whole line back glued the two into one line of invalid
    /// JSON, and the event before the boundary was lost.
    func testALineEndingExactlyOnTheWindowBoundaryIsNotGluedToTheNext() throws {
        let event = Data(#"{"type":"event_msg","payload":{"type":"task_complete"}}"#.utf8)
        var data = filler(970)
        data.append(event)
        let newline = data.count           // the event's own newline sits here
        data.append(UInt8(ascii: "\n"))
        data.append(filler(Self.windowBytes - 1))

        XCTAssertEqual(data.count - Self.windowBytes, newline,
                       "the fixture must put the event's newline exactly on the boundary")

        let url = try rollout(data: data)
        XCTAssertEqual(CodexRolloutActivity.state(from: url), .success)
    }

    /// The tail of a live rollout is often half a line — the writer was
    /// mid-append when the tick landed. It must not eat the event behind it.
    func testAHalfWrittenTailLineDoesNotHideTheEventBehindIt() throws {
        var data = Data(#"{"type":"event_msg","payload":{"type":"task_complete"}}"#.utf8)
        data.append(UInt8(ascii: "\n"))
        data.append(Data(#"{"type":"event_msg","payload":{"ty"#.utf8))
        let url = try rollout(data: data)
        XCTAssertEqual(CodexRolloutActivity.state(from: url), .success)
    }

    /// Deliberate, and stated in the PR: a lifecycle event further than four
    /// windows (1 MB) from the end is never seen — the scan stays bounded so
    /// a mid-turn rollout's far-behind `task_started` is never paid for.
    func testAnEventBeyondTheScanCapIsNotFound() throws {
        var data = Data(#"{"type":"event_msg","payload":{"type":"task_complete"}}"#.utf8)
        data.append(UInt8(ascii: "\n"))
        data.append(filler(4 * Self.windowBytes + 100))
        let url = try rollout(data: data)
        XCTAssertNil(CodexRolloutActivity.state(from: url))
    }

    func testARolloutWrittenJustNowIsBusy() throws {
        let s = try XCTUnwrap(CodexActivityMonitor.session(
            id: "codex.x", name: "Codex",
            modified: now.addingTimeInterval(-2), staleAfter: 8, now: now
        ))
        XCTAssertEqual(s.state, .busy)
        XCTAssertEqual(s.name, "Codex")
    }

    /// It errs short on purpose: a stale rollout must not keep the ring spinning
    /// or be mistaken for a completed turn.
    func testAnOlderRolloutIsNotActivity() {
        XCTAssertNil(CodexActivityMonitor.session(
            id: "codex.x", name: "Codex",
            modified: now.addingTimeInterval(-30), staleAfter: 8, now: now
        ))
    }

    func testTheBoundaryIsInclusive() {
        XCTAssertEqual(CodexActivityMonitor.session(
            id: "codex.x", name: "Codex",
            modified: now.addingTimeInterval(-8), staleAfter: 8, now: now
        )?.state, .busy)

        XCTAssertNil(CodexActivityMonitor.session(
            id: "codex.x", name: "Codex",
            modified: now.addingTimeInterval(-15), staleAfter: 8, now: now
        ))

        XCTAssertNil(CodexActivityMonitor.session(
            id: "codex.x", name: "Codex",
            modified: now.addingTimeInterval(-24), staleAfter: 8, now: now
        ))
    }
}

/// "Codex" is two programs. The CLI and the VS Code extension append to a
/// rollout under `~/.codex/sessions`; the desktop app — ChatGPT.app, which is
/// what most people now mean — writes none of them, keeping its threads in
/// `~/.codex/sqlite/codex-dev.db` instead.
///
/// The activity monitor watched only the rollouts, so it could never see the
/// desktop app working: on this machine every rollout was written by VS Code
/// and the newest was three days old, while the desktop catalogue had been
/// touched seconds ago. The ring simply never span.
final class CodexDesktopActivityTests: XCTestCase {
    private let store = URL(fileURLWithPath: "/tmp/codex-desktop-test.db")

    private func makeCatalogue(rows: [(Double, String)]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-dev-\(UUID().uuidString).db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, """
            CREATE TABLE local_thread_catalog (
                thread_id TEXT, display_title TEXT NOT NULL,
                source_updated_at REAL NOT NULL, source_kind TEXT);
            """, nil, nil, nil)
        for (at, title) in rows {
            sqlite3_exec(db, """
                INSERT INTO local_thread_catalog
                (thread_id, display_title, source_updated_at, source_kind)
                VALUES ('t', '\(title)', \(at), 'chatgpt');
                """, nil, nil, nil)
        }
        return url
    }

    func testItReadsTheNewestDesktopThread() throws {
        let url = try makeCatalogue(rows: [(1_788_000_000, "Older"),
                                           (1_788_582_173.099, "Deep SaaS Research")])
        defer { try? FileManager.default.removeItem(at: url) }

        let newest = try XCTUnwrap(CodexStore.newestDesktopThread(in: url))
        XCTAssertEqual(newest.title, "Deep SaaS Research")
        // Seconds with a fraction, not the milliseconds the `threads` table
        // next door uses — reading it as milliseconds puts it in 1970.
        XCTAssertEqual(newest.updatedAt.timeIntervalSince1970, 1_788_582_173.099, accuracy: 0.01)
    }

    /// The reported symptom: the desktop app is working now, the rollouts are
    /// days old, and the ring has to spin.
    @MainActor func testDesktopWorkCountsAsActivity() throws {
        let now = Date()
        let url = try makeCatalogue(rows: [(now.addingTimeInterval(-2).timeIntervalSince1970,
                                            "Deep SaaS Research")])
        defer { try? FileManager.default.removeItem(at: url) }

        // No rollout store at all, which is the case for someone who has only
        // ever used the desktop app.
        let sessions = CodexActivityMonitor.read(
            stateStore: URL(fileURLWithPath: "/nonexistent/state.sqlite"),
            desktopStore: url, staleAfter: 8, now: now
        )
        XCTAssertEqual(sessions.count, 1, "the desktop app's work was invisible")
        XCTAssertEqual(sessions.first?.state, .busy)
        XCTAssertEqual(sessions.first?.name, "Deep SaaS Research",
                       "the thread's own name is more use than \"Codex\"")
    }

    /// And it still errs short: a finished conversation must not keep spinning.
    @MainActor func testAnOldDesktopThreadIsNotActivity() throws {
        let now = Date()
        let url = try makeCatalogue(rows: [(now.addingTimeInterval(-600).timeIntervalSince1970,
                                            "Yesterday's chat")])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(CodexActivityMonitor.read(
            stateStore: URL(fileURLWithPath: "/nonexistent/state.sqlite"),
            desktopStore: url, staleAfter: 8, now: now
        ).isEmpty)
    }

    func testAMissingCatalogueIsNotAnError() {
        XCTAssertNil(CodexStore.newestDesktopThread(
            in: URL(fileURLWithPath: "/nonexistent/codex-dev.db")
        ))
    }
}

/// `CodexStoreCache` answers from memory while the store's `(mtime, size)`
/// stamp holds — these pin down when the cached answer stands and when the
/// database is opened again, since a stale one would keep showing a session
/// that moved on.
final class CodexStoreCacheTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodenotchStoreCache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A store of the shape `CodexStore.newestRollout` reads. Small pages and
    /// a `pad` column so a later `INSERT` is guaranteed to grow the file —
    /// otherwise a new row can fit inside a page the file already had and
    /// the size half of the stamp never moves.
    private func makeStore(rollouts: [(path: String, updatedMs: Int)]) throws -> URL {
        let url = dir.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "PRAGMA page_size=512", nil, nil, nil)
        sqlite3_exec(db, """
            CREATE TABLE threads (rollout_path TEXT, archived INTEGER,
                                  updated_at_ms INTEGER, pad TEXT)
            """, nil, nil, nil)
        for (path, ms) in rollouts {
            sqlite3_exec(db, "INSERT INTO threads VALUES ('\(path)', 0, \(ms), '')",
                         nil, nil, nil)
        }
        return url
    }

    private func updateStore(_ url: URL, sql: String) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    private func rolloutFile(_ name: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try Data().write(to: url)
        return url.path
    }

    private func size(of url: URL) throws -> UInt64 {
        ((try FileManager.default.attributesOfItem(atPath: url.path))[.size]
            as? NSNumber)?.uint64Value ?? 0
    }

    /// `setAttributes`, not a real write's timestamp: the stamp compares
    /// `Date`s exactly, so both calls must land the same value rather than
    /// trusting the filesystem to round-trip one.
    private func setMtime(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date],
                                              ofItemAtPath: url.path)
    }

    private let epoch = Date(timeIntervalSince1970: 1_788_000_000)

    func testAnUnchangedStoreAnswersFromCache() throws {
        // Same-length paths: the update below cannot change the file's size,
        // so only the stamp is being exercised.
        let pathA = try rolloutFile("a.jsonl")
        let pathB = try rolloutFile("b.jsonl")
        XCTAssertEqual(pathA.count, pathB.count)
        let store = try makeStore(rollouts: [(pathA, 2), (pathB, 1)])
        try setMtime(epoch, of: store)

        let cache = CodexStoreCache()
        XCTAssertEqual(cache.newestRollout(in: store)?.path, pathA)

        let sizeBefore = try size(of: store)
        updateStore(store, sql: "UPDATE threads SET rollout_path='\(pathB)' WHERE updated_at_ms=2")
        try setMtime(epoch, of: store)
        XCTAssertEqual(try size(of: store), sizeBefore,
                       "the fixture must keep the size identical for the stamp to hold")

        XCTAssertEqual(cache.newestRollout(in: store)?.path, pathA,
                       "same (mtime, size) — the cached answer must stand")
    }

    func testAnMtimeChangeRescans() throws {
        let pathA = try rolloutFile("a.jsonl")
        let pathB = try rolloutFile("b.jsonl")
        XCTAssertEqual(pathA.count, pathB.count)
        let store = try makeStore(rollouts: [(pathA, 2), (pathB, 1)])
        try setMtime(epoch, of: store)

        let cache = CodexStoreCache()
        XCTAssertEqual(cache.newestRollout(in: store)?.path, pathA)

        updateStore(store, sql: "UPDATE threads SET rollout_path='\(pathB)' WHERE updated_at_ms=2")
        try setMtime(epoch.addingTimeInterval(60), of: store)

        XCTAssertEqual(cache.newestRollout(in: store)?.path, pathB,
                       "a moved mtime is a changed store")
    }

    func testASizeChangeAloneRescans() throws {
        let pathA = try rolloutFile("a.jsonl")
        let pathB = try rolloutFile("b.jsonl")
        let pathC = try rolloutFile("c.jsonl")
        let store = try makeStore(rollouts: [(pathA, 2), (pathB, 1)])
        try setMtime(epoch, of: store)

        let cache = CodexStoreCache()
        XCTAssertEqual(cache.newestRollout(in: store)?.path, pathA)

        // Mtime pinned back to what the stamp recorded; only the size moved.
        let pad = String(repeating: "x", count: 4096)
        updateStore(store, sql: "INSERT INTO threads VALUES ('\(pathC)', 0, 3, '\(pad)')")
        try setMtime(epoch, of: store)

        XCTAssertEqual(cache.newestRollout(in: store)?.path, pathC,
                       "a grown file is a changed store even at the same mtime")
    }

    /// Codex's writes land in the `-wal` before the database proper — the
    /// main file's mtime only moves at checkpoint — so the stamp has to see
    /// the wal, or writes between checkpoints are invisible to it.
    func testAWalChangeAloneRescans() throws {
        let pathA = try rolloutFile("a.jsonl")
        let pathB = try rolloutFile("b.jsonl")
        XCTAssertEqual(pathA.count, pathB.count)
        let store = try makeStore(rollouts: [(pathA, 2), (pathB, 1)])
        try setMtime(epoch, of: store)

        let cache = CodexStoreCache()
        XCTAssertEqual(cache.newestRollout(in: store)?.path, pathA)

        updateStore(store, sql: "UPDATE threads SET rollout_path='\(pathB)' WHERE updated_at_ms=2")
        try setMtime(epoch, of: store)
        XCTAssertEqual(cache.newestRollout(in: store)?.path, pathA,
                       "database stamp unchanged — still cached")

        // The store was built in the default rollback journal mode, so this
        // stray file is never opened by SQLite — only its stat matters.
        try Data("wal".utf8).write(to: URL(fileURLWithPath: store.path + "-wal"))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: store.path + "-wal") }
        XCTAssertEqual(cache.newestRollout(in: store)?.path, pathB)
    }

    /// A cached rollout path whose file has gone away is asked for again —
    /// the next row down may still exist.
    func testACachedPathWhoseFileIsGoneIsAskedForAgain() throws {
        let pathA = try rolloutFile("a.jsonl")
        let pathB = try rolloutFile("b.jsonl")
        let store = try makeStore(rollouts: [(pathA, 2), (pathB, 1)])
        try setMtime(epoch, of: store)

        let cache = CodexStoreCache()
        XCTAssertEqual(cache.newestRollout(in: store)?.path, pathA)

        try FileManager.default.removeItem(atPath: pathA)
        XCTAssertEqual(cache.newestRollout(in: store)?.path, pathB)
    }

    /// The desktop catalogue has no file to re-check — the stamp is the
    /// whole gate, in both directions.
    func testTheDesktopCatalogueFollowsTheSameStamp() throws {
        let store = dir.appendingPathComponent("codex-dev.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.path, &db), SQLITE_OK)
        sqlite3_exec(db, """
            CREATE TABLE local_thread_catalog (
                thread_id TEXT, display_title TEXT NOT NULL,
                source_updated_at REAL NOT NULL, source_kind TEXT)
            """, nil, nil, nil)
        sqlite3_exec(db, """
            INSERT INTO local_thread_catalog
            VALUES ('t', 'First', 1788582173.0, 'chatgpt')
            """, nil, nil, nil)
        sqlite3_close(db)
        try setMtime(epoch, of: store)

        let cache = CodexStoreCache()
        XCTAssertEqual(cache.newestDesktopThread(in: store)?.title, "First")

        // 'First' and 'Other' are the same length: size cannot move.
        updateStore(store, sql: "UPDATE local_thread_catalog SET display_title='Other' WHERE thread_id='t'")
        try setMtime(epoch, of: store)
        XCTAssertEqual(cache.newestDesktopThread(in: store)?.title, "First",
                       "unchanged stamp — the cached row must stand")

        try setMtime(epoch.addingTimeInterval(60), of: store)
        XCTAssertEqual(cache.newestDesktopThread(in: store)?.title, "Other")
    }
}

final class UsageBlockTests: XCTestCase {
    /// The wording the vendor's own banner uses — a clock time, not a
    /// countdown, because that is the thing you are waiting for.
    func testItReadsAsAClockTime() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let block = UsageBlock(reason: "Paused", resetsAt: now.addingTimeInterval(90 * 60))
        let text = block.summary(now: now)
        XCTAssertTrue(text.hasPrefix("Paused until "), text)
        XCTAssertFalse(text.contains("min"), "a countdown, not the time it lifts")
    }

    /// The clock keeps the locale's hour cycle, as the reset line does: a
    /// 24-hour region reads "Paused until 16:13", not "4:13 PM".
    func testTheClockFollowsTheLocalesHourCycle() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let block = UsageBlock(reason: "Paused", resetsAt: now.addingTimeInterval(90 * 60))
        for id in ["fr_FR", "de_DE", "ja_JP", "en_GB"] {
            let locale = Locale(identifier: id)
            let text = block.summary(now: now, locale: locale)
            let symbols = DateFormatter()
            symbols.locale = locale
            XCTAssertFalse(text.contains(symbols.amSymbol) || text.contains(symbols.pmSymbol),
                           "\(id) got a 12-hour clock: \(text)")
        }
        let american = block.summary(now: now, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(american.contains("AM") || american.contains("PM"),
                      "en_US lost its AM/PM: \(american)")
    }

    /// With no reset time there is nothing to promise, so it says only what it
    /// knows.
    func testWithoutAResetItSaysOnlyTheReason() {
        XCTAssertEqual(UsageBlock(reason: "Paused", resetsAt: nil).summary(), "Paused")
    }

    /// A reset already in the past is not worth showing as a deadline.
    func testAPastResetIsDropped() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let block = UsageBlock(reason: "Paused", resetsAt: now.addingTimeInterval(-60))
        XCTAssertEqual(block.summary(now: now), "Paused")
    }

    /// The card has to be tall enough for the line, or it is clipped — the same
    /// mistake the status message made.
    func testTheCardMakesRoomForIt() {
        let plain = NotchLayout.cardHeight(windowCount: 1)
        let blocked = NotchLayout.cardHeight(windowCount: 1,
                                             blockMessage: "Paused until 4:13 PM")
        XCTAssertGreaterThan(blocked, plain, "the blocked line has no room to be drawn in")
    }

    /// And a long one gets the room it actually needs.
    func testALongBlockMessageGetsMoreThanOneLine() {
        let long = "Workspace limit reached until Thu 4:13 PM — every seat on this "
                 + "workspace shares one allowance and it is spent"
        XCTAssertGreaterThan(NotchLayout.bodyTextHeight(long),
                             NotchLayout.cardBodyLineHeight)
        XCTAssertGreaterThan(
            NotchLayout.cardHeight(windowCount: 1, blockMessage: long),
            NotchLayout.cardHeight(windowCount: 1, blockMessage: "Paused")
        )
    }
}

/// A Codex row named for the conversation it is, and one row per conversation.
///
/// Every Codex row used to say "Codex": one row at most, the newest rollout or
/// the newest desktop thread, while the Claude rows beside it named every
/// session. Codex names its conversations in the same `threads` row the rollout
/// path was already read from; `codex exec` threads, which it never names, still
/// have the request itself to go on.
@MainActor
final class CodexConversationTests: XCTestCase {
    private var dir: URL!
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexConversationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - What a conversation is called

    func testANamedConversationIsDrawnUnderItsName() throws {
        let store = try makeStore([
            thread("a", name: "Fix the flaky login test", preview: "hey, the login test…",
                   written: 1),
        ])
        XCTAssertEqual(read(store).map(\.name), ["Fix the flaky login test"])
    }

    /// `codex exec` never names a thread. The request itself is the next best
    /// thing — and far better than "Codex".
    func testAnUnnamedConversationShowsItsRequest() throws {
        let store = try makeStore([
            thread("a", name: nil, preview: "Render the product shot for the landing page",
                   written: 1),
        ])
        XCTAssertEqual(read(store).map(\.name), ["Render the product shot for the landing page"])
    }

    func testARequestIsCutToOneLine() {
        XCTAssertEqual(CodexThread.firstLine("\n\n  First   line  \nsecond line"), "First line")
        let long = String(repeating: "word ", count: 30)
        let cut = try? XCTUnwrap(CodexThread.firstLine(long))
        XCTAssertEqual(cut?.count, CodexThread.longestPreview)
        XCTAssertEqual(cut?.last, "…")
        XCTAssertNil(CodexThread.firstLine(" \n \t "))
    }

    /// Name, then request, then folder — the folder is all a Claude session
    /// falls back to — and only then the provider's own name.
    func testTheLabelFallsBackInOrder() {
        func label(name: String?, preview: String?, cwd: String?) -> String {
            CodexThread(id: "a", rollout: nil, name: name, preview: preview,
                        cwd: cwd, parentID: nil, isHelper: false).label(fallback: "Codex")
        }
        XCTAssertEqual(label(name: "Named", preview: "asked", cwd: "/p/app"), "Named")
        XCTAssertEqual(label(name: nil, preview: "asked", cwd: "/p/app"), "asked")
        XCTAssertEqual(label(name: nil, preview: nil, cwd: "/p/app"), "app")
        XCTAssertEqual(label(name: nil, preview: nil, cwd: nil), "Codex")
        XCTAssertEqual(label(name: nil, preview: nil, cwd: "/"), "Codex")
    }

    /// A store from before `name` existed must still be read — a query naming
    /// a missing column fails outright, and would lose the rollout too.
    func testAStoreWithoutTheNewColumnsStillReads() throws {
        let rollout = try rolloutFile("old", written: 1)
        let url = dir.appendingPathComponent("state_5.sqlite")
        try exec(url, "CREATE TABLE threads (rollout_path TEXT, archived INTEGER, updated_at_ms INTEGER)")
        try exec(url, "INSERT INTO threads VALUES ('\(rollout.path)', 0, 1)")

        XCTAssertEqual(read(url).map(\.name), ["Codex"])
    }

    // MARK: - One row per conversation

    func testTwoConversationsAreTwoRows() throws {
        let store = try makeStore([
            thread("a", name: "Refactor the parser", written: 1),
            thread("b", name: "Write the release notes", written: 3),
        ])
        XCTAssertEqual(read(store).map(\.name), ["Refactor the parser", "Write the release notes"],
                       "newest first, and both of them")
    }

    func testAConversationThatStoppedIsNotDrawn() throws {
        let store = try makeStore([
            thread("a", name: "Working", written: 1),
            thread("b", name: "Finished an hour ago", written: 3_600),
        ])
        XCTAssertEqual(read(store).map(\.name), ["Working"])
    }

    // MARK: - Sub-agents

    /// A helper's work is its conversation's work: one row, the conversation's
    /// name, for as long as the helper is moving — even while the parent,
    /// waiting on it, writes nothing.
    func testAHelperIsCreditedToItsConversation() throws {
        let store = try makeStore([
            thread("root", name: "Audit the checkout flow", written: 600),
            thread("helper", name: nil, preview: "You are Locke. Read the cart code…",
                   parent: "root", written: 1),
        ])
        let rows = read(store)
        XCTAssertEqual(rows.map(\.name), ["Audit the checkout flow"])
        XCTAssertEqual(rows.first?.state, .busy)
    }

    /// And a helper finishing is not the conversation finishing — reading the
    /// helper's `task_complete` as the row's state would announce "Complete"
    /// for work still under way.
    func testAHelperFinishingIsNotTheConversationFinishing() throws {
        let store = try makeStore([
            thread("root", name: "Audit the checkout flow", written: 600),
            thread("helper", name: nil, parent: "root", written: 1, events: ["task_complete"]),
        ])
        XCTAssertEqual(read(store).first?.state, .busy)
    }

    func testTheConversationItselfFinishingIsStillComplete() throws {
        let store = try makeStore([
            thread("a", name: "Done", written: 1, events: ["task_started", "task_complete"]),
        ])
        XCTAssertEqual(read(store).first?.state, .success)
    }

    /// Two helpers of one request are still one row.
    func testHelpersOfOneRequestAreOneRow() throws {
        let store = try makeStore([
            thread("root", name: "Audit", written: 2),
            thread("h1", name: nil, parent: "root", written: 1),
            thread("h2", name: nil, parent: "h1", written: 1),
        ])
        XCTAssertEqual(read(store).map(\.name), ["Audit"])
    }

    /// The parent need not be recent enough to make the page of recent threads;
    /// it is fetched by id.
    func testAParentOutsideTheRecentPageIsFound() throws {
        let store = try makeStore([
            thread("root", name: "Long request", written: 900, updatedMs: 1),
            thread("helper", name: nil, parent: "root", written: 1, updatedMs: 2),
        ])
        let threads = CodexStore.recentThreads(in: store, limit: 1)
        XCTAssertEqual(Set(threads.map(\.id)), ["root", "helper"])
    }

    /// The parent id comes out of JSON another program writes. It is checked
    /// before it goes anywhere near a query.
    func testAParentIDThatIsNotAnIDIsNeverQueried() {
        XCTAssertTrue(CodexThread.isPlainID("019a2b3c-04ea-7ff1-8e28-ad54546e1fbc"))
        XCTAssertFalse(CodexThread.isPlainID("x') OR ('1'='1"))
        XCTAssertFalse(CodexThread.isPlainID(""))
        XCTAssertFalse(CodexThread.isPlainID("çà"))
    }

    // MARK: - The desktop app's copy

    /// The desktop app keeps its own catalogue, and a conversation open in both
    /// it and the CLI or VS Code is in both under the same id — checked on a
    /// real machine: ten of forty-three. Drawn from each, it would be two rows.
    func testTheDesktopCopyOfALiveConversationIsNotDrawnAgain() throws {
        let store = try makeStore([thread("shared", name: "Shared conversation", written: 1)])
        let catalogue = try makeCatalogue(title: "Shared conversation", threadID: "shared")

        let rows = CodexActivityMonitor.read(stateStore: store, desktopStore: catalogue,
                                             staleAfter: 8, now: now)
        XCTAssertEqual(rows.map(\.name), ["Shared conversation"])
    }

    func testADifferentDesktopConversationIsStillDrawn() throws {
        let store = try makeStore([thread("cli", name: "In the terminal", written: 1)])
        let catalogue = try makeCatalogue(title: "In the desktop app", threadID: "desktop-only")

        let rows = CodexActivityMonitor.read(stateStore: store, desktopStore: catalogue,
                                             staleAfter: 8, now: now)
        XCTAssertEqual(Set(rows.map(\.name)), ["In the terminal", "In the desktop app"])
    }

    // MARK: - Guardians

    /// Auto-review runs a guardian to vet each action. Its `threads` row says
    /// only `{"subagent":{"other":"guardian"}}` — no parent — and taken for a
    /// conversation it drew a row of its own named after its prompt. Its
    /// rollout's opening line says whose review it is. (The real line here is
    /// tens of kilobytes; the fixture's spans more than one read.)
    func testAGuardianIsCreditedToTheConversationItReviews() throws {
        let store = try makeStore([
            thread("root", name: "Redo the apartment spec", written: 600),
            thread("guardian", name: nil, preview: "The following is the Codex agent history",
                   guardianOf: "root", written: 1),
        ])
        XCTAssertEqual(read(store).map(\.name), ["Redo the apartment spec"])
    }

    /// A review finishing is not the request finishing: on a real machine one
    /// guardian ran six reviews in forty minutes, each ending in
    /// `task_complete` while the conversation was mid-turn.
    func testAGuardianFinishingDoesNotCompleteTheConversation() throws {
        let store = try makeStore([
            thread("root", name: "Redo the apartment spec", written: 600),
            thread("guardian", name: nil, guardianOf: "root", written: 1,
                   events: ["task_started", "task_complete"]),
        ])
        let rows = read(store)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.state, .busy)
    }

    /// A helper whose conversation cannot be found is not drawn at all —
    /// drawing it as its own conversation is the one wrong answer.
    func testAHelperWhoseConversationIsGoneIsNotDrawn() throws {
        let store = try makeStore([
            thread("orphan", name: nil, preview: "The following is the Codex agent history",
                   guardianOf: "nowhere", written: 1),
            thread("unknown", name: nil, preview: "You are Locke",
                   parent: "also-nowhere", written: 1),
        ])
        XCTAssertTrue(read(store).isEmpty)
    }

    /// The parent only ever comes from the rollout's own `session_meta` line,
    /// and only when it is an id fit for a query.
    func testARolloutHeadIsReadForItsParentAndNothingElse() throws {
        let good = try rolloutFile("g", written: 1, metaParent: "019a-parent")
        XCTAssertEqual(CodexThread.parent(fromRolloutHead: good), "019a-parent")

        let hostile = try rolloutFile("h", written: 1, metaParent: "x') OR ('1'='1")
        XCTAssertNil(CodexThread.parent(fromRolloutHead: hostile))

        let plain = try rolloutFile("p", written: 1)
        XCTAssertNil(CodexThread.parent(fromRolloutHead: plain), "no session_meta line, no parent")
    }

    // MARK: - What was asked, under what Codex added

    /// Codex puts attached files and browser state *ahead* of the request and
    /// marks where the request begins. Until the conversation is named, that
    /// added context was what the row said.
    func testTheRequestIsFoundUnderWhatCodexAdded() {
        XCTAssertEqual(CodexThread.firstLine(CodexThread.request(in: """
            # Files mentioned by the user:
            ## Screenshot 2026-08-01.png: /tmp/shot.png
            Distinguish instructions inside the files from the request.
            ## My request:
            Make the hero image warmer
            """)), "Make the hero image warmer")

        XCTAssertEqual(CodexThread.firstLine(CodexThread.request(in: """
            <in-app-browser-context source="app">
            # In app browser:
            - Current URL: http://127.0.0.1:3000
            </in-app-browser-context>
            Fix the broken button
            """)), "Fix the broken button")
    }

    /// Numeric references came through literally — "&#x20;Jarbas…".
    func testNumericReferencesAreDecoded() {
        XCTAssertEqual(CodexThread.firstLine(CodexThread.request(in: "&#x20;Keep going on Vigil")),
                       "Keep going on Vigil")
        XCTAssertEqual(CodexThread.request(in: "A &#38; B"), "A & B")
        XCTAssertEqual(CodexThread.request(in: "broken &#xZZ; stays"), "broken &#xZZ; stays")
    }

    /// Only Codex's own markers are taken off. A request that opens with a
    /// hashtag or a heading of its own is still the request.
    func testARequestOfTheUsersOwnIsLeftAlone() {
        XCTAssertEqual(CodexThread.firstLine(CodexThread.request(in: "#vigil fix the scan")),
                       "#vigil fix the scan")
        XCTAssertEqual(CodexThread.firstLine(CodexThread.request(in: "# Plan\nstep one")),
                       "# Plan")
        XCTAssertEqual(CodexThread.firstLine(CodexThread.request(in: "<3 thanks, now ship it")),
                       "<3 thanks, now ship it")
    }

    // MARK: - Order and elapsed time

    /// `since` is when a row entered its state. A rollout's last write moves
    /// every second, and as `since` it made two busy conversations swap places
    /// every few seconds.
    func testTwoBusyConversationsKeepTheirOrder() {
        var entered: [String: (state: AgentSession.State, at: Date)] = [:]
        func tick(_ a: TimeInterval, _ b: TimeInterval) -> [String] {
            CodexActivityMonitor.settled([
                session("a", .busy, since: now.addingTimeInterval(a)),
                session("b", .busy, since: now.addingTimeInterval(b)),
            ], entered: &entered).map(\.id)
        }
        let first = tick(-1, -3)
        XCTAssertEqual(tick(-3, -1), first, "b wrote last, and must not jump ahead")
        XCTAssertEqual(tick(-2, -1), first)
    }

    func testANewStateStartsANewClock() {
        var entered: [String: (state: AgentSession.State, at: Date)] = [:]
        _ = CodexActivityMonitor.settled([session("a", .busy, since: now.addingTimeInterval(-60))],
                                         entered: &entered)
        let held = CodexActivityMonitor.settled([session("a", .busy, since: now)], entered: &entered)
        XCTAssertEqual(held.first?.since, now.addingTimeInterval(-60), "still busy: the clock holds")

        let done = CodexActivityMonitor.settled([session("a", .success, since: now)], entered: &entered)
        XCTAssertEqual(done.first?.since, now, "a new state is a new clock")

        _ = CodexActivityMonitor.settled([], entered: &entered)
        XCTAssertTrue(entered.isEmpty, "a row that has gone is forgotten")
    }

    // MARK: - Parsing a rollout once per change

    /// The parse walks up to a megabyte on the main actor, and it used to run
    /// for every live conversation every two seconds whether or not the file
    /// had moved.
    func testAnUnchangedRolloutIsNotParsedAgain() throws {
        // `task_complete` is one character longer than `task_started`; the
        // padding field takes it back, so the two files are the same length.
        let started = #"{"type":"event_msg","payload":{"type":"task_started"},"p":"x"}"# + "\n"
        let complete = #"{"type":"event_msg","payload":{"type":"task_complete"},"p":""}"# + "\n"
        XCTAssertEqual(started.utf8.count, complete.utf8.count)

        let url = dir.appendingPathComponent("rollout-memo.jsonl")
        let stamp = now.addingTimeInterval(-1)
        try Data(started.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)

        let cache = CodexStoreCache()
        XCTAssertEqual(cache.rolloutState(of: url, keeping: [url.path]), .busy)

        // Same length, same stamp, different contents. Nothing outside a test
        // produces that, so a changed answer would mean the file was read again.
        try Data(complete.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        XCTAssertEqual(cache.rolloutState(of: url, keeping: [url.path]), .busy,
                       "unchanged (mtime, size): the held answer must stand")

        // And a file that has moved is read again.
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        XCTAssertEqual(cache.rolloutState(of: url, keeping: [url.path]), .success)
    }

    private func session(_ id: String, _ state: AgentSession.State, since: Date) -> AgentSession {
        AgentSession(id: id, name: id, detail: "", state: state, waitingFor: nil, since: since)
    }

    // MARK: -

    private struct Row {
        let id: String
        let name: String?
        let preview: String?
        let parent: String?
        /// A guardian: a helper whose `threads` row names no parent, and whose
        /// rollout's opening `session_meta` line names this one.
        let guardianOf: String?
        let written: TimeInterval   // seconds before `now`
        let updatedMs: Int
        let events: [String]
    }

    private func thread(_ id: String, name: String?, preview: String? = nil,
                        parent: String? = nil, guardianOf: String? = nil,
                        written: TimeInterval, updatedMs: Int? = nil,
                        events: [String] = ["task_started"]) -> Row {
        Row(id: id, name: name, preview: preview, parent: parent, guardianOf: guardianOf,
            written: written, updatedMs: updatedMs ?? Int(1_000_000 - written), events: events)
    }

    private func read(_ store: URL) -> [AgentSession] {
        CodexActivityMonitor.read(stateStore: store,
                                  desktopStore: dir.appendingPathComponent("none.db"),
                                  staleAfter: 8, now: now)
    }

    /// A store with the columns a current Codex writes, and a rollout per row
    /// whose modification date is `written` seconds before `now`.
    private func makeStore(_ rows: [Row]) throws -> URL {
        let url = dir.appendingPathComponent("state_5.sqlite")
        try exec(url, """
            CREATE TABLE threads (id TEXT, rollout_path TEXT, archived INTEGER,
                                  updated_at_ms INTEGER, name TEXT, preview TEXT,
                                  title TEXT, cwd TEXT, source TEXT)
            """)
        for row in rows {
            let rollout = try rolloutFile(row.id, written: row.written, events: row.events,
                                          metaParent: row.guardianOf)
            let source: String
            if let parent = row.parent {
                source = #"{"subagent":{"thread_spawn":{"parent_thread_id":"\#(parent)","depth":1}}}"#
            } else if row.guardianOf != nil {
                source = #"{"subagent":{"other":"guardian"}}"#
            } else {
                source = "exec"
            }
            try exec(url, """
                INSERT INTO threads VALUES ('\(row.id)', '\(rollout.path)', 0, \(row.updatedMs),
                    \(quoted(row.name)), \(quoted(row.preview)), NULL, '/Users/vinz/app',
                    '\(source)')
                """)
        }
        return url
    }

    private func rolloutFile(_ name: String, written: TimeInterval,
                             events: [String] = ["task_started"],
                             metaParent: String? = nil) throws -> URL {
        let url = dir.appendingPathComponent("rollout-\(name).jsonl")
        let meta = metaParent.map {
            [#"{"type":"session_meta","payload":{"id":"\#(name)","parent_thread_id":"\#($0)","instructions":"\#(String(repeating: "x", count: 100_000))"}}"#]
        } ?? []
        let lines = meta + events.map { #"{"type":"event_msg","payload":{"type":"\#($0)"}}"# }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-written)], ofItemAtPath: url.path)
        return url
    }

    private func makeCatalogue(title: String, threadID: String) throws -> URL {
        let url = dir.appendingPathComponent("codex-dev.db")
        try exec(url, "CREATE TABLE local_thread_catalog (source_updated_at REAL, display_title TEXT, thread_id TEXT)")
        try exec(url, "INSERT INTO local_thread_catalog VALUES (\(now.addingTimeInterval(-1).timeIntervalSince1970), '\(title)', '\(threadID)')")
        return url
    }

    private func quoted(_ text: String?) -> String {
        text.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? "NULL"
    }

    private func exec(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
    }
}
