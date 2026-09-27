import SwiftUI
import Combine

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var snapshots: [ProviderSnapshot] = []
    /// Per runtime, so Ollama's relay switching off clears its own readings
    /// and nobody else's.
    private var performances: [String: [String: LocalModelPerformance]] = [:]
    private var ledger = LocalTokenLedger()
    private var localMetricsEnabled = false

    /// The Ollama relay's own id; its readings are keyed by model name.
    static let ollamaSource = "ollama-local"

    func setLocalMetricsEnabled(_ enabled: Bool) {
        localMetricsEnabled = enabled
        if !enabled { performances[Self.ollamaSource] = nil; thinkingModels = [:] }
        snapshots = snapshots.map(decorated)
    }

    func updateSnapshots(_ providerSnapshots: [ProviderSnapshot]) {
        let hoveredID = hoveredSnapshot?.id
        let next = ProviderOrder.cells(from: providerSnapshots, keeping: snapshots).map(decorated)
        let nextHoveredIndex = hoveredID.flatMap { id in next.firstIndex { $0.id == id } }
        if hoveredIndex != nextHoveredIndex { hoveredIndex = nextHoveredIndex }
        snapshots = next
    }

    func updatePerformances(_ measurements: [String: LocalModelPerformance],
                            source: String = NotchViewModel.ollamaSource) {
        performances[source] = measurements
        snapshots = snapshots.map(decorated)
    }

    /// Logged tokens per cell, read against `now` as it is drawn so "today"
    /// rolls over at midnight without a new line being written.
    func updateLedger(_ ledger: LocalTokenLedger) {
        self.ledger = ledger
        snapshots = snapshots.map(decorated)
    }

    private func decorated(_ snapshot: ProviderSnapshot) -> ProviderSnapshot {
        guard let model = snapshot.localModel else { return snapshot }
        var snapshot = snapshot
        let shows = localMetricsEnabled || snapshot.localRuntimeMeasuresSpeed
        snapshot.showsLocalPerformance = shows
        snapshot.localPerformance = shows
            ? performances[snapshot.providerID]?[Self.performanceKey(for: snapshot, model: model)] : nil
        snapshot.localLedger = ledger.summary(for: snapshot.id, now: now)
        snapshot.localContextFraction = snapshot.localLedger?.contextFraction(contextLength: model.contextLength)
        return snapshot
    }

    /// Ollama's relay knows a model by the name a client used, with Ollama's
    /// implicit `:latest`; everything else reports by notch cell id.
    static func performanceKey(for snapshot: ProviderSnapshot, model: LocalRuntimeReading.Model) -> String {
        snapshot.providerID == ollamaSource ? OllamaThinkingStream.modelKey(model.name) : snapshot.id
    }

    @Published var thinkingModels: [String: Date] = [:]
    /// What each local model instance is doing, keyed by cell id. Ollama's
    /// thinking relay reports through `thinkingModels`; LM Studio's state
    /// poll reports here, phase and queue included.
    @Published var localActivities: [String: LocalModelActivity] = [:]

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
    @Published var resetTimeFormat: ResetTimeFormat = .automatic

    /// Active usage reset notification event to present beside the notch.
    @Published var activeResetAlert: UsageResetEvent?

    func resetAlertIndex(for event: UsageResetEvent) -> Int? {
        snapshots.firstIndex { $0.id == event.providerID }
    }

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

    /// Providers with a fetch in flight, driven by the store.
    @Published var refreshing: Set<String> = []
    /// Bumped each time the settings orb is clicked, by either route.
    ///
    /// A count rather than a flag: the gear turns to `spins * 360`, so a
    /// second click while the first turn is still running carries on round
    /// instead of restarting from wherever it had got to.
    @Published var settingsSpins = 0

    @Published private(set) var refreshingCells: Set<String> = []

    func isRefreshing(_ snapshot: ProviderSnapshot) -> Bool {
        snapshot.localModel == nil
            ? refreshing.contains(snapshot.providerID)
            : refreshingCells.contains(snapshot.id)
    }

    func refresh(_ snapshot: ProviderSnapshot, using refreshProvider: (String) async -> Void) async {
        guard snapshot.localModel != nil else {
            await refreshProvider(snapshot.providerID)
            return
        }
        guard refreshingCells.insert(snapshot.id).inserted else { return }
        defer { refreshingCells.remove(snapshot.id) }
        // A shared inventory fetch is not activity in every loaded model.
        // Only the clicked cell presses in, even when it joins an existing poll.
        async let feedback: Void = Task.sleep(nanoseconds: 380_000_000)
        await refreshProvider(snapshot.providerID)
        _ = try? await feedback
    }
    /// The settings handle is under the cursor.
    @Published var isHoveringSettings = false
    /// The move handle is under the cursor.
    @Published var isHoveringMove = false
    /// Bumped each time the move handle is pressed, on the same counter
    /// pattern `settingsSpins` uses and for the same reason.
    @Published var moveSpins = 0
    /// The notch is in hand: the move handle has been held past its threshold
    /// and the drop zones are up, waiting for a release.
    @Published var isMoving = false
    /// Which edge a release would land on. Nil before the pointer has moved
    /// far enough for a target to be meaningful.
    @Published var moveTarget: NotchEdge?
    /// A move finished on `edge`. The controller owns persisting it, for the
    /// same reason it owns `onReposition`: this type knows the geometry, not
    /// where preferences live.
    var onMove: ((NotchEdge) -> Void)?
    /// A direct SwiftUI tap on the settings orb, independent of the panel's
    /// own AppKit-level click routing (`NotchPanel.mouseDown` →
    /// `NotchWindowController.handleClick`). That path relies on the panel's
    /// `ignoresMouseEvents` toggle and a custom `hitTest` staying in exact
    /// agreement with this model's own geometry on every click; this gives
    /// the one action people actually get stuck without a second, ordinary
    /// route that only needs SwiftUI's own gesture recognition to work.
    var onOpenSettings: (() -> Void)?
    /// A tap on a session row in the tooltip: jump to the terminal tab the
    /// session runs in. Takes the session's pid; wired to `SessionFocus`.
    var onFocusSession: ((pid_t) -> Void)?
    /// Which screen edge the notch is welded to. Everything geometric reads
    /// this through `placement` rather than assuming an axis.
    @Published var edge: NotchEdge = .right
    /// A user-chosen nudge along that edge, in screen points from the centred
    /// default — set live while ⌥-dragging the pill, and by
    /// `NotchGeometry.panelFrame` from there. Reset to whatever was stored for
    /// the new edge whenever `edge` changes; this type does not own that
    /// persistence, only the live value.
    @Published var alongOffset: CGFloat = 0
    /// What every measured distance is multiplied by before it reaches the
    /// screen — the Appearance size choice, as a number.
    ///
    /// Everything in this type stays in **unscaled** points, the size the
    /// design frame is drawn at, and so does `NotchLayout`. Scaling at the
    /// source would mean threading a factor through forty constants and
    /// leaving each one no longer comparable to the frame it is quoted from.
    /// The multiplication happens once, at the two places that touch the
    /// screen: the panel's frame and the drawn content.
    /// The size the user asked for. Read `sizeScale` to draw with — merged into
    /// the display's own notch, the hardware answers instead.
    @Published var requestedScale: CGFloat = 1

    /// **The scale the notch is drawn at**, which is the setting everywhere
    /// except against the hardware's own notch — see `mergedScale`.
    ///
    /// Computed rather than assigned, and every measurement in this file goes
    /// through it. Keeping the override in a second property and remembering to
    /// use it at each of thirty call sites is the same mistake as `notchShape`
    /// documents: one that is missed draws a shape at one scale with its
    /// contents laid out at another.
    var sizeScale: CGFloat {
        get { mergedScale ?? requestedScale }
        set { requestedScale = newValue }
    }
    /// Mirrors the persisted Appearance choice so the separate notch window
    /// redraws immediately when Settings changes it.
    @Published var accentColor: AccentColorChoice = .system
    /// Whether a provider's weekly limit gets a ring of its own, and where.
    /// Mirrored here for the same reason `accentColor` is: the notch is a
    /// separate window, and it has to redraw the moment Settings changes this.
    @Published var weeklyRing: WeeklyRing = .off
    @Published var weeklyRingDashed: Bool = false
    @Published var weeklyReading: Bool = false
    @Published var watchLimit: Double = 0.50
    @Published var criticalLimit: Double = 0.70
    /// Mirrored from Settings like `surfaceStyle`, just below.
    @Published var colorTransitionStyle: ColorTransitionStyle = .hardStep
    /// Whether the move handle is on the notch at all. Mirrored from Settings
    /// like `weeklyRing`.
    @Published var showsMoveHandle = true
    /// Mirrors the persisted Appearance choice so the separate notch window
    /// redraws immediately when Settings changes it.
    @Published var surfaceStyle: NotchSurfaceStyle = .glass
    /// Whether DeepSeek's billing phase rows are visible in its usage card.
    @Published var deepSeekPricingEnabled = true
    /// The rule used by the DeepSeek card, mirrored from Preferences so a
    /// settings change is reflected in every notch immediately.
    @Published var deepSeekPricingSchedule = DeepSeekPricing.Schedule.current
    /// Whether each ring carries its percentage beside the hardware notch.
    /// Mirrors the Appearance setting; see `showsCellReading`.
    @Published var showsNotchReadings = false
    /// Whether the notch reads what is left rather than what is spent.
    /// Mirrors the Appearance setting; the figure and the arcs' sweep follow
    /// it, the bands still judge by what is spent.
    @Published var showsRemainingInNotch = false
    /// Whether a spent window shuts the rings beside it. Mirrors the
    /// Appearance setting.
    @Published var shutRingsWhenSpent = true

    /// How much screen there is to spend on the panel.
    ///
    /// The tooltip's budget comes out of this: how many sessions a card can
    /// list before the panel holding it would run off the display. Zero until
    /// the controller says otherwise, which reads as "no screen known yet".
    @Published var screenSize: CGSize = .zero

    /// Visible slice of the panel along its edge, in local stack coordinates.
    @Published var visibleAlongRange: ClosedRange<CGFloat>?

    /// **Whether the notch is in the hand**: being ⌥-dragged, or on its way to
    /// where it was let go. Held, it is never joined to the hole — a joined
    /// notch is attached and cannot follow the pointer — and it is measured the
    /// plain way, its leading tip point for point with the pointer. See
    /// `NotchGeometry.cutoutFreelyNear`.
    @Published var holdsOffTheCutout = false

    /// The notch's length as a lone bar at the size that was asked for — what
    /// it is while it is in the hand, joined or not a moment before.
    var plainBarLength: CGFloat {
        NotchLayout.shapeLength(cellCount: snapshots.count, edge: edge, flare: flare,
                                spacing: cellSpacing(cellCount: snapshots.count))
            * requestedScale
    }

    /// How close the display's own hole is, or nil when there is none in reach.
    /// Set by `adopt(screen:)` and read by everything that has to know the
    /// notch is joined to something at its leading end.
    @Published var cutout: CutoutProximity?

    /// Where a ring's centre falls along the panel, on a given copy of the bar.
    func ringAlong(index: Int, in wing: Wing) -> CGFloat {
        wing.lead + ringCenter(index: index) * sizeScale
    }

    /// And how far along a copy a point in the panel is, in the notch's own
    /// measurements — nil when the point is not on that copy at all.
    func alongWithin(_ along: CGFloat, of wing: Wing) -> CGFloat? {
        guard along >= wing.lead - 0.001, along <= wing.lead + wing.length + 0.001
        else { return nil }
        return (along - wing.lead) / max(sizeScale, 0.0001)
    }

    func tooltipAlong(index: Int, length: CGFloat) -> CGFloat {
        let centre = ringAlong(index: index, in: cellWing)
        guard let range = visibleAlongRange else { return centre }
        let lower = range.lowerBound + length / 2
        let upper = range.upperBound - length / 2
        guard lower <= upper else { return (range.lowerBound + range.upperBound) / 2 }
        return min(max(centre, lower), upper)
    }

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Language change leaves snapshots untouched; tick `now` so copy
        // already on screen is redrawn against the new catalog.
        NotificationCenter.default.publisher(for: L10n.didChange)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.now = Date() }
            }
            .store(in: &cancellables)
    }

    /// Take the notch geometry of whichever screen the panel is on.
    ///
    /// The display's own cutout arrives as two numbers and no more — see
    /// `CutoutProximity`. There is no second layout here: the notch is one
    /// shape on all four edges, and what the hole gets a say in is where the
    /// top edge's panel starts (`NotchGeometry.panelFrame`) and how the leading
    /// end of that one shape joins it. A top edge that laid itself out around
    /// the hardware was a second design to keep working, and every measurement
    /// in it had to be kept in step with a shape it did not share.
    func adopt(screen: ScreenDescribing) {
        // `frame`, not `visibleFrame`: the panel is centred on the full screen
        // and may sit under the menu bar, so the menu bar is not room lost.
        // Whether anything of this has been on screen yet.
        let settled = screenSize != .zero
        let size = screen.frameValue.size
        if screenSize != size { screenSize = size }
        let near = NotchGeometry.cutoutProximity(
            for: screen, edge: edge, alongOffset: alongOffset,
            heldBar: holdsOffTheCutout ? plainBarLength : nil)
        let side = edge == .top && screen.hardwareNotch != nil
            && NotchGeometry.cutoutStanding(alongOffset: alongOffset).atTrailingEnd
        if leavesTheCutoutAtItsTrailingEnd != side { leavesTheCutoutAtItsTrailingEnd = side }
        guard cutout != near else { return }

        // **The one change worth animating is taking the hole or letting go of
        // it**, and nothing else here is that.
        //
        // This runs on every tick of an ⌥-drag, because how deep the notch is
        // buried changes with every delta of the pointer. Animated, each of
        // those tiny changes started a 0.62s spring, so the bar chased the
        // cursor on a long spring for the whole drag instead of tracking it —
        // which is most of what "still glitchy" was.
        //
        // And only while the window is standing still. It holds its size and
        // place across the join, but not across the notch drifting out of
        // reach of the hole entirely — and a frame is set in one step, so
        // easing anything while it moves is easing across the distance it
        // moved. Between two states the window is the same in, the depth, the
        // size and both ends ease together, which is the movement this is for.
        let joins = (cutout?.joined ?? false) != (near?.joined ?? false)
        let stillWindow = cutout != nil && near != nil
        guard settled, joins, stillWindow else {
            cutout = near
            return
        }
        withAnimation(NotchMotion.unfold) { cutout = near }
    }

    /// **Whether the notch is drawn as one shape with the display's own hole.**
    ///
    /// Not the same as having one nearby: `cutout` is reported for a way either
    /// side of the join, because the window is sized and placed the same on both
    /// sides of that answer and only what is drawn inside it changes.
    var mergesWithCutout: Bool { cutout?.joined == true }

    /// Which side of the hole the notch is on, whether or not it is joined to
    /// it right now.
    ///
    /// Joined, the pair is symmetric and there is no side; this is for the lone
    /// bar that comes out of the hole and goes back into it, which has to flow
    /// out of the wall it is actually leaving. Popping out to the right while
    /// drawing itself from the left is the one thing that reads as a flip.
    @Published var leavesTheCutoutAtItsTrailingEnd = false

    /// **What the contents need across the bar**, in the design's measurements.
    ///
    /// The open depth whether or not the notch is open: folding must not reflow
    /// the stack on its way out, and the shape is what conceals it.
    ///
    /// Merged into the display's own notch this is what the *cells* need rather
    /// than what the frame budgets, because the frame's figure reserves room for
    /// a reading whether or not one is drawn — and here every point of depth is
    /// spent at a scale the hardware fixes, so reserving depth for something
    /// that is switched off comes straight off the ring.
    var contentDepth: CGFloat {
        guard mergesWithCutout else { return NotchLayout.bodyDepth(for: edge) }
        return 2 * NotchLayout.ringMargin(for: edge)
            + (showsCellReading ? NotchLayout.cellExtent : NotchLayout.ringDiameter)
    }

    /// **The scale at which the notch is exactly the Mac's own notch.**
    ///
    /// Merged, the hardware sets the size and the setting does not come into it.
    /// The depth has to be the cutout's — one shape cannot be two thicknesses —
    /// and a notch whose depth is fixed while everything else follows the slider
    /// is not smaller or bigger, it is *distorted*: rings capped at the depth
    /// but spaced by the setting, padding for a bar three times as deep. So the
    /// whole shape is drawn at the one scale that lands its depth on the hole's,
    /// and every proportion in it is the design's.
    ///
    /// The bezel bleed is in it because the shape is pushed that far past the top
    /// of the screen: the row that has to land on the hole's bottom edge is that
    /// much further down the shape.
    var mergedScale: CGFloat? {
        guard let cutout, cutout.joined, contentDepth > 0 else { return nil }
        return (cutout.depth + NotchRootView.bezelBleed) / contentDepth
    }

    /// How much of the shape's leading end is buried in the hole, in the
    /// shape's own space.
    ///
    /// Length spent in there is length nobody sees, so the bar is drawn that
    /// much longer and everything measured along it starts that much further
    /// in — which is why this is the one number `shapeLength`, `ringCenter` and
    /// `cellsLeadIn` all add. Nothing when the two have been nudged apart: the
    /// bridge reaches back for the hole then, and the tip it reaches from is
    /// the visible start of the bar.
    var cutoutBleed: CGFloat {
        guard mergesWithCutout else { return 0 }
        return max(0, cutout?.overlap ?? 0) / max(sizeScale, 0.0001)
    }

    /// **What each end of the bar spends on its own ending**, before the body
    /// with the rings in it begins.
    ///
    /// A flare at both ends, as every edge has always had — plus, at the end
    /// that meets the hole, whatever of the bar is buried inside it, which is
    /// length nobody can see and so length the rings must not be measured from.
    var leadAllowance: CGFloat { flare + (carriedOnTheLeft ? 0 : cutoutBleed) }

    var endAllowance: CGFloat { flare + (carriedOnTheLeft ? cutoutBleed : 0) }

    /// **One drawn copy of the notch**, and where along the panel it starts.
    struct Wing: Identifiable, Equatable {
        /// **0 is always the copy that carries the readings; 1 is the other.**
        ///
        /// Never shared, and never reused for something else. Whatever a copy
        /// is — which side of the hole, whether it carries anything — it keeps
        /// for as long as it has that identity, so SwiftUI only ever animates a
        /// copy *moving* and never one copy turning into a different one. The
        /// carrying copy has one identity from the moment it is picked up to
        /// the moment it is put down, so a drag and its landing are one bar
        /// moving; the other copy arrives out of the hole and leaves into it.
        var id: Int
        /// Panel points, from the panel's own leading edge.
        var lead: CGFloat
        /// Whether this copy is on the left of the hole, which is the copy whose
        /// joined end is its trailing one. Drawn by `SideNotchShape` as its own
        /// shape, reflected in the path — never flipped by the view.
        var onTheLeft: Bool
        /// Whether this copy carries the readings. Only one does; the other is
        /// the container and nothing else.
        var carriesCells: Bool
        /// **How long this copy is drawn**, in panel points — and for the copy
        /// that carries nothing, how far the notch has widened.
        ///
        /// A length rather than a scale, which is what makes it the notch
        /// getting wider instead of a copy being stretched. Scaled, the copy was
        /// a squashed picture of itself; lengthened, it is drawn at every size it
        /// passes through, its corner the corner it will have, growing out of
        /// the wall it is welded to. And a number rather than a transition, so
        /// it changes with everything else about the notch and eases on the same
        /// spring from the same moment.
        var length: CGFloat
        /// How deep it is drawn, in the notch's own design measurements.
        var depth: CGFloat
    }

    /// **The room the panel keeps along the edge, beside the display's hole.**
    ///
    /// Deliberately the same whether the notch is joined to the hole or not, and
    /// that is the whole of why it is written from the *unjoined* bar at the
    /// size that was asked for: neither of those changes when the notch takes
    /// the hole. A joined bar is a little longer, for what is buried, and drawn
    /// a little smaller, because the hardware sets the size — the headroom
    /// covers the difference, and the window never has to move.
    ///
    /// A window frame is set in one step and cannot be animated. Anything
    /// inside it that eases while it moves is easing across the distance it
    /// moved, and joining moved it a third of the screen.
    func cutoutSpan(cellCount: Int) -> CGFloat {
        guard let cutout else { return shapeLength(cellCount: cellCount) * sizeScale }
        let plain = NotchLayout.shapeLength(cellCount: cellCount, edge: edge, flare: flare,
                                            spacing: cellSpacing(cellCount: cellCount))
        return cutout.width - 2 * NotchGeometry.cutoutOverlap
            + 2 * (plain * requestedScale + 2 * NotchGeometry.cutoutDeepest)
    }

    /// **Every drawn copy of the notch.**
    ///
    /// One, until it joins the display's own notch — then two, mirrored about
    /// the hole, because a bar hanging off one side of the cutout is not what
    /// the machine looks like. The pair reads as the hardware's own notch with
    /// the app either side of it rather than as something stuck to one edge of
    /// it, and it costs seeing each reading twice.
    var wings: [Wing] {
        let drawn = notchLength * sizeScale
        guard let cutout else {
            return [Wing(id: 0, lead: slack + (shapeLength * sizeScale - drawn) / 2,
                         onTheLeft: false, carriesCells: true,
                         length: drawn, depth: notchDepth)]
        }
        // Measured out from the hole's own centre, which is the panel's centre
        // too — see `NotchGeometry.panelFrame`. Each copy is welded to a wall
        // of the hole and draws back toward it as it shortens, so a copy on the
        // right starts at its wall and one on the left ends at its own.
        let middle = (cutoutSpan(cellCount: snapshots.count) + 2 * slack) / 2
        let half = cutout.width / 2
        func lead(onTheLeft: Bool, overlap: CGFloat, length: CGFloat) -> CGFloat {
            onTheLeft ? overlap - half - length + middle : half - overlap + middle
        }

        // The copy that carries the readings. Held, it is measured from the
        // right-hand wall point for point with the pointer, whichever side of
        // the hole it has been dragged to.
        let carryingLeft = mergesWithCutout ? cutout.atTrailingEnd
                                            : (holdsOffTheCutout ? false : cutout.atTrailingEnd)
        let carrying = Wing(id: 0,
                            lead: lead(onTheLeft: carryingLeft, overlap: cutout.overlap,
                                       length: drawn),
                            onTheLeft: carryingLeft, carriesCells: true,
                            length: drawn, depth: notchDepth)

        // **And the notch widening on the other side** — always exactly the
        // hole's depth, ending in the same curve as the side with the readings,
        // and only as long as the join says: nothing at all until the notch is
        // let go against the hole. It stays on the side opposite the one the carrying copy is
        // *on*, which keeps it from ever having to cross the hole to get there.
        let otherLeft = !carryingSide
        let otherOverlap = mergesWithCutout ? cutout.overlap : NotchGeometry.cutoutOverlap
        let widened = mergesWithCutout || revealsTheOtherCopy ? drawn : 0
        let other = Wing(id: 1,
                         lead: lead(onTheLeft: otherLeft, overlap: otherOverlap, length: widened),
                         onTheLeft: otherLeft, carriesCells: false,
                         length: widened,
                         depth: (cutout.depth + NotchRootView.bezelBleed) / max(sizeScale, 0.0001))
        return otherLeft ? [other, carrying] : [carrying, other]
    }

    /// Which side of the hole the copy that carries the readings is *on* —
    /// joined, the side it was put down on; in the hand, the side most of it is
    /// over, which is the side it will be put down on.
    private var carryingSide: Bool {
        guard let cutout else { return false }
        if mergesWithCutout || !holdsOffTheCutout { return cutout.atTrailingEnd }
        // Held: its leading tip is `overlap` inside the right wall, so its
        // middle is half a bar on from there.
        let bar = shapeLength * sizeScale
        return cutout.width / 2 - cutout.overlap + bar / 2 < 0
    }

    /// **The one curve goo takes between the hole and a dragged notch.**
    ///
    /// Flat along the hole's foot to the wall, then easing down to the bar's
    /// own foot on the smoother step — flat at both ends, so there is no crease
    /// against the hole and none against the bar — over the distance from the
    /// wall to a flare-and-a-corner past the bar's near end. Everything that
    /// shapes the notch near the hole while it is in the hand follows this: the
    /// bar's own dip where it reaches into the hole, and the strand across a
    /// gap. There used to be a mask cutting the bar as well, and wherever its
    /// cut crossed the bar's own curved end it left a point.
    var gooReach: CGFloat { (flare + drawnCornerRadius) * sizeScale }

    /// Whether each end of the bar in the hand is inside the hole's width.
    private var carryingEndsInTheHole: (near: Bool, far: Bool)? {
        guard let cutout else { return nil }
        let bar = cellWing
        let middle = (cutoutSpan(cellCount: snapshots.count) + 2 * slack) / 2
        let left = middle - cutout.width / 2, right = middle + cutout.width / 2
        let near = bar.lead, far = bar.lead + bar.length
        return (near > left && near < right, far > left && far < right)
    }

    /// **Where the bar in the hand dips to pass through the hole** — see
    /// `SideNotchShape.Dip`. In the bar's own measure, from its leading tip, and
    /// only while any of it is over the hole; eased out past a wall only where
    /// the bar reaches across that wall.
    var carryingDip: SideNotchShape.Dip? {
        guard holdsOffTheCutout, isExpanded, let cutout else { return nil }
        let bar = cellWing
        let middle = (cutoutSpan(cellCount: snapshots.count) + 2 * slack) / 2
        let half = cutout.width / 2
        let left = middle - half, right = middle + half
        let near = bar.lead, far = bar.lead + bar.length
        guard far > left, near < right else { return nil }
        let scale = max(sizeScale, 0.0001)
        return SideNotchShape.Dip(from: (left - near) / scale,
                                  to: (right - near) / scale,
                                  depth: (cutout.depth + NotchRootView.bezelBleed) / scale,
                                  reach: gooReach / scale,
                                  easesBefore: near < left && far > left,
                                  easesAfter: near < right && far > right)
    }

    /// **The strand of black between a dragged notch and the hole.**
    ///
    /// Goo pulled off a surface does not part from it: it stretches, thins in
    /// the middle, and lets go, and at no moment does it meet either surface at
    /// an angle. So the strand's underside always leaves the hole *along the
    /// hole's own outline* — its foot, then its rounded corner, then its wall —
    /// and arrives on the bar along the bar's own outline — its foot, its
    /// corner, its side, its flare — each time heading the way that outline is
    /// heading, so where one stops and the other starts there is nothing to
    /// see. Pulled away, the two points it leaves from climb those outlines, its
    /// middle thins up into the bezel, and each half draws back into the thing
    /// it came from until nothing is left.
    ///
    /// It used to be one curve scaled toward the bezel as it went. Scaled, its
    /// end at the hole was shallower than the hole's foot: it cut across the
    /// Mac's rounded corner, or met the hole's wall square, and it ran into the
    /// bar's side the same way — the points, and the corner that looked like
    /// it had lost its radius. Worked out from where the bar is, so it follows
    /// the hand with nothing to catch up on.
    struct Neck: Equatable {
        /// Along the panel: the hole's wall nearest the bar, and the bar's end
        /// facing it. `side` is 1 when the bar is right of the wall, −1 left.
        var wall: CGFloat
        var tip: CGFloat
        var side: CGFloat
        /// Down from the top of the screen: the hole's foot, and the radius of
        /// its corner.
        var holeDepth: CGFloat
        var holeCorner: CGFloat
        /// The bar's foot, and its end: the flare's reach and the corner's.
        var barDepth: CGFloat
        var barFlare: CGFloat
        var barCorner: CGFloat
        /// How far it has been pulled apart, 0 where the two touch to 1 where
        /// it lets go.
        var apart: CGFloat
    }

    var neck: Neck? {
        guard holdsOffTheCutout, isExpanded, let cutout else { return nil }
        let carrying = cellWing
        let middle = (cutoutSpan(cellCount: snapshots.count) + 2 * slack) / 2
        let half = cutout.width / 2
        // The wall nearest the bar, the bar's end that faces it, and its other.
        let onTheRight = carrying.lead + carrying.length / 2 >= middle
        let wall = onTheRight ? middle + half : middle - half
        let tip = onTheRight ? carrying.lead : carrying.lead + carrying.length
        let far = onTheRight ? carrying.lead + carrying.length : carrying.lead
        // A bar gone all the way into the hole has nothing out on this side.
        guard onTheRight ? far > wall : far < wall else { return nil }
        let gap = onTheRight ? tip - wall : wall - tip
        let stretch = NotchGeometry.cutoutStretch
        guard gap < stretch else { return nil }
        // The bar's end as `SideNotchShape` draws it, with no more room than
        // the bar has for it.
        let depth = max(cutout.depth, carrying.depth * sizeScale - NotchRootView.bezelBleed)
        let flare = min(self.flare * sizeScale, depth)
        let corner = max(0, min(drawnCornerRadius * sizeScale, depth - flare,
                                (carrying.length - 2 * flare) / 2))
        return Neck(wall: wall, tip: tip, side: onTheRight ? 1 : -1,
                    holeDepth: cutout.depth,
                    // Measured: a circular arc of 31.2px on a 90px-deep cutout.
                    holeCorner: cutout.depth * 31.2 / 90,
                    barDepth: depth, barFlare: flare, barCorner: corner,
                    apart: max(0, gap) / stretch)
    }

    /// **Whether the other copy is coming out of the hole ahead of the join.**
    ///
    /// Set the moment a dragged notch is let go near the hole, so the other copy
    /// starts flowing out of its wall *while* the carrying copy glides to its
    /// own, rather than after it has arrived. The join then finds it already on
    /// its way and simply carries on.
    @Published var revealsTheOtherCopy = false

    /// Where the first drawn copy starts along the panel.
    var notchAlongLead: CGFloat { wings.first?.lead ?? slack }

    /// The copy that carries the readings. Rings, hover bands, tooltips and
    /// handles all belong to it; the other is the container and nothing else.
    var cellWing: Wing {
        wings.first { $0.carriesCells }
            ?? Wing(id: 0, lead: slack, onTheLeft: false, carriesCells: true,
                    length: notchLength * sizeScale, depth: notchDepth)
    }

    /// The copy the settings handle and the move handle hang off — one set of
    /// handles, not two, however many copies of the bar there are.
    var handleWing: Wing { cellWing }

    /// Whether the copy that carries everything is the one on the left of the
    /// hole, which turns its ends round: its joined end is its trailing one.
    ///
    /// Read from the cutout, which is where `wings` reads it too — and never
    /// from `wings`, which needs the bar's length to place the copies, whose
    /// length needs this. Asked the other way round it is a loop with no floor.
    var carriedOnTheLeft: Bool { mergesWithCutout && cutout?.atTrailingEnd == true }

    /// Where the folded notch starts along the panel, whatever state it is in
    /// right now — the hit region that wakes it has to know where it will be.
    var restingAlongLead: CGFloat {
        guard cutout == nil else {
            return wings.first { $0.length > 0 }?.lead ?? slack
        }
        return slack + (shapeLength - restingLength) * sizeScale / 2
    }

    /// How far the drawn notch reaches along the panel, from the first copy's
    /// start to the last one's end. The pair and the hole between them.
    var drawnAlongExtent: CGFloat {
        let shown = wings.filter { $0.length > 0 }
        guard let first = shown.first, let last = shown.last else {
            return notchLength * sizeScale
        }
        return last.lead + last.length - first.lead
    }

    /// How much of the hardware's own height a ring may use, as a fraction of
    /// the design ring.
    ///
    /// The strips either side are the menu bar's height — 38pt on the current
    /// hardware — where a design ring is 44pt and a whole cell, with its
    /// percentage below it, is about 67pt. So the ring shrinks to fit between
    /// the bezel and the hole's bottom edge, and the percentage goes: there is
    /// no second line to put it on.
    /// Where the first cell starts inside the shape.
    ///
    /// The one source for it. `ringCenter` and the view's own leading padding
    /// used to compute this separately, and in the split layout they disagreed
    /// by 14.5pt — so the shape was positioned by one number and the rings
    /// drawn at another, which put them back under the cutout however carefully
    /// the shape was placed.
    var cellsLeadIn: CGFloat {
        leadAllowance + NotchLayout.padStart(for: edge)
    }


    /// **The notch's shape, configured.** Build it here and nowhere else.
    ///
    /// Five separate bugs in this redesign were the same bug: something worked
    /// out its own version of what the shape should be, and the tests agreed
    /// with it because they built their own too — so a green suite described a
    /// shape that was never on screen. A `SideNotchShape()` with four
    /// properties left at their defaults is a different object from the one
    /// the view draws, and there is no way to see that at the call site.
    var notchShape: SideNotchShape { notchShape(for: cellWing) }

    /// The shape one copy is drawn as.
    ///
    /// **The join is drawn only while the notch is joined.** It was drawn
    /// whenever the hole was merely *near*, and the joined end is a square tip
    /// and a flat run at the hole's own depth — invisible inside the hole, the
    /// only reason it may be square, and a hard cut edge hanging on the
    /// wallpaper anywhere else. Near but not joined, the notch is a notch.
    func notchShape(for wing: Wing) -> SideNotchShape {
        var shape = SideNotchShape(edge: edge)
        shape.cornerRadius = drawnCornerRadius
        // Every edge, not only the hardware one. `bezelBleed` pushes the shape
        // past the screen's edge on all four — see `NotchRootView` — so on all
        // four the flare used to begin off-screen and arrive already part way
        // through its turn, cut off by the border rather than meeting it. It
        // showed up first beside the cutout because that sweep is shallow, but
        // a 33pt flare spends a third of its length in those two points.
        shape.bezelHidden = NotchRootView.bezelBleed / max(sizeScale, 0.0001)
        guard let cutout else { return shape }
        shape.reflected = wing.onTheLeft

        // **The copy that carries the readings eases into the join.** Its end
        // at the hole closes up from flare to square as a number, on the same
        // spring as its depth and its size, rather than being swapped for the
        // joined end in one frame — see `SideNotchShape.leadingJoin`. Square at
        // the hole's own depth, with the tip inside the hole, *is* the joined
        // end, so there is nothing else to draw.
        // **Both sides end with the notch's own curve** — the flare into the
        // bezel and the corner below it, the end this shape has everywhere.
        // Joined, the side with the readings keeps it, and the other side has
        // exactly the same one, so the pair balances about the hole.
        if wing.carriesCells {
            shape.leadingJoin = cutout.joined ? 1 : 0
            shape.dip = carryingDip
            // In the hand, an end that has gone into the hole closes square at
            // the hole's depth, like a joined end does. Left curved, it covered
            // only the top of the hole's rounded corner and a wedge of wallpaper
            // showed in the rest, sliding with the pointer. It changes over
            // inside the hole, where neither shape of it can be seen.
            if holdsOffTheCutout, let (nearIn, farIn) = carryingEndsInTheHole {
                shape.leadingJoin = nearIn ? 1 : 0
                shape.trailingJoin = farIn ? 1 : 0
            }
            return shape
        }

        // The other side: joined at its wall, and at its far end the same curve
        // as the side with the readings — put on as it comes out of the hole.
        shape.leadingJoin = 1
        let scale = max(sizeScale, 0.0001)
        shape.emergesFrom = .init(
            buried: (mergesWithCutout ? cutout.overlap : NotchGeometry.cutoutOverlap) / scale,
            // Measured: a circular arc of 31.2px on a 90px-deep cutout.
            corner: cutout.depth * 31.2 / 90 / scale)
        return shape
    }

    /// **Whether each ring carries its percentage in the strip.**
    ///
    /// At the cutout's own depth one ring fills the bar, and a second line
    /// would be drawn into the bezel — so beside the hardware there is none,
    /// and the reading is a hover away in the card. Raise the size setting far
    /// enough and the bar deepens with it; once the reading would come out at
    /// a legible height it is drawn.
    ///
    /// Measured against what the reading *would* be, not against the ring, so
    /// **Whether a cell carries its percentage**, on any edge.
    ///
    /// One setting, everywhere. Beside the hardware it costs something: a ring
    /// and its reading need 79pt of depth between them where the cutout gives
    /// 38, so the reading is paid for out of the ring — which drops from 44pt
    /// to around 30 at the top of the size range, and smaller below it. That
    /// is a trade to offer rather than to make, and there is no floor under it:
    /// asked for, it is drawn, however small the strip leaves it.
    var showsCellReading: Bool {
        showsNotchReadings
    }

    /// How much of each end of the bar the flare actually takes.
    var flare: CGFloat { NotchLayout.curlRadius }

    /// The corner the shape actually draws at its far end.
    ///
    /// Not always `cornerRadius`: a bar drawn as the hardware notch caps it at
    /// the hardware's own rounding, so that the shape is the same at rest as it
    /// is open. Everything the orb does hangs off this rather than off the
    /// nominal figure — the orb traces the corner that is drawn, not the one
    /// that was asked for.
    var drawnCornerRadius: CGFloat {
        NotchLayout.cornerRadius
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
            ? NotchLayout.orbConvexArcRadius(corner: drawnCornerRadius, scale: orbScale)
            : NotchLayout.orbArcRadius
    }

    /// Where the settings orb sits.
    ///
    /// Ordinarily it is concentric with the far flare, one radius in from the
    /// bezel and level with the end of the shape. A flush bar has no flare, so
    /// it hugs the bar's own bottom-end corner from outside instead — same
    /// idea, turned inside out. Left where it was it becomes a dot on the
    /// bar's flat edge.
    var orbHugsCorner: Bool { false }

    /// How much of its drawn size the settings orb — and the move handle that
    /// mirrors it — keeps.
    ///
    /// Full size everywhere except beside the hardware. There the disc is very
    /// nearly as wide as the bar is deep, because every one of its numbers was
    /// chosen against a stack some 30pt deeper: hung off a 38pt strip at that
    /// size it reads as an arc floating in the wallpaper with nothing to hug,
    /// which is what it was doing. Shrinking the whole orb by the ratio of the
    /// two depths keeps the relationship — clear of the corner by `orbGap`,
    /// taken diagonally — and changes only how big it is.
    ///
    /// The corner it hangs off is deliberately not scaled by this. That one
    /// belongs to the hardware.
    /// Drawn a ring's size, because it sits in the same strip the rings do —
    /// the gear is their sibling there, not a fixture of a taller stack.
    var orbScale: CGFloat { 1 }

    var orbAlong: CGFloat {
        // Never into the hole: on the left of it, the settings handle hangs
        // off the copy's *leading* tip, which is its outer one there.
        guard orbHugsCorner else { return carriedOnTheLeft ? 0 : shapeLength }
        return cornerCentreAlong
            + NotchLayout.orbCornerOffset(corner: drawnCornerRadius, scale: orbScale)
    }

    /// Reserve the full hit area even while only the resting arc is visible,
    /// so revealing the settings button cannot put it beyond the screen.
    var trailingExtent: CGFloat {
        (max(0, orbAlong - shapeLength + orbHotZone / 2) * sizeScale).rounded(.up)
    }

    /// The handle's reach, which has to follow the handle's size: a hot zone
    /// wider than the bar is deep sits over the rings and eats their clicks.
    var orbHotZone: CGFloat { NotchLayout.orbHotZone * orbScale }

    /// Where the move handle sits: the settings orb's position mirrored to the
    /// near end of the stack. Measured back from zero the same distance the
    /// orb sits past `shapeLength`, so the pair stay symmetric about the notch
    /// at every size and on every edge.
    var moveAlong: CGFloat {
        guard !carriedOnTheLeft else { return shapeLength - cutoutBleed }
        return cutoutBleed + shapeLength - orbAlong
    }

    /// The mirror of `trailingExtent` at the near end — the room the move
    /// handle needs before the notch's own start.
    ///
    /// Nothing when the handle is switched off, unlike `trailingExtent`: the
    /// settings orb is always there to be revealed, but a hidden handle is
    /// hidden for the session. Reserving its room anyway kept the notch from
    /// sliding to the leading end of its edge, which is a place ⌥-drag is
    /// meant to reach.
    var leadingExtent: CGFloat {
        guard showsMoveHandle else { return 0 }
        return (max(0, -moveAlong + orbHotZone / 2) * sizeScale).rounded(.up)
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
        NotchLayout.orbInsetFromEdge
    }

    /// The arc's radius and offset **as the orb's own view needs them**.
    ///
    /// That view is drawn inside `.scaleEffect(sizeScale * orbScale)`, so it
    /// scales everything handed to it. These two must not be scaled by
    /// `orbScale`: the arc is concentric with the bar's corner and one gap
    /// outside it, and that corner belongs to the hardware, not to the orb.
    /// Passed raw they were shrunk a second time and the arc drifted off the
    /// corner — which is what "the arc line is way too far" was.
    var orbArcRadiusInOrbSpace: CGFloat { orbArcRadius / max(orbScale, 0.0001) }
    var orbArcOffsetInOrbSpace: CGSize { divided(orbArcOffset) }
    var moveArcOffsetInOrbSpace: CGSize { divided(moveArcOffset) }

    private func divided(_ size: CGSize) -> CGSize {
        let by = max(orbScale, 0.0001)
        return CGSize(width: size.width / by, height: size.height / by)
    }

    var orbArcOffset: CGSize {
        guard orbHugsCorner else { return .zero }
        let inward = CGPoint(x: -edge.outward.x, y: -edge.outward.y)
        let back = -NotchLayout.orbCornerOffset(corner: drawnCornerRadius, scale: orbScale)
        return CGSize(width: back * (edge.alongDirection.x + inward.x),
                      height: back * (edge.alongDirection.y + inward.y))
    }

    /// `orbArcOffset` mirrored: the move handle hangs off the near corner, so
    /// its arc tucks back *forward* along the stack rather than backward.
    var moveArcOffset: CGSize {
        guard orbHugsCorner else { return .zero }
        let inward = CGPoint(x: -edge.outward.x, y: -edge.outward.y)
        let forward = NotchLayout.orbCornerOffset(corner: drawnCornerRadius, scale: orbScale)
        return CGSize(width: forward * (edge.alongDirection.x - inward.x),
                      height: forward * (edge.alongDirection.y - inward.y))
    }

    /// The centre of a ring measured across the notch, in stack space.
    ///
    /// One place, because there were two: the stacked layout centres a ring in
    /// `bodyDepth` below the hardware's band, and beside the hardware there is
    /// no band and the bar is the hole's own depth. Anything working the first
    /// formula out for itself lands below the bar entirely at most sizes.
    var ringAcross: CGFloat {
        contentDepth / 2
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
        let radius = orbHotZone / 2
        return orbHandlePoints.contains {
            hypot(along - $0.x, across - $0.y) <= radius
        }
    }

    /// The move handle's own points, mirroring `orbHandlePoints` at the near
    /// end of the stack.
    var moveHandlePoints: [CGPoint] {
        // No points, not merely no drawing. Every way of reaching the handle —
        // hover, a press, and the window's own click-through region — is
        // measured from these, so a hidden handle has to report none or it
        // leaves an invisible spot that still starts a move.
        guard showsMoveHandle else { return [] }
        let button = CGPoint(x: moveAlong, y: orbInset)
        guard orbHugsCorner else { return [button] }

        let arcCentre = CGPoint(x: moveAlong + moveArcOffset.width,
                                y: orbInset + moveArcOffset.height)
        let reach = hypot(button.x - arcCentre.x, button.y - arcCentre.y)
        guard reach > 0 else { return [button] }
        let arcMid = CGPoint(
            x: arcCentre.x + orbArcRadius * (button.x - arcCentre.x) / reach,
            y: arcCentre.y + orbArcRadius * (button.y - arcCentre.y) / reach
        )
        return [button, arcMid]
    }

    func isOnMoveHandle(along: CGFloat, across: CGFloat) -> Bool {
        let radius = orbHotZone / 2
        return moveHandlePoints.contains {
            hypot(along - $0.x, across - $0.y) <= radius
        }
    }


    /// Where the tooltip's tail tip sits, measured in from the bezel: just off
    /// the inner face of a shape that the extension has made deeper.
    var tooltipInset: CGFloat {
        notchDrawnDepth + NotchLayout.tailGap
    }

    /// How deep the notch body reaches on screen — the design-frame depth at
    /// the size it is actually drawn.
    ///
    /// Where the notch ends is where the tooltip begins, and the tooltip is not
    /// drawn at that size, so this is the seam between the two spaces rather
    /// than a measurement either of them owns.
    var notchDrawnDepth: CGFloat {
        NotchLayout.bodyDepth(for: edge) * sizeScale
    }

    /// The straight part of the shape, flares excluded.
    var bodyLength: CGFloat {
        NotchLayout.bodyLength(
            cellCount: snapshots.count, edge: edge, spacing: cellSpacing
        )
    }

    /// Distance along the stack to cell `index`'s ring centre, widening
    /// included so the readings stay in the middle of the bar.
    func ringCenter(index: Int) -> CGFloat {
        NotchLayout.ringCenter(index: index, edge: edge, flare: leadAllowance,
                               spacing: cellSpacing)
    }

    var cellSpacing: CGFloat { cellSpacing(cellCount: snapshots.count) }
    /// Centre-to-centre distance between cells, which is also the width of the
    /// band `cellIndex(along:)` treats as belonging to one.
    var cellPitch: CGFloat {
        NotchLayout.cellAlong(for: edge) + cellSpacing
    }

    private func cellSpacing(cellCount: Int) -> CGFloat {
        guard edge.isVertical, screenSize.height > 0, cellCount > 1 else {
            return NotchLayout.cellSpacing
        }
        // Extra model cells spend the gaps first. Reserve the cards actually
        // present; assuming four quota windows for every local model overflows laptops.
        let slack = NotchLayout.slack(for: edge,
            maxCardHeight: snapshots.isEmpty ? NotchLayout.maxCardHeight(sessionCap: 0)
                : contentCardHeight(sessionCap: 0),
            notchScale: sizeScale)
        let packed = NotchLayout.shapeLength(cellCount: cellCount, edge: edge,
                                             flare: flare, spacing: 0)
        return min(NotchLayout.cellSpacing,
                   max(0, ((screenSize.height - 2 * slack) / sizeScale - packed) / CGFloat(cellCount - 1)))
    }

    /// A provider with no activity source gets none, rather than borrowing
    /// somebody else's.
    func activity(for snapshot: ProviderSnapshot) -> ActivitySummary? {
        guard let model = snapshot.localModel else { return activity(for: snapshot.providerID) }
        if let local = localActivities[snapshot.id] {
            return ActivitySummary(sessions: [AgentSession(id: snapshot.id, name: local.label,
                detail: snapshot.displayName, state: .busy, waitingFor: nil, since: local.since)],
                queued: local.queued, note: local.note)
        }
        guard let since = thinkingModels[OllamaThinkingStream.modelKey(model.name)] else { return nil }
        return ActivitySummary(sessions: [AgentSession(id: snapshot.id, name: L10n.t("Thinking"),
            detail: snapshot.displayName, state: .busy, waitingFor: nil, since: since)])
    }

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
        NotchLayout.slack(for: edge,
                          maxCardHeight: maxCardHeight(cellCount: cellCount),
                          notchScale: sizeScale)
    }

    /// How many sessions a tooltip may list here before it has to summarise
    /// the rest — as many as this screen has room for.
    var sessionCap: Int { sessionCap(cellCount: snapshots.count) }

    private var hasTokenUsage: Bool {
        snapshots.contains { $0.tokenUsage != nil }
    }

    private var hasPlan: Bool {
        snapshots.contains { $0.plan != nil }
    }

    private var hasResetCredits: Bool {
        snapshots.contains(where: \.hasAvailableResetCredits)
    }

    func sessionCap(cellCount: Int) -> Int {
        guard screenSize != .zero else { return NotchLayout.defaultSessionCap }
        return NotchLayout.sessionsFitting(cardBudget: cardBudget(cellCount: cellCount),
                                           windowCount: NotchLayout.maxWindowCount,
                                           hasTokenUsage: hasTokenUsage,
                                           hasPlan: hasPlan,
                                           hasResetCredits: hasResetCredits)
    }

    private func contentCardHeight(sessionCap: Int) -> CGFloat {
        snapshots.map { snapshot in
            NotchLayout.cardHeight(windowCount: snapshot.windows.count,
                groupCount: Set(snapshot.windows.compactMap(\.group)).count,
                moneyWindowCount: snapshot.windows.filter { $0.money != nil }.count,
                usageDetailGroupCount: snapshot.usageDetail?.visibleGroups.count ?? 0,
                sessionCount: snapshot.localModel == nil ? sessionCap + 1 : 0,
                sessionCap: sessionCap,
                statusMessage: snapshot.statusMessage,
                blockMessage: snapshot.block?.summary(now: now),
                hasTokenUsage: snapshot.tokenUsage != nil,
                hasPlan: snapshot.plan != nil,
                hasResetCredits: snapshot.hasAvailableResetCredits,
                localModelName: snapshot.localModel?.name,
                showsLocalPerformance: snapshot.showsLocalPerformance,
                localLedgerRows: snapshot.localLedgerRowCount,
                compactRowCount: snapshot.compactRowCount,
                showsDeepSeekPricing: deepSeekPricingEnabled)
        }.max() ?? 0
    }

    func maxCardHeight(cellCount: Int) -> CGFloat {
        let cap = sessionCap(cellCount: cellCount)
        return snapshots.isEmpty
            ? NotchLayout.maxCardHeight(sessionCap: cap, hasTokenUsage: hasTokenUsage, hasPlan: hasPlan,
                                        hasResetCredits: hasResetCredits)
            : contentCardHeight(sessionCap: cap)
    }

    /// How tall the tallest card may be before the panel runs off the screen.
    ///
    /// Which way it runs out differs by orientation, because the card's height
    /// is spent on a different axis: along a side edge it is spent *along* the
    /// stack, half of it past each end, so the stack itself takes its share
    /// first. Along a horizontal edge the card hangs *inward* instead, and what
    /// it competes with is the depth already spent on the notch body and tail.
    /// The screen is measured in real points, and everything it is compared
    /// against here is unscaled. Dividing brings the screen into the same space
    /// rather than scaling the four constants below it: at `large` a card sized
    /// against the raw height would be drawn a quarter taller than it was
    /// budgeted for, and run off the bottom of a small display.
    private func cardBudget(cellCount: Int) -> CGFloat {
        if edge.isVertical {
            return screenSize.height / sizeScale
                - shapeLength(cellCount: cellCount)
                - 2 * NotchLayout.cardCorner
        }
        return screenSize.height / sizeScale
            - NotchLayout.bodyDepth(for: edge)
            - NotchLayout.tailLength
            - NotchLayout.tailGap
    }

    /// The drawn extent of the notch body right now, along the stack.
    var notchLength: CGFloat {
        if isExpanded { return shapeLength }
        return restingLength
    }

    /// And across it. Merged into the hole this is the hole's own depth in both
    /// states — see `mergedScale`.
    var notchDepth: CGFloat {
        if mergesWithCutout { return contentDepth }
        return isExpanded ? NotchLayout.bodyDepth(for: edge) : NotchLayout.pillWidth
    }

    /// What the notch folds away to, whether or not it is open right now —
    /// the hit region has to know that while the notch is still open.
    ///
    /// The same pill on every edge, plus whatever of it is buried in the
    /// display's hole, so that the part of it anybody can see is the same pill
    /// too. Folded against the hole it is not a separate tab stuck to the
    /// bezel: the bridge holds, and what shows is the hardware's own notch
    /// carrying a shallow ledge out of one side.
    var restingLength: CGFloat { NotchLayout.pillHeight + cutoutBleed }
    var restingDepth: CGFloat { mergesWithCutout ? contentDepth : NotchLayout.pillWidth }

    /// What wakes the folded notch, in panel points: the resting shape and a
    /// band around it, or the resting shape alone.
    ///
    /// The band is for the pill. A 10pt sliver on a screen edge is a fiddly
    /// target, and the only cost of surrounding it is that it opens a little
    /// eagerly. Joined to the hardware notch the band is a different matter:
    /// the notch is already a generous target, and a band around it reached
    /// 34pt *below* the menu bar — across the title bar of a window tiled
    /// against the centre of the screen, whose close, minimise and zoom
    /// buttons then opened the notch on approach and disappeared under it.
    var wakeLength: CGFloat { max(restingLength * sizeScale, wakeBand) }
    var wakeDepth: CGFloat {
        restingDepth * sizeScale + (mergesWithCutout ? 0 : wakeBand)
    }
    private var wakeBand: CGFloat { NotchLayout.pillHotZone }

    /// The drawn size of the notch body, in panel axes.
    var notchSize: CGSize {
        NotchPlacement.panelSize(edge: edge, length: notchLength, depth: notchDepth)
    }

    /// Sized from an explicit count rather than from `snapshots`.
    ///
    /// `@Published` notifies its subscribers in `willSet`, so a sink reacting to
    /// a change in the provider list still sees the *old* array if it reads the
    /// model back. Taking the count as an argument is the only way to be sure
    /// the panel is sized for the list that caused the change.
    func shapeLength(cellCount: Int) -> CGFloat {
        NotchLayout.bodyLength(cellCount: cellCount, edge: edge,
                               spacing: cellSpacing(cellCount: cellCount))
            + leadAllowance + endAllowance
    }

    /// The panel as it lands on screen, size choice included.
    ///
    /// Two spaces, added rather than multiplied together: the notch is drawn at
    /// `sizeScale`, and the tooltip is drawn at one size whatever the notch is
    /// set to — its text has a legible size of its own, and shrinking the
    /// reading you opened the notch to read is the opposite of the point.
    ///
    /// So the notch's share scales and the card's share does not. Scaling the
    /// whole panel instead left the card cropped at the small end, where the
    /// panel had shrunk around a card that had not.
    func panelSize(cellCount: Int) -> CGSize {
        let card = maxCardHeight(cellCount: cellCount)
        return NotchPlacement.panelSize(
            edge: edge,
            length: cutoutSpan(cellCount: cellCount)
                + 2 * NotchLayout.slack(for: edge, maxCardHeight: card, notchScale: sizeScale),
            depth: NotchLayout.bodyDepth(for: edge) * sizeScale
                + NotchLayout.tooltipDepth(for: edge, maxCardHeight: card)
        )
    }
}
