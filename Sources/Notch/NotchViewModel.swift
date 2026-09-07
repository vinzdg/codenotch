import SwiftUI
import Combine

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var snapshots: [ProviderSnapshot] = []
    /// Live agent sessions, keyed by the provider they belong to. They surface
    /// inside that provider's own ring rather than as a cell of their own — one
    /// ring per provider, so nothing in the notch looks like a ring without
    /// being one.
    @Published var sessions: [String: [AgentSession]] = [:]

    /// Which cell the cursor is over, if any. Driven from the window controller
    /// rather than SwiftUI's `.onHover`: the panel ignores mouse events until
    /// the cursor is over it, so SwiftUI cannot see the crossing that turns
    /// event handling on in the first place.
    @Published var hoveredIndex: Int?
    /// Ticked on refresh so the "Resets in N min" copy stays honest.
    @Published var now: Date = Date()

    /// Whether the notch is open or folded away to its pill.
    @Published var isExpanded = false
    /// Clicked open, so it stays open until clicked shut again. A gesture,
    /// not a setting: it lasts as long as this session of looking at it.
    @Published var isPinned = false

    /// The standing choice from Settings — "Always show".
    ///
    /// Separate from `isPinned` because the two are not the same claim, and
    /// sharing one flag is what let a click on the bar undo a setting. Clicking
    /// toggles a pin; only Settings moves this.
    @Published var isAlwaysOn = false

    /// Held open, by either route. What the folding logic actually asks.
    var staysOpen: Bool { isPinned || isAlwaysOn }
    /// Providers with a fetch in flight, driven by the store.
    @Published var refreshing: Set<String> = []
    /// The settings handle is under the cursor.
    @Published var isHoveringSettings = false
    /// Which screen edge the notch is welded to. Everything geometric reads
    /// this through `placement` rather than assuming an axis.
    @Published var edge: NotchEdge = .right
    /// A user-chosen nudge along that edge, in screen points from the centred
    /// default — set live while ⌥-dragging the pill, and by
    /// `NotchGeometry.panelFrame` from there. Reset to whatever was stored for
    /// the new edge whenever `edge` changes; this type does not own that
    /// persistence, only the live value.
    @Published var alongOffset: CGFloat = 0
    /// The display's own notch, when this edge has to share the bezel with one.
    ///
    /// Set by the window controller from the screen the panel is on, because
    /// that is the only thing that knows which screen that is.
    @Published var hardwareNotch: HardwareNotch?

    /// How much screen there is to spend on the panel.
    ///
    /// The tooltip's budget comes out of this: how many sessions a card can
    /// list before the panel holding it would run off the display. Zero until
    /// the controller says otherwise, which reads as "no screen known yet".
    @Published var screenSize: CGSize = .zero

    /// The same screen minus the menu bar and the Dock.
    ///
    /// A horizontal notch starts at the *usable* edge and grows inward from
    /// there, so those two are room it never had. A side notch is centred on
    /// the whole screen and floats over both, so for that one they are not.
    @Published var screenUsableSize: CGSize = .zero

    /// Take the notch geometry of whichever screen the panel is on.
    func adopt(screen: ScreenDescribing) {
        let merging = edge == .top ? screen.hardwareNotch : nil
        if hardwareNotch != merging { hardwareNotch = merging }
        // `frame`, not `visibleFrame`: the panel is centred on the full screen
        // and may sit under the menu bar, so the menu bar is not room lost.
        let size = screen.frameValue.size
        if screenSize != size { screenSize = size }
        let usable = screen.visibleFrameValue.size
        if screenUsableSize != usable { screenUsableSize = usable }
    }

    /// How far in from the bezel the notch's contents start.
    ///
    /// Zero everywhere except a top notch merging with the display's own. There
    /// the shape runs up past the menu bar to meet the hardware, and that top
    /// band is a **hole in the screen** — anything drawn in it is not dimmed or
    /// clipped, it is simply not there. So the readings start below it.
    /// Exactly the hardware's height, and nothing on top of it: the readings
    /// then sit the frame's own `ringMargin` below the hardware's bottom edge,
    /// which is the same distance a ring sits from the bezel on every other
    /// placement. Adding a gap as well pads them twice and leaves them adrift
    /// of the notch they are supposed to belong to.
    var contentInset: CGFloat { hardwareNotch?.height ?? 0 }

    /// How much of each end of the bar the flare actually takes.
    var flare: CGFloat {
        isFlushWithHardware ? NotchLayout.bezelFillet : NotchLayout.curlRadius
    }

    /// Whether the shape is drawn the way the Mac's own notch is — flush to
    /// the bezel, no flares — so the two are one object rather than two.
    var isFlushWithHardware: Bool { hardwareNotch != nil }

    /// The hardware notch as the *shape* needs it, which is only where one is
    /// being drawn as.
    var joinedNotch: HardwareNotch? { hardwareNotch }

    /// The corner the shape actually draws at its far end.
    ///
    /// Not always `cornerRadius`: a bar drawn as the hardware notch caps it at
    /// the hardware's own rounding, so that the shape is the same at rest as it
    /// is open. Everything the orb does hangs off this rather than off the
    /// nominal figure — the orb traces the corner that is drawn, not the one
    /// that was asked for.
    var drawnCornerRadius: CGFloat {
        guard let hardwareNotch else { return NotchLayout.cornerRadius }
        return min(NotchLayout.cornerRadius, hardwareNotch.height / 2)
    }

    /// What the orb scales to as it folds away. Nestled in a flare it grows
    /// outward along the normal and is swallowed by the notch's black; hanging
    /// off a corner there is nothing to be swallowed by, so it draws in on
    /// itself and leaves by the fade.
    var orbMergeScale: CGFloat {
        orbHugsCorner ? 0.6 : NotchLayout.orbMergeScale
    }

    /// The circle the resting arc follows.
    var orbArcRadius: CGFloat {
        orbHugsCorner
            ? NotchLayout.orbConvexArcRadius(corner: drawnCornerRadius)
            : NotchLayout.orbArcRadius
    }

    /// Extra length at each end of the body so the notch has something to open
    /// out *into*.
    ///
    /// A single ring makes a body about 117pt across; this Mac's notch is 220.
    /// Left alone the hardware would be wider than the bar it is supposed to
    /// grow into, which reads as a mistake. Matching it exactly is not enough
    /// either — a bar the same width as the notch is a straight column, and the
    /// notch appears not to have opened at all. So the floor is the notch plus
    /// a fillet's worth of opening at each side, and a corner's worth beyond
    /// that for the bar's own rounding to live in.
    var endSpread: CGFloat { endSpread(cellCount: snapshots.count) }

    func endSpread(cellCount: Int) -> CGFloat {
        guard let hardwareNotch else { return 0 }
        // Expressed against the whole shape, not just its body: with no flares
        // the drawn width *is* the shape's length, and that is what has to
        // clear the hardware.
        let drawn = NotchLayout.shapeLength(
            cellCount: cellCount, edge: edge, flare: flare
        )
        let wanted = hardwareNotch.width + 2 * NotchLayout.cornerRadius
        return max(0, (wanted - drawn) / 2)
    }

    /// Where the settings orb sits.
    ///
    /// Ordinarily it is concentric with the far flare, one radius in from the
    /// bezel and level with the end of the shape. A flush bar has no flare, so
    /// it hugs the bar's own bottom-end corner from outside instead — same
    /// idea, turned inside out. Left where it was it becomes a dot on the
    /// bar's flat edge.
    var orbHugsCorner: Bool { isFlushWithHardware }

    var orbAlong: CGFloat {
        guard orbHugsCorner else { return shapeLength }
        return cornerCentreAlong + NotchLayout.orbCornerOffset(corner: drawnCornerRadius)
    }

    /// Where the bar's far corner actually turns, along the stack.
    ///
    /// Inset from the bar's end by the *flare* as well as by the corner's own
    /// radius — the shape's body starts a flare in from each end, and the
    /// corner is rounded off that body, not off the shape's outer bound.
    /// Leaving the flare out slid the arc a whole fillet down the bar, and the
    /// gap it is supposed to hold opened from 9pt at one end to 19pt at the
    /// other.
    var cornerCentreAlong: CGFloat {
        shapeLength - flare - drawnCornerRadius
    }

    var orbInset: CGFloat {
        guard orbHugsCorner else { return contentInset + NotchLayout.orbInsetFromEdge }
        return contentInset + NotchLayout.bodyDepth(for: edge)
            - drawnCornerRadius + NotchLayout.orbCornerOffset(corner: drawnCornerRadius)
    }

    /// Where the resting arc sits relative to the button.
    ///
    /// Inside a flare's pocket the two are one object — the arc is just the
    /// outer edge of the same orb, and this is zero. Hanging off a convex
    /// corner they part company: the button has to be clear of the bar, but the
    /// arc's whole job is to trace the bar's contour, so it stays back on the
    /// corner the button hangs from.
    var orbArcOffset: CGSize {
        guard orbHugsCorner else { return .zero }
        let inward = CGPoint(x: -edge.outward.x, y: -edge.outward.y)
        let back = -NotchLayout.orbCornerOffset(corner: drawnCornerRadius)
        return CGSize(width: back * (edge.alongDirection.x + inward.x),
                      height: back * (edge.alongDirection.y + inward.y))
    }

    /// The points the settings handle answers around: the button you are
    /// reaching for, and — where it has parted company with it — the arc you
    /// can actually see.
    var orbHandlePoints: [CGPoint] {
        let button = CGPoint(x: orbAlong, y: orbInset)
        guard orbHugsCorner else { return [button] }

        let arcCentre = CGPoint(x: orbAlong + orbArcOffset.width,
                                y: orbInset + orbArcOffset.height)
        let reach = hypot(button.x - arcCentre.x, button.y - arcCentre.y)
        guard reach > 0 else { return [button] }
        // The middle of the quadrant, which is out from its centre in the same
        // direction the button went.
        let arcMid = CGPoint(
            x: arcCentre.x + orbArcRadius * (button.x - arcCentre.x) / reach,
            y: arcCentre.y + orbArcRadius * (button.y - arcCentre.y) / reach
        )
        return [arcMid, button]
    }

    /// Whether a point in stack space is on the settings handle.
    ///
    /// A circle around each of those points, rather than one box around the
    /// pair. The handle is a round thing in two places, and the bounding box of
    /// the two takes in a great deal of ground that is near neither — which is
    /// why the button used to appear well before the pointer reached the arc.
    func isOnOrbHandle(along: CGFloat, across: CGFloat) -> Bool {
        let radius = NotchLayout.orbHotZone / 2
        return orbHandlePoints.contains {
            hypot(along - $0.x, across - $0.y) <= radius
        }
    }


    /// Where the tooltip's tail tip sits, measured in from the bezel: just off
    /// the inner face of a shape that the extension has made deeper.
    var tooltipInset: CGFloat {
        contentInset + NotchLayout.bodyDepth(for: edge) + NotchLayout.tailGap
    }

    /// The straight part of the shape, flares excluded.
    var bodyLength: CGFloat {
        NotchLayout.bodyLength(
            cellCount: snapshots.count, edge: edge
        ) + 2 * endSpread
    }

    /// Distance along the stack to cell `index`'s ring centre, widening
    /// included so the readings stay in the middle of the bar.
    func ringCenter(index: Int) -> CGFloat {
        NotchLayout.ringCenter(index: index, edge: edge, flare: flare) + endSpread
    }

    /// A provider with no activity source gets none, rather than borrowing
    /// somebody else's.
    func activity(for providerID: String) -> ActivitySummary? {
        ActivitySummary(sessions: sessions[providerID] ?? [])
    }

    var hoveredSnapshot: ProviderSnapshot? {
        guard let hoveredIndex, snapshots.indices.contains(hoveredIndex) else { return nil }
        return snapshots[hoveredIndex]
    }

    var shapeLength: CGFloat { shapeLength(cellCount: snapshots.count) }

    var panelSize: CGSize { panelSize(cellCount: snapshots.count) }

    /// How stack space maps onto the panel right now.
    var placement: NotchPlacement { NotchPlacement(edge: edge, panelSize: panelSize) }

    /// Room at each end of the stack, for this edge.
    var slack: CGFloat { slack(cellCount: snapshots.count) }

    func slack(cellCount: Int) -> CGFloat {
        NotchLayout.slack(for: edge, maxCardHeight: maxCardHeight(cellCount: cellCount))
    }

    /// How many sessions a tooltip may list here before it has to summarise
    /// the rest — as many as this screen has room for.
    var sessionCap: Int { sessionCap(cellCount: snapshots.count) }

    func sessionCap(cellCount: Int) -> Int {
        guard screenSize != .zero else { return NotchLayout.defaultSessionCap }
        return NotchLayout.sessionsFitting(cardBudget: cardBudget(cellCount: cellCount),
                                           windowCount: NotchLayout.maxWindowCount)
    }

    func maxCardHeight(cellCount: Int) -> CGFloat {
        NotchLayout.maxCardHeight(sessionCap: sessionCap(cellCount: cellCount))
    }

    /// How tall the tallest card may be before the panel runs off the screen.
    ///
    /// Which way it runs out differs by orientation, because the card's height
    /// is spent on a different axis: along a side edge it is spent *along* the
    /// stack, half of it past each end, so the stack itself takes its share
    /// first. Along a horizontal edge the card hangs *inward* instead, and what
    /// it competes with is the depth already spent on the notch body and tail.
    private func cardBudget(cellCount: Int) -> CGFloat {
        if edge.isVertical {
            return screenSize.height
                - shapeLength(cellCount: cellCount)
                - 2 * NotchLayout.cardCorner
        }
        return screenUsableSize.height
            - contentInset
            - NotchLayout.bodyDepth(for: edge)
            - NotchLayout.tailLength
            - NotchLayout.tailGap
    }

    /// The drawn extent of the notch body right now, along the stack.
    ///
    /// Where it is joining the display's own notch, folding away means becoming
    /// exactly that notch — same width, same height. The resting pill is the
    /// wrong object there: it hangs below the hardware as a separate little
    /// tab, which is the very seam this placement exists to remove. Matching
    /// the hardware instead means nothing shows at rest at all, and reaching
    /// for it makes the notch itself grow.
    var notchLength: CGFloat {
        if isExpanded { return shapeLength }
        return hardwareNotch?.width ?? NotchLayout.pillHeight
    }

    /// And across it.
    var notchDepth: CGFloat {
        if isExpanded { return contentInset + NotchLayout.bodyDepth(for: edge) }
        return hardwareNotch?.height ?? NotchLayout.pillWidth
    }

    /// What the notch folds away to, whether or not it is open right now —
    /// the hit region has to know that while the notch is still open.
    var restingLength: CGFloat { hardwareNotch?.width ?? NotchLayout.pillHeight }
    var restingDepth: CGFloat { hardwareNotch?.height ?? NotchLayout.pillWidth }

    /// The drawn size of the notch body, in panel axes.
    var notchSize: CGSize {
        NotchPlacement.panelSize(edge: edge, length: notchLength, depth: notchDepth)
    }

    /// Where the notch starts along the stack. Both states share a centre line,
    /// so folding away does not slide the notch along the edge as it shrinks.
    var notchLeadingInset: CGFloat {
        slack + (shapeLength - notchLength) / 2
    }

    /// Sized from an explicit count rather than from `snapshots`.
    ///
    /// `@Published` notifies its subscribers in `willSet`, so a sink reacting to
    /// a change in the provider list still sees the *old* array if it reads the
    /// model back. Taking the count as an argument is the only way to be sure
    /// the panel is sized for the list that caused the change.
    func shapeLength(cellCount: Int) -> CGFloat {
        NotchLayout.shapeLength(cellCount: cellCount,
                                edge: edge, flare: flare)
            + 2 * endSpread(cellCount: cellCount)
    }

    func panelSize(cellCount: Int) -> CGSize {
        let card = maxCardHeight(cellCount: cellCount)
        return NotchPlacement.panelSize(
            edge: edge,
            length: shapeLength(cellCount: cellCount)
                + 2 * NotchLayout.slack(for: edge, maxCardHeight: card),
            depth: contentInset
                + NotchLayout.tooltipDepth(for: edge, maxCardHeight: card)
                + NotchLayout.bodyDepth(for: edge)
        )
    }
}
