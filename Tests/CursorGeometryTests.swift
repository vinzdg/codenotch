import AppKit
import SwiftUI
import XCTest
@testable import Codenotch

@MainActor
final class CursorGeometryTests: XCTestCase {
    private struct Screen: ScreenDescribing {
        var frameValue = CGRect(x: -1920, y: 100, width: 1920, height: 1080)
        var visibleFrameValue: CGRect { frameValue }
        var hardwareNotch: HardwareNotch?
        var displayIdentifier: String? { "same-display" }
    }

    private func model(edge: NotchEdge = .right, expanded: Bool = true) -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = edge
        model.snapshots = (0..<3).map {
            ProviderSnapshot(id: "p\($0)", displayName: "Provider", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        model.adopt(screen: Screen())
        model.isExpanded = expanded
        return model
    }

    private func geometry(_ model: NotchViewModel, size: CGSize? = nil) -> CursorGeometry {
        CursorGeometry(model: model,
                       placement: NotchPlacement(edge: model.edge, panelSize: size ?? model.panelSize))
    }

    // The previous uncached regions are the reference, including AppKit's
    // actual (rounded) panel size rather than the model's requested size.
    private func originalNotch(_ m: NotchViewModel, _ p: NotchPlacement) -> CGRect {
        p.rect(along: m.wings.first?.lead ?? m.slack, across: 0,
               length: m.drawnAlongExtent, depth: m.notchDepth * m.sizeScale)
    }

    private func originalPill(_ m: NotchViewModel, _ p: NotchPlacement) -> CGRect {
        let joined = m.mergesWithCutout
        let length = joined ? m.drawnAlongExtent : m.wakeLength
        let lead = joined ? (m.wings.first?.lead ?? m.slack)
            : m.restingAlongLead + (m.restingLength * m.sizeScale - m.wakeLength) / 2
        return p.rect(along: lead, across: 0, length: length, depth: m.wakeDepth)
    }

    private func originalHandle(_ m: NotchViewModel, _ p: NotchPlacement, grip: Bool) -> CGRect {
        let side = m.orbHotZone
        let points = m.orbHandlePoints + (grip ? [m.gripPoint] : [])
        let boxes = points.map { point -> CGRect in
            let centre = p.point(along: m.handleWing.lead + point.x * m.sizeScale,
                                 across: point.y * m.sizeScale)
            return CGRect(x: centre.x - side / 2, y: centre.y - side / 2,
                          width: side, height: side)
        }
        return boxes.dropFirst().reduce(boxes.first ?? .zero) { $0.union($1) }
    }

    func testRegionsMatchOnEveryEdgeFoldScaleAndCutoutState() {
        for edge in NotchEdge.allCases {
            for expanded in [false, true] {
                for scale in [CGFloat(0.6), 1.4] {
                    for cutout in [nil,
                                   CutoutProximity(depth: 38, overlap: 12, width: 220),
                                   CutoutProximity(depth: 38, overlap: 20, atTrailingEnd: true, width: 220),
                                   CutoutProximity(depth: 38, overlap: -5, width: 220, joined: false)] as [CutoutProximity?] {
                        let m = model(edge: edge, expanded: expanded)
                        m.requestedScale = scale
                        m.cutout = edge == .top ? cutout : nil
                        let requested = m.panelSize
                        let size = CGSize(width: requested.width.rounded(.up) + 1,
                                          height: requested.height.rounded(.up) + 1)
                        let g = geometry(m, size: size)
                        XCTAssertEqual(g.notchRect, originalNotch(m, g.placement))
                        XCTAssertEqual(g.pillRect, originalPill(m, g.placement))
                        for grip in [false, true] {
                            let handle = originalHandle(m, g.placement, grip: grip)
                            XCTAssertEqual(g.handleRect(gripRevealed: grip), handle)
                            XCTAssertEqual(g.liveRect(gripRevealed: grip), expanded
                                           ? originalNotch(m, g.placement).union(handle)
                                           : originalPill(m, g.placement))
                        }
                    }
                }
            }
        }
    }

    func testCellsAndRoundHandlesMatchTheModelOnEveryEdge() {
        for edge in NotchEdge.allCases {
            let m = model(edge: edge)
            m.requestedScale = 0.7
            if edge == .top {
                m.cutout = CutoutProximity(depth: 38, overlap: 20, atTrailingEnd: true, width: 220)
            }
            let g = geometry(m)
            for index in m.snapshots.indices {
                let along = m.ringAlong(index: index, in: m.cellWing)
                XCTAssertEqual(g.cellIndex(along: along), index)
            }
            XCTAssertNil(g.cellIndex(along: m.cellWing.lead - 100))
            for point in m.orbHandlePoints {
                let local = g.placement.point(along: m.handleWing.lead + point.x * m.sizeScale,
                                              across: point.y * m.sizeScale)
                XCTAssertTrue(g.isOverHandle(local))
            }
            let grip = g.placement.point(along: m.handleWing.lead + m.gripPoint.x * m.sizeScale,
                                         across: m.gripPoint.y * m.sizeScale)
            XCTAssertTrue(g.isOverGrip(grip))
            let outside = g.placement.point(along: m.handleWing.lead - 1000, across: 1000)
            XCTAssertFalse(g.isOverHandle(outside))
            XCTAssertFalse(g.isOverGrip(outside))
        }
    }

    func testGripCanBeRevealedAndHiddenWithinTheSameEvaluation() {
        let m = model()
        let g = geometry(m)
        let withoutGrip = g.liveRect(gripRevealed: false)
        let withGrip = g.liveRect(gripRevealed: true)
        XCTAssertNotEqual(withoutGrip, withGrip)
        XCTAssertEqual(g.liveRect(gripRevealed: false), withoutGrip)
        XCTAssertEqual(withGrip, originalNotch(m, g.placement)
                       .union(originalHandle(m, g.placement, grip: true)))
    }

    func testNextEvaluationSeesContentTimeScaleAndSameIdentityScreenChanges() throws {
        let m = model()
        let first = geometry(m)
        let original = try XCTUnwrap(first.tooltipRect(index: 0))
        let originalNotch = first.notchRect
        m.snapshots[0].status = .error("More detail that changes the tooltip height")
        m.sessions["p0"] = (0..<4).map {
            AgentSession(id: "s\($0)", name: "Session", detail: "Task", state: .busy,
                         waitingFor: nil, since: m.now)
        }
        m.now = m.now.addingTimeInterval(60)
        m.requestedScale = 1.3
        m.adopt(screen: Screen(frameValue: CGRect(x: 0, y: -200, width: 2560, height: 1440)))
        let next = geometry(m)
        XCTAssertNotEqual(next.notchRect, originalNotch)
        XCTAssertNotEqual(try XCTUnwrap(next.tooltipRect(index: 0)), original)
        XCTAssertEqual(next.cellWing, m.cellWing)
        XCTAssertEqual(next.notchRect, self.originalNotch(m, next.placement))
        XCTAssertNil(next.tooltipRect(index: -1))
        XCTAssertNil(next.tooltipRect(index: m.snapshots.count))
        m.edge = .top
        m.adopt(screen: Screen(hardwareNotch: HardwareNotch(width: 230, height: 40)))
        m.isExpanded = false
        let folded = geometry(m)
        XCTAssertEqual(folded.liveRect(gripRevealed: false), originalPill(m, folded.placement))
    }

    func testTooltipKeepsItsCardAndGapOnEveryEdge() throws {
        for edge in NotchEdge.allCases {
            let m = model(edge: edge)
            m.visibleAlongRange = 200...800
            let g = geometry(m)
            let height = NotchLayout.cardHeight(windowCount: 0, sessionCap: m.sessionCap)
            let along = edge.isVertical ? height : NotchLayout.cardWidth
            let across = edge.isVertical ? NotchLayout.cardWidth : height
            let centre = m.tooltipAlong(index: 0, length: along)
            let expected = g.placement.rect(along: centre - along / 2, across: m.notchDrawnDepth,
                                            length: along,
                                            depth: NotchLayout.tailGap + NotchLayout.tailLength + across)
            XCTAssertEqual(try XCTUnwrap(g.tooltipRect(index: 0)), expected)
            XCTAssertEqual(g.tooltipRect(index: 0), expected)
        }
    }

    func testOpeningRefreshesGeometryAfterSynchronousOnLook() throws {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        let frame = try XCTUnwrap(controller.panelFrameForTesting)
        let before = geometry(controller.model, size: frame.size)
        let wake = before.pillRect
        var looks = 0
        controller.onLook = {
            looks += 1
            controller.model.requestedScale = 1.4
            controller.model.snapshots = self.model().snapshots
            controller.relocate()
        }
        controller.cursorMoved(at: CGPoint(x: wake.midX, y: wake.midY))
        XCTAssertTrue(controller.model.isExpanded)
        XCTAssertGreaterThan(looks, 0)
        try assertPublishedLiveRectIsCurrent(controller)
    }

    func testHoverRefreshesGeometryAfterSynchronousOnLook() throws {
        let controller = NotchWindowController()
        controller.model.snapshots = model().snapshots
        controller.model.isExpanded = true
        controller.foldsForFullScreen = false
        controller.show()
        defer { controller.stop() }
        let frame = try XCTUnwrap(controller.panelFrameForTesting)
        let m = controller.model
        let p = NotchPlacement(edge: m.edge, panelSize: frame.size)
        let local = p.point(along: m.ringAlong(index: 0, in: m.cellWing),
                            across: m.notchDepth * m.sizeScale / 2)
        var looks = 0
        controller.onLook = {
            looks += 1
            m.requestedScale = 0.6
            controller.relocate()
        }
        controller.cursorMoved(at: local)
        XCTAssertEqual(looks, 1)
        XCTAssertEqual(m.hoveredIndex, 0)
        try assertPublishedLiveRectIsCurrent(controller)
    }

    private func assertPublishedLiveRectIsCurrent(_ controller: NotchWindowController,
                                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let frame = try XCTUnwrap(controller.panelFrameForTesting)
        let hosting = try XCTUnwrap(controller.panelContentViewForTesting?.subviews.first
                                   as? NotchHostingView<NotchRootView>)
        let m = controller.model
        let p = NotchPlacement(edge: m.edge, panelSize: frame.size)
        let expected = originalNotch(m, p).union(originalHandle(m, p,
                                                grip: m.isHoveringSettings || m.isHoveringMove))
        XCTAssertEqual(hosting.interactiveRects.first, expected, file: file, line: line)
    }

    #if DEBUG
    func testOneEvaluationReusesWingsAndReducesCardBudgetTraversals() {
        let m = model()
        let p = NotchPlacement(edge: m.edge, panelSize: m.panelSize)
        let outside = CGPoint(x: -1000, y: -1000)
        let oldWings = m.wingEvaluationCount
        let oldCards = m.cardHeightEvaluationCount
        // An expanded, unhovered outside-pointer callback: live check, handle
        // check, then the same live region for AppKit's event mask.
        _ = originalNotch(m, p).union(originalHandle(m, p, grip: false))
        _ = m.isOnOrbHandle(along: (p.along(of: outside) - m.handleWing.lead) / m.sizeScale,
                           across: p.across(of: outside) / m.sizeScale)
        _ = originalNotch(m, p).union(originalHandle(m, p, grip: false))
        let legacyWings = m.wingEvaluationCount - oldWings
        let legacyCards = m.cardHeightEvaluationCount - oldCards
        let newWings = m.wingEvaluationCount
        let newCards = m.cardHeightEvaluationCount
        let g = CursorGeometry(model: m, placement: p)
        _ = g.liveRect(gripRevealed: false)
        _ = g.isOverHandle(outside)
        _ = g.liveRect(gripRevealed: false)
        let reusedWings = m.wingEvaluationCount - newWings
        let reusedCards = m.cardHeightEvaluationCount - newCards
        XCTAssertEqual(reusedWings, 1)
        XCTAssertLessThan(reusedWings, legacyWings)
        XCTAssertLessThan(reusedCards, legacyCards)
    }
    #endif
}
