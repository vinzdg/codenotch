import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Codenotch

@MainActor
final class FullScreenAutoFoldTests: XCTestCase {
    func testDetectorFindsFullScreenWindowMatchingScreenBounds() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let pid: pid_t = 12345
        let windows: [(pid: pid_t, layer: Int, bounds: CGRect)] = [
            (pid: 9999, layer: 0, bounds: CGRect(x: 50, y: 50, width: 800, height: 600)),
            (pid: pid, layer: 0, bounds: screen),
            (pid: pid, layer: 24, bounds: screen) // menu bar or overlay
        ]

        XCTAssertTrue(FullScreenDetector.isFullScreen(screenBounds: screen, frontmostPID: pid, windows: windows))
    }

    func testDetectorFindsFullScreenWindowOnNotchedDisplay() {
        // On a MacBook with camera notch, CoreGraphics screen origin is (0, 0)
        // and full-screen windows start below the notch/menu bar (e.g. y=44)
        // extending to the bottom edge (height = 1117 - 44 = 1073).
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let pid: pid_t = 12345
        let windows: [(pid: pid_t, layer: Int, bounds: CGRect)] = [
            (pid: pid, layer: 0, bounds: CGRect(x: 0, y: 44, width: 1728, height: 1073))
        ]

        XCTAssertTrue(
            FullScreenDetector.isFullScreen(
                screenBounds: screen,
                frontmostPID: pid,
                windows: windows,
                safeAreaTopInset: 44
            ),
            "Full-screen window starting below the notch and reaching screen bottom must be detected"
        )
    }


    func testDetectorRejectsWindowWhenNotMatchingScreenBounds() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let pid: pid_t = 12345
        let windows: [(pid: pid_t, layer: Int, bounds: CGRect)] = [
            (pid: pid, layer: 0, bounds: CGRect(x: 100, y: 100, width: 1200, height: 800))
        ]

        XCTAssertFalse(FullScreenDetector.isFullScreen(screenBounds: screen, frontmostPID: pid, windows: windows))
    }

    func testDetectorRejectsFullScreenWindowOfNonFrontmostApp() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let frontPID: pid_t = 12345
        let otherPID: pid_t = 67890
        let windows: [(pid: pid_t, layer: Int, bounds: CGRect)] = [
            (pid: otherPID, layer: 0, bounds: screen)
        ]

        XCTAssertFalse(FullScreenDetector.isFullScreen(screenBounds: screen, frontmostPID: frontPID, windows: windows))
    }

    func testControllerAutoFoldsWhenActiveSpaceChangesToFullScreen() throws {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        // `handleActiveSpaceOrAppChange` refuses to fold out from under the
        // pointer, so this asserts nothing on a machine where the notch has
        // landed beneath it — which depends on what earlier tests left in
        // `Preferences`, not on this test.
        try skipIfPointerOnNotch(controller)

        controller.model.isExpanded = true
        controller.model.isPinned = false
        controller.model.isAlwaysOn = true
        controller.isFullScreenActive = { true }

        // Post active space changed notification
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        XCTAssertFalse(controller.model.isExpanded, "The notch must fold when entering a full-screen space")
    }

    func testControllerDoesNotFoldWhenPinnedAndActiveSpaceChangesToFullScreen() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        controller.model.isExpanded = true
        controller.model.isPinned = true
        controller.isFullScreenActive = { true }

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        XCTAssertTrue(controller.model.isExpanded, "A pinned notch must survive entering a full-screen space")
        XCTAssertTrue(controller.model.isPinned)
    }

    func testControllerAutoFoldsWhenFullscreenAppActivates() throws {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        // `handleActiveSpaceOrAppChange` refuses to fold out from under the
        // pointer, so this asserts nothing on a machine where the notch has
        // landed beneath it — which depends on what earlier tests left in
        // `Preferences`, not on this test.
        try skipIfPointerOnNotch(controller)

        controller.model.isExpanded = true
        controller.isFullScreenActive = { true }

        // Post application activation notification
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        XCTAssertFalse(controller.model.isExpanded, "The notch must fold when a full-screen app activates")
    }

    func testControllerDoesNotFoldWhenAppIsNotFullScreen() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        controller.model.isExpanded = true
        controller.isFullScreenActive = { false }

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        XCTAssertTrue(controller.model.isExpanded, "The notch should stay open if the active space is not full-screen")
    }

    func testControllerDoesNotFoldWhenAutoFoldIsOff() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        controller.model.isAlwaysOn = true
        controller.model.isExpanded = true
        controller.foldsForFullScreen = false
        controller.isFullScreenActive = { true }
        controller.handleActiveSpaceOrAppChange()

        XCTAssertTrue(controller.model.isExpanded, "With the fold off, a full-screen app must leave the notch alone")
    }

    func testApplyAutoFoldReEvaluatesImmediately() throws {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        // `handleActiveSpaceOrAppChange` refuses to fold out from under the
        // pointer, so this asserts nothing on a machine where the notch has
        // landed beneath it — which depends on what earlier tests left in
        // `Preferences`, not on this test.
        try skipIfPointerOnNotch(controller)

        controller.model.isAlwaysOn = true
        controller.model.isExpanded = true
        controller.foldsForFullScreen = false
        controller.isFullScreenActive = { true }
        controller.handleActiveSpaceOrAppChange()
        XCTAssertTrue(controller.model.isExpanded)

        controller.apply(foldsForFullScreen: true)
        XCTAssertFalse(controller.model.isExpanded, "Re-enabling the fold under a frontmost full-screen app must fold now, not on the next cursor poll")
    }

    /// The pointer has to be off the notch for the hover fold to run; on a
    /// machine where it happens to be parked inside, skip rather than guess.
    private func skipIfPointerOnNotch(_ controller: NotchWindowController) throws {
        if let frame = controller.panelFrameForTesting,
           frame.contains(NSEvent.mouseLocation) {
            throw XCTSkip("Pointer is parked on the notch")
        }
    }

    func testHoverFoldDoesNotOutVoteAlwaysShowWhenAutoFoldIsOff() throws {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        controller.model.isAlwaysOn = true
        controller.model.isExpanded = true
        controller.foldsForFullScreen = false
        controller.isFullScreenActive = { true }
        try skipIfPointerOnNotch(controller)

        // The hover fold is the second place full-screen is consulted, and it
        // must not out-vote Always show once the fold is switched off —
        // ungated, it folds every cursor poll while the other path restores.
        controller.cursorMoved()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        XCTAssertTrue(controller.model.isExpanded, "The hover fold must not fire once the full-screen fold is off")
    }

    func testHoverFoldStillFoldsOnHoverNotchWhenAutoFoldIsOff() throws {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        // onHover and unpinned: staysOpen is false, so the pointer leaving
        // still folds — the setting governs full-screen, not hover behaviour.
        controller.model.isExpanded = true
        controller.foldsForFullScreen = false
        controller.isFullScreenActive = { true }
        try skipIfPointerOnNotch(controller)

        controller.cursorMoved()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        XCTAssertFalse(controller.model.isExpanded, "An on-hover notch must still fold when the pointer leaves")
    }

    /// Answering "is a full-screen app in front" copies every window's
    /// description out of WindowServer, and `cursorMoved` runs for every mouse
    /// event on the screen. Asked on each one, it was nearly all of the app's
    /// CPU while the pointer moved, so it is only asked when "Always show"
    /// is what stands between the notch and a fold.
    func testPointerMovementOnlyAsksAboutFullScreenWhenAlwaysShowIsAtStake() throws {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        var asked = 0
        controller.isFullScreenActive = { asked += 1; return false }
        try skipIfPointerOnNotch(controller)

        // Folded: nothing to fold, nothing to ask.
        controller.model.isExpanded = false
        for _ in 0..<50 { controller.cursorMoved() }
        XCTAssertEqual(asked, 0, "A folded notch must not ask WindowServer on pointer movement")

        // Open on hover: it folds whatever the answer, so there is no question.
        controller.model.isExpanded = true
        for _ in 0..<50 { controller.cursorMoved() }
        XCTAssertEqual(asked, 0, "An on-hover notch must not ask WindowServer on pointer movement")

        // Always show: the answer decides whether it folds, so it is asked.
        // A fresh controller, because the on-hover pass above left its fold
        // scheduled, and a scheduled fold is not asked about twice.
        let alwaysOn = NotchWindowController()
        alwaysOn.show()
        defer { alwaysOn.stop() }
        var alwaysOnAsked = 0
        alwaysOn.isFullScreenActive = { alwaysOnAsked += 1; return false }
        alwaysOn.model.isAlwaysOn = true
        alwaysOn.model.isExpanded = true
        try skipIfPointerOnNotch(alwaysOn)
        alwaysOn.cursorMoved()
        XCTAssertEqual(alwaysOnAsked, 1, "Always show must still consult full-screen state")
        XCTAssertTrue(alwaysOn.model.isExpanded)
    }

    func testSwitchingAutoFoldOffCancelsAPendingFold() throws {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        controller.model.isAlwaysOn = true
        controller.model.isExpanded = true
        controller.isFullScreenActive = { true }
        try skipIfPointerOnNotch(controller)

        // Scheduled while the fold was still on, so the work item already
        // holds ignoreAlwaysOn — without a cancel it lands once against the
        // always-on notch even though the setting is now off.
        controller.cursorMoved()
        controller.apply(foldsForFullScreen: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        XCTAssertTrue(controller.model.isExpanded, "A fold in flight must not land after the setting is switched off")
    }

    func testAlwaysOnRestoresExpandedWhenLeavingFullScreen() throws {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        // `handleActiveSpaceOrAppChange` refuses to fold out from under the
        // pointer, so this asserts nothing on a machine where the notch has
        // landed beneath it — which depends on what earlier tests left in
        // `Preferences`, not on this test.
        try skipIfPointerOnNotch(controller)

        controller.model.isAlwaysOn = true
        controller.model.isExpanded = true

        // Simulate entering full-screen
        controller.isFullScreenActive = { true }
        controller.handleActiveSpaceOrAppChange()
        XCTAssertFalse(controller.model.isExpanded)

        // Simulate returning to desktop
        controller.isFullScreenActive = { false }
        controller.handleActiveSpaceOrAppChange()
        XCTAssertTrue(controller.model.isExpanded, "Always-on notch should unfold again when leaving full screen")
    }
}
