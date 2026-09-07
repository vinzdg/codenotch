import XCTest
@testable import Codenotch

private struct FakeScreen: ScreenDescribing {
    var frameValue: CGRect
    var visibleFrameValue: CGRect
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
}

/// `alongOffset` is how a ⌥-drag on the pill (`NotchWindowController.dragged`)
/// nudges it off the centred default. These pin down the sign convention —
/// get it wrong and the pill runs away from the cursor instead of following
/// it — and the clamp that keeps a drag from pushing it off the screen.
final class PanelOffsetTests: XCTestCase {
    private let screen = FakeScreen(
        frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        visibleFrameValue: CGRect(x: 0, y: 0, width: 1800, height: 1132)
    )

    func testZeroOffsetChangesNothing() {
        let size = CGSize(width: 334, height: 484)
        let centred = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: .right)
        let explicit = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: .right, alongOffset: 0)
        XCTAssertEqual(centred, explicit)
    }

    /// A positive offset on a side edge moves the pill *down* — the direction
    /// `NotchWindowController.dragged` feeds it in when the pointer moves
    /// down, since `NSEvent`'s raw delta and AppKit's y-grows-up frame origin
    /// disagree about which way is positive.
    func testPositiveOffsetMovesASideEdgePanelDown() {
        let size = CGSize(width: 334, height: 484)
        let centred = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: .right)
        let nudged = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: .right, alongOffset: 100)
        XCTAssertEqual(nudged.midY, centred.midY - 100, accuracy: 0.5)
        // Still flush against the right-hand bezel — only the along axis moved.
        XCTAssertEqual(nudged.maxX, centred.maxX, accuracy: 0.001)
    }

    /// A positive offset on a top/bottom edge moves the pill *right* — no sign
    /// flip needed there, since `NSEvent.deltaX` and AppKit's x already agree.
    func testPositiveOffsetMovesATopEdgePanelRight() {
        let size = CGSize(width: 484, height: 120)
        let centred = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: .top)
        let nudged = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: .top, alongOffset: 100)
        XCTAssertEqual(nudged.midX, centred.midX + 100, accuracy: 0.5)
        XCTAssertEqual(nudged.maxY, centred.maxY, accuracy: 0.001)
    }

    /// `slack` is the padding `panelSize` carries beyond the visible pill,
    /// reserved for a hover card that may not be open. Clamping by the full
    /// panel — as if that padding had to stay on screen too — left almost no
    /// room to drag on a panel sized for the worst-case card. Clamping by the
    /// pill's own extent instead should let it travel nearly the whole edge.
    func testAnExtremeOffsetKeepsTheVisiblePillOnScreenRatherThanThePadding() {
        let slack = 400.0
        let size = CGSize(width: 334, height: 900)   // mostly hover-card padding
        let frame = NotchGeometry.panelFrame(
            for: screen, panelSize: size, edge: .right, alongOffset: 10_000, slack: slack
        )
        let pillTop = frame.maxY - slack
        let pillBottom = frame.minY + slack
        XCTAssertLessThanOrEqual(pillTop, screen.frameValue.maxY + 0.5)
        XCTAssertGreaterThanOrEqual(pillBottom, screen.frameValue.minY - 0.5)
    }

    /// Without `slack`'s allowance, the same drag would have clamped to
    /// keeping the *entire* padded panel on screen — which the real bug
    /// report was about: a handful of points of travel on a panel sized for
    /// four providers' worth of hover card.
    func testSlackWidensTheDraggableRangeBeyondClampingTheWholePanel() {
        let size = CGSize(width: 334, height: 900)
        let withoutSlack = NotchGeometry.panelFrame(
            for: screen, panelSize: size, edge: .right, alongOffset: 10_000, slack: 0
        )
        let withSlack = NotchGeometry.panelFrame(
            for: screen, panelSize: size, edge: .right, alongOffset: 10_000, slack: 400
        )
        XCTAssertLessThan(withSlack.minY, withoutSlack.minY)
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
