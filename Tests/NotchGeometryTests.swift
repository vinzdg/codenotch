import XCTest
import SwiftUI
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

/// `alongOffset` is how a ⌥-drag on the pill (`NotchWindowController.dragged`)
/// nudges it off the centred default. These pin down the sign convention —
/// get it wrong and the pill runs away from the cursor instead of following
/// it — and the clamp that keeps a drag from pushing it off the screen.
final class PanelOffsetTests: XCTestCase {
    private let screen = FakeScreen(
        frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        visibleFrameValue: CGRect(x: 0, y: 0, width: 1800, height: 1132)
    )

    @MainActor
    func testDraggingToTheTrailingEndKeepsTheSettingsHandleOnScreen() {
        let secondary = FakeScreen(
            frameValue: CGRect(x: -1800, y: -200, width: 1800, height: 1169),
            visibleFrameValue: CGRect(x: -1800, y: -200, width: 1800, height: 1132)
        )
        for display in [screen, secondary] {
            for edge in NotchEdge.allCases {
                for size in NotchSize.allCases {
                    let model = NotchViewModel()
                    model.edge = edge
                    model.sizeScale = size.scale
                    let frame = NotchGeometry.panelFrame(
                        for: display, panelSize: model.panelSize, edge: edge,
                        alongOffset: 10_000, slack: model.slack,
                        trailingExtent: model.trailingExtent
                    )
                    // The settings button, or the grip out beside it.
                    let handleEnd = model.slack
                        + max(model.orbAlong + NotchLayout.orbHotZone / 2,
                              model.gripAlong + NotchLayout.gripHotZone / 2) * model.sizeScale
                    if edge.isVertical {
                        XCTAssertGreaterThanOrEqual(frame.maxY - handleEnd,
                                                    display.frameValue.minY - 0.5)
                    } else {
                        XCTAssertLessThanOrEqual(frame.minX + handleEnd,
                                                 display.frameValue.maxX + 0.5)
                    }
                }
            }
        }
    }

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

/// Use an offset monitor and reserve desktop space on every side so accidental
/// dependencies on the primary display or visibleFrame are caught together.
final class ScreenAnchorRegressionTests: XCTestCase {
    func testEveryEdgeIgnoresDesktopReservationsAtEveryDragPosition() {
        let full = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        let shown = FakeScreen(frameValue: full,
                               visibleFrameValue: full.insetBy(dx: 90, dy: 70))
        let hidden = FakeScreen(frameValue: full, visibleFrameValue: full)
        for edge in NotchEdge.allCases {
            let size = NotchPlacement.panelSize(edge: edge, length: 800, depth: 300)
            for offset: CGFloat in [-10000, -230, 0, 310, 10000] {
                let frame = NotchGeometry.panelFrame(for: shown, panelSize: size,
                                                     edge: edge, alongOffset: offset, slack: 200)
                XCTAssertEqual(frame, NotchGeometry.panelFrame(for: hidden, panelSize: size,
                                                                edge: edge, alongOffset: offset, slack: 200))
                switch edge {
                case .left: XCTAssertEqual(frame.minX, full.minX)
                case .right: XCTAssertEqual(frame.maxX, full.maxX)
                case .top: XCTAssertEqual(frame.maxY, full.maxY)
                case .bottom: XCTAssertEqual(frame.minY, full.minY)
                }
            }
        }
    }

    @MainActor func testCornerTooltipsStayInsideTheVisiblePartOfThePanel() {
        for size in NotchSize.allCases {
            for edge in NotchEdge.allCases {
                let model = NotchViewModel()
                model.edge = edge
                model.sizeScale = size.scale
                // Open: a tooltip only ever exists on an open notch, and that
                // is the geometry its anchor is measured in.
                model.isExpanded = true
                let length: CGFloat = edge.isVertical ? 300 : NotchLayout.cardWidth
                let ring = model.ringAlong(index: 0, in: model.cellWing)
                XCTAssertEqual(model.tooltipAlong(index: 0, length: length), ring)
                // Both ends of the screen: the ring remains on screen, while a
                // card centred on it would lose its heading or its right edge.
                for range in [(ring - 45)...(ring + 900), (ring - 900)...(ring + 45)] {
                    model.visibleAlongRange = range
                    let centre = model.tooltipAlong(index: 0, length: length)
                    XCTAssertGreaterThanOrEqual(centre - length / 2, range.lowerBound - 0.0001)
                    XCTAssertLessThanOrEqual(centre + length / 2, range.upperBound + 0.0001)
                    XCTAssertNotEqual(centre, ring)
                    XCTAssertLessThanOrEqual(abs(ring - centre), length / 2 - NotchLayout.tailHeight / 2)
                }
                model.visibleAlongRange = (ring - 900)...(ring + 900)
                XCTAssertEqual(model.tooltipAlong(index: 0, length: length), ring)
            }
        }
    }
}

/// The size choice reaches the screen in the notch's own measurements, never
/// in the tooltip's. These pin the seam between the two.
final class ScaledMeasurementTests: XCTestCase {
    /// A scaled panel is still a panel: it has to land flush on the bezel like
    /// any other, or a large notch floats a hairline off the edge.
    func testAScaledPanelStillLandsFlushOnTheEdge() {
        let screen = FakeScreen(frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1000),
                                visibleFrameValue: CGRect(x: 0, y: 0, width: 1800, height: 1000))
        let frame = NotchGeometry.panelFrame(
            for: screen,
            panelSize: CGSize(width: 200, height: 750),
            edge: .right
        )

        XCTAssertEqual(frame.maxX, 1800, accuracy: 0.001)
    }

    /// The notch's own end margin scales; the room reserved for the card does
    /// not. Scaling both would reserve space for a card that is never that big,
    /// and at the small end would reserve less than the card needs.
    func testSlackScalesTheNotchsMarginAndNotTheCards() {
        let cardBound = NotchLayout.slack(for: .right, maxCardHeight: 2000)
        XCTAssertEqual(NotchLayout.slack(for: .right, maxCardHeight: 2000, notchScale: 0.8),
                       cardBound,
                       "the card's half-extent was scaled with the notch")

        let marginBound = NotchLayout.slack(for: .right, maxCardHeight: 0)
        XCTAssertEqual(NotchLayout.slack(for: .right, maxCardHeight: 0, notchScale: 2),
                       marginBound * 2, accuracy: 0.001)
    }
}








/// The cutout's depth, from whichever signal AppKit is willing to give.
final class HardwareNotchDepthTests: XCTestCase {
    /// The bug: the bar came out shallower than the hole it is drawn as.
    ///
    /// `safeAreaInsets.top` is the area the system asks apps to keep clear, so
    /// it collapses when the menu bar is hidden or auto-hides. The hole does
    /// not. The strips either side of the notch are its own height and keep
    /// reporting it, so they carry the answer when the inset gives up.
    func testAHiddenMenuBarDoesNotShrinkTheNotch() {
        XCTAssertEqual(HardwareNotch.height(safeAreaTop: 0, beside: [38, 38]), 38,
                       "a hidden menu bar made the notch shallower than the hole")
        XCTAssertEqual(HardwareNotch.height(safeAreaTop: 24, beside: [38, 38]), 38,
                       "the menu bar's own height was taken for the notch's")
    }

    /// And when the inset is the fuller answer, it wins.
    func testTheDeepestSignalIsTheOne() {
        XCTAssertEqual(HardwareNotch.height(safeAreaTop: 38, beside: [32, 32]), 38)
        XCTAssertEqual(HardwareNotch.height(safeAreaTop: 38, beside: []), 38)
        XCTAssertEqual(HardwareNotch.height(safeAreaTop: 0, beside: []), 0,
                       "a screen with nothing to report must still say nothing")
    }
}




/// Folded, a notch that is not beside the hardware is the small pill it has
/// always been — and the flare on it is a quarter circle, not an ellipse.
@MainActor
final class FoldedPillKeepsItsShapeTests: XCTestCase {
    private func folded(_ edge: NotchEdge) -> NotchViewModel {
        let m = NotchViewModel()
        m.edge = edge
        m.isExpanded = false
        m.snapshots = (0..<3).map {
            ProviderSnapshot(id: "p\($0)", displayName: "p", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        return m
    }

    /// The bug: separating the flare's length from its depth dropped the clamp
    /// that kept the length inside the shape. On a pill 8pt deep the flare is
    /// bounded to about 4pt across — and was stretching 33pt along it.
    func testTheFlareCannotOutrunThePillItIsDrawnOn() {
        for edge in [NotchEdge.right, .left, .bottom] {
            let m = folded(edge)
            let size = m.notchSize
            let place = NotchPlacement(edge: edge, panelSize: size)
            let path = m.notchShape.path(in: CGRect(origin: .zero, size: size))

            // The pill's own extent along its edge, measured off the path at
            // the row furthest from the bezel.
            let hits = stride(from: CGFloat(0), to: NotchLayout.pillHeight, by: 0.5)
                .filter { path.contains(place.point(along: $0, across: NotchLayout.pillWidth - 1)) }
            guard let first = hits.first, let last = hits.last else {
                return XCTFail("\(edge): nothing drawn at the pill's foot")
            }
            let lost = NotchLayout.pillHeight - (last - first)
            XCTAssertLessThan(lost, NotchLayout.pillWidth * 2 + 2,
                              "\(edge): the flare takes \(lost)pt off a "
                              + "\(NotchLayout.pillHeight)pt pill — it cannot cut deeper "
                              + "than the pill is thick")
        }
    }

    /// And it is still the pill: full length at the bezel.
    func testItIsStillThePill() {
        for edge in [NotchEdge.right, .left, .bottom] {
            let m = folded(edge)
            XCTAssertEqual(m.notchLength, NotchLayout.pillHeight, accuracy: 0.001, "\(edge)")
            XCTAssertEqual(m.notchDepth, NotchLayout.pillWidth, accuracy: 0.001, "\(edge)")
        }
    }
}


/// The top edge merges into the display's own cutout.
///
/// This is all that is left of the hardware's influence, and it is a placement
/// and a join rather than a layout: the notch is one shape on every edge, and
/// what the hole decides is where the top panel begins — because the band the
/// hole occupies is not a dim or clipped part of the screen, it is absent — and
/// how the leading end of that one shape flows out of it.
final class AboveTheCutoutTests: XCTestCase {
    private struct Notched: ScreenDescribing {
        var frameValue = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        var visibleFrameValue = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        var hardwareNotch: HardwareNotch? { HardwareNotch(width: 220, height: 38) }
        var displayIdentifier: String? { nil }
    }
    private struct Plain: ScreenDescribing {
        var frameValue = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        var visibleFrameValue = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        var displayIdentifier: String? { nil }
    }

    private let size = CGSize(width: 400, height: 120)

    /// **The panel is centred on the cutout**, because what it holds is a pair
    /// of bars either side of it.
    ///
    /// Where each of the two *lands* is `NotchViewModel.wings` and is measured
    /// in `MergesWithTheCutoutTests`; all this has to do is give them a window
    /// that spans the hole and both of them, on the bezel.
    func testThePanelIsCentredOnTheCutout() {
        let screen = Notched()
        let frame = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: .top)
        XCTAssertEqual(frame.maxY, screen.frameValue.maxY, accuracy: 0.5,
                       "it left the bezel — the notch belongs on the screen's edge")
        XCTAssertEqual(frame.midX, screen.frameValue.midX, accuracy: 0.5,
                       "the pair is symmetric about the hole, so the panel is too")
    }

    /// A display without one loses nothing: centred, on the bezel, as before.
    func testAPlainDisplayIsCentredOnTheBezel() {
        let screen = Plain()
        let frame = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: .top)
        XCTAssertEqual(frame.maxY, screen.frameValue.maxY, accuracy: 0.5)
        XCTAssertEqual(frame.midX, screen.frameValue.midX, accuracy: 0.5,
                       "a display with no cutout should not be shifted off centre")
    }

    /// And the other three edges never cared.
    func testTheOtherEdgesAreUntouchedByIt() {
        for edge in [NotchEdge.right, .left, .bottom] {
            let notched = NotchGeometry.panelFrame(for: Notched(), panelSize: size, edge: edge)
            let plain = NotchGeometry.panelFrame(for: Plain(), panelSize: size, edge: edge)
            XCTAssertEqual(notched, plain, "\(edge) moved for a cutout it never touches")
        }
    }

    /// **The model takes two numbers from the hole and nothing else** — that is
    /// what stops the top edge from growing a second layout again.
    ///
    /// It is one shape drawn to a depth the hardware chose, not a second design.
    /// Everything that describes the shape itself — the corner it turns, the
    /// flare at its trailing end, the padding before its first cell — is the
    /// figure every other edge uses. Every earlier attempt at this failed here:
    /// the top edge grew its own corner, its own flare and its own ring maths,
    /// and then had to be kept in step with a shape it did not share.
    @MainActor
    func testTheModelTakesOnlyTheHolesDepthAndDistance() {
        let m = NotchViewModel()
        m.edge = .top
        m.adopt(screen: Notched())
        let plain = NotchViewModel()
        plain.edge = .top
        plain.adopt(screen: Plain())

        XCTAssertNil(plain.cutout, "a display with no hole has nothing to merge with")
        XCTAssertEqual(m.drawnCornerRadius, plain.drawnCornerRadius, accuracy: 0.001,
                       "the top edge grew its own corner again")
        XCTAssertEqual(m.flare, plain.flare, accuracy: 0.001,
                       "the top edge grew its own flare again")
        XCTAssertEqual(m.cellsLeadIn - m.cutoutBleed, plain.cellsLeadIn, accuracy: 0.001,
                       "the top edge grew its own padding again")
        XCTAssertNil(plain.mergedScale,
                     "a display with no hole must be drawn at the size that was asked for")
        XCTAssertNotNil(m.mergedScale, "the hardware sets the size where there is a hole")
    }
}
