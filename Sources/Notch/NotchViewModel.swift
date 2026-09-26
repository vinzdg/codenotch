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
    @Published var hoveredIndex: Int? {
        // Opened idle sessions last as long as that ring's tooltip does.
        didSet { if hoveredIndex != oldValue { showsIdleSessions = false } }
    }
    /// Ticked on refresh so the "Resets in N min" copy stays honest.
    @Published var now: Date = Date()
    @Published var resetTimeFormat: ResetTimeFormat = .automatic

    /// Active usage reset notification event to present beside the notch.
    @Published var activeResetAlert: UsageResetEvent?
    /// Stopped sessions waiting to be looked at, oldest first — see
    /// `CompletionQueue`. The first is on screen, behind any permission card.
    @Published var completions: [SessionCompletionWatcher.Event] = []
    var activeCompletion: SessionCompletionWatcher.Event? { completions.first }
    /// Wired by the app delegate: jump to the session and clear its card.
    var onOpenCompletion: ((SessionCompletionWatcher.Event) -> Void)?
    /// The pointer is on the completion card.
    @Published var isHoveringCompletion = false

    /// The ring a completed session belongs to; the first when it is not shown.
    func completionIndex(for event: SessionCompletionWatcher.Event) -> Int {
        snapshots.firstIndex { $0.providerID == event.providerID } ?? 0
    }

    /// What Claude Code is waiting on the notch for, oldest first. The first
    /// one is on screen; the notch stays open until the list is empty.
    @Published var permissionRequests: [PermissionRequest] = []
    /// Wired to `HookBridge.answer` by the app delegate.
    var onDecidePermission: ((UUID, PermissionDecision) -> Void)?
    /// Which question of the showing `AskUserQuestion` is up; back to the
    /// first whenever a different request comes to the front.
    @Published var permissionQuestionIndex = 0
    /// The permission card's choice row under the pointer, set by the controller.
    @Published var hoveredChoice: Int?
    /// The pointer is on the card's "Answer in <app>" button.
    @Published var isHoveringAppLink = false

    /// The Claude ring, which the card points at. The first cell when Claude
    /// is not in the notch at all — the request still needs somewhere to go.
    var permissionIndex: Int {
        snapshots.firstIndex { $0.providerID == "claude" } ?? 0
    }

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
    /// The clickable session row under the pointer, set by the controller.
    @Published var hoveredSessionID: String?
    /// The tooltip's "N idle" line was clicked open. Back to folded whenever
    /// the tooltip closes, so the list is calm each time it is opened.
    @Published var showsIdleSessions = false
    /// The pointer is on that line.
    @Published var isHoveringIdleToggle = false
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
    @Published var sizeScale: CGFloat = 1
    /// Mirrors the persisted Appearance choice so the separate notch window
    /// redraws immediately when Settings changes it.
    @Published var accentColor: AccentColorChoice = .system
    /// Whether a provider's weekly limit gets a ring of its own, and where.
    /// Mirrored here for the same reason `accentColor` is: the notch is a
    /// separate window, and it has to redraw the moment Settings changes this.
    @Published var weeklyRing: WeeklyRing = .off
    @Published var weeklyRingDashed: Bool = false
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
    /// Mirrors the Appearance setting; see `splitShowsReading`.
    @Published var showsNotchReadings = false

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

    /// Visible slice of the panel along its edge, in local stack coordinates.
    @Published var visibleAlongRange: ClosedRange<CGFloat>?

    func tooltipAlong(index: Int, length: CGFloat) -> CGFloat {
        let centre = slack + ringCenter(index: index) * sizeScale
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
    func adopt(screen: ScreenDescribing) {
        let merging = edge == .top ? screen.hardwareNotch : nil
        if hardwareNotch != merging { hardwareNotch = merging }
        // `frame`, not `visibleFrame`: the panel is centred on the full screen
        // and may sit under the menu bar, so the menu bar is not room lost.
        let size = screen.frameValue.size
        if screenSize != size { screenSize = size }
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
    var contentInset: CGFloat { splitsAroundHardwareNotch ? 0 : (hardwareNotch?.height ?? 0) }

    // MARK: - Sitting either side of the hardware notch

    /// Whether the readings sit *beside* the hole rather than below it.
    ///
    /// Only where there is a hole to sit beside: an external display, or a Mac
    /// without one, has nothing to split around and keeps the bar.
    var splitsAroundHardwareNotch: Bool { edge == .top && hardwareNotch != nil }

    /// How many cells go to the left of the hole. The odd one goes left, so
    /// three readings are two and one rather than one and two — the eye starts
    /// at the left strip.
    var splitLeftCount: Int { (snapshots.count + 1) / 2 }

    /// The hole's width, in design-frame units.
    ///
    /// Divided by `sizeScale` because every length here is multiplied by it
    /// again on the way to the screen, and the hole is hardware: it does not
    /// widen because someone chose a bigger notch.
    var splitGap: CGFloat {
        guard splitsAroundHardwareNotch, let notch = hardwareNotch, sizeScale > 0 else { return 0 }
        // The hardware's width plus clearance at each end. The reported width
        // is the cutout at its widest; its corners curve in from there, so a
        // ring flush against that number is still under the curve.
        return (notch.width + 2 * NotchLayout.splitHoleClearance) / sizeScale
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
        flare + endSpread
            + (splitsAroundHardwareNotch
               ? splitEndPads(cellCount: snapshots.count).left
               : NotchLayout.padStart(for: edge))
    }

    /// Spacing between cells as the view must draw them.
    var drawnCellSpacing: CGFloat {
        splitsAroundHardwareNotch ? splitCellSpacing : cellSpacing
    }

    /// Bar either side of the outermost rings, when they sit beside the hole.
    ///
    /// The edge's own `padStart`/`padEnd` are the stacked layout's margins and
    /// are about 22pt each — more bar than ring, next to a 30pt one. This is
    /// the same clearance the ring gets above and below it, so the shape reads
    /// as hugging them.
    /// The ring as it is actually drawn, in screen points.
    var splitDrawnRing: CGFloat {
        NotchLayout.ringDiameter * splitCellScale * sizeScale
    }

    /// The whole cell as drawn — the ring, plus its reading where there is one.
    var splitDrawnCell: CGFloat {
        splitCellExtent * splitCellScale * sizeScale
    }

    /// Clear space above and below the ring, in screen points. Whatever the
    /// bar has left over once the ring is placed in it.
    var splitDrawnMargin: CGFloat { max(0, (splitDrawnDepth - splitDrawnCell) / 2) }

    /// Bar beyond the outermost ring.
    ///
    /// The vertical margin *plus* however far the rounded corner has cut into
    /// the side by the time it reaches the ring. Matching the margin alone was
    /// only equal on paper: the corner curves inward across the bottom of the
    /// end, so a ring placed at the bare margin sits inside the curve with
    /// barely a point of real clearance while its top has the full margin.
    var splitEndPad: CGFloat {
        (splitDrawnMargin + splitCornerIntrusion) / max(sizeScale, 0.0001)
    }

    /// How far the bottom corner has eaten into the side at the ring's lowest
    /// point — the sagitta of the arc at that height.
    var splitCornerIntrusion: CGFloat {
        let corner = drawnCornerRadius * sizeScale
        let margin = splitDrawnMargin
        guard corner > 0, margin < corner else { return 0 }
        let dy = corner - margin
        return corner - (corner * corner - dy * dy).squareRoot()
    }

    /// Between rings in a strip. The stacked layout's spacing is about 31pt,
    /// which is as wide as the ring itself once the ring has shrunk to 30.
    /// Between rings. Proportional to the ring rather than fixed, so the run
    /// keeps its rhythm as the ring grows.
    var splitCellSpacing: CGFloat {
        NotchLayout.ringDiameter * splitCellScale * NotchLayout.splitSpacingRatio
    }

    /// How far the rings reach either side of the hole.
    ///
    /// The *same* distance on both sides, even when one side holds more rings.
    /// The panel is centred on the screen and the hole is centred in the
    /// hardware, so the only way the gap lands on the hole is for the two sides
    /// to be equal — otherwise the shape's middle drifts off the hardware's
    /// middle and the rings nearest the gap are drawn behind the cutout.
    var splitSideExtent: CGFloat { splitSideExtent(cellCount: snapshots.count) }

    /// Sized from an explicit count for the same reason `shapeLength(cellCount:)`
    /// is: `@Published` notifies in `willSet`, so a sink reacting to the provider
    /// list still reads the old array back.
    func splitSideExtent(cellCount: Int) -> CGFloat {
        splitWidths(cellCount: cellCount).left
    }

    /// What each side of the hole actually needs, hugging its own rings.
    ///
    /// Not padded to the wider of the two: reserving the long side's width on
    /// the short one draws empty bar, which is what made a single ring sit in
    /// the middle of a shape twice as wide as it needed to be. The shape is
    /// shifted instead — see `splitShift` — so the gap still lands on the hole.
    /// End bar beyond the outermost ring on each side. A side with no rings at
    /// all gets none — one ring should not put an empty tab on the far side.
    func splitEndPads(cellCount: Int) -> (left: CGFloat, right: CGFloat) {
        let w = splitWidths(cellCount: cellCount)
        return (w.left > 0 ? splitEndPad : 0, w.right > 0 ? splitEndPad : 0)
    }

    func splitWidths(cellCount: Int) -> (left: CGFloat, right: CGFloat) {
        guard splitsAroundHardwareNotch else { return (0, 0) }
        let along = NotchLayout.cellAlong(for: edge) * splitCellScale
        let spacing = splitCellSpacing
        let leftCount = (cellCount + 1) / 2
        func width(_ count: Int) -> CGFloat {
            guard count > 0 else { return 0 }
            return CGFloat(count) * along + CGFloat(count - 1) * spacing
        }
        return (width(leftCount), width(cellCount - leftCount))
    }

    /// How far the shape sits from where it would sit if it were centred.
    ///
    /// The panel is centred on the screen and so is the hardware notch, so a
    /// shape that hugs unevenly has to be pushed back by half the difference
    /// for its gap to land on the hole.
    var splitShift: CGFloat { splitShift(cellCount: snapshots.count) }

    /// **The shift as drawn — nothing at all when the notch is folded.**
    ///
    /// The shift exists to land the shape's *gap* on the hardware when an
    /// uneven split makes the two sides different lengths. Folded there is no
    /// gap: the shape is the cutout itself, and it belongs over the cutout.
    /// Shifted anyway it sat some 21pt to one side of the hole with three
    /// rings — a band of black beside a notch that should have been invisible,
    /// and a sideways slide as it opened.
    ///
    /// The sizing keeps the open value: the window has to hold the open notch
    /// wherever it ends up. Only the drawing folds.
    var drawnSplitShift: CGFloat { isExpanded ? splitShift : 0 }

    func splitShift(cellCount: Int) -> CGFloat {
        guard splitsAroundHardwareNotch else { return 0 }
        let w = splitWidths(cellCount: cellCount)
        let pad = splitEndPads(cellCount: cellCount)
        return (w.left + pad.left - w.right - pad.right) / 2
    }

    /// How deep the bar is drawn beside the hardware, before the bleed.
    ///
    /// Never shallower than the hardware, whatever the size setting says: a bar
    /// that stopped short of the cutout's bottom edge would show a step exactly
    /// where the two are meant to read as one object. Above that it is free to
    /// grow, and the rings grow with it.
    var splitDrawnDepth: CGFloat {
        guard let notch = hardwareNotch else { return 0 }
        return notch.height * splitBarScale
    }

    /// **What the bar itself grows by beside the hardware: nothing.**
    ///
    /// The cutout does not resize, so the thing drawn as it may not either.
    /// This was `max(1, sizeScale)` for a while, and above 100% the bar came
    /// out deeper than the hole and hung below it — a notch of our own next to
    /// the Mac's rather than the Mac's made wider.
    ///
    /// Everything shaping the ear — its corner, its sweep, the orb and the arc
    /// — is measured from this, so they all hold the hardware's proportions at
    /// every setting and the two stay one object.
    ///
    /// The cost, stated plainly: the size setting cannot make the notch bigger
    /// on this edge, because there is no room between the rings and the hole's
    /// own depth for it to use. It still makes it smaller.
    var splitBarScale: CGFloat { 1 }

    /// How far the sweep into the screen's edge runs *along* the bar.
    ///
    /// The cutout has no such curve because it never reaches the screen's edge
    /// anywhere but along its own top. An ear does, and it joins it with this.
    ///
    /// This is the one the *sizing* cares about, because it is length the bar
    /// has to be given: see `flare`.
    var splitFillet: CGFloat? {
        guard let depth = splitFilletDepth else { return nil }
        return depth * NotchLayout.splitFilletWidth
    }

    /// And how much depth it uses. Less than its length — see
    /// `NotchLayout.splitFilletWidth`.
    ///
    /// **The open value, whatever the notch is doing now.**
    ///
    /// Everything that sizes the *window* is measured from here, and the window
    /// has to hold the open notch — it is what the fold animates inside. Fold
    /// this to nothing and `shapeLength` loses 38pt with it, so any relocate
    /// taken while the notch is shut builds a panel too narrow for the open
    /// one. The shape centres itself in that panel and lands 19pt off
    /// everything placed from `slack`: the settings arc off its corner, the
    /// tooltip wide of its ring. An edge change relocates while folded, which
    /// is why it showed up there and nowhere else.
    ///
    /// What the *shape* is given is `drawnFilletDepth`, which does fold.
    var splitFilletDepth: CGFloat? {
        guard splitsAroundHardwareNotch, let notch = hardwareNotch else { return nil }
        return splitBarLength(notch.height * NotchLayout.splitFilletFraction)
    }

    /// The sweep as drawn. Nothing at all when the notch is folded away: the
    /// sweep is how an *ear* joins the screen's edge, and folded there are no
    /// ears — the shape is the cutout and nothing else, which is the only way
    /// it can disappear into it. Drawn there it narrowed the resting tab well
    /// inside the hole: a tapered black tab sitting in a straight-sided one.
    var drawnFilletDepth: CGFloat? {
        guard let depth = splitFilletDepth else { return nil }
        return isExpanded ? depth : 0
    }

    /// And its length as drawn.
    var drawnFillet: CGFloat? {
        guard let length = splitFillet else { return nil }
        return isExpanded ? length : 0
    }

    /// **The notch's shape, configured.** Build it here and nowhere else.
    ///
    /// Five separate bugs in this redesign were the same bug: something worked
    /// out its own version of what the shape should be, and the tests agreed
    /// with it because they built their own too — so a green suite described a
    /// shape that was never on screen. A `SideNotchShape()` with four
    /// properties left at their defaults is a different object from the one
    /// the view draws, and there is no way to see that at the call site.
    var notchShape: SideNotchShape {
        var shape = SideNotchShape(edge: edge, joining: joinedNotch)
        shape.cornerRadius = drawnCornerRadius
        shape.filletRadius = drawnFillet
        shape.filletDepth = drawnFilletDepth
        shape.filletRamp = splitsAroundHardwareNotch ? NotchLayout.splitFilletRamp : 0
        shape.bezelHidden = splitsAroundHardwareNotch
            ? NotchRootView.bezelBleed / max(sizeScale, 0.0001) : 0
        shape.cornerCapOverride = splitsAroundHardwareNotch ? drawnCornerRadius : nil
        return shape
    }

    /// A bar-shaped length, held against the bar rather than the setting.
    private func splitBarLength(_ points: CGFloat) -> CGFloat {
        points * splitBarScale / max(sizeScale, 0.0001)
    }

    var splitCellScale: CGFloat {
        guard splitsAroundHardwareNotch, sizeScale > 0 else { return 1 }
        let room = splitDrawnDepth - 2 * NotchLayout.splitRingMargin
        guard room > 0 else { return 1 }
        // Fills the bar's depth, but never drawn larger than the design frame —
        // past that it is being stretched rather than sized. Below the default
        // size the bar cannot shrink, so the cell takes the setting instead.
        var drawn = min(splitCellExtent, room)
        if sizeScale < 1 { drawn *= sizeScale }
        return drawn / (splitCellExtent * sizeScale)
    }

    /// How tall a cell is in the strip: a ring, or a ring with its reading
    /// under it once there is depth enough for one.
    var splitCellExtent: CGFloat {
        splitShowsReading ? NotchLayout.cellExtent : NotchLayout.ringDiameter
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
    /// this cannot depend on `splitCellScale` — which depends on it.
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

    /// The same question as `showsCellReading`, kept for the strip's own
    /// sizing, which has to know before it can work out the cell's scale.
    var splitShowsReading: Bool {
        guard splitsAroundHardwareNotch else { return true }
        return showsNotchReadings
    }

    /// The split layout's own lengths, held at their drawn size whatever the
    /// size setting is. The hole and the strips beside it are hardware.
    private func splitFixed(_ points: CGFloat) -> CGFloat {
        points / max(sizeScale, 0.0001)
    }

    /// How much of each end of the bar the flare actually takes.
    var flare: CGFloat {
        // The same number the shape is given, so whatever length the path
        // spends turning out to the border is length `shapeLength` asked for.
        // Zero beside the hardware, where it does not turn at all.
        if splitsAroundHardwareNotch { return splitFillet ?? 0 }
        return isFlushWithHardware ? NotchLayout.bezelFillet : NotchLayout.curlRadius
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
        // Beside the hole the bar is only the hardware's depth, and half of
        // that is a pill end rather than a notch corner — the Mac's own corners
        // are a much smaller fraction of its height. Capped so the ends read as
        // the same kind of corner the hardware has.
        if splitsAroundHardwareNotch {
            // A fraction of the hardware's own height, so the ear turns at the
            // rate the cutout does rather than at a number picked to look right
            // at one size.
            return splitBarLength(hardwareNotch.height * NotchLayout.splitCornerFraction)
        }
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
            ? NotchLayout.orbConvexArcRadius(corner: drawnCornerRadius, scale: orbScale)
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
        // Nothing to spread when the rings sit beside the hole: the shape
        // already contains the hardware's full width as its gap, so it clears
        // it by construction. Spreading on top of that widened a one-ring bar
        // past a two-ring one.
        guard !splitsAroundHardwareNotch else { return 0 }
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
    var orbScale: CGFloat {
        guard splitsAroundHardwareNotch, NotchLayout.orbDiameter > 0 else { return 1 }
        return min(1, NotchLayout.ringDiameter * splitCellScale / NotchLayout.orbDiameter)
    }

    var orbAlong: CGFloat {
        guard orbHugsCorner else { return shapeLength }
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
        shapeLength - orbAlong
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
        guard orbHugsCorner else { return contentInset + NotchLayout.orbInsetFromEdge }
        // Measured from the bar's own depth. Beside the hardware that is the
        // hardware's height, not `bodyDepth` — the stacked layout's depth, some
        // 30pt deeper — so the orb was being placed well below a bar that had
        // shrunk under it and read as a stray arc floating in the wallpaper.
        return drawnFoot - drawnCornerRadius
            + NotchLayout.orbCornerOffset(corner: drawnCornerRadius, scale: orbScale)
    }

    /// Where the resting arc sits relative to the button.
    ///
    /// Inside a flare's pocket the two are one object — the arc is just the
    /// outer edge of the same orb, and this is zero. Hanging off a convex
    /// corner they part company: the button has to be clear of the bar, but the
    /// arc's whole job is to trace the bar's contour, so it stays back on the
    /// corner the button hangs from.
    /// The bar's visible foot, measured from the bezel in stack space.
    ///
    /// Not `notchDepth`, which beside the hardware carries `bezelBleed` on top
    /// — the couple of points the shape is pushed *past* the top of the screen
    /// so no wallpaper hairline shows. Anything placed against the foot has to
    /// use this one or it lands that far below what the eye sees.
    var drawnFoot: CGFloat {
        if splitsAroundHardwareNotch {
            return splitDrawnDepth / max(sizeScale, 0.0001)
        }
        return contentInset + NotchLayout.bodyDepth(for: edge)
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
        if splitsAroundHardwareNotch {
            return splitDrawnDepth / 2 / max(sizeScale, 0.0001)
        }
        return contentInset + NotchLayout.bodyDepth(for: edge) / 2
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
        // Beside the hardware the bar is the cutout's depth, not the stacked
        // layout's — some 60pt shallower. Measured the old way the tooltip hung
        // that far below a notch that had shrunk out from under it, with a
        // stretch of wallpaper between the tail and the thing it points at.
        if splitsAroundHardwareNotch { return drawnFoot * sizeScale }
        return (contentInset + NotchLayout.bodyDepth(for: edge)) * sizeScale
    }

    /// The straight part of the shape, flares excluded.
    var bodyLength: CGFloat {
        guard splitsAroundHardwareNotch else {
            return NotchLayout.bodyLength(
                cellCount: snapshots.count, edge: edge, spacing: cellSpacing
            ) + 2 * endSpread
        }
        let w = splitWidths(cellCount: snapshots.count)
        let pad = splitEndPads(cellCount: snapshots.count)
        return pad.left + pad.right + w.left + w.right + splitGap + 2 * endSpread
    }

    /// Distance along the stack to cell `index`'s ring centre, widening
    /// included so the readings stay in the middle of the bar.
    func ringCenter(index: Int) -> CGFloat {
        guard splitsAroundHardwareNotch else {
            return NotchLayout.ringCenter(index: index, edge: edge, flare: flare,
                                          spacing: cellSpacing) + endSpread
        }
        // Each group is measured from its own side of the gap, and the gap is
        // centred in the shape. Everything downstream — `cellIndex(along:)`,
        // the hover bands, the tooltip tails — reads its positions from here
        // rather than from the view, so teaching it here is enough.
        let along = NotchLayout.cellAlong(for: edge) * splitCellScale
        let pitch = along + splitCellSpacing
        let base = cellsLeadIn
        let widths = splitWidths(cellCount: snapshots.count)
        if index < splitLeftCount {
            return base + CGFloat(index) * pitch + along / 2
        }
        return base + widths.left + splitGap
            + CGFloat(index - splitLeftCount) * pitch + along / 2
    }

    var cellSpacing: CGFloat { cellSpacing(cellCount: snapshots.count) }
    /// Centre-to-centre distance between cells, which is also the width of the
    /// band `cellIndex(along:)` treats as belonging to one. Scaled with the
    /// cell: beside the hardware notch the rings are smaller, and a band left
    /// at full width would reach into the hole.
    var cellPitch: CGFloat {
        NotchLayout.cellAlong(for: edge) * splitCellScale
            + (splitsAroundHardwareNotch ? splitCellSpacing : cellSpacing)
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
        let content = snapshots.isEmpty
            ? NotchLayout.maxCardHeight(sessionCap: cap, hasTokenUsage: hasTokenUsage, hasPlan: hasPlan,
                                        hasResetCredits: hasResetCredits)
            : contentCardHeight(sessionCap: cap)
        // A pending request's card counts too, but only as far as the screen
        // allows; past that the card trims its preview (`permissionCardLimit`).
        guard let request = permissionRequests.first else { return content }
        let budget = cardBudget(cellCount: cellCount)
        return max(content, min(PermissionCard.height(for: request, limit: budget), budget))
    }

    /// The most height the permission card may take on this screen.
    var permissionCardLimit: CGFloat { cardBudget(cellCount: snapshots.count) }

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
        return restingLength
    }

    /// And across it.
    var notchDepth: CGFloat {
        if splitsAroundHardwareNotch, let notch = hardwareNotch {
            // Open or folded, it is the hardware's depth: the shape is the hole
            // made wider, not a bar hung below it.
            //
            // Plus the bleed, because the shape is then pushed that far *past*
            // the top of the screen so no wallpaper hairline shows at the
            // bezel. Without it the overhang comes out of the visible depth and
            // the bar ends two points above the hardware's bottom edge — a step
            // exactly where the two are supposed to read as one object.
            // Folded, exactly the cutout's depth. Nothing may hang below it:
            // anything drawn there makes the notch read as deeper than the one
            // the display actually has.
            let body = isExpanded ? splitDrawnDepth : notch.height
            return (body + NotchRootView.bezelBleed) / max(sizeScale, 0.0001)
        }
        if isExpanded { return contentInset + NotchLayout.bodyDepth(for: edge) }
        return hardwareNotch?.height ?? NotchLayout.pillWidth
    }

    /// What the notch folds away to, whether or not it is open right now —
    /// the hit region has to know that while the notch is still open.
    ///
    /// **Beside the hardware it folds to the cutout itself** — the hole's own
    /// width, and its depth. Nothing of it can be seen, which is the point:
    /// at rest the app is the notch the Mac already has.
    ///
    /// Two other things have been tried here and are worse. A small pill in
    /// the middle of the hole hides just as well, but the fold is an animation
    /// and that one had the ears coming out of a point in the centre of the
    /// notch rather than out of the notch. A pill's width of ear standing past
    /// each end is visible, and reads as something stuck to the cutout rather
    /// than the cutout itself.
    ///
    /// Divided by the size setting because the hardware is not scaled by it —
    /// the shape is drawn in design points and multiplied back up, and the
    /// hole stays exactly where it is throughout.
    var restingLength: CGFloat {
        guard splitsAroundHardwareNotch, let notch = hardwareNotch else {
            return hardwareNotch?.width ?? NotchLayout.pillHeight
        }
        return notch.width / max(sizeScale, 0.0001)
    }
    var restingDepth: CGFloat {
        guard splitsAroundHardwareNotch, let notch = hardwareNotch else {
            return hardwareNotch?.height ?? NotchLayout.pillWidth
        }
        return notch.height / max(sizeScale, 0.0001)
    }

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
    /// Flush with the hardware, what wakes the notch is the notch.
    var wakeLength: CGFloat {
        // The cutout is the target beside the hardware, not the pill under it:
        // the pill is a sliver, and the hole above it is where the hand goes.
        let pill = max(restingLength * sizeScale, wakeBand)
        guard splitsAroundHardwareNotch, let notch = hardwareNotch else { return pill }
        return max(pill, notch.width)
    }
    var wakeDepth: CGFloat { restingDepth * sizeScale + wakeBand }
    private var wakeBand: CGFloat { isFlushWithHardware ? 0 : NotchLayout.pillHotZone }

    /// The drawn size of the notch body, in panel axes.
    var notchSize: CGSize {
        NotchPlacement.panelSize(edge: edge, length: notchLength, depth: notchDepth)
    }

    /// Where the notch starts along the stack. Both states share a centre line,
    /// so folding away does not slide the notch along the edge as it shrinks.
    var notchLeadingInset: CGFloat {
        slack + (shapeLength - notchLength) / 2 - splitShift
    }

    /// Sized from an explicit count rather than from `snapshots`.
    ///
    /// `@Published` notifies its subscribers in `willSet`, so a sink reacting to
    /// a change in the provider list still sees the *old* array if it reads the
    /// model back. Taking the count as an argument is the only way to be sure
    /// the panel is sized for the list that caused the change.
    func shapeLength(cellCount: Int) -> CGFloat {
        if splitsAroundHardwareNotch {
            // The straight part is two equal sides with the hardware between
            // them, plus the flares. Taken from the same numbers `ringCenter`
            // uses, so the hole it leaves and the hole the rings are placed
            // around cannot drift apart.
            let w = splitWidths(cellCount: cellCount)
            let pad = splitEndPads(cellCount: cellCount)
            return pad.left + pad.right
                + w.left + w.right + splitGap + 2 * flare + 2 * endSpread(cellCount: cellCount)
        }
        return NotchLayout.shapeLength(cellCount: cellCount,
                                edge: edge, flare: flare,
                                spacing: cellSpacing(cellCount: cellCount))
            + 2 * endSpread(cellCount: cellCount)
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
            length: shapeLength(cellCount: cellCount) * sizeScale
                + 2 * NotchLayout.slack(for: edge, maxCardHeight: card, notchScale: sizeScale)
                + 2 * abs(splitShift(cellCount: cellCount)) * sizeScale,
            depth: (contentInset + NotchLayout.bodyDepth(for: edge)) * sizeScale
                + NotchLayout.tooltipDepth(for: edge, maxCardHeight: card)
        )
    }
}
