import XCTest
@testable import Codenotch

/// The cost layer's seams into the app: the hover card reserves room for
/// the project rows, a credit-based Codex seat gets a Credits window, and the
/// money math anchors on the allowance rather than on token prices.
final class CostTests: XCTestCase {
    /// A Business seat reports no rolling windows; the spend control is its ring.
    func testCreditSeatGetsACreditsWindow() throws {
        let json = """
        {"plan_type":"business","rate_limit":null,"additional_rate_limits":null,"code_review_rate_limit":null,
         "spend_control":{"reached":false,"individual_limit":{"unit":"credit","limit":"2500","used":"310.13",
         "used_percent":12,"reset_at":1789430400}}}
        """
        let windows = try CodexUsage.windows(from: Data(json.utf8), now: Date(timeIntervalSince1970: 1_789_000_000))
        let credits = try XCTUnwrap(windows.first { $0.id == "credits" })
        XCTAssertEqual(credits.usedFraction ?? 0, 0.12, accuracy: 0.0001)
        XCTAssertEqual(credits.used, 310)
        XCTAssertEqual(credits.remaining, 2190)
        XCTAssertEqual(credits.resetsAt, Date(timeIntervalSince1970: 1_789_430_400))
    }

    /// Cost rows on the card add exactly what the section draws.
    func testCardHeightGrowsWithCostRows() {
        let base = NotchLayout.cardHeight(windowCount: 2)
        let withRows = NotchLayout.cardHeight(windowCount: 2, costRows: 3)
        let expected = NotchLayout.blockSpacing + NotchLayout.cardBodyLineHeight
            + 3 * (NotchLayout.cardBodyLineHeight + NotchLayout.sessionRowGap)
        XCTAssertEqual(withRows - base, expected, accuracy: 0.01)
        XCTAssertEqual(NotchLayout.cardHeight(windowCount: 2, costRows: 0), base)
    }

    /// Money for subscription work is the weekly share of the plan; a credit
    /// seat prices credits; an API account prices tokens.
    func testCostEstimatorModes() {
        let pricer = Pricer(prices: [ModelPrice(model: "claude-opus-5", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)], rate: 5)
        let period = (start: 0, end: 7 * 86_400, usedPct: 40.0, weight: 100.0)
        let plan = CostEstimator(billing: .subscription, monthlyPrice: 435, periods: [period], pricer: pricer)
        // Week = 435 ÷ 4.35 = 100; 40 % used = 40; this session was half the week's weight → 20.
        XCTAssertEqual(plan.cost(at: 10, weight: 50, model: "claude-opus-5", input: 0, output: 0, cacheRead: 0, cacheWrite: 0) ?? 0, 20, accuracy: 0.01)
        let credits = CostEstimator(billing: .subscription, monthlyPrice: 0, creditPointValue: 25, periods: [period], pricer: pricer)
        // 40 % of the cycle's credits × 25 per point = 1000; half the weight → 500.
        XCTAssertEqual(credits.cost(at: 10, weight: 50, model: "x", input: 0, output: 0, cacheRead: 0, cacheWrite: 0) ?? 0, 500, accuracy: 0.01)
        let api = CostEstimator(billing: .api, monthlyPrice: 0, periods: [], pricer: pricer)
        // 1M input at $5 + 1M output at $25 = $30 × rate 5 = 150.
        XCTAssertEqual(api.cost(at: 10, weight: 1, model: "claude-opus-5", input: 1_000_000, output: 1_000_000, cacheRead: 0, cacheWrite: 0) ?? 0, 150, accuracy: 0.01)
    }

    /// The card's range follows the account's allowance, never "all time".
    @MainActor func testCostRangeNeverStartsOnAllTime() {
        UserDefaults.standard.set("allTime", forKey: "costRange")
        let account = CostAccount(id: "test-x", provider: "claude", name: "Test", configDirectory: URL(fileURLWithPath: "/nonexistent"))
        let model = CostModel(account: account)
        XCTAssertNotEqual(model.range, .allTime)
        UserDefaults.standard.removeObject(forKey: "costRange")
    }

    // MARK: Reading gate

    private func usage(_ fraction: Double, id: String = "claude") -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: id, glyph: .claude, fidelity: .official, status: .ok,
                         windows: [LimitWindow(id: "session", label: "Session", usedFraction: fraction)])
    }

    private func runtime(_ models: Int) -> ProviderSnapshot {
        let names = (0..<models).map {
            LocalRuntimeReading.Model(name: "m\($0)", memoryBytes: 1, contextLength: 1,
                                      quantizationLevel: "Q4", memoryKind: .modelSize)
        }
        return ProviderSnapshot(id: "omlx", displayName: "oMLX", glyph: .third, fidelity: .official, status: .ok,
                                windows: [], kind: .localRuntime, localRuntime: LocalRuntimeReading(models: names))
    }

    /// A local runtime lands once a second, and its reading may well differ.
    /// Neither is a reason to touch the cost databases.
    func testGateIgnoresLocalRuntimes() {
        var gate = CostReadingGate()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(gate.admits([usage(0.1), runtime(0)], at: start))
        for second in 1..<Int(CostReadingGate.heartbeat) {
            XCTAssertFalse(gate.admits([usage(0.1), runtime(second % 3)],
                                       at: start.addingTimeInterval(TimeInterval(second))))
        }
    }

    /// Attribution is timed by when a rise is seen, so a change cannot wait.
    func testGatePassesAChangedReadingAtOnce() {
        var gate = CostReadingGate()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(gate.admits([usage(0.1)], at: start))
        XCTAssertTrue(gate.admits([usage(0.2)], at: start.addingTimeInterval(1)))
        XCTAssertTrue(gate.admits([usage(0.2), usage(0.5, id: "codex")], at: start.addingTimeInterval(2)))
        XCTAssertTrue(gate.admits([usage(0.5, id: "codex")], at: start.addingTimeInterval(3)))
    }

    /// `currentPeriod` reads the latest sample's time, so a quiet reading still
    /// has to be sampled now and then, counted from the last one that passed.
    /// There is no timer behind this: whichever update comes next carries it,
    /// and with a runtime connected that is usually the runtime's.
    func testGateLetsAnUnchangedReadingThroughOnTheHeartbeat() {
        var gate = CostReadingGate()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(gate.admits([usage(0.1)], at: start))
        XCTAssertFalse(gate.admits([usage(0.1)], at: start.addingTimeInterval(CostReadingGate.heartbeat - 1)))
        let beat = start.addingTimeInterval(CostReadingGate.heartbeat)
        XCTAssertTrue(gate.admits([usage(0.1)], at: beat))
        XCTAssertFalse(gate.admits([usage(0.1)], at: beat.addingTimeInterval(1)))
        let next = beat.addingTimeInterval(CostReadingGate.heartbeat)
        XCTAssertTrue(gate.admits([usage(0.1), runtime(1)], at: next))
    }

    // MARK: Activity window on daylight saving days

    private var newYork: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }

    private func local(_ cal: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// The clocks go back on 1 November 2026 in New York, so that day lasts
    /// 25 hours. A fixed 24 hour span ended the day at 11 PM and dropped the
    /// last hour's sessions from both that day and the next.
    func testActivityDayCoversAllTwentyFiveHoursWhenTheClocksGoBack() {
        let cal = newYork
        let day = cal.startOfDay(for: local(cal, 2026, 11, 1, 12))
        let span = TimelinePane.interval(of: .day, containing: day, calendar: cal)
        XCTAssertEqual(span.duration, 25 * 3600)
        XCTAssertTrue(span.contains(local(cal, 2026, 11, 1, 23, 30)))
        XCTAssertEqual(span.end, cal.startOfDay(for: local(cal, 2026, 11, 2, 12)))
    }

    /// The clocks go forward on 8 March 2026, a 23 hour day. A fixed 24 hour
    /// span reached into the first hour of 9 March.
    func testActivityDayStopsAtMidnightWhenTheClocksGoForward() {
        let cal = newYork
        let day = cal.startOfDay(for: local(cal, 2026, 3, 8, 12))
        let span = TimelinePane.interval(of: .day, containing: day, calendar: cal)
        XCTAssertEqual(span.duration, 23 * 3600)
        XCTAssertFalse(span.contains(local(cal, 2026, 3, 9, 0, 30)))
    }

    /// The lane chart's axis is labelled in clock hours, so a session must be
    /// placed by its clock time, not by seconds since midnight, or every bar
    /// after the change sits an hour away from its label.
    func testActivityLanesPlaceSessionsByClockTimeOnChangeDays() {
        let cal = newYork
        let march = cal.startOfDay(for: local(cal, 2026, 3, 8, 12))
        XCTAssertEqual(TimelinePane.clockHours(local(cal, 2026, 3, 8, 10), on: march, calendar: cal), 10, accuracy: 0.0001)
        let november = cal.startOfDay(for: local(cal, 2026, 11, 1, 12))
        XCTAssertEqual(TimelinePane.clockHours(local(cal, 2026, 11, 1, 23, 30), on: november, calendar: cal), 23.5, accuracy: 0.0001)
    }

    /// An ordinary day keeps the old placement, and a session that runs past
    /// midnight still lands beyond the end of the axis so its bar is clamped
    /// to the right edge instead of wrapping back to the left.
    func testActivityLanesKeepOrdinaryDaysAndOverflowPastMidnight() {
        let cal = newYork
        let day = cal.startOfDay(for: local(cal, 2026, 6, 10, 12))
        XCTAssertEqual(TimelinePane.interval(of: .day, containing: day, calendar: cal).duration, 24 * 3600)
        XCTAssertEqual(TimelinePane.clockHours(local(cal, 2026, 6, 10, 14, 15), on: day, calendar: cal), 14.25, accuracy: 0.0001)
        XCTAssertGreaterThan(TimelinePane.clockHours(local(cal, 2026, 6, 11, 0, 30), on: day, calendar: cal), 24)
        XCTAssertLessThan(TimelinePane.clockHours(local(cal, 2026, 6, 9, 23, 30), on: day, calendar: cal), 0)
    }
}
