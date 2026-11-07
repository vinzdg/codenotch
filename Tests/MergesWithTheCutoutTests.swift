import XCTest
import SwiftUI
@testable import Codenotch

/// **One silhouette, not two shapes that touch.**
///
/// Placed beside the display's own hole the notch used to be a second black
/// object a few points away from the first, and that is not what the machine
/// looks like: the eye finds the gap and reads a mistake. So the notch now
/// starts *inside* the hole and flows out of it — the leading end loses its
/// flare, holds the hole's own depth as far as the hole's wall, and steps down
/// onto the bar's far side with no bend at either join.
///
/// Every test here measures the drawn path in screen points, because that is
/// the only space in which "does it line up with the hole" is a question. The
/// mapping is the view's own: the shape is drawn in design points, scaled by
/// the size setting from the bezel, pushed `bezelBleed` past it, and laid into
/// the panel at `notchAlongLead`.
@MainActor
final class MergesWithTheCutoutTests: XCTestCase {
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

    private func model(_ screen: ScreenDescribing, scale: CGFloat = 1,
                       open: Bool = true, offset: CGFloat = 0, count: Int = 4) -> NotchViewModel {
        let m = NotchViewModel()
        m.edge = .top
        m.sizeScale = scale
        m.alongOffset = offset
        m.snapshots = (0..<count).map {
            ProviderSnapshot(id: "p\($0)", displayName: "P", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        m.adopt(screen: screen)
        m.isExpanded = open
        return m
    }

    /// A point on the drawn outline: how far right of the screen's left edge,
    /// and how far *below the top of the screen* — which is the axis the hole is
    /// measured on too.
    private struct Sample {
        var x: CGFloat
        var depth: CGFloat
    }

    /// The whole outline, in screen points.
    ///
    /// Flattened rather than read element by element: the bridge is a polyline
    /// and the flares are too, but the corners are cubics, and a control point
    /// is not a point on the curve. Sampling each one means "nothing of this
    /// shape hangs below the hole" can be asked of the shape itself rather than
    /// of the parts of it that happen to be straight.
    private func outline(of m: NotchViewModel, on screen: ScreenDescribing) -> [Sample] {
        let frame = NotchGeometry.panelFrame(
            for: screen, panelSize: m.panelSize, edge: m.edge,
            alongOffset: m.alongOffset, slack: m.slack,
            trailingExtent: m.trailingExtent, leadingExtent: m.leadingExtent
        )
        var samples: [Sample] = []
        // Every drawn copy, as the shape it is drawn as — the one on the left
        // of the hole is reflected in its own path, not flipped by the view.
        for wing in m.wings where wing.length > 0 {
            let size = NotchPlacement.panelSize(edge: .top,
                                                length: wing.length / m.sizeScale,
                                                depth: wing.depth)
            let path = m.notchShape(for: wing).path(in: CGRect(origin: .zero, size: size))
            let lead = frame.minX + wing.lead
            let place = { (p: CGPoint) in
                Sample(x: lead + p.x * m.sizeScale,
                       depth: p.y * m.sizeScale - NotchRootView.bezelBleed)
            }
            samples += walk(path, place)
        }
        return samples
    }

    private func walk(_ path: Path, _ place: (CGPoint) -> Sample) -> [Sample] {
        var samples: [Sample] = []
        var cursor = CGPoint.zero
        var start = CGPoint.zero
        func cubic(_ a: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ b: CGPoint) {
            for i in 1...16 {
                let t = CGFloat(i) / 16, u = 1 - t
                let w = (u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t)
                samples.append(place(CGPoint(
                    x: w.0 * a.x + w.1 * c1.x + w.2 * c2.x + w.3 * b.x,
                    y: w.0 * a.y + w.1 * c1.y + w.2 * c2.y + w.3 * b.y)))
            }
        }
        path.forEach { element in
            switch element {
            case .move(let to):
                start = to
                cursor = to
                samples.append(place(to))
            case .line(let to):
                // Along the line, not only at its ends: the joined end's bottom
                // edge is one straight run from inside the hole out past its
                // wall, and "what is at the wall" has to find a point there.
                let steps = max(1, Int((hypot(to.x - cursor.x, to.y - cursor.y)).rounded(.up)))
                for i in 1...steps {
                    let t = CGFloat(i) / CGFloat(steps)
                    samples.append(place(CGPoint(x: cursor.x + (to.x - cursor.x) * t,
                                                 y: cursor.y + (to.y - cursor.y) * t)))
                }
                cursor = to
            case .quadCurve(let to, let control):
                cubic(cursor,
                      CGPoint(x: cursor.x + 2.0 / 3 * (control.x - cursor.x),
                              y: cursor.y + 2.0 / 3 * (control.y - cursor.y)),
                      CGPoint(x: to.x + 2.0 / 3 * (control.x - to.x),
                              y: to.y + 2.0 / 3 * (control.y - to.y)),
                      to)
                cursor = to
            case .curve(let to, let control1, let control2):
                cubic(cursor, control1, control2, to)
                cursor = to
            case .closeSubpath:
                cursor = start
            }
        }
        return samples
    }

    /// Where the hole's trailing wall stands, and how deep the hole is.
    /// The nudge that puts the notch on the left of the hole, flush against its
    /// left wall — the far end of the run the nudge travels.
    private func flushOnTheLeft(_ screen: ScreenDescribing) throws -> CGFloat {
        _ = try XCTUnwrap(screen.hardwareNotch)
        return -2 * NotchGeometry.cutoutTravel
    }

    private func hole(_ screen: ScreenDescribing) throws
    -> (wall: CGFloat, left: CGFloat, depth: CGFloat) {
        let cutout = try XCTUnwrap(screen.hardwareNotch)
        return (screen.frameValue.midX + cutout.width / 2,
                screen.frameValue.midX - cutout.width / 2,
                cutout.height)
    }

    // MARK: - The join

    /// **Nothing of the notch hangs out below the hole.**
    ///
    /// This is the one that has to hold, open or folded, at every size. The
    /// overlap is drawn at the hole's own depth so that it fills the lit sliver
    /// in the crook of the hole's rounded corner — a point deeper than that, in
    /// the stretch left of the wall, is a black tongue poking out from under the
    /// hardware's notch where there is nothing for it to belong to.
    func testNothingIsDrawnBelowTheHoleInsideIt() throws {
        for scale in [0.5, 1.0, 1.5] as [CGFloat] {
            for open in [true, false] {
                let screen = Notched()
                let m = model(screen, scale: scale, open: open)
                let hole = try hole(screen)
                let inside = outline(of: m, on: screen).filter { $0.x < hole.wall - 0.5 }
                XCTAssertFalse(inside.isEmpty,
                               "scale \(scale) open \(open): nothing overlaps the hole at all, "
                               + "so there is no join — only two shapes side by side")
                let deepest = inside.map(\.depth).max() ?? 0
                XCTAssertLessThanOrEqual(deepest, hole.depth + 0.6,
                                         "scale \(scale) open \(open): the notch reaches "
                                         + "\(deepest)pt below the screen's top inside the "
                                         + "hole, which is only \(hole.depth)pt deep — that "
                                         + "much of it is drawn on the wallpaper")
            }
        }
    }

    /// **And it is flush with the hole where it meets it**, rather than stopping
    /// short of its bottom edge and leaving a step.
    func testItMeetsTheHolesBottomEdgeExactly() throws {
        for open in [true, false] {
            let screen = Notched()
            let m = model(screen, open: open)
            let hole = try hole(screen)
            let atWall = outline(of: m, on: screen)
                .filter { abs($0.x - hole.wall) < 1.5 }
                .map(\.depth)
            XCTAssertFalse(atWall.isEmpty, "open \(open): the outline never reaches the wall")
            XCTAssertEqual(atWall.max() ?? 0, hole.depth, accuracy: 0.8,
                           "open \(open): at the hole's wall the notch is "
                           + "\(atWall.max() ?? 0)pt deep against the hole's \(hole.depth) — "
                           + "a step, and a step is a seam")
        }
    }

    /// **No crease at either end of the bridge.**
    ///
    /// The bridge leaves the hole's bottom edge and lands on the bar's far side,
    /// and both of those are straight. A curve that arrives at an angle puts a
    /// crease there, and a crease is exactly where the eye stops reading one
    /// object and starts reading two — which is the whole complaint the flare
    /// was rebuilt for once already.
    func testTheBridgeLeavesAndLandsFlat() throws {
        let screen = Notched()
        let m = model(screen)
        let hole = try hole(screen)
        let bar = m.notchDepth * m.sizeScale - NotchRootView.bezelBleed

        // The leading end only. Filtered by depth alone this picks up the far
        // corner and the trailing flare as well, which span the same band — and
        // then "where the bridge lands" is measured at the other end of the bar.
        let end = hole.wall + m.flare * m.sizeScale + 2
        let bridge = outline(of: m, on: screen)
            .filter { $0.x >= hole.wall - 0.5 && $0.x <= end }
            .filter { $0.depth >= hole.depth - 1 && $0.depth <= bar + 1 }
            .sorted { $0.x < $1.x }
        guard bridge.count > 8 else {
            return XCTFail("the bridge is too coarse to measure")
        }

        func slope(_ a: Sample, _ b: Sample) -> CGFloat {
            guard b.x - a.x > 0.0001 else { return .greatestFiniteMagnitude }
            return abs(b.depth - a.depth) / (b.x - a.x)
        }
        // Over the first and last twelfth of it, where a curve that arrived at
        // an angle would have already turned.
        let step = max(1, bridge.count / 12)
        XCTAssertLessThan(slope(bridge[0], bridge[step]), 0.12,
                          "the bridge leaves the hole's bottom edge at an angle")
        XCTAssertLessThan(slope(bridge[bridge.count - 1 - step], bridge[bridge.count - 1]), 0.12,
                          "the bridge lands on the bar's far side at an angle")
    }

    /// **The leading end has no flare left.** A flare is how a shape says it
    /// begins here; this end does not begin, it continues.
    func testTheLeadingEndDoesNotTaperBackToTheBezel() {
        let merged = model(Notched())
        let plain = model(Plain())
        let near = CGFloat(4)   // just below the bezel

        func leadingEdge(_ m: NotchViewModel, _ screen: ScreenDescribing) -> CGFloat {
            let path = m.notchShape.path(in: CGRect(origin: .zero, size: m.notchSize))
            let place = NotchPlacement(edge: .top, panelSize: m.notchSize)
            return stride(from: CGFloat(0), to: m.notchSize.width, by: 0.5)
                .first { path.contains(place.point(along: $0, across: near)) } ?? .infinity
        }

        XCTAssertLessThan(leadingEdge(merged, Notched()), 1,
                          "the merged notch still tapers away from its leading tip")
        XCTAssertGreaterThan(leadingEdge(plain, Plain()), NotchLayout.curlRadius / 2,
                             "the plain notch should still flare back to the bezel")
    }

    // MARK: - Staying joined

    /// **Folding does not let go.**
    ///
    /// The notch normally shrinks toward its own centre line so that hiding
    /// does not slide it along the edge. Joined to the hole it has to shrink
    /// toward the *hole* instead: a pill that retreated to the middle of its
    /// panel would leave the bridge stretched across a hundred points of bezel.
    func testItFoldsTowardTheHoleRatherThanItsOwnCentre() throws {
        let m = model(Notched())
        func joinedEnds(_ m: NotchViewModel) -> [CGFloat] {
            // The end of each copy that meets the hole: the far end of the one
            // on the left, the near end of the one on the right.
            return m.wings.map { $0.onTheLeft ? $0.lead + $0.length : $0.lead }
        }
        let open = joinedEnds(m)
        XCTAssertEqual(open.count, 2, "joined, it is drawn either side of the hole")
        m.isExpanded = false
        for (was, now) in zip(open, joinedEnds(m)) {
            XCTAssertEqual(now, was, accuracy: 0.001, "a folded copy let go of the hole")
        }

        // And a notch with no hole to hold on to still contracts in place.
        let plain = model(Plain())
        let openCentre = plain.notchAlongLead + plain.notchLength * plain.sizeScale / 2
        plain.isExpanded = false
        XCTAssertEqual(plain.notchAlongLead + plain.notchLength * plain.sizeScale / 2,
                       openCentre, accuracy: 0.001,
                       "a notch with no hole should still fold to its own centre line")
    }

    /// Identity 0 survives pickup and landing. Joined, both copies carry cells;
    /// the handles and the geometry of the carried bar keep their identity.
    ///
    /// The bar being dragged has to *be* the bar that lands, or the landing is
    /// one view vanishing and another appearing: a swap, not a movement. And
    /// nothing may be turned over by the view, because a view's `scaleEffect`
    /// is a number SwiftUI animates, and every time a copy's side changed under
    /// one identity the bar turned over through nothing on the way. The copy on
    /// the left of the hole is its own shape now, reflected in the path.
    func testTheCarryingCopyIsOneBarFromPickUpToLanding() {
        let plain = model(Plain())
        let joined = model(Notched())
        let onTheLeft = model(Notched(), offset: -2 * NotchGeometry.cutoutTravel)
        for m in [plain, joined, onTheLeft] {
            XCTAssertEqual(m.cellWing.id, 0, "the carrying copy changed identity")
            XCTAssertEqual(m.wings.filter(\.carriesCells).count, m.mergesWithCutout ? 2 : 1,
                           "joined, both wings carry their share; free, one carries everything")
            XCTAssertEqual(Set(m.wings.map(\.id)).count, m.wings.count,
                           "two copies share an identity")
        }
        XCTAssertFalse(joined.cellWing.onTheLeft)
        XCTAssertTrue(onTheLeft.cellWing.onTheLeft,
                      "put down on the left, the readings should stay on the left")
        XCTAssertTrue(joined.handleWing.carriesCells, "the handles are on the empty copy")
    }

    /// **It is drawn on both sides of the hole**, mirrored, so the hardware's
    /// own notch reads as having the app either side of it rather than as
    /// something with a bar stuck to one edge.
    func testItIsDrawnEitherSideOfTheHole() throws {
        let screen = Notched()
        let m = model(screen)
        let hole = try hole(screen)
        XCTAssertEqual(m.wings.count, 2)
        XCTAssertEqual(m.wings.filter(\.onTheLeft).count, 1, "one of the pair is on each side")

        let frame = NotchGeometry.panelFrame(
            for: screen, panelSize: m.panelSize, edge: .top,
            alongOffset: m.alongOffset, slack: m.slack,
            trailingExtent: m.trailingExtent, leadingExtent: m.leadingExtent)
        let left = frame.minX + (m.wings.first?.lead ?? 0)
        let right = frame.minX + (m.wings.last.map { $0.lead + $0.length } ?? 0)
        XCTAssertEqual(hole.wall - right, left - hole.left, accuracy: 1.5,
                       "the two reach the same distance either side of the hole")

        // And a display with no hole gets one bar, as every other edge does.
        XCTAssertEqual(model(Plain()).wings.count, 1)
    }

    /// The buried overlap is length nobody sees, so the bar is drawn longer by
    /// exactly that much — otherwise the merged notch starts short of the wall
    /// and everything in it sits closer to its visible start than it should.
    func testTheBuriedOverlapIsPaidForInLength() {
        let merged = model(Notched())
        XCTAssertEqual(merged.cutoutBleed * merged.sizeScale,
                       NotchGeometry.cutoutOverlap, accuracy: 0.001)
        XCTAssertEqual(merged.cellsLeadIn - merged.cutoutBleed, merged.cellSpacing,
                       accuracy: 0.001, "the joined end needs the same visible clearance as adjacent rings")
    }

    // MARK: - One thickness

    /// **It is exactly as deep as the hole**, at every size setting and in both
    /// states. One shape cannot be two thicknesses: drawn deeper it bulged out
    /// from under the hardware, drawn shallower it tapered up out of it, and the
    /// fold morphed between the two — which is what "looks like a glitch" was.
    func testItIsExactlyAsDeepAsTheHole() throws {
        let screen = Notched()
        let hole = try hole(screen)
        for scale in [0.5, 0.589, 1.0, 1.5] as [CGFloat] {
            for open in [true, false] {
                let m = model(screen, scale: scale, open: open)
                let drawn = m.notchDepth * m.sizeScale - NotchRootView.bezelBleed
                XCTAssertEqual(drawn, hole.depth, accuracy: 0.001,
                               "scale \(scale) open \(open)")
            }
        }
    }

    /// And folding changes the length alone, so the fold is a bar drawing itself
    /// in along one axis rather than a shape changing into another shape.
    func testFoldingChangesOnlyTheLength() {
        let m = model(Notched())
        let open = m.notchDepth
        m.isExpanded = false
        XCTAssertEqual(m.notchDepth, open, accuracy: 0.001,
                       "the merged notch still changes depth as it folds")
        XCTAssertLessThan(m.notchLength, m.shapeLength, "it should still shorten")
    }

    /// **The bridge has no step left to make.** With both bottom edges at one
    /// depth the join is a straight line, which is the whole point of taking the
    /// hardware's depth: there is no waist to see because there is no mismatch.
    func testTheTwoBottomEdgesAreOneStraightLine() throws {
        let screen = Notched()
        let m = model(screen)
        let hole = try hole(screen)
        // From the wall outward — where it leaves the hole. Inside the hole is
        // the joined end's square tip, standing where nothing shows.
        let far = outline(of: m, on: screen)
            .filter { $0.x >= hole.wall - 0.5 && $0.x < hole.wall + m.flare * m.sizeScale }
            .map(\.depth)
            .filter { $0 > hole.depth / 2 }
        XCTAssertFalse(far.isEmpty)
        XCTAssertEqual(far.min() ?? 0, hole.depth, accuracy: 0.6)
        XCTAssertEqual(far.max() ?? 0, hole.depth, accuracy: 0.6,
                       "the bottom edge steps by \((far.max() ?? 0) - hole.depth)pt where it "
                       + "leaves the hole — at one depth there is nothing to step")
    }

    /// **The size setting does not come into it.**
    ///
    /// However big the notch is set to be, merged it is the size of the Mac's
    /// own notch. Anything else is a distortion rather than a size: the depth
    /// cannot follow the setting — one shape, one thickness — so a setting that
    /// moved everything *except* the depth gave rings capped by the cutout but
    /// spaced for a bar three times as deep.
    func testTheSizeSettingDoesNotChangeIt() throws {
        let screen = Notched()
        let reference = model(screen, scale: 1)
        for scale in [0.5, 0.589, 1.0, 1.5] as [CGFloat] {
            let m = model(screen, scale: scale)
            XCTAssertEqual(m.requestedScale, scale, accuracy: 0.001,
                           "the setting itself must survive — it governs every other edge")
            XCTAssertEqual(m.sizeScale, reference.sizeScale, accuracy: 0.001,
                           "scale \(scale): the notch is drawn at the setting, not at the "
                           + "size of the Mac's notch")
            XCTAssertEqual(m.shapeLength * m.sizeScale,
                           reference.shapeLength * reference.sizeScale, accuracy: 0.001,
                           "scale \(scale): it is a different length")
            XCTAssertEqual(m.ringCenter(index: 0) * m.sizeScale,
                           reference.ringCenter(index: 0) * reference.sizeScale, accuracy: 0.001,
                           "scale \(scale): its rings are in a different place")
        }

        // And on a display with no hole the setting is all there is.
        XCTAssertEqual(model(Plain(), scale: 1.5).sizeScale, 1.5, accuracy: 0.001)
    }

    /// **Every proportion in it is the design's**, which is what taking one
    /// scale buys over pinning the depth and letting the rest follow a slider.
    /// The contents fit the depth, and the clear space around the ring is the
    /// frame's own share of it.
    func testItKeepsTheDesignsProportionsAtTheHardwaresSize() throws {
        let screen = Notched()
        let hole = try hole(screen)
        for reading in [true, false] {
            let m = model(screen)
            m.showsNotchReadings = reading
            let scale = try XCTUnwrap(m.mergedScale)
            let cell = (m.showsCellReading ? NotchLayout.cellExtent
                                           : NotchLayout.ringDiameter) * scale
            let clear = NotchLayout.ringMargin(for: .top) * scale

            XCTAssertEqual(cell + 2 * clear, hole.depth + NotchRootView.bezelBleed,
                           accuracy: 0.001,
                           "reading \(reading): the contents and their margins do not add up "
                           + "to the bar they are in")
            XCTAssertGreaterThan(NotchLayout.ringDiameter * scale, 14,
                                 "reading \(reading): the ring is too small to read as a ring")
        }
    }

    /// The grip that moves the notch comes out beside the settings button, on
    /// the side away from the notch, joined to the hole or not.
    func testTheGripSitsBesideTheSettingsButton() {
        for m in [model(Notched()), model(Plain())] {
            XCTAssertEqual(abs(m.gripAlong - m.orbAlong), m.gripReach, accuracy: 0.001)
            let away = m.orbAlong <= 0 ? m.gripAlong < m.orbAlong : m.gripAlong > m.orbAlong
            XCTAssertTrue(away, "the grip is over the notch rather than beside it")
        }
    }

    // MARK: - Knowing when not to

    /// **Nudged off the hole, it is a notch like any other.**
    ///
    /// ⌥-drag moves the notch along the edge. Up to `cutoutReach` the join
    /// simply reaches further; past that the notch is somewhere else on the
    /// bezel and pretending otherwise would draw a bridge to a hole that is no
    /// longer there.
    func testItLetsGoOnceItHasBeenDraggedClear() {
        let screen = Notched()
        XCTAssertNotNil(model(screen, offset: 0).cutout)
        XCTAssertNil(model(screen, offset: 400).cutout,
                     "dragged half a screen away it is still claiming to be merged")
        XCTAssertNil(model(screen, offset: -200).cutout,
                     "dragged out the far side of the hole it is still claiming to be merged")
    }

    /// **A gap is not a join.**
    ///
    /// The bridge reached across one for a while, on the reasoning that two
    /// shapes a few points apart still read as one object. They do not: what is
    /// drawn at the joined end is a square tip and a flat run at the hole's own
    /// depth, and the only reason that may be square is that it is *inside* the
    /// hole where nothing shows. Over a gap it is a hard cut edge hanging in the
    /// open on a shape that has no other straight edge anywhere.
    func testAGapIsNotAJoin() {
        let screen = Notched()
        for nudged in [CGFloat(1), 4, 12, 30] {
            let m = model(screen, offset: nudged)
            XCTAssertFalse(m.mergesWithCutout,
                           "nudged \(nudged)pt off the hole it still draws the join, and "
                           + "the square end of it is out in the open")
            XCTAssertEqual(m.wings.filter { $0.length > 0 }.count, 1,
                           "nudged \(nudged)pt off, it is one bar")
            XCTAssertEqual(m.cutoutBleed, 0,
                           "nudged \(nudged)pt off, nothing of it is buried")
        }
        // Right up against it, it is joined.
        XCTAssertTrue(model(screen, offset: 0).mergesWithCutout)
        XCTAssertTrue(model(screen, offset: -1).mergesWithCutout)

        // And the window is the same either side of that, which is the whole
        // reason the cutout is still reported once the join has gone: a window
        // frame is set in one step, so a join that moved it would drag a third
        // of a screen of slide behind it.
        let joined = model(screen, offset: 0)
        let apart = model(screen, offset: 12)
        XCTAssertEqual(apart.panelSize.width, joined.panelSize.width, accuracy: 0.001,
                       "the window resizes as the notch takes the hole")
        XCTAssertEqual(apart.slack, joined.slack, accuracy: 0.001)
    }

    /// **A nudge toward the hole is not a reason to let go of it.**
    ///
    /// The bug: the join was gated on how far the notch had been ⌥-dragged from
    /// the placement it was given, and a -42pt nudge was already saved for the
    /// top edge on the machine this was written for. That is not a notch parked
    /// somewhere else on the bezel — it is a notch *deeper inside the hole*,
    /// which is the one direction that cannot part the two. It drew no join at
    /// all, on the only display that has a hole to join.
    func testANudgeIntoTheHoleStaysJoined() throws {
        let screen = Notched()
        for offset in [CGFloat(-6), -18, -42] {
            let m = model(screen, scale: 0.589, offset: offset)
            let near = try XCTUnwrap(m.cutout, "a nudge of \(offset)pt *into* the hole let go of it")
            XCTAssertGreaterThanOrEqual(near.overlap, NotchGeometry.cutoutOverlap,
                                        "offset \(offset): joined, but not buried enough "
                                        + "to hide the square end of the join")

            // And the bar still starts at the wall, as it does with no nudge:
            // everything buried in the hole is paid for in length.
            let hole = try hole(screen)
            // Whichever wall it has ended up against.
            let wall = near.atTrailingEnd ? hole.left : hole.wall
            let deepest = outline(of: m, on: screen)
                .filter { near.atTrailingEnd ? $0.x > wall + 0.5 : $0.x < wall - 0.5 }
                .map(\.depth).max() ?? 0
            XCTAssertLessThanOrEqual(deepest, hole.depth + 0.6, "offset \(offset)")
        }
    }

    // MARK: - The other side of the hole

    /// **It merges on the left of the cutout too.**
    ///
    /// It did not, and there was no reason for it beyond the order the two
    /// sides were built in: the bridge was written at the leading end because
    /// that is the end the default placement puts against the hole. Dragged past
    /// the cutout the notch sits on its left, where the end that meets the hole
    /// is its trailing one — the same join, at the other end of the same shape.
    func testItMergesOnTheLeftOfTheCutoutToo() throws {
        let screen = Notched()
        let cutout = try XCTUnwrap(screen.hardwareNotch)
        _ = cutout
        let m = model(screen, offset: try flushOnTheLeft(screen))
        let near = try XCTUnwrap(m.cutout, "dragged to the left of the hole it let go")
        XCTAssertTrue(near.atTrailingEnd, "it is still joining at the wrong end")
        XCTAssertEqual(near.overlap, NotchGeometry.cutoutOverlap, accuracy: 1.5,
                       "it should land flush against the hole's left wall")

        // And the whole run between the two sides is a join: every nudge from
        // flush on the right through to flush on the left.
        let flush = try flushOnTheLeft(screen)
        for step in stride(from: CGFloat(0), through: flush, by: flush / 12) {
            XCTAssertNotNil(model(screen, offset: step).cutout,
                            "a nudge of \(step)pt fell off the hole part way along")
        }
    }

    /// And the join is drawn at that end: nothing of the notch hangs out below
    /// the hole on that side either, and it meets the left wall at the hole's
    /// own depth.
    func testTheLeftHandJoinIsDrawnAtTheFarEnd() throws {
        let screen = Notched()
        let cutout = try XCTUnwrap(screen.hardwareNotch)
        let hole = try hole(screen)
        for open in [true, false] {
            let m = model(screen, open: open, offset: try flushOnTheLeft(screen))
            let drawn = outline(of: m, on: screen)

            let inside = drawn.filter { $0.x > hole.left + 0.5 }
            XCTAssertFalse(inside.isEmpty, "\(open): nothing overlaps the hole, so there "
                           + "is no join — only two shapes side by side")
            XCTAssertLessThanOrEqual(inside.map(\.depth).max() ?? 0, hole.depth + 0.6,
                                     "\(open): it hangs \(inside.map(\.depth).max() ?? 0)pt "
                                     + "below a hole \(hole.depth)pt deep")

            let atWall = drawn.filter { abs($0.x - hole.left) < 1.5 }.map(\.depth)
            XCTAssertEqual(atWall.max() ?? 0, hole.depth, accuracy: 1.0,
                           "\(open): it meets the hole's left wall at \(atWall.max() ?? 0)pt "
                           + "against the hole's \(hole.depth) — a step is a seam")
        }
    }

    /// **Let go near the hole, it takes the nearer wall** — and out of reach,
    /// nothing pulls at it.
    func testItLandsOnTheNearerWall() throws {
        let screen = Notched()
        let cutout = try XCTUnwrap(screen.hardwareNotch)
        let bar: CGFloat = 150
        let onTheLeft = 2 * NotchGeometry.cutoutOverlap - cutout.width - bar
        for (letGo, left) in [(CGFloat(0), false), (20, false), (-30, false),
                              (onTheLeft, true), (onTheLeft - 20, true), (onTheLeft + 30, true)] {
            let standing = try XCTUnwrap(
                NotchGeometry.cutoutLanding(alongOffset: letGo, width: cutout.width, bar: bar),
                "let go at \(letGo)pt, it was not near the hole at all")
            let stand = NotchGeometry.cutoutStanding(alongOffset: standing)
            XCTAssertEqual(stand.overlap, NotchGeometry.cutoutOverlap, accuracy: 0.001)
            XCTAssertEqual(stand.atTrailingEnd, left,
                           "let go at \(letGo)pt, it joined the other wall")
        }
        XCTAssertNil(NotchGeometry.cutoutLanding(alongOffset: 400, width: cutout.width, bar: bar),
                     "out of reach, something still pulls at it")
    }

    // MARK: - A whole drag, tick by tick

    /// Where the panel lands on screen for the model as it stands.
    private func panel(_ m: NotchViewModel, _ screen: ScreenDescribing) -> CGRect {
        NotchGeometry.panelFrame(
            for: screen, panelSize: m.panelSize, edge: .top,
            alongOffset: m.alongOffset, slack: m.slack,
            trailingExtent: m.trailingExtent, leadingExtent: m.leadingExtent,
            heldBar: m.holdsOffTheCutout ? m.plainBarLength : nil)
    }

    /// What of the window the notch is laid out from: its left edge, its width
    /// and its top. The height below is room for a card and changes with the
    /// card — by a whole session row when the drawn size changes — without
    /// moving anything on the top edge, which is laid out from the top.
    private func frameOfReference(_ m: NotchViewModel,
                                  _ screen: ScreenDescribing) -> [CGFloat] {
        let f = panel(m, screen)
        return [f.minX, f.width, f.maxY]
    }

    /// The carrying copy's two ends on screen.
    private func ends(_ m: NotchViewModel, _ screen: ScreenDescribing) -> (CGFloat, CGFloat) {
        let lead = panel(m, screen).minX + m.cellWing.lead
        return (lead, lead + m.notchLength * m.sizeScale)
    }

    /// **Picked up, dragged across both sides of the hole, and put down.**
    ///
    /// Every property the drag was missing, asked of one drag from end to end:
    ///
    /// - picked up, it lets go of the hole *without the window moving*, so the
    ///   letting-go can be eased;
    /// - in the hand it follows the pointer point for point — no stretch where
    ///   nothing moves, no side-hop — and is never drawn joined, so there is no
    ///   square end on the wallpaper;
    /// - put down near the hole it glides onto the nearer wall and then joins
    ///   it, and neither half moves the window or sends the bar anywhere but
    ///   where it was going.
    func testAWholeDrag() throws {
        let screen = Notched()
        let hole = try hole(screen)
        let m = model(screen)
        XCTAssertTrue(m.mergesWithCutout, "it should start joined")
        let resting = frameOfReference(m, screen)
        let startTip = ends(m, screen).0

        // Picked up.
        m.holdsOffTheCutout = true
        m.alongOffset = NotchGeometry.freeOffset(fromStanding: m.alongOffset,
                                                 width: 220, bar: m.plainBarLength)
        m.adopt(screen: screen)
        XCTAssertFalse(m.mergesWithCutout, "in the hand it is still joined")
        XCTAssertEqual(frameOfReference(m, screen), resting, "picking it up moved the window")
        XCTAssertEqual(ends(m, screen).0, startTip, accuracy: 0.5,
                       "picking it up moved its leading tip")

        // Dragged right, back, and all the way past the hole to the left.
        var path: [CGFloat] = Array(stride(from: 0, through: 120, by: 1))
        path += Array(stride(from: 120, through: -520, by: -1))
        var previous: CGFloat?
        for a in path {
            m.alongOffset = a
            m.adopt(screen: screen)
            XCTAssertFalse(m.mergesWithCutout, "at \(a) the join is drawn while in the hand")
            XCTAssertNil(m.notchShape(for: m.cellWing).cutout,
                         "at \(a) the square joined end is drawn on the wallpaper")
            XCTAssertEqual(m.wings.filter { $0.length > 0 }.count, 1,
                           "at \(a) a second copy is showing while in the hand")
            let tip = ends(m, screen).0
            XCTAssertEqual(tip, hole.wall - NotchGeometry.cutoutOverlap + a, accuracy: 0.5,
                           "at \(a) the bar is not under the pointer")
            // A point of pointer per tick, and the window is set in whole
            // points, so two ticks can differ by up to a point and two
            // half-point roundings — never more.
            if let previous {
                XCTAssertLessThanOrEqual(abs(tip - previous), 2,
                                         "at \(a) the bar jumped \(tip - previous)pt in one tick")
            }
            previous = tip
        }

        // Put down near the hole's left wall.
        let bar = m.plainBarLength
        let letGo = 2 * NotchGeometry.cutoutOverlap - 220 - bar + 15
        m.alongOffset = letGo
        m.adopt(screen: screen)
        let before = frameOfReference(m, screen)
        let landing = try XCTUnwrap(NotchGeometry.cutoutLanding(alongOffset: letGo,
                                                                width: 220, bar: bar))
        // The other copy is there before it is let go, all inside the hole, on
        // the side it will come out of.
        let waiting = try XCTUnwrap(m.wings.first { !$0.carriesCells })
        XCTAssertEqual(waiting.length, 0, "the notch has widened before it was let go")
        XCTAssertFalse(waiting.onTheLeft, "put down on the left, the other copy is on the left too")

        // Let go: one movement onto the wall and into the hole.
        m.revealsTheOtherCopy = false
        m.holdsOffTheCutout = false
        m.alongOffset = landing
        m.adopt(screen: screen)
        let arrived = try XCTUnwrap(m.wings.first { $0.id == 1 })
        XCTAssertGreaterThan(arrived.length, 0, "joining did not widen the notch")
        XCTAssertEqual(arrived.id, waiting.id)
        XCTAssertEqual(arrived.onTheLeft, waiting.onTheLeft, "the other copy changed sides")
        XCTAssertTrue(m.mergesWithCutout, "put down against the hole, it did not join it")
        XCTAssertEqual(frameOfReference(m, screen), before, "joining moved the window")
        XCTAssertTrue(m.cellWing.onTheLeft, "put down on the left, the readings went right")
        XCTAssertEqual(ends(m, screen).1, hole.left + NotchGeometry.cutoutOverlap, accuracy: 0.5,
                       "joining sent its joined end somewhere else")
    }

    /// How far the carrying bar's end at the wall has gone in past it, as a
    /// share of the distance it closes up square over — 1 or more is square.
    private func wallEndInside(_ m: NotchViewModel) throws -> CGFloat {
        // No hole beside it, no wall to be in past.
        guard let d = m.notchShape(for: m.cellWing).dip else { return 0 }
        let length = m.cellWing.length / m.sizeScale
        let inside = max(d.easesAfter ? d.to : 0, d.easesBefore ? length - d.from : 0)
        return max(0, inside) / d.closes
    }

    /// **Joining is a number easing, not a shape being swapped.**
    ///
    /// The bar the readings are on used to become a different kind of shape the
    /// instant it joined — its flared end replaced by the joined end in one
    /// frame, with part of that flare outside the hole where the jump showed.
    /// It is the same shape either side of the join now, and the only thing
    /// that changes is `leadingJoin`, which SwiftUI eases through
    /// `animatableData` on the spring the rest of the notch is on.
    func testJoiningEasesTheEndRatherThanSwappingIt() throws {
        let screen = Notched()
        let joined = model(screen)
        let apart = model(screen, offset: 30)
        for m in [joined, apart] {
            XCTAssertNil(m.notchShape(for: m.cellWing).cutout,
                         "the carrying bar is drawn as a different kind of shape")
        }
        // Joined, its end is in past the wall by the whole of the distance it
        // closes up over; apart, it is not in past it at all.
        XCTAssertGreaterThanOrEqual(try wallEndInside(joined), 1 - 0.001,
                                    "joined, its end has not closed up square")
        XCTAssertEqual(try wallEndInside(apart), 0, accuracy: 0.001,
                       "apart, its end has closed up")

        // And it is carried by `animatableData`, which is what lets it ease.
        var shape = SideNotchShape(edge: .top)
        var data = shape.animatableData
        data.first.second.second.second.first = 0.4
        shape.animatableData = data
        XCTAssertEqual(shape.leadingJoin, 0.4, accuracy: 0.0001,
                       "leadingJoin is not animatable, so the join would snap")
        data = shape.animatableData
        data.first.second.first.second = 0.3
        shape.animatableData = data
        XCTAssertEqual(shape.trailingFlare, 0.3, accuracy: 0.0001,
                       "the far end's flare is not animatable, so it would snap")
    }

    /// **Joined, the two sides are the same shape.**
    ///
    /// Both end with the notch's own curve — the one the side with the readings
    /// has — the same corner, the same length, mirror images of each other about
    /// the hole.
    func testTheTwoSidesBalance() throws {
        let screen = Notched()
        for offset in [CGFloat(0), -2 * NotchGeometry.cutoutTravel] {
            let m = model(screen, offset: offset)
            XCTAssertTrue(m.mergesWithCutout)
            let carrying = m.cellWing
            let other = try XCTUnwrap(m.wings.first { $0.id == 1 })
            let a = m.notchShape(for: carrying), b = m.notchShape(for: other)
            XCTAssertEqual(a.cornerRadius, b.cornerRadius, accuracy: 0.001,
                           "the two sides turn different corners")
            XCTAssertEqual(a.trailingFlare, 1, "the side with the readings lost its curve")
            XCTAssertEqual(b.trailingFlare, 1, "the other side lost its curve")
            // Each is joined at its wall — the carrying bar at whichever of its
            // ends that is, since it is never drawn reflected.
            XCTAssertGreaterThanOrEqual(try wallEndInside(m), b.leadingJoin - 0.001)
            XCTAssertEqual(carrying.length, other.length, accuracy: 0.001)
            XCTAssertEqual(carrying.depth, other.depth, accuracy: 0.001)
            XCTAssertNotEqual(carrying.onTheLeft, other.onTheLeft, "both on one side")

            // And on screen: each reaches the same distance out from its wall.
            let hole = try hole(screen)
            let drawn = outline(of: m, on: screen)
            let leftReach = hole.left - (drawn.map(\.x).min() ?? 0)
            let rightReach = (drawn.map(\.x).max() ?? 0) - hole.wall
            XCTAssertEqual(leftReach, rightReach, accuracy: 1.0,
                           "offset \(offset): one side reaches further than the other")
        }
        // Apart from the hole it is the notch it is on every other edge.
        let apart = model(screen, offset: 6)
        XCTAssertEqual(apart.notchShape(for: apart.cellWing).trailingFlare, 1)
    }

    // MARK: - The magnet

    /// **Near the hole it pulls, holds, and lets go with a snap** — and never
    /// jumps or runs backwards to do it.
    func testTheHolesPullIsAMagnet() {
        let W: CGFloat = 220, bar: CGFloat = 150
        let C = NotchGeometry.cutoutCapture, g = NotchGeometry.cutoutGrip
        let left = 2 * NotchGeometry.cutoutOverlap - W - bar
        for target in [CGFloat(0), left] {
            func pulled(_ d: CGFloat) -> CGFloat {
                NotchGeometry.magnetised(target + d, width: W, bar: bar) - target
            }
            // At the spot it sits heavy: a point of pointer is a fraction of one.
            XCTAssertEqual(pulled(0.1) / 0.1, g, accuracy: 0.01, "it does not hold on")
            XCTAssertEqual(pulled(0), 0, accuracy: 0.0001)
            // Out past the pull it follows the pointer exactly.
            XCTAssertEqual(pulled(C + 5), C + 5, accuracy: 0.0001)
            XCTAssertEqual(pulled(-C - 5), -C - 5, accuracy: 0.0001)
            // And at the edge of the pull it meets the pointer — nothing to
            // jump across, coming in or breaking free.
            XCTAssertEqual(pulled(C - 0.001), C, accuracy: 0.01)
            XCTAssertEqual(pulled(-C + 0.001), -C, accuracy: 0.01)
            // Never much faster than the pointer: the pointer arrives in steps,
            // and a curve that ran at 2.7 times it turned each step into one
            // nearly three times the size — choppy right where it joins.
            var steepest: CGFloat = 0
            for d in stride(from: -C, to: C, by: 0.25) {
                steepest = max(steepest, (pulled(d + 0.25) - pulled(d)) / 0.25)
            }
            XCTAssertLessThan(steepest, 1.3, "it outruns the pointer by \(steepest)×")
            // And it meets the pointer at the edge of the pull at the pointer's
            // own pace, so there is no kink going in or coming out.
            XCTAssertEqual((pulled(C - 0.01) - pulled(C - 0.26)) / 0.25, 1, accuracy: 0.05,
                           "it lurches where the pull begins")
            // It never runs backwards.
            var last = pulled(-C - 2)
            for d in stride(from: -C - 1.5, through: C + 2, by: 0.5) {
                let now = pulled(d)
                XCTAssertGreaterThanOrEqual(now, last, "at \(d) it moved against the pointer")
                last = now
            }
        }
    }

    /// **The other side is the notch widening, with the same curve.**
    ///
    /// Always exactly the hole's depth, and ending with the notch's own curve —
    /// the flare and the corner the side with the readings has — never the
    /// hardware's square end. It widens by being drawn longer: nothing at all
    /// until the notch is joined, the carrying side's own length once it is.
    func testTheOtherSideIsTheNotchWidening() throws {
        let screen = Notched()
        let hole = try hole(screen)
        for scale in [0.5, 1.0, 1.5] as [CGFloat] {
            let m = model(screen, scale: scale)
            let widening = try XCTUnwrap(m.wings.first { $0.id == 1 })
            XCTAssertEqual(widening.depth * m.sizeScale - NotchRootView.bezelBleed,
                           hole.depth, accuracy: 0.001,
                           "scale \(scale): the notch widened to a different depth")
            let shape = m.notchShape(for: widening)
            XCTAssertEqual(shape.trailingFlare, 1, "it lost the curve")
            XCTAssertEqual(shape.cornerRadius, m.drawnCornerRadius, accuracy: 0.001,
                           "scale \(scale): its corner is not the notch's own")
            XCTAssertEqual(widening.length, m.notchLength * m.sizeScale, accuracy: 0.001,
                           "scale \(scale): it widened by a different amount on each side")
        }
        // Near the hole but not joined to it, it has not widened at all.
        let apart = model(screen, offset: 6)
        XCTAssertFalse(apart.mergesWithCutout)
        XCTAssertEqual(try XCTUnwrap(apart.wings.first { !$0.carriesCells }).length, 0,
                       "the notch widened before anything joined it")
    }

    // MARK: - Goo

    /// A notch in the hand at a given place, the drag's own measure.
    private func held(_ screen: ScreenDescribing, at a: CGFloat,
                      scale: CGFloat = 0.5888) -> NotchViewModel {
        let m = NotchViewModel()
        m.edge = .top
        m.requestedScale = scale
        m.snapshots = [ProviderSnapshot(id: "p", displayName: "P", glyph: .claude,
                                        fidelity: .official, status: .ok, windows: [])]
        m.isExpanded = true
        m.holdsOffTheCutout = true
        m.alongOffset = a
        m.adopt(screen: screen)
        return m
    }

    /// **It squeezes through the hole rather than sliding under it** — and
    /// keeps its own size doing it.
    ///
    /// Deeper than the hole, a bar dragged through the display's notch showed
    /// its foot passing underneath. In the hand, its own outline dips to the
    /// hole's depth under the hole and eases back to its own depth past a wall
    /// it reaches across. Shrinking the bar to fit moved whichever end was not
    /// under the pointer; cutting it with a mask left a point wherever the cut
    /// crossed its curved end. The dip is neither — it is the bar's shape.
    func testItSqueezesThroughTheHole() throws {
        let screen = Notched()
        let hole = try hole(screen)
        for scale in [0.5888, 1.0, 1.5] as [CGFloat] {
            for a in [CGFloat(-20), -60, -170, -300] {
                let m = held(screen, at: a, scale: scale)
                XCTAssertEqual(m.sizeScale, scale, accuracy: 0.0001,
                               "scale \(scale) at \(a): squeezing changed its size")
                let under = outline(of: m, on: screen)
                    .filter { $0.x > hole.left + 0.5 && $0.x < hole.wall - 0.5 }
                    .map(\.depth).max() ?? 0
                XCTAssertLessThanOrEqual(under, hole.depth + 0.6,
                                         "scale \(scale) at \(a): its foot shows "
                                         + "\(under - hole.depth)pt below the hole")
            }
            // Clear of the hole it is all its own depth again.
            let clear = held(screen, at: 120, scale: scale)
            XCTAssertEqual(clear.carryingDip?.amount ?? 0, 0,
                           "scale \(scale): it dips with nothing to pass through")
        }
        // Joined, the dip is there — so letting go animates it — but the bar is
        // exactly as deep as the hole and it changes nothing.
        let joined = model(screen)
        let dip = try XCTUnwrap(joined.carryingDip)
        XCTAssertEqual(dip.depth, joined.cellWing.depth, accuracy: 0.001,
                       "joined, the dip is not the bar's own depth")
    }

    /// **Pulled away, a strand stretches between it and the hole, thins, and
    /// lets go** — and only while it is in the hand.
    func testTheStrandStretchesAndLetsGo() throws {
        let screen = Notched()
        let hole = try hole(screen)
        let V = NotchGeometry.cutoutOverlap
        let stretch = NotchGeometry.cutoutStretch

        // Touching: not pulled apart at all.
        let touching = try XCTUnwrap(held(screen, at: V).neck, "no strand where they touch")
        XCTAssertEqual(touching.apart, 0, accuracy: 0.001)
        XCTAssertEqual(touching.holeDepth, hole.depth, accuracy: 0.001)

        // Pulled further, it only ever comes further apart.
        var last = touching
        for gap in stride(from: CGFloat(1), to: stretch, by: 1) {
            let n = try XCTUnwrap(held(screen, at: V + gap).neck, "at \(gap) the strand broke early")
            XCTAssertGreaterThan(n.apart, last.apart, "at \(gap) it drew back together")
            last = n
        }
        // And by the full stretch it has let go.
        XCTAssertNil(held(screen, at: V + stretch).neck, "it never lets go")

        // All the way inside the hole there is nothing out here to join to.
        XCTAssertNil(held(screen, at: -120).neck,
                     "a strand is left on the wall with the bar inside the hole")
        // Joined, it lies flat along the bar's own foot, where nothing of it
        // shows.
        let joined = try XCTUnwrap(model(screen).neck, "joined, the strand is dropped rather than eased")
        XCTAssertEqual(joined.barDepth, joined.holeDepth, accuracy: 0.001)
        XCTAssertEqual(joined.apart, 0, accuracy: 0.001)

        // Animatable, so a notch let go near the hole carries it as it glides.
        var shape = GooNeck(neck: touching)
        var data = shape.animatableData
        data.second.first.second = 0.25
        shape.animatableData = data
        XCTAssertEqual(shape.neck.apart, 0.25, accuracy: 0.0001)
    }

    /// **Nothing of the strand hangs below the hole's foot inside the hole**,
    /// at any step of a pull.
    func testTheStrandLeavesAlongTheOutlines() throws {
        let screen = Notched()
        let hole = try hole(screen)
        let V = NotchGeometry.cutoutOverlap
        for scale in [0.5888, 1.0] as [CGFloat] {
            for gap in stride(from: CGFloat(0), to: NotchGeometry.cutoutStretch, by: 0.5) {
                let m = held(screen, at: V + gap, scale: scale)
                let n = try XCTUnwrap(m.neck)
                let path = GooNeck(neck: n).path(in: .zero)
                // Inside the hole, nothing below its foot.
                let insideX = stride(from: n.wall - n.side * 30, to: n.wall, by: n.side * 0.5)
                for x in insideX {
                    let below = CGPoint(x: x, y: hole.depth + 0.75)
                    XCTAssertFalse(path.contains(below),
                                   "scale \(scale) gap \(gap): hangs below the hole at \(x)")
                }
            }
        }
    }

    /// **No point anywhere along a drag.**
    ///
    /// Drags a notch from right of the hole, through it, and out past the left,
    /// and traces the underside of everything black on screen at every step —
    /// the display's own notch included, which hides whatever is drawn inside
    /// it — for two kinds of point. A spike: a dip or poke narrower than six
    /// points and deeper than three. And a corner: somewhere the underside runs
    /// on unbroken but turns sharply within a couple of points. The first
    /// version of this looked only for spikes and passed a drag that had
    /// corners all through it, sliding with the pointer — which is what was
    /// seen, and read as glitchy.
    func testNoPointAnywhereAlongADrag() {
        let screen = Notched()
        let hole = Path(roundedRect: CGRect(x: 790, y: -20, width: 220, height: 58),
                        cornerRadius: 38 * 31.2 / 90)
        var points: [String] = []
        for scale in [0.5888, 1.0] as [CGFloat] {
            for a in stride(from: CGFloat(70), through: -520, by: -4) {
                let m = held(screen, at: a, scale: scale)
                guard m.cutout != nil else { continue }
                let f = NotchGeometry.panelFrame(
                    for: screen, panelSize: m.panelSize, edge: .top,
                    alongOffset: m.alongOffset, slack: m.slack,
                    trailingExtent: m.trailingExtent, leadingExtent: m.leadingExtent,
                    heldBar: m.plainBarLength)
                let rect = CGRect(origin: .zero, size: f.size)
                let neck = m.neck.map { GooNeck(neck: $0).path(in: rect) }
                let bars = m.wings.filter { $0.length > 0 }.map { w -> (NotchViewModel.Wing, Path) in
                    let size = NotchPlacement.panelSize(edge: .top, length: w.length / m.sizeScale,
                                                        depth: w.depth)
                    return (w, m.notchShape(for: w).path(in: CGRect(origin: .zero, size: size)))
                }
                let xs = Array(stride(from: CGFloat(730), through: 1070, by: 1))
                let bottom: [CGFloat] = xs.map { x in
                    var lowest: CGFloat = -1
                    for yi in 0..<120 {
                        let y = CGFloat(yi) + 0.5
                        let local = CGPoint(x: x - f.minX, y: y)
                        var black = hole.contains(CGPoint(x: x, y: y))
                        if !black, let neck, neck.contains(local) { black = true }
                        for (w, path) in bars where !black {
                            let lx = (x - (f.minX + w.lead)) / m.sizeScale
                            let ly = (y + NotchRootView.bezelBleed) / m.sizeScale
                            if path.contains(CGPoint(x: lx, y: ly)) { black = true }
                        }
                        if black { lowest = y }
                    }
                    return lowest
                }
                for i in 3..<(bottom.count - 3) where bottom[i] >= 0 {
                    let window = bottom[(i - 3)...(i + 3)]
                    guard !window.contains(where: { $0 < 0 }) else { continue }
                    let l = bottom[i - 3], r = bottom[i + 3]
                    let spike = max(min(bottom[i] - l, bottom[i] - r),
                                    min(l - bottom[i], r - bottom[i]))
                    // A corner: unbroken either side, turning by more than a
                    // slope of one and a half across four points.
                    let unbroken = zip(window, window.dropFirst()).allSatisfy { abs($0 - $1) <= 2 }
                    let turn = abs((bottom[i + 2] - bottom[i]) - (bottom[i] - bottom[i - 2])) / 2
                    if spike > 3 {
                        points.append("scale \(scale) at \(a): spike \(Int(spike))pt at x \(Int(xs[i]))")
                    } else if unbroken && turn > 1.5 {
                        points.append("scale \(scale) at \(a): corner at x \(Int(xs[i]))")
                    }
                }
            }
        }
        XCTAssertTrue(points.isEmpty, "\(points.count) points along the drag, first: "
                      + points.prefix(6).joined(separator: "; "))
    }

    /// **Merged, each far end's flare meets the top of the screen flat.**
    ///
    /// At the hole's depth the bar has only just room for its corner, its
    /// flare and the band hidden past the bezel. The band used to be the one
    /// cut short, and the flare began above the screen and met its edge already
    /// turning — a tip cut off by the border rather than running into it.
    func testMergedTipsMeetTheBorderFlat() throws {
        let screen = Notched()
        let hole = try hole(screen)
        for offset in [CGFloat(0), -2 * NotchGeometry.cutoutTravel] {
            for readings in [false, true] {
                let m = model(screen, offset: offset)
                m.showsNotchReadings = readings
                m.adopt(screen: screen)
                XCTAssertTrue(m.mergesWithCutout)
                let samples = outline(of: m, on: screen)
                var steepest: CGFloat = 0
                for (a, b) in zip(samples, samples.dropFirst()) {
                    // The far ends only: the joined ends are square, in the hole.
                    guard a.x < hole.left || a.x > hole.wall,
                          (0...0.3).contains(a.depth), (0...0.3).contains(b.depth),
                          abs(b.x - a.x) > 0.001 else { continue }
                    steepest = max(steepest, abs((b.depth - a.depth) / (b.x - a.x)))
                }
                XCTAssertLessThan(steepest, 0.2, "offset \(offset) readings \(readings): "
                                  + "the tip meets the border at a slope of \(steepest)")
            }
        }
    }

    // MARK: - The one ring's percentage

    /// **Merged with one ring, the percentage is on the other side of the Mac's
    /// notch** — level with the ring, as far from its wall as the ring is from
    /// its own, and drawn there, not under the ring.
    func testTheOneRingsPercentageIsAcrossTheCutout() throws {
        let screen = Notched()
        for offset in [CGFloat(0), -2 * NotchGeometry.cutoutTravel] {
            let m = oneRing(screen, offset: offset, readings: true)
            XCTAssertTrue(m.mergesWithCutout)
            XCTAssertTrue(m.readsAcrossTheCutout, "offset \(offset): it stayed under the ring")
            XCTAssertFalse(m.showsCellReading, "offset \(offset): it is drawn twice")

            // Drawn on the other side, and nowhere on the side with the ring.
            let rep = try XCTUnwrap(render(m))
            let other = try XCTUnwrap(m.wings.first { !$0.carriesCells })
            let text = whitePixels(rep, from: other.lead, to: other.lead + other.length,
                                   depth: m.contentDepth * m.sizeScale)
            XCTAssertGreaterThan(text, 20, "offset \(offset): no percentage on the other side")

            // Clear of the hole and of the side's own curved end, as wide as
            // the number.
            let run = m.readingAcrossRun
            XCTAssertGreaterThan(run.lowerBound * m.sizeScale, NotchGeometry.cutoutOverlap,
                                 "offset \(offset): it reaches into the hole")
            XCTAssertLessThan(run.upperBound, other.length / m.sizeScale - m.flare,
                              "offset \(offset): it runs into the curved end")
            XCTAssertEqual(run.upperBound - run.lowerBound, m.readingAcrossTextWidth, accuracy: 0.5,
                           "offset \(offset): no room for it")
            // And the side no longer than the number and a margin either side
            // of it, the far one level with it.
            XCTAssertEqual(other.length / m.sizeScale,
                           run.upperBound + NotchLayout.ringMargin(for: .top) + m.flare,
                           accuracy: 0.5, "offset \(offset): the side is not fitted to it")

            // And held against the Mac's notch, the ring's margin from it —
            // not floating out in the middle of the side.
            let wallEnd = other.onTheLeft ? other.lead + other.length : other.lead
            let edge = other.onTheLeft ? wallEnd - NotchGeometry.cutoutOverlap
                                       : wallEnd + NotchGeometry.cutoutOverlap
            let nearest = try XCTUnwrap(nearestWhite(rep, to: edge, towards: other.onTheLeft ? -1 : 1,
                                                     depth: m.contentDepth * m.sizeScale))
            XCTAssertLessThan(nearest, NotchLayout.ringMargin(for: .top) * m.sizeScale + 3,
                              "offset \(offset): \(nearest)pt from the Mac's notch")
        }

        // Off, or with more than one ring, it is where it always was.
        XCTAssertFalse(oneRing(screen, offset: 0, readings: false).readsAcrossTheCutout)
        let two = model(screen)
        two.showsNotchReadings = true
        XCTAssertFalse(two.readsAcrossTheCutout, "more than one ring, one other side")
        XCTAssertTrue(two.showsCellReading)
        // In the hand the bar is on its own, and its percentage is under it.
        let held = oneRing(screen, offset: 0, readings: true)
        held.holdsOffTheCutout = true
        held.adopt(screen: screen)
        XCTAssertFalse(held.readsAcrossTheCutout)
        XCTAssertTrue(held.showsCellReading)
    }

    private func oneRing(_ screen: ScreenDescribing, offset: CGFloat,
                         readings: Bool) -> NotchViewModel {
        let m = NotchViewModel()
        m.edge = .top
        m.surfaceStyle = .solid
        m.accentColor = .blue
        m.showsNotchReadings = readings
        m.alongOffset = offset
        m.snapshots = [ProviderSnapshot(
            id: "p", displayName: "P", glyph: .claude, fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "w", label: "Session", usedFraction: 0.42)],
            headlineID: "w")]
        m.adopt(screen: screen)
        m.isExpanded = true
        return m
    }

    private func render(_ m: NotchViewModel) -> NSBitmapImageRep? {
        let size = m.panelSize
        let renderer = ImageRenderer(content: NotchRootView(model: m)
            .frame(width: size.width, height: size.height)
            .environment(\.codenotchHeadlessGlass, true)
            .environment(\.colorScheme, .dark))
        renderer.scale = 1
        return renderer.cgImage.map(NSBitmapImageRep.init(cgImage:))
    }

    /// How far from `x`, heading one way along the panel, the first near-white
    /// pixel is.
    private func nearestWhite(_ rep: NSBitmapImageRep, to x: CGFloat, towards: CGFloat,
                              depth: CGFloat) -> CGFloat? {
        for step in 0..<200 {
            let column = Int(x + towards * CGFloat(step))
            guard column >= 0, column < rep.pixelsWide else { return nil }
            if whitePixels(rep, from: CGFloat(column), to: CGFloat(column + 1), depth: depth) > 0 {
                return CGFloat(step)
            }
        }
        return nil
    }

    /// Near-white pixels between two points along the panel, down to `depth`.
    private func whitePixels(_ rep: NSBitmapImageRep, from: CGFloat, to: CGFloat,
                             depth: CGFloat) -> Int {
        var count = 0
        for x in Int(max(0, from))..<Int(min(CGFloat(rep.pixelsWide), to)) {
            for y in 0..<Int(min(CGFloat(rep.pixelsHigh), depth)) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.redComponent > 0.8, c.greenComponent > 0.8, c.blueComponent > 0.8,
                   c.alphaComponent > 0.5 { count += 1 }
            }
        }
        return count
    }

    func testFourRingsSplitInReadingOrderIncludingAfterReordering() {
        for offset in [CGFloat(0), -2 * NotchGeometry.cutoutTravel] {
            let m = model(Notched(), offset: offset)
            for reversed in [false, true] {
                if reversed { m.snapshots.reverse() }
                XCTAssertEqual(m.wings.map { Array($0.cellIndices) }, [[0, 1], [2, 3]])
                let centres = m.snapshots.indices.map {
                    m.ringAlong(index: $0, in: m.cellWing(index: $0))
                }
                XCTAssertEqual(centres, centres.sorted())
                XCTAssertEqual(m.wings.flatMap { wing in
                    wing.cellIndices.map { m.snapshots[$0].id }
                }, m.snapshots.map(\.id))
                for side in NotchCutoutOddSide.allCases {
                    m.cutoutOddSide = side
                    XCTAssertEqual(m.wings.map { $0.cellIndices.count }, [2, 2])
                }
            }
        }
    }

    func testSortingRepartitionsTheRowWithoutReversingTheLeftWing() {
        let m = model(Notched())
        let readings = [0.1, 0.7, 0.4, 0.9].enumerated().map { index, fraction in
            ProviderSnapshot(id: "p\(index)", displayName: "P", glyph: .claude,
                             fidelity: .official, status: .ok,
                             windows: [LimitWindow(id: "w", label: "Session", usedFraction: fraction)],
                             headlineID: "w")
        }
        m.updateSnapshots(readings)
        m.hoveredIndex = 1
        m.updateSnapshots(ProviderOrder.byRemainingUsage(readings))
        XCTAssertEqual(m.snapshots.map(\.id), ["p0", "p2", "p1", "p3"])
        XCTAssertEqual(m.hoveredIndex, 2, "the hovered provider must follow its new index across the hole")
        XCTAssertEqual(m.wings.map { wing in wing.cellIndices.map { m.snapshots[$0].id } },
                       [["p0", "p2"], ["p1", "p3"]])
        let centres = m.snapshots.indices.map { m.ringAlong(index: $0, in: m.cellWing(index: $0)) }
        XCTAssertEqual(centres, centres.sorted())
    }

    func testBothWingsActuallyDrawTheirAssignedRings() throws {
        for count in [3, 4] {
            let m = model(Notched(), count: count)
            m.surfaceStyle = .solid
            m.snapshots = (0..<count).map {
                ProviderSnapshot(id: "p\($0)", displayName: "P", glyph: .claude,
                                 fidelity: .official, status: .ok,
                                 windows: [LimitWindow(id: "w", label: "Session", usedFraction: 0.42)],
                                 headlineID: "w")
            }
            for side in NotchCutoutOddSide.allCases {
                m.cutoutOddSide = side
                let rep = try XCTUnwrap(render(m))
                for index in m.snapshots.indices {
                    let centre = m.ringAlong(index: index, in: m.cellWing(index: index))
                    let halfGlyph: CGFloat = 7 * m.sizeScale
                    XCTAssertGreaterThan(whitePixels(rep, from: centre - halfGlyph, to: centre + halfGlyph,
                                                      depth: m.notchDrawnDepth), 0,
                                         "ring \(index), count \(count), odd side \(side)")
                }
            }
        }
    }

    func testThreeRingsPutTheExtraOnTheChosenSideAndSizeEachWing() {
        for offset in [CGFloat(0), -2 * NotchGeometry.cutoutTravel] {
            let m = model(Notched(), offset: offset, count: 3)
            XCTAssertEqual(m.cutoutOddSide, .right)
            for side in NotchCutoutOddSide.allCases {
                m.cutoutOddSide = side
                let counts = side == .left ? [2, 1] : [1, 2]
                XCTAssertEqual(m.wings.map { $0.cellIndices.count }, counts)
                XCTAssertEqual(m.wings.flatMap { Array($0.cellIndices) }, [0, 1, 2])
                for wing in m.wings {
                    let n = wing.cellIndices.count
                    let body = NotchLayout.bodyLength(cellCount: n, edge: .top)
                    let joinEnd = m.cutoutBleed + m.cellSpacing - NotchLayout.padStart(for: .top)
                    XCTAssertEqual(wing.length / m.sizeScale, body + m.flare + joinEnd, accuracy: 0.001)
                }
                XCTAssertEqual(m.wings[0].length > m.wings[1].length, side == .left)
            }
        }
    }

    func testVisibleHoleWallToRingGapMatchesAdjacentRingsOnBothWings() throws {
        for count in [2, 3, 4, 5] {
            for offset in [CGFloat(0), -2 * NotchGeometry.cutoutTravel] {
                let m = model(Notched(), offset: offset, count: count)
                for side in NotchCutoutOddSide.allCases {
                    m.cutoutOddSide = side
                    for readings in [false, true] {
                        m.showsNotchReadings = readings
                        for wing in m.wings {
                            let index = try XCTUnwrap(wing.onTheLeft ? wing.cellIndices.last : wing.cellIndices.first)
                            let centre = m.ringAlong(index: index, in: wing)
                            let wall = wing.onTheLeft
                                ? wing.lead + wing.length - m.cutoutBleed * m.sizeScale
                                : wing.lead + m.cutoutBleed * m.sizeScale
                            let distance = abs(wall - centre) / m.sizeScale
                            let clearance = distance - NotchLayout.ringDiameter / 2
                            XCTAssertEqual(clearance, m.cellSpacing, accuracy: 0.001)
                            if wing.cellIndices.count > 1 {
                                let adjacentIndex = wing.onTheLeft ? index - 1 : index + 1
                                let adjacentCentre = m.ringAlong(index: adjacentIndex, in: wing)
                                let visibleGap = abs(adjacentCentre - centre) / m.sizeScale
                                    - NotchLayout.ringDiameter
                                XCTAssertEqual(clearance, visibleGap, accuracy: 0.001,
                                               "the wall gap must match adjacent rings on this wing")
                            }
                        }
                    }
                }
            }
        }
    }

    func testHoverAndCardsFollowTheRingOnEitherWing() throws {
        let m = model(Notched())
        let geometry = CursorGeometry(model: m, placement: m.placement)
        for index in m.snapshots.indices {
            let wing = m.cellWing(index: index)
            let centre = m.ringAlong(index: index, in: wing)
            XCTAssertEqual(geometry.cellIndex(along: centre), index)
            XCTAssertEqual(m.tooltipAlong(index: index, length: NotchLayout.cardWidth), centre, accuracy: 0.001)
            let card = try XCTUnwrap(geometry.tooltipRect(index: index))
            XCTAssertEqual(card.midX, centre, accuracy: 0.001)
            let event = UsageResetEvent(providerID: m.snapshots[index].id, providerName: "P",
                                       windowLabel: "Session", glyph: .claude,
                                       previousFraction: 0.9, currentFraction: 0, resetsAt: m.now)
            XCTAssertEqual(try XCTUnwrap(geometry.resetCardRect(event: event)).midX, centre, accuracy: 0.001)
        }
        m.updatePrompt = UpdatePrompt(version: "99", notes: "New", phase: .available)
        XCTAssertEqual(try XCTUnwrap(geometry.updateCardRect).midX, m.notchMiddleAlong, accuracy: 0.001)
        XCTAssertEqual(m.handleWing.id, 0)
    }

    func testExpandedOverlapFootprintIncludesBothWingsEvenWhileFolded() {
        let controller = NotchWindowController()
        let m = controller.model
        m.edge = .top
        m.snapshots = model(Notched(), count: 3).snapshots
        m.adopt(screen: Notched())
        for side in NotchCutoutOddSide.allCases {
            m.cutoutOddSide = side
            m.isExpanded = true
            let expected = CursorGeometry(model: m, placement: m.placement).notchRect
            XCTAssertEqual(controller.expandedNotchRect, expected)
            m.isExpanded = false
            XCTAssertEqual(controller.expandedNotchRect.minX, expected.minX, accuracy: 0.001)
            XCTAssertEqual(controller.expandedNotchRect.width, expected.width, accuracy: 0.001)
        }
    }

    func testSplitFoldsIntoBothWallsAndPickupCarriesAllCells() {
        let m = model(Notched(), count: 3)
        let open = m.wings
        m.isExpanded = false
        for (before, after) in zip(open, m.wings) {
            XCTAssertGreaterThan(before.length, after.length)
            let beforeWall = before.onTheLeft ? before.lead + before.length : before.lead
            let afterWall = after.onTheLeft ? after.lead + after.length : after.lead
            XCTAssertEqual(beforeWall, afterWall, accuracy: 0.001)
        }
        m.isExpanded = true
        m.holdsOffTheCutout = true
        m.adopt(screen: Notched())
        XCTAssertFalse(m.splitsCellsAcrossCutout)
        XCTAssertEqual(m.cellWing.cellIndices, 0..<3)
        XCTAssertEqual(m.cellWing.length, m.plainBarLength, accuracy: 0.001)
        XCTAssertEqual(m.wings.filter { $0.id == 1 }.first?.length, 0)
        m.holdsOffTheCutout = false
        m.adopt(screen: Notched())
        XCTAssertEqual(m.wings.map { $0.cellIndices.count }, [1, 2])
    }

    func testOneRingAndUnmergedLayoutsIgnoreOddSide() {
        let single = oneRing(Notched(), offset: 0, readings: true)
        let before = single.wings
        single.cutoutOddSide = .left
        XCTAssertEqual(single.wings, before)
        XCTAssertTrue(single.readsAcrossTheCutout)
        XCTAssertEqual(single.wings.filter(\.carriesCells).count, 1)
        for edge in NotchEdge.allCases {
            for plain in [false, true] {
                for joins in [false, true] {
                    if edge == .top && !plain && joins { continue }
                    let m = model(plain ? Plain() : Notched())
                    m.edge = edge
                    m.joinsCutout = joins
                    m.adopt(screen: plain ? Plain() : Notched())
                    let before = m.wings
                    m.cutoutOddSide = .left
                    XCTAssertEqual(m.wings, before)
                    XCTAssertEqual(m.wings.count, 1)
                    XCTAssertEqual(m.cellWing.cellIndices, 0..<4)
                }
            }
        }
    }

    /// No hole, no join — on a plain display and on the other three edges.
    func testOnlyTheTopEdgeOfANotchedDisplayMerges() {
        XCTAssertNil(model(Plain()).cutout)
        for edge in [NotchEdge.right, .left, .bottom] {
            let m = NotchViewModel()
            m.edge = edge
            m.adopt(screen: Notched())
            XCTAssertNil(m.cutout, "\(edge) is merging with a hole it never touches")
            XCTAssertNil(m.notchShape.cutout, "\(edge)")
        }
    }
}

/// **The notch grown out of the hole rather than joined to it** — the
/// Appearance choice `NotchViewModel.joinsCutout` switched off. The hole is
/// left alone, and the top edge draws the bar every other edge draws, at the
/// chosen size. The hole's band replaces the upper margin so that the outermost
/// strokes hang from the camera housing, with the reading's lower margin intact.
@MainActor
final class GrowsOutOfTheCutoutTests: XCTestCase {
    private struct Notched: ScreenDescribing {
        var frameValue = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        var visibleFrameValue = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        var hardwareNotch: HardwareNotch? { HardwareNotch(width: 220, height: 32) }
        var displayIdentifier: String? { nil }
    }
    private struct Plain: ScreenDescribing {
        var frameValue = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        var visibleFrameValue = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        var displayIdentifier: String? { nil }
    }

    private var ringModes: [(name: String, ring: WeeklyRing, dashed: Bool, hasWeek: Bool)] {
        [("outside dashed", .outside, true, true),
         ("outside solid", .outside, false, true),
         ("inside", .inside, true, true),
         ("off", .off, false, true),
         ("no weekly data", .outside, true, false)]
    }

    private func model(_ screen: ScreenDescribing, edge: NotchEdge = .top,
                       joins: Bool = false, scale: CGFloat = 1,
                       hasWeek: Bool = false, empty: Bool = false) -> NotchViewModel {
        let m = NotchViewModel()
        m.edge = edge
        m.joinsCutout = joins
        m.sizeScale = scale
        m.showsNotchReadings = true
        m.snapshots = (0..<3).map {
            let windows = [LimitWindow(id: "session", label: "Session", usedFraction: 0.42)]
                + (hasWeek ? [LimitWindow(id: "week", label: "Week", usedFraction: 0.61)] : [])
            return ProviderSnapshot(id: "p\($0)", displayName: "P", glyph: .claude,
                                    fidelity: .official, status: .ok, windows: empty ? [] : windows,
                                    headlineID: "session", weeklyID: hasWeek ? "week" : nil)
        }
        m.adopt(screen: screen)
        m.isExpanded = true
        return m
    }

    /// Switched off, there is no join: nothing of `cutout`, one copy of the
    /// bar, and the hole remembered only for its band.
    func testLeftLooseItDoesNotTakeTheHole() {
        let m = model(Notched())
        XCTAssertNil(m.cutout)
        XCTAssertFalse(m.mergesWithCutout)
        XCTAssertEqual(m.wings.count, 1)
        XCTAssertEqual(m.looseHole, HardwareNotch(width: 220, height: 32))
        XCTAssertEqual(m.looseBand, 32)
    }

    /// The housing meets whichever stroke extends furthest. The whole row moves
    /// together, with no extra overhang charged below the label. Dashed strokes
    /// have the same envelope as solid ones, and absent weekly data costs nothing.
    func testTheOutermostStrokeHangsFromTheHoleInEveryRingMode() {
        for scale: CGFloat in [1, 1.25, 1.5] {
            for mode in ringModes {
                for readings in [true, false] {
                    let m = model(Notched(), scale: scale, hasWeek: mode.hasWeek)
                    m.weeklyRing = mode.ring
                    m.weeklyRingDashed = mode.dashed
                    m.showsNotchReadings = readings
                    let overhang = mode.ring == .outside && mode.hasWeek
                        ? NotchLayout.weeklyOutsideRadius + NotchLayout.weeklyRingStroke / 2
                            - NotchLayout.ringDiameter / 2 : 0
                    let bleed = NotchRootView.bezelBleed
                    let ringTop = (m.ringAcross - NotchLayout.ringDiameter / 2) * scale - bleed
                    let barBottom = m.notchDepth * scale - bleed
                    let context = "\(mode.name), scale \(scale), readings \(readings)"
                    XCTAssertEqual(m.ringOverhang, overhang, accuracy: 0.001, context)
                    XCTAssertEqual(ringTop - overhang * scale, 32, accuracy: 0.001, context)
                    XCTAssertEqual(m.ringAcross,
                                   m.looseBand + NotchLayout.ringDiameter / 2 + overhang + bleed / scale,
                                   accuracy: 0.001, context)
                    if readings {
                        let labelBottom = ringTop + NotchLayout.cellExtent * scale
                        XCTAssertEqual(labelBottom + NotchLayout.ringMargin(for: .top) * scale,
                                       barBottom, accuracy: 0.001, context)
                    }
                    XCTAssertEqual(m.notchDrawnDepth, m.notchDepth * scale, accuracy: 0.001)
                    XCTAssertEqual(m.tooltipInset - m.notchDrawnDepth, NotchLayout.tailGap,
                                   accuracy: 0.001)
                    // The handle stays beside the housing, independent of the cell's shift.
                    XCTAssertGreaterThan(m.shapeLength * scale, 220)
                    XCTAssertEqual(m.orbInset, NotchLayout.orbInsetFromEdge, accuracy: 0.001)
                }
            }
        }
    }

    /// Hiding the reading still leaves an E-high cell with a centred ring.
    /// Moving that cell up by Q keeps the ring at the housing when the reading
    /// is hidden. At the larger sizes this needs a negative inset, not a clamp.
    func testWithoutReadingsTheRingStaysFlushInItsCentredCell() {
        let q = (NotchLayout.cellExtent - NotchLayout.ringDiameter) / 2
        for scale: CGFloat in [1, 1.25, 1.5] {
            let m = model(Notched(), scale: scale)
            let depth = m.notchDepth
            let labelledCentre = m.ringAcross
            m.showsNotchReadings = false
            let ringTop = (m.ringAcross - NotchLayout.ringDiameter / 2) * scale
                - NotchRootView.bezelBleed
            let ringBottom = ringTop + NotchLayout.ringDiameter * scale
            let barBottom = m.notchDepth * scale - NotchRootView.bezelBleed
            XCTAssertFalse(m.showsCellReading)
            XCTAssertEqual(ringTop, 32, accuracy: 0.001)
            XCTAssertEqual(m.ringAcross, labelledCentre, accuracy: 0.001)
            XCTAssertEqual(m.notchDepth, depth - q, accuracy: 0.001)
            if scale == 1.5 { XCTAssertLessThan(m.looseBodyInset, 0) }
            XCTAssertEqual(barBottom - ringBottom,
                           (NotchLayout.ringMargin(for: .top) + q) * scale, accuracy: 0.001)
        }
    }

    /// One week anywhere in the row reserves its envelope for the whole row.
    /// Removing that reading gives the room back without changing the setting.
    func testOnlyDrawnWeeklyRingsReserveTheEnvelope() {
        let m = model(Notched())
        m.weeklyRing = .outside
        let depth = m.notchDepth
        XCTAssertEqual(m.ringOverhang, 0)
        let populated = model(Notched(), hasWeek: true)
        m.snapshots[2] = populated.snapshots[2]
        let overhang = NotchLayout.weeklyOutsideRadius + NotchLayout.weeklyRingStroke / 2
            - NotchLayout.ringDiameter / 2
        XCTAssertEqual(m.ringOverhang, overhang, accuracy: 0.001)
        XCTAssertEqual(m.notchDepth, depth + overhang, accuracy: 0.001)
        m.snapshots[2].windows = []
        XCTAssertEqual(m.ringOverhang, 0)
        XCTAssertEqual(m.notchDepth, depth, accuracy: 0.001)
    }

    /// The model's centres alone cannot catch a stack still drawn at the
    /// bezel. Measure the stroke in its annulus, excluding the glyph and label.
    /// Track grey is deliberately faint, especially with an empty reading, so
    /// a bright-ink threshold alone would miss the very rim being measured.
    func testTheDrawnCellMovesBelowTheBand() throws {
        func ringInkBounds(_ m: NotchViewModel) throws -> ClosedRange<CGFloat> {
            m.surfaceStyle = .solid
            m.accentColor = .blue
            let size = m.panelSize
            let renderer = ImageRenderer(content: NotchRootView(model: m)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark))
            let sampling: CGFloat = 2
            renderer.scale = sampling
            let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            let centreX = m.ringAlong(index: 0, in: m.cellWing)
            let centreY = m.ringAcross * m.sizeScale - NotchRootView.bezelBleed
            let radius = (NotchLayout.ringDiameter / 2 + m.ringOverhang) * m.sizeScale
            let stroke = (m.ringOverhang > 0 ? NotchLayout.weeklyRingStroke
                          : NotchLayout.trackStroke) * m.sizeScale
            let columns = Int((centreX - radius - 1) * sampling)...Int((centreX + radius + 1) * sampling)
            let rows = (0..<Int(m.notchDrawnDepth * sampling)).filter { y in
                columns.contains { x in
                    let dx = (CGFloat(x) + 0.5) / sampling - centreX
                    let dy = (CGFloat(y) + 0.5) / sampling - centreY
                    let distance = hypot(dx, dy)
                    guard distance >= radius - stroke - 1 / sampling,
                          distance <= radius + 1 / sampling else { return false }
                    guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                    else { return false }
                    let high = max(colour.redComponent, colour.greenComponent, colour.blueComponent)
                    let low = min(colour.redComponent, colour.greenComponent, colour.blueComponent)
                    let track = high - low < 0.02 && (0.025...0.25).contains(high)
                    let arc = colour.saturationComponent > 0.25 && high > 0.05
                    return colour.alphaComponent > 0.5 && (track || arc)
                }
            }
            let top = try CGFloat(XCTUnwrap(rows.first)) / sampling
            let bottom = try CGFloat(XCTUnwrap(rows.last) + 1) / sampling
            return top...bottom
        }
        for scale: CGFloat in [1, 1.25, 1.5] {
            for mode in ringModes {
                for readings in [true, false] {
                    // Keep an empty-reading case too: its dimmed track must still register.
                    for empty in [false, true] {
                        let plainModel = model(Plain(), scale: scale, hasWeek: mode.hasWeek, empty: empty)
                        let looseModel = model(Notched(), scale: scale, hasWeek: mode.hasWeek, empty: empty)
                        for m in [plainModel, looseModel] {
                            m.weeklyRing = mode.ring
                            m.weeklyRingDashed = mode.dashed
                            m.showsNotchReadings = readings
                        }
                        let plain = try ringInkBounds(plainModel)
                        let loose = try ringInkBounds(looseModel)
                        let q = (NotchLayout.cellExtent - NotchLayout.ringDiameter) / 2
                        let shift = 32 + NotchRootView.bezelBleed
                            + (looseModel.ringOverhang - NotchLayout.ringMargin(for: .top)
                                          - (readings ? 0 : q)) * scale
                        let context = "\(mode.name), scale \(scale), readings \(readings), empty \(empty)"
                        XCTAssertEqual(loose.lowerBound - plain.lowerBound, shift, accuracy: 1, context)
                        XCTAssertEqual(loose.upperBound - plain.upperBound, shift, accuracy: 1, context)
                        XCTAssertEqual(loose.lowerBound, 32, accuracy: 1, context)
                        XCTAssertEqual(loose.upperBound - loose.lowerBound,
                                       (NotchLayout.ringDiameter + 2 * looseModel.ringOverhang) * scale,
                                       accuracy: 1, context)
                    }
                }
            }
        }
    }

    /// The size setting is the notch's own again: the hole's band is fixed
    /// by the hardware, and the body below it follows the setting.
    func testTheSizeSettingChangesIt() {
        let small = model(Notched(), scale: 1)
        let large = model(Notched(), scale: 1.5)
        let body = NotchLayout.bodyDepth(for: .top) - NotchLayout.ringMargin(for: .top)
        let bleed = NotchRootView.bezelBleed
        XCTAssertEqual(small.notchDepth * small.sizeScale, 32 + bleed + body, accuracy: 0.001)
        XCTAssertEqual(large.notchDepth * large.sizeScale, 32 + bleed + 1.5 * body, accuracy: 0.001)
        for m in [small, large] {
            XCTAssertGreaterThanOrEqual(m.panelSize(cellCount: 3).height,
                                        m.notchDepth * m.sizeScale,
                                        "the panel has to hold the band and the body")
        }
    }

    /// Folded away it is the hole exactly, so nothing of the app shows at
    /// rest, and the hole is what the hand reaches for.
    func testItFoldsAwayToTheHole() {
        for scale: CGFloat in [1, 1.25, 1.5] {
            let m = model(Notched(), scale: scale)
            let ring = m.ringAcross
            let tail = m.tooltipInset
            let depth = m.notchDepth
            m.isExpanded = false
            XCTAssertEqual(m.restingLength * scale, 220, accuracy: 0.001)
            XCTAssertEqual(m.restingDepth * scale, 32, accuracy: 0.001)
            XCTAssertEqual(m.notchDepth, m.restingDepth, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(m.wakeDepth, 32, "the hole itself has to wake it")
            // The shape conceals the cell as it folds; the cell and the tail
            // keep their open geometry rather than following the shrinking depth.
            XCTAssertEqual(m.ringAcross, ring, accuracy: 0.001)
            XCTAssertEqual(m.tooltipInset, tail, accuracy: 0.001)
            m.isExpanded = true
            XCTAssertEqual(m.notchDepth, depth, accuracy: 0.001)
        }
    }

    /// Every other edge, and a display without a hole, are exactly as before:
    /// the band is zero and the choice is never consulted.
    func testNothingElseIsTouchedByTheChoice() {
        for edge in [NotchEdge.left, .right, .bottom] {
            let loose = model(Notched(), edge: edge)
            let joined = model(Notched(), edge: edge, joins: true)
            XCTAssertNil(loose.looseHole, "\(edge) has no hole to grow out of")
            XCTAssertEqual(loose.notchDepth, joined.notchDepth, accuracy: 0.001)
            XCTAssertEqual(loose.ringAcross, joined.ringAcross, accuracy: 0.001)
        }
        let plain = model(Plain())
        XCTAssertNil(plain.looseHole)
        XCTAssertEqual(plain.notchDepth, NotchLayout.bodyDepth(for: .top), accuracy: 0.001)
    }

    /// Switching the choice on takes the hole again, with everything the join
    /// measures; switching it off lets go. The window follows on relocate.
    func testTheChoiceCanBeChangedUnderARunningNotch() {
        let m = model(Notched(), joins: true)
        XCTAssertTrue(m.mergesWithCutout)
        XCTAssertNil(m.looseHole)
        m.joinsCutout = false
        m.adopt(screen: Notched())
        XCTAssertNil(m.cutout)
        XCTAssertNotNil(m.looseHole)
        m.joinsCutout = true
        m.adopt(screen: Notched())
        XCTAssertTrue(m.mergesWithCutout)
        XCTAssertNil(m.looseHole)
    }
}
