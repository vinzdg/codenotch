import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Codenotch

@MainActor
final class AutoHideTests: XCTestCase {
    // MARK: - Detector overlap pure tests

    func testDetectorFindsWindowOverlappingNotchBounds() {
        let notchBounds = CGRect(x: 700, y: 0, width: 328, height: 44)
        let pid: pid_t = 12345
        let windows: [(pid: pid_t, layer: Int, bounds: CGRect)] = [
            (pid: 9999, layer: 0, bounds: CGRect(x: 50, y: 50, width: 800, height: 600)),
            (pid: pid, layer: 0, bounds: CGRect(x: 600, y: 10, width: 800, height: 600))
        ]

        XCTAssertTrue(
            FullScreenDetector.isWindowOverlapping(notchBounds: notchBounds, frontmostPID: pid, windows: windows),
            "An active window intersecting the notch bounds must be detected as overlapping"
        )
    }

    func testDetectorRejectsNonOverlappingWindow() {
        let notchBounds = CGRect(x: 700, y: 0, width: 328, height: 44)
        let pid: pid_t = 12345
        let windows: [(pid: pid_t, layer: Int, bounds: CGRect)] = [
            (pid: pid, layer: 0, bounds: CGRect(x: 100, y: 200, width: 800, height: 600))
        ]

        XCTAssertFalse(
            FullScreenDetector.isWindowOverlapping(notchBounds: notchBounds, frontmostPID: pid, windows: windows),
            "A window positioned away from the notch bounds must not be reported as overlapping"
        )
    }

    func testDetectorRejectsOverlappingWindowOfNonFrontmostApp() {
        let notchBounds = CGRect(x: 700, y: 0, width: 328, height: 44)
        let frontPID: pid_t = 12345
        let otherPID: pid_t = 67890
        let windows: [(pid: pid_t, layer: Int, bounds: CGRect)] = [
            (pid: otherPID, layer: 0, bounds: CGRect(x: 700, y: 0, width: 400, height: 400))
        ]

        XCTAssertFalse(
            FullScreenDetector.isWindowOverlapping(notchBounds: notchBounds, frontmostPID: frontPID, windows: windows),
            "Overlapping windows belonging to background apps must be ignored"
        )
    }

    func testDetectorIgnoresTinyWindows() {
        let notchBounds = CGRect(x: 700, y: 0, width: 328, height: 44)
        let pid: pid_t = 12345
        let windows: [(pid: pid_t, layer: Int, bounds: CGRect)] = [
            (pid: pid, layer: 0, bounds: CGRect(x: 750, y: 10, width: 10, height: 10))
        ]

        XCTAssertFalse(
            FullScreenDetector.isWindowOverlapping(notchBounds: notchBounds, frontmostPID: pid, windows: windows),
            "Small/utility windows smaller than 20pt must be ignored"
        )
    }

    func testDetectorIgnoresNonLayerZeroWindows() {
        let notchBounds = CGRect(x: 700, y: 0, width: 328, height: 44)
        let pid: pid_t = 12345
        let windows: [(pid: pid_t, layer: Int, bounds: CGRect)] = [
            (pid: pid, layer: 24, bounds: CGRect(x: 600, y: 0, width: 800, height: 600)) // overlay / menu bar
        ]

        XCTAssertFalse(
            FullScreenDetector.isWindowOverlapping(notchBounds: notchBounds, frontmostPID: pid, windows: windows),
            "Non-layer-0 windows must not count as overlapping application windows"
        )
    }

    func testDetectorIgnoresTouchingEdgesWithoutAreaOverlap() {
        let notchBounds = CGRect(x: 700, y: 0, width: 328, height: 44)
        let pid: pid_t = 12345
        // Touching bottom edge exactly at y=44 with 0 overlap depth
        let windows: [(pid: pid_t, layer: Int, bounds: CGRect)] = [
            (pid: pid, layer: 0, bounds: CGRect(x: 700, y: 44, width: 328, height: 500))
        ]

        XCTAssertFalse(
            FullScreenDetector.isWindowOverlapping(notchBounds: notchBounds, frontmostPID: pid, windows: windows),
            "Abutting edges with <= 1pt intersection must not be counted as overlap"
        )
    }

    // MARK: - Controller autoHideMode tests

    func testControllerAutoFoldsOnWindowOverlapWhenModeIsOnOverlap() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        controller.model.isAlwaysOn = true
        controller.model.isExpanded = true
        controller.autoHideMode = .onOverlap
        controller.isFullScreenActive = { false }
        controller.isWindowOverlapActive = { true }

        controller.handleActiveSpaceOrAppChange()

        XCTAssertFalse(controller.model.isExpanded, "The notch must fold when an active window overlaps in onOverlap mode")
    }

    func testControllerDoesNotFoldOnWindowOverlapWhenModeIsOnFullscreen() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        controller.model.isAlwaysOn = true
        controller.model.isExpanded = true
        controller.autoHideMode = .onFullscreen
        controller.isFullScreenActive = { false }
        controller.isWindowOverlapActive = { true }

        controller.handleActiveSpaceOrAppChange()

        XCTAssertTrue(controller.model.isExpanded, "Window overlap must not fold the notch in onFullscreen mode")
    }

    func testControllerDoesNotFoldOnWindowOverlapWhenModeIsNever() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        controller.model.isAlwaysOn = true
        controller.model.isExpanded = true
        controller.autoHideMode = .never
        controller.isFullScreenActive = { true }
        controller.isWindowOverlapActive = { true }

        controller.handleActiveSpaceOrAppChange()

        XCTAssertTrue(controller.model.isExpanded, "Neither full-screen nor window overlap folds the notch in never mode")
    }

    func testControllerRestoresAlwaysOnWhenOverlapEnds() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        controller.model.isAlwaysOn = true
        controller.model.isExpanded = true
        controller.autoHideMode = .onOverlap
        controller.isFullScreenActive = { false }
        controller.isWindowOverlapActive = { true }

        controller.handleActiveSpaceOrAppChange()
        XCTAssertFalse(controller.model.isExpanded)

        // Overlap ends
        controller.isWindowOverlapActive = { false }
        controller.handleActiveSpaceOrAppChange()
        XCTAssertTrue(controller.model.isExpanded, "An always-on notch must unfold again when overlap ends")
    }

    func testApplyAutoHideModeReEvaluatesImmediately() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        controller.model.isAlwaysOn = true
        controller.model.isExpanded = true
        controller.autoHideMode = .onFullscreen
        controller.isFullScreenActive = { false }
        controller.isWindowOverlapActive = { true }

        controller.handleActiveSpaceOrAppChange()
        XCTAssertTrue(controller.model.isExpanded)

        controller.apply(autoHideMode: .onOverlap)
        XCTAssertFalse(controller.model.isExpanded, "Switching to onOverlap mode must fold immediately if an overlap exists")

        controller.apply(autoHideMode: .never)
        XCTAssertTrue(controller.model.isExpanded, "Switching to never mode must restore the always-on notch immediately")
    }

    // MARK: - Preferences synchronization tests

    func testPreferencesSyncAutoHideModeAndFoldsForFullScreen() {
        let defaults = UserDefaults(suiteName: "testPreferencesSyncAutoHideMode")!
        defaults.removePersistentDomain(forName: "testPreferencesSyncAutoHideMode")

        let prefs = Preferences(defaults: defaults)
        XCTAssertEqual(prefs.autoHideMode, .onFullscreen)
        XCTAssertTrue(prefs.foldsForFullScreen)

        prefs.autoHideMode = .never
        XCTAssertFalse(prefs.foldsForFullScreen)

        prefs.autoHideMode = .onOverlap
        XCTAssertTrue(prefs.foldsForFullScreen)

        prefs.foldsForFullScreen = false
        XCTAssertEqual(prefs.autoHideMode, .never)

        prefs.foldsForFullScreen = true
        XCTAssertEqual(prefs.autoHideMode, .onFullscreen)
    }
}
