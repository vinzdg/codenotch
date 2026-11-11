import SwiftUI

/// The settings control, below the notch.
///
/// At rest it is a single arc — a segment of a circle's edge, tucked into the
/// corner the notch's bottom flare makes. On hover that same circle fills in and
/// takes a gear. The two states are the same circle, which is what makes the
/// change read as one object waking up rather than as one thing being swapped
/// for another.
///
/// It is a bare arc at rest because the notch is meant to be glanceable: a
/// permanently visible gear is a second thing competing with the readings, and
/// the readings are the point. An arc says "there is something here" without
/// asserting anything.
struct SettingsOrb: View {
    let isHovered: Bool
    var edge: NotchEdge = .right
    /// True when the arc traces the bar's own rounded corner from outside
    /// rather than a flare from inside — a flush bar has no flare to tuck into.
    var convex: Bool = false
    /// The circle the resting arc follows.
    var arcRadius: CGFloat = NotchLayout.orbArcRadius
    /// How far the arc sits from the button. Zero inside a flare's pocket,
    /// where the two are the same object; back onto the corner when the button
    /// has had to move clear of the bar.
    var arcOffset: CGSize = .zero
    /// How many times the gear has been asked to turn. See
    /// `NotchViewModel.settingsSpins`.
    var spins: Int = 0
    /// Hung off the *leading* end of the stack rather than its trailing one —
    /// the notch merged on the left of the Mac's, whose outer end is its
    /// leading one. The arc is reflected along the stack to face that end's
    /// flare: left facing the trailing way, it curled away from the notch and
    /// hung in the wallpaper.
    var reversed: Bool = false
    /// How far the resting arc has come away from the notch's flare, 0 to 1 —
    /// see `GooArc`.
    var separation: CGFloat = 1
    /// Going back into the notch — see `GooArc.returning`.
    var returning: Bool = false
    /// With the notch folding away as it goes — see `GooArc.quick`.
    var quick: Bool = false
    /// **A red dot**: a newer version is waiting — see `Updater.pending`.
    var badge: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// **Hovered out, the button turns back into its arc** — `DiscToArc`, 0
    /// the button and 1 the arc — rather than the two crossfading, the disc
    /// swelling as it went, which read as one thing swapped for another.
    /// Hovered in stays as it was: the arc filling into the button.
    @State private var release: CGFloat = 1
    @State private var releasing = false
    /// Hovered out as the notch folds, so the arcs are going home: the button
    /// goes back into the notch rather than turning into an arc that is on
    /// its way in already.
    @State private var releaseHome = false

    /// Which quarter of the circle the resting arc occupies.
    ///
    /// The arc has to parallel the flare at the far end of the notch, so it
    /// faces two ways at once: **back along the stack**, toward the notch it
    /// hangs off, and **outward**, toward the bezel it is about to merge into.
    /// On the right edge that is twelve o'clock round to three, which is the
    /// arc this was drawn as before there was any choice of edge. Turn the
    /// notch and the same two directions pick a different quadrant.
    ///
    /// SwiftUI's `Circle` trim starts at three o'clock and runs clockwise, with
    /// y growing downward.
    /// Hugging a corner from outside is the same relationship as hugging a
    /// flare from inside, turned through half a circle.
    static func restingTrim(for edge: NotchEdge, convex: Bool) -> ClosedRange<CGFloat> {
        let concave = restingTrim(for: edge)
        guard convex else { return concave }
        let turned = (concave.lowerBound + 0.5).truncatingRemainder(dividingBy: 1)
        return turned...(turned + 0.25)
    }

    static func restingTrim(for edge: NotchEdge) -> ClosedRange<CGFloat> {
        switch edge {
        case .right:  return 0.75...1.0      // up, round to the right
        case .left:   return 0.5...0.75      // left, round to up
        case .top:    return 0.5...0.75      // left, round to up
        case .bottom: return 0.25...0.5      // down, round to the left
        }
    }

    private var restingTrim: ClosedRange<CGFloat> {
        Self.restingTrim(for: edge, convex: convex, reversed: reversed)
    }

    static func restingTrim(for edge: NotchEdge, convex: Bool, reversed: Bool) -> ClosedRange<CGFloat> {
        let trim = restingTrim(for: edge, convex: convex)
        return reversed ? MoveHandle.mirroredAlongStack(trim, isVertical: edge.isVertical) : trim
    }

    static let badgeSize: CGFloat = Design.px(26)
    static let badgeRing: CGFloat = Design.px(4)

    /// Where the red dot sits: on the middle of the resting arc, or — the
    /// button out — on the button's edge the same way round, like an app's
    /// badge.
    private func badgeOffset(hovered: Bool) -> CGSize {
        let at = FlareArc.point(0.5, offset: NotchLayout.orbClearance, flare: arcRadius + NotchLayout.orbGap,
                                centre: .zero, trim: restingTrim, edge: edge)
        guard hovered else { return CGSize(width: at.x + arcOffset.width, height: at.y + arcOffset.height) }
        let reach = max(hypot(at.x, at.y), 0.001)
        let edgeAt = NotchLayout.orbDiameter / 2 * 0.86
        return CGSize(width: at.x / reach * edgeAt, height: at.y / reach * edgeAt)
    }

    /// How long the button takes to turn back into its arc as the pointer
    /// leaves it — which the notch waits for before it folds.
    static let turnsBack: TimeInterval = 0.5

    /// How far the button dips under a click.
    ///
    /// Shallow on purpose. This is a 22pt control tucked against the bezel, and
    /// a deeper press reads as the whole notch flinching rather than as one
    /// button being pushed.
    private static let squeezeScale: CGFloat = 0.84

    @Environment(\.notchSurfaceStyle) private var surfaceStyle
    @Environment(\.codenotchReduceTransparency) private var reduceTransparency

    /// Reduce transparency means "no see-through chrome", which for the orb is
    /// the solid style — the same precedence the Settings window applies to its
    /// own translucent chrome.
    private var glassy: Bool { surfaceStyle.isGlass && !reduceTransparency }

    /// The resting arc, one gap inside the flare — see `FlareArc`.
    ///
    /// On glass the arc is the material itself rather than a stroke of our
    /// paint, so it reads as the same substance as the flare it hugs instead of
    /// a line drawn beside it.
    @ViewBuilder
    private var restingArc: some View {
        if glassy {
            // `isGlass` is only ever true where `glassEffect` exists; the
            // availability check is what tells the compiler so.
            if #available(macOS 26.0, *) {
                Color.clear
                    .frame(width: 100, height: 100)
                    .glassEffect(surfaceStyle.glass, in: Rectangle())
                    .background { if let dim = surfaceStyle.glassDim { Rectangle().fill(dim) } }
                    // The band's own inset cancels the extra stroke width here,
                    // so this is the same circle the stroked arc follows.
                    .frame(width: arcRadius * 2 + NotchLayout.orbStroke,
                           height: arcRadius * 2 + NotchLayout.orbStroke)
                    // Cut to the arc as it divides off the flare, as the solid
                    // style draws it — see `GooArc`.
                    .mask {
                        GooArc(trim: restingTrim, edge: edge, convex: convex,
                               radius: arcRadius, separation: separation, returning: returning, quick: quick)
                    }
            }
        } else {
            GooArc(trim: restingTrim, edge: edge, convex: convex,
                   radius: arcRadius, separation: separation, returning: returning, quick: quick)
        }
    }

    /// The filled disc the arc becomes on hover. It is the one thing here you
    /// press, so its glass is `interactive` and reacts to the pointer.
    @ViewBuilder
    private var hoverDisc: some View {
        if glassy {
            if #available(macOS 26.0, *) {
                Color.clear
                    .frame(width: 100, height: 100)
                    .glassEffect(surfaceStyle.glass.interactive(), in: Rectangle())
                    .background { if let dim = surfaceStyle.glassDim { Rectangle().fill(dim) } }
                    .frame(width: NotchLayout.orbDiameter, height: NotchLayout.orbDiameter)
                    .clipShape(Circle())
            }
        } else {
            Circle()
                .fill(Palette.notch)
                .frame(width: NotchLayout.orbDiameter, height: NotchLayout.orbDiameter)
        }
    }

    var body: some View {
        ZStack {
            restingArc
                .opacity(isHovered || releasing ? 0 : 1)
                .scaleEffect(isHovered ? 0.86 : 1)
                .offset(arcOffset)

            hoverDisc
                .opacity(isHovered ? 1 : 0)
                .scaleEffect(isHovered ? 1 : 1.1)
                .opacity(releasing ? 0 : 1)

            if releasing, !glassy {
                if releaseHome {
                    // Going home with the notch folding: into the notch as goo.
                    DiscMerge(merge: release, trim: restingTrim, edge: edge, radius: arcRadius)
                } else {
                    DiscToArc(progress: release, trim: restingTrim, edge: edge, radius: arcRadius)
                }
            }

            Image(systemName: "gearshape.fill")
                .font(.system(size: NotchLayout.orbGlyph, weight: .regular))
                .foregroundStyle(Palette.textPrimary)
                .opacity(isHovered ? 1 : 0)
                .scaleEffect(isHovered ? 1 : 0.5)
                // Two rotations on one glyph: the wake-up from the hover
                // state, and a full turn per click. Summed rather than
                // applied separately so a click mid-hover does not fight the
                // -60 the gear is still arriving from.
                .rotationEffect(.degrees((isHovered ? 0 : -60) + Double(spins) * 360))
                .animation(NotchMotion.respectingReduceMotion(.spring(response: 0.55,
                                                                      dampingFraction: 0.72),
                                                              reduceMotion),
                           value: spins)
        }
        .onChange(of: isHovered) { _, hovered in
            guard !glassy, !convex, !reduceMotion else { return }
            if hovered {
                releasing = false
                return
            }
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                release = 0
                releasing = true
                releaseHome = separation < 0.5
            }
            // A beat late, so the dots beside it have run back into it while
            // it is still the button there to take them.
            withAnimation(.timingCurve(0.3, 0, 0.2, 1, duration: releaseHome ? 0.34 : 0.4)
                            .delay(releaseHome ? 0 : 0.1)) {
                release = 1
            } completion: {
                if !isHovered { releasing = false }
            }
        }
        // A newer version waiting: a red dot on the middle of the arc, which
        // is the edge of the button too — there hovered or not.
        .overlay {
            if badge, !convex {
                Circle()
                    .fill(Palette.critical)
                    .overlay(Circle().strokeBorder(Palette.notch, lineWidth: Self.badgeRing))
                    .frame(width: Self.badgeSize, height: Self.badgeSize)
                    .offset(badgeOffset(hovered: isHovered))
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: badge)
        // Sized to the larger of the two states, and never clipped: the arc
        // may sit well outside this frame when it has stayed back on the
        // corner the button hangs from.
        .frame(width: arcRadius * 2 + NotchLayout.orbStroke,
               height: arcRadius * 2 + NotchLayout.orbStroke)
        .animation(
            NotchMotion.respectingReduceMotion(
                .spring(response: 0.36, dampingFraction: 0.7), reduceMotion
            ),
            value: isHovered
        )
        // The press, on the same counter as the turn. A click reaches this
        // view as one event — the panel's own hit test and the SwiftUI
        // gesture both bump `spins`, and neither reports mouse-down and
        // mouse-up separately — so the dip and the release are keyframed off
        // that single tick rather than tracked from a press state that does
        // not exist here.
        //
        // Down fast and back slower: a press is sharp, a release settles.
        .keyframeAnimator(initialValue: CGFloat(1), trigger: spins) { orb, scale in
            orb.scaleEffect(scale)
        } keyframes: { _ in
            SpringKeyframe(reduceMotion ? 1 : Self.squeezeScale,
                           duration: 0.09, spring: .snappy)
            SpringKeyframe(1, duration: 0.34, spring: .bouncy)
        }
    }
}

/// A segment of a circle's edge as a filled shape rather than a stroke.
///
/// Glass takes a shape, not a `ShapeStyle`, so the resting arc has to be an
/// area before it can be made of the material. The circle is inset by half the
/// line width because the glass is masked by this path *within the view's
/// bounds*: run the band along the frame's edge and the outer half of every
/// stroke is cut away.
struct ArcBand: Shape {
    let trim: ClosedRange<CGFloat>
    let lineWidth: CGFloat
    var edge: NotchEdge = .top
    var convex: Bool = false

    func path(in rect: CGRect) -> Path {
        FlareArc(trim: trim, edge: edge, convex: convex)
            .path(in: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
            .strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }
}

/// **The resting arc: the notch's own flare, one gap out from it.**
///
/// The flare is not a circle. It is `SideNotchShape.fluidTurn`, whose bend
/// ramps in from nothing at the bezel and back out to nothing at the side, so
/// it is flatter than a circle at both ends and tighter in the middle — and a
/// quarter circle drawn beside it ran close to it in one place and away from it
/// in another, reading as a separate hook rather than the flare's echo. This is
/// the flare's own curve pushed one `orbGap` into the pocket it makes, so the
/// two run parallel all the way round.
///
/// Drawn in the circle's own square — the rect the old circle filled, its
/// radius the flare's less the gap — and occupying the quadrant `trim` names,
/// as that circle's trim did. Hugging a corner from outside (`convex`) is still
/// a true circle: that corner is one.
struct FlareArc: Shape {
    let trim: ClosedRange<CGFloat>
    var edge: NotchEdge = .top
    var convex: Bool = false
    var gap: CGFloat = NotchLayout.orbGap

    func path(in rect: CGRect) -> Path {
        guard !convex else {
            return Circle().trim(from: trim.lowerBound, to: trim.upperBound).path(in: rect)
        }
        let radius = min(rect.width, rect.height) / 2
        let flare = radius + gap
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let (bezel, side) = Self.ends(of: trim, on: edge)
        var path = Path()
        for (index, step) in GooNeck.flareWalk.enumerated() {
            // Along the flare from where it meets the bezel …
            let x = centre.x + flare * (1 - step.v) * bezel.x + flare * step.u * side.x
            let y = centre.y + flare * (1 - step.v) * bezel.y + flare * step.u * side.y
            // … and out of the bar by the gap, square to the flare there.
            let nx = -sin(step.heading) * side.x - cos(step.heading) * bezel.x
            let ny = -sin(step.heading) * side.y - cos(step.heading) * bezel.y
            let point = CGPoint(x: x + nx * gap, y: y + ny * gap)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    /// The quadrant's two ends: toward the bezel, where the flare meets it,
    /// and toward the side the flare turns down into.
    static func ends(of trim: ClosedRange<CGFloat>, on edge: NotchEdge) -> (bezel: CGPoint, side: CGPoint) {
        func direction(_ t: CGFloat) -> CGPoint {
            let angle = 2 * .pi * t
            return CGPoint(x: cos(angle), y: sin(angle))
        }
        let a = direction(trim.lowerBound), b = direction(trim.upperBound)
        let out = edge.outward
        return a.x * out.x + a.y * out.y >= b.x * out.x + b.y * out.y ? (a, b) : (b, a)
    }

    /// The point `share` of the way round the flare — 0 at the bezel, 1 at the
    /// side — `offset` out from it into the pocket, for a flare of radius
    /// `flare` round `centre`.
    static func point(_ share: CGFloat, offset: CGFloat, flare: CGFloat, centre: CGPoint,
                      trim: ClosedRange<CGFloat>, edge: NotchEdge) -> CGPoint {
        let (bezel, side) = ends(of: trim, on: edge)
        let walk = GooNeck.flareWalk
        let step = walk[min(walk.count - 1, max(0, Int((share * CGFloat(walk.count - 1)).rounded())))]
        let x = centre.x + flare * (1 - step.v) * bezel.x + flare * step.u * side.x
        let y = centre.y + flare * (1 - step.v) * bezel.y + flare * step.u * side.y
        let nx = -sin(step.heading) * side.x - cos(step.heading) * bezel.x
        let ny = -sin(step.heading) * side.y - cos(step.heading) * bezel.y
        return CGPoint(x: x + nx * offset, y: y + ny * offset)
    }
}

/// **The resting arc, dividing off the notch like goo.**
///
/// At `separation` 0 it lies on the notch's own flare, part of the same black;
/// going to 1 it comes away to its place one gap out. Between, the two are
/// blurred together and cut back at half strength, so the arc does not simply
/// appear beside the notch: it swells out of the flare, draws a neck between
/// them as it leaves, and the neck thins and parts — a drop dividing from the
/// body it came out of. Drawn with the notch's own flare along its inside
/// edge, just within the notch where nothing of it shows on its own, for the
/// arc to divide from. Away from the flare it is simply the arc.
struct GooArc: View, Animatable {
    let trim: ClosedRange<CGFloat>
    let edge: NotchEdge
    let convex: Bool
    /// The arc's radius at rest, one gap in from the flare's.
    let radius: CGFloat
    var separation: CGFloat
    /// Going back into the notch rather than coming out: straight home, with
    /// none of the pull out past its place that draws the neck long coming out.
    var returning: Bool = false
    /// Going back in with the notch already folding away: no goo and no neck,
    /// only the arc rolling up and slipping in. What it would merge with is
    /// drawn inside the notch, and a notch folding at the same time left that
    /// standing on the wallpaper as a great black shape.
    var quick: Bool = false

    var animatableData: CGFloat {
        get { separation }
        set { separation = newValue }
    }

    private var gap: CGFloat { NotchLayout.orbGap }
    private var stroke: CGFloat { NotchLayout.orbStroke }
    /// How far the goo reaches: strong while the arc is in and on the flare,
    /// so the two are one body and pull a neck between them as they part, and
    /// gone by the time the arc is at its place — so it arrives at its own
    /// thickness, with no last change of shape.
    private var goo: CGFloat {
        if returning && quick { return 0 }
        if returning {
            // Off while the arc rolls up, so it rolls up clean; on once it is a
            // drop, for the neck reaching out to it to be round and melt in.
            // Softer still as it comes home, so drop and flare run together as
            // one mound that sinks away, not two bumps side by side.
            let home = 1 + 0.8 * (1 - Self.step((separation - 0.04) / 0.32))
            return stroke * 0.45 * home * Self.step((0.93 - separation) / 0.15)
                * Self.step(separation / 0.05)
        }
        // Held at full strength for the first half, so the drop stays joined to
        // the notch by a neck that pulls out long before it lets go, then
        // easing away to nothing as the arc comes to its place.
        // And grown from nothing as it starts, so the flare swells out of its
        // own shape rather than changing shape the moment the arc is shown.
        func step(_ x: CGFloat) -> CGFloat {
            let t = min(max(x, 0), 1)
            return t * t * (3 - 2 * t)
        }
        // Light: enough to round where the neck meets the flare and the arc,
        // not so much it eats the arc's thin ends and shortens it.
        return stroke * 0.4 * step(separation / 0.15) * (1 - step((separation - 0.6) / 0.35))
    }

    /// How far out from the flare the arc is: at 0 buried in the notch, a
    /// stroke and more inside its edge where nothing of it shows; at 1 at its
    /// place. So opening it is pushed out through the flare — the edge swells,
    /// a neck draws, and it parts — rather than turning up beside it.
    /// How far the arc has slid from its place, straight out of the flare's
    /// pocket and back along the middle of the turn — its own shape and size
    /// the whole way, so the only thing drawn out is the neck. Buried in the
    /// notch at 0; past its place on the way, pulling the neck long; back at
    /// its place at 1.
    private var slide: CGFloat {
        let rest = NotchLayout.orbClearance
        let buried = -(rest + stroke * 1.4)
        let t = min(max(separation, 0), 1)
        if returning && quick { return 0 }
        if returning {
            // Going back in: the way it came out, run backwards — rolled up,
            // stepping out a little past its place, clear of the flare, while
            // the neck reaches out to it, then drawn home along it. Pressed
            // against the flare instead, it left sharp creases either side.
            let past = rest * 1.2 * sin(.pi * min(t / 0.85, 1)) * (t < 0.85 ? 1 : 0)
            return buried * (1 - t) + past
        }
        let reach = rest * 2.1 * sin(.pi * min(t / 0.8, 1)) * (t < 0.8 ? 1 : 0)
        return buried * (1 - separation) + reach
    }

    static func step(_ x: CGFloat) -> CGFloat {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// How far out of the flare the arc's middle is, for the neck.
    private var out: CGFloat { NotchLayout.orbClearance + slide }

    /// **A drop first, then the arc.** How much of the arc is drawn, round its
    /// middle, and how thick: none of it and a drop's width while it is being
    /// pushed out and drawn away on the neck — a ball, the arc's own middle
    /// with its round ends meeting — then, once the neck has let go, unrolling
    /// from the middle out to the whole arc and thinning to a line as it does.
    private var unrolled: CGFloat {
        // Going back in, it rolls up before it moves.
        // Going back in, it rolls up before it moves — held by the neck all
        // the while, never a loose drop. With the notch folding it draws in
        // from both ends as a thinning line instead, and never becomes a dot.
        if returning && quick { return Self.step((separation - 0.05) / 0.9) }
        if returning { return Self.step((separation - 0.6) / 0.35) }
        let t = min(max((separation - 0.52) / 0.43, 0), 1)
        return t * t * (3 - 2 * t)
    }
    private var dropWidth: CGFloat { stroke * 2.3 }

    /// **How far the neck has reached**, from the flare toward the drop, 0 to
    /// 1. Coming out it is always all the way: it is the drop pulling away.
    /// Going back in it grows out of the notch across the whole gap to catch
    /// the drop where it waits, and only then draws it home.
    private var reach: CGFloat {
        returning ? Self.step((0.92 - separation) / 0.32) : 1
    }

    /// **The neck**: a strand from the middle of the flare to the middle of the
    /// arc, wide where it leaves the one and meets the other and thinning in
    /// its middle as the arc pulls away — honey drawn out — until it lets go,
    /// near the arc's furthest. Its width at the middle.
    private var neck: CGFloat {
        if returning {
            // Out from the notch early, while the drop is still out where the
            // arc was, and held on to until it is home.
            return quick ? 0 : stroke * 1.1 * Self.step((0.94 - separation) / 0.1)
        }
        let t = min(max((separation - 0.2) / 0.5, 0), 1)
        return stroke * 1.1 * (1 - t * t * (3 - 2 * t))
    }

    var body: some View {
        let flare = radius + gap
        let side = 2 * (flare + 2 * stroke)
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            func square(_ r: CGFloat) -> CGRect {
                CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)
            }
            let out = self.out
            let rest = NotchLayout.orbClearance
            // Pocketward at the middle of the turn: the way the arc slides.
            let (bezel, side) = FlareArc.ends(of: trim, on: edge)
            let away = CGPoint(x: -(bezel.x + side.x) / sqrt(2), y: -(bezel.y + side.y) / sqrt(2))
            let whole = FlareArc(trim: trim, edge: edge, convex: convex, gap: rest)
                .path(in: square(flare - rest))
                .offsetBy(dx: away.x * slide, dy: away.y * slide)
            // The drop is the arc's middle, a hair of it, drawn at its width.
            let half = max(0.004, unrolled / 2)
            let arc = unrolled >= 0.999 ? whole : whole.trimmedPath(from: 0.5 - half, to: 0.5 + half)
            var width = dropWidth + (stroke - dropWidth) * unrolled
            // With the notch folding away there is nothing for it to merge
            // with: it dwindles to nothing going in, and leaves no dot behind.
            // It rolls up and dwindles where it is, gone before the notch is.
            if returning && quick { width = stroke * Self.step(separation / 0.7) }
            // Smaller as it comes home, so it melts into the flare rather
            // than standing on it as a shelf.
            if returning && !quick { width *= Self.step(separation / 0.35) }
            if width < 0.4 { return }
            let style = StrokeStyle(lineWidth: width, lineCap: .round)
            guard goo > 0.2, !convex else {
                context.stroke(arc, with: .color(Palette.notch), style: style)
                return
            }
            context.addFilter(.alphaThreshold(min: 0.5, color: Palette.notch))
            context.addFilter(.blur(radius: goo))
            // Fuller in the goo, which eats back into a thin line — and a drop
            // is fat before it settles to a line.
            let fuller = StrokeStyle(lineWidth: width + goo * 0.4, lineCap: .round)
            context.drawLayer { layer in
                layer.stroke(arc, with: .color(.black), style: fuller)
                // The neck, from inside the flare out to the arc, while it holds.
                if neck > stroke * 0.18 {
                    let from = FlareArc.point(0.5, offset: -stroke, flare: flare,
                                              centre: centre, trim: trim, edge: edge)
                    let drop = FlareArc.point(0.5, offset: out, flare: flare,
                                              centre: centre, trim: trim, edge: edge)
                    let to = CGPoint(x: from.x + (drop.x - from.x) * reach,
                                     y: from.y + (drop.y - from.y) * reach)
                    let dx = to.x - from.x, dy = to.y - from.y
                    let length = max(hypot(dx, dy), 0.001)
                    // Square to the strand.
                    let px = -dy / length, py = dx / length
                    func side(_ at: CGPoint, _ half: CGFloat, _ sign: CGFloat) -> CGPoint {
                        CGPoint(x: at.x + px * half * sign, y: at.y + py * half * sign)
                    }
                    let middle = CGPoint(x: from.x + dx * 0.5, y: from.y + dy * 0.5)
                    // Wide where it leaves the notch, drawn out of the black;
                    // pinched in its middle; filling out again into the arc.
                    let base = stroke * 2.6 / 2, pinch = neck / 2, top = stroke * 1.4 / 2
                    var strand = Path()
                    strand.move(to: side(from, base, 1))
                    strand.addQuadCurve(to: side(to, top, 1), control: side(middle, pinch, 1))
                    strand.addLine(to: side(to, top, -1))
                    strand.addQuadCurve(to: side(from, base, -1), control: side(middle, pinch, -1))
                    strand.closeSubpath()
                    layer.fill(strand, with: .color(.black))
                }
                // The flare's edge, just inside the notch: its outer edge on the
                // flare exactly, and thick enough that the goo does not eat it
                // away — thinner, it was, and the arc had nothing to part from.
                let band = stroke + goo * 1.6
                let within = -band / 2
                let body = FlareArc(trim: trim, edge: edge, convex: convex, gap: within)
                    .path(in: square(flare - within))
                layer.stroke(body, with: .color(.black),
                             style: StrokeStyle(lineWidth: band, lineCap: .round))
            }
        }
        .frame(width: side, height: side)
        .frame(width: radius * 2, height: radius * 2)
        .allowsHitTesting(false)
    }
}

/// **The settings button going back into the notch like goo**, as the notch
/// is picked up by its dots.
///
/// The button is drawn here as one liquid with the flare it hangs in: a neck
/// swells out of the flare to it, and it is drawn along the neck into the
/// notch, shrinking as it goes, until it is inside the black and gone.
/// Faded or scaled away instead, it left in two movements at once — turning
/// back into its arc and shrinking — which is what read as a glitch.
struct DiscMerge: View, Animatable {
    /// 0 the button where it is, 1 inside the notch.
    var merge: CGFloat
    let trim: ClosedRange<CGFloat>
    let edge: NotchEdge
    /// The resting arc's radius — the flare is one gap outside it.
    let radius: CGFloat

    var animatableData: CGFloat {
        get { merge }
        set { merge = newValue }
    }

    private static func step(_ x: CGFloat) -> CGFloat { GooArc.step(x) }

    var body: some View {
        let stroke = NotchLayout.orbStroke
        let flare = radius + NotchLayout.orbGap
        let side = 2 * (flare + 2 * stroke)
        let disc = NotchLayout.orbDiameter / 2
        let t = min(max(merge, 0), 1)
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            func square(_ r: CGFloat) -> CGRect {
                CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            }
            func point(_ offset: CGFloat) -> CGPoint {
                FlareArc.point(0.5, offset: offset, flare: flare, centre: c, trim: trim, edge: edge)
            }
            // Goo from nothing, so the first frame is the button exactly.
            let goo = 5 * Self.step(t / 0.2)
            if goo > 0.3 {
                context.addFilter(.alphaThreshold(min: 0.5, color: Palette.notch))
                context.addFilter(.blur(radius: goo))
            }
            let ink: Color = goo > 0.3 ? .black : Palette.notch
            context.drawLayer { layer in
                // Where the button is: drawn in along the middle of the flare
                // to inside the notch, and smaller as it goes.
                let inside = point(-disc * 0.75)
                let travel = Self.step(t)
                let at = CGPoint(x: c.x + (inside.x - c.x) * travel, y: c.y + (inside.y - c.y) * travel)
                let r = disc * (1 - 0.72 * Self.step((t - 0.2) / 0.8))
                layer.fill(Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(ink))
                guard goo > 0.3 else { return }
                // The flare's edge, just inside the notch, for the neck to
                // swell out of and the button to run into.
                let band = stroke * 2.4
                let within = -band / 2
                let body = FlareArc(trim: trim, edge: edge, convex: false, gap: within)
                    .path(in: square(flare - within))
                layer.stroke(body, with: .color(.black),
                             style: StrokeStyle(lineWidth: band, lineCap: .round))
                // The neck, from inside the flare out to the button, swelling
                // as it takes hold of it.
                let hold = Self.step(t / 0.22)
                guard hold > 0.02 else { return }
                let from = point(-stroke)
                let dx = at.x - from.x, dy = at.y - from.y
                let length = max(hypot(dx, dy), 0.001)
                let px = -dy / length, py = dx / length
                func edgePoint(_ p: CGPoint, _ half: CGFloat, _ sign: CGFloat) -> CGPoint {
                    CGPoint(x: p.x + px * half * sign, y: p.y + py * half * sign)
                }
                let middle = CGPoint(x: from.x + dx / 2, y: from.y + dy / 2)
                let base = disc * 1.1 * hold / 2, pinch = r * 0.8 * hold / 2, top = r * 1.2 * hold / 2
                var neck = Path()
                neck.move(to: edgePoint(from, base, 1))
                neck.addQuadCurve(to: edgePoint(at, top, 1), control: edgePoint(middle, pinch, 1))
                neck.addLine(to: edgePoint(at, top, -1))
                neck.addQuadCurve(to: edgePoint(from, base, -1), control: edgePoint(middle, pinch, -1))
                neck.closeSubpath()
                layer.fill(neck, with: .color(.black))
            }
        }
        .frame(width: side, height: side)
        .frame(width: radius * 2, height: radius * 2)
        .allowsHitTesting(false)
    }
}

/// **The settings button turning back into its arc**, as the pointer leaves
/// it: the disc flows out along the arc from its middle, thinning as it goes,
/// until it is the arc — the way the arc filled into it, backwards. Hollowed
/// into a ring and opened out instead, it went through a doughnut and a C on
/// the way, and never read as the button becoming the line.
struct DiscToArc: View, Animatable {
    /// 0 the button, 1 the arc.
    var progress: CGFloat
    let trim: ClosedRange<CGFloat>
    let edge: NotchEdge
    /// The resting arc's radius — see `SettingsOrb.arcRadius`.
    let radius: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let p = min(max(progress, 0), 1)
        let stroke = NotchLayout.orbStroke
        let disc = NotchLayout.orbDiameter / 2
        let side = radius * 2 + stroke
        // It ends on the arc's own curve at the arc's own width — exactly what
        // is left when it hands back to the resting arc — so there is nothing
        // to fade between the two.
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let flare = radius + NotchLayout.orbGap
            let mid = FlareArc.point(0.5, offset: NotchLayout.orbClearance, flare: flare,
                                     centre: c, trim: trim, edge: edge)
            // From the button's middle onto the arc's.
            let onto = GooArc.step(p / 0.55)
            let shift = CGPoint(x: (c.x - mid.x) * (1 - onto), y: (c.y - mid.y) * (1 - onto))
            // Along the arc from its middle, out to both its ends.
            let half = 0.5 * GooArc.step((p - 0.08) / 0.82)
            // From the button's whole width — a round-ended line that short
            // is the disc — down to the arc's.
            let width = 2 * disc + (stroke - 2 * disc) * GooArc.step(p / 0.8)
            var line = Path()
            let steps = 64
            for i in 0...steps {
                let share = 0.5 - half + 2 * half * CGFloat(i) / CGFloat(steps)
                let q = FlareArc.point(share, offset: NotchLayout.orbClearance, flare: flare,
                                       centre: c, trim: trim, edge: edge)
                let at = CGPoint(x: q.x + shift.x, y: q.y + shift.y)
                if i == 0 { line.move(to: at) } else { line.addLine(to: at) }
            }
            context.stroke(line, with: .color(Palette.notch),
                           style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
        .frame(width: side, height: side)
        .allowsHitTesting(false)
    }
}
