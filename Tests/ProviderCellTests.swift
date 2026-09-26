import XCTest
@testable import Codenotch

/// The figure under the ring reads grey once the reading behind it has gone
/// stale — a white number would claim a freshness it no longer has.
final class ProviderCellTests: XCTestCase {
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
        // is unusable, so in remaining mode the whole cell reads grey, not
        // white-on-red.
        var shut = snapshot()
        shut.block = UsageBlock(reason: "Weekly limit reached", resetsAt: nil,
                                isWeeklyExhaustion: true)
        let cell = ProviderCell(snapshot: shut, showsRemaining: true)
        XCTAssertTrue(cell.isWeeklyExhausted)
        XCTAssertTrue(cell.readingIsDimmed)
    }

    func testWeekShutCellKeepsColoursInUsedMode() {
        // The grey week is a remaining-mode reading. Where the figure says
        // what was spent, a spent week is 100% like anything else spent —
        // red, not grey — so the figure stays white.
        var shut = snapshot()
        shut.block = UsageBlock(reason: "Weekly limit reached", resetsAt: nil,
                                isWeeklyExhaustion: true)
        let cell = ProviderCell(snapshot: shut)
        XCTAssertTrue(cell.isWeeklyExhausted)
        XCTAssertFalse(cell.readingIsDimmed)
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

    func testExhaustedWeekGreysRingsOnlyInRemainingMode() {
        let remaining = ProviderRing(usedFraction: 0.3, glyph: .claude,
                                     showsRemaining: true, weeklyExhausted: true)
        XCTAssertTrue(remaining.showsExhaustedWeekGrey)
        let used = ProviderRing(usedFraction: 0.3, glyph: .claude, weeklyExhausted: true)
        XCTAssertFalse(used.showsExhaustedWeekGrey)
        let unspent = ProviderRing(usedFraction: 0.3, glyph: .claude, showsRemaining: true)
        XCTAssertFalse(unspent.showsExhaustedWeekGrey)
    }
}
