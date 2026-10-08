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
