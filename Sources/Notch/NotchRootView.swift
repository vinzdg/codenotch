import SwiftUI

struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.codenotchReduceTransparency) private var reduceTransparency
    @Environment(\.codenotchHeadlessGlass) private var headlessGlass
    @Environment(\.colorScheme) private var colorScheme

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
                SettingsOrb(isHovered: model.isHoveringSettings, edge: model.edge,
                                    convex: model.orbHugsCorner,
                                    arcRadius: model.orbArcRadius,
                                    arcOffset: model.orbArcOffset,
                                    spins: model.settingsSpins)
                        // A second route to the same action the panel's own
                        // `mouseDown` override reaches for — see
                        // `NotchViewModel.onOpenSettings`. Both still depend
                        // on the panel's `ignoresMouseEvents`/`hitTest` gate
                        // to receive the click at all, so this alone would
                        // not rescue a click that never reaches the content
                        // view — but once it does, this fires reliably where
                        // the AppKit-level path did not.
                        .contentShape(Circle())
                        .onTapGesture {
                            model.settingsSpins += 1
                            model.onOpenSettings?()
                        }
                        // Before `position`, not after. `position` hands back a
                        // view the size of the whole panel with the orb placed
                        // inside it, so a scale applied after this one scales
                        // *that* layer about the panel's centre — which moves
                        // the orb away from the notch by a share of the panel,
                        // and left the arc floating off the corner it is drawn
                        // to hug. Here it scales the orb about its own centre,
                        // which is what `orbCentre` then places.
                        .scaleEffect(model.sizeScale)
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

                // The move handle, mirroring the settings orb at the other end
                // of the stack. Same construction, same reasons — see the
                // comments on the orb above; only the placement differs.
                if model.showsMoveHandle {
                    MoveHandle(isHovered: model.isHoveringMove || model.isMoving,
                               isArmed: model.isMoving,
                               edge: model.edge,
                               convex: model.orbHugsCorner,
                               arcRadius: model.orbArcRadius,
                               arcOffset: model.moveArcOffset,
                               spins: model.moveSpins)
                            .contentShape(Circle())
                            .scaleEffect(model.sizeScale)
                            .position(moveCentre(place))
                            .scaleEffect(model.isExpanded ? 1 : model.orbMergeScale)
                            .opacity(model.isExpanded ? 1 : 0)
                            .animation(motion(orbMotion), value: model.isExpanded)
                }

                if let resetEvent = model.activeResetAlert,
                   model.isExpanded,
                   model.hoveredIndex == nil {
                    let index = model.resetAlertIndex(for: resetEvent) ?? 0
                    let snapshot = model.snapshots[safe: index] ?? model.snapshots.first ?? Fixtures.snapshots().first!
                    UsageResetCard(
                        event: resetEvent,
                        direction: model.edge.tooltipDirection,
                        tailOffset: tooltipTailOffset(index: index, snapshot: snapshot),
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.18)) {
                                model.activeResetAlert = nil
                            }
                        }
                    )
                    .position(resetCardCentre(place, index: index))
                    .transition(.opacity.combined(with: .offset(
                        x: model.edge.outward.x * Design.px(24),
                        y: model.edge.outward.y * Design.px(24)
                    )))
                } else if let snapshot = model.hoveredSnapshot, let index = model.hoveredIndex,
                   model.isExpanded {
                    TooltipCard(
                        snapshot: snapshot,
                        activity: model.activity(for: snapshot),
                        now: model.now,
                        direction: model.edge.tooltipDirection,
                        sessionCap: model.sessionCap,
                        resetTimeFormat: model.resetTimeFormat,
                        deepSeekPricingEnabled: model.deepSeekPricingEnabled,
                        deepSeekPricingSchedule: model.deepSeekPricingSchedule,
                        tailOffset: tooltipTailOffset(index: index, snapshot: snapshot),
                        onFocusSession: model.onFocusSession
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
        .tint(model.accentColor.color)
        .environment(\.codenotchAccentColor, model.accentColor.color)
        .environment(\.notchSurfaceStyle, model.surfaceStyle)
        .environment(\.tooltipSecondaryInk, TooltipGlassContrast.secondaryInk(
            surfaceStyle: model.surfaceStyle,
            colorScheme: colorScheme,
            reduceTransparency: reduceTransparency
        ))
        .environment(\.weeklyRingDashed, model.weeklyRingDashed)
        .environment(\.usageWatchLimit, model.watchLimit)
        .environment(\.usageCriticalLimit, model.criticalLimit)
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
        let shape = SideNotchShape(edge: model.edge, joining: model.joinedNotch)
        // Glass is for the open notch only. Folded, the pill has to read as
        // part of the bezel — and as the hardware notch itself on a MacBook —
        // so it stays black; and glass under a `.statusBar` panel at rest
        // would only be sampling the desktop for nothing.
        //
        // Reduce transparency means "no see-through chrome", which for the
        // notch is the solid style — the same precedence the Settings window
        // applies to its own translucent chrome.
        let glassy = model.surfaceStyle.isGlass
            && !reduceTransparency

        return ZStack {
            if glassy {
                if #available(macOS 26.0, *) {
                    // The same layer twice, once without the material: an
                    // offscreen `ImageRenderer` cannot draw the system glass
                    // faithfully, so the pixel tests ask for the glass path
                    // with the material left out and check the parts that are
                    // ours. See TASKS.md, "The hardware's band stays black".
                    if headlessGlass {
                        Color.clear
                            .frame(width: place.panelSize.width, height: place.panelSize.height)
                            .background {
                                if let dim = model.surfaceStyle.glassDim {
                                    Rectangle().fill(dim)
                                }
                            }
                            .id(model.isExpanded)
                    } else {
                        Color.clear
                            .frame(width: place.panelSize.width, height: place.panelSize.height)
                            .glassEffect(model.surfaceStyle.glass, in: Rectangle())
                            .background {
                                if let dim = model.surfaceStyle.glassDim {
                                    Rectangle().fill(dim)
                                }
                            }
                            .id(model.isExpanded)
                    }
                }
            }
            
            ZStack {
                // Nothing of ours underneath: a wash of our own would override the
                // Clear/Tinted choice in Appearance settings, which is the whole
                // point of handing this surface to the system. `darkGlass` is the
                // one deliberate exception, and its dim sits behind the glass
                // itself above, not here.
                //
                // No `else`: the solid fill below is mounted in every style anyway,
                // and below macOS 26 `glassy` is always false, so it is simply left
                // at full opacity.
                shape.fill(Palette.notch).opacity(glassy ? 0 : 1)

                // The band at the hardware's height is the strip beside a hole in
                // the screen. Glass there makes the cutout read as a black
                // rectangle set into a sheet of glass; black there makes the hole
                // and the shape we draw one wide notch again, and the glass begins
                // below it, where the readings begin. A hardware notch only ever
                // joins the top edge, so `.top` is the right alignment; the band is
                // clipped by the `.clipShape(shape)` below, which keeps the bezel
                // fillets at its corners.
                //
                // Deeper than the hardware by the bleed below, and undoing the
                // scale on that one number: the whole shape is pushed `bezelBleed`
                // points past the screen edge after it is scaled, so a band drawn
                // exactly `contentInset` deep ends that far short of the hole and
                // leaves a strip of glass along the bottom of the cutout.
                if model.joinedNotch != nil {
                    Rectangle()
                        .fill(Palette.notch)
                        .frame(height: model.contentInset + Self.bezelBleed / model.sizeScale)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }   
            // The glass and the fill both stay mounted so folding keeps
            // animating one shape rather than swapping one view for another
            // mid-flight; the crossfade rides on the unfold animation already
            // on the root. The band above them is opaque in every state and
            // takes no part in it.
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
            .clipShape(shape)
            // The size choice, applied to the notch and the cells it carries —
            // and to nothing else. Drawn at design-frame size and scaled from
            // there, so `NotchLayout` keeps measuring the one thing it is
            // quoted from.
            // Scaled *from the bezel*, so the outer edge is a fixed point of
            // the transform rather than a number that has to come out right.
            .scaleEffect(model.sizeScale, anchor: bezelAnchor)
            // Neither argument may depend on the scale, and that is the whole
            // point of the anchor above. They used to: `across` was
            // `notchDepth * sizeScale / 2`, which cancels against a
            // centre-anchored scale — but only once both have settled.
            // SwiftUI animates `scaleEffect` and `position` independently, so
            // while a size change is in flight the eased scale and the
            // stepped position disagree and the notch lifts off the bezel,
            // snapping back at the end. Anchored at the edge with a position
            // that never moves, there is nothing left to disagree about: the
            // shape grows inward from a corner that cannot move, animated or
            // not.
            .position(place.point(
                along: (model.edge.isVertical ? place.panelSize.height
                                              : place.panelSize.width) / 2,
                across: model.notchDepth / 2
            ))
            // Pushed a shade past the bezel, and then clipped by the panel.
            //
            // The arithmetic above already lands the shape's outer edge on the
            // screen's, but "exactly" is doing a lot of work: the scale is a
            // fraction, the shape is antialiased, and a display can round its
            // last column its own way. Any of those leaves a hairline of
            // wallpaper between the notch and the bezel — the one thing this
            // shape must never show, since it is meant to read as part of the
            // frame of the screen. Overhanging costs nothing: the panel ends
            // at the bezel and everything past it is simply not drawn.
            .offset(x: model.edge.outward.x * Self.bezelBleed,
                    y: model.edge.outward.y * Self.bezelBleed)
    }

    /// The bezel side as a scaling anchor: the edge the notch is welded to
    /// stays put while everything else moves toward or away from it.
    private var bezelAnchor: UnitPoint {
        switch model.edge {
        case .right:  return .trailing
        case .left:   return .leading
        case .top:    return .top
        case .bottom: return .bottom
        }
    }

    /// How far the shape may overhang the screen edge. Small enough that the
    /// notch is not visibly shallower for it, large enough to swallow a
    /// rounding error at any size.
    private static let bezelBleed: CGFloat = 2

    /// The cells fade and lift into place a beat after the shape starts opening,
    /// each trailing the one before it. Folded shut they are not just hidden but
    /// pulled toward the edge, so the whole thing reads as one movement.
    @ViewBuilder
    private var cells: some View {
        let stack = ForEach(Array(model.snapshots.enumerated()), id: \.element.id) { index, snapshot in
            ProviderCell(
                snapshot: snapshot,
                activity: model.activity(for: snapshot),
                isRefreshing: model.isRefreshing(snapshot),
                weeklyRing: model.weeklyRing
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
                .transition(.opacity.combined(with: .offset(
                    x: model.edge.outward.x * Design.px(28),
                    y: model.edge.outward.y * Design.px(28)
                )).animation(motion(NotchMotion.unfold)))
        }

        Group {
            if model.edge.isVertical {
                VStack(spacing: model.cellSpacing) { stack }
                    .padding(.top, leadIn)
                    // The contents keep the expanded layout while folding, so
                    // the stack does not reflow on its way out; the shape clips it.
                    .frame(width: NotchLayout.bodyDepth(for: model.edge))
            } else {
                HStack(spacing: model.cellSpacing) { stack }
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
    /// The orb belongs to the notch, not to the tooltip, so it scales with it —
    /// it is tucked into the corner the shape's own flare makes, and a fixed
    /// orb against a scaled flare would sit off that corner.
    private func orbCentre(_ place: NotchPlacement) -> CGPoint {
        place.point(
            along: model.slack + model.orbAlong * model.sizeScale,
            across: model.orbInset * model.sizeScale
        )
    }

    private func moveCentre(_ place: NotchPlacement) -> CGPoint {
        place.point(
            along: model.slack + model.moveAlong * model.sizeScale,
            across: model.orbInset * model.sizeScale
        )
    }

    private func tooltipLength(_ snapshot: ProviderSnapshot) -> CGFloat {
        model.edge.isVertical
            ? NotchLayout.cardHeight(
                windowCount: snapshot.windows.count,
                groupCount: snapshot.windowGroupCount,
                moneyWindowCount: snapshot.windows.filter { $0.money != nil }.count,
                usageDetailGroupCount: snapshot.usageDetail?.visibleGroups.count ?? 0,
                sessionCount: snapshot.localModel == nil ? (model.activity(for: snapshot.id)?.sessions.count ?? 0) : 0,
                sessionCap: model.sessionCap,
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
            : NotchLayout.cardWidth
    }

    private func tooltipTailOffset(index: Int, snapshot: ProviderSnapshot) -> CGFloat {
        model.slack + model.ringCenter(index: index) * model.sizeScale
            - model.tooltipAlong(index: index, length: tooltipLength(snapshot))
    }

    /// The tooltip is the card plus its tail; `position` centres that pair, so
    /// the tail lands on the hovered cell and the card sits beyond it.
    private func tooltipCentre(
        _ place: NotchPlacement, index: Int, snapshot: ProviderSnapshot
    ) -> CGPoint {
        let card = model.edge.isVertical
            ? NotchLayout.cardWidth
            : NotchLayout.cardHeight(
                windowCount: snapshot.windows.count,
                groupCount: snapshot.windowGroupCount,
                moneyWindowCount: snapshot.windows.filter { $0.money != nil }.count,
                usageDetailGroupCount: snapshot.usageDetail?.visibleGroups.count ?? 0,
                sessionCount: snapshot.localModel == nil ? (model.activity(for: snapshot.id)?.sessions.count ?? 0) : 0,
                sessionCap: model.sessionCap,
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
        // The ring it points at has moved with the notch, so the tail follows
        // it — but the card beyond the tail is drawn at its own size, and
        // `tooltipInset` already ends where the drawn notch does.
        return place.point(
            along: model.tooltipAlong(index: index, length: tooltipLength(snapshot)),
            across: model.tooltipInset + (NotchLayout.tailLength + card) / 2
        )
    }

    private func resetCardCentre(_ place: NotchPlacement, index: Int) -> CGPoint {
        let card = model.edge.isVertical ? NotchLayout.cardWidth : UsageResetCard.cardHeight
        let cardAlong = model.edge.isVertical ? UsageResetCard.cardHeight : NotchLayout.cardWidth
        return place.point(
            along: model.tooltipAlong(index: index, length: cardAlong),
            across: model.tooltipInset + (NotchLayout.tailLength + card) / 2
        )
    }
}
