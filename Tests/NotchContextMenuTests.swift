import AppKit
import XCTest
@testable import Codenotch

@MainActor
final class NotchContextMenuTests: XCTestCase {
    func testContextMenuStructureAndConsolidation() {
        let controller = NotchWindowController()
        let menu = controller.contextMenu()

        let nonSeparators = menu.items.filter { !$0.isSeparatorItem }
        let titles = nonSeparators.map(\.title)

        XCTAssertEqual(titles, [
            L10n.t("Keep open"),
            L10n.t("Refresh now"),
            L10n.t("Settings…"),
            L10n.t("Quit Codenotch")
        ])

        let refreshItem = menu.items.first { $0.title == L10n.t("Refresh now") }
        XCTAssertEqual(refreshItem?.keyEquivalent, "r")

        let settingsItem = menu.items.first { $0.title == L10n.t("Settings…") }
        XCTAssertEqual(settingsItem?.keyEquivalent, ",")

        let quitItem = menu.items.first { $0.title == L10n.t("Quit Codenotch") }
        XCTAssertEqual(quitItem?.keyEquivalent, "q")

        for item in menu.items {
            XCTAssertFalse(item.title.contains("Sign in to"), "Found provider sign-in item in menu: \(item.title)")
        }
    }
}
