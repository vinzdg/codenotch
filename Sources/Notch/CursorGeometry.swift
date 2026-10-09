import AppKit

/// One evaluation of hit geometry, discarded when the cursor callback ends.
/// Opening can synchronously refresh content through `onLook`, so the controller
/// starts a new evaluation after that boundary and after changing the hovered
/// cell. Nothing survives the next event or the stationary-pointer poll; no
/// model/screen invalidation list is needed.
@MainActor
final class CursorGeometry {
    private let model: NotchViewModel
    let placement: NotchPlacement
    private lazy var wings = model.wings
    private(set) lazy var cellWing = model.cellWing(in: wings)
    private lazy var cellSpacing = model.cellSpacing
    private lazy var sessionCap = model.sessionCap
    private lazy var orbHandlePoints = model.orbHandlePoints
    private lazy var gripPoint = model.gripPoint
    private var tooltipRects: [Int: CGRect] = [:]

    init(model: NotchViewModel, placement: NotchPlacement) {
        self.model = model
        self.placement = placement
    }

    private func ringAlong(index: Int) -> CGFloat {
        model.ringAlong(index: index, in: cellWing, spacing: cellSpacing)
    }

    func cellIndex(along: CGFloat) -> Int? {
        guard model.alongWithin(along, of: cellWing) != nil else { return nil }
        let pitch = (NotchLayout.cellAlong(for: model.edge) + cellSpacing) * model.sizeScale
        for index in model.snapshots.indices {
            if abs(along - ringAlong(index: index)) <= pitch / 2 { return index }
        }
        return nil
    }

    /// The notch itself, in panel coordinates with a top-left origin.
    private(set) lazy var notchRect: CGRect = placement.rect(
            along: wings.first?.lead ?? model.slack,
            across: 0,
            length: model.drawnAlongExtent(in: wings),
            depth: model.notchDepth * model.sizeScale
        )

    /// What wakes the folded notch. Larger than the pill it surrounds, and
    /// exactly the hardware notch when it is joined to one — see
    /// `NotchViewModel.wakeLength` for both halves of that.
    private(set) lazy var pillRect: CGRect = {
        // Joined, that is both copies and the hole between them: the hardware's
        // own notch is part of the target, which is the whole point of the
        // notch being drawn as part of it.
        let joined = model.mergesWithCutout
        let length = joined ? model.drawnAlongExtent(in: wings) : model.wakeLength
        let lead = joined
            ? (wings.first?.lead ?? model.slack)
            : model.restingAlongLead(in: wings)
                + (model.restingLength * model.sizeScale - model.wakeLength) / 2
        return placement.rect(along: lead, across: 0, length: length, depth: model.wakeDepth)
    }()

    private lazy var orbHandleRect = handleRect(points: orbHandlePoints)
    private lazy var gripRect = handleRect(points: [gripPoint])

    private func handleRect(points: [CGPoint]) -> CGRect {
        let side = model.orbHotZone
        let boxes = points.map { point -> CGRect in
            let centre = placement.point(along: cellWing.lead + point.x * model.sizeScale,
                                         across: point.y * model.sizeScale)
            return CGRect(x: centre.x - side / 2, y: centre.y - side / 2,
                          width: side, height: side)
        }
        return boxes.dropFirst().reduce(boxes.first ?? .zero) { $0.union($1) }
    }

    func handleRect(gripRevealed: Bool) -> CGRect {
        gripRevealed ? orbHandleRect.union(gripRect) : orbHandleRect
    }

    /// Whether the pointer is on the handle itself rather than merely inside
    /// the box that contains it.
    func isOverHandle(_ local: CGPoint) -> Bool {
        // Back into the notch's own measurements, which is what `isOnOrbHandle`
        // is written in — the orb scales with the notch, so its hit test has to
        // be asked in the same space the shape was drawn in.
        model.isOnOrbHandle(
            along: (placement.along(of: local) - cellWing.lead) / model.sizeScale,
            across: placement.across(of: local) / model.sizeScale,
            points: orbHandlePoints
        )
    }

    /// Whether the pointer is on the grip, asked in the same notch-own
    /// measurements `isOverHandle` uses.
    func isOverGrip(_ local: CGPoint) -> Bool {
        model.isOnGrip(
            along: (placement.along(of: local) - cellWing.lead) / model.sizeScale,
            across: placement.across(of: local) / model.sizeScale,
            point: gripPoint
        )
    }

    /// The only region that takes the mouse. Everything else in the panel is a
    /// hole — which matters far more folded than open, since the point of
    /// folding away is to stop being in the way.
    func liveRect(gripRevealed: Bool) -> CGRect {
        guard model.isExpanded else { return pillRect }
        // The orb hangs below the shape, so the live region is both together.
        return notchRect.union(handleRect(gripRevealed: gripRevealed))
    }

    /// The card, its tail, and the gap between the tail and the notch — so
    /// sliding the pointer off the notch and onto the card never leaves it.
    func tooltipRect(index: Int) -> CGRect? {
        if let cached = tooltipRects[index] { return cached }
        guard model.snapshots.indices.contains(index) else { return nil }
        let snapshot = model.snapshots[index]
        let cardHeight = NotchLayout.cardHeight(
            windowCount: snapshot.windows.count,
            groupCount: snapshot.windowGroupCount,
            moneyWindowCount: snapshot.windows.filter { $0.money != nil }.count,
            usageDetailGroupCount: snapshot.usageDetail?.visibleGroups.count ?? 0,
            sessionCount: snapshot.localModel == nil ? (model.activity(for: snapshot.id)?.sessions.count ?? 0) : 0,
            sessionCap: sessionCap,
            statusMessage: snapshot.statusMessage,
            blockMessage: snapshot.block?.summary(now: model.now),
            hasTokenUsage: snapshot.tokenUsage != nil,
            hasPlan: snapshot.plan != nil,
            hasResetCredits: snapshot.hasAvailableResetCredits,
            localModelName: snapshot.localModel?.name,
            showsLocalPerformance: snapshot.showsLocalPerformance,
            localLedgerRows: snapshot.localLedgerRowCount,
            compactRowCount: snapshot.compactRowCount,
            showsDeepSeekPricing: model.deepSeekPricingEnabled
        )
        // Across the stack the region is the card, its tail, and the gap the
        // pointer has to cross. Along it, the card's own extent.
        let cardAcross = model.edge.isVertical ? NotchLayout.cardWidth : cardHeight
        let cardAlong = model.edge.isVertical ? cardHeight : NotchLayout.cardWidth
        let centre = model.cardAlong(centredOn: ringAlong(index: index), length: cardAlong)
        let rect = placement.rect(
            along: centre - cardAlong / 2,
            // The card's own extent does not scale, and it begins where the
            // drawn notch ends.
            across: model.notchDrawnDepth,
            length: cardAlong,
            depth: NotchLayout.tailGap + NotchLayout.tailLength + cardAcross
        )
        tooltipRects[index] = rect
        return rect
    }

    func resetCardRect(event: UsageResetEvent) -> CGRect? {
        let index = model.resetAlertIndex(for: event) ?? 0
        let cardAcross = model.edge.isVertical ? NotchLayout.cardWidth : UsageResetCard.cardHeight
        let cardAlong = model.edge.isVertical ? UsageResetCard.cardHeight : NotchLayout.cardWidth
        let centre = model.cardAlong(centredOn: ringAlong(index: index), length: cardAlong)
        return placement.rect(
            along: centre - cardAlong / 2,
            across: model.notchDrawnDepth,
            length: cardAlong,
            depth: NotchLayout.tailGap + NotchLayout.tailLength + cardAcross
        )
    }

    /// Where the update card is, on the notch's middle — see `UpdateCard`.
    var updateCardRect: CGRect? {
        guard model.isExpanded, model.updatePrompt != nil else { return nil }
        let size = UpdateCard.size(for: model.edge.tooltipDirection)
        let across = model.edge.isVertical ? size.width : size.height
        let along = model.edge.isVertical ? size.height : size.width
        let centre = model.cardAlong(centredOn: cellWing.lead + cellWing.length / 2, length: along)
        return placement.rect(
            along: centre - along / 2,
            across: model.notchDrawnDepth,
            length: along,
            depth: NotchLayout.tailGap + NotchLayout.tailLength + across
        )
    }
}
