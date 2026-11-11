import XCTest
@testable import Codenotch

/// **⌥-dragged, the notch keeps to the screen's frame and goes round it.**
///
/// Along its own edge it slides with the pointer; when another edge is clearly
/// nearer the pointer it goes onto that one, under the pointer.
@MainActor
final class OptionCarryTests: XCTestCase {
    private struct Screen: ScreenDescribing {
        var frameValue = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        var visibleFrameValue = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    }

    func testHowFarThePointerIsFromEachEdge() {
        let frame = Screen().frameValue
        let point = CGPoint(x: 300, y: 900)
        XCTAssertEqual(NotchWindowController.distance(from: .top, of: point, on: frame), 269)
        XCTAssertEqual(NotchWindowController.distance(from: .bottom, of: point, on: frame), 900)
        XCTAssertEqual(NotchWindowController.distance(from: .left, of: point, on: frame), 300)
        XCTAssertEqual(NotchWindowController.distance(from: .right, of: point, on: frame), 1500)
    }

    /// Round the frame: onto whichever edge is clearly nearest, and no
    /// further — out in the middle it stays on the edge it is on.
    func testItGoesRoundOntoTheNearestEdge() {
        let frame = Screen().frameValue
        func edge(from current: NotchEdge, at point: CGPoint) -> NotchEdge {
            NotchWindowController.stickyEdge(current: current, pointer: point, frame: frame)
        }
        // Dragged along the top, it stays on the top.
        XCTAssertEqual(edge(from: .top, at: CGPoint(x: 1200, y: 1150)), .top)
        // Down the right-hand side, it goes round onto the right.
        XCTAssertEqual(edge(from: .top, at: CGPoint(x: 1790, y: 700)), .right)
        // On down to the bottom, onto the bottom.
        XCTAssertEqual(edge(from: .right, at: CGPoint(x: 1500, y: 15)), .bottom)
        // Across and up the left.
        XCTAssertEqual(edge(from: .bottom, at: CGPoint(x: 10, y: 600)), .left)
        XCTAssertEqual(edge(from: .left, at: CGPoint(x: 900, y: 1160)), .top)
    }

    /// At a corner, where two edges are about as near, it does not flick
    /// between them.
    func testItDoesNotFlickerAtACorner() {
        let frame = Screen().frameValue
        let corner = CGPoint(x: 1780, y: 1150)   // 20 from the right, 19 from the top
        XCTAssertEqual(NotchWindowController.stickyEdge(current: .top, pointer: corner, frame: frame), .top)
        XCTAssertEqual(NotchWindowController.stickyEdge(current: .right, pointer: corner, frame: frame), .right)
    }

    /// Gone round, it lands with its middle under the pointer, on any edge.
    func testItLandsUnderThePointer() {
        let screen = Screen()
        let size = CGSize(width: 60, height: 200)
        for (edge, point) in [(NotchEdge.right, CGPoint(x: 1700, y: 300)),
                              (.left, CGPoint(x: 100, y: 800)),
                              (.bottom, CGPoint(x: 1200, y: 80)),
                              (.top, CGPoint(x: 500, y: 1100))] {
            let offset = NotchWindowController.offset(along: edge, at: point, on: screen.frameValue)
            let panel = edge.isVertical ? size : CGSize(width: size.height, height: size.width)
            let frame = NotchGeometry.panelFrame(for: screen, panelSize: panel, edge: edge,
                                                 alongOffset: offset)
            if edge.isVertical {
                XCTAssertEqual(frame.midY, point.y, accuracy: 1, "\(edge): landed away from the pointer")
            } else {
                XCTAssertEqual(frame.midX, point.x, accuracy: 1, "\(edge): landed away from the pointer")
            }
        }
    }
}

/// **The screen's border as one line**, which a dragged notch travels.
@MainActor
final class BorderTrackTests: XCTestCase {
    private let track = BorderTrack(width: 1800, height: 1169)

    func testEveryPlaceIsOnOneEdgeAndBack() {
        for (edge, point) in [(NotchEdge.top, CGPoint(x: 400, y: 0)),
                              (.right, CGPoint(x: 1800, y: 300)),
                              (.bottom, CGPoint(x: 700, y: 1169)),
                              (.left, CGPoint(x: 0, y: 900))] {
            let place = track.position(on: edge, of: point)
            let back = track.place(at: place)
            XCTAssertEqual(back.edge, edge)
            XCTAssertEqual(back.along, edge.isVertical ? point.y : point.x, accuracy: 0.001)
        }
        // Round the whole border and back to the start.
        XCTAssertEqual(track.wrapped(-10), track.perimeter - 10, accuracy: 0.001)
        XCTAssertEqual(track.wrapped(track.perimeter + 10), 10, accuracy: 0.001)
    }

    /// Reaching round a corner, it is some before and the rest after it — and
    /// only then.
    func testItKnowsWhenItReachesRoundACorner() throws {
        let length: CGFloat = 200
        XCTAssertNil(track.corner(for: 900, length: length), "in the middle of the top")
        let round = try XCTUnwrap(track.corner(for: 1800 - 40, length: length))
        XCTAssertEqual(round.corner, .topRight)
        XCTAssertEqual(round.before, 140, accuracy: 0.001)
        XCTAssertEqual(round.after, 60, accuracy: 0.001)
        // Across the start of the line: the top-left corner.
        let wrap = try XCTUnwrap(track.corner(for: 30, length: length))
        XCTAssertEqual(wrap.corner, .topLeft)
        XCTAssertEqual(wrap.before + wrap.after, length, accuracy: 0.001)
        XCTAssertEqual(wrap.after, 130, accuracy: 0.001)
    }
}

/// **At a corner, every movement of the pointer moves the notch round.**
///
/// The screen's corner stops the pointer. Read from one edge only, moving on
/// down the next edge moved nothing until the pointer was well down it, and
/// the notch stopped dead in the corner.
@MainActor
final class CornerReadingTests: XCTestCase {
    private let track = BorderTrack(width: 1800, height: 1169)

    func testNearACornerItIsReadFromBothEdges() {
        let near = CGPoint(x: 1790, y: 20)
        XCTAssertEqual(NotchWindowController.reading(of: near, on: track, nearest: .top), .corner(.topRight))
        let far = CGPoint(x: 900, y: 10)
        XCTAssertEqual(NotchWindowController.reading(of: far, on: track, nearest: .top), .edge(.top))
    }

    /// Pinned against the right-hand edge in the corner, moving down still
    /// moves it round, and moving along the top toward the corner does too.
    func testItNeverStopsDeadInTheCorner() {
        let reading = NotchWindowController.Reading.corner(.topRight)
        var last = -CGFloat.infinity
        // Along the top into the corner, then down the right-hand edge.
        let path = stride(from: CGFloat(1650), through: 1800, by: 10).map { CGPoint(x: $0, y: 5) }
            + stride(from: CGFloat(15), through: 150, by: 10).map { CGPoint(x: 1800, y: $0) }
        for point in path {
            let place = NotchWindowController.place(of: point, on: track, by: reading)
            XCTAssertGreaterThan(place, last, "stopped at \(point)")
            last = place
        }
    }

    /// Read from both edges, a point on either edge is where that edge puts it.
    func testTheCornerReadingAgreesWithEachEdge() {
        let reading = NotchWindowController.Reading.corner(.topRight)
        let onTop = CGPoint(x: 1700, y: 0), onRight = CGPoint(x: 1800, y: 100)
        XCTAssertEqual(NotchWindowController.place(of: onTop, on: track, by: reading),
                       track.position(on: .top, of: onTop), accuracy: 0.001)
        XCTAssertEqual(NotchWindowController.place(of: onRight, on: track, by: reading),
                       track.position(on: .right, of: onRight), accuracy: 0.001)
    }
}

/// **It follows the hand on a spring**: it gets there, carries a little past
/// and comes back, and never rings on.
@MainActor
final class FollowSpringTests: XCTestCase {
    private func run(response: CGFloat, damping: CGFloat, fps: CGFloat) -> (overshoot: CGFloat, settledBy: CGFloat?) {
        let target: CGFloat = 100
        var position: CGFloat = 0, velocity: CGFloat = 0, furthest: CGFloat = 0
        var settledBy: CGFloat?
        let dt = 1 / fps
        for frame in 0..<Int(fps * 2) {
            let step = NotchWindowController.spring(gap: target - position, velocity: velocity,
                                                    elapsed: dt, response: response, damping: damping)
            position += step.moved
            velocity = step.velocity
            furthest = max(furthest, position)
            if settledBy == nil, abs(target - position) < 0.3, abs(velocity) < 6 {
                settledBy = CGFloat(frame + 1) * dt
            }
        }
        return (furthest - target, settledBy)
    }

    func testFollowingTheHandIsBriskAndAllButDead() {
        for fps in [60, 120] as [CGFloat] {
            let r = run(response: NotchWindowController.followResponse,
                        damping: NotchWindowController.followDamping, fps: fps)
            XCTAssertLessThan(r.overshoot, 2, "\(fps)fps: it swings past the hand")
            XCTAssertLessThan(try XCTUnwrap(r.settledBy), 0.5, "\(fps)fps: it lags the hand")
        }
    }

    func testFlowingOffACornerGivesALittleAndSettles() throws {
        for fps in [60, 120] as [CGFloat] {
            let r = run(response: NotchWindowController.settleResponse,
                        damping: NotchWindowController.settleDamping, fps: fps)
            XCTAssertGreaterThan(r.overshoot, 0.1, "\(fps)fps: no give at all")
            XCTAssertLessThan(r.overshoot, 5, "\(fps)fps: it wobbles")
            XCTAssertLessThan(try XCTUnwrap(r.settledBy), 0.8, "\(fps)fps: it never settles")
        }
    }
}
