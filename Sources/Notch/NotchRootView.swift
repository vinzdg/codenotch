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

                // Under the bar, so the bar's own outline is what shows where the
                // two overlap. No transition: it only ever appears and goes with
                // nothing of it to see — see `NotchViewModel.neck`.
                if let neck = model.neck {
                    GooNeck(neck: neck)
                        .fill(Palette.notch)
                        .transition(.identity)
                }
                ForEach(model.wings) { wing in
                    notch(place, wing: wing)
                        // The side carrying the percentage across the Mac's
                        // notch is as long as the number: "9%" to "10%" eases
                        // it longer rather than stepping.
                        .animation(motion(NotchMotion.reading), value: model.readingAcrossTextWidth)
                }

                // The grip that moves the notch, beside the settings button:
                // out with it, and held out while the pointer is on it. Under
                // the button, which it comes out of and goes back into.
                MoveGrip(separation: gripOut ? 1 : 0,
                         hover: model.isHoveringMove ? 1 : 0,
                         edge: model.edge,
                         reach: model.gripReach,
                         direction: gripDirection)
                    .animation(motion(gripOut ? Self.gripDivide : Self.gripReturn), value: gripOut)
                    // Swelling to meet the pointer, quick and springy.
                    .animation(motion(Self.gripHover), value: model.isHoveringMove)
                    .scaleEffect(model.sizeScale)
                    .position(orbCentre(place))
                    // Carried, the handle's end is `CarriedHandle`, from the
                    // moment it is taken hold of.
                    .opacity(model.carry == nil ? 1 : 0)

                // Outside the notch and outside its clip: the orb hangs past
                // the end of the shape, tucked into the corner the far flare
                // makes.
                // Held open while the pointer is on its grip, so the pair
                // stay together.
                SettingsOrb(isHovered: model.isHoveringSettings || model.isHoveringMove,
                                    edge: model.edge,
                                    convex: model.orbHugsCorner,
                                    arcRadius: model.orbArcRadiusInOrbSpace,
                                    arcOffset: model.orbArcOffsetInOrbSpace,
                                    spins: model.settingsSpins,
                                    reversed: model.carriedOnTheLeft,
                                    separation: arcSeparation,
                                    returning: arcStraight,
                                    quick: arcQuick,
                                    badge: model.updatePending)
                        // Its own timing, here, next to it: the notch's own
                        // unfold spring is set further out for everything that
                        // changes as it opens or folds, and took the arc over —
                        // no pause before it came out, and a spring's overshoot
                        // swelling it as it went back in.
                        .animation(motion(arcMotion), value: arcSeparation)
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
                        .scaleEffect(model.sizeScale * model.orbScale)
                        .position(orbCentre(place))
                        // In and out of the notch as goo, both ways — see
                        // `arcSeparation`. Full strength the whole way: the
                        // arc is back in the notch's black before this reaches
                        // zero, so the fade only makes sure nothing is left on
                        // screen once the notch has folded — it is never what
                        // the eye sees the arc leave by.
                        .opacity(model.isExpanded ? 1 : 0)
                        .animation(motion(orbMotion), value: model.isExpanded)
                        // Carried, it gives way to `CarriedHandle`, at once:
                        // that draws the button as it was, and takes it on.
                        .opacity(model.carry == nil ? 1 : 0)

                // **The handle's end of a carried notch** — the button into the
                // notch like goo, the dots in the hand sliding in to its arc's
                // place; set down, the arc back. See `CarriedHandle`.
                if let carry = model.carry, model.isExpanded {
                    CarriedHandle(carry: carry, edge: model.edge,
                                  trim: SettingsOrb.restingTrim(for: model.edge, convex: false,
                                                                reversed: model.carriedOnTheLeft),
                                  arcRadius: model.orbArcRadiusInOrbSpace,
                                  gripShift: gripShift)
                        .scaleEffect(model.sizeScale * model.orbScale)
                        .position(orbCentre(place))
                }

                if let prompt = model.updatePrompt, model.isExpanded {
                    // An update offered, or installing — ahead of anything
                    // else the notch would show here, until it is answered.
                    UpdateCard(prompt: prompt,
                               direction: model.edge.tooltipDirection,
                               tailOffset: model.notchMiddleAlong - updateCardAlong,
                               onChoice: { model.onUpdateChoice?($0) })
                        .position(updateCardCentre(place))
                        .transition(.opacity.combined(with: .offset(
                            x: model.edge.outward.x * Design.px(24),
                            y: model.edge.outward.y * Design.px(24)
                        )))
                } else if let resetEvent = model.activeResetAlert,
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
                        costRows: model.costRows(for: snapshot),
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
                        // Swapping cards is a movement like any other — and it
                        // is the card's movement alone. This used to sit on the
                        // whole panel, so every change that happened alongside a
                        // change of hover rode it too: picking the notch up moves
                        // the pointer off its ring, and the bar, its strand and
                        // everything else about the notch went off on the card's
                        // half-second glide while the drag stepped under them.
                        // Layers moving on two clocks at once is how a smooth
                        // shape shows a point for a frame or two.
                        .animation(motion(NotchMotion.glide), value: model.hoveredIndex)
                        .transition(.opacity.combined(with: .offset(
                            x: model.edge.outward.x * Design.px(24),
                            y: model.edge.outward.y * Design.px(24)
                        )))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
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
        .environment(\.colorTransitionStyle, model.colorTransitionStyle)
        .onAppear { arcSeparation = arcsOut ? 1 : 0 }
        .onChange(of: arcsOut) { _, open in
            // Both ways as motion, from wherever it is: out as the notch opens,
            // back into the black as it folds. Put back on a timer once the
            // fold had finished instead, a hover inside that time found the
            // arc still out and it simply appeared — and one landing on the
            // reset itself jumped.
            if open {
                // Caught on its way back in, it comes straight back out the
                // way it was going in — the long pull out a fresh one takes
                // would start from where it is not.
                arcStraight = arcHome.map { Date().timeIntervalSince($0) < Self.arcReturn } ?? false
                arcQuick = false
                arcSeparation = 1
            } else {
                arcHome = Date()
                arcStraight = true
                // Still open, in the moment before it folds: home the goo way,
                // into a notch that is there. Folding already: the quick way.
                arcQuick = !model.isExpanded
                arcSeparation = 0
            }
        }
    }

    /// Opening and closing are not mirror images. Appearing, the arc shows
    /// once the notch is most of the way open, lying on the flare it is about
    /// to divide from; hiding, any delay at all lets the notch start folding
    /// first, and the arc reads as going with the frame rather than into it.
    private var orbMotion: Animation {
        model.isExpanded
            // Shown only as it starts to push out: until then it is buried
            // in a notch still opening round it, and anything of it could
            // show outside a flare not yet where it will be.
            ? .linear(duration: 0.01).delay(Self.arcDivides)
            // Once it is back in: only then gone.
            : .linear(duration: 0.04).delay(Self.arcQuickReturn * 0.9)
    }

    /// **How far the handles' arcs have come away from the notch**, 0 to 1.
    ///
    /// Opening, each arc does not just appear beside its flare: it is pushed
    /// out of the notch as a drop on a neck of goo, lets go, and unrolls into
    /// the arc — see `GooArc`. Folding, it goes back in, on the fold's own
    /// motion, so the next opening always starts from where it really is.
    @State private var arcSeparation: CGFloat = 1
    /// Whether the arc is taking the straight way — going back in, or coming
    /// back out having been caught going in — rather than a fresh pop out.
    @State private var arcStraight = false
    /// When it last started back in.
    @State private var arcHome: Date?
    /// Whether it is going back in with the notch already folding — see
    /// `GooArc.quick`.
    @State private var arcQuick = false
    /// Whether the arcs are out: the notch open, and not about to fold.
    private var arcsOut: Bool { model.isExpanded && !model.handlesTuckedAway }

    /// The arc's timing, whichever way it is going.
    private var arcMotion: Animation {
        guard arcsOut else {
            return .easeInOut(duration: arcQuick ? Self.arcQuickReturn : Self.arcReturn)
        }
        return arcStraight ? .easeOut(duration: 0.35) : Self.arcDivide.delay(Self.arcDivides)
    }

    /// When the arcs start dividing, into the notch's unfold: once it is open
    /// and its flares are where the arcs push out through them.
    static let arcDivides: TimeInterval = 0.34
    /// **Hiding, how long the arc takes to go back in** the goo way — rolled up
    /// into a drop, reached for by a neck, and drawn back into the flare — in
    /// the moment the notch waits before folding, so it is in before it does.
    static let arcReturn: TimeInterval = 0.4
    /// And the quick way, when the notch is folding already.
    static let arcQuickReturn: TimeInterval = 0.26

    /// Taken evenly enough to watch the neck draw out and let go; the pull
    /// past its place and the spring back are in the arc's own path — see
    /// `GooArc` — where a spring here spent the stretch in its first instant.
    static let arcDivide = Animation.timingCurve(0.35, 0, 0.25, 1, duration: 0.95)

    private func notch(_ place: NotchPlacement, wing: NotchViewModel.Wing) -> some View {
        // Configured by the model, never assembled here — see `notchShape`.
        let shape = model.notchShape(for: wing)
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

            }
        }   
            // The glass and the fill both stay mounted so folding keeps
            // animating one shape rather than swapping one view for another
            // mid-flight; the crossfade rides on the unfold animation already
            // on the root.
            // This copy's own size — the carrying bar's, or the notch's width
            // as far as it has widened — so a copy grows by being drawn longer,
            // corner and all, rather than by being stretched.
            .frame(width: copySize(wing).width, height: copySize(wing).height)
            // Aligned to the corner where the stack starts *and* the bezel is.
            // Only one copy carries the readings. The other is the container
            // mirrored and nothing else: the point of it is that the hardware's
            // notch has the app either side of it, not that every number is
            // printed twice.
            .overlay(alignment: contentAlignment) { if wing.carriesCells { cells } }
            .overlay(alignment: wing.onTheLeft ? .topTrailing : .topLeading) {
                if !wing.carriesCells { readingAcross(wing) }
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
            //
            // Where this copy sits along the edge. One copy is centred in the
            // panel; a pair straddles the hole, each held against the wall it
            // is joined to — see `NotchViewModel.wings`.
            .position(place.point(
                along: wing.lead + wing.length / 2,
                across: wing.depth / 2
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

    /// A copy's frame in the notch's design measurements, which the size
    /// setting then scales from the bezel like everything else in it.
    private func copySize(_ wing: NotchViewModel.Wing) -> CGSize {
        NotchPlacement.panelSize(edge: model.edge,
                                 length: wing.length / max(model.sizeScale, 0.0001),
                                 depth: wing.depth)
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
    /// How far the shape overhangs the bezel so no wallpaper hairline shows.
    /// Not private: `SideNotchShape` keeps that band straight, so a flare
    /// begins at the first row on screen rather than behind the bezel.
    static let bezelBleed: CGFloat = 2

    /// The cells fade and lift into place a beat after the shape starts opening,
    /// each trailing the one before it. Folded shut they are not just hidden but
    /// pulled toward the edge, so the whole thing reads as one movement.

    /// Distance from the start of the shape to the first cell, widening
    /// included so the readings stay in the middle of a bar that was stretched
    /// to cover the hardware notch.
    /// Taken from the model so the rings are drawn exactly where the geometry
    /// says they are. Computing it here as well is what let the two drift.
    private var leadIn: CGFloat { model.cellsLeadIn }

    @ViewBuilder
    private var cells: some View {
        let stack = ForEach(Array(model.snapshots.enumerated()), id: \.element.id) { index, snapshot in
            ProviderCell(
                snapshot: snapshot,
                activity: model.activity(for: snapshot),
                isRefreshing: model.isRefreshing(snapshot),
                weeklyRing: model.weeklyRing,
                showsWeeklyReading: model.weeklyReading,
                showsReading: model.showsCellReading,
                showsRemaining: model.showsRemainingInNotch,
                shutRingsWhenSpent: model.shutRingsWhenSpent
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
                    // the stack does not reflow on its way out; the shape clips
                    // it. `contentDepth` is the open depth for that reason.
                    .frame(width: model.contentDepth)
            } else {
                HStack(spacing: model.cellSpacing) { stack }
                    .padding(.leading, leadIn)
                    .frame(height: model.contentDepth)
            }
        }
        .allowsHitTesting(model.isExpanded)
    }

    /// **The one ring's percentage, on the other side of the Mac's notch** —
    /// see `NotchViewModel.readsAcrossTheCutout`. Pinned to this copy's wall
    /// end, centred in the side's open run and level with the ring, so it comes
    /// out of the hole with the side that carries it and is clipped by that
    /// side's outline on the way.
    @ViewBuilder
    private func readingAcross(_ wing: NotchViewModel.Wing) -> some View {
        let run = model.readingAcrossRun
        let centre = (run.lowerBound + run.upperBound) / 2
        if model.readsAcrossTheCutout, let snapshot = model.snapshots.first {
            ProviderReading(snapshot: snapshot, weeklyRing: model.weeklyRing,
                            showsWeeklyReading: model.weeklyReading,
                            showsRemaining: model.showsRemainingInNotch,
                            across: run.upperBound - run.lowerBound,
                            acrossAlignment: wing.onTheLeft ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 0, height: 0)
                .offset(x: wing.onTheLeft ? -centre : centre, y: model.contentDepth / 2)
                .opacity(model.isExpanded ? 1 : 0)
                .animation(motion(NotchMotion.stagger(index: 0)), value: model.isExpanded)
                .transition(.opacity.animation(motion(NotchMotion.unfold)))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
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
            along: model.handleWing.lead + model.orbAlong * model.sizeScale,
            across: model.orbInset * model.sizeScale
        )
    }

    /// From the settings button to the dots beside it, in the handle's own
    /// measure.
    private var gripShift: CGSize {
        let d = gripDirection, reach = model.gripReach
        return CGSize(width: d.x * reach, height: d.y * reach)
    }

    /// Whether the grip is out of the settings button: with it, and while the
    /// pointer is on the grip.
    private var gripOut: Bool {
        // Out through a carry too, out of sight, so it is already out beside
        // the button when the carry hands back to it.
        model.isExpanded && (model.isHoveringSettings || model.isHoveringMove
                             || model.carry?.fromHover == true)
    }

    /// Which way the grip is from the settings button, on screen.
    private var gripDirection: CGPoint {
        let d = model.edge.alongDirection
        let away: CGFloat = model.gripAlong >= model.orbAlong ? 1 : -1
        return CGPoint(x: d.x * away, y: d.y * away)
    }

    /// Out on a drawn-out ease, a beat after the button so there is a button
    /// to come out of; back in quicker, as the arcs go home.
    static let gripDivide = Animation.timingCurve(0.35, 0, 0.25, 1, duration: 0.42).delay(0.02)
    static let gripHover = Animation.spring(response: 0.22, dampingFraction: 0.55)
    static let gripReturn = Animation.easeIn(duration: 0.2)

    private func tooltipLength(_ snapshot: ProviderSnapshot) -> CGFloat {
        model.edge.isVertical ? cardAcross(snapshot) : NotchLayout.cardWidth
    }

    /// The card's extent across the stack (its height on a horizontal edge).
    private func cardAcross(_ snapshot: ProviderSnapshot) -> CGFloat {
        NotchLayout.cardHeight(
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
            showsDeepSeekPricing: model.deepSeekPricingEnabled,
            costRows: model.costRows(for: snapshot))
    }

    private func tooltipTailOffset(index: Int, snapshot: ProviderSnapshot) -> CGFloat {
        model.ringAlong(index: index, in: model.cellWing)
            - model.tooltipAlong(index: index, length: tooltipLength(snapshot))
    }

    /// The tooltip is the card plus its tail; `position` centres that pair, so
    /// the tail lands on the hovered cell and the card sits beyond it.
    private func tooltipCentre(
        _ place: NotchPlacement, index: Int, snapshot: ProviderSnapshot
    ) -> CGPoint {
        let card = model.edge.isVertical ? NotchLayout.cardWidth : cardAcross(snapshot)
        // The ring it points at has moved with the notch, so the tail follows
        // it — but the card beyond the tail is drawn at its own size, and
        // `tooltipInset` already ends where the drawn notch does.
        return place.point(
            along: model.tooltipAlong(index: index, length: tooltipLength(snapshot)),
            across: model.tooltipInset + (NotchLayout.tailLength + card) / 2
        )
    }

    /// Where the update card is centred along the notch: on its middle, kept
    /// on the screen.
    private var updateCardAlong: CGFloat {
        let size = UpdateCard.size(for: model.edge.tooltipDirection)
        return model.cardAlong(centredOn: model.notchMiddleAlong,
                               length: model.edge.isVertical ? size.height : size.width)
    }

    private func updateCardCentre(_ place: NotchPlacement) -> CGPoint {
        let size = UpdateCard.size(for: model.edge.tooltipDirection)
        let across = model.edge.isVertical ? size.width : size.height
        return place.point(along: updateCardAlong,
                           across: model.tooltipInset + (NotchLayout.tailLength + across) / 2)
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

/// **The strand between a dragged notch and the display's hole**, drawn in the
/// panel's own points along the top edge — see `NotchViewModel.Neck`.
///
/// Worked out along the wall's outward normal, `s` out from the wall and `y`
/// down from the top of the screen, and laid back onto the panel at the end.
/// Its underside is two curves meeting in the middle of the gap. Each leaves
/// its outline at a point on it and in the direction that outline runs there,
/// so it carries straight on from it; the middle, flat, rises into the bezel
/// as the two are pulled apart, and past that the halves are separate and
/// each draws back along its own outline to nothing.
struct GooNeck: Shape {
    var neck: NotchViewModel.Neck

    /// Animatable so a notch let go near the hole carries the strand with it as
    /// it glides, rather than leaving it where it was.
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                       AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                                      AnimatablePair<CGFloat, CGFloat>>> {
        get {
            AnimatablePair(AnimatablePair(neck.wall, neck.tip),
                           AnimatablePair(AnimatablePair(neck.barDepth, neck.apart),
                                          AnimatablePair(neck.barJoin, neck.dipAmount)))
        }
        set {
            neck.wall = newValue.first.first
            neck.tip = newValue.first.second
            neck.barDepth = newValue.second.first.first
            neck.apart = newValue.second.first.second
            neck.barJoin = newValue.second.second.first
            neck.dipAmount = newValue.second.second.second
        }
    }

    /// Where along it the pinch has reached the bezel, and the two halves part.
    static let parting: CGFloat = 0.5

    /// A point on an outline, and the way the strand heads leaving it.
    private struct Departure {
        var s: CGFloat
        var y: CGFloat
        var ds: CGFloat
        var dy: CGFloat
    }

    private static func step(_ u: CGFloat) -> CGFloat {
        let t = min(max(u, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The point `share` of the way along the hole's outline, heading out of
    /// it: from its foot at the wall — the strand filling the crook of its
    /// rounded corner — back along the foot to where the corner starts, round
    /// the corner, and up the wall to depth `to`.
    private func hole(_ share: CGFloat, to: CGFloat) -> Departure {
        let H = neck.holeDepth, r = max(0.001, min(neck.holeCorner, H))
        let arc = r * .pi / 2
        var d = min(max(share, 0), 1) * (r + arc + max(0, H - r - to))
        if d <= r { return Departure(s: -d, y: H, ds: 1, dy: 0) }
        d -= r
        if d <= arc {
            let a = d / r
            return Departure(s: -r + r * sin(a), y: H - r + r * cos(a), ds: cos(a), dy: -sin(a))
        }
        d -= arc
        return Departure(s: 0, y: max(0, H - r - d), ds: 0, dy: -1)
    }

    /// The bar's end facing the hole as it is drawn right now: its flare and
    /// corner as far as they have closed up square and as far as the depth at
    /// its tip leaves room for them, and the depth of its foot where the corner
    /// meets it — its own depth, or less where its dip is lifting it toward the
    /// hole. All worked out the way `SideNotchShape` draws them, so the strand
    /// lands on the bar's end exactly where it is.
    private struct End {
        /// How far along the flare runs, and how far down.
        var along: CGFloat
        var down: CGFloat
        var corner: CGFloat
        var depth: CGFloat
        /// Where the strand lands on the foot — where the corner meets it —
        /// how deep the foot is there, and how steeply it is still going down,
        /// per point out from the hole.
        var land: CGFloat
        var landDepth: CGFloat
        var slope: CGFloat
    }

    private func end(gap: CGFloat) -> End {
        let n = neck
        let H = n.holeDepth, full = max(n.barDepth, H)
        // Closed up by how far in past the wall its end is, as the bar is.
        let t = min(max(-gap / NotchGeometry.cutoutOverlap, 0), 1)
        let closing = t * t * (3 - 2 * t)
        let open = 1 - min(max(max(n.barJoin, closing), 0), 1)
        let reach = max(0.001, n.barFlare + n.barCorner)
        let rise = min(max(n.dipAmount, 0), 1) * (full - H)
        func floor(_ s: CGFloat) -> (depth: CGFloat, slope: CGFloat) {
            let t = min(max(s / reach, 0), 1)
            let eased = t * t * t * (t * (t * 6 - 15) + 10)
            let slope = t > 0 && t < 1 ? rise * 30 * t * t * (1 - t) * (1 - t) / reach : 0
            return (full - rise * (1 - eased), slope)
        }
        // The depth at the tip is all the room the end has.
        let room = max(0, floor(gap).depth)
        // Eased toward those limits by how much of the dip there is, as
        // `SideNotchShape` eases them.
        let amount = min(max(n.dipAmount, 0), 1)
        func relaxed(_ value: CGFloat, toward limit: CGFloat) -> CGFloat {
            value - amount * max(0, value - limit)
        }
        let along = n.barFlare * open
        let down = relaxed(along, toward: room * 0.6)
        let corner = relaxed(n.barCorner * open, toward: max(0, room - down))
        let foot = floor(gap + along + corner)
        let land = gap + along + corner
        let landing = floor(land)
        return End(along: along, down: down, corner: corner, depth: foot.depth,
                   land: land, landDepth: landing.depth, slope: landing.slope)
    }

    /// The point on the bar's end at depth `y` — round its corner, up its side,
    /// or round its flare into the bezel — heading toward the hole.
    private func bar(depth y: CGFloat, gap: CGFloat) -> Departure {
        let e = end(gap: gap)
        let B = e.depth, R = max(0.001, e.corner)
        let foot = gap + e.along + e.corner
        if y >= B {
            let length = hypot(1, e.slope)
            return Departure(s: e.land, y: e.landDepth, ds: -1 / length, dy: -e.slope / length)
        }
        if y >= B - R {
            // Round the corner — the very curve `SideNotchShape.turn` draws it
            // with, down off the side and on along the foot at the foot's own
            // slope, not a quarter circle: while the foot is lifting the two
            // part company, and the strand bent where it met the real one.
            let p0 = CGPoint(x: gap + e.along, y: B - R), p3 = CGPoint(x: foot, y: B)
            let length = hypot(1, e.slope)
            let arrive = CGVector(dx: 1 / length, dy: e.slope / length)
            let out = R, into = abs(R * arrive.dx + R * arrive.dy)
            let k = SideNotchShape.circleReach
            let p1 = CGPoint(x: p0.x, y: p0.y + out * k)
            let p2 = CGPoint(x: p3.x - arrive.dx * into * k, y: p3.y - arrive.dy * into * k)
            func point(_ t: CGFloat) -> CGPoint {
                let u = 1 - t
                let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                               y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
            }
            var lo: CGFloat = 0, hi: CGFloat = 1
            for _ in 0..<30 {
                let t = (lo + hi) / 2
                if point(t).y < y { lo = t } else { hi = t }
            }
            let t = (lo + hi) / 2, u = 1 - t
            let dx = 3 * u * u * (p1.x - p0.x) + 6 * u * t * (p2.x - p1.x) + 3 * t * t * (p3.x - p2.x)
            let dy = 3 * u * u * (p1.y - p0.y) + 6 * u * t * (p2.y - p1.y) + 3 * t * t * (p3.y - p2.y)
            let size = max(hypot(dx, dy), 0.0001)
            let at = point(t)
            return Departure(s: at.x, y: at.y, ds: -dx / size, dy: -dy / size)
        }
        if y >= min(e.down, B - R) { return Departure(s: gap + e.along, y: y, ds: 0, dy: -1) }
        // On the flare: the same curve `SideNotchShape` draws it with, walked
        // from the tip to the depth asked for. A circle in its place put the
        // point off the bar's real outline, and the strand stood a step out
        // from the bar there.
        let walk = Self.flareWalk
        let want = min(max(y / max(e.down, 0.001), 0), 1)
        var i = 1
        while i < walk.count - 1 && walk[i].v < want { i += 1 }
        let a = walk[i - 1], b = walk[i]
        let t = b.v > a.v ? (want - a.v) / (b.v - a.v) : 0
        let heading = a.heading + (b.heading - a.heading) * t
        let ds = cos(heading) * e.along, dy = sin(heading) * e.down
        let length = max(hypot(ds, dy), 0.0001)
        return Departure(s: gap + e.along * (a.u + (b.u - a.u) * t), y: e.down * want,
                         ds: -ds / length, dy: -dy / length)
    }

    /// `SideNotchShape.fluidTurn` at the notch's own ramp, from the tip — along
    /// the bar, then down — normalised to land on (1, 1).
    static let flareWalk: [(u: CGFloat, v: CGFloat, heading: CGFloat)] = {
        let p: CGFloat = 0.5, steps = 96
        let bend = (CGFloat.pi / 2) / (1 - p)
        var heading: CGFloat = 0, u: CGFloat = 0, v: CGFloat = 0
        var walk: [(u: CGFloat, v: CGFloat, heading: CGFloat)] = [(0, 0, 0)]
        for i in 0..<steps {
            let s = (CGFloat(i) + 0.5) / CGFloat(steps)
            let share = s < p ? s / p : (s > 1 - p ? (1 - s) / p : 1)
            let before = heading
            heading += bend * share / CGFloat(steps)
            u += cos(heading) / CGFloat(steps)
            v += sin(heading) / CGFloat(steps)
            walk.append((u, v, (before + heading) / 2))
        }
        let end = walk[walk.count - 1]
        return walk.map { ($0.u / end.u, $0.v / end.v, $0.heading) }
    }()

    /// A cubic from `a`, leaving along its heading, to `b`, arriving along its
    /// — its handles a little over a third of the way, and, off an outline
    /// heading up, never so long that the curve climbs past where it is going.
    private static func curve(_ path: inout Path, from a: Departure, to b: Departure,
                              at place: (CGFloat, CGFloat) -> CGPoint) {
        let chord = hypot(b.s - a.s, b.y - a.y)
        func reach(_ dy: CGFloat, rise: CGFloat) -> CGFloat {
            let k = 0.36 * chord
            return dy < -0.001 && rise > 0 ? min(k, 0.9 * rise / -dy) : k
        }
        let ka = reach(a.dy, rise: a.y - b.y)
        let kb = reach(-b.dy, rise: b.y - a.y)
        path.addCurve(to: place(b.s, b.y),
                      control1: place(a.s + a.ds * ka, a.y + a.dy * ka),
                      control2: place(b.s - b.ds * kb, b.y - b.dy * kb))
    }

    func path(in rect: CGRect) -> Path {
        let n = neck
        let top = -NotchRootView.bezelBleed
        let r = min(n.holeCorner, n.holeDepth)
        let signed = n.side * (n.tip - n.wall)
        let inside = -(r + 1)
        func at(_ s: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: n.wall + n.side * s, y: y) }
        var path = Path()

        // **Its end in past the wall**, the strand stays, still touching: from
        // the hole's foot at the wall to the bar's foot as far out as a flare
        // and a corner, which is the curve the bar's own dip takes out of the
        // hole there — the one drawn over the other, with nothing to see where
        // either ends. It fills the crook of the hole's corner with the bar's
        // end still in it, where a wedge of wallpaper showed. Further in than
        // the corner the bar fills it itself, and the strand only squared the
        // Mac's corner off once the bar had all but gone in past it.
        guard signed > -r else { return path }
        // The bar's end where it actually is, in past the wall too — its foot
        // never nearer the hole than the wall itself.
        let gap = signed
        let apart = min(max(n.apart, 0), 1)
        let H = n.holeDepth, B = max(end(gap: gap).depth, H)
        let landing = end(gap: gap)
        // Past both, where the closing edges run, inside the hole and the bar.
        // Only as far as the end reaches: joined, that is nowhere outside the
        // hole, and the strand is only the crook of the hole's corner filled.
        // Reaching as far as the end's full flare and corner, it stood out
        // square past a folded bar the moment the notch began to unfold.
        let beyond = max(gap + landing.along + landing.corner, landing.land) + 1
        let place = { (s: CGFloat, y: CGFloat) in at(s, y) }

        if apart < Self.parting {
            // **One strand**, its middle thinning up toward the bezel. Each end
            // leaves its outline half way between the outline's foot and the
            // middle's depth, so it is always deeper than the middle and the
            // curve from it only ever rises to it.
            let thin = Self.step(apart / Self.parting)
            let mid = (H + B) / 2
            let my = mid * (1 - thin)
            // At the wall on the hole's foot until the middle is up past it,
            // then round the corner as the middle rises the rest of the way.
            let h = hole(max(0, (H - my) / H), to: H / 2)
            let b = bar(depth: B - 0.5 * thin * (B - my), gap: gap)
            let ms = (h.s + b.s) / 2
            let slope = (1 - thin) * 1.5 * (b.y - h.y) / max(1, b.s - h.s)
            let length = hypot(1, slope)
            let m = Departure(s: ms, y: my, ds: 1 / length, dy: slope / length)
            path.move(to: at(inside, top))
            path.addLine(to: at(beyond, top))
            path.addLine(to: at(beyond, b.y))
            path.addLine(to: at(b.s, b.y))
            Self.curve(&path, from: b, to: Departure(s: m.s, y: m.y, ds: -m.ds, dy: -m.dy),
                       at: place)
            Self.curve(&path, from: Departure(s: m.s, y: m.y, ds: -m.ds, dy: -m.dy),
                       to: Departure(s: h.s, y: h.y, ds: -h.ds, dy: -h.dy), at: place)
            path.addLine(to: at(inside, h.y))
            path.closeSubpath()
            return path
        }

        // **Parted.** Each half ends flat on the bezel where the strand parted,
        // and draws back into its own outline: the point it leaves from climbs
        // to where that outline meets the bezel, and its end on the bezel
        // follows it there.
        let back = Self.step((apart - Self.parting) / (1 - Self.parting))
        let h = hole(1, to: H / 2 * (1 - back))
        let b = bar(depth: B / 2 * (1 - back), gap: gap)
        let split = (hole(1, to: H / 2).s + bar(depth: B / 2, gap: gap).s) / 2
        let mh = max(h.s, split * (1 - back))
        let mb = min(b.s, split + (gap - split) * back)

        path.move(to: at(inside, top))
        path.addLine(to: at(mh, top))
        path.addLine(to: at(mh, 0))
        Self.curve(&path, from: Departure(s: mh, y: 0, ds: -1, dy: 0),
                   to: Departure(s: h.s, y: h.y, ds: -h.ds, dy: -h.dy), at: place)
        path.addLine(to: at(inside, h.y))
        path.closeSubpath()

        path.move(to: at(mb, top))
        path.addLine(to: at(beyond, top))
        path.addLine(to: at(beyond, b.y))
        path.addLine(to: at(b.s, b.y))
        Self.curve(&path, from: b, to: Departure(s: mb, y: 0, ds: -1, dy: 0), at: place)
        path.closeSubpath()
        return path
    }
}
