import XCTest
import SwiftUI
@testable import Codenotch

/// `MiMoUsage` is written against the platform's documented console payloads,
/// not against a live session this build could take, so these tests are the
/// contract: they pin the shape the first signed-in probe has to confirm.
final class MiMoUsageTests: XCTestCase {
    private let clock = Date(timeIntervalSince1970: 1_760_000_000)

    private let usage = """
    {"code":0,"message":"","data":{
        "monthUsage":{"percent":0.1661,"items":[
            {"name":"month_total_token","used":265741632,"limit":1600000000,"percent":0.1661}]},
        "usage":{"items":[
            {"name":"plan_total_token","used":14954038035,"limit":38000000000,"percent":0.39},
            {"name":"compensation_total_token","used":0,"limit":0,"percent":0}]}}}
    """

    private let detail = """
    {"planCode":"pro","planName":"Pro","currentPeriodEnd":"2026-11-05 23:59:59",
     "expired":false,"enableAutoRenew":true}
    """

    private func envelope(usage: String? = nil, detail: String? = nil) throws -> String {
        let body: [String: Any] = [
            "usage": usage ?? self.usage,
            "detail": detail ?? self.detail,
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        return String(decoding: data, as: UTF8.self)
    }

    func testThePlanPeriodReadingIsTheHeadlineAndItsResetComesFromDetail() throws {
        let windows = try MiMoUsage.windows(fromJSON: envelope(), now: clock)
        // The empty compensation row is dropped, so this is the one ring.
        XCTAssertEqual(windows.map(\.id), ["month"])

        let headline = try XCTUnwrap(windows.first)
        XCTAssertEqual(headline.id, "month")
        XCTAssertEqual(headline.label, "Pro plan")
        // The exact counts divide to the same fraction the platform states.
        XCTAssertEqual(try XCTUnwrap(headline.usedFraction), 0.39, accuracy: 0.0001)
        XCTAssertEqual(headline.remaining, 38_000_000_000 - 14_954_038_035)
        XCTAssertEqual(headline.used, 14_954_038_035)
        // The subscription's own reset moment, read as a local wall clock — the
        // same zone the console renders it in.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let expected = try XCTUnwrap(formatter.date(from: "2026-11-05 23:59:59"))
        XCTAssertEqual(headline.resetsAt, expected)
    }

    func testTheEmptyCompensationRowIsNotAWindow() throws {
        let windows = try MiMoUsage.windows(fromJSON: envelope(), now: clock)
        // `compensation_total_token` reports limit 0, so it is noise rather
        // than a bonus pool worth a second ring.
        XCTAssertEqual(windows.map(\.id), ["month"])
    }

    func testARealCompensationPoolEarnsItsOwnWindow() throws {
        let usage = """
        {"code":0,"data":{"usage":{"items":[
            {"name":"plan_total_token","used":200,"limit":1000,"percent":0.2},
            {"name":"compensation_total_token","used":50,"limit":200,"percent":0.25}]}}}
        """
        let windows = try MiMoUsage.windows(fromJSON: envelope(usage: usage), now: clock)
        XCTAssertEqual(windows.map(\.id), ["month", "compensation"])
        XCTAssertEqual(windows[1].label, "Bonus credits")
        XCTAssertEqual(try XCTUnwrap(windows[1].usedFraction), 0.25, accuracy: 0.0001)
        XCTAssertEqual(windows[1].remaining, 150)
    }

    func testWithoutThePlanBlockTheCalendarMonthViewIsTheRing() throws {
        let usage = """
        {"code":0,"data":{"monthUsage":{"percent":0.1661,"items":[
            {"name":"month_total_token","used":265741632,"limit":1600000000,"percent":0.1661}]}}}
        """
        let windows = try MiMoUsage.windows(fromJSON: envelope(usage: usage), now: clock)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(try XCTUnwrap(windows[0].usedFraction), 0.1661, accuracy: 0.0001)
        // A calendar-month reading has no reset of its own, so it closes at the
        // boundary the month actually closes at — the 1st of the next one.
        XCTAssertNotNil(windows[0].resetsAt)
        XCTAssertGreaterThan(try XCTUnwrap(windows[0].resetsAt), clock)
    }

    func testADeadSessionIsNotAnUnreadableShape() throws {
        let signedOut = """
        {"code":401,"message":"","data":null,
         "loginUrl":"https://account.xiaomi.com/sts?..." }
        """
        XCTAssertThrowsError(try MiMoUsage.windows(fromJSON: try envelope(usage: signedOut), now: clock)) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("expected needsAuth, got \(error)")
            }
        }
    }

    func testABusinessFailureIsNamedRatherThanDrawn() throws {
        let failure = """
        {"code":500,"message":"internal error","data":null}
        """
        XCTAssertThrowsError(try MiMoUsage.windows(fromJSON: try envelope(usage: failure), now: clock)) { error in
            guard case UsageProviderError.apiError(let name) = error else {
                return XCTFail("expected apiError, got \(error)")
            }
            XCTAssertEqual(name, L10n.t("MiMo refused the request."))
        }
    }

    func testAPayloadWithoutAQuotaReportsNothingMetered() throws {
        let empty = """
        {"code":0,"data":{"monthUsage":{"percent":0,"items":[]}}}
        """
        XCTAssertThrowsError(try MiMoUsage.windows(fromJSON: try envelope(usage: empty), now: clock)) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }

    func testANonFinitePercentFallsBackToTheCounts() throws {
        let usage = """
        {"code":0,"data":{"monthUsage":{"items":[
            {"name":"month_total_token","used":250,"limit":1000,"percent":"nan"}]}}}
        """
        let windows = try MiMoUsage.windows(fromJSON: envelope(usage: usage), now: clock)
        XCTAssertEqual(try XCTUnwrap(windows[0].usedFraction), 0.25, accuracy: 0.0001)
        XCTAssertEqual(windows[0].remaining, 750)
    }

    func testAStaleResetIsDroppedRatherThanDrawnAsAPastMoment() throws {
        let detail = """
        {"planName":"Pro","currentPeriodEnd":"2020-01-01 00:00:00"}
        """
        let windows = try MiMoUsage.windows(fromJSON: envelope(detail: detail), now: clock)
        XCTAssertNil(windows[0].resetsAt)
    }

    func testTheMarkMatchesTheProviderGlyph() {
        XCTAssertEqual(ProviderGlyph.mimo.rawValue, "mimo")
        XCTAssertEqual(ProviderGlyph.mimo.outline, GlyphOutline.mimo)
        XCTAssertEqual(ProviderGlyph.mimo.assetName, "glyph-mimo")
        XCTAssertEqual(ProviderGlyph.mimo.brandColor, Color(hex: 0xFF6900))
    }

    /// A refused read reloads the page once — and only for the site whose
    /// refusal has been shown to be the site retiring its own cookie rather
    /// than the user signing out. Everywhere else a 401 has to end the session
    /// immediately, exactly as it did before: DeepSeek's and MiniMax's
    /// endpoints are the ones this app has been throttled on, and asking a
    /// door that just closed a second time is how that happened.
    func testOnlyMiMoReloadsARefusedSessionBeforeDeclaringItDead() {
        XCTAssertTrue(Sites.mimo.reloadsSessionOnAuthFailure)
        XCTAssertFalse(Sites.deepSeek.reloadsSessionOnAuthFailure)
        XCTAssertFalse(Sites.qianwen.reloadsSessionOnAuthFailure)
        XCTAssertFalse(Sites.qoder(region: .global).reloadsSessionOnAuthFailure)
        XCTAssertFalse(Sites.perplexity.reloadsSessionOnAuthFailure)
        for region in MiniMaxRegion.allCases {
            XCTAssertFalse(Sites.minimax(region: region).reloadsSessionOnAuthFailure)
        }
    }
}
