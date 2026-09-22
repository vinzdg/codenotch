import XCTest
@testable import Codenotch

/// The Tasks ring is a provider like any other, so it lives in the same
/// list, order and display settings as the usage rings.
final class TasksRingTests: XCTestCase {
    /// The provider always answers with a Today window, even before the task
    /// app has been read (0 of 0), so the ring exists from the first poll.
    @MainActor func testTheSnapshotHasATodayWindow() async throws {
        let snapshot = try await TasksProvider().fetchSnapshot()
        XCTAssertEqual(snapshot.id, TasksProvider.providerID)
        let focus = FocusStore.shared
        XCTAssertEqual(snapshot.glyph, focus.isActive ? (focus.isRunning ? .focus : .focusPaused) : .tasks)
        XCTAssertNotNil(snapshot.windows.first { $0.id == "today" })
        XCTAssertEqual(snapshot.headlineID, focus.isActive ? "focus" : "today")
    }

    /// The ring's glyphs are SF Symbols, not traced outlines.
    func testTheRingGlyphsAreSymbols() {
        XCTAssertEqual(ProviderGlyph.tasks.symbolName, "checklist")
        XCTAssertEqual(ProviderGlyph.focus.symbolName, "play.fill")
        XCTAssertEqual(ProviderGlyph.focusPaused.symbolName, "pause.fill")
        XCTAssertNil(ProviderGlyph.claude.symbolName)
        XCTAssertTrue(ProviderGlyph.tasks.outline.isEmpty)
    }

    /// The clock under a ring in focus: minutes and seconds, hours once there are any.
    @MainActor func testTheFocusClock() {
        XCTAssertEqual(FocusStore.clock(0), "00:00")
        XCTAssertEqual(FocusStore.clock(65), "01:05")
        XCTAssertEqual(FocusStore.clock(3600 + 60 + 5), "1:01:05")
    }

    /// The tasks card reserves a height the height math can ask for before
    /// anything is drawn, and it is never shorter than the card's own chrome.
    @MainActor func testTheTasksCardReservesAHeight() {
        XCTAssertGreaterThan(TasksCard.height(), 2 * NotchLayout.cardPadding)
        XCTAssertGreaterThanOrEqual(TasksCard.height(rows: 12), TasksCard.height(rows: 0))
    }
}
