import AppKit

/// The display's *own* notch — the camera housing on a MacBook, not ours.
///
/// Worth naming, because it is the one piece of the screen that is not a screen:
/// pixels drawn there are behind a hole, not merely covered.
struct HardwareNotch: Equatable {
    let width: CGFloat
    let height: CGFloat

    /// **How deep the cutout is**, from every signal AppKit offers rather than
    /// the one that seemed obvious.
    ///
    /// `safeAreaInsets.top` was it, and it is not dependable: it describes the
    /// area the system is asking apps to keep clear, so it collapses when the
    /// menu bar is hidden or set to auto-hide. The hole in the display does not
    /// move when that happens, so the bar came out shallower than the cutout it
    /// is supposed to be — a step along the bottom of the notch.
    ///
    /// The strips either side of the notch are the notch's own height and keep
    /// reporting it either way, so the deepest of the three is the cutout.
    static func height(safeAreaTop: CGFloat, beside strips: [CGFloat]) -> CGFloat {
        max(safeAreaTop, strips.max() ?? 0)
    }
}

/// **How close the display's own hole is to the notch, and how deep it is.**
///
/// The notch is one shape on all four edges and knows nothing about the
/// hardware. This is the exception, and it is deliberately the smallest one
/// that will do: two numbers, measured in screen points, that say the hole is
/// within reach and where its trailing wall stands relative to the notch's
/// leading tip. Everything the join needs is derived from them — see
/// `SideNotchShape.Cutout`, which draws it.
struct CutoutProximity: Equatable {
    /// How deep the hole is.
    var depth: CGFloat

    /// How far the notch's own end lies *inside* the hole. Never less than
    /// `NotchGeometry.cutoutOverlap`: short of that there is no join — see
    /// `cutoutProximity`.
    var overlap: CGFloat

    /// **Which end of the notch the hole is at.**
    ///
    /// The notch is placed to the right of the cutout and joins it at its
    /// leading end. Dragged the other way it ends up on the *left* of the
    /// cutout, where the end that meets the hole is its trailing one — the same
    /// join, at the other end of the same shape.
    ///
    /// Only of consequence while the notch is coming off the hole or going back
    /// on to it: joined, it is drawn on *both* sides at once, and a pair that is
    /// symmetric about the hole has no side.
    var atTrailingEnd: Bool = false

    /// How wide the hole is, which is the gap the pair is drawn either side of.
    var width: CGFloat = 0

    /// **Whether the two actually overlap**, which is whether the join is
    /// drawn at all.
    ///
    /// The notch is still *reported* for a way either side of that, and the
    /// difference matters: the window is sized and placed for a notch that has
    /// a hole beside it, joined or not, so that taking the hole and letting go
    /// of it do not move the window. A window frame is set in one step and
    /// cannot be animated — anything inside it that eases while it moves is
    /// easing across the distance it moved.
    var joined: Bool = true
}

/// Everything the geometry maths needs from a screen, so it can be faked in tests.
protocol ScreenDescribing {
    var frameValue: CGRect { get }
    var visibleFrameValue: CGRect { get }
    var hardwareNotch: HardwareNotch? { get }
    var displayIdentifier: String? { get }
}

extension ScreenDescribing {
    /// Most displays have none, and most tests do not care.
    var hardwareNotch: HardwareNotch? { nil }
    var displayIdentifier: String? { nil }
}

extension NSScreen: ScreenDescribing {
    var frameValue: CGRect { frame }
    var visibleFrameValue: CGRect { visibleFrame }

    /// Unlike `CGDirectDisplayID`, this UUID survives display reconfiguration
    /// and restarts, so a saved choice still names the same physical monitor.
    var displayIdentifier: String? {
        let screenNumber = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = deviceDescription[screenNumber] as? NSNumber,
              let unmanaged = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)
        else { return nil }
        let uuid = unmanaged.takeRetainedValue()
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Measured from the two menu-bar strips *either side* of the notch, which
    /// is the only thing AppKit describes directly. A display without a notch
    /// reports no auxiliary areas.
    var hardwareNotch: HardwareNotch? {
        guard let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else {
            return nil
        }
        let width = frame.width - left.width - right.width
        let height = HardwareNotch.height(safeAreaTop: safeAreaInsets.top,
                                          beside: [left.height, right.height])
        guard width > 0, height > 0 else { return nil }
        return HardwareNotch(width: width, height: height)
    }
}

enum NotchGeometry {
    /// How far the notch tucks *into* the display's own cutout.
    ///
    /// The two are one piece of black, so they have to overlap rather than
    /// abut: the hole's bottom corners are rounded, and a notch that stopped
    /// dead on the wall would leave a lit sliver in the crook of each one.
    /// Enough to swallow that rounding and no more — the overlap is length
    /// nobody sees, and the bar is drawn longer to pay for it.
    static let cutoutOverlap: CGFloat = 12

    /// **How far the nudge travels on each side of the hole**, past flush.
    ///
    /// A joined notch cannot really be moved — it is attached, and burying more
    /// of it in the hole changes nothing anybody can see. So what the nudge has
    /// to buy is the *other side*, and then the way off the hole altogether;
    /// two dozen points of it apiece. Far enough that a drag does not flip
    /// sides under the hand, near enough that reaching the other side is a
    /// flick rather than a journey — it was the hole's whole width once, which
    /// is two hundred points of dragging for nothing at all to happen.
    static let cutoutTravel: CGFloat = 24

    /// The deepest into the hole the joined end goes before the notch gives up
    /// on that side.
    static var cutoutDeepest: CGFloat { cutoutOverlap + cutoutTravel }

    /// **Where the notch stands against the hole**, on whichever side of it the
    /// nudge has put the notch — before asking whether that is a join at all.
    ///
    /// One number has to say both which side and how far along it, and it can,
    /// because the two runs are laid end to end rather than side by side. On
    /// the right the nudge buries the notch's leading end deeper and deeper
    /// into the hole; once it has buried as much of the bar as the hole will
    /// take there is nowhere further to go on that side, so the notch hops to
    /// the other one at that same depth and the nudge goes on drawing it out
    /// again — by its trailing end, on the left. Every position on either side
    /// is a nudge away in the one direction, and the two runs are the same
    /// length.
    static func cutoutStanding(alongOffset: CGFloat)
    -> (atTrailingEnd: Bool, overlap: CGFloat) {
        let flip = cutoutOverlap - cutoutDeepest
        guard alongOffset < flip else {
            return (atTrailingEnd: false, overlap: cutoutOverlap - alongOffset)
        }
        return (atTrailingEnd: true, overlap: cutoutDeepest + alongOffset - flip)
    }

    // MARK: - While the notch is in the hand

    /// **Near the hole, for a notch that is being dragged.**
    ///
    /// A drag measures the notch the plain way — its leading tip, point for
    /// point with the pointer, `alongOffset` from where it sits flush on the
    /// right — rather than through `cutoutStanding`, whose buried stretches
    /// and side-hop are what made a drag go dead for fifty points and then
    /// jump. Near is anywhere either end is within reach of its own wall of the
    /// hole, and inside it the window is the one that holds a joined pair, so
    /// the notch can be let go of into a join without the window moving.
    static func cutoutFreelyNear(alongOffset a: CGFloat, width: CGFloat,
                                 bar: CGFloat) -> Bool {
        let reach = 2 * cutoutDeepest
        return a >= cutoutOverlap - width - bar - reach && a <= cutoutOverlap + reach
    }

    /// **How far out the hole's pull reaches**, while the notch is dragged.
    static let cutoutCapture: CGFloat = 48

    /// **How hard it holds on**: at the very spot, how much of the pointer's
    /// movement the notch still follows. A tenth-and-a-half — enough to show
    /// it is being held, little enough that it is plainly *held*.
    static let cutoutGrip: CGFloat = 0.15

    /// **How far the strand between a dragged notch and the hole stretches**
    /// before it has thinned to nothing.
    static let cutoutStretch: CGFloat = 48

    /// **The magnet.** Where a dragged notch is drawn, for where the pointer has
    /// actually taken it.
    ///
    /// Near either of the two places it can join — flush against the right wall,
    /// or the left — the pointer's distance `d` from that place is bent to
    /// `d · (1 − (1 − g)(1 − |d|/C)²)`. At the place itself the notch follows
    /// only `g` of the pointer, so it sits heavy and has to be tugged; further
    /// out it follows more and more of it.
    ///
    /// **And never more than a little over all of it.** The first curve here
    /// held just as hard, but to catch up with the pointer by the edge of the
    /// pull it had to run at 2.7 times the pointer near that edge — and the
    /// pointer arrives in steps, so every step became one nearly three times
    /// the size: choppy exactly where the notch was about to join. This one
    /// peaks at `1 + (1 − g)/3`, about 1.28, and meets the pointer at the edge
    /// of the pull with the pointer's own *slope* as well as its position, so
    /// there is no kink to feel going in or coming out. It only ever rises.
        static func magnetised(_ a: CGFloat, width: CGFloat, bar: CGFloat) -> CGFloat {
        for target in [0, 2 * cutoutOverlap - width - bar] {
            let d = a - target
            guard abs(d) < cutoutCapture else { continue }
            let rest = 1 - abs(d) / cutoutCapture
            return target + d * (1 - (1 - cutoutGrip) * rest * rest)
        }
        return a
    }

    /// The drag's measure of a notch placed by `cutoutStanding` — the same spot
    /// on screen, said the plain way.
    static func freeOffset(fromStanding a: CGFloat, width: CGFloat,
                           bar: CGFloat) -> CGFloat {
        let stand = cutoutStanding(alongOffset: a)
        guard stand.atTrailingEnd else { return a }
        // On the left its trailing tip is `overlap` inside the left wall, and
        // its leading tip a bar's length back from that.
        return cutoutOverlap - width + stand.overlap - bar
    }

    /// And back: the placement a dragged notch has once it is let go, on
    /// whichever side of the hole most of it is.
    static func standingOffset(fromFree a: CGFloat, width: CGFloat,
                               bar: CGFloat) -> CGFloat {
        let flip = cutoutOverlap - cutoutDeepest
        // The bar's middle against the hole's, both measured from the hole's.
        let lead = width / 2 - cutoutOverlap + a
        guard lead + bar / 2 < 0 else { return max(a, flip) }
        let overlap = lead + bar + width / 2
        return min(overlap - cutoutDeepest + flip, flip - 0.5)
    }

    /// **Where a dragged notch goes when it is let go**, as the joined offset
    /// it is kept at — flush on whichever side of the hole most of it is on —
    /// or nil when it is out of reach and stays where it was put.
    ///
    /// One movement takes it there from wherever it was let go: onto the wall,
    /// in past it, and the hole's size taken, all on one spring.
    static func cutoutLanding(alongOffset a: CGFloat, width: CGFloat, bar: CGFloat) -> CGFloat? {
        guard cutoutFreelyNear(alongOffset: a, width: width, bar: bar) else { return nil }
        let lead = width / 2 - cutoutOverlap + a
        // Its leading tip is inside the right wall while it is left of it, or
        // its trailing tip inside the left wall while it is right of it.
        return lead + bar / 2 >= 0 ? 0 : 2 * (cutoutOverlap - cutoutDeepest)
    }

    /// **Whether the notch is on the display's own hole**, at which end, and by
    /// how much.
    ///
    /// Answered from the offset alone rather than from the panel that is about
    /// to be placed, and that is not an approximation: the nudge *is* the
    /// placement, and `panelFrame` pins the joined end to the wall from the
    /// same answer. Asking the panel instead would be circular — the panel is
    /// sized for a bar whose length depends on this.
    ///
    /// **The question is whether the two are touching, not whether the notch
    /// has been dragged.** Asking the second cost the join on the one machine it
    /// was written for: a nudge of -42pt was already saved for the top edge from
    /// an afternoon of dragging the bar toward the hole, which is a perfectly
    /// good place for it to be — the tip is inside the hole and the bar starts
    /// at the wall, exactly as it does with no nudge at all — and a rule written
    /// on the size of the nudge threw all of it away.
    static func cutoutProximity(for screen: ScreenDescribing, edge: NotchEdge,
                                alongOffset: CGFloat,
                                heldBar: CGFloat? = nil) -> CutoutProximity? {
        guard edge == .top, let cutout = screen.hardwareNotch else { return nil }
        // **In the hand, it is never joined.** Joined, the notch is attached
        // and cannot follow the pointer; it lets go when it is picked up and
        // takes the hole again when it is put down — see `cutoutLanding`.
        if let bar = heldBar {
            guard cutoutFreelyNear(alongOffset: alongOffset, width: cutout.width, bar: bar)
            else { return nil }
            return CutoutProximity(depth: cutout.height, overlap: cutoutOverlap - alongOffset,
                                   atTrailingEnd: false, width: cutout.width, joined: false)
        }
        // Measured on the end that meets the hole, which `panelFrame` pins to
        // the wall it meets — so this is the placement rather than a guess at it.
        let (atTrailingEnd, overlap) = cutoutStanding(alongOffset: alongOffset)

        // **Near the hole at all**, which is a wider question than whether the
        // join is drawn: the window has to be the same size and in the same
        // place either side of that answer.
        guard overlap >= cutoutOverlap - cutoutTravel,
              overlap <= cutoutDeepest + cutoutTravel else { return nil }

        // **There is no join unless the two actually overlap.**
        //
        // The bridge used to reach across a gap, on the reasoning that two
        // shapes a few points apart still read as one. They do not. What is
        // drawn at the joined end is a square tip and a flat run at the hole's
        // depth — invisible while it is *inside* the hole, which is the only
        // reason it may be square. Hanging in the open over a gap it is exactly
        // the hard, cut edge that has no business being on this shape, and the
        // notch is plainly not merged with anything.
        //
        // So short of the overlap the join is drawn for, there is no join: the
        // notch is a notch, with the flare it has on every other edge. And past
        // the hole's far wall there is none either, or the fill that hides
        // inside the hole would hang out the other side of it.
        let joined = overlap >= cutoutOverlap && overlap <= cutoutDeepest
        return CutoutProximity(depth: cutout.height, overlap: overlap,
                               atTrailingEnd: atTrailingEnd, width: cutout.width,
                               joined: joined)
    }

    /// Anchor to the physical display edge, even when the Dock or menu bar
    /// reserves part of the desktop. Showing or hiding either must not move
    /// a position the user chose.
    ///
    /// The rect is rounded out to whole points on purpose. AppKit rounds window
    /// frames anyway, and if it does the rounding the panel ends up a fraction
    /// larger than asked for — which leaves the content, laid out at its exact
    /// size, stopping short of the screen edge. A hairline of wallpaper along
    /// that edge is all it takes for the notch to read as floating rather than
    /// welded to the bezel.
    static func panelFrame(
        for screen: ScreenDescribing,
        panelSize: CGSize,
        edge: NotchEdge = .right,
        // A user-chosen nudge along the edge, from `NotchViewModel.alongOffset`
        // — zero is the centred default this file always drew before the nudge
        // existed. Vertical edges read it as AppKit's y running *down* the
        // screen (dragging the pill down increases it); horizontal edges read
        // it as x running right, which needs no such flip.
        alongOffset: CGFloat = 0,
        // The padding `panelSize` carries on *each* end beyond the visible
        // pill, reserved for a hover card that is not there right now —
        // `NotchViewModel.slack`. Clamping the offset by the padded size
        // would have left the pill only a sliver of room to move in on most
        // screens, since that padding is sized for the tallest possible card
        // and can be most of the panel. Clamping by the pill's own extent
        // instead — `panelSize` shrunk by this on each end — lets it travel
        // almost the full edge; the padding is free to run past the bezel,
        // since nothing is drawn there until a card actually opens.
        slack: CGFloat = 0,
        // The handles can hang past either end of the body. Those parts of
        // the padding must stay on screen even when the hover card may not.
        trailingExtent: CGFloat = 0,
        leadingExtent: CGFloat = 0,
        // The notch's own length when it is being dragged, nil otherwise — a
        // held notch is placed point for point with the pointer.
        heldBar: CGFloat? = nil
    ) -> CGRect {
        let full = screen.frameValue
        let width = panelSize.width.rounded(.up)
        let height = panelSize.height.rounded(.up)

        let origin: CGPoint
        switch edge {
        case .right:
            let y = clamp(full.midY - height / 2 - alongOffset,
                          min: full.minY - slack + trailingExtent,
                          max: full.maxY - height + slack - leadingExtent)
            origin = CGPoint(x: full.maxX - width, y: y)
        case .left:
            let y = clamp(full.midY - height / 2 - alongOffset,
                          min: full.minY - slack + trailingExtent,
                          max: full.maxY - height + slack - leadingExtent)
            origin = CGPoint(x: full.minX, y: y)
        case .top:
            // **Merged into the display's own cutout, where it has one.**
            //
            // The notch is drawn the same way on all four edges — see
            // `NotchViewModel`, which knows nothing about the hardware. The
            // one thing the cutout decides is where the top edge's notch
            // *sits*, and that is settled here.
            //
            // Not centred, which buries it in the hole: that band is not a dim
            // part of the screen, it is absent, and anything drawn there is not
            // on screen at all. Not below it either — dropping the panel clear
            // of the hole leaves the notch hanging in the wallpaper under the
            // cutout, attached to nothing.
            //
            // And not beside it with a gap, which is what this was first. Two
            // black shapes ten points apart on the same bezel do not read as
            // two things, they read as one thing with a fault in it. So the
            // notch starts `cutoutOverlap` *inside* the hole and flows out of
            // it — one silhouette, joined by `SideNotchShape.Cutout`.
            //
            // Measured on the *visible* notch, not the panel: the panel
            // carries `slack` at each end for a hover card that is usually not
            // there, so the notch inside it starts that much in from its edge.
            //
            // Written as "pin this end of the bar to that wall of the hole"
            // rather than as an offset from centre, because that is the whole
            // of it: `cutoutStanding` says which end and how far inside, on
            // either side, and it answers for positions that are no longer a
            // join at all — so the notch goes on travelling with the nudge
            // after it has let go of the hole, out past it rather than back to
            // the middle of the screen.
            var wanted: CGFloat = full.midX - width / 2 + alongOffset
            if let bar = heldBar, let cutout = screen.hardwareNotch {
                // In the hand: the window that holds a pair while the notch is
                // anywhere near the hole, so letting go into a join does not
                // move it, and the plain pin beside the hole once it is not.
                wanted = cutoutFreelyNear(alongOffset: alongOffset, width: cutout.width, bar: bar)
                    ? full.midX - width / 2
                    : full.midX + cutout.width / 2 - cutoutOverlap + alongOffset - slack
            } else if cutoutProximity(for: screen, edge: edge, alongOffset: alongOffset) != nil {
                // **Centred on the hole, joined or not.**
                //
                // Joined the notch is a pair either side of the cutout and the
                // panel holds both; not joined it is one bar beside it and the
                // panel holds the room the other would need. The same window
                // either way, deliberately: taking the hole must not move it.
                // Where each copy sits inside it is `NotchViewModel.wings`.
                wanted = full.midX - width / 2
            } else if let cutout = screen.hardwareNotch {
                let bar: CGFloat = width - 2 * slack
                let stand = cutoutStanding(alongOffset: alongOffset)
                wanted = stand.atTrailingEnd
                    ? full.midX - cutout.width / 2 + stand.overlap - bar - slack
                    : full.midX + cutout.width / 2 - stand.overlap - slack
            }
            let x = clamp(wanted,
                          min: full.minX - slack + leadingExtent,
                          max: full.maxX - width + slack - trailingExtent)
            origin = CGPoint(x: x, y: full.maxY - height)
        case .bottom:
            let x = clamp(full.midX - width / 2 + alongOffset,
                          min: full.minX - slack + leadingExtent,
                          max: full.maxX - width + slack - trailingExtent)
            origin = CGPoint(x: x, y: full.minY)
        }

        return CGRect(
            x: origin.x.rounded(),
            y: origin.y.rounded(),
            width: width,
            height: height
        )
    }

    static func preferredScreen(
        from screens: [NSScreen],
        preference: DisplayPreference = .followActiveWindow
    ) -> NSScreen? {
        preferredScreen(from: screens, preference: preference, activeScreen: NSScreen.main)
    }

    /// Kept generic so display selection can be proved without relying on the
    /// monitors attached to the machine running the tests.
    static func preferredScreen<Screen: ScreenDescribing>(
        from screens: [Screen],
        preference: DisplayPreference,
        activeScreen: Screen?
    ) -> Screen? {
        if case .display(let id) = preference,
           let selected = screens.first(where: { $0.displayIdentifier == id }) {
            return selected
        }
        return activeScreen ?? screens.first
    }

    /// Keeps a dragged offset from pushing the visible pill off the screen it
    /// is on. A plain `ClosedRange` clamp would trap if the pill were ever
    /// taller or wider than the screen, which a very small display could
    /// make true.
    private static func clamp(_ value: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        guard lo <= hi else { return lo }
        return Swift.min(Swift.max(value, lo), hi)
    }
}
