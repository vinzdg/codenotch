import XCTest
@testable import Codenotch

/// Pinned to the shape `GET /v2/users/me/limits` is documented with — the
/// same three blocks the Console's Billing page draws its "Custom usage
/// limit" bar from. The amounts are synthetic.
final class ApifyUsageTests: XCTestCase {
    private func windows(_ json: String = ApifyFixture.limits) throws -> [LimitWindow] {
        try ApifyUsage.windows(from: Data(json.utf8))
    }

    private func monthly(_ json: String = ApifyFixture.limits) throws -> LimitWindow {
        try XCTUnwrap(windows(json).first { $0.id == ApifyUsage.headlineID })
    }

    func testTheRingIsTheShareOfTheMonthlyCap() throws {
        let monthly = try monthly()
        XCTAssertEqual(monthly.label, "Monthly usage")
        XCTAssertEqual(monthly.usedFraction ?? -1, 1200.6 / 1500, accuracy: 0.0001)
        XCTAssertEqual(try windows().count, 1, "one cap, one window — nothing invented beside it")
    }

    func testTheDollarsAreWrittenTheWayTheConsoleWritesThem() throws {
        let monthly = try monthly()
        XCTAssertEqual(monthly.usedText, "$1,200.60")
        XCTAssertEqual(monthly.detail, "$1,200.60 of $1,500.00")
    }

    func testTheWindowRollsOverWhenTheCycleEnds() throws {
        let monthly = try monthly()
        let reset = try XCTUnwrap(monthly.resetsAt)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.component(.month, from: reset), 10)
        XCTAssertEqual(utc.component(.day, from: reset), 1)
        XCTAssertEqual(utc.component(.hour, from: reset), 23)
        // The cycle runs from the 2nd to the end of the 1st: a day short of a
        // calendar month, and a millisecond short of that.
        XCTAssertEqual(try XCTUnwrap(monthly.duration), 30 * 86400, accuracy: 1)
    }

    func testSpendingPastTheCapIsReportedAsPastIt() throws {
        let over = ApifyFixture.limits.replacingOccurrences(of: #""monthlyUsageUsd":1200.6"#,
                                                            with: #""monthlyUsageUsd":1650"#)
        let monthly = try monthly(over)
        XCTAssertEqual(monthly.usedFraction ?? -1, 1.1, accuracy: 0.0001,
                       "the platform pauses at the cap, but the number Apify reports is still the number")
        XCTAssertEqual(monthly.detail, "$1,650.00 of $1,500.00")
    }

    func testWithoutACapThereIsNoDenominator() throws {
        for json in [ApifyFixture.limits.replacingOccurrences(of: #""maxMonthlyUsageUsd":1500,"#, with: ""),
                     ApifyFixture.limits.replacingOccurrences(of: #""maxMonthlyUsageUsd":1500"#,
                                                              with: #""maxMonthlyUsageUsd":0"#)] {
            let monthly = try monthly(json)
            XCTAssertNil(monthly.usedFraction, "no cap means no share of it, not 0%")
            XCTAssertEqual(monthly.usedText, "$1,200.60")
            XCTAssertEqual(monthly.detail, "$1,200.60 this cycle")
            XCTAssertNotNil(monthly.resetsAt, "the cycle still ends when Apify says it does")
        }
    }

    func testMissingOrMalformedUsageIsNotAReading() {
        let broken = [
            "not json",
            "{}",
            #"{"data":{}}"#,
            #"{"data":{"current":{}}}"#,
            #"{"data":{"current":{"monthlyUsageUsd":"1200.6"}}}"#,
            #"{"data":{"current":{"monthlyUsageUsd":-1}}}"#,
            #"{"error":{"type":"invalid-token","message":"Authentication token is not valid"}}"#
        ]
        for json in broken {
            XCTAssertThrowsError(try windows(json), json) { error in
                guard case UsageProviderError.badResponse = error else {
                    return XCTFail("expected badResponse for \(json), got \(error)")
                }
            }
        }
    }

    func testMoneyIsGroupedAndKeepsTwoDecimalsWhateverTheMacsRegion() {
        XCTAssertEqual(ApifyUsage.money(0), "$0.00")
        XCTAssertEqual(ApifyUsage.money(0.5), "$0.50")
        XCTAssertEqual(ApifyUsage.money(12345.678), "$12,345.68")
        XCTAssertEqual(ApifyUsage.money(1500), "$1,500.00")
    }
}

enum ApifyFixture {
    /// The documented `LimitsResponse`, with the Console's example numbers
    /// swapped for a synthetic account at 80% of a $1,500 cap.
    static let limits = """
    {"data":{"monthlyUsageCycle":{"startAt":"2026-09-02T00:00:00.000Z","endAt":"2026-10-01T23:59:59.999Z"},\
    "limits":{"maxMonthlyUsageUsd":1500,"maxMonthlyActorComputeUnits":1000,"maxMonthlyExternalDataTransferGbytes":7,\
    "maxMonthlyProxySerps":50,"maxMonthlyResidentialProxyGbytes":0.5,"maxActorMemoryGbytes":16,"maxActorCount":100,\
    "maxActorTaskCount":1000,"maxConcurrentActorJobs":256,"maxTeamAccountSeatCount":9,"dataRetentionDays":90},\
    "current":{"monthlyUsageUsd":1200.6,"monthlyActorComputeUnits":312.5,"monthlyExternalDataTransferGbytes":1.2,\
    "monthlyProxySerps":0,"monthlyResidentialProxyGbytes":0,"actorMemoryGbytes":0,"actorCount":3,"actorTaskCount":4,\
    "activeActorJobCount":0,"teamAccountSeatCount":1}}}
    """
}
