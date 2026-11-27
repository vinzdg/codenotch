import XCTest
@testable import Codenotch

/// The conversation above the pill is as tall as what has been said, within
/// the room above the pill.
@MainActor
final class DockHistoryHeightTests: XCTestCase {
    func testShortConversationTakesOnlyItsOwnHeight() {
        // One short message, about 60 points tall: the pill grows by that
        // and the view's 6-point margin, not by the whole room.
        XCTAssertEqual(DockChatModel.historyExtraHeight(content: 60), 66)
    }

    func testNothingMeasuredYetStillLeavesALine() {
        XCTAssertEqual(DockChatModel.historyExtraHeight(content: 0), DockHistory.leastHeight + 6)
    }

    func testLongConversationStopsAtTheRoomAboveAndScrolls() {
        XCTAssertEqual(DockChatModel.historyExtraHeight(content: 5_000), DockChatController.roomAbove - 6)
    }

    func testGrowsWithTheConversation() {
        XCTAssertLessThan(DockChatModel.historyExtraHeight(content: 80),
                          DockChatModel.historyExtraHeight(content: 160))
    }
}
