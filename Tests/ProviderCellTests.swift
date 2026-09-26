import XCTest
@testable import Codenotch

/// The figure under the ring reads grey once the reading behind it has gone
/// stale — a white number would claim a freshness it no longer has.
final class ProviderCellReadingTests: XCTestCase {
    private func snapshot(status: ProviderStatus = .ok,
                          windows: [LimitWindow]? = nil) -> ProviderSnapshot {
        ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude,
                         fidelity: .official, status: status,
                         windows: windows ?? [LimitWindow(id: "session", label: "Session", usedFraction: 0.5)],
                         headlineID: "session")
    }

    func testFreshReadingIsWhite() {
        XCTAssertFalse(ProviderCell(snapshot: snapshot()).readingIsDimmed)
    }

    func testStaleReadingIsGrey() {
        let stale = snapshot(status: .stale(since: Date()), windows: [
            LimitWindow(id: "session", label: "Session", usedFraction: 0.5),
        ])
        XCTAssertTrue(ProviderCell(snapshot: stale).readingIsDimmed)
    }

    func testNoReadingIsGrey() {
        XCTAssertTrue(ProviderCell(snapshot: snapshot(windows: [])).readingIsDimmed)
    }

    func testLocalSpeedWithNothingMeasuredIsGrey() {
        var local = snapshot(windows: [])
        local.showsLocalPerformance = true
        local.localPerformance = nil
        XCTAssertTrue(ProviderCell(snapshot: local).readingIsDimmed)
    }

    func testWeekShutCellIsGreyEvenWithHeadlineRoom() {
        // Freshly confirmed room on the 5-hour beside a spent week: the room
        // is unusable, so the whole cell reads grey, not white-on-red.
        var shut = snapshot()
        shut.block = UsageBlock(reason: "Weekly limit reached", resetsAt: nil,
                                isWeeklyExhaustion: true)
        let cell = ProviderCell(snapshot: shut)
        XCTAssertTrue(cell.isWeeklyExhausted)
        XCTAssertTrue(cell.readingIsDimmed)
    }

    func testProviderPauseKeepsItsColours() {
        // A pause the provider reported itself — rate limited, not week-shut —
        // keeps the red ring and the white figure.
        var paused = snapshot()
        paused.block = UsageBlock(reason: "Rate limited", resetsAt: nil)
        let cell = ProviderCell(snapshot: paused)
        XCTAssertFalse(cell.isWeeklyExhausted)
        XCTAssertFalse(cell.readingIsDimmed)
    }
}
