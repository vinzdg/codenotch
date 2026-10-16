import XCTest
import AppKit
@testable import Codenotch

/// What a plain click on the menu bar item does, and the one thing that must
/// hold whatever the answer is: the menu stays reachable. With the app out of
/// the Dock it is the only way to Settings and to Quit.
@MainActor
final class StatusItemClickActionTests: XCTestCase {
    private func scratchDefaults() throws -> UserDefaults {
        let name = "StatusItemClickActionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// A controller with its item actually on the bar, since the routing is
    /// a property of the item and its button.
    private func shown(_ action: MenuBarClickAction) -> StatusItemController {
        let controller = StatusItemController(onOpenSettings: {})
        controller.clickAction = action
        controller.show()
        addTeardownBlock { @MainActor in controller.hide() }
        return controller
    }

    // MARK: - The default is the untouched path

    func testTheMenuIsTheDefault() throws {
        XCTAssertEqual(Preferences(defaults: try scratchDefaults()).menuBarClickAction, .menu)
        XCTAssertTrue(MenuBarClickAction.menu.opensMenuOnItsOwn)
        XCTAssertFalse(MenuBarClickAction.refresh.opensMenuOnItsOwn)
        XCTAssertFalse(MenuBarClickAction.activity.opensMenuOnItsOwn)
    }

    /// Nothing of ours between the click and the menu: the menu is on the
    /// item and AppKit tracks it, exactly as before this setting existed.
    func testTheMenuAnswerLeavesAppKitToIt() {
        let controller = shown(.menu)
        XCTAssertTrue(controller.menuIsOnTheItem)
        XCTAssertFalse(controller.buttonTakesTheClicks)
    }

    // MARK: - The answers that take the clicks

    func testTheOtherAnswersTakeTheClicksOffTheMenu() {
        for action in [MenuBarClickAction.refresh, .activity] {
            let controller = shown(action)
            XCTAssertFalse(controller.menuIsOnTheItem, "\(action)")
            XCTAssertTrue(controller.buttonTakesTheClicks, "\(action)")
        }
    }

    /// Changed while the item is up, not only at launch — and changed back
    /// restores the original arrangement rather than leaving the button with
    /// an action that will never fire.
    func testChangingTheAnswerRoutesTheClicksAgain() {
        let controller = shown(.menu)

        controller.clickAction = .refresh
        XCTAssertFalse(controller.menuIsOnTheItem)
        XCTAssertTrue(controller.buttonTakesTheClicks)

        controller.clickAction = .menu
        XCTAssertTrue(controller.menuIsOnTheItem)
        XCTAssertFalse(controller.buttonTakesTheClicks)
    }

    /// The menu is put back on the item to open it, and taken off once it
    /// closes — otherwise the click after a right-click would open a second
    /// menu instead of doing what was asked for.
    func testTheMenuIsHandedBackAfterItCloses() {
        let controller = shown(.refresh)
        let menu = NSMenu()

        controller.menuDidClose(menu)
        let settled = expectation(description: "the hand-back runs on the main queue")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 1)

        XCTAssertFalse(controller.menuIsOnTheItem)
        XCTAssertTrue(controller.buttonTakesTheClicks)
    }

    /// With the menu as the answer, closing one must not take it off: there
    /// is nothing to hand the clicks back to, and the next click would find
    /// no menu at all.
    func testClosingAMenuNeverStripsTheDefaultAnswer() {
        let controller = shown(.menu)

        controller.menuDidClose(NSMenu())
        let settled = expectation(description: "any async work has run")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 1)

        XCTAssertTrue(controller.menuIsOnTheItem)
    }

    // MARK: - What the menu still holds

    /// Whichever answer is chosen, the menu is the same menu: every provider
    /// read, then Refresh all, Activity, Settings and Quit.
    func testTheMenuIsUnchangedByTheAnswer() throws {
        for action in MenuBarClickAction.allCases {
            let controller = shown(action)
            let menu = NSMenu()
            controller.rebuild(menu: menu, now: Date())
            let titles = menu.items.map(\.title)
            for expected in ["Refresh all", "Activity…", "Settings…", "Quit Codenotch"] {
                XCTAssertTrue(titles.contains(expected), "\(action): \(titles)")
            }
        }
    }

    func testTheChosenAnswerSurvivesARestart() throws {
        let defaults = try scratchDefaults()
        Preferences(defaults: defaults).menuBarClickAction = .activity
        XCTAssertEqual(Preferences(defaults: defaults).menuBarClickAction, .activity)
    }
}
