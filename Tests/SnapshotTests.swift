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

/// The notch can show what is left instead of what is spent. The figure is
/// the tooltip's own left half, so the two never disagree by a point.
final class RemainingHeadlineTests: XCTestCase {
    private func snapshot(_ windows: [LimitWindow]) -> ProviderSnapshot {
        ProviderSnapshot(id: "p", displayName: "P", glyph: .claude,
                         fidelity: .official, status: .ok, windows: windows)
    }

    private func window(_ used: Double) -> LimitWindow {
        LimitWindow(id: "w", label: "W", usedFraction: used)
    }

    func testRemainingReadsFromTheOtherEnd() {
        let s = snapshot([window(0.125)])
        XCTAssertEqual(s.headlineText, "13%")
        XCTAssertEqual(s.headlineText(showingRemaining: true), "87%")
    }

    /// The left half derives from the *rounded* used figure — 9.5% used is
    /// "10% Used · 90% left" in the card, so the notch reads 90, not the 91
    /// one-minus-the-fraction would give.
    func testRemainingAgreesWithTheTooltipLeftHalf() {
        for (used, expected) in [(0.0, "100%"), (0.095, "90%"), (0.003, "99.7%"),
                                 (1.0, "0%"), (1.28, "0%")] as [(Double, String)] {
            let s = snapshot([window(used)])
            XCTAssertEqual(s.headlineText(showingRemaining: true), expected, "used \(used)")
            XCTAssertEqual(s.headlineText(showingRemaining: true),
                           Percent.halves(for: used).left + "%", "used \(used)")
        }
    }

    /// A count of what is left already reads from the asked-for end.
    func testRemainingCountsAreUnchanged() {
        let s = snapshot([LimitWindow(id: "r", label: "R", remaining: 2)])
        XCTAssertEqual(s.headlineText(showingRemaining: true), "2")
    }

    /// A used count has no remaining figure to show; the number stays rather
    /// than turning into a dash.
    func testUsedCountsAreUnchanged() {
        let s = snapshot([LimitWindow(id: "u", label: "U", used: 651_061)])
        XCTAssertEqual(s.headlineText(showingRemaining: true), "651k")
    }

    func testAnExplicitUsedTextIsUnchanged() {
        let s = snapshot([LimitWindow(id: "u", label: "U", usedFraction: 0.25,
                                      usedText: "$4.20 spent", prefersUsedText: true)])
        XCTAssertEqual(s.headlineText(showingRemaining: true), "$4.20 spent")
    }

    func testNoReadingIsStillADash() {
        XCTAssertEqual(snapshot([]).headlineText(showingRemaining: true), "—")
    }
}
