import XCTest
@testable import Codenotch

@MainActor
final class ProviderCellReadingTests: XCTestCase {
    private func session(_ used: Double? = 0.30) -> LimitWindow {
        LimitWindow(id: "session", label: "5-hour limit", usedFraction: used,
                    resetsAt: nil, duration: 5 * 3600)
    }

    private func weekly(_ used: Double? = 0.70, id: String = "weekly") -> LimitWindow {
        LimitWindow(id: id, label: "Weekly limit", usedFraction: used,
                    resetsAt: Date(timeIntervalSince1970: 1_800_000_000), duration: 7 * 86_400)
    }

    private func claude(_ windows: [LimitWindow], weeklyID: String? = "weekly") -> ProviderSnapshot {
        ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude,
                         fidelity: .official, status: .ok, windows: windows,
                         headlineID: windows.first?.id, weeklyID: weeklyID)
    }

    private func reading(_ snapshot: ProviderSnapshot, _ weeklyRing: WeeklyRing = .outside,
                         weekly: Bool = true) -> String {
        ProviderCell(snapshot: snapshot, weeklyRing: weeklyRing, showsWeeklyReading: weekly).accessibilityText
    }

    func testTheWeeklyPercentageFollowsTheSession() {
        XCTAssertEqual(reading(claude([session(), weekly()])), "Claude, 30%/70%")
    }

    /// The ring can be on without its number, and the number never shows
    /// without the ring it belongs to.
    func testItNeedsBothTheSettingAndTheRing() {
        XCTAssertEqual(reading(claude([session(), weekly()]), weekly: false), "Claude, 30%")
        XCTAssertEqual(reading(claude([session(), weekly()]), .off), "Claude, 30%")
    }

    // MARK: - Other ring modes: the pair reads the way the rings are drawn

    /// Weekly limit as the main ring: the weekly leads and the thin ring is
    /// the session, so the reading is weekly/session.
    func testWithTheWeeklyAsTheMainRingThePairFollowsTheRings() {
        let led = WeeklyHeadline.apply(to: claude([session(), weekly()]))
        XCTAssertEqual(led.headlineID, "weekly", "fixture no longer triggers the swap")
        XCTAssertEqual(reading(led), "Claude, 70%/30%")
    }

    /// Daily pace ring: today's share of the week leads, the session is thin.
    func testWithTheDailyPaceRingThePairFollowsTheRings() throws {
        let weekStart = Date(timeIntervalSince1970: 1_800_000_000 - 7 * 86_400)
        let paced = DailyPace.apply(to: claude([session(0.42), weekly(0.30, id: "weekly_all")],
                                                weeklyID: "weekly_all"),
                                    now: weekStart.addingTimeInterval(2.25 * 86_400))
        XCTAssertEqual(paced.weeklyID, "session", "fixture no longer triggers the pace ring")
        XCTAssertEqual(reading(paced), "Claude, 70%/42%")
    }

    // MARK: - Only after a percentage

    func testACostHeadlineGetsNoPercentageAfterIt() {
        let cost = LimitWindow(id: "spend", label: "Spend", usedFraction: 0.30, usedText: "$1.20",
                               resetsAt: nil, prefersUsedText: true)
        XCTAssertEqual(reading(claude([cost, weekly()])), "Claude, $1.20")
    }

    func testACountHeadlineGetsNoPercentageAfterIt() {
        let count = LimitWindow(id: "requests", label: "Requests", remaining: 1200, resetsAt: nil)
        let snapshot = claude([count, weekly()])
        XCTAssertFalse(reading(snapshot).contains("/"), reading(snapshot))
        XCTAssertEqual(reading(snapshot), "Claude, \(snapshot.headlineText)")
    }

    // MARK: - Nothing to pair with

    func testNoWeeklyWindowLeavesThePlainReading() {
        XCTAssertEqual(reading(claude([session()], weeklyID: nil)), "Claude, 30%")
    }

    func testAWeeklyWindowWithoutAFractionLeavesThePlainReading() {
        XCTAssertEqual(reading(claude([session(), weekly(nil)])), "Claude, 30%")
    }
}
