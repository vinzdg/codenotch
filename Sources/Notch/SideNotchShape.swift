import SwiftUI

/// The notch body: a pill welded to one edge of the screen, with *inverse*
/// rounded corners at each end that flare back out to the edge so it reads as
/// part of the bezel rather than a floating panel.
///
/// The path is only ever written once, for the right edge, and then transformed
/// onto whichever edge it is actually on. Writing four variants would mean four
/// copies of the corner-versus-flare clamping below, which is the one piece of
/// this that took real work to get right — and three of the copies would never
/// be the one under the cursor when it broke.
///
/// In canonical form `rect` is the whole shape including the flares; the
/// straight body runs from `rect.minY + curlRadius` to `rect.maxY - curlRadius`,
/// and `rect.maxX` is the screen edge.
struct SideNotchShape: Shape {
    var edge: NotchEdge = .right
    /// **The display's own hole, when this notch is close enough to flow into
    /// it.** Nil on every other edge and every other display.
    ///
    /// Set, the leading end stops being an end. Instead of tapering back to the
    /// bezel with a flare, the shape starts at the hole's own depth, runs
    /// straight to the hole's wall, and *steps* from there onto its own far
    /// side — so what the eye is given is one black silhouette with a waist in
    /// it rather than two shapes that happen to touch.
    struct Cutout: Equatable {
        /// How deep the hole is, in this shape's own space.
        var depth: CGFloat

        /// Where the hole's trailing wall stands, measured along from the
        /// shape's leading tip. Negative when the notch has been nudged clear
        /// and the bridge has to reach back along the bezel for it.
        var wall: CGFloat

        /// How far along the bridge takes to settle onto the body's far side.
        ///
        /// The whole depth difference is spent in this distance, so it sets how
        /// steep the join is. A flare's worth keeps the first ring clear of it,
        /// which is the same bargain the flare it replaces was struck for.
        var run: CGFloat
    }
    var cutout: Cutout?

    /// **How far the leading end has become the joined one**, 0 to 1.
    ///
    /// At 0 it is the notch's own end, flare and corner. At 1 it is square: the
    /// flare and the corner have closed up to nothing, and the end runs straight
    /// down from the bezel — which, at the hole's own depth, is exactly the
    /// joined end, with nothing to step and the tip inside the hole.
    ///
    /// A number, because a swap cannot be eased. Joining used to replace the
    /// flared end with the joined one in a single frame — and that end is not
    /// all inside the hole, so the flare visibly vanished. As a number the flare
    /// is drawn *into* the corner of the hole on the same spring as everything
    /// else, which is the fold's own kind of movement.
    var leadingJoin: CGFloat = 0

    /// **How far the trailing end has closed up square**, 0 to 1 — the trailing
    /// counterpart of `leadingJoin`, flare and corner both. Used for an end of
    /// a dragged bar that has gone into the hole, which has to fill the hole's
    /// rounded corner rather than leave a wedge of wallpaper in it.
    var trailingJoin: CGFloat = 0

    /// **How much of the flare the far end keeps**, 0 to 1. At 0 the far end
    /// meets the bezel square, straight up from its corner, which is how the
    /// display's own notch ends — used for the hardware's notch widening, as
    /// opposed to the bar that grows out of it.
    var trailingFlare: CGFloat = 1

    /// **Where the bar dips to pass through the display's hole**, while it is
    /// in the hand. Nil everywhere else.
    ///
    /// Goo through a gap narrower than itself squeezes into it and keeps its own
    /// size either side. So along the stretch of the bar that is under the
    /// hole, the bar is no deeper than the hole; out past a wall the bar reaches
    /// across, it eases back to its own depth on the smoother step; and its
    /// corners and flares are drawn *on* that edge, wherever they fall. It is
    /// the bar's own outline, not a cut through it: cutting the bar with a mask
    /// left a point wherever the cut crossed the bar's own curved end, and the
    /// points slid along with the pointer.
    struct Dip: Equatable {
        /// Along the bar, in its own measure from its leading tip: the hole's
        /// near wall and its far one.
        var from: CGFloat
        var to: CGFloat
        /// How deep the hole is, in the shape's own measure.
        var depth: CGFloat
        /// How far out past a wall the bar takes to ease back to its own depth.
        var reach: CGFloat
        /// Whether it eases out before the near wall and after the far one —
        /// only where the bar reaches across that wall.
        var easesBefore: Bool
        var easesAfter: Bool
        /// The hole's own corner radius, in the shape's measure.
        ///
        /// An end of the bar that is inside the hole follows the hole's rounded
        /// corner rather than filling it square, and an end coming out past a
        /// wall comes out wearing the hole's outline — a straight wall and this
        /// corner — putting on its own flare and corner only as there is room
        /// for them outside. Square, or out with its own rounder corner on, it
        /// cut across the Mac's corner and left it looking as if it had none.
        var corner: CGFloat = 0
        /// How much of the dip there is, 0 to 1: none while the bar is not
        /// over the hole at all, all of it while it is.
        ///
        /// A dip is always there when the bar is beside the hole, and this is
        /// what changes, because a dip that comes and goes cannot be animated.
        /// Letting go switched it off in one frame while the bar was still
        /// deeper than the hole — its end already square, hanging below the
        /// hole with a sharp corner beside it — and a glide onto the wall slid
        /// the bar under a dip already drawn where it would end up.
        var amount: CGFloat = 1
        /// How far in past a wall an end of the bar goes before it has closed
        /// up square — the joined overlap, in the shape's measure.
        ///
        /// An end the bar reaches in past a wall with closes up by how far in
        /// it is, worked out where it is drawn: as it goes in, and only as it
        /// goes in, however the movement that takes it there is animated.
        /// Closing up as a number eased from one state to the next, it closed
        /// up outside the hole whenever the two states were further apart than
        /// the wall, and the landing had to stop at the wall to avoid it — two
        /// movements, with a halt between them.
        var closes: CGFloat = 0
    }
    var dip: Dip?

    /// Whether this copy is drawn turned round along the bar — the copy on the
    /// left of the hole, whose joined end is its trailing one. A path has no
    /// in-between to animate through, and a copy's side is never changed while
    /// it is anything but symmetric.
    var reflected = false

    /// **For the copy that widens the Mac's notch: how it comes out of the
    /// hole.** `buried` is how far its joined end sits inside the hole, and
    /// `corner` the hole's own corner radius, both in the shape's measure.
    ///
    /// Its far end comes out of the hole wearing the hole's own outline — a
    /// straight wall and the Mac's corner — and puts on the notch's own curve
    /// only as there is room for it outside: the flare at half the pace it
    /// comes out, the corner no faster than it clears the hole's. Coming out
    /// with its own end already on, its rounder corner cut across the Mac's
    /// and its flare across the hole's wall, and for a moment the Mac's notch
    /// looked like it had lost its corner. Worked out from the length it is
    /// drawn at, so it keeps pace with the length however that animates.
    struct Emergence: Equatable {
        var buried: CGFloat
        var corner: CGFloat
    }
    var emergesFrom: Emergence?
    var curlRadius: CGFloat = NotchLayout.curlRadius
    var cornerRadius: CGFloat = NotchLayout.cornerRadius
    /// The inverse curve where the shape meets the bezel, when the caller wants
    /// one of its own. Nil takes the fixed `bezelFillet` a joined shape used to
    /// get unconditionally — right when the bar *was* the hardware, too abrupt
    /// once it extends past it as ears that have to flow into the screen edge.
    var filletRadius: CGFloat?

    /// How much *depth* that sweep uses, when it is not the same as how far it
    /// runs along the bar. Nil keeps them equal, which is a circular arc.
    ///
    /// They are separate because the two are bounded by different things. The
    /// depth is all the ear has — 38pt beside the hardware, shared with the
    /// corner at its foot — while the length is not scarce at all. Holding the
    /// depth and stretching the length flattens the sweep, which is the only
    /// way left to make it gentler once it already reaches the corner.
    var filletDepth: CGFloat?

    /// How much of the sweep is spent ramping its bend in and out — see
    /// `fluidTurn`. 0 is a plain arc; 0.5 never holds a constant bend at all.
    var filletRamp: CGFloat = 0.5

    /// The band of depth at the bezel that nobody can see.
    ///
    /// The shape is pushed this far *past* the top of the screen so no
    /// wallpaper hairline shows along the bezel. Anything curved up there is
    /// spent where it cannot be seen, and what reaches the screen is a curve
    /// already part way through its turn, cut off by the border — the tip ends
    /// up over the edge rather than on it. So the band is kept straight and
    /// the sweep starts at the first row that is actually on screen.
    var bezelHidden: CGFloat = 0
    /// **What morphs when the notch folds.**
    ///
    /// Without this the shape is rebuilt from scratch on the frame that the
    /// fold begins: the rect it is drawn into animates, but the numbers it is
    /// drawn *from* do not. Beside the hardware the sweep into the border goes
    /// from nothing to its full depth the instant `isExpanded` flips, so the
    /// ears arrive with a pop in the middle of an otherwise smooth movement —
    /// which is most of what "it does not feel fluid" is.
    ///
    /// Each of these is a length in the shape's own space, so interpolating
    /// them is exactly the morph you want: the corner opens out, the sweep
    /// grows from the border, and the hidden band keeps pace with both.
    ///
    /// Whether a fillet is `nil` never changes while a shape is on screen — it
    /// follows the placement, not the state — so the optionals are carried
    /// through untouched rather than given a sentinel to interpolate against.
    /// The same goes for `cutout`, whose three numbers describe where the
    /// display's hole is and not what the notch is doing: the morph across it
    /// is the rect's, as the body deepens past the hole and shallows back.
    ///
    /// The dip rides along too — where the hole's walls are along the bar, how
    /// deep it is, and how much of it there is — so it moves with the bar as
    /// the bar glides rather than being drawn where the bar will end up.
    typealias DipData = AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                       AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                                      AnimatablePair<CGFloat, CGFloat>>>
    var animatableData: AnimatablePair<
        AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                       AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                      AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>>>,
        DipData> {
        get {
            let d = dip ?? Dip(from: 0, to: 0, depth: 0, reach: 0,
                               easesBefore: false, easesAfter: false, amount: 0)
            return AnimatablePair(
                AnimatablePair(AnimatablePair(cornerRadius, filletRadius ?? 0),
                               AnimatablePair(AnimatablePair(filletDepth ?? 0, trailingFlare),
                                              AnimatablePair(bezelHidden,
                                                             AnimatablePair(leadingJoin, trailingJoin)))),
                AnimatablePair(AnimatablePair(d.from, d.to),
                               AnimatablePair(AnimatablePair(d.depth, d.reach),
                                              AnimatablePair(d.corner, d.amount))))
        }
        set {
            let shape = newValue.first
            cornerRadius = shape.first.first
            if filletRadius != nil { filletRadius = shape.first.second }
            if filletDepth != nil { filletDepth = shape.second.first.first }
            trailingFlare = shape.second.first.second
            bezelHidden = shape.second.second.first
            leadingJoin = shape.second.second.second.first
            trailingJoin = shape.second.second.second.second
            if dip != nil {
                let d = newValue.second
                dip?.from = d.first.first
                dip?.to = d.first.second
                dip?.depth = d.second.first.first
                dip?.reach = d.second.first.second
                dip?.corner = d.second.second.first
                dip?.amount = d.second.second.second
            }
        }
    }

    func path(in rect: CGRect) -> Path {
        // Canonical space: depth across the shape, length along it. For a side
        // edge that is already width x height; for a horizontal one it is the
        // rect turned on its side. The bezel is at `maxX`.
        let depth = edge.isVertical ? rect.width : rect.height
        let length = edge.isVertical ? rect.height : rect.width
        let canonical = canonicalPath(
            in: CGRect(x: 0, y: 0, width: depth, height: length),
            flare: filletRadius ?? curlRadius,
            flareDepth: filletDepth
        )

        // **The copy on the left of the hole is this shape reflected**, and it
        // is reflected here, in the path, rather than by the view.
        //
        // The view used to do it with `scaleEffect(x: -1)`, and a scale is a
        // number SwiftUI will happily animate: any time a copy's side changed
        // under one identity, the bar turned over through nothing on the way.
        // A path has no in-between to animate through. It is the shape it is,
        // and what it carries is never reflected at all.
        let turned = reflected
            ? canonical.applying(CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                                   tx: 0, ty: length))
            : canonical
        return turned
            .applying(Self.transform(for: edge, depth: depth))
            .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    /// Canonical (`u`, `v`) — `u` across from the far side, `v` along — onto the
    /// rect's own coordinates, with the bezel landing on the right edge.
    ///
    /// Derived rather than eyeballed: in stack space the bezel is always
    /// `across == 0`, so `across = depth - u`, and each edge then places
    /// `(along, across)` the same way `NotchPlacement` does.
    static func transform(for edge: NotchEdge, depth: CGFloat) -> CGAffineTransform {
        switch edge {
        case .right:
            return .identity
        case .left:
            // Mirrored: the flares point the other way.
            return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: depth, ty: 0)
        case .top:
            // Quarter turn, bezel to the top.
            return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: depth)
        case .bottom:
            // Quarter turn the other way, bezel to the bottom.
            return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        }
    }

    /// The handle reach that makes a cubic Bézier trace a circle exactly.
    ///
    /// Every corner here is a circular arc, and two attempts at making them
    /// something cleverer both came back as "stiff". The reason is curvature
    /// at the *joins*, not the shape in the middle. Reach further than this
    /// and the curve holds flat against each straight and turns late — the
    /// squircle. Reach less and it turns early. Either way a single cubic that
    /// matches a target outline ends up with the wrong curvature where it
    /// meets the straight: at reach 0.37 it is three times a circle's, and the
    /// eye reads that jump as a kink however good the outline is.
    ///
    /// A circle has one curvature throughout, so the only jump is the
    /// unavoidable one from the straight line — and that is what Apple's notch
    /// does. Fitted over the whole sweep, its corner is an arc to within a
    /// pixel; the fit prefers it over every ramped or squircled alternative.
    static let circleReach: CGFloat = 0.5523

    /// **A quarter turn whose bend ramps in from nothing at both ends.**
    ///
    /// Where the sweep meets the screen's border, a Bézier arrives at the right
    /// *angle* but with its whole bend already there — curvature goes from none
    /// along the border to all of it in one step, and the eye reads that step
    /// as a stiff join however the outline is shaped. No single cubic can avoid
    /// it: holding curvature at zero at both ends of a quarter turn takes all
    /// four control points, and they are spoken for by the tangents.
    ///
    /// So this is not one: the curve is integrated from its curvature directly,
    /// which rises from zero, holds, and falls back to zero. `ramp` is the
    /// share of the turn spent rising and falling at each end — 0 is a circular
    /// arc, 0.5 ramps the whole way with no constant-curvature middle at all.
    /// The result is walked out as a polyline, fine enough that the facets are
    /// far below a point at any size the notch is drawn.
    private func fluidTurn(_ path: inout Path, to: CGPoint,
                           leaving: CGVector, arriving: CGVector, ramp: CGFloat) {
        guard let from = path.currentPoint else { return }
        let alongReach = (to.x - from.x) * leaving.dx + (to.y - from.y) * leaving.dy
        let acrossReach = (to.x - from.x) * arriving.dx + (to.y - from.y) * arriving.dy
        guard alongReach != 0, acrossReach != 0 else {
            path.addLine(to: to)
            return
        }
        let p = min(max(ramp, 0), 0.5)
        // Curvature times length, set so the turn comes to exactly a quarter.
        let bend = (CGFloat.pi / 2) / (1 - p)
        let steps = 96
        var heading: CGFloat = 0, u: CGFloat = 0, v: CGFloat = 0
        var walk: [(CGFloat, CGFloat)] = [(0, 0)]
        for i in 0..<steps {
            let s = (CGFloat(i) + 0.5) / CGFloat(steps)
            let share = p <= 0 ? 1 : (s < p ? s / p : (s > 1 - p ? (1 - s) / p : 1))
            heading += bend * share / CGFloat(steps)
            u += cos(heading) / CGFloat(steps)
            v += sin(heading) / CGFloat(steps)
            walk.append((u, v))
        }
        // The walk is symmetric, so one scale per axis lands it on `to`.
        let (endU, endV) = walk[walk.count - 1]
        let alongScale = alongReach / endU, acrossScale = acrossReach / endV
        for (wu, wv) in walk.dropFirst() {
            path.addLine(to: CGPoint(
                x: from.x + leaving.dx * wu * alongScale + arriving.dx * wv * acrossScale,
                y: from.y + leaving.dy * wu * alongScale + arriving.dy * wv * acrossScale))
        }
    }

    /// **A step from one depth to the next with no bend at either end.**
    ///
    /// The bridge out of the display's hole has to leave the hole's own bottom
    /// edge and arrive on the notch's far side without a crease at either join,
    /// because the two are one piece of black and a crease is where the eye
    /// finds the seam. Neither curve above will do it: both are quarter turns,
    /// and they arrive across the other axis rather than back along this one.
    ///
    /// So this is the smoother step, `6t⁵ - 15t⁴ + 10t³`, walked along the
    /// stack. Its first *and* second derivatives vanish at both ends, so the
    /// bridge leaves and lands with no slope and no curvature — the strongest
    /// join either straight can be given. Where the two depths are equal it
    /// flattens to the straight line it should be, which is what the notch
    /// passes through on its way from open to folded.
    private func smoothStep(_ path: inout Path, to: CGPoint) {
        guard let from = path.currentPoint else { return }
        let steps = 64
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let eased = t * t * t * (t * (t * 6 - 15) + 10)
            path.addLine(to: CGPoint(x: from.x + (to.x - from.x) * eased,
                                     y: from.y + (to.y - from.y) * t))
        }
    }

    /// A quarter turn from the current point to `to`, leaving along `leaving`
    /// and arriving along `arriving`.
    ///
    /// Each handle is `circleReach` of the distance the turn covers *on its own
    /// axis*, taken from the endpoints rather than from one radius. When the
    /// two distances match that is a circular arc exactly; when they differ it
    /// is the corresponding quarter ellipse, which is how the sweep into the
    /// screen's edge can run wide along the bar without getting any deeper.
    private func turn(_ path: inout Path, to: CGPoint,
                      leaving: CGVector, arriving: CGVector, radius: CGFloat,
                      leavingReach: CGFloat = SideNotchShape.circleReach,
                      arrivingReach: CGFloat = SideNotchShape.circleReach) {
        guard radius > 0, let from = path.currentPoint else {
            path.addLine(to: to)
            return
        }
        let delta = CGVector(dx: to.x - from.x, dy: to.y - from.y)
        let out = abs(delta.dx * leaving.dx + delta.dy * leaving.dy)
        let into = abs(delta.dx * arriving.dx + delta.dy * arriving.dy)
        guard out > 0, into > 0 else {
            path.addLine(to: to)
            return
        }
        path.addCurve(
            to: to,
            control1: CGPoint(x: from.x + leaving.dx * out * leavingReach,
                              y: from.y + leaving.dy * out * leavingReach),
            control2: CGPoint(x: to.x - arriving.dx * into * arrivingReach,
                              y: to.y - arriving.dy * into * arrivingReach)
        )
    }


    private func canonicalPath(in rect: CGRect, flare: CGFloat,
                               flareDepth: CGFloat? = nil) -> Path {
        // Order matters. Clamping the corner by `width - curl` — the obvious
        // reading — collapses it to zero as soon as the flare is as wide as the
        // body, which is exactly what happens when the notch folds to its pill:
        // a 10pt-wide shape came out with square corners. The corner is claimed
        // first, out of half the width, and the flare takes what is left.
        var wanted = max(0, min(cornerRadius, rect.width / 2))
        var flareShare = max(0, min(trailingFlare, 1))
        if let e = emergesFrom {
            let out = max(0, rect.height - e.buried)
            flareShare = min(flareShare, out / 2 / max(flare, 0.001))
            wanted = min(wanted, e.corner + max(0, out - flare * flareShare))
        }
        // Along the bar, and across it.
        //
        // The two are independent only when the caller has asked for them to
        // be — that is what an elliptical sweep is. Left to itself the flare is
        // a quarter circle, and then the across clamp binds the along as well:
        // the depth is what is scarce, and a circle cannot be 33pt long and
        // 4pt deep. Dropping that term stretched the folded pill's flare over
        // half its length and left it a shape nobody recognised.
        // The band hidden past the bezel is claimed before the flare's depth,
        // not after: it is what lets the flare start on the first row that is
        // on screen and meet the border flat. Claimed last, a shape too shallow
        // for band, flare and corner all three — merged into the Mac's notch,
        // at its depth — lost the band, and the flare began above the screen
        // and met the border already part way through its turn: a cut tip.
        let bandDepth = max(0, min(bezelHidden, rect.width - wanted))
        let curlDepth = max(0, min(flareDepth ?? flare, rect.width - wanted - bandDepth))
        let curl = flareDepth == nil
            ? curlDepth
            : max(0, min(flare, rect.height / 2))
        // How far each end has gone in past a wall the bar reaches across —
        // see `Dip.closes`.
        func closing(_ inside: CGFloat) -> CGFloat {
            guard let d = dip, d.closes > 0, inside > 0 else { return 0 }
            let t = min(inside / d.closes, 1)
            return t * t * (3 - 2 * t)
        }
        let leadIn = dip.map { $0.easesAfter ? closing($0.to - rect.minY) : 0 } ?? 0
        let trailIn = dip.map { $0.easesBefore ? closing(rect.maxY - $0.from) : 0 } ?? 0
        let open = 1 - max(0, min(max(leadingJoin, leadIn), 1))
        let trailOpen = 1 - max(0, min(max(trailingJoin, trailIn), 1))
        // How far each end is out past a wall of the hole it is coming out of,
        // and so how much of its flare it has room for: half of what is out,
        // the rest left for the hole's wall. See `Dip.corner`.
        let leadOut = dip.flatMap { $0.easesBefore && $0.corner > 0 ? $0.from - rect.minY : nil }
        let trailOut = dip.flatMap { $0.easesAfter && $0.corner > 0 ? rect.maxY - $0.to : nil }
        // Everything the dip does to the ends comes and goes with its amount,
        // so the fold, which turns it off, eases them rather than switching.
        let dipAmount = min(max(dip?.amount ?? 0, 0), 1)
        func emerging(_ out: CGFloat?) -> CGFloat {
            guard let out else { return 1 }
            return 1 - dipAmount * (1 - min(1, max(0, out) / 2 / max(curl, 0.001)))
        }
        func relaxed(_ value: CGFloat, toward limit: CGFloat) -> CGFloat {
            value - dipAmount * max(0, value - limit)
        }
        let leadShare = open * emerging(leadOut)
        let trailShare = flareShare * trailOpen * emerging(trailOut)
        let leadCurl = curl * leadShare
        let trailCurl = curl * trailShare
        let trailDepth = curlDepth * trailShare
        // Clamped by what the two ends take along the bar, which is what lets a
        // bar that has closed its flares be as short as nothing and still be a
        // clean shape rather than one turned inside out.
        // Shared between the ends that have one: a joined end is square and
        // takes none, so a short copy widening the Mac's notch keeps its whole
        // corner rather than one squeezed under the Mac's.
        let rounded = max(1, open + trailOpen)
        let corner = max(0, min(wanted, (rect.height - leadCurl - trailCurl) / rounded))
        let bodyTop = rect.minY + curl
        let bodyBottom = rect.maxY - trailCurl

        // Never more than the band itself, and never so much that it eats the
        // sweep it is making room for.
        let hidden = bandDepth
        // **How deep the bar is at `v` along it** — its own depth, or less where
        // it dips through the hole.
        //
        // Past a wall it reaches across, it swells back out of the hole the way
        // goo does: held at the hole's depth until enough of it is out to hold
        // its own end — the flare and the corner there — and only then growing
        // toward its full depth, the swell always finished before the end
        // begins to curve up. Easing over a fixed distance instead ran the
        // swell *into* the end whenever less of the bar was out than the two
        // together needed, one curve going down as the other came up, and every
        // one of those left a point.
        let fullDepth = rect.width
        let leadEnd = curl * open + corner * open
        let trailEnd = curl * flareShare * trailOpen + corner * trailOpen
        func eased(_ u: CGFloat) -> CGFloat {
            let t = min(max(u, 0), 1)
            return t * t * t * (t * (t * 6 - 15) + 10)
        }
        // How far it swells past a wall, and over what distance, for `out` of it
        // beyond that wall with `end` of that taken by its own end.
        func swell(out: CGFloat, end: CGFloat, reach: CGFloat,
                   hole: CGFloat) -> (depth: CGFloat, over: CGFloat) {
            let room = out - end
            // Squared, so a sliver of room makes a sliver of swell: in
            // proportion, the little that was out stepped down in a short S
            // straight into the end's corner, and read as a nick.
            let fraction = reach > 0 ? min(max(room / reach, 0), 1) : 1
            let share = fraction * fraction
            return (hole + (fullDepth - hole) * share, max(0.001, min(reach, room)))
        }
        func localDepth(_ v: CGFloat) -> CGFloat {
            guard let d = dip else { return fullDepth }
            let amount = min(max(d.amount, 0), 1)
            let hole = fullDepth - (fullDepth - min(fullDepth, d.depth)) * amount
            // An end inside the hole follows its rounded corner.
            let r = min(d.corner * dipAmount, hole)
            if r > 0, !d.easesBefore, v >= d.from, v < d.from + r {
                let u = d.from + r - v
                return hole - r + (r * r - u * u).squareRoot()
            }
            if r > 0, !d.easesAfter, v <= d.to, v > d.to - r {
                let u = v - (d.to - r)
                return hole - r + (r * r - u * u).squareRoot()
            }
            if v >= d.from && v <= d.to { return hole }
            if v < d.from {
                guard d.easesBefore else { return fullDepth }
                let s = swell(out: d.from - rect.minY, end: leadEnd, reach: d.reach, hole: hole)
                return hole + (s.depth - hole) * eased((d.from - v) / s.over)
            }
            guard d.easesAfter else { return fullDepth }
            let s = swell(out: rect.maxY - d.to, end: trailEnd, reach: d.reach, hole: hole)
            return hole + (s.depth - hole) * eased((v - d.to) / s.over)
        }

        // Which way the far side runs at `v` — straight along, or down or up
        // with the dip. A corner meets the far side heading this way: meeting
        // it straight along where the dip was still lifting it left a shoulder
        // at the foot of the corner.
        func floorHeading(_ v: CGFloat) -> CGVector {
            guard dip != nil else { return CGVector(dx: 0, dy: 1) }
            let slope = (localDepth(v + 0.5) - localDepth(v - 0.5))
            let length = hypot(slope, 1)
            return CGVector(dx: -slope / length, dy: 1 / length)
        }

        var path = Path()
        if let cutout {
            // **Out of the hole.** No flare and no corner at this end: the
            // shape does not begin here, it continues.
            //
            // The bridge starts wherever the hole's wall is — at the tip when
            // the two overlap, back along the bezel when a nudge has parted
            // them — and the run to the wall is held at the hole's own depth,
            // flush with its bottom edge. Overlapping, that fill lands inside
            // the hole, where nothing can be seen: what it is for is the lit
            // sliver in the crook of the hole's rounded corner, which it covers
            // over. Only then does the shape step down onto its own far side.
            let brim = rect.maxX - cutout.depth
            // Neither the wall nor the run may reach past the body into the far
            // corner. A folded pill is a few tens of points long all told, and
            // a path that turned back on itself there would fill inside out.
            let wall = min(cutout.wall, bodyBottom - corner)
            let run = max(0, min(cutout.run, bodyBottom - corner - wall))
            let bridge = min(0, wall)
            path.move(to: CGPoint(x: rect.maxX, y: bridge))
            path.addLine(to: CGPoint(x: brim, y: bridge))
            path.addLine(to: CGPoint(x: brim, y: wall))
            smoothStep(&path, to: CGPoint(x: rect.minX, y: wall + run))
        } else {
            // The flare and the corner at this end, closed up by however far
            // it has joined the hole — see `leadingJoin` — and fitted into the
            // depth the bar has here, which is less where it dips.
            var leadDepth = curlDepth * leadShare
            var leadCorner = corner * open
            if let d = dip {
                let room = max(0, localDepth(rect.minY) - hidden)
                leadDepth = relaxed(leadDepth, toward: room * 0.6)
                leadCorner = relaxed(leadCorner, toward: max(0, room - leadDepth))
                // No rounder than the hole's own corner until it has cleared it.
                if let out = leadOut {
                    leadCorner = relaxed(leadCorner, toward: d.corner + max(0, out - leadCurl))
                }
            }
            let leadTop = rect.minY + leadCurl
            let leadFar = rect.maxX - localDepth(leadTop + leadCorner)
            // Screen edge, above the body.
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            if hidden > 0 { path.addLine(to: CGPoint(x: rect.maxX - hidden, y: rect.minY)) }
            // Flare inward and down onto the top edge.
            if leadCurl > 0.001 {
                fluidTurn(&path, to: CGPoint(x: rect.maxX - hidden - leadDepth, y: leadTop),
                          leaving: CGVector(dx: 0, dy: 1), arriving: CGVector(dx: -1, dy: 0),
                          ramp: filletRamp)
            }
            path.addLine(to: CGPoint(x: leadFar + leadCorner, y: leadTop))
            turn(&path, to: CGPoint(x: leadFar, y: leadTop + leadCorner),
                 leaving: CGVector(dx: -1, dy: 0),
                 arriving: floorHeading(leadTop + leadCorner),
                 radius: leadCorner)
        }
        // The far end is the notch's own end, merged or not: the corner it has
        // on every other edge, and the flare that makes it read as moulded into
        // the bezel rather than stuck on it. This is the drawn shape and it is
        // not the join's to change.
        // The same at the trailing end.
        var trailFlareDepth = trailDepth
        var trailCorner = corner * trailOpen
        if let d = dip {
            let room = max(0, localDepth(rect.maxY) - hidden)
            trailFlareDepth = relaxed(trailFlareDepth, toward: room * 0.6)
            trailCorner = relaxed(trailCorner, toward: max(0, room - trailFlareDepth))
            if let out = trailOut {
                trailCorner = relaxed(trailCorner, toward: d.corner + max(0, out - trailCurl))
            }
        }
        let trailFar = rect.maxX - localDepth(bodyBottom - trailCorner)
        // The far side: straight, or following the dip where there is one.
        if dip != nil, let start = path.currentPoint {
            let end = bodyBottom - trailCorner
            let steps = 192
            for i in 1...steps {
                let v = start.y + (end - start.y) * CGFloat(i) / CGFloat(steps)
                path.addLine(to: CGPoint(x: rect.maxX - localDepth(v), y: v))
            }
        } else {
            path.addLine(to: CGPoint(x: trailFar, y: bodyBottom - trailCorner))
        }
        turn(&path, to: CGPoint(x: trailFar + trailCorner, y: bodyBottom),
             leaving: floorHeading(bodyBottom - trailCorner), arriving: CGVector(dx: 1, dy: 0),
             radius: trailCorner)
        path.addLine(to: CGPoint(x: rect.maxX - hidden - trailFlareDepth, y: bodyBottom))
        // Flare back out to the screen edge.
        if trailCurl > 0.001 {
            fluidTurn(&path, to: CGPoint(x: rect.maxX - hidden, y: rect.maxY),
                      leaving: CGVector(dx: 1, dy: 0), arriving: CGVector(dx: 0, dy: 1),
                      ramp: filletRamp)
        }
        // Back out across the hidden band, whether or not there was a sweep —
        // left inside the branch above it, the flush shape came out a band
        // short on this side and no longer matched itself end to end.
        if hidden > 0 { path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)) }
        path.closeSubpath()
        return path
    }
}
