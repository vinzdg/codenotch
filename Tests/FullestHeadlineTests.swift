import XCTest
@testable import Codenotch

final class FullestHeadlineTests: XCTestCase {
    private func snapshot(id: String = "codex", _ windows: [LimitWindow],
                          headline: String, weekly: String?) -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: "P", glyph: .claude, fidelity: .official,
                         status: .ok, windows: windows, headlineID: headline, weeklyID: weekly)
    }

    private func window(_ id: String, _ used: Double?, days: Double? = nil, group: String? = nil,
                        money: UsageMoneyBreakdown? = nil) -> LimitWindow {
        LimitWindow(id: id, group: group, label: id, usedFraction: used, money: money,
                    duration: days.map { $0 * 86_400 })
    }

    func testASpentWeekLeadsAndTheShortWindowTakesTheThinRing() {
        let led = FullestHeadline.apply(to: snapshot(
            [window("primary", 0), window("secondary", 0.16)], headline: "primary", weekly: "secondary"))
        XCTAssertEqual(led.headlineID, "secondary")
        XCTAssertEqual(led.weeklyID, "primary")
    }

    func testAFullShortWindowKeepsTheLead() {
        let led = FullestHeadline.apply(to: snapshot(
            [window("primary", 1), window("secondary", 0.16)], headline: "primary", weekly: "secondary"))
        XCTAssertEqual(led.headlineID, "primary")
        XCTAssertEqual(led.weeklyID, "secondary")
    }

    func testATieKeepsTheDeclaredHeadline() {
        let led = FullestHeadline.apply(to: snapshot(
            [window("primary", 0.3), window("secondary", 0.3)], headline: "primary", weekly: "secondary"))
        XCTAssertEqual(led.headlineID, "primary")
    }

    func testAMonthlyWindowLeadsAndTheWeeklyRingStays() {
        let led = FullestHeadline.apply(to: snapshot(
            [window("rolling", 0.1), window("weekly", 0.4, days: 7), window("monthly", 0.8, days: 30)],
            headline: "rolling", weekly: "weekly"))
        XCTAssertEqual(led.headlineID, "monthly")
        XCTAssertEqual(led.weeklyID, "weekly")
    }

    func testGroupedWindowsNeverCompete() {
        let led = FullestHeadline.apply(to: snapshot(
            [window("primary", 0.1), window("spark-secondary", 0.9, days: 30, group: "spark")],
            headline: "primary", weekly: nil))
        XCTAssertEqual(led.headlineID, "primary")
    }

    func testAHeadlineWithoutAReadingIsLeftAlone() {
        let led = FullestHeadline.apply(to: snapshot(
            [window("balance", nil), window("monthly", 0.9, days: 30)], headline: "balance", weekly: nil))
        XCTAssertEqual(led.headlineID, "balance")
    }

    func testOffLeavesEverythingUntouched() {
        let base = snapshot([window("primary", 0), window("secondary", 0.5)],
                            headline: "primary", weekly: "secondary")
        XCTAssertEqual(FullestHeadline.apply(to: [base], enabled: false).first?.headlineID, "primary")
    }

    func testItOutranksTheWeeklyMainRingWhenBothAreOn() {
        let codex = snapshot([window("primary", 1, days: 5.0 / 24), window("secondary", 0.16, days: 7)],
                             headline: "primary", weekly: "secondary")
        let drawn = AppDelegate.drawn([codex], weekly: true, paced: false, fullest: true)
        XCTAssertEqual(drawn.first?.headlineID, "primary")
        XCTAssertEqual(drawn.first?.weeklyID, "secondary")
        let weekOnly = AppDelegate.drawn([codex], weekly: true, paced: false, fullest: false)
        XCTAssertEqual(weekOnly.first?.headlineID, "secondary")
    }

    func testSiblingsInTheHeadlinesOwnCycleNeverTakeTheRing() {
        let led = FullestHeadline.apply(to: snapshot(
            [window("auto", 0.2, days: 30), window("api", 0.9, days: 30), window("on_demand", 0.95, days: 30)],
            headline: "auto", weekly: nil))
        XCTAssertEqual(led.headlineID, "auto")
    }

    func testGroupedDeclaredWindowsStillCompete() {
        let led = FullestHeadline.apply(to: snapshot(
            [window("daily", 0.1, days: 1, group: "Usage"), window("weekly", 0.6, days: 7, group: "Usage")],
            headline: "daily", weekly: "weekly"))
        XCTAssertEqual(led.headlineID, "weekly")
        XCTAssertEqual(led.weeklyID, "daily")
    }

    func testAntigravityKeepsItsOwnLaneChoice() {
        let led = FullestHeadline.apply(to: snapshot(
            id: AntigravityProfile.defaultID,
            [window("gemini-hourly", 0.1), window("gemini-weekly", 0.9, days: 7)],
            headline: "gemini-hourly", weekly: "gemini-weekly"))
        XCTAssertEqual(led.headlineID, "gemini-hourly")
    }

    func testAMonetaryWindowNeverTakesTheRing() {
        let spend = UsageMoneyBreakdown(currency: "USD", spent: 60, remaining: 40)
        let led = FullestHeadline.apply(to: snapshot(
            [window("session", 0.1), window("seven_day", 0.2, days: 7), window("spend", 0.6, days: 30, money: spend)],
            headline: "session", weekly: "seven_day"))
        XCTAssertEqual(led.headlineID, "seven_day")
    }

    @MainActor
    func testThePreferenceIsOffByDefaultAndRemembered() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "FullestHeadlineTests.\(UUID().uuidString)"))
        XCTAssertFalse(Preferences(defaults: defaults).fullestLimitHeadline)
        Preferences(defaults: defaults).fullestLimitHeadline = true
        XCTAssertTrue(Preferences(defaults: defaults).fullestLimitHeadline)
    }
}
