import SwiftUI

struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Measured rather than assumed: the panel's real size is whatever
        // AppKit settled on, and the notch has to sit flush against *that*
        // edge, not against the size we asked for.
        GeometryReader { proxy in
            let place = NotchPlacement(edge: model.edge, panelSize: proxy.size)

            ZStack(alignment: .topLeading) {
                Color.clear

                notch(place)

                // Outside the notch and outside its clip: the orb hangs past
                // the end of the shape, tucked into the corner the far flare
                // makes.
                if !model.snapshots.isEmpty {
                    SettingsOrb(isHovered: model.isHoveringSettings, edge: model.edge,
                                    convex: model.orbHugsCorner,
                                    arcRadius: model.orbArcRadius,
                                    arcOffset: model.orbArcOffset)
                        .position(orbCentre(place))
                        // Outward, into the black — not inward to nothing.
                        .scaleEffect(model.isExpanded ? 1 : model.orbMergeScale)
                        // Full strength the whole way in. The arc is buried in
                        // the notch before this reaches zero, so the fade is
                        // only there to guarantee nothing is left on screen
                        // once the notch has folded — it is never what the eye
                        // sees the arc leave by.
                        .opacity(model.isExpanded ? 1 : 0)
                        .animation(motion(orbMotion), value: model.isExpanded)
                }

                if let snapshot = model.hoveredSnapshot, let index = model.hoveredIndex,
                   model.isExpanded {
                    TooltipCard(
                        snapshot: snapshot,
                        activity: model.activity(for: snapshot.id),
                        now: model.now,
                        direction: model.edge.tooltipDirection,
                        sessionCap: model.sessionCap
                    )
                        // Deliberately *no* `.id` here: the card is one object
                        // that travels and resizes between cells, which reads
                        // far better than one card leaving and another arriving.
                        // What must not interpolate is its contents — see
                        // `TooltipCard`.
                        .position(tooltipCentre(place, index: index, snapshot: snapshot))
                        .transition(.opacity.combined(with: .offset(
                            x: model.edge.outward.x * Design.px(24),
                            y: model.edge.outward.y * Design.px(24)
                        )))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            // Swapping cards is a movement like any other here.
            .animation(motion(NotchMotion.glide), value: model.hoveredIndex)
        }
        .animation(motion(NotchMotion.unfold), value: model.isExpanded)
    }

    /// Opening and closing are not mirror images. Appearing, the arc waits its
    /// turn behind the cells before it; hiding, any delay at all lets the notch
    /// start folding first, and the arc reads as going with the frame rather
    /// than into it.
    private var orbMotion: Animation {
        model.isExpanded
            ? NotchMotion.stagger(index: model.snapshots.count)
            : NotchMotion.merge
    }

    private func notch(_ place: NotchPlacement) -> some View {
        SideNotchShape(edge: model.edge, joining: model.joinedNotch)
            .fill(Palette.notch)
            .frame(width: model.notchSize.width, height: model.notchSize.height)
            // Aligned to the corner where the stack starts *and* the bezel is,
            // then pushed clear of any hardware notch. Centring the contents in
            // a shape that had been made deeper is what put the top of every
            // ring inside the hole in the display.
            .overlay(alignment: contentAlignment) {
                cells.padding(bezelSide, model.contentInset)
            }
            // Masked by the notch itself, not by its bounding box. Without this
            // the cells simply sit on top of a shrinking shape and appear to
            // slide out of the end of it; clipped, they are swallowed by the
            // outline as it closes, which is what a notch should do.
            .clipShape(SideNotchShape(edge: model.edge, joining: model.joinedNotch))
            .position(place.point(
                along: model.notchLeadingInset + model.notchLength / 2,
                across: model.notchDepth / 2
            ))
    }

    /// The cells fade and lift into place a beat after the shape starts opening,
    /// each trailing the one before it. Folded shut they are not just hidden but
    /// pulled toward the edge, so the whole thing reads as one movement.
    @ViewBuilder
    private var cells: some View {
        let stack = ForEach(Array(model.snapshots.enumerated()), id: \.element.id) { index, snapshot in
            ProviderCell(
                snapshot: snapshot,
                activity: model.activity(for: snapshot.id),
                isRefreshing: model.refreshing.contains(snapshot.id)
            )
                // Pinned to what the cell claims along the stack, or the drawn
                // rings stop lining up with the centres `ringCenter` hands to
                // the hover bands and the tooltip tails. Across a horizontal
                // edge that is the ring alone — the label sits below it, in the
                // notch's depth, and claims nothing here.
                .frame(width: model.edge.isVertical ? nil : NotchLayout.cellAlong(for: model.edge))
                .opacity(model.isExpanded ? 1 : 0)
                // A short slide toward the edge, no scaling: the clip is
                // already doing the concealing, and scaling on top of it
                // reads as two effects fighting.
                .offset(
                    x: model.isExpanded ? 0 : model.edge.outward.x * Design.px(28),
                    y: model.isExpanded ? 0 : model.edge.outward.y * Design.px(28)
                )
                .animation(motion(NotchMotion.stagger(index: index)), value: model.isExpanded)
        }

        Group {
            if model.edge.isVertical {
                VStack(spacing: NotchLayout.cellSpacing) { stack }
                    .padding(.top, leadIn)
                    // The contents keep the expanded layout while folding, so
                    // the stack does not reflow on its way out; the shape clips it.
                    .frame(width: NotchLayout.bodyDepth(for: model.edge))
            } else {
                HStack(spacing: NotchLayout.cellSpacing) { stack }
                    .padding(.leading, leadIn)
                    .frame(height: NotchLayout.bodyDepth(for: model.edge))
            }
        }
        .allowsHitTesting(model.isExpanded)
    }

    /// The corner of the shape's own frame where the stack starts and the
    /// bezel is — the origin everything inside it is measured from.
    private var contentAlignment: Alignment {
        switch model.edge {
        case .right:  return .topTrailing
        case .left:   return .topLeading
        case .top:    return .topLeading
        case .bottom: return .bottomLeading
        }
    }

    /// Which side of that frame faces the bezel.
    private var bezelSide: Edge.Set {
        switch model.edge {
        case .right:  return .trailing
        case .left:   return .leading
        case .top:    return .top
        case .bottom: return .bottom
        }
    }

    /// Distance from the start of the shape to the first cell, widening
    /// included so the readings stay in the middle of a bar that was stretched
    /// to cover the hardware notch.
    private var leadIn: CGFloat {
        model.flare + NotchLayout.padStart(for: model.edge) + model.endSpread
    }

    private func motion(_ animation: Animation) -> Animation? {
        NotchMotion.respectingReduceMotion(animation, reduceMotion)
    }

    /// The orb sits on the flare's own centre of curvature, one radius in from
    /// the bezel and level with the far end of the shape.
    private func orbCentre(_ place: NotchPlacement) -> CGPoint {
        place.point(
            along: model.slack + model.orbAlong,
            across: model.orbInset
        )
    }

    /// The tooltip is the card plus its tail; `position` centres that pair, so
    /// the tail lands on the hovered cell and the card sits beyond it.
    private func tooltipCentre(
        _ place: NotchPlacement, index: Int, snapshot: ProviderSnapshot
    ) -> CGPoint {
        let card = model.edge.isVertical
            ? NotchLayout.cardWidth
            : NotchLayout.cardHeight(
                for: snapshot,
                activity: model.activity(for: snapshot.id),
                sessionCap: model.sessionCap,
                now: model.now
            )
        return place.point(
            along: model.slack + model.ringCenter(index: index),
            across: model.tooltipInset + (NotchLayout.tailLength + card) / 2
        )
    }
}
