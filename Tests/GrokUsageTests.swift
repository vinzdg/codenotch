import XCTest
@testable import Codenotch

/// Pinned to a response recorded from a live SuperGrok CLI session. Credits
/// is the weekly Grok Build allowance — the one number this account's own
/// endpoint actually states.
final class GrokUsageTests: XCTestCase {
    private let credits = """
    {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",\
    "start":"2026-09-05T08:21:18.802818+00:00",\
    "end":"2026-09-12T08:21:18.802818+00:00"},\
    "creditUsagePercent":8.0,\
    "onDemandCap":{"val":0},"onDemandUsed":{"val":0},\
    "productUsage":[{"product":"GrokBuild","usagePercent":8.0}],\
    "isUnifiedBillingUser":true,"prepaidBalance":{"val":0},\
    "topUpMethod":"TOP_UP_METHOD_SAVED_PAYMENT_METHOD",\
    "billingPeriodStart":"2026-09-05T08:21:18.802818+00:00",\
    "billingPeriodEnd":"2026-09-12T08:21:18.802818+00:00"}}
    """

    private func windows() throws -> [LimitWindow] {
        try GrokUsage.windows(creditsJSON: credits)
    }

    func testTheRingIsTheCreditsPercentage() throws {
        let credits = try XCTUnwrap(windows().first { $0.id == "credits" })
        XCTAssertEqual(credits.duration, 7 * 86400)
        XCTAssertEqual(credits.label, "Grok Build")
        XCTAssertEqual(credits.usedFraction ?? -1, 0.08, accuracy: 0.0001)
    }

    func testWeeklyCreditsHaveTheirOwnReset() throws {
        let credits = try XCTUnwrap(windows().first { $0.id == "credits" })
        let reset = try XCTUnwrap(credits.resetsAt)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.component(.month, from: reset), 9)
        XCTAssertEqual(utc.component(.day, from: reset), 12)
    }

    /// An empty config has nothing to draw a ring from — not a reading of
    /// zero, an absence of one.
    func testAnEmptyConfigIsNotASuccessfulReading() {
        XCTAssertThrowsError(try GrokUsage.windows(
            creditsJSON: #"{"config":{}}"#
        )) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }

    /// `creditUsagePercent` is absent; the product array is the reading. The
    /// ring is still declared as both the headline and weekly allowance.
    func testProductOnlyCreditsStillUseTheHeadlineID() throws {
        let productOnly = """
        {"config":{"productUsage":[{"product":"GrokBuild","usagePercent":33.0}],\
        "billingPeriodEnd":"2026-09-12T08:21:18.802818+00:00"}}
        """
        let w = try GrokUsage.windows(creditsJSON: productOnly)
        let credits = try XCTUnwrap(w.first { $0.id == "credits" })
        XCTAssertNil(credits.duration)
        XCTAssertEqual(credits.label, "Grok Build")
        XCTAssertEqual(credits.usedFraction ?? -1, 0.33, accuracy: 0.0001)
        let snap = ProviderSnapshot(
            id: "grok", displayName: "Grok", glyph: .grok,
            fidelity: .official, status: .ok, windows: w,
            headlineID: "credits", weeklyID: "credits"
        )
        XCTAssertEqual(snap.headline?.id, "credits")
        XCTAssertEqual(snap.weeklyLimitWindow?.id, "credits")
        XCTAssertEqual(snap.usedFraction ?? -1, 0.33, accuracy: 0.0001)
    }

    /// An X Premium+ / SuperGrok weekly pool states its window in
    /// `currentPeriod` but carries no `creditUsagePercent` or `productUsage`
    /// until usage lands. Grok's own `/usage` draws a "Weekly limit" bar at 0%
    /// here, so this is a zero reading, not an absent one.
    func testWeeklyPoolWithoutAPercentIsAZeroRing() throws {
        let weeklyOnly = """
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",\
        "start":"2026-09-07T20:59:12+00:00",\
        "end":"2026-09-14T20:59:12+00:00"},\
        "onDemandCap":{"val":0},"onDemandUsed":{"val":0},\
        "isUnifiedBillingUser":true,"prepaidBalance":{"val":0}}}
        """
        let w = try GrokUsage.windows(creditsJSON: weeklyOnly)
        let credits = try XCTUnwrap(w.first { $0.id == "credits" })
        XCTAssertEqual(credits.label, "Weekly limit")
        XCTAssertEqual(credits.usedFraction ?? -1, 0, accuracy: 0.0001)
        let reset = try XCTUnwrap(credits.resetsAt)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.component(.month, from: reset), 9)
        XCTAssertEqual(utc.component(.day, from: reset), 14)
    }

    func testGarbageIsABadResponseRatherThanAGuess() {
        XCTAssertThrowsError(try GrokUsage.windows(creditsJSON: "not json")) { error in
            guard case UsageProviderError.badResponse = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
    }

    func testHumanizesTheProductNameTheWayTheModalWritesIt() {
        XCTAssertEqual(GrokUsage.humanize("GrokBuild"), "Grok Build")
    }

    /// The issuer is compared whole: a host that merely begins with
    /// `auth.x.ai` is someone else's, and its token must not be sent to xAI.
    func testALookalikeIssuerIsNotTrusted() {
        XCTAssertFalse(GrokCredentials.isTrusted(key: "https://auth.x.ai.example.com::cli", entry: [:]))
        XCTAssertFalse(GrokCredentials.isTrusted(key: "https://auth.x.aix::cli", entry: [:]))
        XCTAssertTrue(GrokCredentials.isTrusted(key: "https://auth.x.ai::cli", entry: [:]))
        XCTAssertTrue(GrokCredentials.isTrusted(key: "https://auth.x.ai", entry: [:]))
    }
}
