import XCTest
@testable import Codenotch

@MainActor
private final class TestSyntheticScreen: NSScreen {
    private let number: Int
    private let customFrame: CGRect

    init(number: Int, frame: CGRect? = nil) {
        self.number = number
        self.customFrame = frame ?? CGRect(x: CGFloat(number) * 1600, y: 0, width: 1440, height: 900)
        super.init()
    }

    override var frame: CGRect { customFrame }
    override var visibleFrame: CGRect { customFrame }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): NSNumber(value: number)]
    }
}

@MainActor
final class MultiDisplayPositionAndRecoveryTests: XCTestCase {
    private func makeScreen(_ number: Int, frame: CGRect? = nil) -> TestSyntheticScreen {
        TestSyntheticScreen(number: number, frame: frame)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "MultiDisplayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - Preferences per-screen tests

    func testPerScreenOffsetAndEdgePersistence() {
        let defaults = makeDefaults()
        let prefs = Preferences(defaults: defaults)

        XCTAssertEqual(prefs.notchEdge, .right)
        XCTAssertEqual(prefs.offset(for: .top), 0)

        // Set per-screen values for screen A
        prefs.setEdge(.top, for: "screen-A")
        prefs.setOffset(45.0, for: .top, on: "screen-A")

        // Set per-screen values for screen B
        prefs.setEdge(.left, for: "screen-B")
        prefs.setOffset(-30.0, for: .left, on: "screen-B")

        // Verify screen A
        XCTAssertEqual(prefs.edge(for: "screen-A"), .top)
        XCTAssertEqual(prefs.offset(for: .top, on: "screen-A"), 45.0)

        // Verify screen B
        XCTAssertEqual(prefs.edge(for: "screen-B"), .left)
        XCTAssertEqual(prefs.offset(for: .left, on: "screen-B"), -30.0)

        // Verify unspecified screen falls back to defaults
        XCTAssertEqual(prefs.edge(for: "screen-unseen"), prefs.notchEdge)
        XCTAssertEqual(prefs.offset(for: .bottom, on: "screen-unseen"), 0)
    }

    // MARK: - NotchFleet unplug recovery and key re-mapping

    func testMainDisplayUnplugRecoveryAndKeyUpdate() {
        let fleet = NotchFleet(scope: .mainDisplay, edge: .right)
        defer { fleet.stop() }

        let externalScreen = makeScreen(101)
        let builtInScreen = makeScreen(102)

        // Initial setup with both screens connected
        fleet.reconcileForTesting(screens: [externalScreen, builtInScreen])
        XCTAssertEqual(fleet.controllersForTesting.count, 1)

        let initialKey = NotchFleet.key(for: externalScreen)
        XCTAssertNotNil(fleet.controllersByDisplayKeyForTesting[initialKey])

        // External screen unplugs; only built-in remains
        fleet.reconcileForTesting(screens: [builtInScreen])
        XCTAssertEqual(fleet.controllersForTesting.count, 1)

        let builtInKey = NotchFleet.key(for: builtInScreen)
        // Verify controller was gracefully re-keyed to the remaining screen
        XCTAssertNotNil(fleet.controllersByDisplayKeyForTesting[builtInKey])
        XCTAssertNil(fleet.controllersByDisplayKeyForTesting[initialKey])
        XCTAssertTrue(fleet.controllersForTesting.first?.assignedScreen === builtInScreen)

        // External screen reconnects
        fleet.reconcileForTesting(screens: [externalScreen, builtInScreen])
        XCTAssertEqual(fleet.controllersForTesting.count, 1)
        XCTAssertNotNil(fleet.controllersByDisplayKeyForTesting[initialKey])
        XCTAssertNil(fleet.controllersByDisplayKeyForTesting[builtInKey])
    }

    // MARK: - Per-screen edge and offset adopted on reconcile

    func testPerScreenEdgeAndOffsetAdoptedAcrossScreens() {
        let fleet = NotchFleet(scope: .allDisplays, edge: .right)
        defer { fleet.stop() }

        let screen1 = makeScreen(201)
        let screen2 = makeScreen(202)

        let key1 = screen1.persistentScreenKey
        let key2 = screen2.persistentScreenKey

        fleet.edgeForScreen = { screen in
            screen.persistentScreenKey == key1 ? .top : .left
        }
        fleet.offsetForScreen = { screen, edge in
            screen.persistentScreenKey == key1 ? 75.0 : -25.0
        }

        fleet.reconcileForTesting(screens: [screen1, screen2])

        let c1 = try! XCTUnwrap(fleet.controllersByDisplayKeyForTesting[NotchFleet.key(for: screen1)])
        let c2 = try! XCTUnwrap(fleet.controllersByDisplayKeyForTesting[NotchFleet.key(for: screen2)])

        XCTAssertEqual(c1.model.edge, .top)
        XCTAssertEqual(c1.model.alongOffset, 75.0)

        XCTAssertEqual(c2.model.edge, .left)
        XCTAssertEqual(c2.model.alongOffset, -25.0)
    }

    // MARK: - Empty screens graceful handling

    func testEmptyScreensArrayDoesNotCrashAndRecovers() {
        let fleet = NotchFleet(scope: .mainDisplay, edge: .right)
        defer { fleet.stop() }

        let screen1 = makeScreen(301)
        fleet.reconcileForTesting(screens: [screen1])
        XCTAssertEqual(fleet.controllersForTesting.count, 1)

        // All screens temporarily gone (e.g. clamshell mode transitions)
        fleet.reconcileForTesting(screens: [])
        XCTAssertEqual(fleet.controllersForTesting.count, 0)

        // Screen comes back
        fleet.reconcileForTesting(screens: [screen1])
        XCTAssertEqual(fleet.controllersForTesting.count, 1)
        XCTAssertNotNil(fleet.controllersByDisplayKeyForTesting[NotchFleet.key(for: screen1)])
    }

    // MARK: - Screen re-instantiation matching

    func testCurrentScreenMatchesByScreenNumberWhenAppKitReallocates() {
        let controller = NotchWindowController()
        let original = makeScreen(401)
        controller.assignedScreen = original

        let reallocated = makeScreen(401)
        XCTAssertFalse(original === reallocated)

        let resolved = controller.currentScreen(in: [reallocated])
        XCTAssertTrue(resolved === reallocated)
        XCTAssertTrue(controller.assignedScreen === reallocated)
    }
}
