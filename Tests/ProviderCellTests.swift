import XCTest
@testable import Codenotch

/// The figure under the ring reads grey only when a window is actually
/// spent — the 5-hour or the weekly — and only in remaining mode. Grey means
/// "nothing usable", and neither staleness, nor a missing reading, nor an
/// unmeasured speed says that.
final class ProviderCellTests: XCTestCase {
    private let spentWeek = [
        LimitWindow(id: "session", label: "Session", usedFraction: 0.5),
        LimitWindow(id: "weekly_all", label: "Weekly", usedFraction: 1.0),
    ]
    private let spentSession = [
        LimitWindow(id: "session", label: "Session", usedFraction: 1.0),
        LimitWindow(id: "weekly_all", label: "Weekly", usedFraction: 0.3),
    ]

    private func snapshot(status: ProviderStatus = .ok,
                          windows: [LimitWindow]? = nil,
                          weeklyID: String? = nil) -> ProviderSnapshot {
        ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude,
                         fidelity: .official, status: status,
                         windows: windows ?? [LimitWindow(id: "session", label: "Session", usedFraction: 0.5)],
                         headlineID: "session", weeklyID: weeklyID)
    }

    func testFreshReadingIsWhite() {
        XCTAssertFalse(ProviderReading(snapshot: snapshot()).isDimmed)
    }

    func testStaleReadingWithRoomStaysWhite() {
        // Staleness no longer dims the figure: a grey 27% beside full quota
        // reads as "spent", and the reading is merely old.
        let stale = snapshot(status: .stale(since: Date()), windows: [
            LimitWindow(id: "session", label: "Session", usedFraction: 0.5),
        ])
        XCTAssertFalse(ProviderReading(snapshot: stale, showsRemaining: true).isDimmed)
    }

    func testNoReadingStaysWhite() {
        XCTAssertFalse(ProviderReading(snapshot: snapshot(windows: []), showsRemaining: true).isDimmed)
    }

    func testLocalSpeedWithNothingMeasuredStaysWhite() {
        var local = snapshot(windows: [])
        local.showsLocalPerformance = true
        local.localPerformance = nil
        XCTAssertFalse(ProviderReading(snapshot: local, showsRemaining: true).isDimmed)
    }

    func testWeekShutCellIsGreyEvenWithHeadlineRoom() {
        // Freshly confirmed room on the 5-hour beside a spent week: the room
        // is unusable, so in remaining mode the figure reads grey. Judged off
        // the fractions, not the block the store attached.
        let shut = snapshot(windows: spentWeek, weeklyID: "weekly_all")
        let reading = ProviderReading(snapshot: shut, showsRemaining: true)
        XCTAssertTrue(reading.isDimmed)
    }

    func testHeadlineSpentCellIsGreyInRemainingMode() {
        // The other half of the rule: a spent 5-hour with a healthy week —
        // Codex at 0% left — greys the figure too.
        let shut = snapshot(windows: spentSession, weeklyID: "weekly_all")
        let reading = ProviderReading(snapshot: shut, showsRemaining: true)
        XCTAssertTrue(reading.isDimmed)
    }

    func testSpentWindowsKeepColoursInUsedMode() {
        // The grey is a remaining-mode reading. Where the figure says what
        // was spent, spent windows are 100% like anything else spent — red,
        // not grey — so the figure stays white even with both spent.
        let shut = snapshot(windows: [
            LimitWindow(id: "session", label: "Session", usedFraction: 1.0),
            LimitWindow(id: "weekly_all", label: "Weekly", usedFraction: 1.0),
        ], weeklyID: "weekly_all")
        let reading = ProviderReading(snapshot: shut)
        XCTAssertFalse(reading.isDimmed)
    }

    func testProviderPauseKeepsItsColours() {
        // A pause the provider reported itself — rate limited, not week-shut —
        // keeps the red ring and the white figure.
        var paused = snapshot()
        paused.block = UsageBlock(reason: "Rate limited", resetsAt: nil)
        let cell = ProviderCell(snapshot: paused)
        XCTAssertFalse(cell.isWeeklyExhausted)
        XCTAssertFalse(ProviderReading(snapshot: paused).isDimmed)
    }

    func testShutRingsNeedTheSettingAndASpentWindow() {
        // A spent week shuts, on by default.
        let weekShut = ProviderRing(usedFraction: 0.3, glyph: .claude, weeklyExhausted: true)
        XCTAssertTrue(weekShut.showsShutRings)
        // A spent 5-hour with no block: the headline fraction alone shuts.
        let sessionShut = ProviderRing(usedFraction: 1.0, glyph: .claude)
        XCTAssertTrue(sessionShut.showsShutRings)
        // The setting off keeps every ring its own colour, however spent.
        let off = ProviderRing(usedFraction: 1.0, glyph: .claude,
                               weeklyExhausted: true, shutRingsWhenSpent: false)
        XCTAssertFalse(off.showsShutRings)
        // Nothing spent, nothing shut.
        let healthy = ProviderRing(usedFraction: 0.3, glyph: .claude)
        XCTAssertFalse(healthy.showsShutRings)
    }

    // MARK: - Pace / Deficit Marker on Progress Rings

    func testDeficitMarkerOnHeadlineRingAppearsWhenSettingEnabled() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let timedWindow = LimitWindow(id: "session", label: "Session", usedFraction: 0.6,
                                      resetsAt: now.addingTimeInterval(2.5 * 3600), duration: 5 * 3600)
        let s = ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude,
                                 fidelity: .official, status: .ok, windows: [timedWindow],
                                 headlineID: "session")

        // Setting off: marker is nil
        let cellOff = ProviderCell(snapshot: s, showsUsagePace: false, now: now)
        XCTAssertNil(cellOff.headlinePaceMarker)

        // Setting on: 2.5h of 5h elapsed = 0.5 marker position
        let cellOn = ProviderCell(snapshot: s, showsUsagePace: true, now: now)
        XCTAssertEqual(cellOn.headlinePaceMarker!, 0.5, accuracy: 1e-6)

        // Remaining mode: 1 - 0.5 = 0.5
        let cellRemaining = ProviderCell(snapshot: s, showsRemaining: true, showsUsagePace: true, now: now)
        XCTAssertEqual(cellRemaining.headlinePaceMarker!, 0.5, accuracy: 1e-6)
    }

    func testDeficitMarkerOnWeeklyRingAppearsWhenWeeklyRingActive() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = LimitWindow(id: "session", label: "Session", usedFraction: 0.3,
                                  resetsAt: now.addingTimeInterval(3600), duration: 5 * 3600)
        let weekly = LimitWindow(id: "weekly_all", label: "Weekly", usedFraction: 0.8,
                                 resetsAt: now.addingTimeInterval(86400), duration: 7 * 86400)
        let s = ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude,
                                 fidelity: .official, status: .ok, windows: [session, weekly],
                                 headlineID: "session", weeklyID: "weekly_all")

        // Weekly ring off: weekly marker is nil
        let cellWeeklyOff = ProviderCell(snapshot: s, weeklyRing: .off, showsUsagePace: true, now: now)
        XCTAssertNil(cellWeeklyOff.weeklyPaceMarker)

        // Weekly ring on (.inside or .outside): weekly marker is computed
        let cellWeeklyOn = ProviderCell(snapshot: s, weeklyRing: .inside, showsUsagePace: true, now: now)
        let expectedWeekly = weekly.paceMarkerFraction(now: now, showingRemaining: false)!
        XCTAssertEqual(cellWeeklyOn.weeklyPaceMarker!, expectedWeekly, accuracy: 1e-6)
    }

    func testDeficitMarkerAbsentWithoutResetTimeOrForLocalModel() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let untimed = LimitWindow(id: "session", label: "Session", usedFraction: 0.4)
        let sUntimed = ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude,
                                        fidelity: .official, status: .ok, windows: [untimed],
                                        headlineID: "session")
        let cellUntimed = ProviderCell(snapshot: sUntimed, showsUsagePace: true, now: now)
        XCTAssertNil(cellUntimed.headlinePaceMarker)

        var local = ProviderSnapshot(id: "ollama", displayName: "Ollama", glyph: .ollama,
                                     fidelity: .official, status: .ok, windows: [untimed],
                                     kind: .localRuntime)
        local.localModel = LocalRuntimeReading.Model(name: "llama3", memoryBytes: 1024, contextLength: 4096, quantizationLevel: "Q4_0")
        let cellLocal = ProviderCell(snapshot: local, showsUsagePace: true, now: now)
        XCTAssertNil(cellLocal.headlinePaceMarker)
    }
}
