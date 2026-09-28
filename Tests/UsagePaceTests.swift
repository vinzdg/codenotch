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

    private func projection(
        used: Double? = 0.75,
        remaining: TimeInterval? = 9000,
        duration: TimeInterval? = 18000
    ) -> UsageProjection? {
        LimitWindow(id: "w", label: "Session", usedFraction: used,
                    resetsAt: remaining.map { now.addingTimeInterval($0) }, duration: duration)
            .projection(now: now)
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testProjectsTheAverageRateToTheLimit() throws {
        // 75% in 2h 30m: the last 25% takes 50m, 1h 40m before the reset.
        let result = try XCTUnwrap(projection())
        XCTAssertEqual(result.hitAt.timeIntervalSince(now), 3000, accuracy: 0.001)
        XCTAssertEqual(result.early, 6000, accuracy: 0.001)
        XCTAssertEqual(result.summary(now: now, calendar: utc, locale: Locale(identifier: "en_GB")),
                       "~100% around 08:50 · 1h 40m early")
    }

    func testNamesTheDayWhenTheLimitIsReachedOnAnotherDay() throws {
        let result = try XCTUnwrap(projection(used: 0.75, remaining: 302400, duration: 604800))
        XCTAssertEqual(result.hitAt.timeIntervalSince(now), 100800, accuracy: 0.001)
        XCTAssertEqual(result.summary(now: now, calendar: utc, locale: Locale(identifier: "en_GB")),
                       "~100% around Sat 12:00 · 2d 8h early")
    }

    func testNamesTheDateWhenTheLimitIsAWeekOrMoreAway() throws {
        let result = try XCTUnwrap(projection(used: 0.2, remaining: 25 * 86400, duration: 30 * 86400))
        XCTAssertEqual(result.summary(now: now, calendar: utc, locale: Locale(identifier: "en_GB")),
                       "~100% around 4 Feb · 5d early")
    }

    func testNoProjectionWithoutADeficitOrTooEarly() {
        XCTAssertNil(projection(used: 0.5), "on pace reaches 100% at the reset, not before")
        XCTAssertNil(projection(used: 0.3), "in reserve")
        XCTAssertNil(projection(used: 1.0), "already spent")
        XCTAssertNil(projection(used: 1.2), "overdrawn")
        // 4% of the window elapsed: 17280s left of 18000s.
        XCTAssertNil(projection(used: 0.2, remaining: 17280), "too early to extrapolate")
        XCTAssertNotNil(projection(used: 0.2, remaining: 17100), "5% elapsed is enough")
    }

    func testNoProjectionWithoutAValidWindow() {
        let invalid = [
            projection(used: nil), projection(used: .nan),
            projection(remaining: nil), projection(remaining: 0), projection(remaining: -60),
            projection(duration: nil), projection(duration: 0), projection(duration: .infinity),
        ]
        for result in invalid { XCTAssertNil(result) }
    }

    func testEarlyDurationSwitchesToDaysFromADay() {
        XCTAssertEqual(UsageProjection.duration(59 * 60), "59m")
        XCTAssertEqual(UsageProjection.duration(6000), "1h 40m")
        XCTAssertEqual(UsageProjection.duration(86400), "1d")
        XCTAssertEqual(UsageProjection.duration(201600), "2d 8h")
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

final class UsageProjectionLayoutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(_ used: [Double]) -> ProviderSnapshot {
        ProviderSnapshot(
            id: "claude", displayName: "Claude", glyph: .claude, fidelity: .official, status: .ok,
            windows: used.enumerated().map { index, fraction in
                LimitWindow(id: "w\(index)", label: "Window", usedFraction: fraction,
                            resetsAt: now.addingTimeInterval(9000), duration: 18000)
            }
        )
    }

    func testCountsOnlyProjectedRowsAndOnlyWithPaceOn() {
        let reading = snapshot([0.75, 0.3])
        XCTAssertEqual(reading.projectionRowCount(now: now, showsUsagePace: true), 1)
        XCTAssertEqual(reading.projectionRowCount(now: now, showsUsagePace: false), 0)
    }

    func testEachProjectionRowAddsExactlyOneLine() {
        let plain = NotchLayout.cardHeight(windowCount: 2)
        let projected = NotchLayout.cardHeight(windowCount: 2, projectionRowCount: 1)
        XCTAssertEqual(projected - plain,
                       NotchLayout.projectionGap + NotchLayout.cardBodyLineHeight, accuracy: 0.001)
    }

    func testProjectionRowsLeaveLessRoomForSessions() {
        // Built like `sessionsFitting` builds its own cards, so five fit exactly.
        let budget = NotchLayout.cardHeight(windowCount: NotchLayout.maxWindowCount, groupCount: 2,
                                            sessionCount: 6, sessionCap: 5)
        let without = NotchLayout.sessionsFitting(cardBudget: budget,
                                                  windowCount: NotchLayout.maxWindowCount)
        let with = NotchLayout.sessionsFitting(cardBudget: budget,
                                               windowCount: NotchLayout.maxWindowCount,
                                               projectionRowCount: NotchLayout.maxWindowCount)
        XCTAssertLessThan(with, without)
    }
}
