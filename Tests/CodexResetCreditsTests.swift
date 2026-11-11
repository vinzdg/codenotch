import XCTest
@testable import Codenotch

/// Banked rate-limit resets. The count is its own field — the details list
/// can be shorter than the total — and the next expiry is the soonest credit,
/// not the first one in the payload.
final class CodexResetCreditsTests: XCTestCase {
    private func credits(_ json: String) throws -> UsageResetCredits {
        try CodexUsage.resetCredits(from: Data(json.utf8))
    }

    private func utcDate(year: Int, month: Int, day: Int,
                         hour: Int = 0, minute: Int = 0, second: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second
        ))!
    }

    /// Recorded shape: a count plus one row per credit, expiry as an
    /// internet-date string. Extra keys on a row must not trip the decode.
    func testDecodesAvailableCountAndExpiryFromTheFixture() throws {
        let json = """
        {"available_count":2,"credits":[
          {"id":"credit-a","reset_type":"codex_rate_limits","status":"available",
           "title":"Full reset","granted_at":"2026-06-12T01:33:14Z",
           "expires_at":"2026-07-12T01:33:14Z"},
          {"id":"credit-b","reset_type":"codex_rate_limits","status":"available",
           "title":"Full reset","granted_at":"2026-06-18T08:00:00Z",
           "expires_at":"2026-07-18T08:00:00Z"}]}
        """
        let result = try credits(json)
        let firstExpiry = utcDate(year: 2026, month: 7, day: 12, hour: 1, minute: 33, second: 14)
        let secondExpiry = utcDate(year: 2026, month: 7, day: 18, hour: 8)

        XCTAssertEqual(result.availableCount, 2)
        XCTAssertEqual(result.credits[0].expiresAt, firstExpiry)
        XCTAssertEqual(result.credits[1].expiresAt, secondExpiry)
        XCTAssertEqual(result.nextExpiry, firstExpiry)
    }

    /// Arrival order is not expiry order — the next one is the soonest date,
    /// not whichever row happened to come first.
    func testNextExpiryIsTheSoonestCredit() throws {
        let json = """
        {"available_count":2,"credits":[
          {"status":"available","expires_at":"2026-08-01T00:00:00Z"},
          {"status":"available","expires_at":"2026-07-01T00:00:00Z"}]}
        """
        let result = try credits(json)
        XCTAssertEqual(result.nextExpiry, utcDate(year: 2026, month: 7, day: 1))
    }

    /// The details list can be capped, so the count field is the total rather
    /// than `credits.count`.
    func testAvailableCountIsTrustedWhenTheCreditsArrayIsShorter() throws {
        let json = """
        {"available_count":5,"credits":[
          {"status":"available","expires_at":"2026-07-12T01:33:14Z"}]}
        """
        let result = try credits(json)
        XCTAssertEqual(result.availableCount, 5)
        XCTAssertEqual(result.credits.count, 1)
        XCTAssertLessThan(result.credits.count, result.availableCount)
    }

    /// The reset-credit block is extra card, so the hover region has to grow
    /// with it or the pointer falls out of a card it is still over.
    func testTheCardGrowsWhenResetCreditsAreShown() {
        let plain = NotchLayout.cardHeight(windowCount: 2)
        let withCredits = NotchLayout.cardHeight(windowCount: 2, hasResetCredits: true)
        XCTAssertGreaterThan(withCredits, plain)
    }

    /// A successful endpoint response with no available credits is not card
    /// content. It must neither draw the empty-state copy nor reserve space.
    func testEmptyResetCreditsDoNotReserveCardSpace() {
        var snapshot = ProviderSnapshot(
            id: "codex", displayName: "Codex", glyph: .openai,
            fidelity: .official, status: .ok, windows: []
        )
        snapshot.resetCredits = UsageResetCredits(availableCount: 0)

        XCTAssertFalse(snapshot.hasAvailableResetCredits)
        XCTAssertEqual(
            NotchLayout.cardHeight(
                windowCount: snapshot.windows.count,
                hasResetCredits: snapshot.hasAvailableResetCredits
            ),
            NotchLayout.cardHeight(windowCount: snapshot.windows.count)
        )
    }

    func testAvailableResetCreditsAreShownAndReserveSpace() {
        var snapshot = ProviderSnapshot(
            id: "codex", displayName: "Codex", glyph: .openai,
            fidelity: .official, status: .ok, windows: []
        )
        snapshot.resetCredits = UsageResetCredits(availableCount: 1)

        XCTAssertTrue(snapshot.hasAvailableResetCredits)
        XCTAssertGreaterThan(
            NotchLayout.cardHeight(
                windowCount: snapshot.windows.count,
                hasResetCredits: snapshot.hasAvailableResetCredits
            ),
            NotchLayout.cardHeight(windowCount: snapshot.windows.count)
        )
    }
}
