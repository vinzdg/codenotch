import XCTest
@testable import Codenotch

/// Guards the shape of `GET /v1/billing?format=credits`. It is not a published
/// API, so these are the tests that will fail first if xAI changes it.
final class GrokUsageTests: XCTestCase {
    /// Trimmed from a live SuperGrok Heavy response.
    private let live = """
    { "config": {
        "currentPeriod": {
          "type": "USAGE_PERIOD_TYPE_WEEKLY",
          "start": "2026-09-04T17:04:30.982568+00:00",
          "end": "2026-09-11T17:04:30.982568+00:00" },
        "creditUsagePercent": 1.0,
        "onDemandCap": { "val": 0 },
        "onDemandUsed": { "val": 0 },
        "productUsage": [
          { "product": "GrokBuild", "usagePercent": 1.0 },
          { "product": "GrokChat" },
          { "product": "GrokVoice" } ],
        "isUnifiedBillingUser": true,
        "prepaidBalance": { "val": 0 },
        "billingPeriodStart": "2026-09-04T17:04:30.982568+00:00",
        "billingPeriodEnd": "2026-09-11T17:04:30.982568+00:00" } }
    """

    func testDecodesTheLiveShape() throws {
        let payload = try GrokUsage.parse(Data(live.utf8))
        XCTAssertEqual(payload.windows.map(\.id), ["weekly", "product:GrokBuild"])
        XCTAssertEqual(payload.windows[0].label, "Weekly")
        XCTAssertEqual(payload.windows[0].usedFraction ?? -1, 0.01, accuracy: 0.0001)
        XCTAssertEqual(payload.windows[1].label, "Grok Build")
        XCTAssertEqual(payload.windows[1].usedFraction ?? -1, 0.01, accuracy: 0.0001)
        XCTAssertEqual(
            payload.windows[0].resetsAt?.timeIntervalSince1970 ?? -1,
            1_789_146_270.982568,
            accuracy: 0.01
        )
    }

    /// 1.0 is one percent, not a full ring. The field is already a percentage;
    /// treating it as a fraction would report a spent week on a nearly unused
    /// SuperGrok Heavy pool.
    func testAOnePointZeroPercentIsOnePercentUsed() throws {
        let json = """
        { "config": { "creditUsagePercent": 1.0,
            "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "end": "2026-09-11T17:04:30.982568+00:00" } } }
        """
        let window = try GrokUsage.parse(Data(json.utf8)).windows[0]
        XCTAssertEqual(window.usedFraction ?? -1, 0.01, accuracy: 0.0001)
    }

    /// A period with no usage field is an unused week, not a missing reading.
    func testAPeriodWithoutAPercentageReadsAsZero() throws {
        let json = """
        { "config": {
            "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "end": "2026-09-11T17:04:30.982568+00:00" } } }
        """
        let window = try GrokUsage.parse(Data(json.utf8)).windows[0]
        XCTAssertEqual(window.usedFraction ?? -1, 0, accuracy: 0.0001)
    }

    func testProductsWithoutAPercentageAreDropped() throws {
        let json = """
        { "config": {
            "currentPeriod": { "end": "2026-09-11T17:04:30.982568+00:00" },
            "creditUsagePercent": 12,
            "productUsage": [ { "product": "GrokChat" } ] } }
        """
        XCTAssertEqual(try GrokUsage.parse(Data(json.utf8)).windows.map(\.id), ["weekly"])
    }

    func testMonthlyPeriodIsLabeledMonthly() throws {
        let json = """
        { "config": {
            "currentPeriod": { "type": "USAGE_PERIOD_TYPE_MONTHLY",
              "end": "2026-10-04T17:04:30.982568+00:00" },
            "creditUsagePercent": 40 } }
        """
        XCTAssertEqual(try GrokUsage.parse(Data(json.utf8)).windows[0].label, "Monthly")
    }

    func testNoConfigIsABadResponse() {
        XCTAssertThrowsError(try GrokUsage.parse(Data(#"{}"#.utf8))) { error in
            guard case UsageProviderError.badResponse = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
    }

    func testSettingsCarryThePlanName() {
        let json = #"{"subscription_tier_display":"SuperGrok Heavy"}"#
        XCTAssertEqual(GrokUsage.planName(from: Data(json.utf8)), "SuperGrok Heavy")
    }
}

final class GrokCredentialsTests: XCTestCase {
    func testReadsTheAuthXAIEntry() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-auth-\(UUID().uuidString).json")
        let future = "2099-01-01T00:00:00.000000Z"
        try Data("""
        { "https://auth.x.ai::abc": {
            "key": "tok-live", "expires_at": "\(future)",
            "email": "dev@example.com", "auth_mode": "oidc" },
          "https://accounts.x.ai/sign-in": {
            "key": "tok-old", "expires_at": "\(future)" } }
        """.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try XCTUnwrap(GrokCredentials.load(from: url))
        XCTAssertEqual(loaded.accessToken, "tok-live")
        XCTAssertEqual(loaded.email, "dev@example.com")
        XCTAssertFalse(loaded.isExpired)
    }

    func testAMissingFileIsNoCredential() {
        let url = URL(fileURLWithPath: "/tmp/codenotch-no-such-grok-auth.json")
        XCTAssertNil(GrokCredentials.load(from: url))
    }

    func testAnExpiredTokenIsStillLoadedSoTheCallerCanSayStale() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-auth-\(UUID().uuidString).json")
        try Data("""
        { "https://auth.x.ai::abc": {
            "key": "tok-stale", "expires_at": "2020-01-01T00:00:00Z" } }
        """.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try XCTUnwrap(GrokCredentials.load(from: url))
        XCTAssertTrue(loaded.isExpired)
    }
}
