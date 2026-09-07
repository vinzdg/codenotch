import XCTest
@testable import Codenotch

/// The context menu's "Hide for an hour", and its interaction with launch.
@MainActor
final class TimedHideTests: XCTestCase {
    private func makePreferences(hiddenUntil: Date?) -> Preferences {
        let name = "TimedHideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let preferences = Preferences(defaults: defaults)
        preferences.hiddenUntil = hiddenUntil
        return preferences
    }

    /// Found live: a relaunch while the timed hide was in force showed the
    /// notch for up to half a minute before the clock tick noticed. The
    /// suppression has to be applied by the first visibility delivery.
    func testARelaunchWhileHiddenStartsHidden() {
        let controller = NotchWindowController()
        // Held strongly: the controller's reference is weak by design.
        let preferences = makePreferences(hiddenUntil: Date().addingTimeInterval(3600))
        controller.preferences = preferences
        controller.apply(.onHover)
        XCTAssertFalse(controller.model.isAlwaysOn)
        XCTAssertFalse(controller.model.isExpanded)
    }

    func testAnExpiredHideBehavesAsChosen() {
        let controller = NotchWindowController()
        let preferences = makePreferences(hiddenUntil: Date().addingTimeInterval(-60))
        controller.preferences = preferences
        controller.apply(.alwaysShow)
        XCTAssertTrue(controller.model.isAlwaysOn)
        XCTAssertTrue(controller.model.isExpanded)
    }

    /// Restoring the Settings choice once the hide is over must not need the
    /// clock: the next visibility delivery sees the reprieve is spent.
    func testTheChoiceReturnsWhenTheReprieveIsSpent() {
        let controller = NotchWindowController()
        let preferences = makePreferences(hiddenUntil: Date().addingTimeInterval(3600))
        controller.preferences = preferences

        controller.apply(.onHover)
        XCTAssertFalse(controller.model.isExpanded)

        preferences.hiddenUntil = nil
        controller.apply(.onHover)
        XCTAssertTrue(controller.model.isAlwaysOn == false, "hover mode is not always-on")
        XCTAssertFalse(controller.model.staysOpen)
    }

    /// The menu item's own action hides immediately, without waiting for the
    /// clock that expires it.
    func testHideForAnHourActsImmediately() {
        let controller = NotchWindowController()
        let preferences = makePreferences(hiddenUntil: nil)
        controller.preferences = preferences
        controller.apply(.onHover)

        controller.hideForAnHour()
        XCTAssertFalse(controller.model.isExpanded)
        XCTAssertNotNil(preferences.hiddenUntil)
    }
}
