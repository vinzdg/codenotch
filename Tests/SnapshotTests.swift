import XCTest
@testable import Codenotch

final class SnapshotTests: XCTestCase {
    private func window(_ id: String, _ used: Double) -> LimitWindow {
        LimitWindow(id: id, label: id, usedFraction: used, resetsAt: Date())
    }

    private func snapshot(_ windows: [LimitWindow], fidelity: Fidelity = .derived) -> ProviderSnapshot {
        ProviderSnapshot(id: "p", displayName: "P", glyph: .claude,
                         fidelity: fidelity, status: .ok, windows: windows)
    }

    func testHeadlineIsThePrimaryWindow() {
        let s = snapshot([window("session", 0.73), window("all", 0.07)])
        XCTAssertEqual(s.headline?.id, "session")
        XCTAssertEqual(s.usedFraction ?? -1, 0.73, accuracy: 0.0001)
    }

    /// The headline stays on the session even when another window is higher.
    /// Picking the highest made the ring mean "session" one minute and "weekly"
    /// the next, which reads as the number being wrong — and disagrees with
    /// Claude's own panel, which always leads with the session.
    func testHeadlineDoesNotJumpToAHigherWindow() {
        let s = snapshot([window("session", 0.22), window("weekly_all", 0.24)])
        XCTAssertEqual(s.headline?.id, "session")
        XCTAssertEqual(s.usedFraction ?? -1, 0.22, accuracy: 0.0001)
    }

    /// The ring and the tooltip's top row are the same window, always.
    func testHeadlineMatchesTheFirstRowShown() {
        let s = snapshot([window("session", 0.05), window("weekly_all", 0.9)])
        XCTAssertEqual(s.headline?.id, s.windows.first?.id)
    }

    /// No windows is not "nothing used" — it is "nothing known", and the cell
    /// prints a dash rather than a confident zero.
    func testNoWindowsReadsAsNoReading() {
        XCTAssertNil(snapshot([]).usedFraction)
        XCTAssertEqual(snapshot([]).headlineText, "—")
        XCTAssertFalse(snapshot([]).hasReading)
    }

    /// A provider that reports only what is left gets a count, not a percentage.
    func testCountOnlyWindowsPrintTheCount() {
        let s = snapshot([LimitWindow(id: "remaining_pro", label: "Pro searches", remaining: 2)])
        XCTAssertNil(s.usedFraction)
        XCTAssertNil(s.ringFraction)
        XCTAssertEqual(s.headlineText, "2")
    }

    /// Token counts are seven digits wide and the ring is 44 pt; requests and
    /// credits are small enough to stay verbatim.
    func testLargeCountsAreCompacted() {
        XCTAssertEqual(LimitWindow.compact(9_999), "9999")
        XCTAssertEqual(LimitWindow.compact(651_061), "651k")
        XCTAssertEqual(LimitWindow.compact(1_128_771), "1.1M")
        XCTAssertEqual(LimitWindow.compact(2_000_000), "2.0M")
    }

    func testACountOnlyHeadlineIsCompacted() {
        let s = snapshot([LimitWindow(id: "month", label: "Tokens this month", used: 651_061)])
        XCTAssertEqual(s.headlineText, "651k")
    }

    func testOnlyOfficialNumbersAreShownUnqualified() {
        XCTAssertEqual(Fidelity.official.qualifier, "")
        XCTAssertEqual(Fidelity.derived.qualifier, "~")
        XCTAssertEqual(Fidelity.manual.qualifier, "~")
    }
}
