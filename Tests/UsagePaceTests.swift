import XCTest
@testable import Codenotch

final class UsagePaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func pace(
        used: Double? = 0.5,
        remaining: TimeInterval? = 302400,
        duration: TimeInterval? = 604800
    ) -> UsagePace? {
        LimitWindow(id: "w", label: "Weekly", usedFraction: used,
                    resetsAt: remaining.map { now.addingTimeInterval($0) }, duration: duration)
            .usagePace(now: now)
    }

    func testCalculatesDeficitAndReserve() throws {
        let deficit = try XCTUnwrap(pace(used: 0.98, remaining: 86400))
        XCTAssertEqual(deficit.percentagePoints, 12.285714, accuracy: 0.00001)
        XCTAssertEqual(deficit.summary, "12.3% deficit")
        XCTAssertTrue(deficit.isDeficit)

        let reserved = try XCTUnwrap(pace(used: 0.27))
        XCTAssertEqual(reserved.percentagePoints, -23, accuracy: 0.00001)
        XCTAssertEqual(reserved.summary, "23% reserved")
        XCTAssertFalse(reserved.isDeficit)
    }

    func testUsesAnyReportedDuration() throws {
        let result = try XCTUnwrap(pace(used: 0.8, remaining: 36 * 3600, duration: 3 * 86400))
        XCTAssertEqual(result.percentagePoints, 30, accuracy: 0.00001)
    }

    func testAResetJustBeyondTheCycleStartsAtZeroElapsed() throws {
        let result = try XCTUnwrap(pace(used: 0.2, remaining: 604801))
        XCTAssertEqual(result.percentagePoints, 20, accuracy: 0.00001)
    }

    func testRequiresAValidCurrentWindow() {
        let invalid = [
            pace(used: nil), pace(used: .infinity), pace(used: -0.1),
            pace(remaining: nil), pace(remaining: 0),
            pace(duration: nil), pace(duration: 0), pace(duration: .infinity),
        ]
        for result in invalid { XCTAssertNil(result) }
    }

    func testFormattingKeepsTheSignAtSubTenthPrecision() throws {
        XCTAssertEqual(try XCTUnwrap(pace(used: 0.5004)).summary, "<0.1% deficit")
        XCTAssertEqual(try XCTUnwrap(pace(used: 0.4996)).summary, "<0.1% reserved")
        XCTAssertEqual(try XCTUnwrap(pace()).summary, "0% reserved")
    }

    func testDurationCodingRemainsBackwardCompatible() throws {
        let original = LimitWindow(id: "w", label: "Weekly", usedFraction: 0.98,
                                   resetsAt: now.addingTimeInterval(86400), duration: 604800)
        XCTAssertEqual(try JSONDecoder().decode(LimitWindow.self,
                       from: JSONEncoder().encode(original)), original)

        let archived = try JSONDecoder().decode(LimitWindow.self,
            from: Data(#"{"id":"w","label":"Weekly","usedFraction":0.98}"#.utf8))
        XCTAssertNil(archived.duration)
    }
}

final class UsageProjectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let month: TimeInterval = 30 * 86400

    private func projection(used: Double?, elapsedDays: Double) -> UsageProjection? {
        LimitWindow(id: "spend", label: "Spend limit", usedFraction: used,
                    resetsAt: now.addingTimeInterval(month - elapsedDays * 86400), duration: month)
            .usageProjection(now: now)
    }

    func testAQuietMonthLastsAndSaysWhereItEnds() throws {
        let result = try XCTUnwrap(projection(used: 0.038, elapsedDays: 10))
        XCTAssertEqual(result.fractionAtReset, 0.114, accuracy: 0.00001)
        XCTAssertNil(result.limitReachedAt)
        XCTAssertFalse(result.runsOut)
    }

    func testAHeavyMonthSaysWhenTheLimitRunsOut() throws {
        // Half gone in ten days: the other half lasts ten more.
        let result = try XCTUnwrap(projection(used: 0.5, elapsedDays: 10))
        XCTAssertEqual(result.fractionAtReset, 1.5, accuracy: 0.00001)
        let reachedAt = try XCTUnwrap(result.limitReachedAt)
        XCTAssertEqual(reachedAt.timeIntervalSince(now), 10 * 86400, accuracy: 1)
    }

    func testTheFirstFifteenthOfAWindowIsTooEarlyToTell() {
        XCTAssertNil(projection(used: 0.2, elapsedDays: 1))
        XCTAssertNotNil(projection(used: 0.2, elapsedDays: 2))
    }

    func testNothingToForecastOnceSpentOrWithoutAWindow() {
        XCTAssertNil(projection(used: 1, elapsedDays: 10))
        XCTAssertNil(projection(used: nil, elapsedDays: 10))
        XCTAssertNil(LimitWindow(id: "spend", label: "Spend limit", usedFraction: 0.5)
            .usageProjection(now: now))
    }
}

@MainActor
final class UsagePacePreferenceTests: XCTestCase {
    func testDefaultsOffAndSurvivesARelaunch() throws {
        let name = "UsagePacePreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(Preferences(defaults: defaults).showUsagePace)
        Preferences(defaults: defaults).showUsagePace = true
        XCTAssertTrue(Preferences(defaults: defaults).showUsagePace)
    }
}

final class BurnDeficitTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let week: TimeInterval = 7 * 86400

    private func window(used: Double, hoursLeft: Double) -> LimitWindow {
        LimitWindow(id: "w", label: "Weekly", usedFraction: used,
                    resetsAt: now.addingTimeInterval(hoursLeft * 3600), duration: week)
    }

    func testBurnIsRemainingMinusTimeLeft() throws {
        // 70% left with 23h of a week left: ~56 to burn.
        let urgent = try XCTUnwrap(window(used: 0.3, hoursLeft: 23).burnDeficitPoints(now: now))
        XCTAssertEqual(urgent, 56.3095, accuracy: 0.01)
        // 100% left with 6 days: ~14 to burn.
        let fresh = try XCTUnwrap(window(used: 0.0, hoursLeft: 6 * 24).burnDeficitPoints(now: now))
        XCTAssertEqual(fresh, 14.2857, accuracy: 0.0001)
        XCTAssertGreaterThan(urgent, fresh)
    }

    func testHeadlineBurnTakesTheLeadingWindow() throws {
        let session = LimitWindow(id: "session", label: "Session", usedFraction: 0.1,
                                  resetsAt: now.addingTimeInterval(4 * 3600), duration: 5 * 3600)
        let weekly = LimitWindow(id: "weekly_all", label: "Weekly", usedFraction: 0.3,
                                 resetsAt: now.addingTimeInterval(23 * 3600), duration: week)
        // Led by the session, the burn is the session's 10 points, however
        // urgent the week beside it is: the 5-hour window is the main
        // percentage, so its deficit is the one that orders the rings.
        let sessionLed = ProviderSnapshot(id: "p", displayName: "p", glyph: .claude,
                                          fidelity: .official, status: .ok,
                                          windows: [session, weekly],
                                          headlineID: "session", weeklyID: "weekly_all")
        XCTAssertEqual(try XCTUnwrap(sessionLed.headlineBurnDeficit(now: now)), 10, accuracy: 0.0001)
        // The weekly limit as the main ring reads the week's ~56 instead.
        let weeklyLed = ProviderSnapshot(id: "p", displayName: "p", glyph: .claude,
                                         fidelity: .official, status: .ok,
                                         windows: [session, weekly],
                                         headlineID: "weekly_all", weeklyID: "session")
        XCTAssertEqual(try XCTUnwrap(weeklyLed.headlineBurnDeficit(now: now)), 56.3095, accuracy: 0.01)
    }

    func testAClocklessHeadlineHasNoBurnEvenBesideATimedWeek() {
        // No fallback to the other window: a leading window with no cycle
        // has no deficit, so the timed week beside it cannot order the ring.
        let snapshot = ProviderSnapshot(
            id: "p", displayName: "p", glyph: .claude,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.3),
                      LimitWindow(id: "weekly_all", label: "Weekly", usedFraction: 0.3,
                                  resetsAt: now.addingTimeInterval(23 * 3600), duration: week)],
            headlineID: "session", weeklyID: "weekly_all")
        XCTAssertNil(snapshot.headlineBurnDeficit(now: now))
    }

    func testNoClockMeansNoBurn() {
        XCTAssertNil(LimitWindow(id: "w", label: "Weekly", usedFraction: 0.3).burnDeficitPoints(now: now))
        let snapshot = ProviderSnapshot(id: "p", displayName: "p", glyph: .claude,
                                        fidelity: .official, status: .ok,
                                        windows: [LimitWindow(id: "w", label: "W", usedFraction: 0.3)],
                                        headlineID: "w")
        XCTAssertNil(snapshot.headlineBurnDeficit(now: now))
    }
}

final class PaceMarkerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(
        used: Double? = 0.8,
        remaining: TimeInterval? = 2700,
        duration: TimeInterval? = 3600
    ) -> LimitWindow {
        LimitWindow(id: "w", label: "Session", usedFraction: used,
                    resetsAt: remaining.map { now.addingTimeInterval($0) }, duration: duration)
    }

    func testElapsedFractionMeasuresTheCycle() throws {
        XCTAssertEqual(try XCTUnwrap(window().elapsedFraction(now: now)), 0.25, accuracy: 1e-9)
    }

    func testElapsedFractionNeedsAResetAndADuration() {
        XCTAssertNil(window(remaining: nil).elapsedFraction(now: now))
        XCTAssertNil(window(duration: nil).elapsedFraction(now: now))
        XCTAssertNil(window(duration: 0).elapsedFraction(now: now))
        XCTAssertNil(window(duration: .infinity).elapsedFraction(now: now))
        XCTAssertNil(window(remaining: 0).elapsedFraction(now: now))
        XCTAssertNil(window(remaining: -10).elapsedFraction(now: now))
    }

    func testElapsedFractionStartsAtZeroPastTheCycle() throws {
        XCTAssertEqual(try XCTUnwrap(window(remaining: 3601).elapsedFraction(now: now)), 0, accuracy: 1e-9)
    }

    func testMarkerSitsOnElapsedInUsedMode() throws {
        XCTAssertEqual(try XCTUnwrap(window().paceMarkerFraction(now: now, showingRemaining: false)),
                       0.25, accuracy: 1e-9)
    }

    func testMarkerMirrorsToExpectedRemaining() throws {
        XCTAssertEqual(try XCTUnwrap(window().paceMarkerFraction(now: now, showingRemaining: true)),
                       0.75, accuracy: 1e-9)
    }

    func testMarkerAbsentWithoutAWindow() {
        XCTAssertNil(window(remaining: nil).paceMarkerFraction(now: now, showingRemaining: false))
        XCTAssertNil(window(remaining: nil).paceMarkerFraction(now: now, showingRemaining: true))
    }

    func testMarkerXStaysOnTheTrack() {
        XCTAssertEqual(paceMarkerX(position: 0.25, trackWidth: 536, markerWidth: 2), 133, accuracy: 1e-9)
        XCTAssertEqual(paceMarkerX(position: 0, trackWidth: 536, markerWidth: 2), 0, accuracy: 1e-9)
        XCTAssertEqual(paceMarkerX(position: 1, trackWidth: 536, markerWidth: 2), 534, accuracy: 1e-9)
    }
}
