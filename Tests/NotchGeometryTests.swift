import XCTest
@testable import Codenotch

private struct FakeScreen: ScreenDescribing {
    var frameValue: CGRect
    var visibleFrameValue: CGRect
    var displayIdentifier: String? = nil
}

final class NotchGeometryTests: XCTestCase {
    private let screen = FakeScreen(
        frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        visibleFrameValue: CGRect(x: 0, y: 0, width: 1800, height: 1132)
    )

    func testPanelHugsTheRightEdgeAndIsVerticallyCentred() {
        let size = CGSize(width: 334, height: 484)
        let frame = NotchGeometry.panelFrame(for: screen, panelSize: size)
        XCTAssertEqual(frame.maxX, 1800, accuracy: 0.001)
        // Centring is allowed to be half a point out: the frame is rounded to
        // whole points so the right-hand edge can be exact, and being flush
        // against the bezel matters where half a point of vertical drift does not.
        XCTAssertEqual(frame.midY, screen.frameValue.midY, accuracy: 0.5)
        XCTAssertEqual(frame.size, size)
    }

    func testPanelFollowsAScreenWithANonZeroOrigin() {
        let secondary = FakeScreen(
            frameValue: CGRect(x: -2560, y: 200, width: 2560, height: 1440),
            visibleFrameValue: CGRect(x: -2560, y: 200, width: 2560, height: 1415)
        )
        let frame = NotchGeometry.panelFrame(for: secondary, panelSize: CGSize(width: 334, height: 484))
        XCTAssertEqual(frame.maxX, 0, accuracy: 0.001)
        XCTAssertEqual(frame.midY, 920, accuracy: 0.5)
    }

    func testAChosenDisplayWinsOverTheActiveOne() {
        let active = FakeScreen(frameValue: .zero, visibleFrameValue: .zero,
                                displayIdentifier: "active")
        let chosen = FakeScreen(frameValue: CGRect(x: 100, y: 0, width: 100, height: 100),
                                visibleFrameValue: .zero, displayIdentifier: "chosen")

        let result = NotchGeometry.preferredScreen(
            from: [active, chosen], preference: .display("chosen"), activeScreen: active
        )

        XCTAssertEqual(result?.displayIdentifier, "chosen")
    }

    func testADisconnectedChoiceTemporarilyFallsBackToTheActiveDisplay() {
        let active = FakeScreen(frameValue: .zero, visibleFrameValue: .zero,
                                displayIdentifier: "active")

        let result = NotchGeometry.preferredScreen(
            from: [active], preference: .display("missing"), activeScreen: active
        )

        XCTAssertEqual(result?.displayIdentifier, "active")
    }

    func testFollowActiveWindowUsesTheActiveDisplay() {
        let first = FakeScreen(frameValue: .zero, visibleFrameValue: .zero,
                               displayIdentifier: "first")
        let active = FakeScreen(frameValue: .zero, visibleFrameValue: .zero,
                                displayIdentifier: "active")

        let result = NotchGeometry.preferredScreen(
            from: [first, active], preference: .followActiveWindow, activeScreen: active
        )

        XCTAssertEqual(result?.displayIdentifier, "active")
    }
}

/// A hairline of wallpaper down the right-hand side is all it takes for the
/// notch to read as floating instead of welded to the bezel, and a fractional
/// panel frame is how that happens.
final class PanelEdgeTests: XCTestCase {
    private let screen = FakeScreen(
        frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        visibleFrameValue: CGRect(x: 0, y: 0, width: 1800, height: 1132)
    )

    /// The real panel size is fractional — it is derived from the design
    /// frame's pixel ratios — which is exactly the case that used to leave a gap.
    func testAFractionalSizeStillLandsFlushOnTheEdge() {
        let fractional = CGSize(width: 334.3247863247863, height: 205.182905982906)
        let frame = NotchGeometry.panelFrame(for: screen, panelSize: fractional)
        XCTAssertEqual(frame.maxX, 1800, accuracy: 0.0001)
    }

    func testTheFrameIsIntegral() {
        let frame = NotchGeometry.panelFrame(
            for: screen,
            panelSize: CGSize(width: 334.3247863247863, height: 205.182905982906)
        )
        for value in [frame.minX, frame.minY, frame.width, frame.height] {
            XCTAssertEqual(value, value.rounded(), "\(value) is not a whole point")
        }
    }

    /// Rounding must never make the panel narrower than its content.
    func testItNeverRoundsBelowTheRequestedSize() {
        let requested = CGSize(width: 334.325, height: 205.183)
        let frame = NotchGeometry.panelFrame(for: screen, panelSize: requested)
        XCTAssertGreaterThanOrEqual(frame.width, requested.width)
        XCTAssertGreaterThanOrEqual(frame.height, requested.height)
    }

    func testItStaysFlushOnAScreenWithANonZeroOrigin() {
        let secondary = FakeScreen(
            frameValue: CGRect(x: -2560, y: 200, width: 2560, height: 1440),
            visibleFrameValue: CGRect(x: -2560, y: 200, width: 2560, height: 1415)
        )
        let frame = NotchGeometry.panelFrame(
            for: secondary,
            panelSize: CGSize(width: 334.3247863247863, height: 205.182905982906)
        )
        XCTAssertEqual(frame.maxX, 0, accuracy: 0.0001)
    }
}
