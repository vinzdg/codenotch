import XCTest
@testable import Codenotch

/// The coding-plan windows, pinned to the schema the Kilo CLI validates the
/// same answers against — the same figures the Kilo dashboard shows.
final class KiloUsageTests: XCTestCase {
    /// Verbatim shape from `codingPlans.getUsage` (a plan at 25% remaining).
    private let usagePayload = """
    {"result":{"data":{"json":{\
    "schemaVersion":1,\
    "fetchedAt":"2026-09-22T08:00:00.000Z",\
    "subscription":{\
    "id":"sub-1","planName":"Kilo Pro","providerId":"anthropic","providerName":"Anthropic",\
    "windows":[\
    {"id":"five_hour","remainingPercent":75,"resetsAt":"2026-09-22T13:00:00.000Z",\
    "startsAt":"2026-09-22T08:00:00.000Z","period":{"unit":"hour","value":5}},\
    {"id":"weekly","remainingPercent":40,"resetsAt":"2026-09-28T00:00:00.000Z",\
    "period":{"unit":"week","value":1}}]}}}}}
    """

    func testReadsBothWindowsInvertedAndOrdered() throws {
        let w = try KiloUsage.windows(fromJSON: usagePayload)
        XCTAssertEqual(w.map(\.id), ["five_hour", "weekly"], "the shortest window first")
        XCTAssertEqual(w[0].usedFraction ?? -1, 0.25, accuracy: 0.0001, "remainingPercent is what is left")
        XCTAssertEqual(w[1].usedFraction ?? -1, 0.60, accuracy: 0.0001)
        XCTAssertEqual(w[0].duration, 5 * 3600, "the period names the length")
        XCTAssertEqual(w[1].duration, 7 * 86400)
        XCTAssertEqual(w[0].label, "5h limit")
        XCTAssertEqual(w[1].label, "Weekly limit")
    }

    func testFiveHourWindowIsRecognisedAsTheSessionRing() throws {
        let w = try KiloUsage.windows(fromJSON: usagePayload)
        XCTAssertTrue(w[0].isFiveHour, "the five-hour window is the one a session runs into first")
        XCTAssertFalse(w[1].isFiveHour)
        XCTAssertEqual(KiloUsage.headlineID(in: w), "five_hour")
    }

    func testResetsCarryMilliseconds() throws {
        let w = try KiloUsage.windows(fromJSON: usagePayload)
        let at = try XCTUnwrap(w[0].resetsAt)
        let plain = ISO8601DateFormatter().date(from: "2026-09-22T13:00:00Z")!
        XCTAssertEqual(at.timeIntervalSince1970, plain.timeIntervalSince1970, accuracy: 1)
    }

    func testARemainingOfZeroMeansSpent() throws {
        let json = """
        {"result":{"data":{"json":{"subscription":{"id":"s","planName":"p","providerId":"x","providerName":"y",\
        "windows":[{"id":"monthly","remainingPercent":0,"resetsAt":"2026-10-01T00:00:00Z",\
        "period":{"unit":"month","value":1}}]}}}}}
        """
        let w = try KiloUsage.windows(fromJSON: json)
        XCTAssertEqual(w[0].usedFraction ?? -1, 1.0, accuracy: 0.0001)
    }

    func testWindowsWithoutAPercentAreDropped() throws {
        let json = """
        {"result":{"data":{"json":{"subscription":{"id":"s","planName":"p","providerId":"x","providerName":"y",\
        "windows":[{"id":"odd"},{"id":"monthly","remainingPercent":10,"resetsAt":"2026-10-01T00:00:00Z",\
        "period":{"unit":"month","value":1}}]}}}}}
        """
        let w = try KiloUsage.windows(fromJSON: json)
        XCTAssertEqual(w.map(\.id), ["monthly"])
    }

    func testAnEmptyWindowListIsNotAReading() {
        for json in ["{}", "{\"result\":{}}",
                     #"{"result":{"data":{"json":{"subscription":{"id":"s","planName":"p","providerId":"x","providerName":"y","windows":[]}}}}}"#] {
            XCTAssertThrowsError(try KiloUsage.windows(fromJSON: json)) { error in
                guard case UsageProviderError.badResponse = error else {
                    return XCTFail("expected badResponse, got \(error)")
                }
            }
        }
    }

    // MARK: The tRPC envelope

    func testAnErrorEnvelopeIsNotData() {
        XCTAssertThrowsError(try KiloUsage.unwrap(json: #"{"error":{"message":"nope"}}"#)) { error in
            guard case UsageProviderError.apiError = error else {
                return XCTFail("expected apiError, got \(error)")
            }
        }
    }

    func testTheEnvelopeUnwrapsBothShapes() throws {
        let wrapped = try KiloUsage.unwrap(json: #"{"result":{"data":{"json":[1]}}}"#)
        XCTAssertEqual(wrapped as? [Int], [1])
        let flat = try KiloUsage.unwrap(json: #"{"result":{"data":[2]}}"#)
        XCTAssertEqual(flat as? [Int], [2], "older tRPC answers carry the payload bare")
    }

    // MARK: Subscriptions

    func testSubscriptionsKeepOnlyMeteringPlans() throws {
        let json = """
        {"result":{"data":{"json":[\
        {"id":"a","planId":"p1","planName":"Pro","providerName":"Anthropic","providerId":"anthropic",\
        "canQueryUsage":true,"hasInstalledByokKey":true,"status":"active","cancelAtPeriodEnd":false},\
        {"id":"b","planId":"p2","planName":"Old","providerName":"X","providerId":"x",\
        "canQueryUsage":true,"hasInstalledByokKey":true,"status":"canceled","cancelAtPeriodEnd":true}]}}}
        """
        let plans = try KiloUsage.subscriptions(fromJSON: json).filter(\.meters)
        XCTAssertEqual(plans.map(\.id), ["a"], "a cancelled plan meters nothing")
        XCTAssertEqual(plans[0].planName, "Pro")
        XCTAssertEqual(plans[0].meters, true)
    }

    // MARK: Balance

    func testTheBalanceBecomesACountUpRow() throws {
        let w = KiloUsage.balanceWindow(fromJSON: #"{"balance":14.28}"#)
        let window = try XCTUnwrap(w)
        XCTAssertEqual(window.id, "balance")
        XCTAssertEqual(window.usedText, "$14.28")
        XCTAssertNil(window.usedFraction, "a balance has no denominator to draw a ring with")
        XCTAssertEqual(window.prefersUsedText, true)
    }

    func testABalancelessAnswerIsNoRow() {
        XCTAssertNil(KiloUsage.balanceWindow(fromJSON: "{}"))
        XCTAssertNil(KiloUsage.balanceWindow(fromJSON: #"{"balance":null}"#))
    }
}
